// lite 内置图像模块：PNG/JPEG/WebP 解码 + RGBA resize + 编码。
// 动态链接 libpng/libjpeg/libwebp；打包时把 .so 一起放进 lib/。
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <png.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <webp/decode.h>
#include <webp/encode.h>
#include <jpeglib.h>

#define LITE_IMAGE_INPUT_MAX (64u * 1024u * 1024u)
#define LITE_IMAGE_MAX_PIXELS 64000000LL

static _Thread_local char g_err[512];

static void set_err(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof(g_err), fmt, ap);
    va_end(ap);
}

const char *lite_image_error(void)
{
    return g_err[0] ? g_err : "unknown image error";
}

typedef struct {
    unsigned char *px;
    int w;
    int h;
} lite_image_t;

static int read_file(const char *path, unsigned char **out, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        set_err("open %s: %s", path, strerror(errno));
        return -1;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        set_err("seek %s: %s", path, strerror(errno));
        fclose(f);
        return -1;
    }
    long n = ftell(f);
    if (n < 0) {
        set_err("tell %s: %s", path, strerror(errno));
        fclose(f);
        return -1;
    }
    if (n == 0) {
        set_err("empty image: %s", path);
        fclose(f);
        return -1;
    }
    if ((unsigned long)n > LITE_IMAGE_INPUT_MAX) {
        set_err("image too large: %ld bytes (max %u)", n, LITE_IMAGE_INPUT_MAX);
        fclose(f);
        return -1;
    }
    rewind(f);
    unsigned char *buf = malloc((size_t)n);
    if (!buf) {
        set_err("out of memory reading %s", path);
        fclose(f);
        return -1;
    }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        set_err("read %s: %s", path, strerror(errno));
        free(buf);
        fclose(f);
        return -1;
    }
    fclose(f);
    *out = buf;
    *out_len = (size_t)n;
    return 0;
}

static int check_pixels(int w, int h)
{
    if (w <= 0 || h <= 0) {
        set_err("invalid image dimensions: %dx%d", w, h);
        return -1;
    }
    if ((long long)w * (long long)h > LITE_IMAGE_MAX_PIXELS) {
        set_err("image too large: %dx%d", w, h);
        return -1;
    }
    return 0;
}

static int decode_png(const unsigned char *buf, size_t len, lite_image_t *img)
{
    png_image image;
    memset(&image, 0, sizeof(image));
    image.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&image, buf, len)) {
        set_err("png: %s", image.message);
        return -1;
    }
    if (check_pixels((int)image.width, (int)image.height) != 0) {
        png_image_free(&image);
        return -1;
    }
    image.format = PNG_FORMAT_RGBA;
    size_t size = PNG_IMAGE_SIZE(image);
    unsigned char *px = malloc(size);
    if (!px) {
        set_err("out of memory decoding png");
        png_image_free(&image);
        return -1;
    }
    if (!png_image_finish_read(&image, NULL, px, 0, NULL)) {
        set_err("png: %s", image.message);
        free(px);
        png_image_free(&image);
        return -1;
    }
    img->px = px;
    img->w = (int)image.width;
    img->h = (int)image.height;
    png_image_free(&image);
    return 0;
}

struct lite_jpeg_err {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
};

static void jpeg_fail(j_common_ptr cinfo)
{
    struct lite_jpeg_err *err = (struct lite_jpeg_err *)cinfo->err;
    char msg[JMSG_LENGTH_MAX];
    (*cinfo->err->format_message)(cinfo, msg);
    set_err("jpeg: %s", msg);
    longjmp(err->jump, 1);
}

