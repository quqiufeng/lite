-- PP-OCRv4 FFI（libocr_simple.so + ONNX Runtime）。
local ffi = require("ffi")
local cjson = require("cjson")
local Text = require("core.text")

ffi.cdef[[
typedef struct ocr_simple_t ocr_simple_t;
ocr_simple_t *ocr_simple_create(const char *det, const char *rec, const char *dict);
char *ocr_simple_run(ocr_simple_t *h, const char *image_path);
void ocr_simple_free(char *s);
void ocr_simple_destroy(ocr_simple_t *h);
]]

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

local ROOT = (os.getenv("LITE_ROOT") or "."):gsub("/+$", "")

local function first_file(paths)
    for _, path in ipairs(paths) do
        if path then
            local f = io.open(path, "rb")
            if f then f:close(); return path end
        end
    end
    return nil
end

local LIB = env("LITE_OCR_LIB") or first_file({
    ROOT .. "/lib/libocr_simple.so",
    ROOT .. "/third_party/ocr/lib/libocr_simple.so",
    "/usr/lib/libocr_simple.so",
    "/usr/local/lib/libocr_simple.so",
})

local MODELS = env("LITE_OCR_MODELS")
if not MODELS then
    MODELS = first_file({
        ROOT .. "/models/ocr/ch_PP-OCRv4_det_infer.onnx",
        ROOT .. "/third_party/ocr/models/ocr/ch_PP-OCRv4_det_infer.onnx",
    })
    if MODELS then MODELS = MODELS:match("^(.*)/[^/]+$") .. "/" end
end

local ORT_CANDIDATES = {
    env("LITE_ORT") or "",
    ROOT .. "/lib/libonnxruntime.so.1",
    ROOT .. "/third_party/ocr/lib/libonnxruntime.so.1",
    "/usr/local/lib/libonnxruntime.so.1",
    "/usr/lib/libonnxruntime.so.1",
}

local M = {}
local lib, handle, load_err, tried

local function load_ort()
    for _, path in ipairs(ORT_CANDIDATES) do
        if path and path ~= "" then
            local f = io.open(path, "rb")
            if f then
                f:close()
                local ok = pcall(ffi.load, path, true)
                if ok then return true end
            end
        end
    end
    return false
end

function M.ready()
    if handle then return true end
    if tried then return false, load_err end
    tried = true

    if not LIB then
        load_err = "libocr_simple.so not found (set LITE_OCR_LIB)"
        return false, load_err
    end
    if not MODELS then
        load_err = "PP-OCRv4 models not found (set LITE_OCR_MODELS)"
        return false, load_err
    end

    load_ort()
    local ok, h = pcall(ffi.load, LIB)
    if not ok then
        load_err = "OCR library not available: " .. tostring(h)
        return false, load_err
    end
    lib = h

    local okc, res = pcall(lib.ocr_simple_create,
        MODELS .. "ch_PP-OCRv4_det_infer.onnx",
        MODELS .. "ch_PP-OCRv4_rec_infer.onnx",
        MODELS .. "ppocr_keys_v1.txt")
    if not okc or res == nil then
        load_err = "OCR init failed (models/onnxruntime): " .. tostring(res)
        return false, load_err
    end
    handle = res
    return true
end
function M.raw(path)
    local ready, err = M.ready()
    if not ready then return nil, err end
    local ptr = lib.ocr_simple_run(handle, path)
    if ptr == nil then return nil, "OCR run failed" end
    local s = ffi.string(ptr)
    lib.ocr_simple_free(ptr)
    return s
end

local function decode(s)
    if not s or s == "" then return {} end
    s = Text.sanitize(s)
    local ok, res = pcall(cjson.decode, s)
    if ok and type(res) == "table" then return res end
    local clean = s:gsub("[%z\1-\8\11\12\14-\31]", " ")
    ok, res = pcall(cjson.decode, clean)
    return ok and type(res) == "table" and res or {}
end

function M.run(path)
    local raw, err = M.raw(path)
    if not raw then return {}, err end
    return decode(raw)
end

function M.text(path)
    local boxes, err = M.run(path)
    if err then return "", {}, err end
    table.sort(boxes, function(a, b)
        local ay, by = tonumber(a.y) or 0, tonumber(b.y) or 0
        if math.abs(ay - by) > 6 then return ay < by end
        return (tonumber(a.x) or 0) < (tonumber(b.x) or 0)
    end)
    local parts = {}
    for _, b in ipairs(boxes) do
        local t = tostring(b.text or "")
        if t ~= "" then parts[#parts + 1] = t end
    end
    return table.concat(parts, " "), boxes
end

return M
