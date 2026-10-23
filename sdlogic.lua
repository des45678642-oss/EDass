-- 檔案路徑：sd_logic.lua
local io = require("io")
local component = require("component")

local sdapi = require("sdapi")
local json = require("sdjson")
local fs = require("filesystem")

local sdlogic = {}

-- 直接讀取主程式 touch_menu 的參數(gpu、ae、db、路徑…)，不再由主程式打包傳遞。
-- 延遲 require，避免 touch_menu 載入階段互相循環引用。
local function main() return require("touch_menu") end

-- ========================================================
-- 【字元寬度輔助】OpenComputers 的 unicode 函式庫；測試環境退回 utf8
-- ========================================================
local has_unicode, unicode = pcall(require, "unicode")
if not has_unicode then unicode = nil end

local function ulen(s)
    if unicode and unicode.wlen then return unicode.wlen(s) end
    return utf8.len(s) or #s
end

-- 取前 n 個字元（不會切斷 UTF-8 多位元組字元）
local function usub(s, n)
    if n <= 0 then return "" end
    if unicode and unicode.sub then return unicode.sub(s, 1, n) end
    local len = utf8.len(s)
    if not len or len <= n then return s end
    return s:sub(1, utf8.offset(s, n + 1) - 1)
end

-- 依顯示寬度補空白（超過則截斷），修正 %-35s 以位元組計算造成的中文錯位
local function fit(s, w)
    s = tostring(s)
    while ulen(s) > w do
        local chars = utf8.len(s) or #s
        s = usub(s, chars - 1)
    end
    return s .. string.rep(" ", w - ulen(s))
end
sdlogic.fit = fit
sdlogic.usub = usub


-- ========================================================
-- 【設定檔載入】ae_config.json (原本在 sdapi.load_hybrid_config)
-- 每筆物品只寫 database 格子編號 slot；name / damage / label 載入時用 database.get 查詢。
-- ========================================================
local MODES = { restock = true, clone = true, monitor = true }
local parse_cache = { path = nil, mtime = nil, data = nil }
local last_good = nil

-- JSON 的 null 視同沒填
local function val(x)
    if x == json.null then return nil end
    return x
end

local function is_int(n) return type(n) == "number" and n == math.floor(n) end

-- 讀取並解析 JSON；檔案沒變 (lastModified 相同) 就沿用上次解析結果
function sdlogic.parse_config_file(path)
    if not fs.exists(path) then return nil, "找不到設定檔 " .. tostring(path) end
    local ok, mtime = pcall(fs.lastModified, path)
    if not ok then mtime = nil end
    if mtime and parse_cache.path == path and parse_cache.mtime == mtime and parse_cache.data then
        return parse_cache.data
    end
    local f = io.open(path, "r")
    if not f then return nil, "無法開啟設定檔 " .. tostring(path) end
    local text = f:read("*a")
    f:close()
    local data, err = json.decode(text or "")
    if not data then return nil, "JSON 格式錯誤: " .. tostring(err) end
    if type(data) ~= "table" or type(data.items) ~= "table" then
        return nil, 'JSON 最上層必須是物件且含有 "items" 陣列'
    end
    parse_cache.path, parse_cache.mtime, parse_cache.data = path, mtime, data
    return data
end