static int decode_jpeg(const unsigned char *buf, size_t len, lite_image_t *img)
{
    struct jpeg_decompress_struct cinfo;
    struct lite_jpeg_err jerr;
    unsigned char *volatile px = NULL;
    memset(&cinfo, 0, sizeof(cinfo));
    memset(&jerr, 0, sizeof(jerr));
    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_fail;
    if (setjmp(jerr.jump)) {
        free(px);
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, buf, (unsigned long)len);
    jpeg_read_header(&cinfo, TRUE);
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);

    int w = (int)cinfo.output_width;
    int h = (int)cinfo.output_height;
    if (check_pixels(w, h) != 0) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    px = malloc((size_t)w * (size_t)h * 4);
    if (!px) {
        set_err("out of memory decoding jpeg");
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    int ch = cinfo.output_components;
    JSAMPARRAY row = (*cinfo.mem->alloc_sarray)((j_common_ptr)&cinfo,
        JPOOL_IMAGE, (JDIMENSION)(w * ch), 1);
    while (cinfo.output_scanline < cinfo.output_height) {
        JDIMENSION y = cinfo.output_scanline;
        jpeg_read_scanlines(&cinfo, row, 1);
        const unsigned char *src = row[0];
        unsigned char *dst = px + (size_t)y * (size_t)w * 4;
        for (int x = 0; x < w; x++) {
            if (ch >= 3) {
                dst[x * 4 + 0] = src[x * ch + 0];
                dst[x * 4 + 1] = src[x * ch + 1];
                dst[x * 4 + 2] = src[x * ch + 2];
            } else {
                dst[x * 4 + 0] = src[x * ch];
                dst[x * 4 + 1] = src[x * ch];
                dst[x * 4 + 2] = src[x * ch];
            }
            dst[x * 4 + 3] = 255;
        }
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    img->px = px;
    img->w = w;
    img->h = h;
    return 0;
}

static int decode_webp(const unsigned char *buf, size_t len, lite_image_t *img)
{
    int w = 0, h = 0;
    if (!WebPGetInfo(buf, len, &w, &h)) {
        set_err("webp: invalid header");
        return -1;
    }
    if (check_pixels(w, h) != 0) return -1;
    unsigned char *px = malloc((size_t)w * (size_t)h * 4);
    if (!px) {
        set_err("out of memory decoding webp");
        return -1;
    }
    if (!WebPDecodeRGBAInto(buf, len, px, (size_t)w * (size_t)h * 4, w * 4)) {
        set_err("webp: decode failed");
        free(px);
        return -1;
    }
    img->px = px;
    img->w = w;
    img->h = h;
    return 0;
}

static int decode_image(const unsigned char *buf, size_t len, lite_image_t *img)
{
    static const unsigned char png_sig[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
    if (len >= 8 && memcmp(buf, png_sig, 8) == 0) return decode_png(buf, len, img);
    if (len >= 3 && buf[0] == 0xff && buf[1] == 0xd8 && buf[2] == 0xff)
        return decode_jpeg(buf, len, img);
    if (len >= 12 && memcmp(buf, "RIFF", 4) == 0 && memcmp(buf + 8, "WEBP", 4) == 0)
        return decode_webp(buf, len, img);
    set_err("unsupported image format (png/jpeg/webp only)");
    return -1;
}

static void premultiply(unsigned char *px, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        unsigned char *p = px + i * 4;
        unsigned a = p[3];
        if (a == 255) continue;
        p[0] = (unsigned char)((p[0] * a + 127) / 255);
        p[1] = (unsigned char)((p[1] * a + 127) / 255);
        p[2] = (unsigned char)((p[2] * a + 127) / 255);
    }
}

static void unpremultiply(unsigned char *px, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        unsigned char *p = px + i * 4;
        unsigned a = p[3];
        if (a == 0) {
            p[0] = p[1] = p[2] = 0;
        } else if (a != 255) {
            unsigned r = (p[0] * 255u + a / 2) / a;
            unsigned g = (p[1] * 255u + a / 2) / a;
            unsigned b = (p[2] * 255u + a / 2) / a;
            p[0] = (unsigned char)(r > 255 ? 255 : r);
            p[1] = (unsigned char)(g > 255 ? 255 : g);
            p[2] = (unsigned char)(b > 255 ? 255 : b);
        }
    }
}

static void resize_area(const lite_image_t *src, lite_image_t *dst)
{
    for (int y = 0; y < dst->h; y++) {
        int y0 = (int)((long long)y * src->h / dst->h);
        int y1 = (int)((long long)(y + 1) * src->h / dst->h);
        if (y1 <= y0) y1 = y0 + 1;
        for (int x = 0; x < dst->w; x++) {
            int x0 = (int)((long long)x * src->w / dst->w);
            int x1 = (int)((long long)(x + 1) * src->w / dst->w);
            if (x1 <= x0) x1 = x0 + 1;
            unsigned long long sum[4] = {0, 0, 0, 0};
            for (int sy = y0; sy < y1; sy++) {
                const unsigned char *p = src->px + ((size_t)sy * src->w + x0) * 4;
                for (int sx = x0; sx < x1; sx++, p += 4) {
                    sum[0] += p[0];
                    sum[1] += p[1];
                    sum[2] += p[2];
                    sum[3] += p[3];
                }
            }
            unsigned long long count = (unsigned long long)(x1 - x0) * (y1 - y0);
            unsigned char *q = dst->px + ((size_t)y * dst->w + x) * 4;
            q[0] = (unsigned char)(sum[0] / count);
            q[1] = (unsigned char)(sum[1] / count);
            q[2] = (unsigned char)(sum[2] / count);
            q[3] = (unsigned char)(sum[3] / count);
        }
    }
}

