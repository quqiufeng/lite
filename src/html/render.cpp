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
#include <cmath>
#include <string>
#include <vector>
#include <map>
#include <memory>

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

void rect_fill(cairo_t* cr, const web_color& c, double x, double y, double w, double h)
{
    if (!cr || w <= 0 || h <= 0) return;
    cairo_set_source_rgba(cr, c.red / 255.0, c.green / 255.0, c.blue / 255.0, c.alpha / 255.0);
    cairo_rectangle(cr, x, y, w, h);
    cairo_fill(cr);
}

void clip_fill(cairo_t* cr, const web_color& c)
{
    double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    cairo_clip_extents(cr, &x1, &y1, &x2, &y2);
    rect_fill(cr, c, x1, y1, x2 - x1, y2 - y1);
}

// 按 background_layer 的 border_box 填充（litehtml 要求一切画在 border_box 内）
void layer_fill(cairo_t* cr, const background_layer& layer, const web_color& c)
{
    if (!cr) return;
    cairo_save(cr);
    cairo_rectangle(cr, layer.clip_box.x, layer.clip_box.y, layer.clip_box.width, layer.clip_box.height);
    cairo_clip(cr);
    rect_fill(cr, c, layer.border_box.x, layer.border_box.y, layer.border_box.width, layer.border_box.height);
    cairo_restore(cr);
}

class cairo_container : public document_container
{
public:
    std::map<std::string, font_entry*> m_fonts;
    int m_clip_depth = 0;
    int m_n_text = 0, m_n_fill = 0, m_n_clip = 0;
    int m_width  = 800;
    int m_height = 600;
    std::string m_base_url;
    std::string m_font_name = "Sans";

    ~cairo_container() override
    {
        for (auto& kv : m_fonts) {
            if (kv.second) {
                if (kv.second->sf) cairo_scaled_font_destroy(kv.second->sf);
                delete kv.second;
            }
        }
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
        cairo_surface_t* scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        cairo_t* tmp = cairo_create(scratch);
        cairo_select_font_face(tmp, fe->family.c_str(), (cairo_font_slant_t)fe->slant,
                               (cairo_font_weight_t)fe->weight);
        cairo_set_font_size(tmp, fe->size);
        cairo_text_extents_t te;
        cairo_text_extents(tmp, text, &te);
        cairo_destroy(tmp);
        cairo_surface_destroy(scratch);
        return pixel_t(static_cast<float>(std::ceil(te.x_advance)));
    }

    void draw_text(uint_ptr hdc, const char* text, uint_ptr hFont, web_color color,
                   const position& pos) override
    {
        auto* cr = cr_of(hdc);
        auto* fe = fe_of(hFont);
        if (!cr || !fe || !text) return;
        cairo_save(cr);
        cairo_select_font_face(cr, fe->family.c_str(), (cairo_font_slant_t)fe->slant,
                               (cairo_font_weight_t)fe->weight);
        cairo_set_font_size(cr, fe->size);
        cairo_set_source_rgba(cr, color.red / 255.0, color.green / 255.0, color.blue / 255.0,
                              color.alpha / 255.0);
        cairo_move_to(cr, pos.x.value(), static_cast<double>(pos.y.value()) + fe->ascent);
        cairo_show_text(cr, text);
        cairo_restore(cr);
    }

    pixel_t pt_to_px(float pt) const override { return static_cast<pixel_t>(pt * 1.3333f); }
    pixel_t get_default_font_size() const override { return 14; }
    const char* get_default_font_name() const override { return m_font_name.c_str(); }

    void draw_list_marker(uint_ptr hdc, const list_marker& /*marker*/) override
    {
        auto* cr = cr_of(hdc);
        if (!cr) return;
        clip_fill(cr, web_color(0, 0, 0));
    }

