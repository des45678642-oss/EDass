-- 檔案下載客戶端範例 (OpenComputers 電腦)：向中繼伺服器 (server.lua) 要檔案，存到本機。
-- 用法: filedl <伺服器網卡位址> <遠端檔名> <存檔路徑> [標籤]
--   標籤 (逗號分隔，預設都不開)：block = 整塊傳送，minify = 傳送前精簡 (Lua 程式用)
-- 同時支援逐行 (FILE_LINE) 與整塊 (FILE_BLOCK) 兩種傳送方式。
local component = require("component")
local event = require("event")
local modem = component.modem
local FILE_PORT = 101

local args = { ... }
local server, remote, dest, flags = args[1], args[2], args[3], args[4]
if not (server and remote and dest) then
  print("用法: filedl <伺服器位址> <遠端檔名> <存檔路徑> [block,minify]")
  return
end

modem.open(FILE_PORT)
if flags then modem.send(server, FILE_PORT, "GET_FILE", remote, flags) else modem.send(server, FILE_PORT, "GET_FILE", remote) end

local out, parts = {}, {}
while true do
  local e = { event.pull(30, "modem_message") }
  if not e[1] then print("逾時") return end
  local cmd = e[6]
  if cmd == "FILE_START" then
    modem.send(server, FILE_PORT, "CONTINUE")        -- 要略過就改送 "SKIP"
  elseif cmd == "FILE_LINE" then
    out[#out + 1] = e[8]
  elseif cmd == "FILE_BLOCK" then
    parts[e[7]] = e[9]
  elseif cmd == "FILE_QUEUE" then
    print("排隊中，第 " .. tostring(e[7]) .. " 位")
  elseif cmd == "FILE_ERROR" then
    print("錯誤: " .. tostring(e[7])) return
  elseif cmd == "FILE_END" then
    break
  end
end

local text
if #parts > 0 then text = table.concat(parts) else text = table.concat(out, "\n") .. "\n" end
local f = assert(io.open(dest, "w"))
f:write(text)
f:close()
print(string.format("已存到 %s (%d 位元組)", dest, #text))