static void resize_bilinear(const lite_image_t *src, lite_image_t *dst)
{
    for (int y = 0; y < dst->h; y++) {
        double sy = ((double)(y + 0.5) * src->h / dst->h) - 0.5;
        if (sy < 0) sy = 0;
        if (sy > src->h - 1) sy = src->h - 1;
        int y0 = (int)sy;
        int y1 = y0 + 1 < src->h ? y0 + 1 : y0;
        double fy = sy - y0;
        for (int x = 0; x < dst->w; x++) {
            double sx = ((double)(x + 0.5) * src->w / dst->w) - 0.5;
            if (sx < 0) sx = 0;
            if (sx > src->w - 1) sx = src->w - 1;
            int x0 = (int)sx;
            int x1 = x0 + 1 < src->w ? x0 + 1 : x0;
            double fx = sx - x0;
            const unsigned char *p00 = src->px + ((size_t)y0 * src->w + x0) * 4;
            const unsigned char *p10 = src->px + ((size_t)y0 * src->w + x1) * 4;
            const unsigned char *p01 = src->px + ((size_t)y1 * src->w + x0) * 4;
            const unsigned char *p11 = src->px + ((size_t)y1 * src->w + x1) * 4;
            unsigned char *q = dst->px + ((size_t)y * dst->w + x) * 4;
            for (int c = 0; c < 4; c++) {
                double top = p00[c] * (1.0 - fx) + p10[c] * fx;
                double bot = p01[c] * (1.0 - fx) + p11[c] * fx;
                double v = top * (1.0 - fy) + bot * fy;
                q[c] = (unsigned char)(v + 0.5);
            }
        }
    }
}

static int resize_rgba(const lite_image_t *src, int dw, int dh, lite_image_t *dst)
{
    if (check_pixels(dw, dh) != 0) return -1;
    dst->px = malloc((size_t)dw * (size_t)dh * 4);
    if (!dst->px) {
        set_err("out of memory resizing");
        return -1;
    }
    dst->w = dw;
    dst->h = dh;
    premultiply(src->px, (size_t)src->w * (size_t)src->h);
    if (dw < src->w && dh < src->h) {
        resize_area(src, dst);
    } else {
        resize_bilinear(src, dst);
    }
    unpremultiply(dst->px, (size_t)dw * (size_t)dh);
    return 0;
}

static int output_format(const char *path)
{
    const char *dot = strrchr(path, '.');
    if (!dot) return -1;
    if (strcasecmp(dot, ".png") == 0) return 0;
    if (strcasecmp(dot, ".jpg") == 0 || strcasecmp(dot, ".jpeg") == 0) return 1;
    if (strcasecmp(dot, ".webp") == 0) return 2;
    return -1;
}

static int write_png(const char *path, const lite_image_t *img)
{
    png_image image;
    memset(&image, 0, sizeof(image));
    image.version = PNG_IMAGE_VERSION;
    image.width = img->w;
    image.height = img->h;
    image.format = PNG_FORMAT_RGBA;
    if (!png_image_write_to_file(&image, path, 0, img->px, 0, NULL)) {
        set_err("png write: %s", image.message);
        return -1;
    }
    return 0;
}

