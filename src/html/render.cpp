// src/html/render.cpp — litehtml + cairo 无头 HTML→PNG。
// litehtml 只做 CSS 布局（盒子树），像素由 cairo 画（cairo toy font API，够用且零 pango 依赖）。
// 导出 ABI：int lite_html_render(const char* html, const char* out_png, int w, int h, double scale)
//           const char* lite_html_error(void)
#include <litehtml/html.h>
#include <litehtml/document.h>
#include <litehtml/document_container.h>

#include <cairo/cairo.h>
#include <fontconfig/fontconfig.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>
#include <map>
#include <memory>

#include "prepass.h"

using namespace litehtml;

namespace {

std::string g_error;

struct font_entry {
    cairo_scaled_font_t* sf = nullptr;
    std::string family = "Sans";
    int slant  = CAIRO_FONT_SLANT_NORMAL;
    int weight = CAIRO_FONT_WEIGHT_NORMAL;
    double size    = 14;
    double ascent  = 0;
    double descent = 0;
    double height  = 0;
    double x_height = 0;
    double ch_width = 0;
};

inline cairo_t* cr_of(uint_ptr hdc) { return reinterpret_cast<cairo_t*>(hdc); }
inline font_entry* fe_of(uint_ptr f) { return reinterpret_cast<font_entry*>(f); }

// 缺字回退顺序：注册进 fontconfig 的 Droid Sans Fallback 覆盖 CJK + 全角标点，
// DejaVu 兜西文/数学符号，Symbola / FreeSerif 兜 emoji 与装饰符号（✅❌⏳𝄞），
// 最后 Noto Color Emoji（彩色位图，cairo 有时画不出，仅当兜底）。族不存在时
// scaled_has_glyph 直接判 miss，所以这份清单跨机器多写几个也不出错。
const char* const kFallbackFamilies[] = {
    "Droid Sans Fallback", "Noto Sans CJK SC", "DejaVu Sans",
    "Symbola", "FreeSerif", "Noto Sans Symbols2", "Noto Color Emoji", nullptr
};

// 切一个 UTF-8 字符（非法/截断字节当成单字节）
size_t utf8_next(const char* s, size_t len, size_t i)
{
    unsigned char c = (unsigned char)s[i];
    size_t n = 1;
    if (c >= 0xF0) n = 4;
    else if (c >= 0xE0) n = 3;
    else if (c >= 0xC0) n = 2;
    if (i + n > len) n = 1;
    return i + n;
}

// 这个 scaled font 能否画出这段字节：任一字形 index==0 即缺字。
// 纯空白返回的 glyph 数为 0，不算缺字。
bool scaled_has_glyph(cairo_scaled_font_t* sf, const char* s, int len)
{
    if (!sf) return false;
    cairo_glyph_t* glyphs = nullptr;
    cairo_text_cluster_t* clusters = nullptr;
    int ng = 0, nc = 0;
    cairo_text_cluster_flags_t cf = (cairo_text_cluster_flags_t)0;
    cairo_status_t st = cairo_scaled_font_text_to_glyphs(
        sf, 0, 0, s, len, &glyphs, &ng, &clusters, &nc, &cf);
    bool ok = (st == CAIRO_STATUS_SUCCESS);
    if (ok)
        for (int i = 0; i < ng; ++i)
            if (glyphs[i].index == 0) { ok = false; break; }
    if (glyphs) cairo_glyph_free(glyphs);
    if (clusters) cairo_text_cluster_free(clusters);
    return ok;
}

void rect_fill(cairo_t* cr, const web_color& c, double x, double y, double w, double h)
{
    if (!cr || w <= 0 || h <= 0) return;
    cairo_set_source_rgba(cr, c.red / 255.0, c.green / 255.0, c.blue / 255.0, c.alpha / 255.0);
    cairo_rectangle(cr, x, y, w, h);
    cairo_fill(cr);
}

// 四角半径（像素；x/y 可不等 = 椭圆圆角）。litehtml 的 border_radiuses 是 pixel_t，这里摊平。
struct radii4
{
    double tlx = 0, tly = 0, trx = 0, try_ = 0, brx = 0, bry = 0, blx = 0, bly = 0;
};

radii4 radii_of(const border_radiuses& r)
{
    radii4 o;
    o.tlx  = r.top_left_x;
    o.tly  = r.top_left_y;
    o.trx  = r.top_right_x;
    o.try_ = r.top_right_y;
    o.brx  = r.bottom_right_x;
    o.bry  = r.bottom_right_y;
    o.blx  = r.bottom_left_x;
    o.bly  = r.bottom_left_y;
    return o;
}

bool radii_is_zero(const radii4& r)
{
    return r.tlx <= 0 && r.tly <= 0 && r.trx <= 0 && r.try_ <= 0 && r.brx <= 0 && r.bry <= 0 &&
           r.blx <= 0 && r.bly <= 0;
}

// 相邻角的半径之和不得超过边（否则路径自交、填充糊成一片）。litehtml 对 CSS 值
// 做过 fix_values，但内缩矩形（border box 减 border width）算出来可能为负，必须再夹一次。
void clamp_radii(radii4& r, double w, double h)
{
    auto nn = [](double& v) { if (!(v > 0)) v = 0; };
    nn(r.tlx); nn(r.tly); nn(r.trx); nn(r.try_); nn(r.brx); nn(r.bry); nn(r.blx); nn(r.bly);
    auto fit = [](double& a, double& b, double len) {
        if (a + b > len && a + b > 0) { const double k = len / (a + b); a *= k; b *= k; }
    };
    fit(r.tlx, r.trx, w);
    fit(r.blx, r.brx, w);
    fit(r.tly, r.bly, h);
    fit(r.try_, r.bry, h);
}

// 椭圆角：cairo 的 arc 只有正圆，靠 translate+scale 变换成椭圆弧。
void corner_arc(cairo_t* cr, double cx, double cy, double rx, double ry, double a1, double a2)
{
    if (rx <= 0.01 || ry <= 0.01) { cairo_line_to(cr, cx, cy); return; }
    cairo_save(cr);
    cairo_translate(cr, cx, cy);
    cairo_scale(cr, rx, ry);
    cairo_arc(cr, 0, 0, 1, a1, a2);
    cairo_restore(cr);
}

// 只往当前路径**追加**一个圆角矩形子路径（不清路径），方便两个子路径做 even-odd 环。
void rounded_rect_path(cairo_t* cr, double x, double y, double w, double h, radii4 r)
{
    if (w <= 0 || h <= 0) return;
    clamp_radii(r, w, h);
    const double PI = M_PI;
    cairo_move_to(cr, x + r.tlx, y);
    cairo_line_to(cr, x + w - r.trx, y);
    corner_arc(cr, x + w - r.trx, y + r.try_, r.trx, r.try_, -PI / 2, 0);
    cairo_line_to(cr, x + w, y + h - r.bry);
    corner_arc(cr, x + w - r.brx, y + h - r.bry, r.brx, r.bry, 0, PI / 2);
    cairo_line_to(cr, x + r.blx, y + h);
    corner_arc(cr, x + r.blx, y + h - r.bly, r.blx, r.bly, PI / 2, PI);
    cairo_line_to(cr, x, y + r.tly);
    corner_arc(cr, x + r.tlx, y + r.tly, r.tlx, r.tly, PI, 1.5 * PI);
    cairo_close_path(cr);
}

void set_src(cairo_t* cr, const web_color& c)
{
    cairo_set_source_rgba(cr, c.red / 255.0, c.green / 255.0, c.blue / 255.0, c.alpha / 255.0);
}

// 背景层统一裁剪：clip_box 矩形 ∩ 圆角 border_box（litehtml 要求一切画在 border_box 内，
// 而 border-radius 就是「把矩形抹圆」，不裁剪就会出现方角背景角刺出圆角边框）。
void layer_clip(cairo_t* cr, const background_layer& layer)
{
    cairo_rectangle(cr, layer.clip_box.x, layer.clip_box.y, layer.clip_box.width, layer.clip_box.height);
    cairo_clip(cr);
    cairo_new_path(cr);
    rounded_rect_path(cr, layer.border_box.x, layer.border_box.y, layer.border_box.width,
                      layer.border_box.height, radii_of(layer.border_radius));
    cairo_clip(cr);
}

// 按 background_layer 的 border_box（含圆角）填充
void layer_fill(cairo_t* cr, const background_layer& layer, const web_color& c)
{
    if (!cr) return;
    cairo_save(cr);
    layer_clip(cr, layer);
    cairo_rectangle(cr, layer.border_box.x, layer.border_box.y, layer.border_box.width,
                    layer.border_box.height);
    set_src(cr, c);
    cairo_fill(cr);
    cairo_restore(cr);
}

// box-shadow 只能在没有元素钩子的容器里近似：从外到内叠一圈圈「放大 / 内缩」的圆角环，
// 每一带的目标遮盖率取 CSS 的模糊剖面 coverage = 0.5*erfc((s - spread)/(σ√2))（σ = blur/2，
// s = 到阴影自身边界的有符号距离，正=外侧），再反解出「画这一圈要多不透明」，使得 n..1 圈
// 叠起来在每一带正好等于该遮盖率。
// 三个必踩的坑：
//   1. 每圈固定 alpha 叠加 → 不透明阴影（rgba(...,1)）每圈都是 1，整块糊成硬边实心光晕；
//   2. 采样区间只铺 s>=0 的环、内环却用「平移后的盒子」挖洞 → offset 露出的那一条
//      （y..y+dy）没人画，卡片和阴影之间留一圈背景色亮缝。区间要往内延伸到
//      「平移量 + 3σ」，挖洞只挖元素自己的盒子（阴影压在元素里的部分才该被遮住）；
//   3. erfc 的自变量要保留符号，别先取绝对值（内侧遮盖率 > 0.5）。
void paint_shadow(cairo_t* cr, const background_layer& layer, const prepass::shadow_spec& s)
{
    if (!cr || s.a <= 0) return;
    const double ex = layer.border_box.x.value();
    const double ey = layer.border_box.y.value();
    const double ew = layer.border_box.width.value();
    const double eh = layer.border_box.height.value();
    if (ew <= 0 || eh <= 0) return;
    const double bx = ex + s.dx;                        // 阴影自身盒子 = 元素盒子平移
    const double by = ey + s.dy;

    const double target = s.a / 255.0;                  // 阴影颜色自身的不透明度
    const double sigma  = s.blur > 0.5 ? s.blur * 0.5 : 0.25;
    const double out_b  = s.blur > 0.5 ? s.blur * 1.5 : 0.5;   // 外侧铺满 3σ
    const double in_b   = out_b + std::max(std::fabs(s.dx), std::fabs(s.dy));
    const double total  = out_b + in_b;
    // 1 带 ≈ 0.5px，少了会看到一圈圈色带
    const int n = static_cast<int>(std::clamp(std::ceil(total * 2.0), 16.0, 96.0));

    // A[k] = 第 k 带（含其内所有带）叠完后的目标累计 alpha，k 越大越靠外
    std::vector<double> A(static_cast<size_t>(n) + 2, 0.0);
    for (int k = 1; k <= n; ++k) {
        const double d = s.spread - in_b + total * (k - 0.5) / n;   // 相对阴影边界，正=外侧
        A[k] = std::clamp(target * 0.5 * std::erfc(d / (sigma * std::sqrt(2.0))), 0.0, 1.0);
    }

    const radii4 base = radii_of(layer.border_radius);

    cairo_save(cr);
    cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
    for (int j = n; j >= 1; --j)
    {
        // 画了 j..n 圈之后，第 j 带要是 A[j]：由 (1-A[j])/(1-A[j+1]) 反解本圈 alpha
        const double denom = 1.0 - A[static_cast<size_t>(j) + 1];
        if (denom <= 1e-6) continue;
        const double a = 1.0 - (1.0 - A[static_cast<size_t>(j)]) / denom;
        if (a <= 0.0) continue;
        const double grow = s.spread - in_b + total * j / n;   // 负值 = 往阴影里内缩
        radii4       rr   = base;
        rr.tlx += grow; rr.tly += grow; rr.trx += grow; rr.try_ += grow;
        rr.brx += grow; rr.bry += grow; rr.blx += grow; rr.bly += grow;
        cairo_new_path(cr);
        rounded_rect_path(cr, bx - grow, by - grow, ew + 2 * grow, eh + 2 * grow, rr);
        rounded_rect_path(cr, ex, ey, ew, eh, base);   // 挖掉元素自身（不带 offset）
        cairo_set_source_rgba(cr, s.r / 255.0, s.g / 255.0, s.b / 255.0, a);
        cairo_fill(cr);
    }
    cairo_restore(cr);
}

class cairo_container : public document_container
{
public:
    std::map<std::string, font_entry*> m_fonts;
    int m_clip_depth = 0;
    // 元素级 clip（overflow != visible）的右边界栈，给 text-overflow 近似截断用
    std::vector<double> m_clip_right;
    int m_n_text = 0, m_n_fill = 0, m_n_clip = 0;
    int m_width  = 800;
    int m_height = 600;
    std::string m_base_url;
    std::string m_font_name = "Sans";
    // prepass 识别出的 box-shadow（哨兵色 b 通道 = 索引 + 1）
    std::vector<prepass::shadow_spec> m_shadows;
    // key: family|slant|weight|size → cairo_scaled_font_t*（只用于查缺字）
    std::map<std::string, cairo_scaled_font_t*> m_sf_cache;