    void load_image(const char* /*src*/, const char* /*base*/, bool /*redraw*/) override {}
    void get_image_size(const char* /*src*/, const char* /*base*/, size& sz) override { sz.width = 0; sz.height = 0; }
    void draw_image(uint_ptr /*hdc*/, const background_layer& /*layer*/, const std::string& /*url*/,
                    const std::string& /*base*/) override {}

    void draw_solid_fill(uint_ptr hdc, const background_layer& layer, const web_color& color) override
    {
        auto* cr = cr_of(hdc);
        if (cr) layer_fill(cr, layer, color);
    }

    void draw_linear_gradient(uint_ptr /*hdc*/, const background_layer& /*layer*/, const background_layer::linear_gradient& /*img*/) override {}
    void draw_radial_gradient(uint_ptr /*hdc*/, const background_layer& /*layer*/, const background_layer::radial_gradient& /*g*/) override {}
    void draw_conic_gradient(uint_ptr /*hdc*/, const background_layer& /*layer*/, const background_layer::conic_gradient& /*g*/) override {}

    // litehtml 只算布局，边框像素要这里画；空实现会让所有 border 消失。
    void draw_borders(uint_ptr hdc, const borders& b, const position& pos, bool /*root*/) override
    {
        cairo_t* cr = cr_of(hdc);
        if (!cr) return;
        const double x = pos.x, y = pos.y, w = pos.width, h = pos.height;
        auto side = [&](const border& bd, double bx, double by, double bw, double bh) {
            const double wd = bd.width;
            if (wd <= 0 || bh <= 0 || bw <= 0) return;
            if (bd.style == border_style_none || bd.style == border_style_hidden) return;
            if (bd.color.alpha == 0) return;
            rect_fill(cr, bd.color, bx, by, bw, bh);
        };
        const double tw = b.top.width, bt = b.bottom.width, lw = b.left.width, rw = b.right.width;
        side(b.top,    x, y, w, tw);
        side(b.bottom, x, y + h - bt, w, bt);
        side(b.left,   x, y + tw, lw, h - tw - bt);
        side(b.right,  x + w - rw, y + tw, rw, h - tw - bt);
    }

    void set_caption(const char* /*c*/) override {}
    void set_base_url(const char* base) override { if (base) m_base_url = base; }
    void link(const std::shared_ptr<document>& /*doc*/, const element::ptr& /*el*/) override {}
    void on_anchor_click(const char* /*url*/, const element::ptr& /*el*/) override {}
    void on_mouse_event(const element::ptr& /*el*/, mouse_event /*ev*/) override {}
    void set_cursor(const char* /*cursor*/) override {}

    void transform_text(std::string& /*text*/, text_transform /*tt*/) override {}
    void import_css(std::string& /*text*/, const std::string& /*url*/, std::string& /*base*/) override {}

    void set_clip(const position& pos, const border_radiuses& /*r*/) override
    {
        // hdc 在 draw 前由调用方压栈；这里用全局当前 cr（单线程渲染）
        if (!g_cr) return;
        cairo_save(g_cr);
        cairo_rectangle(g_cr, pos.x, pos.y, pos.width, pos.height);
        cairo_clip(g_cr);
        ++m_clip_depth;
    }

    void del_clip() override
    {
        if (!g_cr || m_clip_depth <= 0) return;
        cairo_restore(g_cr);
        --m_clip_depth;
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
    if (w <= 0 || h <= 0) { g_error = "invalid size"; return 2; }
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
    container.m_height = h;

    document::ptr doc;
    try {
        doc = document::createFromString(html, &container, master_css, "");
    } catch (const std::exception& e) {
        g_error = std::string("createFromString: ") + e.what();
        return 3;
    } catch (...) {
        g_error = "createFromString failed";
        return 3;
    }
    if (!doc) { g_error = "createFromString returned null"; return 3; }

    pixel_t content_h = 0;
    try {
        content_h = doc->render(w);
    } catch (...) {
        g_error = "layout failed";
        return 4;
    }
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
        while (container.m_clip_depth > 0) { cairo_restore(cr); --container.m_clip_depth; }
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
