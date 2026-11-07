-- 無人機 EEPROM 終極除錯版
local computer = computer
local tunnel = component.proxy(component.list("tunnel")())

tunnel.send("GET_CODE")

while true do
  local sig, _, _, _, _, msgType, codeString = computer.pullSignal(5)
  
  if not sig then
    tunnel.send("GET_CODE")
  end
  
  if sig == "modem_message" and msgType == "CODE_REPLY" and codeString then
    -- load 會回傳兩個值：(函式, 錯誤訊息)
    local run, err = load(codeString)
    
    if run then
      -- 嘗試執行程式，並用 pcall 捕捉執行時的錯誤
      local success, runtimeErr = pcall(run)
      if not success then
        -- 如果執行到一半死掉，把錯誤傳回中轉電腦
        tunnel.send("DRONE_ERROR: " .. tostring(runtimeErr))
        computer.beep(300, 1)
      end
    else
      -- 如果語法或記憶體編譯就失敗，把錯誤傳回中轉電腦
      tunnel.send("COMPILE_ERROR: " .. tostring(err))
      computer.beep(440, 1)
    end
    break
  end
end
