local component = require("component")
local event = require("event")
local fs = require("filesystem")

event.shouldInterrupt = function() return false end

for a in require('component').list('relay') do require('component').invoke(a, 'setStrength', 16) end

-- ────────── 【硬體地址指定區】 ──────────
local ASSIGNED_MODEM_ADDRESS  = "0456aae326c34ae5882179ef965ed130"

local TUNNEL_POOL = {
  ["A"] = "28ce",
  ["B"] = "b9f7",
}
-- ────────────────────────────────────────

local modem
if ASSIGNED_MODEM_ADDRESS and component.type(ASSIGNED_MODEM_ADDRESS) == "modem" then
  modem = component.proxy(ASSIGNED_MODEM_ADDRESS)
else
  if not component.isAvailable("modem") then error("❌ 找不到任何常規網絡卡 (Modem)！") end
  modem = component.modem
end

local tunnels = {}
local tunnel_addresses = {}

for tag, raw_uuid in pairs(TUNNEL_POOL) do
  if raw_uuid and type(raw_uuid) == "string" then
    local clean_uuid = raw_uuid:gsub("%s+", ""):lower()
    local verified_addr = nil
    for addr, c_type in component.list("tunnel") do
      if addr:sub(1, #clean_uuid) == clean_uuid then verified_addr = addr break end
    end
    if verified_addr then
      tunnels[tag] = component.proxy(verified_addr)
      tunnel_addresses[verified_addr] = tag
      print(string.format("🔗 [連接卡成功] 群組 [%s] 已綁定 -> UUID: %s...", tag, verified_addr:sub(1,8)))
    end
  end
end

if next(tunnels) == nil and component.isAvailable("tunnel") then
  local default_tunnel = component.tunnel
  tunnels["default"] = default_tunnel
  tunnel_addresses[default_tunnel.address] = "default"
  print("ℹ️ [提示] 自動啟用預設單張連接卡 [default]。")
end

if type(modem.setStrength) == "function" then
  modem.setStrength(400)
  print("📡 [無線網卡] 已成功初始化發信強度：400 格滿功率。")
end

local SERVER_PORT = 100           
local FILE_PORT = 101             
local STORAGE_MNT = "/mnt/4c8/"   

modem.open(SERVER_PORT)
modem.open(FILE_PORT)

local t4_server_address = nil

-- 🌟 【新增：多端下載管理核心變數】
local download_queue = {}    -- 下載排隊 FIFO 隊列
local is_transferring = false -- 本端目前是否正在傳送大檔案中

-- 🌟 繪製進度條的輔助工具
local function drawProgressBar(current, total)
    local percentage = math.floor((current / total) * 100)
    local width = 20 -- 進度條寬度（格數）
    local filled = math.floor((current / total) * width)
    local bar = string.rep("=", filled) .. (filled < width and ">" or "") .. string.rep(" ", width - filled - 1)
    -- 使用 \r 動態刷新當前行日誌
    io.write(string.format("\r   📈 傳輸進度: [%s] %d%% (%d/%d 行)", bar, percentage, current, total))
    io.flush()
    if current == total then io.write("\n") end
end

print("=============================================")
print("  【多工排隊型智慧中繼檔案伺服器】已啟動")
print("  - 硬碟區群網文件中心：監聽 Port " .. FILE_PORT)
print("  - 支援最大併發下載排隊隊列，")
print("=============================================")

-- 🌟 處理核心大檔案流式傳送與智慧握手（提取為獨立函數以利隊列排程）
local function processFileTransfer(target_client, requested_filename)
    is_transferring = true
    
    local sanitized_input = requested_filename:gsub("^/", "")
    local full_path = fs.canonical(fs.concat(STORAGE_MNT, sanitized_input))
    local check_base = fs.canonical(STORAGE_MNT)
    
    if full_path:sub(1, #check_base) ~= check_base then
        modem.send(target_client, FILE_PORT, "FILE_ERROR", "安全阻擋：超出限定儲存區！")
        is_transferring = false
        return
    end

    if not fs.exists(full_path) or fs.isDirectory(full_path) then
        modem.send(target_client, FILE_PORT, "FILE_ERROR", "中繼硬碟內找不到該檔案")
        is_transferring = false
        return
    end

    local lines = {}
    local f = io.open(full_path, "r")
    if f then
        for line in f:lines() do table.insert(lines, line) end
        f:close()
        
        local total_lines = #lines
        print(string.format("\n[開啟傳輸] 目標客戶端: [%s...] | 檔案: %s (%d 行)", target_client:sub(1,6), sanitized_input, total_lines))
        
        -- 1. 發送起點通知，並附帶詢問 (考慮到無線網卡，對端要用 %s 接收)
        modem.send(target_client, FILE_PORT, "FILE_START", requested_filename, total_lines)
        
        -- 3 秒雙向確認機制
        local proceed_download = true
        local handshake_event = { event.pull(3, "modem_message", nil, target_client, FILE_PORT) }
        
        -- 無線網卡解包：第 5 格 Distance 擠壓，自訂變數 cmd 在第 6 格
        if handshake_event[1] then
            local reply_cmd = handshake_event[6]
            if reply_cmd == "SKIP" then
                print("[客戶端回報] 取消資料發送")
                proceed_download = false
            elseif reply_cmd == "CONTINUE" then
                print("[客戶端回報] 內容已變更，開始傳輸檔案")
            end
        else
            proceed_download = false
            print("超過 3 秒未收到回應")
        end
        
        -- 2. 執行逐行發送與動態進度條渲染
        if proceed_download then
            for line_num, line_content in ipairs(lines) do
                modem.send(target_client, FILE_PORT, "FILE_LINE", line_num, line_content)
                if line_num % 10 == 0 or line_num == total_lines then
                    drawProgressBar(line_num, total_lines)
                end
                os.sleep(0.01) -- 降溫延時，防範網路洪水
            end
            modem.send(target_client, FILE_PORT, "FILE_END")
            print("✅ 檔案發送完畢。")
        else
            modem.send(target_client, FILE_PORT, "FILE_END")
			print("✅ 跳過檔案完畢。")
        end
    else
        modem.send(target_client, FILE_PORT, "FILE_ERROR", "中繼端系統讀取失敗")
    end

    is_transferring = false
end

-- 主控制無窮循環
while true do
    -- 1. 🌟 【隊列調度器】：如果目前沒有在傳大檔案，且排隊隊列裡有等待的客戶端，優先處理！
    if not is_transferring and #download_queue > 0 then
        local next_request = table.remove(download_queue, 1) -- 提取排在最前面的任務
        print(string.format("[隊列釋放] 正在為排隊中的客戶端 [%s...] 傳送檔案: %s", next_request.client:sub(1,6), next_request.file))
        -- 異步執行傳送
        processFileTransfer(next_request.client, next_request.file)
    end

    -- 2. 正常的網卡訊號拉取 (設定 0.5 秒小超時，好讓迴圈能隨時回頭執行上面的「隊列調度器」)
    local raw_event = { event.pull(0.5, "modem_message") }
    
    if raw_event[1] then
        local localAddr  = raw_event[2] 
        local remoteAddr = raw_event[3] 
        local port       = raw_event[4] 
        -- 🌟 【無線網卡自適應解包】：自動探查第 5 格是不是 Distance 數字，完美相容無線有線對接！
        local cmd, raw_filename
        if type(raw_event[5]) == "number" then
            cmd = raw_event[6]
            raw_filename = raw_event[7]
        else
            cmd = raw_event[6] -- 常規有線/Tunnel 下的解包
            raw_filename = raw_event[7]
        end
        
        local active_tunnel_tag = tunnel_addresses[localAddr]
        
        -- 狀況 A：收到來自無人機的連接卡訊號 (此處維持您原本的優良代碼)
        if active_tunnel_tag then
            local current_tunnel = tunnels[active_tunnel_tag]
            if cmd == "GET_CODE" then
                print(string.format("-> [通道 %s] 收到無人機請求！正在發送 drone_task.lua...", active_tunnel_tag))
                local f = io.open("drone_task.lua", "r")
                if f then
                    local code = f:read("*a")
                    f:close()
                    current_tunnel.send("CODE_REPLY", code)
                end
            else
                local drone_args = {}
                for i = 6, #raw_event do table.insert(drone_args, raw_event[i]) end
                if t4_server_address then
                    modem.send(t4_server_address, SERVER_PORT, active_tunnel_tag, table.unpack(drone_args))
                else
                    modem.broadcast(SERVER_PORT, active_tunnel_tag, table.unpack(drone_args))
                end
            end

        -- 狀況 B & C：常規網卡訊號
        elseif localAddr == modem.address then
            if port == SERVER_PORT then
                -- 基地與 T4 控制路由 (維持您原本的優良代碼)
                if cmd == "SERVER_CMD" then
                    local target_tunnel_tag = raw_event[7]
                    local s_cmd = raw_event[8]
                    t4_server_address = remoteAddr
                    if target_tunnel_tag == "close_relay" or s_cmd == "close_relay" then break end
                    local selected_tunnel = tunnels[target_tunnel_tag]
                    if selected_tunnel then
                        local server_args = {}
                        for i = 8, #raw_event do table.insert(server_args, raw_event[i]) end
                        selected_tunnel.send("DRONE_CMD", table.unpack(server_args))
                    end
                elseif cmd == "FORWARD_CMD" then
                    local target_uuid = raw_event[7]
                    local t_port = raw_event[8]
                    local forward_args = {}
                    for i = 9, #raw_event do table.insert(forward_args, raw_event[i]) end
                    if target_uuid and t_port then modem.send(target_uuid, t_port, table.unpack(forward_args)) end
                end

            -- 🌟 狀況 C：群網下載服務 (Port 101) ➔ 【大升級：全面引入異步高併發等待隊列】
            elseif port == FILE_PORT and cmd == "GET_FILE" then
                local requested_filename = ""
                if type(raw_filename) == "table" then
                    requested_filename = tostring(raw_filename[1] or raw_filename.name or "")
                else
                    requested_filename = tostring(raw_filename or "")
                end
                
                if requested_filename ~= "" then
                    -- 💡 【排隊防撞核心】：如果目前正在幫別台電腦發送大檔案，立刻把新請求塞進排隊名單！
                    if is_transferring then
                        table.insert(download_queue, { client = remoteAddr, file = requested_filename })
                        local current_position = #download_queue
                        print(string.format("伺服器正忙！客戶端 [%s...] 請求 '%s' 已排入，目前排在第 %d 位。", 
                            remoteAddr:sub(1,6), requested_filename, current_position))
                        
                        -- 回傳一個特殊的排隊封包給客戶端，讓它的下載程序稍微拉長超時，安心在原地等待
                        modem.send(remoteAddr, FILE_PORT, "FILE_QUEUE", current_position)
                    else
                        -- 如果目前伺服器閒置，直接執行傳送
                        processFileTransfer(remoteAddr, requested_filename)
                    end
                end
            end
        end
    end
end

print("【綜合中繼伺服器】已安全關閉。")
