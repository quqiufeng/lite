// src/html/imgcache.cpp — 见 imgcache.h。解码 PNG/JPEG/WebP 到 premultiplied ARGB32。
// 三个格式的「读头取尺寸」都只碰文件头，不做完整解码（布局期 litehtml 会按元素反复问尺寸）。
#include "imgcache.h"

#include <png.h>
#include <jpeglib.h>
#include <setjmp.h>
#include <webp/decode.h>

#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

namespace imgcache {
namespace {

const size_t kMaxFileBytes  = 64u * 1024u * 1024u;
const long   kMaxPixels     = 64000000L;      // 与 src/image/image.c 的上限一致

std::string g_base_dir;
std::string g_err;

struct size_entry
{
    int  w = 0, h = 0;
    bool ok = false;
};

std::map<std::string, size_entry>          g_sizes;
std::map<std::string, std::unique_ptr<image>> g_images;
std::mutex                                 g_mu;   // 只为多实例线程安全，单线程下零开销

std::string percent_decode(const std::string& s)
{
    std::string o;
    o.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) {
            auto hex = [](char c) -> int {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return c - 'a' + 10;
                if (c >= 'A' && c <= 'F') return c - 'A' + 10;
                return -1;
            };
            int hi = hex(s[i + 1]), lo = hex(s[i + 2]);
            if (hi >= 0 && lo >= 0) { o.push_back(static_cast<char>(hi * 16 + lo)); i += 2; continue; }
        }
        o.push_back(s[i]);
    }
    return o;
}

// 把 a/b/../c 规范成 a/c（纯文本处理，不 realpath：图片可以还不存在或被软链）
std::string normalize(const std::string& p)
{
    if (p.empty()) return p;
    const bool abs = p[0] == '/';
    std::vector<std::string> parts;
    size_t i = 0;
    while (i <= p.size()) {
        size_t j = p.find('/', i);
        if (j == std::string::npos) j = p.size();
        std::string seg = p.substr(i, j - i);
        if (seg == "..") { if (!parts.empty() && parts.back() != "..") parts.pop_back(); else if (!abs) parts.push_back(".."); }
        else if (!seg.empty() && seg != ".") parts.push_back(seg);
        i = j + 1;
    }
    std::string o = abs ? "/" : "";
    for (size_t k = 0; k < parts.size(); ++k) { if (k) o += "/"; o += parts[k]; }
    return o.empty() ? (abs ? "/" : ".") : o;
}

bool has_scheme(const std::string& s) { return s.find("://") != std::string::npos; }

bool read_file(const std::string& path, std::vector<unsigned char>& out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { g_err = "open " + path + ": " + strerror(errno); return false; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); g_err = "seek " + path; return false; }
    long n = ftell(f);
    if (n <= 0 || static_cast<size_t>(n) > kMaxFileBytes) {
        fclose(f);
        g_err = "bad size (" + std::to_string(n) + " bytes) " + path;
        return false;
    }
    rewind(f);
    out.resize(static_cast<size_t>(n));
    size_t got = fread(out.data(), 1, out.size(), f);
    fclose(f);
    if (got != out.size()) { g_err = "short read " + path; return false; }
    return true;
}

enum class fmt { png, jpeg, webp, unknown };

fmt sniff(const std::vector<unsigned char>& d)
{
    if (d.size() >= 8 && !memcmp(d.data(), "\x89PNG\r\n\x1a\n", 8)) return fmt::png;
    if (d.size() >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return fmt::jpeg;
    if (d.size() >= 12 && !memcmp(d.data(), "RIFF", 4) && !memcmp(d.data() + 8, "WEBP", 4)) return fmt::webp;
    return fmt::unknown;
}

// BGRA（小端 = ARGB32 的字节序）就地预乘
void premultiply_bgra(unsigned char* p, size_t npx)
{
    for (size_t i = 0; i < npx; ++i, p += 4) {
        const unsigned a = p[3];
        if (a == 255 || a == 0) { if (a == 0) p[0] = p[1] = p[2] = 0; continue; }
        p[0] = static_cast<unsigned char>((p[0] * a + 127) / 255);
        p[1] = static_cast<unsigned char>((p[1] * a + 127) / 255);
        p[2] = static_cast<unsigned char>((p[2] * a + 127) / 255);
    }
}

// ── PNG（libpng simplified API）─────────────────────────────────────────────
bool png_size(const std::vector<unsigned char>& d, int* w, int* h)
{
    png_image im;
    memset(&im, 0, sizeof im);
    im.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&im, d.data(), d.size())) { g_err = im.message; return false; }
    *w = static_cast<int>(im.width);
    *h = static_cast<int>(im.height);
    png_image_free(&im);                     // 只读了头，直接放掉
    return true;
}

