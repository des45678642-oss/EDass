-- T4 端：送出 place_probe 指令並顯示、儲存結果。TAG 要是你暫時改成 place_probe.lua 的那個通道。
-- 用法：place_probe_collect  [地面方塊的 Y，預設 81]
local component = require("component")
local event = require("event")
local modem = component.modem
local SERVER_PORT, TAG = 100, "C"
local args = { ... }
modem.open(SERVER_PORT)
modem.broadcast(SERVER_PORT, "SERVER_CMD", TAG, "probe_place", tonumber(args[1]) or 81)
print("已送出 probe_place (通道 " .. TAG .. ")，無人機會先蓋 24 根石柱再逐點測試，需要幾分鐘…")
local out = io.open("place_probe_result.txt", "w")
while true do
  local raw = { event.pull(300, "modem_message") }
  if not raw[1] then print("5 分鐘沒收到資料") break end
  if raw[4] == SERVER_PORT and raw[7] == "DRONE_REPORT" and raw[8] == "REPORT" then
    if raw[9] == "PROBE" then
      print(raw[10])
      if out then out:write(raw[10], "\n") end
    elseif raw[9] == "PROBE_DONE" then print("完成，已存到 place_probe_result.txt") break end
  end
end
if out then out:close() end
