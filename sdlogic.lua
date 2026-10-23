-- 檔案路徑：sd_logic.lua
local io = require("io")
local component = require("component")

local sdlogic = {}

-- 處理第一頁：系統時間顯示與微調
function sdlogic.render_page1(ctx, sdapi)
    local file_time, file_date = sdapi.read_saved_time()
    ctx.gpu.setForeground(0xFFFF00)
    ctx.gpu.set(43, 19, file_time .. "        ")
    ctx.gpu.set(43, 21, file_date .. "        ")
end

-- 處理第二頁：AE2 核心庫存盤點、佇列智慧調度與補貨下單
function sdlogic.render_page2(ctx, sdapi, now_time)
    -- 1. 即時重新解析設定檔
    local monitor_items, _ = sdapi.load_hybrid_config(ctx.config_file_path, ctx.db)
    
    -- 如果設定檔是空的或不存在，清除下方舊殘影並給予提示
    if #monitor_items == 0 then
        ctx.gpu.setForeground(0xFFEE00)
        ctx.gpu.set(6, 17, " ⚠️ 目前 ae_config.txt 為空、格式錯誤或硬碟未正確掛載。                        ")
        return
    end
    
    -- 擦除舊數據，防止更換更短的設定檔時產生文字殘影
    ctx.gpu.fill(1, 16, ctx.SCR_W, ctx.SCR_H - 15, " ")
    
    local log_lines = {}
    local item_dict = {}
    
    local success_item, ae_items = pcall(ctx.ae.getItemsInNetwork)
    if success_item and ae_items then
        for _, item in ipairs(ae_items) do
            if item.label then 
                item_dict[item.label] = (item_dict[item.label] or 0) + item.size 
            end
        end
    end
    
    -- 遍歷動態物品清單
    for idx, item_info in ipairs(monitor_items) do
        local item_name = item_info.name
        local count = item_dict[item_name] or 0
        
        -- 格式化儲存數量 (1M/1K)
        local count_str = tostring(count)
        if count >= 1000000 then 
            count_str = string.format("%.2fM", count / 1000000)
        elseif count >= 1000 then 
            count_str = string.format("%.1fK", count / 1000) 
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
        local is_special_mode = (item_info.min_stock > 0 and item_info.req_qty == 0)
        
        if is_special_mode or (item_info.min_stock > 0 and count < item_info.min_stock) then
            -- 狀況甲：特殊複製模式
            if is_special_mode then
                local target_circuit = item_info.cooldown or 1
                local priority = item_info.priority or 9 
                
                if count >= item_info.min_stock then
                    if _G.current_global_task == item_name then
                        --print("🎉 [調度中心] 高優先級物品已達標，解鎖全域通道: " .. item_name)
                        _G.current_global_task = nil
                        if component.isAvailable("modem") then
                            component.modem.broadcast(201, "STOP_CLONE")
                        end
                    end
                    ctx.gpu.setForeground(0xFFFFFF)
                    status_msg = "[✅庫存充裕安全]"
                    tag1, tag2, tag3 = 0, 0, 0
                else
                    _G.global_queue = _G.global_queue or {}
                    _G.global_queue[item_name] = priority
                    
                    if _G.current_global_task == nil then
                        _G.current_global_task = item_name
                    else
                        local current_running_priority = 9
                        for _, check_info in ipairs(monitor_items) do
                            if check_info.name == _G.current_global_task then
                                current_running_priority = check_info.priority or 9
                                break
                            end
                        end
                        
                        if priority < current_running_priority then
                            --print(string.format("🚨 [權重插隊] 發現更高優先級物資！強制換單 [%s] -> [%s]", _G.current_global_task, item_name))
                            _G.current_global_task = item_name
                            if component.isAvailable("modem") then
                                component.modem.broadcast(201, "KEEP_ALIVE", target_circuit, item_info.min_stock, count)
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
                            component.modem.broadcast(201, "KEEP_ALIVE", target_circuit, item_info.min_stock, count)
                        end
                    else
                        ctx.gpu.setForeground(0xFFAA00)
                        status_msg = string.format("[⏳ 排隊中 (P%d) | 鎖定者: %s]", priority, tostring(_G.current_global_task):sub(1,4))
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
                    local success_req, request_handle = pcall(target_recipe.request, item_info.req_qty)
                    if success_req and request_handle then 
                        ctx.last_order_time[item_name] = now_time
                        ctx.active_ae_requests[item_name] = request_handle
                        ctx.gpu.setForeground(0xFFEE00) 
                        status_msg = string.format("[🚀 已下單 +%d]", item_info.req_qty)
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
            if _G.global_queue then _G.global_queue[item_name] = nil end
            if _G.current_global_task == item_name then _G.current_global_task = nil end
            ctx.gpu.setForeground(count < 10 and 0xFF5555 or 0xFFFFFF)
            status_msg = "[✅庫存充裕安全]"
            tag1, tag2, tag3 = 0, 0, 0
        end
        
        -- 渲染至螢幕
        local row_pos = 15 + idx
        ctx.gpu.set(6, row_pos, string.format("  [%02d]|%-35s|%11s |%-28s      ", idx, item_name, count_str, status_msg))
        
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
function sdlogic.check_battery_and_play(ctx)
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
                    pcall(component.jukebox.stop)
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
                pcall(component.jukebox.play)
            end
        end
    end
end


return sdlogic
