-- 檔案路徑：/home/touch_menu.lua
local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

-- 🌟 載入外包的獨立模組（它們直接讀取本檔案 M 內的參數，不再由這裡傳遞）
local sdlogic = require("sdlogic")
local sdquery = require("sdquery")
local sdminer = require("sdminer")

local M = {} 
local timer_id, main_thread
local current_page = 1
local internal_counter = 0

-- ========================================================
-- 【玩家核心變數與硬體繫結整合】
-- ========================================================
local target_gpu_address      = "6429"   
local target_screen_address   = "a875"   
local refresh_delay           = 5        -- 畫面與動態補貨檢查間隔 (5 秒)
local default_cooldown        = 600      -- 全域預設冷卻時間（秒）

-- 檔案路徑配置
local config_file_path        = "/mnt/4c8/ae_config.json"
local log_file_path           = "/mnt/4c8/ae_log.txt"

-- 🌟 【AE2 遠端查詢：與 server.lua 中繼電腦配合】
local query_port              = 102      -- 本機監聽的查詢埠
local relay_port              = 100      -- server.lua 的 SERVER_PORT (回覆經中繼時使用)

-- 🌟 【第一頁：電池電量顯示】網路上所有 getName() 含此字串的 gt_machine 都會列出
-- (唱片機追蹤的電池仍然固定用下面的 battery_address)
local battery_name            = "multimachine.supercapacitor"
local battery_rescan_interval = 60       -- 重新搜尋電池的間隔(秒)；搜尋要對每台機器呼叫 getName，比較慢

-- 🌟 【速度相關】
local config_check_interval   = 10       -- 幾秒內不重新檢查 ae_config.json 是否被修改(掃描/轉換後會立刻重讀)
local query_mode              = "auto"   -- AE2 庫存查詢："filter" 每個 label 查一次 / "full" 一次查全部 / "auto" 物品多就用 full
local query_full_threshold    = 8        -- auto 模式下，物品超過幾個就改用 full

-- 🌟 【礦機調度 (mode_tag = "miner")】對應原本的 space_main.lua，需要本機有 modem 和轉運器
local miner_port              = 300      -- 與 space_miner.lua 約定的通訊埠
local miner_strength          = 16       -- 對礦機發信的強度 (送完會還原成原本的強度)
local miner_transposer_address = nil     -- 轉運器位址前綴；nil = 用預設那台
local miner_chest_side        = 1        -- 轉運器貼著共享終界箱的方向
local drone_item_name         = "gtnhintergalactic:item.MiningDrone"
local miner_cooldown          = 300      -- 飽和後的冷卻(秒)，到期全廠回收重新分配；一輪最長也是這個時間
local miner_dispatch_interval = 5        -- 每隔幾秒做一輪分配
local miner_msgs_per_tick     = 4        -- 每秒最多送幾則指令 (原本靠 os.sleep(0.1) 間隔)
local miner_settle            = 2        -- 指令送完後等幾秒再掃描終界箱 (讓礦機搬完物品)

-- 🌟 【新功能：低電量自動唱片機配置】
local battery_address         = "20b2"   -- 電池地址
local low_energy_threshold    = 50
local high_energy_threshold   = 60


-- 追蹤 AE2 請求狀態的持久表（會打包傳遞，不可刪除）
local active_ae_requests = {}
local last_order_time = {}

-- 【全域調度變數宣告】用於多配方全域唯一排隊互鎖機制
_G.current_global_task = _G.current_global_task or nil

