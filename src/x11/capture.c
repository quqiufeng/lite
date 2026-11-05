// X11 屏幕/窗口区域截图：XGetImage + libpng，替代外部 libagentkit。
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <png.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local char g_err[256];

static void set_err(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof(g_err), fmt, ap);
    va_end(ap);
}

const char *lite_capture_error(void)
{
    return g_err[0] ? g_err : "unknown capture error";
}

static int mask_shift(unsigned long mask, int *bits)
{
    int shift = 0;
    if (mask == 0) {
        *bits = 0;
        return 0;
    }
    while ((mask & 1UL) == 0) {
        mask >>= 1;
        shift++;
    }
    int n = 0;
    while (mask & 1UL) {
        mask >>= 1;
        n++;
    }
    *bits = n;
    return shift;
}

static unsigned char channel(unsigned long pixel, unsigned long mask, int bits, int shift)
{
    if (!bits) return 0;
    unsigned long v = (pixel & mask) >> shift;
    unsigned long max = (1UL << bits) - 1UL;
    return (unsigned char)((v * 255UL + max / 2UL) / max);
}

int lite_capture(int x, int y, int width, int height, const char *out_png)
{
    g_err[0] = 0;
    if (!out_png || !*out_png) {
        set_err("output path is required");
        return -1;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        set_err("cannot open X display");
        return -1;
    }
    int screen = DefaultScreen(dpy);
    int sw = DisplayWidth(dpy, screen);
    int sh = DisplayHeight(dpy, screen);

    if (x < 0) { width += x; x = 0; }
    if (y < 0) { height += y; y = 0; }
    if (x >= sw || y >= sh || width <= 0 || height <= 0) {
        set_err("capture rect outside display: %d,%d %dx%d", x, y, width, height);
        XCloseDisplay(dpy);
        return -1;
    }
    if (x + width > sw) width = sw - x;
    if (y + height > sh) height = sh - y;
    if (width <= 0 || height <= 0) {
        set_err("capture rect is empty");
        XCloseDisplay(dpy);
        return -1;
    }

    XImage *img = XGetImage(dpy, DefaultRootWindow(dpy), x, y,
        (unsigned int)width, (unsigned int)height, AllPlanes, ZPixmap);
    if (!img) {
        set_err("XGetImage failed: %d,%d %dx%d", x, y, width, height);
        XCloseDisplay(dpy);
        return -1;
    }

    size_t stride = (size_t)width * 4;
    unsigned char *rgba = malloc(stride * (size_t)height);
    if (!rgba) {
        set_err("out of memory");
        XDestroyImage(img);
        XCloseDisplay(dpy);
        return -1;
    }

    int rbits, gbits, bbits;
    int rshift = mask_shift(img->red_mask, &rbits);
    int gshift = mask_shift(img->green_mask, &gbits);
    int bshift = mask_shift(img->blue_mask, &bbits);

    for (int yy = 0; yy < height; yy++) {
        unsigned char *row = rgba + (size_t)yy * stride;
        for (int xx = 0; xx < width; xx++) {
            unsigned long p = XGetPixel(img, xx, yy);
            row[xx * 4 + 0] = channel(p, img->red_mask, rbits, rshift);
            row[xx * 4 + 1] = channel(p, img->green_mask, gbits, gshift);
            row[xx * 4 + 2] = channel(p, img->blue_mask, bbits, bshift);
            row[xx * 4 + 3] = 255;
        }
    }

    png_image png;
    memset(&png, 0, sizeof(png));
    png.version = PNG_IMAGE_VERSION;
    png.width = (png_uint_32)width;
    png.height = (png_uint_32)height;
    png.format = PNG_FORMAT_RGBA;
    int ok = png_image_write_to_file(&png, out_png, 0, rgba, 0, NULL);
    if (!ok) {
        set_err("png write failed: %s", png.message);
    }

    free(rgba);
    XDestroyImage(img);
    XCloseDisplay(dpy);
    return ok ? 0 : -1;
}