bool png_load(const std::vector<unsigned char>& d, int* w, int* h, std::vector<unsigned char>* px)
{
    png_image im;
    memset(&im, 0, sizeof im);
    im.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&im, d.data(), d.size())) { g_err = im.message; return false; }
    if (static_cast<long>(im.width) * static_cast<long>(im.height) > kMaxPixels) {
        png_image_free(&im);
        g_err = "png too large: " + std::to_string(im.width) + "x" + std::to_string(im.height);
        return false;
    }
    im.format = PNG_FORMAT_BGRA;             // 小端 → CAIRO_FORMAT_ARGB32 的内存布局
    px->resize(PNG_IMAGE_SIZE(im));
    if (!png_image_finish_read(&im, nullptr, px->data(), 0, nullptr)) {
        g_err = im.message;
        png_image_free(&im);
        return false;
    }
    *w = static_cast<int>(im.width);
    *h = static_cast<int>(im.height);
    png_image_free(&im);
    return true;
}

// ── JPEG（libjpeg，错误用 longjmp 兜，libjpeg 默认会退出进程）───────────────
struct jpeg_err_mgr
{
    jpeg_error_mgr pub;
    jmp_buf        jb;
};

void jpeg_on_error(j_common_ptr cinfo)
{
    auto* e = reinterpret_cast<jpeg_err_mgr*>(cinfo->err);
    longjmp(e->jb, 1);
}

void jpeg_silent(j_common_ptr) {}            // 默认 output_message 会往 stderr 喷

bool jpeg_size(const std::vector<unsigned char>& d, int* w, int* h)
{
    jpeg_decompress_struct ci;
    jpeg_err_mgr jerr;
    ci.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit   = jpeg_on_error;
    jerr.pub.output_message = jpeg_silent;
    if (setjmp(jerr.jb)) { jpeg_destroy_decompress(&ci); g_err = "jpeg header: corrupt"; return false; }
    jpeg_create_decompress(&ci);
    jpeg_mem_src(&ci, d.data(), static_cast<unsigned long>(d.size()));
    if (jpeg_read_header(&ci, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&ci);
        g_err = "jpeg header: not jpeg";
        return false;
    }
    *w = static_cast<int>(ci.image_width);
    *h = static_cast<int>(ci.image_height);
    jpeg_destroy_decompress(&ci);
    return true;
}

bool jpeg_load(const std::vector<unsigned char>& d, int* w, int* h, std::vector<unsigned char>* px)
{
    jpeg_decompress_struct ci;
    jpeg_err_mgr jerr;
    ci.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit    = jpeg_on_error;
    jerr.pub.output_message = jpeg_silent;
    unsigned char* volatile row = nullptr;      // volatile：longjmp 后要靠它释放
    if (setjmp(jerr.jb)) {
        free(row);
        jpeg_destroy_decompress(&ci);
        g_err = "jpeg decode failed";
        return false;
    }
    jpeg_create_decompress(&ci);
    jpeg_mem_src(&ci, d.data(), static_cast<unsigned long>(d.size()));
    if (jpeg_read_header(&ci, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&ci);
        g_err = "jpeg header: not jpeg";
        return false;
    }
    ci.out_color_space = JCS_RGB;
    jpeg_start_decompress(&ci);
    const int iw = static_cast<int>(ci.output_width), ih = static_cast<int>(ci.output_height);
    if (static_cast<long>(iw) * static_cast<long>(ih) > kMaxPixels) {
        jpeg_destroy_decompress(&ci);
        g_err = "jpeg too large: " + std::to_string(iw) + "x" + std::to_string(ih);
        return false;
    }
    row = static_cast<unsigned char*>(malloc(static_cast<size_t>(iw) * 3));
    if (!row) { jpeg_destroy_decompress(&ci); g_err = "jpeg: out of memory"; return false; }
    px->assign(static_cast<size_t>(iw) * ih * 4, 255);
    unsigned char* dst = px->data();
    while (ci.output_scanline < ci.output_height) {
        unsigned char* rows[1] = { row };
        jpeg_read_scanlines(&ci, rows, 1);
        for (int x = 0; x < iw; ++x) {
            const unsigned char* s = row + x * 3;
            dst[0] = s[2]; dst[1] = s[1]; dst[2] = s[0]; dst[3] = 255;
            dst += 4;
        }
    }
    free(row);
    jpeg_finish_decompress(&ci);
    jpeg_destroy_decompress(&ci);
    *w = iw;
    *h = ih;
    return true;
}

// ── WebP（libwebp）─────────────────────────────────────────────────────────
bool webp_size(const std::vector<unsigned char>& d, int* w, int* h)
{
    if (!WebPGetInfo(d.data(), d.size(), w, h)) { g_err = "webp header: corrupt"; return false; }
    return true;
}

bool webp_load(const std::vector<unsigned char>& d, int* w, int* h, std::vector<unsigned char>* px)
{
    int iw = 0, ih = 0;
    if (!WebPGetInfo(d.data(), d.size(), &iw, &ih)) { g_err = "webp header: corrupt"; return false; }
    if (static_cast<long>(iw) * static_cast<long>(ih) > kMaxPixels) {
        g_err = "webp too large: " + std::to_string(iw) + "x" + std::to_string(ih);
        return false;
    }
    px->resize(static_cast<size_t>(iw) * ih * 4);
    if (!WebPDecodeBGRAInto(d.data(), d.size(), px->data(), px->size(), iw * 4)) {
        g_err = "webp decode failed";
        return false;
    }
    *w = iw;
    *h = ih;
    return true;
}

