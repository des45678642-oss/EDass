local component = require("component")
local event = require("event")
local fs = require("filesystem")

event.shouldInterrupt = function() return false end

-- ────────── 【硬體地址指定區】 ──────────
-- 💡 請在電腦輸入 components 查看您網卡與各張連接卡的精確 UUID 並填入下方：
local ASSIGNED_MODEM_ADDRESS  = "0456aae326c34ae5882179ef965ed130"  -- 例如: "1a2b3c4d..." (一般無線網卡)

-- 🌟 【多連接卡池配置】
-- 你可以插上多張連接卡，並在這裡給它們命名標籤（標籤可自訂，UUID 請根據 components 查詢填入）
local TUNNEL_POOL = {
  ["A"] = "28ce", -- 例如: "5e6f7g8h..."
  ["B"] = "b9f7", -- 例如: "9x8y7z6w..."
}
-- ────────────────────────────────────────

-- 1. 精準獲取一般網路卡組件
local modem
if ASSIGNED_MODEM_ADDRESS and component.type(ASSIGNED_MODEM_ADDRESS) == "modem" then
  modem = component.proxy(ASSIGNED_MODEM_ADDRESS)
else
  if not component.isAvailable("modem") then error("❌ 找不到任何常規網絡卡 (Modem)！") end
  modem = component.modem
end

-- 🌟 【多連接卡池配置 - 優化修復版】
local tunnels = {}
local tunnel_addresses = {}