    struct text_run {
        std::string text;
        std::string family;
    };

    // 取（并缓存）某个族的 scaled font；用临时 ctx 再 reference，绕开本机
    // cairo_scaled_font_create 直接建 toy face 返回 NULL_POINTER 的坑。
    cairo_scaled_font_t* scaled_get(const std::string& family, int slant, int weight, double size)
    {
        char key[300];
        snprintf(key, sizeof key, "%s|%d|%d|%.2f", family.c_str(), slant, weight, size);
        auto it = m_sf_cache.find(key);
        if (it != m_sf_cache.end()) return it->second;

        cairo_surface_t* scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        cairo_t* tmp = cairo_create(scratch);
        cairo_select_font_face(tmp, family.c_str(), (cairo_font_slant_t)slant,
                               (cairo_font_weight_t)weight);
        cairo_set_font_size(tmp, size);
        cairo_scaled_font_t* sf = cairo_get_scaled_font(tmp);
        if (cairo_scaled_font_status(sf) != CAIRO_STATUS_SUCCESS) sf = nullptr;
        else sf = cairo_scaled_font_reference(sf);
        cairo_destroy(tmp);
        cairo_surface_destroy(scratch);

        m_sf_cache[key] = sf;
        return sf;
    }

    // 按「当前字体有没有这个字形」切 run：cairo toy font API 没有自动 fallback，
    // 代码块用 DejaVu Sans Mono 时全角：）等会画成豆腐块。
    void build_runs(const char* text, font_entry* fe, std::vector<text_run>& runs)
    {
        size_t n = strlen(text);
        cairo_scaled_font_t* primary = scaled_get(fe->family, fe->slant, fe->weight, fe->size);
        std::string cur_family = fe->family;
        std::string cur;
        size_t i = 0;
        while (i < n) {
            size_t j = utf8_next(text, n, i);
            std::string fam = fe->family;
            if (!scaled_has_glyph(primary, text + i, (int)(j - i))) {
                for (int k = 0; kFallbackFamilies[k]; ++k) {
                    cairo_scaled_font_t* cs = scaled_get(kFallbackFamilies[k], fe->slant,
                                                         fe->weight, fe->size);
                    if (scaled_has_glyph(cs, text + i, (int)(j - i))) {
                        fam = kFallbackFamilies[k];
                        break;
                    }
                }
            }
            if (!cur.empty() && fam != cur_family) {
                runs.push_back(text_run{cur, cur_family});
                cur.clear();
            }
            cur_family = fam;
            cur.append(text + i, j - i);
            i = j;
        }
        if (!cur.empty()) runs.push_back(text_run{cur, cur_family});
    }

