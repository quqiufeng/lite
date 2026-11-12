// src/html/prepass.cpp — 见 prepass.h 的设计说明。
#include "prepass.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace prepass {
namespace {

struct rgba
{
    double r = 0, g = 0, b = 0, a = 255;
};

std::string lower(std::string s)
{
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string trim(const std::string& s)
{
    size_t b = 0, e = s.size();
    while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return s.substr(b, e - b);
}

bool starts_at(const std::string& s, size_t i, const char* lit)
{
    const size_t n = std::strlen(lit);
    if (i + n > s.size()) return false;
    for (size_t k = 0; k < n; ++k)
        if (std::tolower(static_cast<unsigned char>(s[i + k])) != lit[k]) return false;
    return true;
}

int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

struct named_color
{
    const char* name;
    int         r, g, b;
};

const named_color kNamed[] = {
    { "black", 0, 0, 0 },        { "silver", 192, 192, 192 },  { "gray", 128, 128, 128 },
    { "grey", 128, 128, 128 },   { "white", 255, 255, 255 },   { "maroon", 128, 0, 0 },
    { "red", 255, 0, 0 },        { "purple", 128, 0, 128 },    { "fuchsia", 255, 0, 255 },
    { "magenta", 255, 0, 255 },  { "green", 0, 128, 0 },       { "lime", 0, 255, 0 },
    { "olive", 128, 128, 0 },    { "yellow", 255, 255, 0 },    { "navy", 0, 0, 128 },
    { "blue", 0, 0, 255 },       { "teal", 0, 128, 128 },      { "aqua", 0, 255, 255 },
    { "cyan", 0, 255, 255 },     { "orange", 255, 165, 0 },    { "pink", 255, 192, 203 },
    { "gold", 255, 215, 0 },     { "brown", 165, 42, 42 },     { "whitesmoke", 245, 245, 245 },
    { "gainsboro", 220, 220, 220 }, { "darkgray", 169, 169, 169 },
    { "darkgrey", 169, 169, 169 },  { "lightgray", 211, 211, 211 },
    { "lightgrey", 211, 211, 211 }, { "dimgray", 105, 105, 105 },
    { "dimgrey", 105, 105, 105 },   { "slategray", 112, 128, 144 },
    { "slategrey", 112, 128, 144 }, { "rebeccapurple", 102, 51, 153 },
    { "beige", 245, 245, 220 },     { "ivory", 255, 255, 240 },
    { "seashell", 255, 245, 238 },  { "linen", 250, 240, 230 },
    { "antiquewhite", 250, 235, 215 },
};

double parse_number(const std::string& s, bool& ok)
{
    ok = false;
    if (s.empty()) return 0;
    char*            end = nullptr;
    const double     v   = std::strtod(s.c_str(), &end);
    if (end && *end == '\0') ok = true;
    return v;
}

// 一个颜色分量：支持 0..255 数字与百分比
double color_comp(const std::string& s, bool& ok)
{
    ok = false;
    std::string t = trim(s);
    if (t.empty()) return 0;
    if (t.back() == '%')
    {
        bool         okn = false;
        const double p   = parse_number(t.substr(0, t.size() - 1), okn);
        if (!okn) return 0;
        ok = true;
        return p * 255.0 / 100.0;
    }
    const double v = parse_number(t, ok);
    return v;
}

double color_alpha(const std::string& s, bool& ok)
{
    ok = false;
    std::string t = trim(s);
    if (t.empty()) return 255;
    if (t.back() == '%')
    {
        bool         okn = false;
        const double p   = parse_number(t.substr(0, t.size() - 1), okn);
        if (!okn) return 255;
        ok = true;
        return p * 255.0 / 100.0;
    }
    const double v = parse_number(t, ok);
    if (!ok) return 255;
    return v <= 1.0 ? v * 255.0 : v;   // CSS 语义是 0..1；>1 按 0..255 兜底
}

bool parse_color(const std::string& in, rgba& out)
{
    const std::string s = lower(trim(in));
    if (s.empty()) return false;
    if (s == "transparent")
    {
        out = rgba{ 0, 0, 0, 0 };
        return true;
    }
    if (s[0] == '#')
    {
        const std::string h = s.substr(1);
        if (h.size() != 3 && h.size() != 4 && h.size() != 6 && h.size() != 8) return false;
        int v[8];
        for (size_t i = 0; i < h.size(); ++i)
        {
            v[i] = hexval(h[i]);
            if (v[i] < 0) return false;
        }
        if (h.size() <= 4)
        {
            out.r = v[0] * 17;
            out.g = v[1] * 17;
            out.b = v[2] * 17;
            out.a = h.size() == 4 ? v[3] * 17 : 255;
        }
        else
        {
            out.r = v[0] * 16 + v[1];
            out.g = v[2] * 16 + v[3];
            out.b = v[4] * 16 + v[5];
            out.a = h.size() == 8 ? v[6] * 16 + v[7] : 255;
        }
        return true;
    }
    for (const auto& n : kNamed)
        if (s == n.name)
        {
            out = rgba{ static_cast<double>(n.r), static_cast<double>(n.g),
                        static_cast<double>(n.b), 255 };
            return true;
        }
    const bool is_rgb  = starts_at(s, 0, "rgb(") || starts_at(s, 0, "rgba(");
    const bool is_hsl  = starts_at(s, 0, "hsl(") || starts_at(s, 0, "hsla(");
    if (!is_rgb && !is_hsl) return false;
    const size_t lp = s.find('(');
    const size_t rp = s.rfind(')');
    if (lp == std::string::npos || rp == std::string::npos || rp < lp) return false;
    std::string inner = s.substr(lp + 1, rp - lp - 1);
    for (auto& c : inner)
        if (c == '/' || c == ',') c = ' ';
    std::vector<std::string> parts;
    {
        std::string cur;
        for (char c : inner)
        {
            if (std::isspace(static_cast<unsigned char>(c)))
            {
                if (!cur.empty()) { parts.push_back(cur); cur.clear(); }
            }
            else
                cur.push_back(c);
        }
        if (!cur.empty()) parts.push_back(cur);
    }
    if (parts.size() < 3 || parts.size() > 4) return false;
    if (is_rgb)
    {
        bool ok1 = false, ok2 = false, ok3 = false;
        out.r = color_comp(parts[0], ok1);
        out.g = color_comp(parts[1], ok2);
        out.b = color_comp(parts[2], ok3);
        if (!ok1 || !ok2 || !ok3) return false;
    }
    else
    {
        // hsl：只做旋转近似不值得，直接放弃（保留原样，opacity 对它不生效）
        return false;
    }
    if (parts.size() == 4)
    {
        bool ok = false;
        out.a   = color_alpha(parts[3], ok);
        if (!ok) return false;
    }
    else
        out.a = 255;
    auto clamp255 = [](double v) { return v < 0 ? 0.0 : (v > 255 ? 255.0 : v); };
    out.r         = clamp255(out.r);
    out.g         = clamp255(out.g);
    out.b         = clamp255(out.b);
    out.a         = clamp255(out.a);
    return true;
}

std::string fmt_color(const rgba& c)
{
    char buf[96];
    std::snprintf(buf, sizeof(buf), "rgba(%d,%d,%d,%.3f)", static_cast<int>(std::lround(c.r)),
                  static_cast<int>(std::lround(c.g)), static_cast<int>(std::lround(c.b)),
                  c.a / 255.0);
    return buf;
}

// 在 value 里把每个颜色字面量（#hex / rgb() / rgba()）的 alpha 乘 mul
std::string scale_colors(const std::string& v, double mul)
{
    std::string out;
    out.reserve(v.size() + 32);
    for (size_t i = 0; i < v.size();)
    {
        const char c = v[i];
        if (c == '#')
        {
            size_t j = i + 1;
            while (j < v.size() && hexval(v[j]) >= 0) ++j;
            const size_t n = j - i - 1;
            if (n == 3 || n == 4 || n == 6 || n == 8)
            {
                rgba col;
                if (parse_color(v.substr(i, j - i), col))
                {
                    col.a *= mul;
                    out += fmt_color(col);
                    i = j;
                    continue;
                }
            }
            out.push_back(c);
            ++i;
            continue;
        }
        if ((c == 'r' || c == 'R') && (starts_at(v, i, "rgb(") || starts_at(v, i, "rgba(")))
        {
            const size_t lp = v.find('(', i);
            size_t       depth = 0, j = lp;
            for (; j < v.size(); ++j)
            {
                if (v[j] == '(') ++depth;
                else if (v[j] == ')')
                {
                    if (--depth == 0) { ++j; break; }
                }
            }
            rgba col;
            if (parse_color(v.substr(i, j - i), col))
            {
                col.a *= mul;
                out += fmt_color(col);
                i = j;
                continue;
            }
        }
        out.push_back(c);
        ++i;
    }
    return out;
}

// 整个 value 就是一个颜色（含裸色名）时，整体改写
bool scale_whole_color(const std::string& v, double mul, std::string& out)
{
    rgba col;
    if (!parse_color(v, col)) return false;
    col.a *= mul;
    out = fmt_color(col);
    return true;
}

bool is_color_prop(const std::string& n)
{
    if (n == "color" || n == "background-color" || n == "border-color" || n == "outline-color" ||
        n == "text-decoration-color" || n == "caret-color" || n == "column-rule-color")
        return true;
    static const char* sides[] = { "border-top-color", "border-right-color", "border-bottom-color",
                                   "border-left-color", "border-block-color", "border-inline-color" };
    for (const char* s : sides)
        if (n == s) return true;
    return false;
}

bool has_gradient(const std::string& v)
{
    const std::string l = lower(v);
    return l.find("gradient(") != std::string::npos;
}

struct decl
{
    std::string name, value;
    bool        drop = false;
};

// 按空白切 token（括号内的空白不算）
std::vector<std::string> split_tokens(const std::string& v)
{
    std::vector<std::string> out;
    std::string              cur;
    int                      depth = 0;
    for (char c : v)
    {
        if (c == '(') ++depth;
        if (c == ')') --depth;
        if (std::isspace(static_cast<unsigned char>(c)) && depth <= 0)
        {
            if (!cur.empty())
            {
                out.push_back(cur);
                cur.clear();
            }
        }
        else
            cur.push_back(c);
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

// 按 ; 切声明（括号/引号内的 ; 不算）
std::vector<decl> split_decls(const std::string& body)
{
    std::vector<decl> out;
    std::string       cur;
    int               depth = 0;
    char              quote = 0;
    for (char c : body)
    {
        if (quote)
        {
            cur.push_back(c);
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' || c == '"') { quote = c; cur.push_back(c); continue; }
        if (c == '(') ++depth;
        if (c == ')') --depth;
        if (c == ';' && depth <= 0)
        {
            if (!trim(cur).empty()) out.push_back({ "", trim(cur), false });
            cur.clear();
            continue;
        }
        cur.push_back(c);
    }
    if (!trim(cur).empty()) out.push_back({ "", trim(cur), false });
    for (auto& d : out)
    {
        const size_t colon = d.value.find(':');
        if (colon == std::string::npos)
        {
            d.name  = lower(trim(d.value));
            d.value = "";
        }
        else
        {
            d.name  = lower(trim(d.value.substr(0, colon)));
            d.value = trim(d.value.substr(colon + 1));
        }
    }
    return out;
}

// 长度值 → px；无法确定时 ok=false
bool length_px(const std::string& s, double& out)
{
    std::string t = trim(lower(s));
    if (t.empty()) return false;
    if (t == "0") { out = 0; return true; }
    size_t unit = 0;
    while (unit < t.size() && (std::isdigit(static_cast<unsigned char>(t[unit])) || t[unit] == '.' ||
                               t[unit] == '-' || t[unit] == '+'))
        ++unit;
    if (unit == 0) return false;
    bool         okn = false;
    const double v   = parse_number(t.substr(0, unit), okn);
    if (!okn) return false;
    const std::string u = t.substr(unit);
    if (u == "px" || u.empty()) { out = v; return true; }
    if (u == "em" || u == "rem") { out = v * 16.0; return true; }
    if (u == "pt") { out = v * 1.3333; return true; }
    return false;
}

// box-shadow → spec。只取第一条非 inset 的阴影；颜色缺省时（currentColor）放弃。
bool parse_shadow(const std::string& raw, shadow_spec& sp, double alpha_mul)
{
    // 逗号深度切开，只取第一条
    std::string first;
    {
        int depth = 0;
        for (char c : raw)
        {
            if (c == '(') ++depth;
            if (c == ')') --depth;
            if (c == ',' && depth <= 0) break;
            first.push_back(c);
        }
    }
    const std::string l = lower(first);
    if (l.find("inset") != std::string::npos) return false;

    const std::vector<std::string> toks = split_tokens(first);
    std::vector<double>            lens;
    rgba                col;
    bool                has_col = false;
    for (const auto& t : toks)
    {
        double v = 0;
        if (length_px(t, v)) { lens.push_back(v); continue; }
        rgba c;
        if (parse_color(t, c)) { col = c; has_col = true; continue; }
        return false;   // 未知 token（含 var()）放弃
    }
    if (lens.size() < 2 || !has_col) return false;
    sp.dx     = lens[0];
    sp.dy     = lens[1];
    sp.blur   = lens.size() > 2 ? std::max(0.0, lens[2]) : 0.0;
    sp.spread = lens.size() > 3 ? lens[3] : 0.0;
    sp.r      = static_cast<int>(std::lround(col.r));
    sp.g      = static_cast<int>(std::lround(col.g));
    sp.b      = static_cast<int>(std::lround(col.b));
    sp.a      = static_cast<int>(std::lround(col.a * alpha_mul));
    if (sp.a <= 0) return false;
    return true;
}

// transform: translate(x[, y]) / translateX / translateY → 返回是否有可用位移
bool parse_translate(const std::string& raw, double& dx, double& dy)
{
    dx = dy = 0;
    const std::string l = lower(trim(raw));
    if (l.empty() || l.find("rotate") != std::string::npos ||
        l.find("scale") != std::string::npos || l.find("matrix") != std::string::npos ||
        l.find("skew") != std::string::npos || l.find("perspective") != std::string::npos)
        return false;
    bool any = false;
    size_t i = 0;
    while (i < l.size())
    {
        const size_t p = l.find("translate", i);
        if (p == std::string::npos) break;
        size_t j = p + 9;
        bool   is_x = false, is_y = false;
        if (j < l.size() && l[j] == 'x') { is_x = true; ++j; }
        else if (j < l.size() && l[j] == 'y')
        {
            is_y = true;
            ++j;
        }
        else if (j < l.size() && l[j] == 'z')
        {
            return false;
        }
        if (j < l.size() && l[j] == '3' && !is_x && !is_y) return false;
        if (j >= l.size() || l[j] != '(') { i = p + 9; continue; }
        const size_t rp = l.find(')', j);
        if (rp == std::string::npos) return false;
        const std::string inner = l.substr(j + 1, rp - j - 1);
        std::string       a     = inner, b;
        const size_t      comma = inner.find(',');
        if (comma != std::string::npos)
        {
            a = inner.substr(0, comma);
            b = inner.substr(comma + 1);
        }
        double vx = 0, vy = 0;
        if (is_y)
        {
            if (!length_px(a, vy)) return false;
        }
        else if (is_x)
        {
            if (!length_px(a, vx)) return false;
        }
        else
        {
            if (!length_px(a, vx)) return false;
            if (!b.empty() && !length_px(b, vy)) return false;
        }
        dx += vx;
        dy += vy;
        any = true;
        i = rp + 1;
    }
    return any;
}

std::string rewrite_decls(const std::string& body, std::vector<shadow_spec>& shadows);

// 找 in[i] == '{' 的配对 '}'；返回其下标，找不到返回 npos
size_t match_brace(const std::string& in, size_t open)
{
    int  depth = 0;
    char quote = 0;
    for (size_t i = open; i < in.size(); ++i)
    {
        const char c = in[i];
        if (quote)
        {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' || c == '"') { quote = c; continue; }
        if (c == '{') ++depth;
        else if (c == '}')
        {
            if (--depth == 0) return i;
        }
    }
    return std::string::npos;
}

std::string rewrite_css(const std::string& css, std::vector<shadow_spec>& shadows)
{
    std::string out;
    out.reserve(css.size() + 64);
    size_t i = 0;
    while (i < css.size())
    {
        const size_t open = css.find('{', i);
        if (open == std::string::npos)
        {
            out += css.substr(i);
            break;
        }
        out += css.substr(i, open - i + 1);
        const size_t close = match_brace(css, open);
        if (close == std::string::npos)
        {
            out += css.substr(open + 1);
            break;
        }
        const std::string body = css.substr(open + 1, close - open - 1);
        if (body.find('{') != std::string::npos)
            out += rewrite_css(body, shadows);   // @media / @supports：递归
        else
            out += rewrite_decls(body, shadows);
        out.push_back('}');
        i = close + 1;
    }
    return out;
}

std::string rewrite_decls(const std::string& body, std::vector<shadow_spec>& shadows)
{
    std::vector<decl> ds = split_decls(body);

    double      opacity = 1.0;
    bool        has_opacity = false;
    std::string transform;
    bool        has_transform = false;
    std::string shadow;
    bool        has_shadow = false;
    bool        abs_pos    = false;
    bool        has_position = false;
    std::string bg_decl;          // background-color 的原值（若有）
    bool        bg_solid   = false;
    bool        bg_image   = false;   // 有 background-image 或渐变：哨兵会盖掉它

    for (const auto& d : ds)
    {
        if (d.name == "opacity")
        {
            bool         ok = false;
            const double v  = parse_number(trim(d.value), ok);
            if (ok)
            {
                opacity     = v < 0 ? 0 : (v > 1 ? 1 : v);
                has_opacity = true;
            }
        }
        else if (d.name == "transform") { transform = d.value; has_transform = true; }
        else if (d.name == "box-shadow") { shadow = d.value; has_shadow = true; }
        else if (d.name == "position")
        {
            has_position   = true;
            const std::string l = lower(trim(d.value));
            abs_pos = (l == "absolute" || l == "fixed" || l == "sticky");
        }
        else if (d.name == "background-color" && !bg_solid)
        {
            rgba c;
            if (parse_color(d.value, c))
            {
                bg_decl  = d.value;
                bg_solid = true;
            }
        }
        else if (d.name == "background")
        {
            if (has_gradient(d.value)) bg_image = true;
            else if (!bg_solid)
            {
                rgba c;
                if (parse_color(d.value, c))
                {
                    bg_decl  = d.value;
                    bg_solid = true;
                }
                else
                {
                    // 简写里夹着裸色名（background: white no-repeat 之类）：逐 token 试颜色
                    for (const auto& tk : split_tokens(d.value))
                    {
                        rgba tc;
                        if (parse_color(tk, tc))
                        {
                            bg_decl  = tk;
                            bg_solid = true;
                            break;
                        }
                    }
                }
            }
        }
        else if (d.name == "background-image")
        {
            if (lower(d.value) != "none") bg_image = true;
        }
    }

    const double mul        = (has_opacity && opacity < 1.0) ? opacity : 1.0;
    bool         need_sentinel = false;
    size_t       shadow_idx    = 0;

    if (has_shadow)
    {
        shadow_spec sp;
        if (parse_shadow(shadow, sp, mul))
        {
            // 触发点只能是纯色背景层：把 background-color 换成哨兵色
            rgba bg;
            bool bg_ok = bg_solid && parse_color(bg_decl, bg);
            if (bg_ok && !bg_image && shadows.size() < 254)
            {
                if (mul < 0.999) bg.a *= mul;
                sp.bg_r = static_cast<int>(std::lround(bg.r));
                sp.bg_g = static_cast<int>(std::lround(bg.g));
                sp.bg_b = static_cast<int>(std::lround(bg.b));
                sp.bg_a = static_cast<int>(std::lround(bg.a));
                shadow_idx    = shadows.size();
                need_sentinel = true;
                shadows.push_back(sp);
            }
        }
    }

    double tdx = 0, tdy = 0;
    bool   translate_ok = has_transform && parse_translate(transform, tdx, tdy);

    std::string out;
    for (auto& d : ds)
    {
        if (d.name == "opacity" || d.name == "transform" || d.name == "box-shadow") continue;
        if (need_sentinel && (d.name == "background-color")) continue;
        std::string value = d.value;
        if (mul < 0.999)
        {
            if (is_color_prop(d.name))
            {
                std::string scaled;
                if (scale_whole_color(value, mul, scaled)) value = scaled;
                else if (value.find("var(") == std::string::npos)
                    value = scale_colors(value, mul);
            }
            else if (d.name == "background" || d.name == "background-image" ||
                     d.name == "border" || d.name == "border-top" || d.name == "border-right" ||
                     d.name == "border-bottom" || d.name == "border-left" || d.name == "outline" ||
                     d.name == "text-decoration" || d.name == "text-shadow" ||
                     d.name == "border-image")
            {
                if (value.find("var(") == std::string::npos) value = scale_colors(value, mul);
            }
        }
        out += d.name + ":" + value + ";";
    }

    if (need_sentinel)
    {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "background-color:rgb(254,1,%d);",
                      static_cast<int>(shadow_idx + 1));
        out += buf;
    }
    if (translate_ok && !abs_pos && (std::fabs(tdx) > 0.01 || std::fabs(tdy) > 0.01))
    {
        char buf[96];
        if (!has_position) out += "position:relative;";
        std::snprintf(buf, sizeof(buf), "left:%.2fpx;top:%.2fpx;", tdx, tdy);
        out += buf;
    }
    return out;
}

// 把 style="..." / <style>…</style> 里的声明改写掉
std::string rewrite_html(const std::string& html, std::vector<shadow_spec>& shadows)
{
    std::string out;
    out.reserve(html.size() + 256);
    size_t i = 0;
    while (i < html.size())
    {
        // <style ...> … </style>
        if (html[i] == '<' && starts_at(html, i, "<style"))
        {
            const size_t gt = html.find('>', i);
            if (gt != std::string::npos)
            {
                size_t end = std::string::npos;
                for (size_t k = gt + 1; k + 7 <= html.size(); ++k)
                    if (html[k] == '<' && starts_at(html, k, "</style"))
                    {
                        end = k;
                        break;
                    }
                if (end != std::string::npos)
                {
                    out += html.substr(i, gt - i + 1);
                    const std::string css = html.substr(gt + 1, end - gt - 1);
                    out += rewrite_css(css, shadows);
                    i = end;
                    continue;
                }
            }
        }
        // style="..." / style='...'
        if (html[i] == 's' && starts_at(html, i, "style") &&
            (i == 0 || !std::isalnum(static_cast<unsigned char>(html[i - 1]))))
        {
            size_t j = i + 5;
            while (j < html.size() && std::isspace(static_cast<unsigned char>(html[j]))) ++j;
            if (j < html.size() && html[j] == '=')
            {
                ++j;
                while (j < html.size() && std::isspace(static_cast<unsigned char>(html[j]))) ++j;
                if (j < html.size() && (html[j] == '"' || html[j] == '\''))
                {
                    const char   q   = html[j];
                    const size_t end = html.find(q, j + 1);
                    if (end != std::string::npos)
                    {
                        out += html.substr(i, j - i + 1);
                        out += rewrite_decls(html.substr(j + 1, end - j - 1), shadows);
                        i = end;   // 结束引号留给下一轮
                        continue;
                    }
                }
            }
        }
        out.push_back(html[i]);
        ++i;
    }
    return out;
}

} // namespace

std::string rewrite(const std::string& html, std::vector<shadow_spec>& shadows)
{
    return rewrite_html(html, shadows);
}

} // namespace prepass