bool read_header(const std::string& path, int* w, int* h)
{
    std::vector<unsigned char> d;
    if (!read_file(path, d)) return false;
    switch (sniff(d)) {
    case fmt::png:  return png_size(d, w, h);
    case fmt::jpeg: return jpeg_size(d, w, h);
    case fmt::webp: return webp_size(d, w, h);
    default:        g_err = "unsupported image: " + path; return false;
    }
}

} // namespace

void set_base_dir(const std::string& dir)
{
    std::lock_guard<std::mutex> lk(g_mu);
    g_base_dir = dir;
}

const std::string& base_dir() { return g_base_dir; }

const std::string& last_error() { return g_err; }

std::string resolve(const std::string& src, const std::string& base)
{
    if (src.empty()) return std::string();
    std::string s = src;
    // 去掉引号（CSS url("…") 之外，md 里也可能带引号）
    if (s.size() >= 2 && (s[0] == '"' || s[0] == '\'') && s.back() == s[0]) s = s.substr(1, s.size() - 2);
    if (s.empty()) return std::string();
    if (s.compare(0, 5, "data:") == 0) return std::string();      // 不内联解 base64
    if (s.compare(0, 7, "file://") == 0) s = percent_decode(s.substr(7));
    else if (has_scheme(s)) return std::string();                  // http(s)/其它协议交给调用方
    else s = percent_decode(s);

    if (!s.empty() && s[0] == '/') return normalize(s);
    std::string b = base.empty() ? g_base_dir : base;
    if (b.compare(0, 7, "file://") == 0) b = b.substr(7);
    if (b.empty()) {
        char buf[4096];
        if (getcwd(buf, sizeof buf)) b = buf;
    }
    if (!b.empty() && b[0] != '/') {
        char buf[4096];
        if (getcwd(buf, sizeof buf)) b = std::string(buf) + "/" + b;
    }
    return normalize(b + "/" + s);
}

bool size(const std::string& path, int* w, int* h)
{
    if (path.empty()) return false;
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_sizes.find(path);
    if (it != g_sizes.end()) {
        if (!it->second.ok) return false;
        *w = it->second.w;
        *h = it->second.h;
        return true;
    }
    size_entry e;
    e.ok = read_header(path, &e.w, &e.h) && e.w > 0 && e.h > 0;
    g_sizes[path] = e;
    if (!e.ok) return false;
    *w = e.w;
    *h = e.h;
    return true;
}

const image* get(const std::string& path)
{
    if (path.empty()) return nullptr;
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_images.find(path);
    if (it != g_images.end()) return it->second ? it->second.get() : nullptr;

    std::vector<unsigned char> d;
    std::unique_ptr<image> out;
    std::vector<unsigned char> px;
    int w = 0, h = 0;
    bool ok = read_file(path, d);
    if (ok) {
        switch (sniff(d)) {
        case fmt::png:  ok = png_load(d, &w, &h, &px); break;
        case fmt::jpeg: ok = jpeg_load(d, &w, &h, &px); break;
        case fmt::webp: ok = webp_load(d, &w, &h, &px); break;
        default:        g_err = "unsupported image: " + path; ok = false; break;
        }
    }
    if (ok && w > 0 && h > 0 && px.size() >= static_cast<size_t>(w) * h * 4) {
        premultiply_bgra(px.data(), static_cast<size_t>(w) * h);
        cairo_surface_t* s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
        if (cairo_surface_status(s) == CAIRO_STATUS_SUCCESS) {
            unsigned char* dst = cairo_image_surface_get_data(s);
            const int stride = cairo_image_surface_get_stride(s);
            for (int y = 0; y < h; ++y)
                memcpy(dst + static_cast<size_t>(y) * stride,
                       px.data() + static_cast<size_t>(y) * w * 4, static_cast<size_t>(w) * 4);
            cairo_surface_mark_dirty(s);
            out.reset(new image());
            out->surf = s;
            out->w = w;
            out->h = h;
        } else {
            cairo_surface_destroy(s);
            g_err = std::string("cairo surface: ") + cairo_status_to_string(cairo_surface_status(s));
        }
    }
    // 顺带把尺寸写进尺寸缓存（省一次文件头读取）
    if (out) g_sizes[path] = size_entry{ w, h, true };
    else if (!g_sizes.count(path)) g_sizes[path] = size_entry{ 0, 0, false };

    const image* ret = out.get();
    g_images[path] = std::move(out);
    return ret;
}

void clear()
{
    std::lock_guard<std::mutex> lk(g_mu);
    for (auto& kv : g_images)
        if (kv.second && kv.second->surf) cairo_surface_destroy(kv.second->surf);
    g_images.clear();
    g_sizes.clear();
}

} // namespace imgcache