    ~cairo_container() override
    {
        for (auto& kv : m_fonts) {
            if (kv.second) {
                if (kv.second->sf) cairo_scaled_font_destroy(kv.second->sf);
                delete kv.second;
            }
        }
        for (auto& kv : m_sf_cache)
            if (kv.second) cairo_scaled_font_destroy(kv.second);
    }

    uint_ptr create_font(const font_description& d, const document* /*doc*/, font_metrics* fm) override
    {
        auto* fe = new font_entry();
        fe->size = d.size.value();
        if (fe->size < 1) fe->size = 14;

        // cairo toy font API 只接受单一字体名：CSS 的 "A","B",serif 多值列表会让
        // cairo_select_font_face 匹配失败并静默落回 Sans。这里取第一个可用的族名。
        std::string fam = d.family.empty() ? m_font_name : d.family;
        std::string first;
        for (size_t i = 0; i < fam.size() && fam[i] != ','; ++i) {
            char ch = fam[i];
            if (ch == '"' || ch == '\'' || ch == ' ') { if (ch == ' ' && !first.empty()) {} else continue; }
            first.push_back(ch);
        }
        while (!first.empty() && first.back() == ' ') first.pop_back();
        if (first.empty()) first = "Sans";
        const char* family = first.c_str();
        cairo_font_slant_t slant = (d.style == font_style_italic) ? CAIRO_FONT_SLANT_ITALIC : CAIRO_FONT_SLANT_NORMAL;
        cairo_font_weight_t weight = (d.weight >= 600) ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL;

        // 本机 cairo_scaled_font_create 返回 CAIRO_STATUS_NULL_POINTER(7)：度量全 0、
        // show_text 静默不出墨。统一改走 toy font API（select_font_face + set_font_size）。
        fe->family = family;
        fe->slant  = (int)slant;
        fe->weight = (int)weight;

        cairo_surface_t* scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        cairo_t* tmp = cairo_create(scratch);
        cairo_select_font_face(tmp, family, slant, weight);
        cairo_set_font_size(tmp, fe->size);

        cairo_font_extents_t ext;
        cairo_font_extents(tmp, &ext);
        fe->ascent  = ext.ascent;
        fe->descent = ext.descent;
        fe->height  = ext.height;

        cairo_text_extents_t te;
        cairo_text_extents(tmp, "x", &te);
        fe->x_height = te.height;
        cairo_text_extents(tmp, "0", &te);
        fe->ch_width = te.x_advance;
        cairo_destroy(tmp);
        cairo_surface_destroy(scratch);

        if (fm) {
            fm->font_size = (float)fe->size;
            fm->height    = (float)fe->height;
            fm->ascent    = (float)fe->ascent;
            fm->descent   = (float)fe->descent;
            fm->x_height  = (float)fe->x_height;
            fm->ch_width  = (float)fe->ch_width;
            fm->draw_spaces = false;
        }
        return reinterpret_cast<uint_ptr>(fe);
    }

