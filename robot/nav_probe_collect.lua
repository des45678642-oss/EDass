-- T4 端：送出 probe 指令並顯示無人機傳回的導航座標。TAG 要和 T4server.lua 的 DRONE_GROUP_TAG 一致。
local component = require("component")
local event = require("event")
local modem = component.modem
local SERVER_PORT, TAG = 100, "A"
modem.open(SERVER_PORT)
modem.broadcast(SERVER_PORT, "SERVER_CMD", TAG, "probe")
print("已送出 probe，請同時記下無人機『起點』的 F3 座標 (XYZ) 與朝向")
while true do
  local raw = { event.pull(60, "modem_message") }
  if not raw[1] then print("60 秒沒收到資料") break end
  if raw[4] == SERVER_PORT and raw[7] == "DRONE_REPORT" and raw[8] == "REPORT" then
    if raw[9] == "PROBE" then print(raw[10]) elseif raw[9] == "PROBE_DONE" then print("完成") break end
  end
end
