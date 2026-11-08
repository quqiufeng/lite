-- voice.lua -- 常驻语音转文本：ffmpeg 录音 → SenseVoice.cpp 转写 → inbox 行
-- voice.start() 起后台 bash 循环；voice.poll() 取新行；voice.stop() 关。
local M = {}

local function env(k, d)
  local v = os.getenv(k)
  if v and v ~= "" then return v end
  return d
end

-- 分段是自适应的（VAD 在前台 bash 里逐帧做）：说完一段静音 LITE_VOICE_TAIL 秒
-- 才收尾转写，所以一句话说完前不会被打断；LITE_VOICE_CHUNK 只是单段上限。
function M.cfg()
  local c = {
    mic    = env("LITE_VOICE_MIC", env("VOICE_MIC_DEV", "default")),
    bin    = env("SENSEVOICE_BIN", "/opt/SenseVoice.cpp/bin/sense-voice-main"),
    model  = env("SENSEVOICE_MODEL", "/data/models/sense-voice-small-q4_k.gguf"),
    lang   = env("SENSEVOICE_LANG", "auto"),   -- auto 可辨 zh/en/yue/ja/ko
    thread = env("SENSEVOICE_THREADS", "4"),
    secs   = tonumber(env("LITE_VOICE_CHUNK", "20")) or 20,   -- 单段最长秒数
    gate   = tonumber(env("LITE_VOICE_GATE", "-38")) or -38,
    tail   = tonumber(env("LITE_VOICE_TAIL", "1.5")) or 1.5,  -- 尾静音多少秒收一段
    minlen = tonumber(env("LITE_VOICE_MIN", "2")) or 2,       -- 单段最短秒数
  }
  local frame = 0.5                       -- 逐帧判定粒度：0.5s
  c.frame = frame
  c.tailf = math.max(1, math.ceil(c.tail / frame))
  c.minf  = math.max(1, math.ceil(c.minlen / frame))
  c.maxf  = math.max(c.minf + 1, math.ceil(c.secs / frame))
  -- dB 门限换算成 s16 满量程 32768 下的 RMS 振幅
  c.thr = math.max(1, math.floor(32768 * 10 ^ (c.gate / 20)))
  return c
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

-- 逐帧 VAD 分段：ffmpeg 持续出 16k/mono/s16le 裸流 → 每 0.5s 一帧算 RMS →
-- 有声帧攒进 seg.pcm，尾静音满 tailf 帧才收尾；短于 minf 帧的碎片直接丢，
-- 连续说到 maxf 帧强制切。转写在后台并发（最多 2 个），不堵录音管道。
local function script(c, dir)
  return (string.format([==[
#!/bin/bash
cd "%s" || exit 1
FR=16000            # 0.5s s16le 16k mono
TAIL=%d
MINF=%d
MAXF=%d
THR=%d
n=0; active=0; len=0; sil=0
rm -f seg.pcm frame.pcm seg.*.pcm seg.*.wav

flush() {
  local f="seg.$n"
  active=0; len=0; sil=0
  if [ ! -s seg.pcm ]; then return; fi
  mv -f seg.pcm "$f.pcm"
  n=$((n+1))
  while [ "$(jobs -rp | wc -l)" -ge 2 ]; do wait -n 2>/dev/null || break; done
  (
    if ffmpeg -nostdin -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i "$f.pcm" -y "$f.wav" 2>>err.log < /dev/null; then
      out=$("%s" -m "%s" -f "$f.wav" -l %s -t %s 2>>err.log < /dev/null)
      [ -n "$out" ] && printf '%%s\n' "$out" >> inbox.txt
    else
      echo "conv-fail" >> err.log
    fi
    rm -f "$f.pcm" "$f.wav"
  ) &
}

while [ ! -f stop ]; do
  if ! dd of=frame.pcm bs=$FR count=1 iflag=fullblock 2>/dev/null; then break; fi
  if [ "$(stat -c %%s frame.pcm)" -lt $FR ]; then break; fi
  r=$(od -An -v -td2 frame.pcm | awk '{for(i=1;i<=NF;i++){v=$i; s+=v*v; k++}} END{printf "%%d", (k?sqrt(s/k):0)}')
  if [ "${r:-0}" -lt $THR ]; then
    if [ $active -eq 1 ]; then
      cat frame.pcm >> seg.pcm
      len=$((len+1)); sil=$((sil+1))
      if [ $sil -ge $TAIL ]; then
        if [ $len -ge $MINF ]; then flush; else active=0; len=0; sil=0; rm -f seg.pcm; fi
      fi
    fi
  else
    if [ $active -eq 0 ]; then active=1; len=0; sil=0; rm -f seg.pcm; fi
    cat frame.pcm >> seg.pcm
    len=$((len+1)); sil=0
    if [ $len -ge $MAXF ]; then flush; fi
  fi
done < <(ffmpeg -nostdin -hide_banner -loglevel error -f pulse -i "%s" -ar 16000 -ac 1 -f s16le pipe:1 2>>ff.log)
if [ $active -eq 1 ] && [ $len -ge $MINF ]; then flush; fi
wait
]==], dir, c.tailf, c.minf, c.maxf, c.thr, c.bin, c.model, c.lang, c.thread, c.mic))
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
  -- 外部(插件等)停语音时通知 UI 同步状态,避免 TUI 以为还在听
  if M.on_stop then pcall(M.on_stop) end
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
