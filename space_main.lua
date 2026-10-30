-- =====================================================================
--    基地中央主控大腦 - 精確數字化與分階段保底填充版 ( master_brain.lua )
--    核心：5分鐘到期全清洗 ➔ 剛需嚴格審查 ➔ 閒置隨機保底 ➔ 300埠定向發信
-- =====================================================================
local component = require("component")
local event = require("event")
local serialization = require("serialization")

if not component.isAvailable("modem") or not component.isAvailable("transposer") then
    error("❌ 中央主機錯誤：本機缺失無線網卡 (Modem) 或主控轉運器 (Transposer)！")
end

local modem = component.modem
local tp = component.transposer 
local PORT = 300
modem.open(PORT)
modem.setStrength(16)

local recipes = require("space_recipe")

-- 線上礦機名冊：記錄格式為 { ["MCU_UUID"] = { tier_num = 1, is_busy = false, current_item = nil } }
local online_miners = {}

-- 共享終界箱物理方向
local SIDE_SHARED_ENDER_CHEST = 2

-- 模擬從外部 database 查詢物品當前庫存量
local function getInventoryStockFromDatabase(item_name)
    local mock_database = {
        ["label1"] = 12000,   -- 已達標 (但有 limit=1 標記)
        ["label2"] = 400,  -- 未達標 (優先指派)
        ["label3"] = 5500     -- 已達標
    }
    return mock_database[item_name] or 0
end

-- 🌟 【核心功能】：從回傳的 gt_name (如 t1, t2, t3) 中精確提取並轉換為數字等級
local function extractMinerTierNum(gt_name)
    local clean = tostring(gt_name):lower():gsub("%s+", "")
    local num = tonumber(clean:match("%d+")) -- 提取字串中的第一個數字
    return num or 1 -- 萬一沒抓到，預設返回最低等級 1 (t1)
end

-- =====================================================================
-- 🌟 【精密修復點】：亂塞環境專用 - 全局遍歷最高階無人機絕對優先雷達
-- =====================================================================
local function searchDrone(min_drone, max_drone, is_fallback_allowed)
    local check_min = tonumber(min_drone) or 0
    local check_max = tonumber(max_drone) or 99

    local size_success, inv_size = pcall(tp.getInventorySize, SIDE_SHARED_ENDER_CHEST)
    if not size_success or not inv_size or inv_size == 0 then inv_size = 27 end

    local success, all_stacks_obj = pcall(tp.getAllStacks, SIDE_SHARED_ENDER_CHEST)
    if not success or not all_stacks_obj then return nil, nil, nil, false end
    
    local success_get, slotDataAll = pcall(all_stacks_obj.getAll)
    if not success_get or not slotDataAll then return nil, nil, nil, false end
    
    -- 🌟 【動態擂台變數】：用來記錄全箱子目前找到最厲害的無人機特徵
    local best_slot = nil
    local best_size = nil
    local max_found_level = -1 -- 初始設為 -1
    
    -- 🌟 🌟 ─── 第一階段：【剛需全局遍歷】 ─── 🌟 🌟
    -- 不用 break 提前退出！強行掃描 0 到 (inv_size - 1) 的每一個格子
    for slotIdx = 0, (inv_size - 1) do
        local slotData = slotDataAll[slotIdx]
        
        if slotData and slotData.name == "gtnhintergalactic:item.MiningDrone" then
            local current_drone_level = (slotData.damage or 0) + 1
            
            -- 核對代數是否落在配方要求的純數字 [最低] 與 [最高] 區間內
            if current_drone_level >= check_min and current_drone_level <= check_max and (slotData.size or 0) > 0 then
                -- 🤼 擂台比武：如果這格無人機等級比之前找到的還要高，立刻把第一名換成它！
                if current_drone_level > max_found_level then
                    max_found_level = current_drone_level
                    best_slot = slotIdx
                    best_size = slotData.size
                end
            end
        end
    end
    
    -- 如果在第一階段有成功挑選出最優秀的正規軍，直接回傳，絕對是全箱符合區間裡最高級的！
    if best_slot then
        best_slot = best_slot + 1
		return best_slot, best_size, max_found_level, false
    end
    
    -- 🌟 🌟 ─── 第二階段：【隨機保底全局遍歷】 ─── 🌟 🌟
    -- 只有在第二階段且正規軍全滅時才發動，一樣進行最高級優先遍歷
    if is_fallback_allowed then
        print("   ⚠️ [雷達提示] 目標區間無人機不足，正在執行第二階段全局保底(最高級優先)填充...")
        
        local fallback_slot = nil
        local fallback_size = nil
        local fallback_max_level = -1
        
        for slotIdx = 0, (inv_size - 1) do
            local slotData = slotDataAll[slotIdx]
            if slotData and slotData.name == "gtnhintergalactic:item.MiningDrone" and (slotData.size or 0) > 0 then
                local current_drone_level = (slotData.damage or 0) + 1
                
                if current_drone_level > fallback_max_level then
                    fallback_max_level = current_drone_level
                    fallback_slot = slotIdx
                    fallback_size = slotData.size
                end
            end
        end
        
        if fallback_slot then
            fallback_slot = fallback_slot + 1
			return fallback_slot, fallback_size, fallback_max_level, true -- 保底填充放行
        end
    end
    
    return nil, nil, nil, false -- 共享終界箱內徹底沒有任何一隻無人機
