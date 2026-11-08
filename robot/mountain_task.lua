-- 山體施工無人機程式：一次收一批欄位 (build_batch)，蓋完才回報一次，省下連接卡每則約 100 點的電。
-- 每欄是一段垂直的殼 (start..h 層)，由下往上蓋：無人機停在目標格正上方，用 place(0) 往腳下放，
-- 放完往上升一格再放。OC 放置規則：目標格的腳下或四個側邊有方塊就放得上去 (產生器已保證順序可行)。
--
-- 材料：背包 SLOTS 格 (目前 8)，用 ME 升級按需請求。資料庫 (database) 不用手動設定：第一次用到某種材料時，
--   程式會用 ME 的 store 把該材料寫進資料庫的對應項目 (編號見 ENTRY)，再用 requestItems 請求。
--   材料的名稱與損傷值在下面的 ITEM 表，不是這些方塊 (例如其他模組的石頭) 就改這張表。
--   ME 網路裡必須有這些材料。
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
local g = component.proxy(component.list("generator")() or "")

local ENTRY = { S = 1, T = 2, C = 3, N = 4, G = 5, D = 6, F = 7 }   -- 各材料用的資料庫項目編號
local ITEM = {                                                   -- 各材料的 ME 過濾條件 (1.7.10 名稱)
  S = { name = "minecraft:stone", damage = 0 },                 -- 石頭
  T = { name = "minecraft:stained_hardened_clay", damage = 9 },  -- 青色陶瓦
  C = { name = "minecraft:cobblestone", damage = 0 },           -- 鵝卵石
  N = { name = "minecraft:snow", damage = 0 },                  -- 雪 (方塊)
  G = { name = "minecraft:gravel", damage = 0 },                -- 砂礫
  D = { name = "minecraft:dirt", damage = 0 },                  -- 泥土
  F = { name = "minecraft:coal_block", damage = 0 },            -- 發電升級的燃料 (煤炭塊燃燒 16000 tick，比煤炭耐燒 10 倍)
}
local SLOTS = 8               -- 背包格數 (物品欄升級)；6 種材料可以全部常駐，剩下的給燃料暫用
local FUEL_MIN = 8             -- 發電升級裡的燃料少於這個數量就補
local WX0, WZ0, BASE = -200.5, -49.5, 82
local MAXUP, LEG = 12, 30
local HOVER = 0.5             -- 放置時停在整數高度上方這麼多 (實測位置只會停在 0.25 的倍數，且有 ±0.005 的雜訊；+0.25~+0.75 都放得到目標層，0.5 離上下邊界最遠：
                           -- 停在剛好整數高度，約一半機率 floor 掉到下一層，方塊就放錯層)
local HOP = 10                 -- 水平距離不超過這個就低空平移，超過就升到巡航高度
local LOW_FRAC, RESUME_FRAC = 0.10, 0.30   -- 電量保險：低於 10% 懸停等充電，充到 30% 再動

d.setStatusText("MTN")

local ensure_fuel
local function refuel()
  local maxe = computer.maxEnergy()
  if computer.energy() / maxe >= LOW_FRAC then return end
  pcall(ensure_fuel)                 -- 電量低：先確認發電升級有燃料，再懸停等充電
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
    if not go(dx * leg / dist, 0, dz * leg / dist) then
      climbed = climbed + 2
      if climbed > MAXUP or not vert(2) then return false end
    end
  end
end

-- 確保資料庫項目 ENTRY[m] 是材料 m：這次開機第一次用到時，用 ME 的 store 重寫一次
local ready = {}
local function setup_entry(m)
  if ready[m] then return end
  db.clear(ENTRY[m])
  me.store(ITEM[m], db.address, ENTRY[m], 1)
  if not db.get(ENTRY[m]) then error("ME 網路裡找不到 " .. ITEM[m].name .. " (損傷值 " .. ITEM[m].damage .. ")") end
  ready[m] = true
