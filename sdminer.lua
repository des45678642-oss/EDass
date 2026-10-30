-- 檔案路徑：sdminer.lua
-- 礦機調度：把 space_main.lua (中央主控大腦) 的邏輯整合進 touch_menu。
-- ae_config.json 裡 mode_tag = "miner" 的物品，庫存不足時：從共享終界箱挑無人機，
-- 透過 300 埠對礦機電腦 (space_miner.lua) 下達 SET_MACHINE / PUSH_MATERIAL / PULL_BACK。
--
-- 與 space_main 的差別：不再 os.sleep / 無限迴圈，改由 touch_menu 的計時器每秒呼叫 sdminer.tick()
-- (訊息放進佇列慢慢送)，所以畫面和 AE2 補貨邏輯不會被卡住。參數直接讀取主程式 touch_menu。
local component = require("component")
local event = require("event")
local sdlogic = require("sdlogic")

local sdminer = {}

local function main() return require("touch_menu") end

local function new_state()
    return {
        phase = "off",            -- off / cleaning / dispatch / cooldown
        miners = {},              -- [uuid] = { tier = 數字, busy = false, item = label|nil, name = 原始 GT 名稱 }
        queue = {},               -- 待送出的訊息 { to = uuid|nil(廣播), args = {...} }
        status = {},              -- [label] = { stock, target, needed, assigned, reason }
        assigned = {},            -- [label] = 目前負責這個物品的礦機數
        drones = nil,             -- 上次掃描時終界箱剩餘的無人機總數
        last_send = -1e9,         -- 上次實際送出訊息的時間
        next_pass = 0, cooldown_until = 0, cycle_started = 0,
        manual_refresh = false,
        last_error = nil,
        listener = nil,
    }
end
local S = new_state()

-- 從礦機回報的 GT 名稱 (例如 ...t3) 取出第一個數字當等級；抓不到就當 1 級
function sdminer.extract_tier(gt_name)
    local clean = tostring(gt_name):lower():gsub("%s+", "")
    return tonumber(clean:match("%d+")) or 1
end

function sdminer.available()
    local m = main()
    if not m.miner_transposer then return false, "找不到轉運器 (transposer)" end
    if not component.isAvailable("modem") then return false, "找不到網路卡 (modem)" end
    return true
end

