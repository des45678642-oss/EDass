local d = component.proxy(component.list("drone")())
local n = component.proxy(component.list("navigation")())
local i = component.proxy(component.list("inventory_controller")())
local g = component.proxy(component.list("generator")())
local t = component.proxy(component.list("tunnel")())
local me = component.proxy(component.list("upgrade_me")() or component.list("me_interface")() or "")
local db = component.proxy(component.list("database")() or "")

d.setStatusText("ECO")

-- 超輕量位置鎖定 (降低高頻檢查頻率，極大節省 CPU 電量)
local function move(dx, dy, dz)
  d.move(dx, dy, dz)
  while true do
    local ox, oy, oz = d.getOffset()
    if math.abs(ox or 0) < 0.05 and math.abs(oy or 0) < 0.05 and math.abs(oz or 0) < 0.05 then break end
    computer.pullSignal(0.1) -- 🌟 降低為 0.1 秒物理檢查，CPU 耗電直接減半！
  end
end

while true do
  local sig, _, _, _, _, _, cmd, x, z, dp, sY = computer.pullSignal()
  if sig == "modem_message" and cmd == "build_point" then
    
    -- 1. 原地極速物資請求 (拿掉數量檢查，少於5個由 ME 網絡自動承接，直接就地提領)
    if me and db then
      for s = 1, 4 do d.select(s) me.requestItems(db.address, s, 64) end
      if g then d.select(4) g.insert() end
    end
    
    -- 2. 🌟 防撞安全：原地垂直拉高到 Y=83 的高空絕對航道
    local cx, cy, cz = n.getPosition()
    if (cy or 81) < 83 then move(0, 83 - cy, 0) end
    
    -- 3. 在 Y:83 高空極速水平橫移至目標點正上方
    cx, cy, cz = n.getPosition()
    move(-200.5 + x - cx, 0, -49.5 - z - cz)
    
    -- 4. 垂直 3D 打樁工序：計算該格需要拍下的方塊總層數 (基岩在 74，施工從 75 開始)
    local total = (sY - dp) - 74
    
    if total > 0 then
      for layer = 1, total do
        local cur_y = 75 + (layer - 1)
        
        -- 下降到該方塊正上方 1 格準備投彈
        _, cy, _ = n.getPosition()
        move(0, (cur_y + 1) - cy, 0)
        
        -- 智慧材料選取（去重版）：表面層以下用 3(鵝卵石)；封頂層依深度選 1(泥土) 或 2(沙子)
        if layer < total then
          d.select(3)
        else
          d.select((dp == 1 or dp == 2) and 1 or 2)
        end
        
        -- 純淨正下方放置
        d.place(0)
      end
    end
    
    -- 5. 一對一完工握手放行
    if t then
      --t.send("REPORT", "PLACE_RESULT", "SUCCESS", x, z)
	  t.send("DRONE_REPORT", "REPORT", "PLACE_RESULT", "SUCCESS", x, z)
      --t.send("REPORT", "PROGRESS", x, z)
    end
    
  end
end