end

-- 背包當快取：要的材料不在就向 ME 請求，沒有空槽就把最久沒用的還給 ME
local slot_m, slot_t, clock = {}, {}, 0
local function free_slot()                 -- 選一個空槽 (沒有就挑最久沒用的、把裡面的還給 ME)，並選取它
  local pick, best = 1, math.huge
  for s = 1, SLOTS do
    local score = d.count(s) == 0 and -1 or (slot_t[s] or 0)
    if score < best then pick, best = s, score end
  end
  d.select(pick)
  if d.count(pick) > 0 then me.sendItems() end
  if d.count(pick) > 0 then error("ME 收不回槽 " .. pick .. " 的舊材料 (ME 滿了？)") end
  slot_m[pick] = nil
  return pick
end

local function stock(m)
  clock = clock + 1
  for s = 1, SLOTS do
    if slot_m[s] == m and d.count(s) > 0 then slot_t[s] = clock return s end
  end
  local pick = free_slot()
  setup_entry(m)
  local got = me.requestItems(db.address, ENTRY[m], 64)
  if not got or got < 1 or d.count(pick) < 1 then error("ME 供不出材料 " .. m .. " (資料庫項目 " .. ENTRY[m] .. ")") end
  slot_m[pick], slot_t[pick] = m, clock
  return pick
end

-- 發電升級的燃料：無人機本身每 tick 耗 0.4 (每秒 8 點)，加區塊加載和太陽能，電量收支大約打平，
-- 光靠太陽能懸停也充不回來。所以讓 ME 供煤炭塊，插進發電升級 (一個煤炭塊可發約 12800 點)。
ensure_fuel = function()
  if not g or g.count() >= FUEL_MIN then return end
  local pick = free_slot()
  setup_entry("F")
  local got = me.requestItems(db.address, ENTRY.F, 64)
  if not got or got < 1 then error("ME 供不出燃料 " .. ITEM.F.name) end
  g.insert()
  if d.count(pick) > 0 then me.sendItems() end   -- 發電升級插不下的還給 ME
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

-- 對準欄位正中心：放置的射線只比目標格多伸進鄰格 0.15 格，偏離超過這個就會打空
local function settle()                    -- 等無人機真的停穩：連續 3 次速度都幾乎為 0 (到位 != 停穩，還在飄的時候射線會偏)
  local calm = 0
  for _ = 1, 60 do
    if d.getVelocity() < 0.01 then
      calm = calm + 1
      if calm >= 3 then return end
    else
      calm = 0
    end
    computer.pullSignal(0.05)
  end
end

local function align(wx, wz, wy)
  local cx, cy, cz = pos()
  local dx, dy, dz = wx - cx, (wy or cy) - cy, wz - cz
  if math.abs(dx) > 0.03 or math.abs(dy) > 0.03 or math.abs(dz) > 0.03 then return go(dx, dy, dz) end
  return true
end

-- 對準到欄中心的上方 (水平偏差要 0，垂直有 ±0.25 的餘量，不用特別等停穩、也不用從上方接近)
local function steady(wx, wz, wy)
  return align(wx, wz, wy) ~= false
end

-- 放置前確認高度在安全範圍：整數 +0.3 ~ +0.6 (低於整數會掉到下一層放錯層；實測太高有時會放到奇怪的位置)
local function yok(wx, wz, layer)
  for _ = 1, 3 do
    local _, cy = pos()
    local dy = cy - BASE - layer
    if dy >= 0.3 and dy <= 0.6 then return true end
    align(wx, wz, BASE + layer + HOVER)
  end
  return false
end