-- 依 JSON 的 database 欄位(位址前綴)選擇資料庫元件；沒填或找不到就用主程式預設的 db
function sdlogic.get_database()
    local m = main()
    local data = parse_cache.data
    local prefix = data and val(data.database)
    if type(prefix) == "string" and prefix ~= "" then
        local ok, found = pcall(function()
            for addr in component.list("database") do
                if addr:sub(1, #prefix) == prefix:lower() then return component.proxy(addr) end
            end
        end)
        if ok and found then return found end
    end
    return m.db
end

-- 驗證單筆設定並用 database 補齊 name/damage/label。回傳 entry 或 nil, 錯誤訊息
local function build_entry(raw, index, db)
    if type(raw) ~= "table" or raw == json.null then return nil, string.format("第 %d 筆不是物件", index) end
    local slot = val(raw.slot)
    if not (is_int(slot) and slot > 0) then return nil, string.format("第 %d 筆: slot 必須是正整數", index) end
    local tag = "slot " .. slot
    local mode = val(raw.mode_tag)
    if not MODES[mode or ""] then return nil, tag .. ": mode_tag 必須是 restock / clone / monitor" end

    local target = val(raw.target_quantity)
    local once = val(raw.target_once)
    local cooldown = val(raw.cooldown)
    if mode ~= "monitor" or target ~= nil then
        if type(target) ~= "number" or target < 0 then return nil, tag .. ": target_quantity 必須是數字 (>=0)" end
    end
    target = target or 0
    if mode == "restock" then
        if type(once) ~= "number" or once <= 0 then return nil, tag .. ": restock 需要 target_once > 0" end
    else
        once = 0
    end
    if cooldown ~= nil and (type(cooldown) ~= "number" or cooldown < 0) then
        return nil, tag .. ": cooldown 必須是數字 (>=0) 或省略"
    end
    local circuit, priority = nil, 9
    if mode == "clone" then
        circuit = val(raw.circuit)
        if not (is_int(circuit) and circuit >= 1 and circuit <= 24) then return nil, tag .. ": clone 需要 circuit (1~24)" end
        local p = val(raw.priority)
        if p ~= nil then
            if not (is_int(p) and p >= 1 and p <= 9) then return nil, tag .. ": priority 必須是 1~9" end
            priority = p
        end
    end

    local ok, stack = pcall(db.get, slot)
    if not ok or type(stack) ~= "table" or not stack.label then
        return nil, string.format("database 格子 %d 是空的或無法讀取", slot)
    end
    return {
        slot = slot, name = stack.name, damage = stack.damage, label = stack.label,
        target_quantity = target, target_once = once, cooldown = cooldown,
        mode_tag = mode, circuit = circuit, priority = priority,
    }
end

-- 回傳 items, errors。設定有問題的項目會被略過並列在 errors，絕不丟出例外。
function sdlogic.load_hybrid_config()
    local m = main()
    local errors = {}
    local data, err = sdlogic.parse_config_file(m.config_file_path)
    if not data then
        if last_good and fs.exists(m.config_file_path) then
            -- 檔案存在但暫時壞掉(例如編輯到一半)：沿用上次正確的設定，避免誤解除全域鎖
            data = last_good
            errors[#errors + 1] = "設定檔錯誤，沿用上次設定: " .. err
        else
            return {}, { err }
        end
    else
        last_good = data
    end
    local db = sdlogic.get_database()
    if not db then return {}, { "找不到 database 組件" } end
    local items = {}
    for i, raw in ipairs(data.items) do
        local entry, e = build_entry(raw, i, db)
        if entry then items[#items + 1] = entry else errors[#errors + 1] = e end
    end
    return items, errors
end

-- 查詢單一物品在 AE2 網路內的總數量。失敗回傳 nil, 錯誤訊息 (呼叫端不可當成 0 處理)
function sdlogic.count_item(entry, ae)
    ae = ae or main().ae
    if not ae then return nil, "找不到 ME 介面" end
    local ok, items = pcall(ae.getItemsInNetwork, { label = entry.label })
    if not ok or type(items) ~= "table" then return nil, "AE2 查詢失敗" end
    local total = 0
    for _, it in ipairs(items) do
        if it.label == entry.label
            and (entry.name == nil or it.name == nil or it.name == entry.name)
            and (entry.damage == nil or it.damage == nil or it.damage == entry.damage) then
            total = total + (it.size or 0)
        end
    end
    return total
end

-- 測試用：清掉快取
function sdlogic._reset_config_cache()
    parse_cache.path, parse_cache.mtime, parse_cache.data = nil, nil, nil
    last_good = nil
end

-- 全域鎖持有者若已不在設定檔中，或不再是特殊複製模式，就強制解鎖，
-- 避免其他複製物品永遠排隊。
function sdlogic.release_stale_lock(monitor_items)
    local current = _G.current_global_task
    if not current then return end
    for _, info in ipairs(monitor_items) do
        if info.label == current and info.mode_tag == "clone" then
            return
        end
    end
    _G.current_global_task = nil
    if component.isAvailable("modem") then
        component.modem.broadcast(201, "STOP_CLONE")
    end
end

-- 處理第一頁：系統時間顯示與微調
function sdlogic.render_page1()
    local ctx = main()
    local file_time, file_date = sdapi.read_saved_time()
    ctx.gpu.setForeground(0xFFFF00)
    ctx.gpu.set(43, 19, file_time .. "        ")
    ctx.gpu.set(43, 21, file_date .. "        ")
end

-- 處理第二頁：AE2 核心庫存盤點、佇列智慧調度與補貨下單
function sdlogic.render_page2()
    local ctx = main()
    local now_time = ctx.get_now_time()
    -- 1. 即時重新解析設定檔
    local monitor_items, cfg_errors = sdlogic.load_hybrid_config()
    
    -- 如果設定檔是空的或不存在，清除下方舊殘影並給予提示
    sdlogic.release_stale_lock(monitor_items)
    if #monitor_items == 0 then
        ctx.list_page, ctx.list_pages = 1, 1
        ctx.draw_pager()
        ctx.gpu.setForeground(0xFFEE00)
        if cfg_errors[1] then ctx.gpu.set(6, 19, "  " .. fit(cfg_errors[1], 120)) end
        ctx.gpu.set(6, 17, " ⚠️ 目前 ae_config.json 為空、格式錯誤或硬碟未正確掛載。                        ")
        return
    end
    
    -- 擦除舊數據，防止更換更短的設定檔時產生文字殘影
    ctx.gpu.fill(1, 16, ctx.SCR_W, ctx.SCR_H - 15, " ")

    -- 設定檔錯誤提示(第 12 列；清空舊內容)
    ctx.gpu.set(6, 12, string.rep(" ", 150))
    if cfg_errors[1] then
        ctx.gpu.setForeground(0xFF5555)
        local more = #cfg_errors > 1 and string.format(" (另有 %d 項)", #cfg_errors - 1) or ""
        ctx.gpu.set(6, 12, fit("⚠️ " .. cfg_errors[1] .. more, 150))
    end

    -- 分頁：全部物品照常運算與下單，但畫面只顯示目前這一頁
    local per_page = ctx.items_per_page
    local pages = math.max(1, math.ceil(#monitor_items / per_page))
    ctx.list_page = math.min(math.max(ctx.list_page, 1), pages)
    ctx.list_pages = pages
    ctx.draw_pager()
    local first_idx = (ctx.list_page - 1) * per_page + 1
    local last_idx = first_idx + per_page - 1
    
    local log_lines = {}
    -- 遍歷動態物品清單
    for idx, item_info in ipairs(monitor_items) do
        local item_name = item_info.label
        local count = sdlogic.count_item(item_info, ctx.ae)

        -- 格式化儲存數量 (1M/1K)；查詢失敗顯示 ?
        local count_str = "?"
        if count then
            count_str = tostring(count)
            if count >= 1000000 then
                count_str = string.format("%.2fM", count / 1000000)
            elseif count >= 1000 then
                count_str = string.format("%.1fK", count / 1000)
            end
        end

        local status_msg = ""
        local item_cooldown = item_info.cooldown or ctx.default_cooldown
        local req_handle = ctx.active_ae_requests[item_name]
        local tag1, tag2, tag3 = 0, 0, 0
        
        -- 異步追蹤 AE2 訂單任務
        if req_handle then
            local is_done_ok, is_done = pcall(req_handle.isDone)
            local is_canceled_ok, is_canceled = pcall(req_handle.isCanceled)
            
            if is_done_ok and is_canceled_ok and not is_done and not is_canceled then
                tag3 = 1 -- 代表 AE 核心正在合成中
            else
                ctx.active_ae_requests[item_name] = nil
                ctx.last_order_time[item_name] = now_time + 60
                tag3 = 0
            end
        end
        
        local last_order = ctx.last_order_time[item_name] or 0
        local time_passed = now_time - last_order
        local remaining = math.ceil(item_cooldown - time_passed)
        
        if last_order > now_time then
            remaining = math.ceil(last_order - now_time)
        elseif remaining < 0 then
            remaining = 0
        end
        
        -- 【智慧權重佇列與自動插隊互鎖邏輯】
        local is_special_mode = (item_info.mode_tag == "clone")
        
        if count == nil then
            -- AE2 查詢失敗時不可當成 0 個去下單
            ctx.gpu.setForeground(0xFF5555)
            status_msg = "[⚠️ AE查詢失敗]"
            tag1 = 7
        elseif is_special_mode or (item_info.mode_tag == "restock" and count < item_info.target_quantity) then
            -- 狀況甲：特殊複製模式
            if is_special_mode then
                local target_circuit = item_info.circuit
                local priority = item_info.priority or 9 
                
                if count >= item_info.target_quantity then
                    if _G.current_global_task == item_name then
                        --print("[調度中心] 高優先級物品已達標，解鎖全域通道: " .. item_name)
                        _G.current_global_task = nil
                        if component.isAvailable("modem") then
                            component.modem.broadcast(201, "STOP_CLONE")
                        end
                    end
                    ctx.gpu.setForeground(0xFFFFFF)
                    status_msg = "[✅庫存充裕安全]"
                    tag1, tag2, tag3 = 0, 0, 0
                else
                    if _G.current_global_task == nil then
                        _G.current_global_task = item_name
                    else
                        local current_running_priority = 9
                        for _, check_info in ipairs(monitor_items) do
                            if check_info.label == _G.current_global_task then
                                current_running_priority = check_info.priority or 9
                                break
                            end
                        end
                        
                        if priority < current_running_priority then
                            --print(string.format("[權重插隊] 發現更高優先級物資！強制換單 [%s] -> [%s]", _G.current_global_task, item_name))
                            _G.current_global_task = item_name
                            if component.isAvailable("modem") then
                                component.modem.broadcast(201, "KEEP_ALIVE", target_circuit, item_info.target_quantity, count)
                            end
                        end
                    end
                    
                    if _G.current_global_task == item_name then
                        ctx.gpu.setForeground(0x00FF00)
                        status_msg = string.format("[📡 複製中: Cnf %d | Prio %d]", target_circuit, priority)
                        tag1 = 5
                        tag2 = target_circuit
                        
                        if component.isAvailable("modem") then
                            if type(component.modem.setStrength) == "function" then component.modem.setStrength(400) end
                            component.modem.broadcast(201, "KEEP_ALIVE", target_circuit, item_info.target_quantity, count)
                        end
                    else
                        ctx.gpu.setForeground(0xFFAA00)
                        status_msg = string.format("[⏳ 排隊中 (P%d) | 鎖定者: %s]", priority, usub(tostring(_G.current_global_task), 4))
                        tag1 = 6
                        tag2 = 0
                    end
                end
                
            -- 狀況乙：常規 AE2 補貨邏輯
            elseif tag3 == 1 then
                ctx.gpu.setForeground(0x55AFFF) 
                status_msg = "[🛠 訂單合成中...]"
                tag1 = 2; tag2 = 999
            elseif last_order > now_time or time_passed < item_cooldown then
                ctx.gpu.setForeground(0x55AFFF)
                status_msg = string.format("[🛠 補貨冷卻: %ds]", remaining)
                tag1 = 2; tag2 = remaining
            else
                local success_craft, craftables = pcall(ctx.ae.getCraftables, {label = item_name})
                if success_craft and craftables and craftables[1] then
                    local target_recipe = craftables[1]
                    local success_req, request_handle = pcall(target_recipe.request, item_info.target_once)
                    if success_req and request_handle then 
                        ctx.last_order_time[item_name] = now_time
                        ctx.active_ae_requests[item_name] = request_handle
                        ctx.gpu.setForeground(0xFFEE00) 
                        status_msg = string.format("[🚀 已下單 +%d]", item_info.target_once)
                        tag1 = 1
                    else
                        ctx.last_order_time[item_name] = now_time - item_cooldown + 30
                        ctx.gpu.setForeground(0xFF5555) 
                        status_msg = "[❌ AE拒絕下單/無原料]"
                        tag1 = 3
                    end
                else
                    ctx.gpu.setForeground(0xFF5555)
                    status_msg = "[⚠️ 未在AE中找到配方]"
                    tag1 = 4
                end
            end
        else
            if ctx.active_ae_requests[item_name] then ctx.active_ae_requests[item_name] = nil end
            if _G.current_global_task == item_name then _G.current_global_task = nil end
            ctx.gpu.setForeground(count < 10 and 0xFF5555 or 0xFFFFFF)
            status_msg = "[✅庫存充裕安全]"
            tag1, tag2, tag3 = 0, 0, 0
        end
        
        -- 渲染至螢幕
        local row_pos = 15 + (idx - first_idx + 1)
        if idx >= first_idx and idx <= last_idx and row_pos <= ctx.SCR_H then
            ctx.gpu.set(6, row_pos, string.format("  [%02d]|", idx) .. fit(item_name, 35) ..
                string.format("|%11s |", count_str) .. fit(status_msg, 28) .. "      ")
        end
        
        -- 快照紀錄
        table.insert(log_lines, string.format("%s=%d=%d=%d", item_name, tag1, tag2, tag3))
    end
    
    -- 覆蓋寫入狀態文本
    pcall(function()
        local f = io.open(ctx.log_file_path, "w")
        if f then
            for _, log_line in ipairs(log_lines) do f:write(log_line .. "\n") end
            f:close()
        end
    end)
end

-- ========================================================
-- 【全新擴充：低電量自動控制實體唱片機元件 - 智慧續播版】
-- ========================================================
function sdlogic.check_battery_and_play()
    local ctx = main()
    if not ctx.battery or not ctx.jukebox then return end

    -- ⚡ 核心設定：每 5 秒必定執行一次電量檢查
    local used_capacity_percent = nil
    local success_info, sensor_info = pcall(ctx.battery.getSensorInformation)
    
    if success_info and type(sensor_info) == "table" then
        for _, line in ipairs(sensor_info) do
            local match_val = line:match("Used%s+Capacity:%s*([%d%.]+)%%")
            if match_val then
                used_capacity_percent = tonumber(match_val)
                break
            end
        end
    end

    if used_capacity_percent then
        _G.is_low_power_alert = _G.is_low_power_alert or false
        _G.jukebox_loop_counter = _G.jukebox_loop_counter or 0

        if used_capacity_percent < ctx.energy_threshold then
            -- 狀況一：電量跌破 low，立刻在 5 秒內進入警報狀態
            if not _G.is_low_power_alert then
                _G.is_low_power_alert = true
                _G.jukebox_loop_counter = 60 -- 設為 60 讓它在下面判定時能「立刻」播第一聲
                --print(string.format("[系統警報] 電量跌破下限 (%.1f%%)！正式啟動警告音樂。", used_capacity_percent))
            end
            
        elseif used_capacity_percent >= ctx.high_threshold then
            -- 狀況二：電量充回 high，立刻在 5 秒內解除警報狀態
            if _G.is_low_power_alert then
                _G.is_low_power_alert = false
                _G.jukebox_loop_counter = 0 -- 計時歸零
                if type(ctx.jukebox.stop) == "function" then
                    pcall(ctx.jukebox.stop)
                end
                --print(string.format("[系統通知] 電量已回升至安全線 (%.1f%%)，已關閉音樂。", used_capacity_percent))
            end
        end

        -- 唱片機動作控制
        if _G.is_low_power_alert then
            -- 處於低電量警告期：每 5 秒將循環計時器累加 5
            _G.jukebox_loop_counter = _G.jukebox_loop_counter + 5
            -- 只有當累加滿 60 秒（或剛觸發第一次）時，才真正呼叫一次 play()
            if _G.jukebox_loop_counter >= 60 then
                _G.jukebox_loop_counter = 0 -- 滿 60 秒歸零，重新等待下一分鐘
                pcall(ctx.jukebox.play)
            end
        end
    end
end


return sdlogic