for tag, raw_uuid in pairs(TUNNEL_POOL) do
  if raw_uuid and type(raw_uuid) == "string" then
    -- 1. 防呆處理：去除前後空格，並強制轉換成全小寫
    local clean_uuid = raw_uuid:gsub("%s+", ""):lower()
    
    -- 2. 寬容型完整匹配：先用 component.list 掃描該地址是否存在且為 tunnel
    local verified_addr = nil
    for addr, c_type in component.list("tunnel") do
      -- 支援縮寫（只要前幾個字對了就放行）或完整 UUID 匹配
      if addr:sub(1, #clean_uuid) == clean_uuid then
        verified_addr = addr
        break
      end
    end
    
    -- 3. 綁定代理物件
    if verified_addr then
      tunnels[tag] = component.proxy(verified_addr)
      tunnel_addresses[verified_addr] = tag
      print(string.format("🔗 [連接卡成功] 群組 [%s] 已綁定 -> UUID: %s...", tag, verified_addr:sub(1,8)))
    else
      -- 如果防呆後還是找不到，列出當前電腦上所有真實存在的 tunnel 提供比對
      print(string.format("❌ [警告] 找不到群組 [%s] 的連接卡！您填寫的是: '%s'", tag, raw_uuid))
      print("   目前電腦上實際存在的連接卡地址有：")
      local found_any = false
      for addr in component.list("tunnel") do
        print("   -> " .. addr)
        found_any = true
      end
      if not found_any then print("   -> (⚠️ 警告：這台電腦目前連一張連接卡都沒偵測到！)") end
    end
  end
end


-- 💡 保留安全機制：如果使用者沒設定池子，但電腦插了預設連接卡，自動將其歸類為 "default" 群組
if next(tunnels) == nil then
  if component.isAvailable("tunnel") then
    local default_tunnel = component.tunnel
    tunnels["default"] = default_tunnel
    tunnel_addresses[default_tunnel.address] = "default"
    print("ℹ️ [提示] 連接卡池為空，已自動啟用預設單張連接卡，歸類為 [default] 群組。")
  else
    error("❌ 系統找不到任何可用的連接卡 (Linked Card)！")
  end
end

-- 📡 【強制設定無線網卡發信強度】
if type(modem.setStrength) == "function" then
  modem.setStrength(400)
  print("📡 [無線網卡] 已成功初始化發信強度：400 格滿功率。")
end

-- ────────── 【網路連接埠配置與路徑常數】 ──────────
local SERVER_PORT = 100           -- 與 T4 伺服器以及一般控制電腦約定的通訊埠
local FILE_PORT = 101             -- 專門用來提供「檔案查詢與下載」的通訊埠
local STORAGE_MNT = "/mnt/4c8/"   -- 外部硬碟的嚴格限定存取根目錄

modem.open(SERVER_PORT)
modem.open(FILE_PORT)
-- ────────────────────────────────────────

local t4_server_address = nil

print("=============================================")
print("  【多連接卡動態切換型中繼檔案伺服器】已啟動")
print("  - 網卡主控位置：" .. modem.address:sub(1,8) .. "...")
print("  - 無人機端 (本地 /home 讀取)：運行中       ")
print("  - 基地跨網指令路由轉發：運行中             ")
print("  - 硬碟區群網文件中心：監聽 Port " .. FILE_PORT)
print("=============================================")

while true do
  local raw_event = { event.pullMultiple("modem_message") }
  
  -- 解析基本網絡參數
  local localAddr  = raw_event[2] -- 接收到此訊號的本機網卡/連接卡 UUID
  local remoteAddr = raw_event[3] -- 發送端的網卡 UUID
  local port       = raw_event[4] -- 接收的埠號 (連接卡固定為 0)
  local arg1       = raw_event[6] -- 自訂的第一個變數
  
  -- 🌟 檢查此訊號是不是來自「連接卡池」的某一條通道
  local active_tunnel_tag = tunnel_addresses[localAddr]
  
  -- =========================================================================
  -- 狀況 A：收到來自【無人機】（經由【某一條連接卡通道】接收，Port 固定為 0）的訊號
  -- =========================================================================
  if active_tunnel_tag then
    local current_tunnel = tunnels[active_tunnel_tag]
    
    -- 狀況 A-1：無人機開機索取程式碼 (可依據不同群組無人機發送不同檔案，預設仍為 drone_task.lua)
    if arg1 == "GET_CODE" then
      print(string.format("-> [通道 %s] 收到無人機請求！正在發送 drone_task.lua...", active_tunnel_tag))
      local f = io.open("drone_task.lua", "r")
      if f then
        local code = f:read("*a")
        f:close()
        current_tunnel.send("CODE_REPLY", code)
        print(string.format("-> [通道 %s] 程式碼已成功回傳給無人機。", active_tunnel_tag))
      else
        print("❌【錯誤】中轉電腦找不到 drone_task.lua 檔案！")
      end
    
        -- 狀況 A-2：無人機回傳的一般狀態或資料
    else
      print(string.format("-> [通道 %s] 收到無人機訊息: %s", active_tunnel_tag, tostring(arg1)))
      
      -- 🌟 【流線化修正】：直接將無人機傳來的所有原始參數（含 "DRONE_REPORT"）提取出來
      local drone_args = {}
      for i = 6, #raw_event do
        table.insert(drone_args, raw_event[i])
      end
      
      -- 🌟 【核心對齊】：第一個自訂變數直接傳送「群組標籤」，後半段則完美解包無人機原本的內容
      -- 這樣 T4 接收到的第一個參數 (raw[6]) 就會 100% 是群組標籤（例如 "A"）
      if t4_server_address then
        modem.send(t4_server_address, SERVER_PORT, active_tunnel_tag, table.unpack(drone_args))
      else
        modem.broadcast(SERVER_PORT, active_tunnel_tag, table.unpack(drone_args))
      end
    end

  
  -- =========================================================================
  -- 狀況 B 與 C：經由【一般無線網卡】接收到的基地網絡訊號
  -- =========================================================================
  elseif localAddr == modem.address then

    -- 狀況 B：常規區網控制指令 (Port 100)
    if port == SERVER_PORT then
      
      -- 子狀況 B-1：標準 T4 伺服器/控制電腦管理指令
      -- 格式：modem.broadcast(100, "SERVER_CMD", "要使用的連接卡標籤(Tag)", "實際命令", ...)
      if arg1 == "SERVER_CMD" then
        local target_tunnel_tag = raw_event[7] -- 💡 這是新增的：指定發信的連接卡標籤
        local cmd = raw_event[8]               -- 實際的無人機指令
        
        t4_server_address = remoteAddr -- 記錄 T4 位址
        
        if target_tunnel_tag == "close_relay" or cmd == "close_relay" then
          print("\n⚠️ 收到 T4 伺服器遠端關閉指令，正在安全停止中繼服務...")
          break
        end
        
        -- 檢查指定的連接卡是否存在
        local selected_tunnel = tunnels[target_tunnel_tag]
        if selected_tunnel then
          print(string.format("<- [區網端] 收到 T4 指令，正在切換至連接卡 [%s] 轉發: 【%s】", target_tunnel_tag, tostring(cmd)))
          
          -- 收集後續所有真正的無人機控制參數
          local server_args = {}
          for i = 8, #raw_event do
            table.insert(server_args, raw_event[i])
          end
          -- 使用動態選中的連接卡發送出去
          selected_tunnel.send("DRONE_CMD", table.unpack(server_args))
        else
          print(string.format("❌ [錯誤] T4 請求使用群組 [%s] 的連接卡，但該卡未在池中配置！", tostring(target_tunnel_tag)))
        end
      
      -- 子狀況 B-2：跨電腦指令轉發
      elseif arg1 == "FORWARD_CMD" then
        local target_computer_uuid = raw_event[7]
        local target_port = raw_event[8]
        
        local forward_args = {}
        for i = 9, #raw_event do
          table.insert(forward_args, raw_event[i])
        end
        
        if target_computer_uuid and target_port then
          print(string.format("🔄 [轉發路由] 幫忙轉發指令給電腦 [%s] 的 Port [%d]", target_computer_uuid:sub(1,8), target_port))
          modem.send(target_computer_uuid, target_port, table.unpack(forward_args))
        else
          print("⚠️ 收到轉發請求，但缺少目標 UUID 或 Port！")
        end
      end
	    -- =========================================================================
  -- 🌟 狀況 C：協助其他電腦【查詢 / 下載文件檔案】（強類型防崩潰流式版）
  -- =========================================================================
  elseif port == FILE_PORT then
    if arg1 == "GET_FILE" then
      local raw_filename = raw_event[7]
      
      -- 🌟 【核心修正】：如果收到的不是字串（例如是 Table），嘗試將其解包或強制轉換，防止系統崩潰
      local requested_filename = nil
      if type(raw_filename) == "table" then
        requested_filename = tostring(raw_filename[1] or raw_filename.name or "")
      else
        requested_filename = tostring(raw_filename or "")
      end
      
      print("📂 [流式文件服務] 處理來自 [" .. remoteAddr:sub(1,8) .. "] 的請求，解析檔名: " .. requested_filename)
      
      if requested_filename and requested_filename ~= "" then
        -- 1. 防呆：去掉開頭斜線
        local sanitized_input = requested_filename:gsub("^/", "")
        
        -- 2. 合成絕對路徑
        local full_path = fs.canonical(fs.concat(STORAGE_MNT, sanitized_input))
        local check_base = fs.canonical(STORAGE_MNT)
        
        if full_path:sub(1, #check_base) == check_base then
          -- 3. 檢查檔案是否存在
          if fs.exists(full_path) and not fs.isDirectory(full_path) then
            local lines = {}
            local f = io.open(full_path, "r")
            if f then
              for line in f:lines() do table.insert(lines, line) end
              f:close()
              
              local total_lines = #lines
              print(string.format("📦 檔案安全驗證成功！即將發送: %s (%d 行)", full_path, total_lines))
              
              -- 發送握手
              modem.send(remoteAddr, FILE_PORT, "FILE_START", requested_filename, total_lines)
              os.sleep(0.1)
              
              -- 逐行發送
              for line_num, line_content in ipairs(lines) do
                modem.send(remoteAddr, FILE_PORT, "FILE_LINE", line_num, line_content)
                os.sleep(0.05)
              end
              
              modem.send(remoteAddr, FILE_PORT, "FILE_END")
              print("✅ [流式文件服務] 檔案發送完畢。")
            else
              modem.send(remoteAddr, FILE_PORT, "FILE_ERROR", "中繼端系統讀取失敗")
            end
          else
            modem.send(remoteAddr, FILE_PORT, "FILE_ERROR", "中繼硬碟內找不到該檔案")
            print("❌ [文件服務] 找不到檔案，真實路徑為: " .. full_path)
          end
        else
          modem.send(remoteAddr, FILE_PORT, "FILE_ERROR", "安全阻擋：超出限定儲存區！")
          print("⚠️ [安全警報] 越權路徑請求已被攔截！")
        end
      else
        modem.send(remoteAddr, FILE_PORT, "FILE_ERROR", "無法解析的無效檔名")
      end
    end
  end

end
end

print("【綜合中繼伺服器】已安全關閉。")