    void delete_font(uint_ptr hFont) override
    {
        auto* fe = fe_of(hFont);
        if (!fe) return;
        if (fe->sf) cairo_scaled_font_destroy(fe->sf);
        delete fe;
    }

    pixel_t text_width(const char* text, uint_ptr hFont) override
    {
        auto* fe = fe_of(hFont);
        if (!fe || !text) return 0;
        std::vector<text_run> runs;
        build_runs(text, fe, runs);

        cairo_surface_t* scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        cairo_t* tmp = cairo_create(scratch);
        double total = 0;
        for (auto& r : runs) {
            cairo_select_font_face(tmp, r.family.c_str(), (cairo_font_slant_t)fe->slant,
                                   (cairo_font_weight_t)fe->weight);
            cairo_set_font_size(tmp, fe->size);
            cairo_text_extents_t te;
            cairo_text_extents(tmp, r.text.c_str(), &te);
            total += te.x_advance;
        }
        cairo_destroy(tmp);
        cairo_surface_destroy(scratch);
        return pixel_t(static_cast<float>(std::ceil(total)));
    }

    // 单段 run 的绘制宽度
    double run_width(cairo_t* cr, font_entry* fe, const text_run& r)
    {
        cairo_select_font_face(cr, r.family.c_str(), (cairo_font_slant_t)fe->slant,
                               (cairo_font_weight_t)fe->weight);
        cairo_set_font_size(cr, fe->size);
        cairo_text_extents_t te;
        cairo_text_extents(cr, r.text.c_str(), &te);
        return te.x_advance;
    }

    // 一段文本（已按字形回退切成 runs）的绘制宽度
    double runs_width(cairo_t* cr, font_entry* fe, const std::vector<text_run>& runs)
    {
        double w = 0.0;
        for (auto& r : runs) w += run_width(cr, fe, r);
        return w;
    }

    // 量一段 UTF-8 文本的宽度（走同一套字形回退）
    double ell_width(cairo_t* cr, font_entry* fe, const std::string& s)
    {
        std::vector<text_run> tr;
        build_runs(s.c_str(), fe, tr);
        return runs_width(cr, fe, tr);
    }

    // 画一段文本（已切好 runs），从 (x, baseline) 起
    void paint_runs(cairo_t* cr, font_entry* fe, const web_color& color, double x, double y,
                    const std::vector<text_run>& runs)
    {
        cairo_save(cr);
        cairo_set_source_rgba(cr, color.red / 255.0, color.green / 255.0, color.blue / 255.0,
                              color.alpha / 255.0);
        for (auto& r : runs) {
            cairo_select_font_face(cr, r.family.c_str(), (cairo_font_slant_t)fe->slant,
                                   (cairo_font_weight_t)fe->weight);
            cairo_set_font_size(cr, fe->size);
            cairo_move_to(cr, x, y);
            cairo_show_text(cr, r.text.c_str());
            cairo_text_extents_t te;
            cairo_text_extents(cr, r.text.c_str(), &te);
            x += te.x_advance;
        }
        cairo_restore(cr);
    }

    // 同一视觉行上、同一 clip 内的待画片段。litehtml 在 nowrap 下是「一个词/一个汉字
    // 一次 draw_text」，单看某一段根本判断不出整行会不会越过 clip 右边界，所以先把整行
    // 收齐，等行尾/换行/clip 变化时再一次性落笔——这样换行排版的每一行本来就装得下，
    // 永远不会被加省略号，而 nowrap 溢出的那行精确截断。
    struct pend_frag
    {
        std::string text;
        double x = 0, y = 0;
        font_entry* fe = nullptr;
        web_color color{};
    };
    std::vector<pend_frag> m_pend;
    double m_pend_clip = 0;

    // text-overflow:ellipsis 的近似：clip 生效且整行越过右边界时，截到能放下省略号为止。
    void flush_text()
    {
        if (m_pend.empty()) return;
        cairo_t* cr = g_cr;
        const bool has_clip = !m_clip_right.empty();
        const double clip_r = has_clip ? m_clip_right.back() : 1e9;
        if (cr) {
            double end = 0.0;
            for (auto& p : m_pend) {
                std::vector<text_run> tr;
                build_runs(p.text.c_str(), p.fe, tr);
                end = p.x + runs_width(cr, p.fe, tr);
            }
            const bool cut = has_clip && end > clip_r + 0.5;
            double x_stop  = 1e9;                              // 超过这个 x 就不再画
            if (cut) {
                auto& last = m_pend.back();
                const double ell = ell_width(cr, last.fe, "\xE2\x80\xA6");
                x_stop = clip_r - ell;                         // 给省略号留位置
            }
            for (auto& p : m_pend) {
                std::vector<text_run> tr;
                build_runs(p.text.c_str(), p.fe, tr);
                const double y = p.y + p.fe->ascent;
                if (p.x + runs_width(cr, p.fe, tr) <= x_stop + 0.5) {
                    paint_runs(cr, p.fe, p.color, p.x, y, tr);  // 整段放得下
                    continue;
                }
                // 这一段跨过了边界：逐字画到放不下为止，再补省略号
                double x = p.x;
                for (size_t i = 0, n = p.text.size(); i < n;) {
                    const size_t j = utf8_next(p.text.c_str(), n, i);
                    const std::string ch = p.text.substr(i, j - i);
                    std::vector<text_run> ct;
                    build_runs(ch.c_str(), p.fe, ct);
                    const double cw = runs_width(cr, p.fe, ct);
                    if (cut && x + cw > x_stop + 0.5) {
                        std::vector<text_run> et;
                        build_runs("\xE2\x80\xA6", p.fe, et);
                        paint_runs(cr, p.fe, p.color, x, y, et);   // 省略号收尾
                        break;
                    }
                    paint_runs(cr, p.fe, p.color, x, y, ct);
                    x += cw;
                    i = j;
                }
                if (cut) break;                                // 后面的片段不再画
            }
        }
        m_pend.clear();
    }