-- ========================================================
-- 【網路】訊息放進佇列，每秒只送幾則，避免一次塞爆 (原本靠 os.sleep(0.1) 間隔)
-- ========================================================
local function enqueue(to, ...)
    S.queue[#S.queue + 1] = { to = to, args = { ... } }
end

local function with_strength(fn)
    local m = main()
    local ok, modem = pcall(function() return component.modem end)
    if not ok or not modem then return false end
    -- 無線網卡的發信強度是共用的(複製機廣播會用 400)，送完要還原
    local prev = type(modem.getStrength) == "function" and modem.getStrength() or nil
    if type(modem.setStrength) == "function" then modem.setStrength(m.miner_strength) end
    local good = pcall(fn, modem, m)
    if prev and type(modem.setStrength) == "function" then modem.setStrength(prev) end
    return good
end

local function drain(limit, now)
    if #S.queue == 0 then return end
    with_strength(function(modem, m)
        for _ = 1, limit do
            local item = table.remove(S.queue, 1)
            if not item then break end
            if item.to then modem.send(item.to, m.miner_port, table.unpack(item.args))
            else modem.broadcast(m.miner_port, table.unpack(item.args)) end
            S.last_send = now
        end
    end)
end

-- 礦機註冊 (冷卻期間也會處理；已登記過的礦機重新開機後也會收到回覆)
local function on_modem_message(_, _, remote, port, _, cmd, arg1)
    local m = main()
    if S.phase == "off" or port ~= m.miner_port then return end
    if cmd == "MINER_REGISTER" and arg1 ~= nil and type(remote) == "string" then
        local tier = sdminer.extract_tier(arg1)
        local known = S.miners[remote]
        if known then known.tier, known.name = tier, tostring(arg1)
        else S.miners[remote] = { tier = tier, busy = false, item = nil, name = tostring(arg1) } end
        with_strength(function(modem) modem.send(remote, m.miner_port, "REG_SUCCESS") end)
    end
end
sdminer._on_modem_message = on_modem_message

-- ========================================================
-- 【共享終界箱雷達】
-- ========================================================
-- 回傳 { {slot=, size=, level=}, ... }, 無人機總數；失敗回傳 nil, 錯誤訊息
local function scan_drones()
    local m = main()
    local tp = m.miner_transposer
    if not tp then return nil, "找不到轉運器" end
    local side = m.miner_chest_side
    local ok_size, size = pcall(tp.getInventorySize, side)
    if not ok_size or type(size) ~= "number" or size == 0 then size = 27 end
    local ok, iter = pcall(tp.getAllStacks, side)
    if not ok or not iter then return nil, "無法讀取共享終界箱" end
    local ok_all, all = pcall(iter.getAll)
    if not ok_all or type(all) ~= "table" then return nil, "無法讀取共享終界箱" end
    local list, total = {}, 0
    for idx = 0, size - 1 do                       -- getAll() 的索引從 0 開始，轉運器的格子編號從 1 開始
        local st = all[idx]
        if type(st) == "table" and st.name == m.drone_item_name and (st.size or 0) > 0 then
            list[#list + 1] = { slot = idx + 1, size = st.size, level = (st.damage or 0) + 1 }
            total = total + st.size
        end
    end
    return list, total
end
sdminer._scan_drones = scan_drones

-- 在區間內挑等級最高的無人機 (已被本輪預訂的數量要扣掉)；allow_fallback 時區間內沒有就挑全箱最高級
local function pick_drone(list, reserved, min_t, max_t, allow_fallback)
    local best, fallback
    for _, d in ipairs(list) do
        if d.size - (reserved[d.slot] or 0) > 0 then
            if d.level >= min_t and d.level <= max_t and (not best or d.level > best.level) then best = d end
            if not fallback or d.level > fallback.level then fallback = d end
        end
    end
    if best then return best, false end
    if allow_fallback and fallback then return fallback, true end
    return nil
end
sdminer._pick_drone = pick_drone

-- ========================================================
-- 【調度】一輪分配 (對應 space_main 的階段一「剛需」與階段二「閒置再利用」)
-- ========================================================
local function sorted_idle()
    local ids = {}
    for uuid, st in pairs(S.miners) do if not st.busy then ids[#ids + 1] = uuid end end
    table.sort(ids)
    return ids
end

-- 回傳 true 表示「已飽和」：有礦機，且全部在忙或終界箱已沒有無人機
local function dispatch()
    local m = main()
    local items = sdlogic.load_hybrid_config()
    local miner_items = {}
    for _, it in ipairs(items) do if it.mode_tag == "miner" then miner_items[#miner_items + 1] = it end end
    S.status = {}
    local has_any_miner = next(S.miners) ~= nil
    if #miner_items == 0 then return false end

    local counts = sdlogic.query_counts(miner_items, m)

    -- 終界箱只在真的需要分配時才掃描(元件呼叫很貴)；同一輪內用 reserved 記錄已預訂的數量，
    -- 因為指令還在佇列裡，箱子的實際內容要等礦機收到指令才會改變
    local list, total_drones
    local scan_failed = false
    local function drones()
        if list == nil and not scan_failed then
            local l, t = scan_drones()
            if l then list, total_drones = l, t else scan_failed = true; S.last_error = t end
        end
        return list
    end
    local reserved = {}
    local function assign(uuid, it, drone)
        local miner = S.miners[uuid]
        miner.busy, miner.item = true, it.label
        S.assigned[it.label] = (S.assigned[it.label] or 0) + 1
        reserved[drone.slot] = (reserved[drone.slot] or 0) + 1
        enqueue(uuid, "SET_MACHINE", 0, 0, it.distance)
        enqueue(uuid, "PUSH_MATERIAL", drone.slot, 1)
    end

    -- 階段一：庫存未達標的物品，缺口比例大的優先
    local needy, satisfied = {}, {}
    for _, it in ipairs(miner_items) do
        local stock = counts[it.label]
        if stock == nil then
            S.status[it.label] = { reason = "query", assigned = S.assigned[it.label] or 0 }
        elseif stock < it.target_quantity then
            needy[#needy + 1] = { it = it, stock = stock, ratio = (it.target_quantity - stock) / it.target_quantity }
        else
            satisfied[#satisfied + 1] = it
            S.status[it.label] = { stock = stock, target = it.target_quantity, assigned = S.assigned[it.label] or 0 }
        end
    end
    table.sort(needy, function(a, b) if a.ratio ~= b.ratio then return a.ratio > b.ratio end return a.it.label < b.it.label end)

    for _, n in ipairs(needy) do
        local it = n.it
        local needed = math.ceil(n.ratio * it.weight)
        local assigned = S.assigned[it.label] or 0          -- 已經在採這個的礦機也算進去，不會每輪重複加碼
        local reason
        if assigned < needed then
            local d_list = drones()
            if not d_list then reason = "no_drone" else
                for _, uuid in ipairs(sorted_idle()) do
                    if assigned >= needed then break end
                    if S.miners[uuid].tier >= it.min_miner_tier then
                        -- 嚴格模式：不在無人機等級區間內就不投料(防空轉)，不使用保底
                        local drone = pick_drone(d_list, reserved, it.min_drone_tier, it.max_drone_tier, false)
                        if not drone then reason = "no_drone"; break end
                        assign(uuid, it, drone)
                        assigned = assigned + 1
                    end
                end
                if assigned < needed and not reason then reason = "no_miner" end
            end
        end
        S.status[it.label] = { stock = n.stock, target = it.target_quantity, needed = needed, assigned = assigned, reason = reason }
    end

    -- 階段二：還閒置的礦機，隨機分給「已達標且 limit = 1」的物品，無人機允許保底(全箱最高級)
    local candidates = {}
    for _, it in ipairs(satisfied) do if (it.limit or 0) == 1 then candidates[#candidates + 1] = it end end
    if #candidates > 0 then
        local d_list = drones()
        if d_list then
            for _, uuid in ipairs(sorted_idle()) do
                local it = candidates[math.random(1, #candidates)]
                if S.miners[uuid].tier >= it.min_miner_tier then
                    local drone = pick_drone(d_list, reserved, it.min_drone_tier, it.max_drone_tier, true)
                    if drone then
                        assign(uuid, it, drone)
                        S.status[it.label].assigned = S.assigned[it.label]
                    end
                end
            end
        end
    end

    if list then
        local used = 0
        for _, v in pairs(reserved) do used = used + v end
        S.drones = total_drones - used
    end
    local all_busy = true
    for _, st in pairs(S.miners) do if not st.busy then all_busy = false break end end
    local drones_gone = list ~= nil and S.drones <= 0
    return has_any_miner and (all_busy or drones_gone)
end
sdminer._dispatch = dispatch

-- 全廠大清洗：所有礦機把無人機摳回共享池，狀態歸零
local function begin_clean(now)
    for uuid, st in pairs(S.miners) do
        enqueue(uuid, "PULL_BACK")
        st.busy, st.item = false, nil
    end
    S.assigned, S.status = {}, {}
    S.phase = "cleaning"
end

-- ========================================================
-- 【對外介面】
-- ========================================================
function sdminer.start()
    local ok, why = sdminer.available()
    if not ok then S.phase = "off"; S.last_error = why; return false, why end
    if S.listener then return true end
    local m = main()
    for addr in component.list("modem") do pcall(component.invoke, addr, "open", m.miner_port) end
    S.listener = on_modem_message
    event.listen("modem_message", S.listener)
    S.phase = "cleaning"
    S.last_send = m.get_now_time()
    enqueue(nil, "REG_RESET")          -- 請所有礦機重新登記
    return true
end

function sdminer.stop()
    if S.listener then event.ignore("modem_message", S.listener); S.listener = nil end
    S.phase = "off"
    S.queue = {}
end

-- 對應 space_main 的「按 Enter 立刻手動刷新」
function sdminer.refresh_now()
    if S.phase == "off" then return false end
    S.manual_refresh = true
    return true
end

-- 每秒由 touch_menu 呼叫一次
function sdminer.tick()
    if S.phase == "off" then return end
    local m = main()
    local now = m.get_now_time()

    if S.manual_refresh then
        S.manual_refresh = false
        if S.phase ~= "cleaning" then begin_clean(now) end
    end
    -- 先判斷「指令都送完、礦機也搬完了」再送這一秒的訊息，這樣剛排進佇列的指令會在同一秒送出，
    -- 而且還沒送完/剛送完時不會開始下一輪分配
    local quiet = #S.queue == 0 and now - S.last_send >= m.miner_settle

    if S.phase == "cleaning" then
        if quiet then S.phase, S.cycle_started, S.next_pass = "dispatch", now, now end
    elseif S.phase == "dispatch" then
        if quiet and now >= S.next_pass then
            local ok, saturated = pcall(dispatch)
            S.next_pass = now + m.miner_dispatch_interval
            if not ok then S.last_error = tostring(saturated)
            elseif saturated then S.phase, S.cooldown_until = "cooldown", now + m.miner_cooldown
            elseif now - S.cycle_started >= m.miner_cooldown then begin_clean(now) end   -- 一輪最長 cooldown 秒就重新整理
        end
    elseif S.phase == "cooldown" then
        if now >= S.cooldown_until then begin_clean(now) end
    end

    drain(m.miner_msgs_per_tick, now)
end

function sdminer.status(label) return S.status[label] end

function sdminer.is_active() return S.phase ~= "off" end

-- 第二頁上方的一行摘要；沒有礦機也沒有 miner 物品時回傳 nil
function sdminer.summary(has_miner_items)
    local m = main()
    if S.phase == "off" then
        if not has_miner_items then return nil end
        return "⛏ 礦機模組未啟用：" .. tostring(S.last_error or "尚未啟動"), false
    end
    local total, busy = 0, 0
    for _, st in pairs(S.miners) do total = total + 1; if st.busy then busy = busy + 1 end end
    if total == 0 and not has_miner_items then return nil end
    local phase_text
    if S.phase == "cooldown" then phase_text = string.format("冷卻 %ds", math.max(0, math.ceil(S.cooldown_until - m.get_now_time())))
    elseif S.phase == "cleaning" then phase_text = "回收中"
    else phase_text = "分配中" end
    return string.format("⛏ 礦機 %d 台 (忙碌 %d)  |  %s  |  終界箱無人機: %s%s", total, busy, phase_text,
        S.drones and tostring(S.drones) or "?", S.last_error and ("  |  ⚠️ " .. S.last_error) or ""), true
end

-- 測試用
function sdminer._state() return S end
function sdminer._reset()
    sdminer.stop()
    S = new_state()
end

return sdminer
