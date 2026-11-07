-- 地形掃描程式：無人機 + Computronics 攝影機。
-- 跟著地表飛 (維持在地表上方 LIFT 格)，每個取樣點用攝影機往正下方量一次距離，
-- 算出該點的「頂面座標」(地面最上面那塊方塊的上表面 = 82)，一列一列傳回 T4。
--
-- 使用方式：
--   1. 中繼伺服器 (server.lua) 把 DRONE_PROGRAM 改成 "scan_task.lua"，無人機開機後就會下載這支程式。
--   2. 在 T4 執行 scan_collect.lua，它會送出 scan_region 指令並把回傳的資料存成 scan.txt。
--   3. 掃完後把 DRONE_PROGRAM 改回 "drone_task.lua"。
--
-- 座標：取樣點用世界「方塊座標」(整數)，飛到方塊中心 (+0.5)。
-- 導航升級回傳的是「相對地圖中心」的座標，Y 是絕對高度。程式開頭會自己校正：
--   1. 往世界 +X、+Z 各飛 4 格，量導航座標怎麼變，得出兩套座標軸的對應 (可處理軸互換、反向)
--   2. 檢查掃描範圍有沒有超出導航升級的範圍 (超出時導航會回傳 nil)
-- 校正結果會回報給 T4。地圖中心不在世界 (0,0) 時，改下面的 MAP_CENTER_X / MAP_CENTER_Z。
local d = component.proxy(component.list("drone")())
local n = component.proxy(component.list("navigation")())
local t = component.proxy(component.list("tunnel")())
local ca = component.list("camera")()
local cam = ca and component.proxy(ca)

local MAP_CENTER_X, MAP_CENTER_Z = 0, 0   -- 導航地圖中心的世界座標 (你的地圖中心對齊 (0,0))
local LIFT = 12            -- 飛在地表上方幾格 (要高過前方的樹和坡)
local MIN_D, MAX_D = 4, 26 -- 攝影機距離的合理範圍 (攝影機最遠只看 32 格)
local APPROACH_Y = 215 -- 出發時先升到這個高度，再飛向掃描起點 (要比搬遷地形最高處高；世界上限是 256)

-- 電量管理：每次連接卡發訊息約耗 100 點，補充只有每秒約 10 點，所以不能想飛就飛、想傳就傳。
-- 電量低於 LOW_FRAC 就原地懸停等充電，充到 RESUME_FRAC 才繼續 (等待期間無人機不耗電移動)。
local LOW_FRAC, RESUME_FRAC = 0.30, 0.65
local function refuel(label)
  local maxe = computer.maxEnergy()
  if computer.energy() / maxe >= LOW_FRAC then return end
  d.setStatusText("CHARGE")
  while computer.energy() / maxe < RESUME_FRAC do computer.pullSignal(2) end
  d.setStatusText(label or "SCAN")
end

local function report(...)
  refuel()
  if t then t.send("DRONE_REPORT", "REPORT", ...) end
end

-- 導航座標與世界座標的對應：nav_x = N[1]*wx + N[2]*wz，nav_z = N[3]*wx + N[4]*wz (wx、wz 已扣掉地圖中心)
local N = { 1, 0, 0, 1 }

local function rawpos()
  local x, y, z = n.getPosition()
  if type(x) ~= "number" then error("導航升級沒有回傳位置: " .. tostring(y) .. " (超出地圖範圍？)") end
  return x, y, z
end

-- 世界座標 (已套用校正)
local function pos()
  local nx, y, nz = rawpos()
  local det = N[1] * N[4] - N[2] * N[3]
  local wx = (N[4] * nx - N[2] * nz) / det + MAP_CENTER_X
  local wz = (-N[3] * nx + N[1] * nz) / det + MAP_CENTER_Z
  return wx, y, wz
end

-- 移動並等到位；連續 0.8 秒幾乎不動、還差 0.3 格以上 = 被擋住，取消剩下的路程回傳 false
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

-- 校正導航軸：drone.move 永遠用世界軸，所以往世界 +X、+Z 各飛一小段，看導航座標怎麼變
local function calibrate()
  local function probe(wx, wz)
    local x0, _, z0 = rawpos()
    if not go(wx, 0, wz) then error("校正時被擋住，請把無人機放在空曠處") end
    local x1, _, z1 = rawpos()
    go(-wx, 0, -wz)
    local len = math.sqrt(wx * wx + wz * wz)
    return (x1 - x0) / len, (z1 - z0) / len
  end
  local ax, az = probe(4, 0)           -- 世界 +X 在導航座標裡的方向
  local bx, bz = probe(0, 4)           -- 世界 +Z 在導航座標裡的方向
  local function r(v) return math.floor(v + 0.5) end
  local m = { r(ax), r(bx), r(az), r(bz) }
  if math.abs(m[1] * m[4] - m[2] * m[3]) ~= 1 then
    error(string.format("導航座標軸校正失敗 (%.2f,%.2f / %.2f,%.2f)", ax, az, bx, bz))
  end
  N = m
  return ax, az, bx, bz