    void draw_text(uint_ptr hdc, const char* text, uint_ptr hFont, web_color color,
                   const position& pos) override
    {
        auto* cr = cr_of(hdc);
        auto* fe = fe_of(hFont);
        if (!cr || !fe || !text || !*text) return;
        // 同一行（y 相同）+ 同一 clip 才合并，否则先把上一行落笔
        const double clip_r = m_clip_right.empty() ? 0.0 : m_clip_right.back();
        if (!m_pend.empty() &&
            (std::fabs(pos.y.value() - m_pend.front().y) > 0.5 || clip_r != m_pend_clip))
            flush_text();
        if (m_pend.empty()) m_pend_clip = clip_r;
        pend_frag f;
        f.text  = text;
        f.x     = pos.x.value();
        f.y     = pos.y.value();
        f.fe    = fe;
        f.color = color;
        m_pend.push_back(std::move(f));
    }

    pixel_t pt_to_px(float pt) const override { return static_cast<pixel_t>(pt * 1.3333f); }
    pixel_t get_default_font_size() const override { return 14; }
    const char* get_default_font_name() const override { return m_font_name.c_str(); }

    // 列表符号（bullet）：litehtml 只为 none/circle/disc/square 回调这里，
    // 数字/字母序号的文字它自己用 draw_text 画。以前这里 clip_fill(黑) 会把
    // 整个 clip 区涂黑（从 corner 到整页全黑），必须按 marker_type 画形状。
    void draw_list_marker(uint_ptr hdc, const list_marker& marker) override
    {
        flush_text();
        auto* cr = cr_of(hdc);
        if (!cr) return;
        if (marker.marker_type == list_style_type_none) return;

        const double w = marker.pos.width.value(), h = marker.pos.height.value();
        if (w <= 0 || h <= 0) return;
        const double cx = marker.pos.x.value() + w / 2;
        const double cy = marker.pos.y.value() + h / 2;
        const double r  = (w < h ? w : h) / 2;

        web_color c = marker.color;
        if (c.alpha == 0) c = web_color(0, 0, 0);

        cairo_save(cr);
        cairo_set_source_rgba(cr, c.red / 255.0, c.green / 255.0, c.blue / 255.0, c.alpha / 255.0);
        switch (marker.marker_type) {
        case list_style_type_circle:
            cairo_set_line_width(cr, 1.0);
            cairo_arc(cr, cx, cy, r - 0.5, 0, 2 * M_PI);
            cairo_stroke(cr);
            break;
        case list_style_type_square:
            cairo_rectangle(cr, cx - r, cy - r, 2 * r, 2 * r);
            cairo_fill(cr);
            break;
        case list_style_type_disc:
        default:
            cairo_arc(cr, cx, cy, r, 0, 2 * M_PI);
            cairo_fill(cr);
            break;
        }
        cairo_restore(cr);
    }

    void load_image(const char* /*src*/, const char* /*base*/, bool /*redraw*/) override {}
    void get_image_size(const char* /*src*/, const char* /*base*/, size& sz) override { sz.width = 0; sz.height = 0; }
    void draw_image(uint_ptr /*hdc*/, const background_layer& /*layer*/, const std::string& /*url*/,
                    const std::string& /*base*/) override {}

    void draw_solid_fill(uint_ptr hdc, const background_layer& layer, const web_color& color) override
    {
        flush_text();                                          // 先落笔缓冲的文本，保持绘制顺序
        auto* cr = cr_of(hdc);
        if (!cr) return;
        // prepass 把「有 box-shadow 的元素」的 background-color 换成哨兵色：
        // 先画阴影，再补回被哨兵替换掉的真实背景色。
        size_t idx = 0;
        if (prepass::sentinel_index(color.red, color.green, color.blue, idx) && idx < m_shadows.size()) {
            const prepass::shadow_spec& s = m_shadows[idx];
            paint_shadow(cr, layer, s);
            web_color bg(static_cast<byte>(s.bg_r), static_cast<byte>(s.bg_g),
                         static_cast<byte>(s.bg_b), static_cast<byte>(s.bg_a));
            if (bg.alpha > 0) layer_fill(cr, layer, bg);
            return;
        }
        layer_fill(cr, layer, color);
    }

    // 颜色点 → cairo pattern 的 stop 列表（litehtml 已把 offset 归一化到 0..1）
    static void add_stops(cairo_pattern_t* p, const background_layer::gradient_base& g)
    {
        for (const auto& cp : g.color_points)
            cairo_pattern_add_color_stop_rgba(p, cp.offset, cp.color.red / 255.0,
                                             cp.color.green / 255.0, cp.color.blue / 255.0,
                                             cp.color.alpha / 255.0);
    }

    // 只有一个颜色点：不是渐变，退化成纯色填充（cairo 单 stop 会整片变终点色）
    static bool stops_flat(const background_layer::gradient_base& g, web_color& out)
    {
        if (g.color_points.size() != 1) return false;
        out = g.color_points[0].color;
        return true;
    }

