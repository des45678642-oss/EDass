-- T4 端：送出掃描指令，收集無人機 (scan_task.lua) 傳回的資料，存成 scan.txt。
-- 每行格式「方塊X 方塊Z 頂面座標」，直接給 mountain/mountain.py 的 --existing 使用。
-- 中斷後可以重新執行：已存在的 scan.txt 會接著寫 (重複的點不影響結果，mountain.py 取最後一筆)。
local component = require("component")
local event = require("event")
local modem = component.modem

local SERVER_PORT = 100
local TAG = "A"                          -- 與 T4server.lua 的 DRONE_GROUP_TAG 一致
local OUT = "scan.txt"

-- 掃描範圍 (世界方塊座標，含頭尾) 與取樣間隔。範圍外多留一圈平地，產生器才能校正高度
local X0, X1 = -65, 360
local Z0, Z1 = -640, -300
local STEP = 4       -- 取樣間隔：山體是平滑的，4 格足夠；改成 2 會多花 4 倍時間和電量

-- 接續上次進度：scan.txt 已有資料就從最後一列的下一列開始 (無人機沒電中斷後重新執行即可)
local last_z
local old = io.open(OUT, "r")
if old then
  for line in old:lines() do
    local _, z = line:match("^(-?%d+) (-?%d+) ")
    if z then z = tonumber(z); if not last_z or z > last_z then last_z = z end end
  end
  old:close()
end
if last_z and last_z >= Z0 and last_z < Z1 then
  Z0 = last_z + STEP
  print("接續上次進度，從 Z=" .. Z0 .. " 開始")
end

modem.open(SERVER_PORT)
local f = assert(io.open(OUT, "a"))

print(string.format("送出掃描指令：X %d~%d、Z %d~%d、間隔 %d", X0, X1, Z0, Z1, STEP))
modem.broadcast(SERVER_PORT, "SERVER_CMD", TAG, "scan_region", X0, X1, Z0, Z1, STEP)

local rows = 0
while true do
  local raw = { event.pull(120, "modem_message") }
  if not raw[1] then
    print("\n120 秒沒有新資料 (掃一列要好幾分鐘；無人機狀態文字是 CHARGE 代表在等電，其他請去看看它)，繼續等待，Ctrl+C 結束")
  elseif raw[4] == SERVER_PORT and raw[6] == TAG and raw[7] == "DRONE_REPORT" and raw[8] == "REPORT" then
    local kind = raw[9]
    if kind == "SCAN" then
      local z, x, step, csv = math.floor(raw[10]), math.floor(raw[11]), math.floor(raw[12]), raw[13]
      for v in tostring(csv):gmatch("[^,]+") do
        f:write(string.format("%d %d %s\n", x, z, v))
        x = x + step
      end
      f:flush()
      rows = rows + 1
      io.write(string.format("\r已收 %d 列 (Z=%d)   ", rows, z))
    elseif kind == "CALIB" then
      print("導航校正：" .. tostring(raw[10]))
    elseif kind == "SCAN_DONE" then
      print("\n掃描完成，共 " .. rows .. " 列，已存成 " .. OUT)
      break
    elseif kind == "ERROR" then
      print("\n無人機回報錯誤: " .. tostring(raw[10]))
      break
    end
  end
end
f:close()
