-- T4 端：山體施工派發。兩台以上的無人機各自一份施工清單 (mountain_cols_<通道>.txt)，
-- 一批一批送 (每批 BATCH 欄)，無人機蓋完整批才回報一次 (連接卡每則約耗 100 點電，不能每欄回報)。
-- 進度存在 mountain_progress.txt：每個通道一行「通道 已完成欄數 檔案位移」，斷線 / 沒電後 resume 接著蓋。
-- 清單由 mountain/mountain.py --drones 2 --tags AC 產生，放在這台 T4 的目前目錄。
local component = require("component")
local event = require("event")
local modem = component.modem

local SERVER_PORT = 100
modem.open(SERVER_PORT)

-- ────────── 設定 ──────────
local TAGS = { "B", "C" }          -- 要出動的通道 (中繼 server.lua 的 TUNNEL_POOL 要有)
local BATCH = 40                   -- 每批欄數：每批 ≈ 1 KB，遠低於封包上限 8192
local CRUISE = 203                 -- 巡航高度上限 (山最高頂面 + 3)；mountain.py 會印出「無人機巡航高度至少 Y=」
local MIN_CRUISE = 110                -- 巡航高度下限：湖和其他既有建築的高度；動態巡航不會低於這個
local MARGIN = 6                      -- 巡航比「已蓋最高頂面」/ 既有地形再高幾格
local SCAN_FILE = "scan.txt"          -- 掃描檔 (每行 bx bz top)；有的話，既有地形 (樹、山) 高過已蓋的部分也會避開
local BASE_TOP = 82                   -- 第 1 層方塊頂面的 Y；h 層的頂面 = BASE_TOP + h - 1
local PROGRESS = "mountain_progress.txt"
local function failfile(tag) return "mountain_failed_" .. tag .. ".txt" end   -- 失敗紀錄：每批一行「批次id 失敗數 x,z,原因;...」
local WARN_SECONDS = 900           -- 超過這麼久沒收到回報就提醒 (掃一批要幾分鐘；沒電的話無人機會自己等充電)
-- ──────────────────────────

local function fname(tag) return "mountain_cols_" .. tag .. ".txt" end

local function loadProgress()
  local p = {}
  for _, tag in ipairs(TAGS) do p[tag] = { done = 0, off = 0 } end
  local f = io.open(PROGRESS, "r")
  if f then
    for line in f:lines() do
      local tag, done, off = line:match("^(%S+) (%d+) (%d+)$")
      if tag and p[tag] then p[tag] = { done = tonumber(done), off = tonumber(off) } end
    end
    f:close()
  end
  return p
end

local function saveProgress(p)
  local f = io.open(PROGRESS, "w")
  for _, tag in ipairs(TAGS) do f:write(string.format("%s %d %d\n", tag, p[tag].done, p[tag].off)) end
  f:close()
end

local function logFailed(tag, id, n, why)
  local f = io.open(failfile(tag), "a")
  if f then f:write(string.format("%s %s %s\n", tostring(id), tostring(n), tostring(why))) f:close() end
end

local function countLines(path)
  local n, f = 0, io.open(path, "r")
  if not f then return nil end
  for _ in f:lines() do n = n + 1 end
  f:close()
  return n
end

