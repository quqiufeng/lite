-- 初始化页（盒子没有 API key 时用）：绑一个端口发一张网页，填 key 落盘到
-- ~/.config/lite/.env（0600），立刻能被 `lite serve` / TUI 读到。
--
--   GET  /  /index.html   自包含 HTML5 表单（不引 CDN：没 key 的盒子不一定有网）
--   GET  /api/state       {ok,configured,masked,host,version} 供页面回显
--   POST /api/key         {"key":"sk-…","model":"deepseek-flash"} → 校验+验活+写盘
--
-- 刻意保持「一个连接一个请求、Connection: close、单线程 poll」：配置页只服务
-- 头几分钟，不需要并发；连不上的客户端靠 deadline 收掉，不留后台线程。
local ffi = require("ffi")
local bit = require("bit")
local cjson = require("cjson")
local net = require("core.net")
local http = require("core.serve_http")

ffi.cdef[[
int chmod(const char *path, unsigned int mode);
int mkdir(const char *path, unsigned int mode);
]]

local M = {}

M.VERSION = "0.1.0"
M.DEFAULT_PORT = 8080
-- 默认 0.0.0.0：盒子没有显示器，配置页必须能从别的机器打开。
M.DEFAULT_HOST = "0.0.0.0"
M.MAX_BODY = 8192
M.MAX_CONN_SECONDS = 20

local function home_dir()
    return os.getenv("HOME") or "/"
end

function M.env_path(home)
    return (home or home_dir()):gsub("/+$", "") .. "/.config/lite/.env"
end

-- 页脚显示「你连的是哪台机器」：盒子上的 hostname 比 IP 更有辨识度。
function M.hostname()
    local f = io.open("/etc/hostname", "r")
    if f then
        local s = f:read("*l")
        f:close()
        if s and s:match("%S") then return (s:gsub("%s+$", "")) end
    end
    return os.getenv("HOST") or "lite"
end

-- ---------------------------------------------------------------- .env 读写