-- 蓋一欄 (可重複執行：已經蓋好的層會跳過，所以失敗重試、續蓋、補蓋都安全)
local function build_column(x, z, h, mats, cruise)
  local seq, s = parse(mats)
  local wx, wz = WX0 + x, WZ0 - z
  if not travel(wx, wz, BASE + h + 2, cruise) then return false, "travel" end
  align(wx, wz)
  -- 往下走到殼起點；途中被已經蓋好的方塊擋住就停在它上面，從那一層接著看 (續蓋、補蓋都靠這個)
  local _, cy = pos()
  go(0, BASE + s + HOVER - cy, 0)
  _, cy = pos()
  for layer = math.max(s, math.ceil(cy - BASE - HOVER - 0.05)), h do
    if not steady(wx, wz, BASE + layer + HOVER) then return false, "climb@" .. layer end
    local _, what = d.detect(0)
    if what ~= "solid" then                      -- 腳下那格還是空的才放
      local ok, why, slot = false, nil, nil
      for try = 1, 4 do
        slot = stock(seq[layer])
        d.select(slot)                           -- 每次都重新選：補燃料 / 補貨可能換掉了選取的槽
        if yok(wx, wz, layer) then ok, why = d.place(0) else ok, why = false, "y" end
        if ok then
          local _, w = d.detect(0)               -- place 找不到目標會改放四周：確認腳下真的有方塊才算成功
          if w == "solid" and seq[layer] == "G" then   -- 砂礫放下去 2 tick 後才會掉：等一下再確認，沒撐住就不要再放 (重放只會讓砂礫一顆顆掉下去)
            computer.pullSignal(0.3)
            _, w = d.detect(0)
            if w ~= "solid" then return false, "fall@" .. layer end
          end
          if w == "solid" then break end
          ok, why = false, "side"
        end
        computer.pullSignal(0.2)                 -- 失敗才多等一下：等停穩再重新對準
        settle()
        steady(wx, wz, BASE + layer + HOVER)
      end
      if not ok then                             -- 失敗原因附上現場狀態，方便從失敗紀錄判斷
        local cx, cy2, cz = pos()
        local _, det = d.detect(0)
        return false, string.format("place@%d(%s%d %s y%+.2f x%+.2f z%+.2f %s)", layer, seq[layer], d.count(slot),
          det, cy2 - BASE - layer - HOVER, cx - wx, cz - wz, why)
      end
    end
  end
  return true
end

local function run_batch(id, cruise, payload)
  local cols, failed = {}, {}
  for line in payload:gmatch("[^;]+") do
    local x, z, h, mats = line:match("^(-?%d+) (-?%d+) (%d+) (%S+)$")
    if x then cols[#cols + 1] = { tonumber(x), tonumber(z), tonumber(h), mats } end
  end
  local done = 0
  local function try(c)
    local ok, r, reason = pcall(build_column, c[1], c[2], c[3], c[4], cruise)
    if not ok then report("ERROR", tostring(r)) return nil end      -- 致命 (ME 供不出等)：整批中止，不回報完成
    return r, reason
  end
  for _, c in ipairs(cols) do
    local r, reason = try(c)
    if r == nil and reason == nil then return end
    if r then done = done + 1 else failed[#failed + 1] = { c, reason } end
  end
  -- 失敗的欄 (多半是它的支撐欄剛好在後面才蓋好)：整批做完後再試一次
  local still = {}
  for _, f in ipairs(failed) do
    local c = f[1]
    local r, reason = try(c)
    if r == nil and reason == nil then return end
    if r then done = done + 1 else still[#still + 1] = c[1] .. "," .. c[2] .. "," .. tostring(reason) end
  end
  local why = table.concat(still, ";")
  report("BATCH_DONE", id, done, #still, why:sub(1, 1200))
end

if not me or not db then
  report("ERROR", "找不到 ME 升級或資料庫升級")
  return
end

while true do
  local sig, _, _, _, _, _, cmd, id, cruise, payload = computer.pullSignal()
  if sig == "modem_message" and cmd == "build_batch" then
    d.setStatusText("MTN")
    pcall(ensure_fuel)
    run_batch(id, tonumber(cruise) or 203, tostring(payload))
  end
end