-- 從位移 off 讀下一批：回傳 payload 字串、欄數、新位移 (沒有了回傳 nil)
local function nextBatch(tag, off)
  local f = io.open(fname(tag), "r")
  if not f then return nil end
  f:seek("set", off)
  local lines, n = {}, 0
  while n < BATCH do
    local line = f:read("*l")
    if not line then break end
    if line:match("%S") then
      lines[#lines + 1] = (line:gsub("%s+$", ""))
      n = n + 1
    end
  end
  local new_off = f:seek("cur")
  f:close()
  if n == 0 then return nil end
  return table.concat(lines, ";"), n, new_off
end

-- 動態巡航高度：整座山是由低到高蓋的，早期已蓋的最高點很低，不必每次都升到 203。
-- 每批的巡航 = max(下限, 已蓋 / 本批最高頂面 + 邊界, 本批飛行範圍內既有地形最高點 + 邊界)，不超過上限。
local scanGrid = {}
local CELL = 16
local function loadScan()
  local f = io.open(SCAN_FILE, "r")
  if not f then return 0 end
  local n = 0
  for line in f:lines() do
    local x, z, top = line:match("^(-?%d+) (-?%d+) (-?%d+)")
    if x then
      local k = math.floor(tonumber(x) / CELL) .. "," .. math.floor(tonumber(z) / CELL)
      if (scanGrid[k] or -1) < tonumber(top) then scanGrid[k] = tonumber(top) end
      n = n + 1
    end
  end
  f:close()
  return n
end

local function scanMax(x0, x1, z0, z1)
  local m = 0
  for cx = math.floor((x0 - 8) / CELL), math.floor((x1 + 8) / CELL) do
    for cz = math.floor((z0 - 8) / CELL), math.floor((z1 + 8) / CELL) do
      local t = scanGrid[cx .. "," .. cz]
      if t and t > m then m = t end
    end
  end
  return m
end

loadScan()
local builtMax = {}                    -- 每個通道目前送出的最高 h
local lastCol = {}                     -- 每個通道上一批最後一欄的世界方塊座標

local function cruiseFor(tag, payload)
  local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
  local function add(bx, bz)
    if bx < x0 then x0 = bx end
    if bx > x1 then x1 = bx end
    if bz < z0 then z0 = bz end
    if bz > z1 then z1 = bz end
  end
  local hmax = builtMax[tag] or 0
  local last
  for x, z, h in payload:gmatch("(-?%d+) (-?%d+) (%d+) %S+") do
    local bx, bz = math.floor(-200.5 + tonumber(x)), math.floor(-49.5 - tonumber(z))
    add(bx, bz)
    last = { bx, bz }
    if tonumber(h) > hmax then hmax = tonumber(h) end
  end
  builtMax[tag] = hmax
  if lastCol[tag] then add(lastCol[tag][1], lastCol[tag][2]) end
  lastCol[tag] = last
  local built = 0
  for _, t in ipairs(TAGS) do if (builtMax[t] or 0) > built then built = builtMax[t] end end
  local c = BASE_TOP + built - 1 + MARGIN
  if x0 <= x1 then
    local sm = scanMax(x0, x1, z0, z1)
    if sm > 0 and sm + MARGIN > c then c = sm + MARGIN end
  end
  return math.min(CRUISE, math.max(MIN_CRUISE, c))
end

print("=======================================================")
print("  T4 山體施工控制中心 (多無人機、整批回報)")
print("=======================================================")
local total = {}
for _, tag in ipairs(TAGS) do
  total[tag] = countLines(fname(tag))
  if not total[tag] then print("❌ 找不到 " .. fname(tag)) return end
  print(string.format("  通道 %s：%s，共 %d 欄", tag, fname(tag), total[tag]))
end
print("  指令： start = 從頭開始 (清除進度) | resume = 讀取進度續蓋 | status | exit")

local progress = loadProgress()
local inflight, finished, silent_since = {}, {}, {}

local function status()
  for _, tag in ipairs(TAGS) do
    print(string.format("  通道 %s：%d / %d 欄 (%.1f%%)%s", tag, progress[tag].done, total[tag],
      100 * progress[tag].done / total[tag], finished[tag] and "  完成" or ""))
  end
end

local function send(tag)
  local payload, n, new_off = nextBatch(tag, progress[tag].off)
  if not payload then
    finished[tag] = true
    inflight[tag] = nil
    print(string.format("\n✅ 通道 %s 全部完成", tag))
    return
  end
  local id = progress[tag].done + 1
  inflight[tag] = { id = id, n = n, off = new_off, t = os.time() }
  silent_since[tag] = os.clock()
  modem.broadcast(SERVER_PORT, "SERVER_CMD", tag, "build_batch", id, cruiseFor(tag, payload), payload)
end

local function run()
  finished, inflight = {}, {}
  for _, tag in ipairs(TAGS) do send(tag) end
  while true do
    local alldone = true
    for _, tag in ipairs(TAGS) do if not finished[tag] then alldone = false end end
    if alldone then print("\n🎉 所有通道都完成了！") return end
    local raw = { event.pull(5, "modem_message") }
    if raw[1] then
      local tag, a1, a2, kind = raw[6], raw[7], raw[8], raw[9]
      if raw[4] == SERVER_PORT and a1 == "DRONE_REPORT" and a2 == "REPORT" and (kind == "BATCH_DONE" or kind == "ERROR") then
        if kind == "BATCH_DONE" and inflight[tag] and tonumber(raw[10]) == inflight[tag].id then
          local b = inflight[tag]
          progress[tag].done = progress[tag].done + b.n
          progress[tag].off = b.off
          saveProgress(progress)
          silent_since[tag] = os.clock()
          io.write(string.format("\r通道 %s：%d / %d 欄 (%.1f%%) 本批失敗 %s    ", tag, progress[tag].done, total[tag],
            100 * progress[tag].done / total[tag], tostring(raw[12])))
          if (tonumber(raw[12]) or 0) > 0 then
            print("\n   失敗清單 (x,z,原因): " .. tostring(raw[13]) .. "\n   (已記錄到 " .. failfile(tag) .. ")")
            logFailed(tag, b.id, raw[12], raw[13])
          end
          send(tag)
        elseif kind == "ERROR" then
          print(string.format("\n🚨 通道 %s 回報錯誤: %s\n   (這一批沒有計入進度；排除問題後輸入 resume)", tostring(tag), tostring(raw[10])))
          inflight[tag] = nil
          finished[tag] = true            -- 這台先停；其他台繼續
        end
      end
    end
    for _, tag in ipairs(TAGS) do
      if inflight[tag] and os.clock() - (silent_since[tag] or 0) > WARN_SECONDS then
        print(string.format("\n⚠️ 通道 %s 已超過 %d 秒沒有回報 (沒電？卡住？)。確認無人機後可 Ctrl+C，再輸入 resume 重送這一批。", tag, WARN_SECONDS))
        silent_since[tag] = os.clock()
      end
    end
  end
end

while true do
  io.write("\n指令 > ")
  local input = io.read()
  if input == "exit" or input == nil then break end
  if input == "status" then
    status()
  elseif input == "start" then
    print("⚠️ 這會清除進度並從頭開始，確定請輸入 y：")
    if io.read() == "y" then
      for _, tag in ipairs(TAGS) do progress[tag] = { done = 0, off = 0 } io.open(failfile(tag), "w"):close() end
      saveProgress(progress)
      run()
    end
  elseif input == "resume" then
    progress = loadProgress()
    status()
    run()
  end
end
