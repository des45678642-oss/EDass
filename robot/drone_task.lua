local d = component.proxy(component.list("drone")())
local n = component.proxy(component.list("navigation")())
local i = component.proxy(component.list("inventory_controller")())
local g = component.proxy(component.list("generator")())
local t = component.proxy(component.list("tunnel")())
local me = component.proxy(component.list("upgrade_me")() or component.list("me_interface")() or "")
local db = component.proxy(component.list("database")() or "")
-- Computronics 攝影機升級 (沒裝也能跑，只是看不到前方，改靠卡住偵測)
local ca = component.list("camera")()
local cam = ca and component.proxy(ca)

local CRUISE = 83   -- 高空航道 Y
local MAXUP = 12    -- 水平被擋時最多再往上爬幾格
local LEG = 30      -- 每段水平飛行最長距離 (攝影機最遠看 32 格)

d.setStatusText("ECO")

local function pos()
  local x, y, z = n.getPosition()
  return x or 0, y or CRUISE, z or 0
end

-- 攝影機：中心 + 上下左右各偏一點，取最近距離；沒擋到回傳 huge
-- 注意：無人機的 distance() 永遠朝南(+Z)，左右上下最多 45 度
local O = { {0, 0}, {.1, 0}, {-.1, 0}, {0, .1}, {0, -.1} }
local function probe(f, bx, by)
  if not cam then return math.huge end
  local m = math.huge
  for _, o in ipairs(O) do
    local x = math.max(-1, math.min(1, (bx or 0) + o[1]))
    local r = f(x, (by or 0) + o[2])
    if r and r >= 0 and r < m then m = r end
  end
  return m
end

-- 移動並等到位；連續 0.8 秒幾乎不動、還差 0.3 格以上 = 卡住，取消剩下的路程回傳 false
local function go(dx, dy, dz)
  local sx, sy, sz = pos()
  d.move(dx, dy, dz)
  local still, off = 0, d.getOffset()
  while off > 0.05 do
    computer.pullSignal(0.1)
    off = d.getOffset()
    if d.getVelocity() < 0.05 then still = still + 1 else still = 0 end
    if still >= 8 and off <= 0.3 then return true end  -- 差一點點，當作到了
    if still >= 8 then
      local cx, cy, cz = pos()
      d.move(cx - (sx + dx), cy - (sy + dy), cz - (sz + dz))
      return false
    end
  end
  return true
end

-- 垂直移動：先用攝影機看上/下方，空間不夠就不動
local function vert(dy)
  if math.abs(dy) < 0.05 then return true end
  if probe(dy > 0 and cam and cam.distanceUp or cam and cam.distanceDown) < math.abs(dy) + 0.5 then
    return false
  end
  return go(0, dy, 0)
end

-- 在目前高度水平飛到 (tx, tz)；前方被擋就往上爬再試
local function fly(tx, tz)
  local climbed = 0
  while true do
    local cx, cy, cz = pos()
    local dx, dz = tx - cx, tz - cz
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 0.1 then return true end
    local leg = math.min(dist, LEG)
    -- 往南 45 度內的方向可以先用攝影機看
    if cam and dz > 0 and math.abs(dx) <= dz then
      local free = probe(cam.distance, -dx / dz, 0)
      if free < leg + 0.5 then leg = free - 1 end
    end
    if leg < 0.5 or not go(dx * leg / dist, 0, dz * leg / dist) then
      d.setStatusText("AVOID")
      climbed = climbed + 2
      if climbed > MAXUP or not vert(2) then return false end
    end
  end
end

local function report(st, x, z)
  d.setStatusText(st == "SUCCESS" and "ECO" or st)
  if t then t.send("DRONE_REPORT", "REPORT", "PLACE_RESULT", st, x, z) end
end

while true do
  local sig, _, _, _, _, _, cmd, x, z, dp, sY = computer.pullSignal()
  if sig == "modem_message" and cmd == "build_point" then

    -- 1. 原地物資請求
    if me and db then
      for s = 1, 4 do d.select(s) me.requestItems(db.address, s, 64) end
      if g then d.select(4) g.insert() end
    end

    -- 2. 爬升到高空航道 (上方被擋就回報 BLOCKED，不硬撞)
    local _, cy = pos()
    if cy < CRUISE and not vert(CRUISE - cy) then report("BLOCKED", x, z) goto continue end

    -- 3. 水平飛到目標點正上方 (沿途避障)
    if not fly(-200.5 + x, -49.5 - z) then report("BLOCKED", x, z) goto continue end

    -- 4. 逐層下降打樁 (基岩在 74，施工從 75 開始)；下方有東西擋住就停
    do
      local total = (sY - dp) - 74
      local ok = true
      for layer = 1, math.max(total, 0) do
        local cur_y = 75 + (layer - 1)
        _, cy = pos()
        if not vert((cur_y + 1) - cy) then ok = false break end
        if layer < total then
          d.select(3)
        else
          d.select((dp == 1 or dp == 2) and 1 or 2)
        end
        d.place(0)
      end
      -- 5. 一對一完工握手放行
      report(ok and "SUCCESS" or "BLOCKED", x, z)
    end
    ::continue::
  end
end