end



-- 異步接收工廠電腦註冊
local function pollRegistrations()
    local ev = { event.pull(0.5, "modem_message") }
    if ev[1] == "modem_message" and ev[4] == PORT then
        local client_uuid = ev[3]
        local cmd         = ev[6]
        local reported_gt = ev[7]
        
        if cmd == "MINER_REGISTER" and reported_gt then
            if not online_miners[client_uuid] then
                -- 🌟 【依要求修改】：實時從註冊名字中摳出數字等級
                local t_num = extractMinerTierNum(reported_gt)
                online_miners[client_uuid] = { tier_num = t_num, is_busy = false, current_item = nil }
                print(string.format("🆕 [名冊登記] 工廠節點 [%s...] ➔ 解析 GT 等級: 【t%d】", client_uuid:sub(1,8), t_num))
                modem.send(client_uuid, PORT, "REG_SUCCESS")
            end
        end
    end
end

-- 階段 0：全廠無條件大清洗
local function executeGlobalClean()
    local clean_count = 0
    for mcu_uuid, miner_status in pairs(online_miners) do
        modem.send(mcu_uuid, PORT, "PULL_BACK")
        miner_status.is_busy = false
        miner_status.current_item = nil
        clean_count = clean_count + 1
        os.sleep(0.1)
    end
	os.sleep(0.5)
    print(string.format("✅ 全廠已重置，共 %d 台採礦節點無人機摳回共享池。", clean_count))
    print("--------------------------------------------")
end

print("====================================================")
print("     🛰️  GTNH 中央大腦：雙階段階梯式調度控台啟動      ")
print("====================================================")
print("⏳ 正在等待工廠電腦節點聯網申報...")
modem.broadcast(300,"REG_RESET")
executeGlobalClean()

