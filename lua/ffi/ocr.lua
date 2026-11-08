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

int open(const char *pathname, int flags, unsigned int mode);
int close(int fd);
int dup(int oldfd);
int dup2(int oldfd, int newfd);
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

-- 已知噪声：libocr_simple 无条件尝试 CUDA EP，随包只有 CPU 版 onnxruntime，
-- 这段失败信息是预期内的（见 ready() 里的说明）。只过滤这几类，其余照常输出。
local NOISE = {
    "Failed to load library",
    "Failed to load shared library",
    "CUDA not available",
    "AppendExecutionProvider_Cuda",
    "libonnxruntime_providers_cuda.so",
    "provider_bridge_ort.cc",
    "ONNXRuntimeError",
    "VerifyEachNodeIsAssignedToAnEp",
    "Rerunning with verbose output",
    "tensorrt_execution_provider",
}

local function is_noise(line)
    for _, pat in ipairs(NOISE) do
        if line:find(pat, 1, true) then return true end
    end
    -- ORT 的彩色输出会单独留一行 "^[[1;31m" / "^[[m"
    if line:match("^%[?%[?[%d;]*m$") or line:match("^%[m$") then return true end
    return false
end

-- 临时把 fd 1/2 都指到临时文件，跑 fn，再还原并把非噪声行回放到 stderr。
-- 必须两个都接管：libocr_simple 的诊断走 **stdout**，ORT 自己的日志走 stderr。
local last_capture = ""

local function with_output_filtered(fn)
    local tmp = os.tmpname()
    local fd = ffi.C.open(tmp, 0x242, 420)      -- O_RDWR|O_CREAT|O_TRUNC, 0644
    if fd < 0 then return fn() end
    local saved_out, saved_err = ffi.C.dup(1), ffi.C.dup(2)
    if saved_out < 0 or saved_err < 0 then
        if saved_out >= 0 then ffi.C.close(saved_out) end
        if saved_err >= 0 then ffi.C.close(saved_err) end
        ffi.C.close(fd)
        return fn()
    end
    io.flush()
    ffi.C.dup2(fd, 1)
    ffi.C.dup2(fd, 2)
    local results = { pcall(fn) }
    ffi.C.dup2(saved_out, 1)
    ffi.C.dup2(saved_err, 2)
    ffi.C.close(saved_out)
    ffi.C.close(saved_err)
    ffi.C.close(fd)

    local f = io.open(tmp, "rb")
    local cap = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(tmp)
    last_capture = cap
    for line in (cap .. "\n"):gmatch("(.-)\n") do
        local text = line:gsub("\27%[[%d;]*m", "")
        if text:match("%S") and not is_noise(text) then
            io.stderr:write(text, "\n")
        end
    end
    local unpack = unpack or table.unpack
    return unpack(results)
end

-- 只验证「动态库能不能加载」：ORT 已链接、libocr_simple 的版本符号能解析。
-- 不碰模型文件 —— 否则 dist 不带模型时，ort_link.sh 会把链接误判为失败。
-- 返回 true / false, err。
function M.loadable()
    if lib then return true end
    if not LIB then return false, "libocr_simple.so not found (set LITE_OCR_LIB)" end
    load_ort()
    local ok, h = pcall(ffi.load, LIB)
    if not ok then
        return false, "OCR library not available: " .. tostring(h)
    end
    lib = h
    return true
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
        load_err = "PP-OCRv4 models not found "
            .. "(ocr is optional; set LITE_OCR_MODELS to the models dir)"
        return false, load_err
    end
    -- 三个文件缺一不可。逐个检查，别等到 create 返回 NULL 才给个看不懂的
    -- "cdata<struct ocr_simple_t *>: NULL"。
    local missing = {}
    for _, name in ipairs({ "ch_PP-OCRv4_det_infer.onnx",
                            "ch_PP-OCRv4_rec_infer.onnx",
                            "ppocr_keys_v1.txt" }) do
        local f = io.open(MODELS .. name, "rb")
        if f then f:close() else missing[#missing + 1] = name end
    end
    if #missing > 0 then
        load_err = string.format(
            "PP-OCRv4 models incomplete in %s (missing: %s). "
            .. "ocr is optional — copy the models there or set LITE_OCR_MODELS.",
            MODELS, table.concat(missing, ", "))
        return false, load_err
    end

    load_ort()
    local ok, h = pcall(ffi.load, LIB)
    if not ok then
        load_err = "OCR library not available: " .. tostring(h)
        return false, load_err
    end
    lib = h

    -- libocr_simple.so 无条件尝试 CUDA EP。随包只带 CPU 版 onnxruntime，
    -- 于是每次初始化都往 stderr 打一段红色的
    --   [E:onnxruntime:...] FAIL : Failed to load library .../libonnxruntime_providers_cuda.so
    -- 然后回退 CPU。这条是**预期行为**（我们故意不打包 329MB 的 CUDA provider），
    -- 实测 CUDA 对单张小图反而慢 3 倍（2.4s vs 0.8s），CPU 才是正确默认。
    -- 所以初始化期间临时接管 fd 2，过滤掉这段噪声，其余照常回放。
    local okc, res = with_output_filtered(function()
        return lib.ocr_simple_create(
            MODELS .. "ch_PP-OCRv4_det_infer.onnx",
            MODELS .. "ch_PP-OCRv4_rec_infer.onnx",
            MODELS .. "ppocr_keys_v1.txt")
    end)
    if not okc or res == nil then
        load_err = "OCR init failed (models/onnxruntime): " .. tostring(res)
        return false, load_err
    end
    -- 后端状态按实测日志决定（libocr_simple 会打 "CUDA enabled" 或
    -- "CUDA not available, using CPU"）。不写死，否则 tools/cuda_provider.sh
    -- 链接 CUDA 之后这行就是错的。
    if last_capture:find("CUDA enabled", 1, true) then
        io.stderr:write("[OCR] backend: CUDA\n")
    else
        io.stderr:write("[OCR] backend: CPU "
            .. "(CUDA provider not linked; single images are faster on CPU)\n")
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

-- libocr 把识别文本原样拼进 JSON，文本里的裸引号（如 `*"`）会让整串非法。
-- cjson 失败时按对象逐个捞回：每块的前缀固定是 `{"x":N,"y":N,"w":N,"h":N,"text":"`，
-- 块尾是 `"}`，块间以 `,{"x":` 分隔。
local function salvage(s)
    local out = {}
    local body = s:match("^%s*%[(.*)%]%s*$") or s
    local pos = 1
    while true do
        local _, after, x, y, w, h = body:find('"x":(%d+),"y":(%d+),"w":(%d+),"h":(%d+),"text":"', pos)
        if not x then break end
        local nxt = body:find(',{"x":', after + 1, true)
        local seg = body:sub(after + 1, (nxt or #body + 1) - 1)
        local text = seg:match('^(.-)"%s*%}%s*$')
        if text then
            out[#out + 1] = {
                x = tonumber(x), y = tonumber(y),
                w = tonumber(w), h = tonumber(h), text = text,
            }
        end
        if not nxt then break end
        pos = nxt
    end
    return out
end

local function decode(s)
    if not s or s == "" then return {} end
    s = Text.sanitize(s)
    local ok, res = pcall(cjson.decode, s)
    if ok and type(res) == "table" then return res end
    local clean = s:gsub("[%z\1-\8\11\12\14-\31]", " ")
    ok, res = pcall(cjson.decode, clean)
    if ok and type(res) == "table" then return res end
    return salvage(clean)
end

M.parse = decode

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