    // 渐变统一出口：先按背景层裁圆角，再让 setup 造 pattern（可顺手改 CTM），最后填边框盒。
    // setup 返回的 pattern 归本函数销毁；CTM 改动由外层 save/restore 收回。
    template <class Setup>
    void grad_paint(cairo_t* cr, const background_layer& layer, Setup setup)
    {
        cairo_save(cr);
        layer_clip(cr, layer);
        cairo_rectangle(cr, layer.border_box.x, layer.border_box.y, layer.border_box.width,
                        layer.border_box.height);
        cairo_pattern_t* pat = setup();
        if (pat) {
            cairo_set_source(cr, pat);
            cairo_fill(cr);
            cairo_pattern_destroy(pat);
        }
        cairo_restore(cr);
    }

    // t（0..1 沿渐变轴）处的插值颜色，conic 手绘要用
    static web_color stop_at(const std::vector<background_layer::color_point>& cps, double t)
    {
        if (cps.empty()) return web_color(0, 0, 0, 0);
        if (t <= cps.front().offset) return cps.front().color;
        if (t >= cps.back().offset) return cps.back().color;
        for (size_t i = 1; i < cps.size(); ++i) {
            if (t <= cps[i].offset) {
                const auto& a = cps[i - 1];
                const auto& b = cps[i];
                const double span = b.offset - a.offset;
                const double k = span > 1e-6 ? (t - a.offset) / span : 0.0;
                auto lerp = [k](byte lo, byte hi) {
                    return static_cast<byte>(std::lround(lo + (hi - lo) * k));
                };
                return web_color(lerp(a.color.red, b.color.red), lerp(a.color.green, b.color.green),
                                 lerp(a.color.blue, b.color.blue), lerp(a.color.alpha, b.color.alpha));
            }
        }
        return cps.back().color;
    }

    void draw_linear_gradient(uint_ptr hdc, const background_layer& layer,
                              const background_layer::linear_gradient& g) override
    {
        flush_text();
        cairo_t* cr = cr_of(hdc);
        if (!cr || g.color_points.empty()) return;
        web_color flat;
        if (stops_flat(g, flat)) { layer_fill(cr, layer, flat); return; }
        grad_paint(cr, layer, [&]() {
            cairo_pattern_t* p =
                cairo_pattern_create_linear(g.start.x, g.start.y, g.end.x, g.end.y);
            add_stops(p, g);
            return p;
        });
    }

    void draw_radial_gradient(uint_ptr hdc, const background_layer& layer,
                              const background_layer::radial_gradient& g) override
    {
        flush_text();
        cairo_t* cr = cr_of(hdc);
        if (!cr || g.color_points.empty()) return;
        web_color flat;
        if (stops_flat(g, flat)) { layer_fill(cr, layer, flat); return; }
        double rx = g.radius.x, ry = g.radius.y;
        if (rx <= 0) {  // 没给半径（farthest-corner 之类）：用边框盒外接半径兜底
            rx = std::hypot(static_cast<double>(layer.border_box.width),
                            static_cast<double>(layer.border_box.height));
            ry = rx;
        }
        if (ry <= 0) ry = rx;
        grad_paint(cr, layer, [&]() {
            // cairo 只有正圆渐变：把 y 轴压成 ry/rx，再做 1:rx 的正圆
            cairo_translate(cr, g.position.x, g.position.y);
            cairo_scale(cr, 1.0, ry / rx);
            cairo_pattern_t* p = cairo_pattern_create_radial(0, 0, 0, 0, 0, rx);
            add_stops(p, g);
            return p;
        });
    }

    // cairo 没有 conic gradient：按角度切薄扇形手绘。相邻扇形多叠半个步长，
    // 遮住抗锯齿在接缝处漏出的底色（纯色环看不出来，渐变会有细缝）。
    void draw_conic_gradient(uint_ptr hdc, const background_layer& layer,
                             const background_layer::conic_gradient& g) override
    {
        flush_text();
        cairo_t* cr = cr_of(hdc);
        if (!cr || g.color_points.empty()) return;
        web_color flat;
        if (stops_flat(g, flat)) { layer_fill(cr, layer, flat); return; }

        const double cx = g.position.x, cy = g.position.y;
        double radius = g.radius;
        if (radius <= 0) {
            const double bx = layer.border_box.x, by = layer.border_box.y;
            const double bw = layer.border_box.width, bh = layer.border_box.height;
            const double dx = std::max(std::fabs(bx - cx), std::fabs(bx + bw - cx));
            const double dy = std::max(std::fabs(by - cy), std::fabs(by + bh - cy));
            radius = std::hypot(dx, dy) + 1.0;
        }
        const int steps = 360;
        const double step = 2 * M_PI / steps;
        const double start = (g.angle - 90.0) * M_PI / 180.0;  // CSS: 0deg = 正上方，顺时针
        const double over = step * 0.5;

        cairo_save(cr);
        layer_clip(cr, layer);
        for (int i = 0; i < steps; ++i) {
            const web_color c = stop_at(g.color_points, (i + 0.5) / steps);
            cairo_new_path(cr);
            cairo_move_to(cr, cx, cy);
            cairo_arc(cr, cx, cy, radius, start + i * step - over, start + (i + 1) * step + over);
            cairo_close_path(cr);
            set_src(cr, c);
            cairo_fill(cr);
        }
        cairo_restore(cr);
    }

