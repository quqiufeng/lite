-- pdftext: 用系统 libpoppler-glib 抽 PDF 文本（纯 FFI，无需编译、无 pdftotext 子进程）。
-- 依赖：libpoppler-glib.so.8（Debian/Ubuntu poppler-glib8t64）。缺库时报错说明装什么。
-- 手工 cdef 是因为本机没装 poppler 开发头文件，但导出符号稳定（poppler ABI 从 0.5 至今没改名）。
local ffi = ffi or require("ffi")

local LIB_NAMES = { "libpoppler-glib.so.8", "libpoppler-glib.so", "poppler-glib" }
local lib

local function open_lib()
  if lib then return lib end
  for _, name in ipairs(LIB_NAMES) do
    local ok, h = pcall(ffi.load, name)
    if ok then
      ffi.cdef[[
        typedef struct _PopplerDocument PopplerDocument;
        typedef struct _PopplerPage PopplerPage;
        PopplerDocument *poppler_document_new_from_file(const char *uri, const char *password, void **error);
        int poppler_document_get_n_pages(PopplerDocument *doc);
        PopplerPage *poppler_document_get_page(PopplerDocument *doc, int index);
        char *poppler_page_get_text(PopplerPage *page);
        void g_object_unref(void *obj);

        void g_free(void *p);
      ]]
      lib = h
      return h
    end
  end
  error("pdftext: need libpoppler-glib.so.8 (install poppler-utils / libpoppler-glib8)", 0)
end

-- 相对路径按 workspace cwd 补全（env.cwd 优先，其次 LITE_CWD/PWD），再转 file:// URI。
local function uri_path(p, cwd)
  if p:match("^%a[%w+.-]*://") then return p end
  if p:sub(1, 1) ~= "/" then
    cwd = cwd or (rawget(_G, "LITE_CWD")) or os.getenv("PWD") or "."
    p = cwd:gsub("/+$", "") .. "/" .. p
  end
  return "file://" .. p:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", c:byte())
  end)
end

local function extract(path, first, last, max_chars, cwd)
  local L = open_lib()
  local doc = L.poppler_document_new_from_file(uri_path(path, cwd), nil, nil)
  if doc == nil then error("pdftext: cannot open " .. path, 0) end
  local n = L.poppler_document_get_n_pages(doc)
  if n <= 0 then error("pdftext: no pages in " .. path, 0) end
  first = math.max(1, tonumber(first) or 1)
  last = math.min(n, tonumber(last) or n)
  if last < first then error("pdftext: last page < first page", 0) end
  local parts, used, truncated = {}, 0, false
  for i = first - 1, last - 1 do
    local page = L.poppler_document_get_page(doc, i)
    if page ~= nil then
      local txt = L.poppler_page_get_text(page)
      if txt ~= nil then
        local s = ffi.string(txt)
        L.g_free(txt)
        parts[#parts + 1] = string.format("--- page %d ---\n%s", i + 1, s)
        used = used + #s
      end
      L.g_object_unref(page)
    end
    if max_chars and used > max_chars then truncated = true break end
  end
  L.g_object_unref(doc)
  local body = table.concat(parts, "\n")
  if max_chars and #body > max_chars then
    body = body:sub(1, max_chars)
    truncated = true
  end
  return string.format("pages %d-%d / %d\n%s%s", first, last, n, body,
    truncated and "\n[truncated]" or "")
end

return {
  schema = {
    name = "pdftext",
    description = "抽 PDF 文本（libpoppler-glib FFI，无子进程）。返回每页文本，可指定页范围。",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "PDF 路径（相对 cwd 或绝对）" },
        first = { type = "integer", description = "起始页，默认 1" },
        last = { type = "integer", description = "结束页，默认最后一页" },
        max_chars = { type = "integer", description = "文本上限，默认 16000" },
      },
      required = { "path" },
    },
  },
  run = function(args, env)
    return extract(args.path, args.first, args.last, args.max_chars or 16000,
      env and env.cwd or nil)
  end,
}
