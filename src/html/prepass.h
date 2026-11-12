// src/html/prepass.h — litehtml 不支持 opacity / box-shadow / transform:translate，
// 在交给 litehtml 之前先把这几条 CSS 改写成它认识的东西：
//   opacity: v        → 把同一条规则的 color/background/border/gradient 颜色 alpha 乘 v
//                       （子元素不重叠且不透明时与浏览器分组合成等价；重叠处略有差异）
//   transform:translate → position:relative; left/top（litehtml 支持相对定位偏移）
//                       rotate/scale/matrix 不在此列（无法在无元素钩子的容器里实现）
//   box-shadow: ...    → background-color 换成哨兵色 rgb(254,1,i)，参数存 shadows[i-1]，
//                       由 render.cpp 的 draw_solid_fill 识别后先画软阴影再补回原背景色。
// 只在「有纯色背景」的元素上做哨兵（否则无处触发），做不到就原样丢掉该属性。
#ifndef LITE_HTML_PREPASS_H
#define LITE_HTML_PREPASS_H

#include <string>
#include <vector>

namespace prepass {

struct shadow_spec
{
    double dx = 0, dy = 0, blur = 0, spread = 0;
    int    r = 0, g = 0, b = 0, a = 255;          // 阴影颜色
    int    bg_r = 0, bg_g = 0, bg_b = 0, bg_a = 0; // 元素自身背景色（哨兵替换掉的）
};

// 哨兵色：r=254,g=1,b=index+1（b 通道当索引，最多 254 条阴影）
inline bool sentinel_index(int r, int g, int b, size_t& idx)
{
    if (r != 254 || g != 1 || b < 1) return false;
    idx = static_cast<size_t>(b - 1);
    return true;
}

// 改写 html 里 <style> 与 style="..." 中的上述三条属性；返回新的 html。
// 识别到的 box-shadow 按哨兵索引顺序追加到 shadows。
std::string rewrite(const std::string& html, std::vector<shadow_spec>& shadows);

} // namespace prepass

#endif