    // litehtml 只算布局，边框像素要这里画；空实现会让所有 border 消失。
    // 有圆角时画「外圆角矩形 − 内圆角矩形」的环（even-odd），并按四条角平分线裁成四边：
    // 这样边框在圆角处是斜接（浏览器行为），而不是四条矩形在角上叠成方块。
    void draw_borders(uint_ptr hdc, const borders& b, const position& pos, bool /*root*/) override
    {
        flush_text();
        cairo_t* cr = cr_of(hdc);
        if (!cr) return;
        const double x = pos.x, y = pos.y, w = pos.width, h = pos.height;
        if (w <= 0 || h <= 0) return;
        const double tw = b.top.width, bt = b.bottom.width, lw = b.left.width, rw = b.right.width;

        auto visible = [](const border& bd) {
            return static_cast<double>(bd.width) > 0 && bd.color.alpha != 0 &&
                   bd.style != border_style_none &&
                   bd.style != border_style_hidden;
        };
        // 直角分支（也是内框退化成负值时的兜底）：四条矩形带
        auto side = [&](const border& bd, double bx, double by, double bw, double bh) {
            if (!visible(bd) || bw <= 0 || bh <= 0) return;
            rect_fill(cr, bd.color, bx, by, bw, bh);
        };
        auto square_sides = [&]() {
            side(b.top,    x, y, w, tw);
            side(b.bottom, x, y + h - bt, w, bt);
            side(b.left,   x, y + tw, lw, h - tw - bt);
            side(b.right,  x + w - rw, y + tw, rw, h - tw - bt);
        };

        radii4 ro = radii_of(b.radius);
        const double ix = x + lw, iy = y + tw, iw = w - lw - rw, ih = h - tw - bt;
        if (radii_is_zero(ro) || iw < 0.5 || ih < 0.5) {
            square_sides();
            return;
        }
        clamp_radii(ro, w, h);
        // 内框半径 = 外半径内缩对应边框宽度，负数夹 0
        radii4 ri = ro;
        auto shrink = [](double& v, double by) { v = (v - by > 0) ? v - by : 0; };
        shrink(ri.tlx, lw); shrink(ri.tly, tw);
        shrink(ri.trx, rw); shrink(ri.try_, tw);
        shrink(ri.brx, rw); shrink(ri.bry, bt);
        shrink(ri.blx, lw); shrink(ri.bly, bt);
        clamp_radii(ri, iw, ih);
        // 内角中心（角平分线的内端）
        const double itlx = ix + ri.tlx, itly = iy + ri.tly;
        const double itrx = ix + iw - ri.trx, itry = iy + ri.try_;
        const double ibrx = ix + iw - ri.brx, ibry = iy + ih - ri.bry;
        const double iblx = ix + ri.blx, ibly = iy + ih - ri.bly;

        struct cutline { double px, py, dx, dy; };
        auto mkcut = [](bool hs, bool vs, double cx, double cy, double nx, double ny) -> cutline {
            if (hs && vs) return cutline{cx, cy, nx - cx, ny - cy};  // 两边都在：斜线
            if (hs) return cutline{cx, cy, 0.0, 1.0};                // 只有横边：竖直线
            return cutline{cx, cy, 1.0, 0.0};                        // 只有竖边：水平线
        };
        const double BIGC = 4.0 * (w + h + 64.0);
        // 取分界线一侧作为半平面；哪一侧由 ref（本边中部一点）决定。
        // 分界线各向外让 EPS：两条边在交界处重叠不到半像素，否则 cairo 的裁剪
        // 抗锯齿让两边各出 ~50% 覆盖，叠成 75% 透出背景，角上留一道浅色细缝。
        const double EPS = 0.75;
        auto clip_half = [&](const cutline& c, double rx, double ry) {
            const double len = std::hypot(c.dx, c.dy);
            if (len < 1e-9) return;
            const double ux = c.dx / len, uy = c.dy / len;
            double nx = -uy, ny = ux;
            if ((rx - c.px) * nx + (ry - c.py) * ny < 0) { nx = -nx; ny = -ny; }
            const double px = c.px - nx * EPS, py = c.py - ny * EPS;
            const double ax = px - ux * BIGC, ay = py - uy * BIGC;
            const double bx = px + ux * BIGC, by = py + uy * BIGC;
            cairo_new_path(cr);
            cairo_move_to(cr, ax, ay);
            cairo_line_to(cr, bx, by);
            cairo_line_to(cr, bx + nx * BIGC, by + ny * BIGC);
            cairo_line_to(cr, ax + nx * BIGC, ay + ny * BIGC);
            cairo_close_path(cr);
            cairo_clip(cr);
        };
        auto ring_side = [&](const border& bd, const cutline& c1, const cutline& c2,
                             double rx, double ry) {
            if (!visible(bd)) return;
            cairo_save(cr);
            cairo_new_path(cr);
            clip_half(c1, rx, ry);
            clip_half(c2, rx, ry);
            cairo_new_path(cr);
            rounded_rect_path(cr, x, y, w, h, ro);
            rounded_rect_path(cr, ix, iy, iw, ih, ri);
            cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
            set_src(cr, bd.color);
            cairo_fill(cr);
            cairo_restore(cr);
        };

        // 每个角的分界线：外框点 o + 内框点 n。相邻边不可见时，本侧接管整个圆角
        // 区域（CSS 的行为），分界线退到相邻边所在的边线上——否则 `border-left` 单
        // 边配圆角时弧段没人画，四个角会露出白色缺口。
        const bool tv = visible(b.top), bv = visible(b.bottom);
        const bool lv = visible(b.left), rv = visible(b.right);
        const cutline ctl = mkcut(tv, lv, x, y, itlx, itly);
        const cutline ctr = mkcut(tv, rv, x + w, y, itrx, itry);
        const cutline cbr = mkcut(bv, rv, x + w, y + h, ibrx, ibry);
        const cutline cbl = mkcut(bv, lv, x, y + h, iblx, ibly);

        ring_side(b.top,    ctl, ctr, x + w * 0.5, y + tw * 0.5);
        ring_side(b.right,  ctr, cbr, x + w - rw * 0.5, y + h * 0.5);
        ring_side(b.bottom, cbr, cbl, x + w * 0.5, y + h - bt * 0.5);
        ring_side(b.left,   cbl, ctl, x + lw * 0.5, y + h * 0.5);
    }

    void set_caption(const char* /*c*/) override {}
    void set_base_url(const char* base) override { if (base) m_base_url = base; }
    void link(const std::shared_ptr<document>& /*doc*/, const element::ptr& /*el*/) override {}
    void on_anchor_click(const char* /*url*/, const element::ptr& /*el*/) override {}
    void on_mouse_event(const element::ptr& /*el*/, mouse_event /*ev*/) override {}
    void set_cursor(const char* /*cursor*/) override {}

    void transform_text(std::string& /*text*/, text_transform /*tt*/) override {}
    void import_css(std::string& /*text*/, const std::string& /*url*/, std::string& /*base*/) override {}

