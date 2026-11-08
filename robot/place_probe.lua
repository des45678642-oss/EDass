-- 放置範圍測試 (無人機)：量「無人機偏離欄中心多遠，還放得上去」。
-- 用法：server.lua 的 DRONE_PROGRAMS 把要測的通道暫時改成 "place_probe.lua"，
--   把無人機停在一塊「平坦、空曠」的地面上空 (需要東邊 22 格、南邊 13 格內都是平地、沒有東西)，
--   背包第 1、2 格各放一組石頭 (共 128 個)，T4 執行 place_probe_collect.lua。
-- 每個測試點的結構：一根 2 格高的石柱 S，旁邊 (東側) 一格 T 的腳下是空氣、只有 S 當側邊支撐。
--   無人機停在 T 上方、故意偏離中心一個距離後 place(0)，記錄方塊最後放在哪 (T 腳下 / 旁邊 / 沒放)。
--   偏移方向：away (遠離 S)、toward (靠近 S)、perp (垂直 S 的方向)、diag (遠離 + 垂直)
-- 偏移最大只測 0.45：超過 0.5 無人機就跑到隔壁那一格上方了。
local d = component.proxy(component.list("drone")())
local n = component.proxy(component.list("navigation")())
local t = component.proxy(component.list("tunnel")())

local SLOTS = 8
local OFFS = { 0, 0.1, 0.15, 0.2, 0.3, 0.45 }
local MODES = { { "away", 1, 0 }, { "toward", -1, 0 }, { "perp", 0, 1 }, { "diag", 1, 1 } }
local GAP = 4                                   -- 測試點之間隔幾格

local function report(...) if t then t.send("DRONE_REPORT", "REPORT", ...) end end
local function pos() local x, y, z = n.getPosition() return x or 0, y or 0, z or 0 end

local function settle()
  local calm = 0
  for _ = 1, 80 do
    if d.getVelocity() < 0.01 then calm = calm + 1 if calm >= 3 then return end else calm = 0 end
    computer.pullSignal(0.05)
  end
end

-- 移到絕對座標 (精準：到位後等停穩，再補正一次)
local function goto_(x, y, z)
  for _ = 1, 3 do
    local cx, cy, cz = pos()
    local dx, dy, dz = x - cx, y - cy, z - cz
    if math.abs(dx) < 0.005 and math.abs(dy) < 0.005 and math.abs(dz) < 0.005 then break end
    d.move(dx, dy, dz)
    local w = 0
    while d.getOffset() > 0.01 and w < 300 do computer.pullSignal(0.05) w = w + 1 end
    settle()
  end
end

local function power()
  local m = computer.maxEnergy()
  if computer.energy() / m < 0.2 then
    d.setStatusText("CHARGE")
    while computer.energy() / m < 0.5 do computer.pullSignal(2) end
  end
end

local function pick()
  for s = 1, SLOTS do if d.count(s) > 0 then d.select(s) return true end end
  return false
end

local function solid(side) local _, w = d.detect(side) return w == "solid" end

local function run(gy)
  local x0, y0, z0 = pos()
  local bx, bz = math.floor(x0) + 0.5, math.floor(z0) + 0.5     -- 起點所在格的中心
  local ALT = gy + 6
  local cells = {}
  for mi = 1, #MODES do
    for k = 1, #OFFS do
      cells[#cells + 1] = { mi, k, bx + GAP * (k - 1) + 1, bz + GAP * (mi - 1) }   -- S 的格中心；T 在 S 的東邊一格
    end
  end
  -- 1) 先把所有石柱蓋好
  for i, c in ipairs(cells) do
    power()
    if not pick() then report("PROBE", "ERROR 石頭不夠 (蓋石柱時用完了)") report("PROBE_DONE") return end
    goto_(c[3], ALT, c[4])
    for _, py in ipairs({ gy + 2, gy + 3 }) do
      goto_(c[3], py, c[4])
      if not pick() then report("PROBE", "ERROR 石頭不夠") report("PROBE_DONE") return end
      d.place(0)
    end
    if not solid(0) then report("PROBE", "ERROR 石柱沒蓋起來 (座標 " .. c[3] .. "," .. c[4] .. ")，請確認下方是平地") report("PROBE_DONE") return end
    d.setStatusText("S" .. i)
  end
  -- 2) 逐點測試：每個偏移方向一則回報
  local best = {}
  for mi, m in ipairs(MODES) do
    local lines = {}
    for k, off in ipairs(OFFS) do
      power()
      local c
      for _, cc in ipairs(cells) do if cc[1] == mi and cc[2] == k then c = cc end end
      local tx, tz = c[3] + 1, c[4]                     -- T 的中心
      local hx, hz = tx + m[2] * off, tz + m[3] * off   -- 無人機要停的位置
      goto_(hx, gy + 5, hz)                             -- 從上方接近
      goto_(hx, gy + 3, hz)
      local ax, ay, az = pos()
      local pre = solid(0) or solid(2) or solid(3) or solid(4) or solid(5)
      local res
      if not pick() then report("PROBE", "ERROR 石頭不夠") report("PROBE_DONE") return end
      if pre then
        res = "DIRTY(測試點不乾淨)"
      else
        local ok = d.place(0)
        local below = solid(0)
        local sides = ""
        for s = 2, 5 do if solid(s) then sides = sides .. s end end
        res = string.format("ok=%s T=%s 旁邊=%s", ok and 1 or 0, below and 1 or 0, sides == "" and "-" or sides)
        if below then best[mi] = math.max(best[mi] or 0, off) end
      end
      lines[#lines + 1] = string.format("%.2f 實際(%+.3f,%+.3f,y%+.3f) %s", off, ax - tx, az - tz, ay - gy - 3, res)
    end
    report("PROBE", m[1] .. " (偏移 / 實際偏差 dx,dz,dy / 結果；T=1 代表放在目標格)\n" .. table.concat(lines, "\n"))
  end
  local sum = {}
  for mi, m in ipairs(MODES) do sum[#sum + 1] = m[1] .. " 最大成功偏移=" .. tostring(best[mi] or "全部失敗") end
  report("PROBE", "總結: " .. table.concat(sum, "；"))
  report("PROBE_DONE")
  goto_(x0, y0, z0)
  d.setStatusText("DONE")
end

while true do
  local sig, _, _, _, _, _, cmd, a1 = computer.pullSignal()
  if sig == "modem_message" and cmd == "probe_place" then
    local ok, err = pcall(run, tonumber(a1) or 81)
    if not ok then report("PROBE", "ERROR " .. tostring(err):sub(1, 200)) report("PROBE_DONE") end
  end
end