-- 硬體代理與精確繫結
local gpu = nil
for addr in component.list("gpu") do
    if string.sub(addr, 1, #target_gpu_address) == target_gpu_address then
        gpu = component.proxy(addr)
        break
    end
end
if not gpu then gpu = component.gpu end

local full_screen_addr = nil
for addr in component.list("screen") do
    if string.sub(addr, 1, #target_screen_address) == target_screen_address then
        full_screen_addr = addr
        break
    end
end

local battery_comp = nil
for addr in component.list() do
    if string.sub(addr, 1, #battery_address) == battery_address then
        battery_comp = component.proxy(addr)
        break
    end
end

local jukebox_comp = nil
if component.isAvailable("jukebox") then
    jukebox_comp = component.jukebox
end

local transposer_comp = nil
for addr in component.list("transposer") do
    if not miner_transposer_address or string.sub(addr, 1, #miner_transposer_address) == miner_transposer_address then
        transposer_comp = component.proxy(addr)
        break
    end
end

local btn1 = { x = 5,  y = 3, w = 25, h = 4, label = "     電池電量     " }
local btn2 = { x = 35, y = 3, w = 25, h = 4, label = "   AE2 核心物資倉   " }
-- 第二頁專用：物品清單換頁鍵
local btn_prev = { x = 65, y = 3, w = 14, h = 4, label = "◀ 上一頁" }
local btn_next = { x = 81, y = 3, w = 14, h = 4, label = "下一頁 ▶" }
-- 第二頁專用：即時掃描 database 並新增尚未登錄的物品
local btn_scan = { x = 115, y = 3, w = 22, h = 4, label = "🔍 掃描新增物品" }
-- 第二頁專用：立刻回收全部礦機並重新分配 (原本 space_main 的「按 Enter 手動刷新」)
local btn_miner = { x = 139, y = 3, w = 20, h = 4, label = "⛏ 重新分配礦機" }
local database_slots = 81            -- database 升級最大格數 (Tier 3)
local items_per_page = 35               -- 第 16 列起到螢幕底部
local list_page, list_pages = 1, 1

-- component.database 在沒有資料庫升級時會直接拋錯，需先檢查
local db = nil
if component.isAvailable("database") then db = component.database end
local SCR_W, SCR_H = 160, 50

-- GTNH 2.9 之後物品與流體都要從 fluid_interface 查；舊版沒有它就退回 me_interface / me_controller
local ae = nil
if component.isAvailable("fluid_interface") then ae = component.fluid_interface
elseif component.isAvailable("me_interface") then ae = component.me_interface
elseif component.isAvailable("me_controller") then ae = component.me_controller end

local function get_now_time()
    return computer.uptime()
end

-- ========================================================
-- 【對外公開參數】sdapi / sdlogic / sdquery 直接從這裡讀取
-- ========================================================
M.gpu, M.ae, M.db = gpu, ae, db
M.SCR_W, M.SCR_H = SCR_W, SCR_H
M.config_file_path, M.log_file_path = config_file_path, log_file_path
M.default_cooldown = default_cooldown
M.active_ae_requests, M.last_order_time = active_ae_requests, last_order_time
M.battery, M.jukebox = battery_comp, jukebox_comp
M.energy_threshold, M.high_threshold = low_energy_threshold, high_energy_threshold
M.query_port, M.relay_port = query_port, relay_port
M.items_per_page = items_per_page
M.miner_port, M.miner_strength, M.miner_transposer = miner_port, miner_strength, transposer_comp
M.miner_chest_side, M.drone_item_name = miner_chest_side, drone_item_name
M.miner_cooldown, M.miner_dispatch_interval = miner_cooldown, miner_dispatch_interval
M.miner_msgs_per_tick, M.miner_settle = miner_msgs_per_tick, miner_settle
M.battery_name, M.battery_rescan_interval = battery_name, battery_rescan_interval
M.config_check_interval = config_check_interval
M.query_mode, M.query_full_threshold = query_mode, query_full_threshold
M.perf = nil             -- 第二頁每次刷新後由 sdlogic 填入耗時
M.battery_rescan_requested = true   -- 換到第一頁時強制重新搜尋電池
M.database_slots = database_slots
M.scan_message = nil     -- { text = "...", color = 0x... }，顯示在第二頁第 13 列
M.list_page, M.list_pages = list_page, list_pages
M.get_now_time = get_now_time

local function is_clicked(cx, cy, btn)
    return cx >= btn.x and cx < (btn.x + btn.w) and cy >= btn.y and cy < (btn.y + btn.h)
end

-- 第二頁的換頁鍵與頁碼（只在第二頁顯示）
function M.draw_pager()
    if current_page ~= 2 then return end
    local function draw_btn(btn, enabled)
        gpu.setBackground(enabled and 0x2255AA or 0x222222)
        gpu.setForeground(enabled and 0xFFFFFF or 0x666666)
        gpu.fill(btn.x, btn.y, btn.w, btn.h, " ")
        gpu.set(btn.x + 2, btn.y + 1, btn.label)
    end
    draw_btn(btn_prev, M.list_page > 1)
    draw_btn(btn_next, M.list_page < M.list_pages)
    draw_btn(btn_scan, true)
    draw_btn(btn_miner, sdminer.is_active())
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFF00)
    gpu.set(btn_next.x + btn_next.w + 2, btn_prev.y + 1, string.format("第 %d / %d 頁      ", M.list_page, M.list_pages))
    gpu.setForeground(0xFFFFFF)
end

-- 掃描結果訊息(第 13 列)
function M.draw_scan_message()
    if current_page ~= 2 then return end
    gpu.setBackground(0x000000)
    gpu.set(6, 13, string.rep(" ", 150))
    if not M.scan_message and not db then
        gpu.setForeground(0xFFAA00)
        gpu.set(6, 13, "[⚠️ 找不到 database 組件：無法掃描新增物品，其餘功能不受影響]")
    elseif M.scan_message then
        gpu.setForeground(M.scan_message.color or 0xFFFFFF)
        gpu.set(6, 13, M.scan_message.text)
    end
    gpu.setForeground(0xFFFFFF)
end

local function draw_navigation()
    -- 先綁定螢幕再設定解析度與繪製，否則第一次會畫到錯誤的螢幕
    if full_screen_addr then gpu.bind(full_screen_addr) end
    gpu.setResolution(SCR_W, SCR_H)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, SCR_W, SCR_H, " ")
    gpu.setBackground(current_page == 1 and 0x00FF00 or 0x222222)
    gpu.setForeground(current_page == 1 and 0x000000 or 0xDDDDDD)
    gpu.fill(btn1.x, btn1.y, btn1.w, btn1.h, " ")
    gpu.set(btn1.x + 2, btn1.y + 1, btn1.label)

    gpu.setBackground(current_page == 2 and 0x00FF00 or 0x222222)
    gpu.setForeground(current_page == 2 and 0x000000 or 0xDDDDDD)
    gpu.fill(btn2.x, btn2.y, btn2.w, btn2.h, " ")
    gpu.set(btn2.x + 2, btn2.y + 1, btn2.label)
    
    gpu.setBackground(0x000000)
    gpu.setForeground(0x555555)
    gpu.set(1, 8, string.rep("═", SCR_W))
    gpu.setForeground(0xFFFFFF)
    M.draw_pager()
end

local function init_page_background()
    gpu.setBackground(0x000000)
    gpu.fill(1, 9, SCR_W, SCR_H - 8, " ")
    
    sdlogic.reset_draw_cache()          -- 上面剛把整區清掉，快取必須一起作廢
    if current_page == 1 then
        -- 第一頁(電池)的內容全部由 sdlogic.render_page1 繪製
    elseif current_page == 2 then
        M.draw_scan_message()
        gpu.setForeground(0x00FFFF)
        gpu.set(6, 11, "◆─────────────────────────────── AE2 AUTOMATED INVENTORY CONTROL PANEL ───────────────────────────────◆")
        if not ae then
            gpu.setForeground(0xFF0000)
            gpu.set(6, 14, " [❌ 系統異常] 找不到物理 ME 控制器或介面元件！請檢查自動補貨線纜。")
        else
            gpu.setForeground(0xBBBBBB)
            gpu.set(6, 14, "  物 資 名 稱 ( ITEM LABEL )               |  目前庫存  | 自動補貨狀態 ( STATUS )")
            gpu.set(6, 15, "  ────────────────────────────────────────+────────────+───────────────────────────────────────────────")
        end
    end
    gpu.setForeground(0xFFFFFF)
end

-- ========================================================
-- 【動態資料刷新核心】（依要求：僅保留核心計時與頁面判斷）
-- ========================================================
local function update_dynamic_data(force_refresh)
    gpu.setBackground(0x000000)
    

	internal_counter = internal_counter + 1

    -- 礦機調度：每秒推進一次，不論目前在哪一頁
    pcall(sdminer.tick)
	
    -- 3. 根據頁面進行判斷與外包呼叫（保留判斷，內容清空由新檔案處理）
	
	local is_5s_elapsed = (internal_counter >= refresh_delay)
	
	if is_5s_elapsed or force_refresh then
        pcall(sdlogic.check_battery_and_play)
    end
	
    if is_5s_elapsed or force_refresh then
        if current_page == 1 then
            pcall(sdlogic.render_page1)
        elseif current_page == 2 and ae then
            pcall(sdlogic.render_page2)
        end
    end
	
	if is_5s_elapsed or force_refresh then
        internal_counter = 0
    end
	
    gpu.setForeground(0xFFFFFF)
end


local function switch_page(page_num)
    current_page = page_num
    M.battery_rescan_requested = true
    M.list_page = 1
    draw_navigation()
    init_page_background()
    update_dynamic_data(true)
end

-- 即時掃描 database，把還沒登錄的物品新增到 JSON，並更新畫面
function M.scan_now()
    local ok, n, added, skipped = pcall(sdlogic.scan_database)
    if not ok then
        M.scan_message = { text = "掃描失敗: " .. tostring(n), color = 0xFF5555 }
    elseif not n then
        M.scan_message = { text = "掃描失敗: " .. tostring(added), color = 0xFF5555 }
    elseif n == 0 then
        local extra = (skipped and #skipped > 0) and string.format("（%d 個 label 重複、name/damage 不同的物品已略過）", #skipped) or ""
        M.scan_message = { text = "掃描完成：沒有新增物品" .. extra, color = 0xBBBBBB }
    else
        local shown = {}
        for i = 1, math.min(#added, 5) do shown[#shown + 1] = added[i] end
        local more = #added > 5 and string.format(" ...等 %d 個", #added) or ""
        M.scan_message = { text = string.format("掃描完成：新增 %d 個物品 (%s%s)，預設為 monitor，請到設定檔設定補貨%s",
            n, table.concat(shown, ", "), more,
            (skipped and #skipped > 0) and string.format("；另有 %d 個 label 重複的已略過", #skipped) or ""), color = 0x00FF00 }
    end
    M.draw_scan_message()
    update_dynamic_data(true)
end

-- 觸控處理：頁籤切換 + 第二頁的上一頁/下一頁/掃描
function M.handle_touch(cx, cy)
    if is_clicked(cx, cy, btn1) and current_page ~= 1 then
        switch_page(1)
    elseif is_clicked(cx, cy, btn2) and current_page ~= 2 then
        switch_page(2)
    elseif current_page == 2 and is_clicked(cx, cy, btn_prev) and M.list_page > 1 then
        M.list_page = M.list_page - 1
        update_dynamic_data(true)
    elseif current_page == 2 and is_clicked(cx, cy, btn_next) and M.list_page < M.list_pages then
        M.list_page = M.list_page + 1
        update_dynamic_data(true)
    elseif current_page == 2 and is_clicked(cx, cy, btn_scan) then
        M.scan_now()
    elseif current_page == 2 and is_clicked(cx, cy, btn_miner) then
        if sdminer.refresh_now() then
            M.scan_message = { text = "已要求礦機重新分配：先回收全部無人機，再依庫存重新派工", color = 0x55AFFF }
        else
            M.scan_message = { text = "礦機模組未啟用 (需要本機有 transposer 和 modem)", color = 0xFF5555 }
        end
        M.draw_scan_message()
    end
end

function M.start()
    if timer_id or main_thread then return false, "服務已經在運行中" end
    if full_screen_addr then gpu.bind(full_screen_addr) end
    -- 初始化：轉換舊格式並檢查 database 有沒有新增的物品
    local init_ok, init_msg, init_err = pcall(sdlogic.init_config)
    if not init_ok then
        M.scan_message = { text = "初始化設定檔失敗: " .. tostring(init_msg), color = 0xFF5555 }
    elseif init_msg then
        M.scan_message = { text = init_msg, color = init_err and 0xFF5555 or 0x00FF00 }
    end
    switch_page(1)
    sdquery.start()
    pcall(sdminer.start)

    timer_id = event.timer(1.0, function() update_dynamic_data(false) end, math.huge)

    local thread = require("thread")
    main_thread = thread.create(function()
        while true do
            local e, s_addr, cx, cy = event.pull(0.5, "touch")
            if e == "touch" and (not full_screen_addr or s_addr == full_screen_addr) then
                M.handle_touch(cx, cy)
            end
        end
    end)
    return true
end

function M.stop()
    sdquery.stop()
    sdminer.stop()
    if timer_id then event.cancel(timer_id) timer_id = nil end
    if main_thread then main_thread:kill() main_thread = nil end
    term.clear()
    print("觸控服務已安全關閉。")
    return true
end

return M
