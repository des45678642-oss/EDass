-- 山體施工無人機程式：一次收一批欄位 (build_batch)，蓋完才回報一次，省下連接卡每則約 100 點的電。
-- 每欄是一段垂直的殼 (start..h 層)，由下往上蓋：無人機停在目標格正上方，用 place(0) 往腳下放，
-- 放完往上升一格再放。OC 放置規則：目標格的腳下或四個側邊有方塊就放得上去 (產生器已保證順序可行)。
--
-- 材料：背包只有 4 格，用 ME 升級按需請求。資料庫 (database) 的項目編號要照下面 ENTRY 設定：
--   1=石頭 2=灰色陶瓦 3=鵝卵石 4=雪 5=砂礫 6=泥土
-- 座標：欄位用湖地圖座標 (x_map, z_map)，世界 X = -200.5 + x_map，世界 Z = -49.5 - z_map，
--       層 k 的方塊 Y = 81 + k，放它時無人機的 Y = 82 + k。
-- 指令格式 (T4 -> 中繼 -> 無人機)：build_batch, 批次編號, 巡航高度, "x z h 材質串;x z h 材質串;..."
-- 回報：BATCH_DONE, 批次編號, 完成欄數, 失敗欄數, "x,z,原因;..."   (失敗不中斷，繼續下一欄)
--       ERROR, 訊息 (ME 供不出材料等致命問題，整批中止)
local d = component.proxy(component.list("drone")())
local n = component.proxy(component.list("navigation")())
local t = component.proxy(component.list("tunnel")())
local me = component.proxy(component.list("upgrade_me")() or "")
local db = component.proxy(component.list("database")() or "")
local ca = component.list("camera")()
local cam = ca and component.proxy(ca)

local ENTRY = { S = 1, T = 2, C = 3, N = 4, G = 5, D = 6 }
local WX0, WZ0, BASE = -200.5, -49.5, 82
local MAXUP, LEG = 12, 30
local HOP = 6                  -- 水平距離不超過這個就低空平移，超過就升到巡航高度
local LOW_FRAC, RESUME_FRAC = 0.10, 0.30   -- 電量保險：低於 10% 懸停等充電，充到 30% 再動

d.setStatusText("MTN")

local function refuel()
  local maxe = computer.maxEnergy()
  if computer.energy() / maxe >= LOW_FRAC then return end
  d.setStatusText("CHARGE")
  while computer.energy() / maxe < RESUME_FRAC do computer.pullSignal(2) end
  d.setStatusText("MTN")
end

local function report(...)
  refuel()
  if t then t.send("DRONE_REPORT", "REPORT", ...) end
end

local function pos()
  local x, y, z = n.getPosition()
  return x or 0, y or BASE, z or 0
end

-- 攝影機：中心 + 上下左右各偏一點取最近距離；垂直移動只看正中間 (斜射的光線會打到旁邊更高的方塊)
local O = { { 0, 0 }, { .1, 0 }, { -.1, 0 }, { 0, .1 }, { 0, -.1 } }
local function probe(f, bx, by, narrow)
  if not cam then return math.huge end
  local m = math.huge
  for k, o in ipairs(O) do
    if not narrow or k == 1 then
      local r = f(math.max(-1, math.min(1, (bx or 0) + o[1])), (by or 0) + o[2])
      if r and r >= 0 and r < m then m = r end
    end
  end
  return m
end

local function go(dx, dy, dz)
  refuel()
  local sx, sy, sz = pos()
  d.move(dx, dy, dz)
  local still, off = 0, d.getOffset()
  while off > 0.05 do
    computer.pullSignal(0.1)
    off = d.getOffset()
    if d.getVelocity() < 0.05 then still = still + 1 else still = 0 end
    if still >= 8 and off <= 0.3 then return true end
    if still >= 8 then
      local cx, cy, cz = pos()
      d.move(cx - (sx + dx), cy - (sy + dy), cz - (sz + dz))
      return false
    end
  end
  return true
end

local function vert(dy)
  if math.abs(dy) < 0.05 then return true end
  local f = cam and (dy > 0 and cam.distanceUp or cam.distanceDown)
  if f and probe(f, 0, 0, true) < math.abs(dy) + 0.5 then return false end
  return go(0, dy, 0)
end