static int write_jpeg(const char *path, const lite_image_t *img)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        set_err("open %s: %s", path, strerror(errno));
        return -1;
    }
    struct jpeg_compress_struct cinfo;
    struct lite_jpeg_err jerr;
    memset(&cinfo, 0, sizeof(cinfo));
    memset(&jerr, 0, sizeof(jerr));
    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_fail;
    unsigned char *volatile row = NULL;
    if (setjmp(jerr.jump)) {
        free(row);
        jpeg_destroy_compress(&cinfo);
        fclose(f);
        return -1;
    }
    jpeg_create_compress(&cinfo);
    jpeg_stdio_dest(&cinfo, f);
    cinfo.image_width = img->w;
    cinfo.image_height = img->h;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, 90, TRUE);
    jpeg_start_compress(&cinfo, TRUE);
    row = malloc((size_t)img->w * 3);
    if (!row) {
        set_err("out of memory encoding jpeg");
        jpeg_destroy_compress(&cinfo);
        fclose(f);
        return -1;
    }
    while (cinfo.next_scanline < cinfo.image_height) {
        const unsigned char *p = img->px + (size_t)cinfo.next_scanline * (size_t)img->w * 4;
        for (int x = 0; x < img->w; x++, p += 4) {
            unsigned a = p[3];
            if (a == 255) {
                row[x * 3 + 0] = p[0];
                row[x * 3 + 1] = p[1];
                row[x * 3 + 2] = p[2];
            } else {
                row[x * 3 + 0] = (unsigned char)((p[0] * a + 255u * (255u - a)) / 255u);
                row[x * 3 + 1] = (unsigned char)((p[1] * a + 255u * (255u - a)) / 255u);
                row[x * 3 + 2] = (unsigned char)((p[2] * a + 255u * (255u - a)) / 255u);
            }
        }
        JSAMPROW rows[1] = {row};
        jpeg_write_scanlines(&cinfo, rows, 1);
    }
    free(row);
    row = NULL;
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    fclose(f);
    return 0;
}

static int write_webp(const char *path, const lite_image_t *img)
{
    uint8_t *out = NULL;
    size_t n = WebPEncodeRGBA(img->px, img->w, img->h, img->w * 4, 90.0f, &out);
    if (n == 0 || !out) {
        set_err("webp encode failed");
        return -1;
    }
    FILE *f = fopen(path, "wb");
    if (!f) {
        set_err("open %s: %s", path, strerror(errno));
        WebPFree(out);
        return -1;
    }
    size_t wrote = fwrite(out, 1, n, f);
    WebPFree(out);
    int close_rc = fclose(f);
    if (wrote != n || close_rc != 0) {
        set_err("webp write failed: %s", path);
        return -1;
    }
    return 0;
}

int lite_image_resize(const char *src, const char *dst, int width, int height, int force)
{
    g_err[0] = 0;
    if (!src || !dst) {
        set_err("src and dst are required");
        return -1;
    }
    if (width <= 0 && height <= 0) {
        set_err("width or height is required");
        return -1;
    }
    int fmt = output_format(dst);
    if (fmt < 0) {
        set_err("unsupported output format (use .png/.jpg/.jpeg/.webp): %s", dst);
        return -1;
    }

    unsigned char *buf = NULL;
    size_t len = 0;
    if (read_file(src, &buf, &len) != 0) return -1;

    lite_image_t in = {0};
    if (decode_image(buf, len, &in) != 0) {
        free(buf);
        return -1;
    }
    free(buf);

    int dw, dh;
    if (force && width > 0 && height > 0) {
        dw = width;
        dh = height;
    } else {
        double sx = width > 0 ? (double)width / in.w : 1e30;
        double sy = height > 0 ? (double)height / in.h : 1e30;
        double scale = sx < sy ? sx : sy;
        if (scale == 1e30) {
            set_err("width or height is required");
            free(in.px);
            return -1;
        }
        dw = (int)llround((double)in.w * scale);
        dh = (int)llround((double)in.h * scale);
        if (dw < 1) dw = 1;
        if (dh < 1) dh = 1;
    }

    lite_image_t out = {0};
    if (resize_rgba(&in, dw, dh, &out) != 0) {
        free(in.px);
        return -1;
    }
    free(in.px);

    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", dst, (long)getpid());
    if (n < 0 || (size_t)n >= sizeof(tmp)) {
        set_err("output path too long: %s", dst);
        free(out.px);
        return -1;
    }

    int rc;
    if (fmt == 0) rc = write_png(tmp, &out);
    else if (fmt == 1) rc = write_jpeg(tmp, &out);
    else rc = write_webp(tmp, &out);
    free(out.px);

    if (rc != 0) {
        unlink(tmp);
        return -1;
    }
    if (rename(tmp, dst) != 0) {
        set_err("rename %s: %s", dst, strerror(errno));
        unlink(tmp);
        return -1;
    }
    return 0;
}