end

-- 掃描範圍的四個角都要在導航升級的範圍內
local function check_range(x0, x1, z0, z1)
  local range = n.getRange()
  for _, c in ipairs({ { x0, z0 }, { x0, z1 }, { x1, z0 }, { x1, z1 } }) do
    local wx, wz = c[1] - MAP_CENTER_X, c[2] - MAP_CENTER_Z
    local nx, nz = N[1] * wx + N[2] * wz, N[3] * wx + N[4] * wz
    if math.abs(nx) > range - 1 or math.abs(nz) > range - 1 then
      error(string.format("掃描範圍超出導航範圍 ±%d：世界 (%d,%d) 對應導航 (%d,%d)", range, c[1], c[2], nx, nz))
    end
  end
  return range
end

-- 水平飛到 (tx, tz)；被坡面或樹擋住就往上爬再試
-- 一次最多飛 LEG 格，每段之間檢查電量 (長距離一口氣飛會在半路沒電)
local LEG = 16
local function moveto(tx, tz)
  local fails = 0
  while fails < 6 do
    local cx, _, cz = pos()
    local dx, dz = tx - cx, tz - cz
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 0.1 then return true end
    if dist > LEG then dx, dz = dx * LEG / dist, dz * LEG / dist end
    if not go(dx, 0, dz) then
      fails = fails + 1
      go(0, 6, 0)
    end
  end
  return false
end

-- 正下方的頂面座標；距離不在合理範圍就調整高度重量
local function measure()
  for _ = 1, 10 do
    local _, py = pos()
    local dist = cam.distanceDown()
    if not dist or dist < 0 then
      go(0, -(MAX_D - 6), 0)                 -- 32 格內什麼都沒看到：往下降
    elseif dist < MIN_D then
      go(0, MIN_D + 6 - dist, 0)             -- 太靠近地表：往上爬
    else
      return math.floor(py - dist + 0.5), py
    end
  end
end

local function scan(x0, x1, z0, z1, step)
  local _, y0 = pos()
  if y0 < APPROACH_Y then go(0, APPROACH_Y - y0, 0) end   -- 先升到高空，避免長距離直線飛行撞到地形
  local ax, az, bx, bz = calibrate()
  local range = check_range(x0, x1, z0, z1)
  -- 封包最多 8 個部分 (中繼轉發時還會再加一個通道標籤)，所以校正結果合成一個字串傳
  report("CALIB", string.format("世界+X->導航(%.1f,%.1f) 世界+Z->導航(%.1f,%.1f) 導航範圍±%d", ax, az, bx, bz, range))
  local dir = 1
  local xlast = x0 + math.floor((x1 - x0) / step) * step
  for z = z0, z1, step do
    local xs, xe, xstep = x0, xlast, step
    if dir < 0 then xs, xe, xstep = xlast, x0, -step end
    local vals, first = {}, nil
    for x = xs, xe, xstep do
      if not moveto(x + 0.5, z + 0.5) then report("ERROR", "無法抵達 " .. x .. "," .. z) return end
      local top, py = measure()
      if not top then report("ERROR", "量不到地表 " .. x .. "," .. z) return end
      vals[#vals + 1] = top
      first = first or x
      local adj = top + LIFT - py            -- 維持在地表上方約 LIFT 格；差不到 3 格就不動，省下一次移動 (電量和時間都省)
      if math.abs(adj) >= 3 then go(0, adj, 0) end
    end
    report("SCAN", z, first, xstep, table.concat(vals, ","))
    dir = -dir
  end
  report("SCAN_DONE")
end

if not cam then
  report("ERROR", "找不到攝影機升級 (camera)")
  return
end
d.setStatusText("SCAN")

while true do
  local sig, _, _, _, _, _, cmd, x0, x1, z0, z1, step = computer.pullSignal()
  if sig == "modem_message" and cmd == "scan_region" then
    step = math.max(1, math.floor(step or 2))
    local ok, err = pcall(scan, math.floor(x0), math.floor(x1), math.floor(z0), math.floor(z1), step)
    if not ok then report("ERROR", tostring(err)) end
    d.setStatusText("DONE")
  end
end