while true do
    pollRegistrations()
    
    -- 🌟 🌟 ─── 階段一：【剛需分配】優先填補未達標礦物 (嚴格代數匹配) ─── 🌟 🌟
    for item_name, cfg in pairs(recipes) do
        local current_stock = getInventoryStockFromDatabase(item_name)
        
        if current_stock < cfg.target_amount then
            local shortage = cfg.target_amount - current_stock
            local shortage_ratio = shortage / cfg.target_amount
            local needed_miners = math.ceil(shortage_ratio * cfg.weight)
            
            print(string.format("\n📊 [優先級: 剛需] 【%s】 缺額比值: %.2f ➔ 需投入: %d 台", item_name, shortage_ratio, needed_miners))
            
            -- 🌟 【嚴格審查】：第三個參數傳入 false ➔ 絕對不允許隨機保底填充
            local use_slot, drone_size, drone_lvl, _ = searchDrone(cfg.min_drone, cfg.max_drone, false)
            
            local assigned_count = 0
            if use_slot then
                print(string.format("   🔍 雷達回報：精確匹配成功！➡️ 採用第 %d 格的 T%d 無人機", use_slot, drone_lvl))
                
                for mcu_uuid, miner_status in pairs(online_miners) do
                    -- 🌟 【等級動態比對】：直接拿純數字進行大小核對，絕不卡死
                    if not miner_status.is_busy and assigned_count < needed_miners then
                        if miner_status.tier_num >= cfg.min_miner_tier then
                            print(string.format("   🚀 [剛需點火] 節點 [%s...](t%d) ➡️ 投放終界箱第 %d 格無人機開採 【%s】", mcu_uuid:sub(1,8), miner_status.tier_num, use_slot, item_name))
                            
                            miner_status.is_busy = true
                            miner_status.current_item = item_name
                            assigned_count = assigned_count + 1
                            -- 定向 300 埠下發調參與點火
                            modem.send(mcu_uuid, PORT, "SET_MACHINE", 0, 0, cfg.distance)
                            os.sleep(0.1)
                            modem.send(mcu_uuid, PORT, "PUSH_MATERIAL", use_slot, 1)
                            
                            drone_size = drone_size - 1
                            if drone_size <= 0 then break end -- 該槽位抽乾，跳出重刷
                        end
                    end
                end
            else
                print("   ⚠️ [剛需阻斷] 終界箱內無符合代數要求的專屬無人機，拒絕降級投料，防空轉保護中。")
            end
        end
    end

    -- 🌟 🌟 ─── 階段二：【閒置再利用】對 limit=1 隨機分配 (開放隨機保底填充) ─── 🌟 🌟
    local idle_miners = {}
    for mcu_uuid, miner_status in pairs(online_miners) do
        if not miner_status.is_busy then table.insert(idle_miners, mcu_uuid) end
    end

    local limit_one_candidates = {}
    for item_name, cfg in pairs(recipes) do
        local current_stock = getInventoryStockFromDatabase(item_name)
        if current_stock >= cfg.target_amount and (cfg.limit or 0) == 1 then
            table.insert(limit_one_candidates, item_name)
        end
    end

    if #idle_miners > 0 and #limit_one_candidates > 0 then
        print(string.format("\n💡 [優先級: 閒置再利用] 全廠仍有 %d 台閒置電腦，準備指派 limit=1 飽和任務...", #idle_miners))
        
        for _, mcu_uuid in ipairs(idle_miners) do
            local random_index = math.random(1, #limit_one_candidates)
            local chosen_item = limit_one_candidates[random_index]
            local cfg = recipes[chosen_item]
            
            -- 🌟 🌟 🌟 【核心修改點】：第三個參數傳入 true ➔ 開放隨機保底填充！ 🌟 🌟 🌟
            local use_slot, drone_size, drone_lvl, is_fallback = searchDrone(cfg.min_drone, cfg.max_drone, true)
            local miner_status = online_miners[mcu_uuid]
            
            if use_slot and miner_status.tier_num >= cfg.min_miner_tier then
                if is_fallback then
                    print(string.format("   🎲 [保底填充成功] 閒置節點 [%s...](t%d) 🎲 隨機常駐 ➡️ 【%s】(採用第 %d 格 T%d 備用無人機)", mcu_uuid:sub(1,8), miner_status.tier_num, chosen_item, use_slot, drone_lvl))
                else
                    print(string.format("   🎲 [閒置飽和] 閒置節點 [%s...](t%d) 🎲 隨機常駐 ➡️ 【%s】(採用第 %d 格 T%d 正規無人機)", mcu_uuid:sub(1,8), miner_status.tier_num, chosen_item, use_slot, drone_lvl))
                end
                
                miner_status.is_busy = true
                miner_status.current_item = chosen_item
                
                modem.send(mcu_uuid, PORT, "SET_MACHINE", 0, 0, cfg.distance)
                os.sleep(0.1)
                modem.send(mcu_uuid, PORT, "PUSH_MATERIAL", use_slot, 1)
            end
        end
    end

    -- =====================================================================
    -- 🌟 ─── 5分鐘手動可刷新型冷卻與背景守護大循環 ───
    -- =====================================================================
    local all_busy = true
    local has_any_miner = false
    for _, status in pairs(online_miners) do
        has_any_miner = true
        if not status.is_busy then all_busy = false break end
    end
    
    -- 實時多撈一次終界箱，看看全箱子是不是已經徹底沒有任何無人機了
    -- 🚨 【安全退場防線新版對齊】：檢查終界箱內是否還有任何無人機
    local global_drone_slot = nil
    local success, slotDataAll = pcall(tp.getAllStacks, SIDE_SHARED_ENDER_CHEST)
    if success and slotDataAll then
        for slotIdx, slotData in pairs(slotDataAll) do
            if slotData and type(slotData) == "table" and slotData.name == "gtnhintergalactic:item.MiningDrone" and (slotData.size or 0) > 0 then
                global_drone_slot = slotIdx
                break
            end
        end
    end

    
    -- 【雙重保險退場條件】：產能滿載 或 無人機耗盡
    if has_any_miner and (all_busy or global_drone_slot == nil) then
        print("\n====================================================")
        if global_drone_slot == nil and not all_busy then
            print("  ⚠️ [資產耗盡] 共享終界箱內的採礦無人機已完全分發完畢！")
            print("  ℹ️ 剩餘閒置節點將保持原地安全待命，拒絕空轉投料。")
        else
            print("  🎉 全廠符合條件的採礦節點已指派完畢並產能飽和！")
        end
        print("  ⏳ 大腦正在進入 5 分鐘安全冷卻期...")
        print("  💡 [黑科技提示]：冷卻期間主機「背景仍會自動接收新機器註冊」")
        print("  ⌨️  任何時候在主機鍵盤按下 【Enter 鍵】，即可【立刻手動刷新】！")
        print("====================================================")
        
        -- 🌟 🌟 🌟 ─── 【智慧小步進異步計時核心】 ─── 🌟 🌟 🌟
        local total_cool_down = 300 -- 總冷卻時間 300 秒 (5分鐘)
        local elapsed = 0
        local force_refresh = false
        
        while elapsed < total_cool_down and not force_refresh do
            -- A. 每次只等 1 秒，一邊拉取網路，一邊拉取鍵盤點擊事件 (key_down)
            local ev_type, _, charOrCode, keyCode = event.pull(1)
            
            -- B. 背景不間斷聽信：即使在大腦冷卻期間，有新電腦開機，一樣能順利登記進名冊！
            if ev_type == "modem_message" then
                -- 暫時將這段封包丟給註冊函數處理，防範冷卻期漏抓新電腦
                pcall(function()
                    if ev_type == "modem_message" and ev_event[4] == PORT then
                        local client_uuid = ev_event[3]
                        local cmd         = ev_event[6]
                        local reported_gt = ev_event[7]
                        if cmd == "MINER_REGISTER" and reported_gt and not online_miners[client_uuid] then
                            local t_num = extractMinerTierNum(reported_gt)
                            online_miners[client_uuid] = { tier_num = t_num, is_busy = false, current_item = nil }
                            print(string.format("\n🆕 [冷卻期名冊登記] 發現新上線工廠節點 [%s...] ➔ 等級: 【t%d】", client_uuid:sub(1,8), t_num))
                            modem.send(client_uuid, PORT, "REG_SUCCESS")
                        end
                    end
                end)
            
            -- C. ⌨️ 鍵盤按鍵攔截：檢查玩家有沒有在鍵盤打字
            elseif ev_type == "key_down" then
                -- 在 OpenOS 中，keyCode = 28 代表 Enter 鍵 (或者是 charOrCode == 13)
                -- 為了寬容處理，您也可以設定成「隨便按鍵盤任何鍵都觸發強制刷新」
                if keyCode == 28 or charOrCode == 13 then
                    print("\n⌨️  [手動干預觸發] 偵測到玩家按下 Enter 鍵！正在強行打破冷卻限制...")
                    force_refresh = true
                end
            end
            
            -- 每過 10 秒，在螢幕上動態印出倒數計時提示，讓你知道主機沒死機
            elapsed = elapsed + 1
            if elapsed % 10 == 0 and not force_refresh then
                io.write(string.format("\r   ⏳ 正在冷卻待機中... 已過去 %d/%d 秒 (按 Enter 可手動刷新)", elapsed, total_cool_down))
                io.flush()
            end
        end
        io.write("\n")
        
        -- 5 分鐘時間到，或者是玩家按了 Enter，解除鎖定，發動大清洗重分配
        executeGlobalClean() 
    end
    
    os.sleep(1) -- 主循環防卡小休眠
end

