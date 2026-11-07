-- 導航座標診斷程式 (無人機)：只在原地附近移動 ±6 格，不長途飛行，用來查「導航座標和世界座標差多少」。
-- 用法：server.lua 的 DRONE_PROGRAM 改成 "nav_probe.lua"，無人機開機後在 T4 執行 nav_probe_collect.lua。
-- 同時把結果顯示在無人機狀態文字，沒連上 T4 也能看。
local d = component.proxy(component.list("drone")())
local n = component.proxy(component.list("navigation")())
local t = component.proxy(component.list("tunnel")())

local function report(...) if t then t.send("DRONE_REPORT", "REPORT", ...) end end

local function nav(label)
  local x, y, z = n.getPosition()
  local r = n.getRange and n.getRange() or -1
  local f = n.getFacing and n.getFacing() or -1
  local line = string.format("%s 導航=(%s, %s, %s) 範圍=%s 朝向=%s", label, tostring(x), tostring(y), tostring(z), tostring(r), tostring(f))
  report("PROBE", line)
  d.setStatusText(label)
end

local function step(label, dx, dy, dz)
  d.move(dx, dy, dz)
  local waited = 0
  while d.getOffset() > 0.1 and waited < 100 do computer.pullSignal(0.1); waited = waited + 1 end
  computer.pullSignal(0.3)
  nav(label)
end

while true do
  local sig, _, _, _, _, _, cmd = computer.pullSignal()
  if sig == "modem_message" and cmd == "probe" then
    nav("起點")
    step("世界+X 6", 6, 0, 0)
    step("世界+Z 6", 0, 0, 6)
    step("世界+Y 6", 0, 6, 0)
    step("回起點", -6, -6, -6)
    report("PROBE_DONE")
  end
end