local function parse_dotenv(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k then out[k] = (v:gsub("^(['\"])(.-)%1$", "%2")) end
        end
    end
    return out
end

function M.read_key(path)
    local f = io.open(path or M.env_path(), "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local v = parse_dotenv(text)["DEEPSEEK_API_KEY"]
    if v and v ~= "" then return v end
    return nil
end

-- 只露头尾：配置页要给「已配置」的反馈，但不能把 key 明文写进 HTML/日志。
function M.mask(key)
    key = tostring(key or "")
    if #key <= 10 then return string.rep("•", #key) end
    -- 圆点上限 8：这串会进 HTML 占位符，16 个点在手机输入框里会被切掉尾巴
    return key:sub(1, 6) .. string.rep("•", math.min(#key - 10, 8)) .. key:sub(-4)
end

-- 合并写：保留 .env 里别的行（顺序不动），同名键就地替换，新键追加在尾部。
-- 先写 .tmp 再 rename，0600 —— 中途断电也不会留下半截 key。
function M.write_kv(path, kv, opts)
    path = path or M.env_path()
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then ffi.C.mkdir(dir, 0x1C0) end -- 0700，已存在返回 EEXIST 无所谓

    local lines, seen = {}, {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local k = line:match("^%s*([%w_]+)%s*=")
            if k and kv[k] ~= nil and not seen[k] then
                lines[#lines + 1] = k .. "=" .. tostring(kv[k])
                seen[k] = true
            elseif k and kv[k] == nil then
                lines[#lines + 1] = line
                seen[k] = true
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    local order = opts and opts.order or {}
    for _, k in ipairs(order) do
        if kv[k] ~= nil and not seen[k] then
            lines[#lines + 1] = k .. "=" .. tostring(kv[k])
            seen[k] = true
        end
    end
    for k, v in pairs(kv) do
        if not seen[k] then lines[#lines + 1] = k .. "=" .. tostring(v) end
    end

    local tmp = path .. ".tmp"
    local out, err = io.open(tmp, "w")
    if not out then return false, "write " .. tmp .. ": " .. tostring(err) end
    out:write(table.concat(lines, "\n"), "\n")
    out:close()
    ffi.C.chmod(tmp, 0x180) -- 0600
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, "rename " .. tmp .. " -> " .. path .. ": " .. tostring(rerr)
    end
    return true
end

-- ---------------------------------------------------------------- key 校验

-- 只做本地形状检查（真伪交给网络验活）：DeepSeek 的 key 形如 sk-<32 hex/base64ish>。
function M.validate_key(key)
    key = tostring(key or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if key == "" then return nil, "请填写 API Key" end
    if #key < 16 then return nil, "Key 太短（应形如 sk-…）" end
    if #key > 200 then return nil, "Key 太长（>200 字符）" end
    if not key:match("^[%w%-%_%.]+$") then return nil, "Key 含非法字符（只允许字母数字 - _ .）" end
    if key:sub(1, 3) ~= "sk-" then return nil, "DeepSeek 的 Key 以 sk- 开头" end
    return key
end

-- 打 /user/balance 验活：比 /models 更能一次说清「key 有效 + 有余额」。
-- 返回 ok, info；info = {balance=…, currency=…, available=…} 或错误文案。
function M.verify_key(key, base_url, timeout)
    base_url = (base_url or "https://api.deepseek.com"):gsub("/+$", "")
    local rc, code, body = http.get(base_url .. "/user/balance",
        { "Authorization: Bearer " .. key, "Accept: application/json" }, 65536, timeout or 15)
    if rc ~= 0 then return false, "网络不通：" .. tostring(body) end
    if code == 401 then return false, "Key 无效（HTTP 401）" end
    if code == 403 then return false, "Key 被禁用（HTTP 403）" end
    if code ~= 200 then
        return false, "验活失败（HTTP " .. tostring(code) .. "）" .. tostring(body):sub(1, 120)
    end
    local ok, obj = pcall(cjson.decode, body or "")
    if not ok or type(obj) ~= "table" then
        return true, { available = true } -- 网关回了 200 但不是预期 JSON：当验活通过
    end
    local info = { available = obj.is_available ~= false }
    local b = type(obj.balance_infos) == "table" and obj.balance_infos[1] or nil
    if type(b) == "table" then
        info.balance = tostring(b.total_balance or "?")
        info.currency = tostring(b.currency or "")
    end
    return true, info
end

-- ---------------------------------------------------------------- 页面

local PAGE = [==[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0f1115">
<title>lite 初始化 · @@HOST@@</title>
<style>
  :root{
    --bg:#0d1014; --card:rgba(24,28,35,.86); --line:rgba(255,255,255,.09);
    --txt:#e8ecf3; --dim:#93a0b4; --accent:#4f8cff; --accent2:#7c5cff;
    --ok:#2fbf71; --err:#ff5d5d; --radius:18px;
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{
    margin:0; color:var(--txt); background:var(--bg);
    font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans SC","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
    display:flex; align-items:center; justify-content:center; padding:24px 16px;
    -webkit-text-size-adjust:100%;
  }
  body::before{
    content:""; position:fixed; inset:-20%; z-index:-1;
    background:
      radial-gradient(46% 38% at 18% 12%, rgba(79,140,255,.30), transparent 65%),
      radial-gradient(42% 40% at 82% 8%, rgba(124,92,255,.26), transparent 68%),
      radial-gradient(52% 46% at 60% 100%, rgba(47,191,113,.14), transparent 70%);
    filter:blur(8px);
  }
  .card{
    width:100%; max-width:560px; background:var(--card); border:1px solid var(--line);
    border-radius:var(--radius); padding:34px 32px 28px;
    box-shadow:0 24px 70px rgba(0,0,0,.55), inset 0 1px 0 rgba(255,255,255,.05);
    backdrop-filter:blur(14px); -webkit-backdrop-filter:blur(14px);
  }
  .brand{display:flex; align-items:center; gap:12px; margin-bottom:22px}
  .logo{
    width:42px;height:42px;border-radius:13px;display:grid;place-items:center;
    background:linear-gradient(140deg,var(--accent),var(--accent2));
    box-shadow:0 8px 24px rgba(79,140,255,.42); font-weight:700; font-size:19px; color:#fff;
  }
  h1{font-size:20px; margin:0; letter-spacing:.2px}
  .sub{color:var(--dim); font-size:13px; margin-top:2px}
  .badge{
    margin-left:auto; font-size:12px; padding:5px 11px; border-radius:999px;
    border:1px solid var(--line); color:var(--dim); white-space:nowrap;
  }
  .badge.on{color:#8ff0bb; border-color:rgba(47,191,113,.5); background:rgba(47,191,113,.12)}
  .badge.off{color:#ffb4b4; border-color:rgba(255,93,93,.42); background:rgba(255,93,93,.10)}
  label{display:block; font-size:13px; color:var(--dim); margin:18px 0 8px}
  label .hint{float:right; color:#6f7c90; font-size:12px}
  .tip{margin-top:8px; font-size:12px; line-height:1.5; color:#6f7c90}
  /* 不用 flex：手机窄屏下 flex 项会按内容塌成一小截，宽度交给块级 + width:100% 最稳 */
  .field{position:relative; width:100%}
  input[type=password],input[type=text],select{
    display:block; width:100%; padding:13px 46px 13px 14px; color:var(--txt);
    background:rgba(9,12,17,.72); border:1px solid var(--line); border-radius:12px;
    font:inherit; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:14px;
    transition:border-color .15s, box-shadow .15s;
  }
  select{font-family:inherit; padding-right:14px; appearance:none;
    background-image:linear-gradient(45deg,transparent 50%,var(--dim) 50%),linear-gradient(135deg,var(--dim) 50%,transparent 50%);
    background-position:calc(100% - 19px) 51%,calc(100% - 14px) 51%;
    background-size:5px 5px,5px 5px; background-repeat:no-repeat;}
  input:focus,select:focus{outline:none; border-color:rgba(79,140,255,.85); box-shadow:0 0 0 4px rgba(79,140,255,.16)}
  .eye{
    position:absolute; right:8px; top:50%; transform:translateY(-50%);
    width:34px; height:34px; border:0; border-radius:9px;
    background:transparent; color:var(--dim); cursor:pointer; font-size:15px; line-height:1;
  }
  .eye:hover{background:rgba(255,255,255,.07); color:var(--txt)}
  .row{display:flex; gap:10px; margin-top:24px}
  button.primary{
    flex:1; padding:14px 18px; border:0; border-radius:12px; cursor:pointer;
    font:600 15px/1 inherit; color:#fff;
    background:linear-gradient(140deg,var(--accent),var(--accent2));
    box-shadow:0 10px 26px rgba(79,140,255,.34); transition:transform .12s, filter .15s;
  }
  button.primary:hover{filter:brightness(1.07)}
  button.primary:active{transform:translateY(1px)}
  button.primary[disabled]{opacity:.6; cursor:default; transform:none}
  button.ghost{
    padding:14px 16px; border-radius:12px; cursor:pointer; font:500 14px/1 inherit;
    color:var(--dim); background:transparent; border:1px solid var(--line);
  }
  button.ghost:hover{color:var(--txt); border-color:rgba(255,255,255,.22)}
  .msg{margin-top:16px; padding:12px 14px; border-radius:12px; font-size:13.5px; display:none; white-space:pre-wrap; word-break:break-word}
  .msg.show{display:block}
  .msg.ok{color:#a8f0c6; background:rgba(47,191,113,.12); border:1px solid rgba(47,191,113,.4)}
  .msg.err{color:#ffc0c0; background:rgba(255,93,93,.10); border:1px solid rgba(255,93,93,.36)}
  .msg.busy{color:#c3d4ff; background:rgba(79,140,255,.10); border:1px solid rgba(79,140,255,.34)}
  ol.steps{margin:24px 0 0; padding-left:18px; color:var(--dim); font-size:13px}
  ol.steps li{margin:7px 0}
  code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:12.5px; color:#cbd6e8;
    background:rgba(255,255,255,.06); padding:2px 6px; border-radius:6px}
  footer{margin-top:22px; padding-top:16px; border-top:1px solid var(--line); color:#66748a; font-size:12px;
    display:flex; justify-content:space-between; gap:10px; flex-wrap:wrap}
  @media (max-width:480px){
    body{padding:14px 12px}
    .card{padding:24px 18px 20px; border-radius:16px}
    h1{font-size:18px} .logo{width:36px;height:36px;border-radius:11px;font-size:16px}
    .badge{display:none} .row{flex-direction:column}
    /* 手机上 hint 别跟标题抢一行，掉到标签下面去；16px 免得 iOS 聚焦时自动放大 */
    label .hint{float:none; display:block; margin-top:3px}
    input[type=password],input[type=text],select{font-size:16px}
  }
</style>
</head>
<body>
<main class="card">
  <div class="brand">
    <div class="logo">l</div>
    <div>
      <h1>lite 初始化</h1>
      <div class="sub">填写 DeepSeek API Key，发给 <b>@@HOST@@</b></div>
    </div>
    <div class="badge @@BADGE_CLASS@@" id="badge">@@BADGE@@</div>
  </div>

  <form id="form" autocomplete="off">
    <label for="key">DeepSeek API Key
      <span class="hint">在 platform.deepseek.com → API keys 创建</span>
    </label>
    <div class="field">
      <input id="key" name="key" type="password" inputmode="text" spellcheck="false"
             placeholder="粘贴 sk- 开头的 Key" autofocus>
      <button class="eye" type="button" id="eye" title="显示/隐藏" aria-label="显示或隐藏">👁</button>
    </div>
    <div class="tip" id="tip" style="display:none">已保存的 Key 不会回显；要换就直接填新的，提交后覆盖旧的。</div>

    <label for="model">模型</label>
    <select id="model" name="model">
      <option value="deepseek-flash">deepseek-flash（默认，快）</option>
      <option value="deepseek-chat">deepseek-chat</option>
      <option value="deepseek-reasoner">deepseek-reasoner（推理）</option>
    </select>

    <div class="row">
      <button class="primary" type="submit" id="save">测试并保存</button>
      <button class="ghost" type="button" id="paste">粘贴</button>
    </div>
  </form>

  <div class="msg" id="msg"></div>

  <ol class="steps">
    <li>保存后 Key 写入 <code>~/.config/lite/.env</code>（权限 0600），不会回显给你。</li>
    <li>盒子上的 lite 会自动读到它，无需重启系统服务。</li>
    <li>想换 Key 直接回到本页重填，旧的会被覆盖。</li>
  </ol>

  <footer>
    <span>lite setup · v@@VERSION@@</span>
    <span>@@HOSTNAME@@</span>
  </footer>
</main>
<script>
(function(){
  var form = document.getElementById('form');
  var input = document.getElementById('key');
  var save = document.getElementById('save');
  var msg = document.getElementById('msg');
  var badge = document.getElementById('badge');
  var eye = document.getElementById('eye');
  var paste = document.getElementById('paste');

  function show(kind, text){
    msg.className = 'msg show ' + kind;
    msg.textContent = text;
  }
  function hide(){ msg.className = 'msg'; msg.textContent = ''; }

  eye.addEventListener('click', function(){
    input.type = input.type === 'password' ? 'text' : 'password';
    input.focus();
  });
  paste.addEventListener('click', async function(){
    try {
      var t = await navigator.clipboard.readText();
      if (t) { input.value = t.trim(); hide(); input.focus(); }
    } catch (e) {
      show('busy', '浏览器不允许读剪贴板，请手动粘贴（Ctrl+V / 长按粘贴）。');
    }
  });

  form.addEventListener('submit', function(ev){
    ev.preventDefault();
    var key = (input.value || '').trim();
    if (!key) { show('err', '请先填写 API Key。'); input.focus(); return; }
    save.disabled = true;
    save.textContent = '验证中…';
    show('busy', '正在向 DeepSeek 验活并保存…');
    fetch('/api/key', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({key: key, model: document.getElementById('model').value})
    }).then(function(r){ return r.text().then(function(t){
        try { return {status: r.status, body: JSON.parse(t)}; }
        catch(e){ return {status: r.status, body: {ok:false, error:{message: t.slice(0,200)}}}; }
      }); })
      .then(function(res){
        var b = res.body || {};
        if (res.status === 200 && b.ok) {
          var extra = '';
          if (b.balance) extra = '余额 ' + b.balance + ' ' + (b.currency || '');
          show('ok', '✅ 已保存到 ' + (b.path || '~/.config/lite/.env') + (extra ? '（' + extra + '）' : '') + '\n现在可以在盒子上跑 lite 了。');
          badge.className = 'badge on';
          badge.textContent = '已配置';
          input.value = '';
        } else {
          var m = (b.error && b.error.message) || ('保存失败（HTTP ' + res.status + '）');
          show('err', '❌ ' + m);
        }
      })
      .catch(function(e){ show('err', '❌ 请求失败：' + e); })
      .then(function(){
        save.disabled = false;
        save.textContent = '测试并保存';
      });
  });

  fetch('/api/state').then(function(r){ return r.json(); }).then(function(s){
    if (s && s.configured) {
      badge.className = 'badge on';
      badge.textContent = '已配置';
      /* 占位符只留掩码：手机上输入框 ~300px，再多几个字就被切掉尾巴 */
      input.placeholder = s.masked || '已配置';
      document.getElementById('tip').style.display = 'block';
    }
  }).catch(function(){});
})();
</script>
</body>
</html>
]==]

local function html_escape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

-- 页面渲染（纯函数，单测直接调）。state.configured 决定徽标颜色。
function M.page(state)
    state = state or {}
    local configured = state.configured and true or false
    local out = PAGE
    local function put(token, value)
        out = out:gsub(token, function() return value end)
    end
    put("@@HOST@@", html_escape(state.host or "lite"))
    put("@@VERSION@@", html_escape(M.VERSION))
    put("@@HOSTNAME@@", html_escape(state.hostname or ""))
    put("@@BADGE_CLASS@@", configured and "on" or "off")
    put("@@BADGE@@", configured and "已配置" or "未配置")
    return out
end

-- ---------------------------------------------------------------- 路由（纯函数）

local function decode_form(body)
    local out = {}
    for k, v in tostring(body or ""):gmatch("([%w_%-%.]+)=([^&]*)") do
        v = v:gsub("+", " "):gsub("%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)
        out[k] = v
    end
    return out
end

-- req: serve_http.parse 的返回值；ctx: {env_path, base_url, verify, host, hostname, state()}
-- 返回完整的 HTTP 响应字符串。
function M.route(req, ctx)
    ctx = ctx or {}
    local env_path = ctx.env_path or M.env_path()
    local method, path = req.method, req.path

    if path == "/api/state" then
        local key = M.read_key(env_path)
        return http.json(200, {
            ok = true, configured = key ~= nil,
            masked = key and M.mask(key) or nil,
            host = ctx.host, version = M.VERSION,
            hostname = ctx.hostname,
        })
    end

    if path == "/api/key" then
        if method ~= "POST" then
            return http.error(405, "use POST", "method_not_allowed")
        end
        if #(req.body or "") > M.MAX_BODY then
            return http.error(413, "body too large", "too_large")
        end
        local body = req.body or ""
        local key, model
        local okj, obj = pcall(cjson.decode, body)
        if okj and type(obj) == "table" then
            key, model = obj.key, obj.model
        else
            local form = decode_form(body)
            key, model = form.key, form.model
        end
        local k, verr = M.validate_key(key)
        if not k then return http.error(400, verr, "bad_key") end

        local info = {}
        if ctx.verify ~= false then
            local vok, detail = M.verify_key(k, ctx.base_url or "https://api.deepseek.com")
            if not vok then
                return http.json(400, { ok = false, error = { message = detail, code = "invalid_key" } })
            end
            info = detail or {}
        end

        local kv = { DEEPSEEK_API_KEY = k }
        local order = { "DEEPSEEK_API_KEY" }
        if type(model) == "string" and model:match("^[%w%-_%.]+$") and model ~= "" then
            kv.DEEPSEEK_MODEL = model
            order[#order + 1] = "DEEPSEEK_MODEL"
        end
        local wok, werr = M.write_kv(env_path, kv, { order = order })
        if not wok then
            return http.error(500, "写配置失败：" .. tostring(werr), "write_failed")
        end
        return http.json(200, {
            ok = true, path = env_path, masked = M.mask(k),
            balance = info.balance, currency = info.currency,
            available = info.available,
        })
    end

    if path == "/" or path == "/index.html" or path == "/index.htm" then
        if method ~= "GET" and method ~= "HEAD" then
            return http.error(405, "use GET", "method_not_allowed")
        end
        local key = M.read_key(env_path)
        local body = M.page({
            configured = key ~= nil, masked = key and M.mask(key),
            host = ctx.host, hostname = ctx.hostname,
        })
        if method == "HEAD" then body = "" end
        return http.response(200, {
            ["Content-Type"] = "text/html; charset=utf-8",
            ["X-Content-Type-Options"] = "nosniff",
        }, body)
    end

    if path == "/api/health" or path == "/health" then
        return http.json(200, { ok = true, version = M.VERSION })
    end

    return http.error(404, "no such page: " .. tostring(path), "not_found")
end

-- ---------------------------------------------------------------- 服务器

-- 收一个完整请求（或超时/超长就放弃）。fd 是非阻塞的：先读，读空了再等。
-- 超时用 os.time()（墙钟）而不是 os.clock()（CPU 时间）——配置页常年空闲，
-- CPU 时间根本走不动，拿它当 deadline 等于永远不超时。
local function read_request(fd)
    local buf = ""
    local deadline = os.time() + M.MAX_CONN_SECONDS
    while os.time() <= deadline do
        local chunk, err = net.recv(fd)
        if chunk then
            buf = buf .. chunk
            if #buf > M.MAX_BODY + 16384 then return nil, "bad: request too large" end
            local req, perr = http.parse(buf)
            if req then return req end
            if perr ~= "more" then return nil, perr end
        elseif err == "closed" then
            return nil, "bad: closed"
        elseif err ~= "again" then
            return nil, "bad: " .. tostring(err)
        end
        net.poll({ fd }, 120)
    end
    return nil, "bad: timeout"
end

-- opts: {host, port, once, verify, base_url, on_ready(host,port), max_seconds, stop()}
function M.run(opts)
    opts = opts or {}
    local host = opts.host or M.DEFAULT_HOST
    local port = tonumber(opts.port) or M.DEFAULT_PORT
    local srv, err = net.listen(host, port)
    if not srv then return nil, err end

    local env_path = opts.env_path or M.env_path()
    local ctx = {
        env_path = env_path,
        base_url = opts.base_url or os.getenv("DEEPSEEK_BASE_URL"),
        verify = opts.verify,
        host = host .. ":" .. tostring(srv.port),
        hostname = opts.hostname,
    }
    if opts.on_ready then opts.on_ready(srv) end

    local started = os.time()
    local served = 0
    while true do
        if opts.stop and opts.stop() then break end
        if opts.max_seconds and os.time() - started >= opts.max_seconds then break end

        local rc, revents = net.poll({ srv.fd }, 200)
        if rc and rc > 0 and bit.band(revents[1], 1) ~= 0 then
            local fd = net.accept(srv)
            if fd then
                local req, perr = read_request(fd)
                if req then
                    local ok, resp = pcall(M.route, req, ctx)
                    if not ok then
                        resp = http.error(500, "internal: " .. tostring(resp), "internal")
                    end
                    net.send(fd, resp)
                else
                    net.send(fd, http.error(400, tostring(perr), "bad_request"))
                end
                net.close(fd)
                served = served + 1
                if opts.on_request then
                    local okc, cerr = pcall(opts.on_request, req, served)
                    if not okc then err = cerr end
                end
            end
        end
    end
    net.close(srv.fd)
    return true, { served = served, port = srv.port, env_path = env_path }
end

return M
