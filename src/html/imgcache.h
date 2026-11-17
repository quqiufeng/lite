// src/html/imgcache.h — litehtml 容器用的图片缓存（PNG / JPEG / WebP，纯本地文件）。
// 只做三件事：把 <img src> / background-image 的字符串解析成路径、读头取固有尺寸（布局要用）、
// 解码成 cairo surface（绘制要用，按路径缓存一次）。没有网络、没有 SVG。
// 相对路径的基准顺序：调用方给的 base（litehtml 的 baseurl）→ lite_html_set_base_dir 设的目录 → cwd。
#ifndef LITE_HTML_IMGCACHE_H
#define LITE_HTML_IMGCACHE_H

#include <cairo/cairo.h>
#include <string>

namespace imgcache {

struct image
{
    cairo_surface_t* surf = nullptr;
    int              w    = 0;   // 固有宽（像素 = CSS px）
    int              h    = 0;
};

// 渲染期的相对路径基准目录（空 = cwd）。进程级，条带渲染前后由调用方设置。
void               set_base_dir(const std::string& dir);
const std::string& base_dir();

// src → 绝对路径：支持 /abs、./rel、file://、%20 转义；http(s):// 不处理（返回空串）。
std::string resolve(const std::string& src, const std::string& base);

// 只读文件头取尺寸，不解码像素（失败返回 false，结果同样缓存，坏图不会反复 IO）。
bool size(const std::string& path, int* w, int* h);

// 取解码好的图（按路径缓存）；失败返回 nullptr，失败也缓存。
const image* get(const std::string& path);

// 最近一次失败原因（给 lite_html_error 之外的诊断用，可为空）
const std::string& last_error();

// 清空缓存（同一进程里换 base_dir 不影响已缓存的绝对路径，一般不用调用）
void clear();

} // namespace imgcache

#endif
