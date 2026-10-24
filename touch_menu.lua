-- 檔案路徑：/home/touch_menu.lua
local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

-- 🌟 載入外包的獨立模組（它們直接讀取本檔案 M 內的參數，不再由這裡傳遞）
local sdapi = require("sdapi")
local sdlogic = require("sdlogic")
local sdquery = require("sdquery")

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
local time_delay              = 300
local time_counter = time_delay 

-- 檔案路徑配置
local config_file_path        = "/mnt/4c8/ae_config.json"
local log_file_path           = "/mnt/4c8/ae_log.txt"
local realtime_path           = "/mnt/4c8/realtime.txt"

-- 🌟 【AE2 遠端查詢：與 server.lua 中繼電腦配合】
local query_port              = 102      -- 本機監聽的查詢埠
local relay_port              = 100      -- server.lua 的 SERVER_PORT (回覆經中繼時使用)

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

local btn1 = { x = 5,  y = 3, w = 25, h = 4, label = "   系統時間大螢幕   " }
local btn2 = { x = 35, y = 3, w = 25, h = 4, label = "   AE2 核心物資倉   " }
-- 第二頁專用：物品清單換頁鍵
local btn_prev = { x = 65, y = 3, w = 14, h = 4, label = "◀ 上一頁" }
local btn_next = { x = 81, y = 3, w = 14, h = 4, label = "下一頁 ▶" }
local items_per_page = 35               -- 第 16 列起到螢幕底部
local list_page, list_pages = 1, 1

-- component.database 在沒有資料庫升級時會直接拋錯，需先檢查
local db = nil
if component.isAvailable("database") then db = component.database end
local SCR_W, SCR_H = 160, 50

local ae = nil
if component.isAvailable("me_interface") then ae = component.me_interface
elseif component.isAvailable("me_controller") then ae = component.me_controller end

local function get_now_time()
    return computer.uptime()
end

-- ========================================================
-- 【對外公開參數】sdapi / sdlogic / sdquery 直接從這裡讀取
-- ========================================================
M.gpu, M.ae, M.db = gpu, ae, db
M.SCR_W, M.SCR_H = SCR_W, SCR_H
M.config_file_path, M.log_file_path, M.realtime_path = config_file_path, log_file_path, realtime_path
M.default_cooldown = default_cooldown
M.active_ae_requests, M.last_order_time = active_ae_requests, last_order_time
M.battery, M.jukebox = battery_comp, jukebox_comp
M.energy_threshold, M.high_threshold = low_energy_threshold, high_energy_threshold
M.query_port, M.relay_port = query_port, relay_port
M.items_per_page = items_per_page
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
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFF00)
    gpu.set(btn_next.x + btn_next.w + 2, btn_prev.y + 1, string.format("第 %d / %d 頁      ", M.list_page, M.list_pages))
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
    
    if current_page == 1 then
        gpu.setForeground(0xFFFF00)
        gpu.set(15, 15, "╔═════════════════════════════════════════════════════════════════════════════════════════╗")
        gpu.set(15, 16, "║                                                                                         ║")
        gpu.set(15, 17, "║   [ REALWORLD TIME SYSTEM ]                                                             ║")
        gpu.set(15, 18, "║                                                                                         ║")
        gpu.set(15, 19, "║   ► 目前真實時間 (TIME) :                                                               ║")
        gpu.set(15, 20, "║                                                                                         ║")
        gpu.set(15, 21, "║   ► 目前真實日期 (DATE) :                                                               ║")
        gpu.set(15, 22, "║                                                                                         ║")
        gpu.set(15, 23, "╚═════════════════════════════════════════════════════════════════════════════════════════╝")
    elseif current_page == 2 then
        gpu.setForeground(0x00FFFF)
        gpu.set(6, 11, "◆─────────────────────────────── AE2 AUTOMATED INVENTORY CONTROL PANEL ───────────────────────────────◆")
        if not ae then
            gpu.setForeground(0xFF0000)
            gpu.set(6, 14, " [❌ 系統異常] 找不到物理 ME 控制器或介面元件！請檢查自動補貨線纜。")
        elseif not db then
            gpu.setForeground(0xFF5555)
            gpu.set(6, 14, " [⚠️ 設備缺漏] 找不到資料庫晶片 (Database Upgrade)！無法動態解析組態。")
        else
            gpu.setForeground(0xBBBBBB)
            gpu.set(6, 14, "  物 資 名 稱 ( ITEM LABEL BY DB )        |  目前庫存  | 自動補貨狀態 ( STATUS )")
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
    
    -- 1. 時間核心計時器邏輯（保留）
	if time_counter >= time_delay then
        pcall(sdapi.update_time) 
        time_counter = 0
    else
        -- 不分頁面都推進時鐘，切回第一頁時才不會顯示過期時間
        pcall(sdapi.local_tick_time, 1)
        time_counter = time_counter + 1
    end
	
	internal_counter = internal_counter + 1
	
    -- 3. 根據頁面進行判斷與外包呼叫（保留判斷，內容清空由新檔案處理）
	
	local is_5s_elapsed = (internal_counter >= refresh_delay)
	
	if is_5s_elapsed or force_refresh then
        pcall(sdlogic.check_battery_and_play)
    end
	
    if current_page == 1 then
        pcall(sdlogic.render_page1)

    elseif current_page == 2 and ae and db then
        if is_5s_elapsed or force_refresh then
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
    M.list_page = 1
    draw_navigation()
    init_page_background()
    update_dynamic_data(true)
end

-- 觸控處理：頁籤切換 + 第二頁的上一頁/下一頁
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
    end
end

function M.start()
    if timer_id or main_thread then return false, "服務已經在運行中" end
    if full_screen_addr then gpu.bind(full_screen_addr) end
    switch_page(1)
    sdquery.start()

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
    if timer_id then event.cancel(timer_id) timer_id = nil end
    if main_thread then main_thread:kill() main_thread = nil end
    term.clear()
    print("觸控服務已安全關閉。")
    return true
end

return M