local function fly(tx, tz)
  local climbed = 0
  while true do
    local cx, cy, cz = pos()
    local dx, dz = tx - cx, tz - cz
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 0.1 then return true end
    local leg = math.min(dist, LEG)
    if cam and dz > 0 and math.abs(dx) <= dz then
      local free = probe(cam.distance, -dx / dz, 0)
      if free < leg + 0.5 then leg = free - 1 end
    end
    if leg < 0.5 or not go(dx * leg / dist, 0, dz * leg / dist) then
      climbed = climbed + 2
      if climbed > MAXUP or not vert(2) then return false end
    end
  end
end

-- 背包 4 格當快取：要的材料不在就向 ME 請求，沒有空槽就把最久沒用的還給 ME
local slot_m, slot_t, clock = {}, {}, 0
local function stock(m)
  clock = clock + 1
  for s = 1, 4 do
    if slot_m[s] == m and d.count(s) > 0 then slot_t[s] = clock return s end
  end
  local pick, best = 1, math.huge
  for s = 1, 4 do
    local score = d.count(s) == 0 and -1 or (slot_t[s] or 0)
    if score < best then pick, best = s, score end
  end
  d.select(pick)
  if d.count(pick) > 0 then me.sendItems() end
  if d.count(pick) > 0 then error("ME 收不回槽 " .. pick .. " 的舊材料 (ME 滿了？)") end
  local got = me.requestItems(db.address, ENTRY[m], 64)
  if not got or got < 1 or d.count(pick) < 1 then error("ME 供不出材料 " .. m .. " (資料庫項目 " .. ENTRY[m] .. ")") end
  slot_m[pick], slot_t[pick] = m, clock
  return pick
end

-- "_37S2C1" -> 逐層材質表，以及殼起點層 (第一個不是 "_" 的層)
local function parse(mats)
  local seq = {}
  for m, c in mats:gmatch("([%u_])(%d+)") do
    for _ = 1, tonumber(c) do seq[#seq + 1] = m end
  end
  local s = 1
  while seq[s] == "_" do s = s + 1 end
  return seq, s
end

-- 水平移到 (wx, wz)：近的低空平移 (高度 = 目標頂面上方 2 格)，遠的升到巡航高度；被擋就改走巡航高度
local function travel(wx, wz, ty, cruise)
  local cx, cy, cz = pos()
  local far = math.abs(wx - cx) + math.abs(wz - cz) > HOP
  local alt = far and cruise or math.max(cy, ty)
  if cy < alt and not vert(alt - cy) then return false end
  if fly(wx, wz) then return true end
  if far then return false end
  _, cy = pos()
  if cy < cruise and not vert(cruise - cy) then return false end
  return fly(wx, wz)
end

local function build_column(x, z, h, mats, cruise)
  local seq, s = parse(mats)
  if not travel(WX0 + x, WZ0 - z, BASE + h + 2, cruise) then return false, "travel" end
  local _, cy = pos()
  if not vert(BASE + s - cy) then return false, "descend" end
  for layer = s, h do
    if layer > s and not go(0, 1, 0) then return false, "climb@" .. layer end
    d.select(stock(seq[layer]))
    if not d.place(0) then return false, "place@" .. layer end
  end
  return true
end

local function run_batch(id, cruise, payload)
  local done, failed, why = 0, 0, {}
  for line in payload:gmatch("[^;]+") do
    local x, z, h, mats = line:match("^(-?%d+) (-?%d+) (%d+) (%S+)$")
    if x then
      local ok, r, reason = pcall(build_column, tonumber(x), tonumber(z), tonumber(h), mats, cruise)
      if not ok then report("ERROR", tostring(r)) return end      -- 致命 (ME 供不出等)：整批中止，不回報完成
      if r then done = done + 1 else
        failed = failed + 1
        if #why < 8 then why[#why + 1] = x .. "," .. z .. "," .. tostring(reason) end
      end
    end
  end
  report("BATCH_DONE", id, done, failed, table.concat(why, ";"))
end

if not me or not db then
  report("ERROR", "找不到 ME 升級或資料庫升級")
  return
end

while true do
  local sig, _, _, _, _, _, cmd, id, cruise, payload = computer.pullSignal()
  if sig == "modem_message" and cmd == "build_batch" then
    d.setStatusText("MTN")
    run_batch(id, tonumber(cruise) or 203, tostring(payload))
  end
end