    void set_clip(const position& pos, const border_radiuses& r) override
    {
        // hdc 在 draw 前由调用方压栈；这里用全局当前 cr（单线程渲染）
        if (!g_cr) return;
        flush_text();                                          // 用旧 clip 落笔再压新 clip
        cairo_save(g_cr);
        const radii4 rr = radii_of(r);
        if (radii_is_zero(rr)) {
            cairo_rectangle(g_cr, pos.x, pos.y, pos.width, pos.height);
        } else {
            // overflow:hidden 的圆角裁剪：矩形会留下四个方形角，让子元素从圆角外露出来
            rounded_rect_path(g_cr, pos.x, pos.y, pos.width, pos.height, rr);
        }
        cairo_clip(g_cr);
        ++m_clip_depth;
        m_clip_right.push_back(static_cast<double>(pos.x) + static_cast<double>(pos.width));
    }

    void del_clip() override
    {
        if (!g_cr || m_clip_depth <= 0) return;
        flush_text();                                          // 先落笔再弹 clip
        cairo_restore(g_cr);
        --m_clip_depth;
        if (!m_clip_right.empty()) m_clip_right.pop_back();
    }

    void get_viewport(position& vp) const override { vp.x = 0; vp.y = 0; vp.width = m_width; vp.height = m_height; }

    element::ptr create_element(const char* /*tag*/, const string_map& /*attrs*/,
                                const std::shared_ptr<document>& /*doc*/) override { return nullptr; }

    void get_media_features(media_features& media) const override
    {
        media.type = media_type_screen;
        media.width = m_width;
        media.height = m_height;
        media.device_width = m_width;
        media.device_height = m_height;
        media.color = 8;
        media.color_index = 256;
        media.monochrome = 0;
        media.resolution = 96;
    }

    void get_language(std::string& language, std::string& culture) const override
    {
        language = "zh";
        culture = "CN";
    }

    static cairo_t* g_cr;
};

cairo_t* cairo_container::g_cr = nullptr;

} // namespace

extern "C" {

const char* lite_html_error(void) { return g_error.c_str(); }

// 返回 0 成功；非 0 失败（错误串见 lite_html_error）
int lite_html_render(const char* html, const char* out_png, int w, int h, double scale)
{
    g_error.clear();
    if (!html || !out_png) { g_error = "html/out_png is null"; return 1; }
    // h <= 0 表示自动测高：先按 w 布局，出图高度 = 内容实际高度（不裁剪、不留空白）
    if (w <= 0 || h < 0) { g_error = "invalid size"; return 2; }
    if (scale <= 0) scale = 1.0;

    // 项目自带字体（helper/assets）：cairo toy font 只认族名，靠 fontconfig 兜底。
    // 进程级注册一次即可；LITE_HTML_FONT_DIR 可覆盖目录。
    static bool fc_fonts_loaded = false;
    if (!fc_fonts_loaded) {
        fc_fonts_loaded = true;
        const char* fdir = getenv("LITE_HTML_FONT_DIR");
        if (!fdir || !*fdir) fdir = "helper/assets";
        FcConfig* cfg = FcConfigGetCurrent();
        const char* fnames[] = { "DroidSansFallbackFull.ttf", "DejaVuSansMono.ttf" };
        for (const char* fn : fnames) {
            std::string fp = std::string(fdir) + "/" + fn;
            if (FcConfigAppFontAddFile(cfg, (const FcChar8*)fp.c_str()))
                FcConfigBuildFonts(cfg);
        }
    }

    cairo_container container;
    container.m_width  = w;
    // 自动测高时先用一个足够大的视口布局：m_height 是媒体/DOM 视口高度，
    // 给 0 会让 litehtml 按 0 高视口算，content_h 偏小、最后几行被裁掉。
    container.m_height = (h > 0) ? h : 100000;

    document::ptr doc;
    // litehtml 本身不认 opacity / box-shadow / transform:translate：先改写成它认识的形式
    // （见 src/html/prepass.cpp）。aliasing 只在这里做一次，渲染期只认哨兵色。
    std::string pre_html = prepass::rewrite(html, container.m_shadows);
    try {
        doc = document::createFromString(pre_html.c_str(), &container, master_css, "");
    } catch (const std::exception& e) {
        g_error = std::string("createFromString: ") + e.what();
        return 3;
    } catch (...) {
        g_error = "createFromString failed";
        return 3;
    }
    if (!doc) { g_error = "createFromString returned null"; return 3; }

    // 注意：document::render() 的返回值不是内容高度（render_item 的返回值），
    // 文档真实高度在 m_size 里，要靠 doc->height() 取 —— 否则自动测高恒等于视口高。
    pixel_t content_h = 0;
    try {
        doc->render(w);
        content_h = doc->height();
    } catch (...) {
        g_error = "layout failed";
        return 4;
    }
    if (h <= 0) {
        int auto_h = static_cast<int>(std::ceil(content_h.value()));
        h = auto_h > 0 ? auto_h : 800;
    }
    container.m_height = h;   // 出图按最终高度，clip/draw 都对齐
    if (content_h.value() <= 0) content_h = pixel_t(static_cast<float>(h));

    cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                          static_cast<int>(w * scale),
                                                          static_cast<int>(h * scale));
    cairo_t* cr = cairo_create(surface);
    cairo_scale(cr, scale, scale);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);

    cairo_container::g_cr = cr;
    position clip(0, 0, w, h);
    try {
        doc->draw(reinterpret_cast<uint_ptr>(cr), 0, 0, &clip);
        container.flush_text();                            // 最后一行落笔
        while (container.m_clip_depth > 0) { cairo_restore(cr); --container.m_clip_depth; }
        container.m_clip_right.clear();
    } catch (...) {
        cairo_container::g_cr = nullptr;
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        g_error = "draw failed";
        return 5;
    }
    cairo_container::g_cr = nullptr;

    cairo_status_t st = cairo_surface_write_to_png(surface, out_png);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    if (st != CAIRO_STATUS_SUCCESS) {
        g_error = std::string("png write: ") + cairo_status_to_string(st);
        return 6;
    }
    return 0;
}

} // extern "C"
