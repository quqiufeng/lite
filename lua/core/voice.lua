-- voice.lua -- 常驻语音转文本：ffmpeg 录音 → SenseVoice.cpp 转写 → inbox 行
-- voice.start() 起后台 bash 循环；voice.poll() 取新行；voice.stop() 关。
local M = {}

local function env(k, d)
  local v = os.getenv(k)
  if v and v ~= "" then return v end
  return d
end

function M.cfg()
  return {
    mic    = env("LITE_VOICE_MIC", env("VOICE_MIC_DEV", "default")),
    bin    = env("SENSEVOICE_BIN", "/opt/SenseVoice.cpp/bin/sense-voice-main"),
    model  = env("SENSEVOICE_MODEL", "/data/models/sense-voice-small-q4_k.gguf"),
    lang   = env("SENSEVOICE_LANG", "auto"),   -- auto 可辨 zh/en/yue/ja/ko
    thread = env("SENSEVOICE_THREADS", "4"),
    secs   = tonumber(env("LITE_VOICE_CHUNK", "5")) or 5,
    gate   = tonumber(env("LITE_VOICE_GATE", "-38")) or -38,
  }
end

local function exists(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

function M.available()
  local c = M.cfg()
  if not exists(c.bin) then return false, "缺少 ASR 可执行文件: " .. c.bin end
  if not exists(c.model) then return false, "缺少 ASR 模型: " .. c.model end
  if not exists("/usr/bin/ffmpeg") then return false, "缺少 ffmpeg" end
  return true
end

-- 清洗输出：时间戳 / 语言标记 / 纯标点 / 单字符噪声
function M.clean(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%[%d+%.%d+%-%d+%.%d+%]", " ")
  s = s:gsub("<[^>]->", " ")
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  if not s:find("[%w%z\228-\233]") then return nil end
  local rest = s:gsub("[%p%s%d]", "")
  if #rest < 2 then return nil end
  return s
end

local function script(c, dir)
  return (string.format([==[
#!/bin/bash
cd "%s" || exit 1
while [ ! -f stop ]; do
  rm -f seg.wav
  ffmpeg -hide_banner -loglevel error -f pulse -i "%s" -ar 16000 -ac 1 -t %d -y seg.wav 2>>ff.log
  if [ ! -s seg.wav ]; then echo "rec-fail" >> err.log; sleep 0.3; continue; fi
  rms=$(ffmpeg -hide_banner -i seg.wav -af volumedetect -f null - 2>&1 | awk '/mean_volume/{print $5}' | tail -1)
  if [ -z "$rms" ]; then rms=-99; fi
  if awk -v r="$rms" -v t="%s" 'BEGIN{exit !(r>t+0)}'; then
    out=$("%s" -m "%s" -f seg.wav -l %s -t %s 2>>err.log)
    if [ -n "$out" ]; then
      printf '%%s\n' "$out" >> inbox.txt
    fi
  fi
done
]==], dir, c.mic, c.secs, c.gate, c.bin, c.model, c.lang, c.thread))
end

-- 识别输入框里的语音指令：整行是标记，或标记跟在本轮转写文字后面
function M.command(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "#语音模式" or s:match("%s#语音模式$") then return "toggle" end
  if s == "#退出" or s:match("%s#退出$") then return "off" end
  if s:match("^#退出$") then return "off" end
  return nil
end

-- 起常驻循环；重复 start 幂等
function M.start()
  if M.handle then return true end
  local ok, err = M.available()
  if not ok then return false, err end
  local c = M.cfg()
  local dir = string.format("/tmp/lite-voice-%d", os.time())
  os.execute("mkdir -p " .. dir)
  M.dir = dir
  M.offset = 0
  local sp = dir .. "/loop.sh"
  local f = assert(io.open(sp, "w"))
  f:write(script(c, dir))
  f:close()
  os.remove(dir .. "/stop")
  local cmd = string.format(
    "setsid bash %q < /dev/null > %q 2>&1 & echo $! > %q",
    sp, dir .. "/out.log", dir .. "/pid")
  os.execute(cmd)
  local pf = io.open(dir .. "/pid", "r")
  M.pid = pf and tonumber((pf:read("*l") or ""):match("%d+")) or nil
  if pf then pf:close() end
  M.handle = M.pid or -1
  return true
end

function M.running()
  return M.handle ~= nil
end

function M.stop()
  if not M.dir then M.handle = nil return true end
  local f = io.open(M.dir .. "/stop", "w")
  if f then f:write("1") f:close() end
  if M.pid then os.execute("kill " .. M.pid .. " 2>/dev/null") end
  M.handle, M.pid = nil, nil
  return true
end

-- 取新转写行（不清空已读部分）
function M.poll()
  if not M.dir then return {} end
  local f = io.open(M.dir .. "/inbox.txt", "r")
  if not f then return {} end
  local data = f:read("*a") or ""
  f:close()
  data = data:sub((M.offset or 0) + 1)
  M.offset = (M.offset or 0) + #data
  local out = {}
  for line in data:gmatch("[^\n]+") do
    local t = M.clean(line)
    if t then out[#out + 1] = t end
  end
  return out
end

function M.last_error()
  if not M.dir then return nil end
  local f = io.open(M.dir .. "/err.log", "r")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return s ~= "" and s or nil
end

return M
