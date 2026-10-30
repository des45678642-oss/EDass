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
-- 【繪圖快取】gpu 的呼叫有每 tick 的次數上限，每次刷新都整頁重畫會拖慢；
-- 只有「文字或顏色真的改變」的列才會重新畫。換頁/清螢幕時要呼叫 reset_draw_cache。
-- ========================================================
local draw_cache = {}

function sdlogic.reset_draw_cache() draw_cache = {} end

local function put(x, y, text, color)
    local k = y * 1000 + x
    local sig = tostring(color) .. ":" .. text
    local c = draw_cache[k]
    if c and c.sig == sig then return end
    local gpu = main().gpu
    gpu.setForeground(color)
    gpu.set(x, y, text)
    draw_cache[k] = { sig = sig, w = ulen(text), x = x, y = y }
end

-- 把 y1..y2 列中畫過的內容用空白蓋掉
local function clear_rows(y1, y2)
    local gpu = main().gpu
    for _, c in pairs(draw_cache) do
        if c.y >= y1 and c.y <= y2 and not c.blank then
            gpu.set(c.x, c.y, string.rep(" ", c.w))
            c.sig, c.blank = "blank", true
        end
    end
end

-- 電量數字：1.23GEU 這種好讀格式
local UNITS = { "", "K", "M", "G", "T", "P", "E" }
function sdlogic.format_eu(n)
    if type(n) ~= "number" then return "?" end
    local i, v = 1, math.abs(n)
    while v >= 1000 and i < #UNITS do v = v / 1000; i = i + 1 end
    if i == 1 then return string.format("%d EU", n) end
    return string.format("%.2f%sEU", n / 1000 ^ (i - 1), UNITS[i])
end


-- ========================================================
-- 【設定檔載入】ae_config.json (原本在 sdapi.load_hybrid_config)
-- 每筆物品直接存 name / damage / label (方便查詢)。database 只用來「新增物品」：
-- 初始化時與按下掃描鍵時，把 database 裡還沒登記的物品加進 JSON。
-- ========================================================
local MODES = { restock = true, clone = true, monitor = true, miner = true }
local parse_cache = { path = nil, mtime = nil, data = nil, checked_at = nil }
local built_cache = { data = nil, items = nil, errors = nil }
local last_good = nil
local last_log_text = nil

-- JSON 的 null 視同沒填
local function val(x)
    if x == json.null then return nil end
    return x
end

local function is_int(n) return type(n) == "number" and n == math.floor(n) end

-- 讀取並解析 JSON。
-- 快取兩層：(1) config_check_interval 秒內完全不碰檔案系統；(2) 之後只比對 lastModified，
-- 檔案沒變就沿用上次解析結果。force=true 時一律重新讀檔(掃描/轉換要改檔前使用)。
function sdlogic.parse_config_file(path, force)
    local m = main()
    local now = m.get_now_time and m.get_now_time() or 0
    local interval = m.config_check_interval or 0
    if not force and interval > 0 and parse_cache.data and parse_cache.path == path
        and parse_cache.checked_at and now >= parse_cache.checked_at and now - parse_cache.checked_at < interval then
        return parse_cache.data
    end
    if not fs.exists(path) then return nil, "找不到設定檔 " .. tostring(path) end
    local ok, mtime = pcall(fs.lastModified, path)
    if not ok then mtime = nil end
    if not force and mtime and parse_cache.path == path and parse_cache.mtime == mtime and parse_cache.data then
        parse_cache.checked_at = now
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
    if not force then parse_cache.path, parse_cache.mtime, parse_cache.data, parse_cache.checked_at = path, mtime, data, now end
    return data
end

-- 依 JSON 的 database 欄位(位址前綴)選擇資料庫元件；沒填或找不到就用主程式預設的 db
function sdlogic.get_database(config)
    local m = main()
    local data = config or parse_cache.data
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

-- 驗證單筆設定。回傳 entry 或 nil, 錯誤訊息
local function build_entry(raw, index, seen)
    if type(raw) ~= "table" or raw == json.null then return nil, string.format("第 %d 筆不是物件", index) end
    local name, damage, label = val(raw.name), val(raw.damage), val(raw.label)
    if label == nil and val(raw.slot) ~= nil then
        return nil, string.format("第 %d 筆 (slot %s) 尚未轉換成 name/damage/label，請重新啟動讓它自動轉換", index, tostring(raw.slot))
    end
    if type(label) ~= "string" or label == "" then return nil, string.format("第 %d 筆: label 必須是非空字串", index) end
    local tag = label
    if type(name) ~= "string" or name == "" then return nil, tag .. ": name 必須是非空字串" end
    if not (is_int(damage) and damage >= 0) then return nil, tag .. ": damage 必須是 >=0 的整數" end
    -- AE2 搜尋只用 label，所以 label 就是物品的唯一識別 (也是冷卻/訂單/全域鎖的狀態鍵)
    local key = label
    if seen[key] then return nil, tag .. ": 重複的 label (AE2 只用 label 搜尋，同一個 label 只能登錄一次)" end

    local mode = val(raw.mode_tag)
    if not MODES[mode or ""] then return nil, tag .. ": mode_tag 必須是 restock / clone / monitor / miner" end

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
    -- 礦機模式 (參數沿用 space_recipe.lua；target_amount 就是 target_quantity)
    local miner
    if mode == "miner" then
        if target <= 0 then return nil, tag .. ": miner 需要 target_quantity > 0" end
        local function int_field(key, default, lo)
            local v = val(raw[key])
            if v == nil then return default end
            if is_int(v) and v >= lo then return v end
            return nil
        end
        local min_miner_tier = int_field("min_miner_tier", 1, 1)
        if not min_miner_tier then return nil, tag .. ": min_miner_tier 必須是 >=1 的整數" end
        local min_drone_tier = int_field("min_drone_tier", 0, 0)
        if not min_drone_tier then return nil, tag .. ": min_drone_tier 必須是 >=0 的整數" end
        local max_drone_tier = int_field("max_drone_tier", 99, min_drone_tier)
        if not max_drone_tier then return nil, tag .. ": max_drone_tier 必須是 >= min_drone_tier 的整數" end
        local distance = val(raw.distance)
        if type(distance) ~= "number" or distance < 0 then return nil, tag .. ": miner 需要 distance (數字)" end
        local weight = val(raw.weight)
        if weight == nil then weight = 1 end
        if type(weight) ~= "number" or weight <= 0 then return nil, tag .. ": weight 必須是 >0 的數字" end
        local limit = val(raw.limit)
        if limit == nil then limit = 0 end
        if limit ~= 0 and limit ~= 1 then return nil, tag .. ": limit 只能是 0 或 1" end
        miner = { min_miner_tier = min_miner_tier, min_drone_tier = min_drone_tier, max_drone_tier = max_drone_tier,
                  distance = distance, weight = weight, limit = limit }
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
    seen[key] = true
    local entry = {
        key = key, name = name, damage = damage, label = label,
        target_quantity = target, target_once = once, cooldown = cooldown,
        mode_tag = mode, circuit = circuit, priority = priority,
    }
    if miner then for k, v in pairs(miner) do entry[k] = v end end
    return entry
end

-- 回傳 items, errors。設定有問題的項目會被略過並列在 errors，絕不丟出例外。
-- 不再需要 database：物品資料全部來自 JSON。
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
    -- 解析結果沒變就直接沿用已驗證好的項目，不必每次刷新重建
    if built_cache.data == data and #errors == 0 then return built_cache.items, built_cache.errors end
    local items, seen, build_errors = {}, {}, {}
    for i, raw in ipairs(data.items) do
        local entry, e = build_entry(raw, i, seen)
        if entry then items[#items + 1] = entry else build_errors[#build_errors + 1] = e end
    end
    if #errors == 0 then
        built_cache.data, built_cache.items, built_cache.errors = data, items, build_errors
        return items, build_errors
    end
    for _, e in ipairs(build_errors) do errors[#errors + 1] = e end
    return items, errors
end

-- ========================================================
-- 【寫回設定檔】與【database 掃描新增物品】
-- ========================================================
local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function write_all(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

-- 寫入 JSON：先備份舊檔(.bak)，寫完立刻重讀驗證，壞掉就還原
function sdlogic.save_config(path, data)
    local text, err = json.encode(data)
    if not text then return false, "編碼失敗: " .. tostring(err) end
    local old = fs.exists(path) and read_all(path) or nil
    if old then write_all(path .. ".bak", old) end
    if not write_all(path, text) then return false, "無法寫入 " .. tostring(path) end
    local back = read_all(path)
    if not back or not json.decode(back) then
        if old then write_all(path, old) end
        return false, "寫入後驗證失敗，已還原舊檔"
    end
    parse_cache.path, parse_cache.mtime, parse_cache.data, parse_cache.checked_at = nil, nil, nil, nil
    built_cache.data = nil
    return true
end

-- 讀取最新的設定檔準備修改；檔案不存在時回傳空設定 (掃描會建立它)
local function read_for_edit(path)
    if not fs.exists(path) then return { items = {} } end
    local data, err = sdlogic.parse_config_file(path, true)
    if not data then return nil, err end
    return data
end

local function db_stack(db, slot)
    local ok, stack = pcall(db.get, slot)
    if ok and type(stack) == "table" and type(stack.label) == "string" and stack.label ~= ""
        and type(stack.name) == "string" and stack.name ~= "" then
        return stack
    end
end

-- 舊格式 (只有 slot) 的項目：用 database 補上 name/damage/label 並移除 slot。回傳 轉換筆數, 錯誤
function sdlogic.migrate_legacy_slots()
    local m = main()
    local path = m.config_file_path
    if not fs.exists(path) then return 0 end
    local data, err = read_for_edit(path)
    if not data then return 0, err end
    local pending = false
    for _, raw in ipairs(data.items) do
        if type(raw) == "table" and val(raw.label) == nil and val(raw.slot) ~= nil then pending = true end
    end
    if not pending then return 0 end
    local db = sdlogic.get_database(data)
    if not db then return 0, "找不到 database 組件，無法轉換舊格式 (slot)" end
    local changed = 0
    for _, raw in ipairs(data.items) do
        if type(raw) == "table" and val(raw.label) == nil and is_int(val(raw.slot)) then
            local stack = db_stack(db, raw.slot)
            if stack then
                raw.name, raw.damage, raw.label = stack.name, stack.damage or 0, stack.label
                raw.slot = nil
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        local ok, e = sdlogic.save_config(path, data)
        if not ok then return 0, e end
    end
    return changed
end

-- 掃描 database，把 JSON 裡還沒有的物品新增進去 (mode_tag = monitor，只顯示不補貨)。
-- 回傳 新增數量, 新增的 label 清單, 因 label 重複而略過的清單；失敗回傳 nil, 錯誤訊息。
function sdlogic.scan_database()
    local m = main()
    local path = m.config_file_path
    local data, err = read_for_edit(path)
    if not data then return nil, "設定檔無法讀取，已取消掃描以免覆蓋: " .. tostring(err) end
    local db = sdlogic.get_database(data)
    if not db then return nil, "找不到 database 組件" end
    if type(data.items) ~= "table" then return nil, '設定檔缺少 "items" 陣列' end

    -- AE2 只用 label 搜尋，所以以 label 判斷「是否已登錄」；
    -- label 相同但 name/damage 不同的 database 物品無法同時登錄，會列在 skipped
    local known = {}
    for _, raw in ipairs(data.items) do
        if type(raw) == "table" then
            local l = val(raw.label)
            if type(l) == "string" then known[l] = { name = val(raw.name), damage = val(raw.damage) } end
        end
    end

    local added, skipped, skipped_seen = {}, {}, {}
    for slot = 1, (m.database_slots or 81) do
        local stack = db_stack(db, slot)
        if stack then
            local damage = stack.damage or 0
            local have = known[stack.label]
            if not have then
                known[stack.label] = { name = stack.name, damage = damage }
                data.items[#data.items + 1] = {
                    name = stack.name, damage = damage, label = stack.label,
                    mode_tag = "monitor", target_quantity = 0,
                }
                added[#added + 1] = stack.label
            elseif (have.name ~= stack.name or have.damage ~= damage) and not skipped_seen[stack.label] then
                skipped_seen[stack.label] = true
                skipped[#skipped + 1] = stack.label
            end
        end
    end
    if #added > 0 then
        local ok, e = sdlogic.save_config(path, data)
        if not ok then return nil, e end
    end
    return #added, added, skipped
end

-- 初始化：先轉換舊格式，再掃描新增。回傳 訊息, 是否有錯誤 (沒事可做回傳 nil)
function sdlogic.init_config()
    local msgs, had_error = {}, false
    local migrated, merr = sdlogic.migrate_legacy_slots()
    if merr then msgs[#msgs + 1] = merr; had_error = true
    elseif migrated > 0 then msgs[#msgs + 1] = string.format("已轉換 %d 筆舊格式", migrated) end
    local n, added = sdlogic.scan_database()
    if not n then msgs[#msgs + 1] = added; had_error = true
    elseif n > 0 then msgs[#msgs + 1] = string.format("已新增 %d 個物品", n) end
    if #msgs == 0 then return nil end
    return table.concat(msgs, "；"), had_error
end

-- 查詢單一物品(只用 label)在 AE2 網路內的總數量。失敗回傳 nil, 錯誤訊息 (呼叫端不可當成 0 處理)
function sdlogic.count_item(entry, ae)
    ae = ae or main().ae
    if not ae then return nil, "找不到 ME 介面" end
    local ok, items = pcall(ae.getItemsInNetwork, { label = entry.label })
    if not ok or type(items) ~= "table" then return nil, "AE2 查詢失敗" end
    local total = 0
    for _, it in ipairs(items) do
        if it.label == entry.label then total = total + (it.size or 0) end
    end
    return total
end

-- 一次查完整份清單。query_mode: "filter" 每個 label 各查一次 getItemsInNetwork({label=...})；
-- "full" 只呼叫一次 getItemsInNetwork() 再自己加總；"auto" 物品數超過 query_full_threshold 就用 full。
-- 每次元件呼叫都會花掉至少 1 tick，物品多的時候 full 通常快很多。
-- 回傳 counts(label → 數量；查詢失敗的 label 為 nil), 實際使用的模式
function sdlogic.query_counts(items, ctx)
    local mode = ctx.query_mode or "auto"
    if mode == "auto" then mode = (#items > (ctx.query_full_threshold or 8)) and "full" or "filter" end
    local counts = {}
    if mode == "full" then
        if ctx.ae then
            local ok, all = pcall(ctx.ae.getItemsInNetwork)
            if ok and type(all) == "table" then
                local sums = {}
                for _, it in ipairs(all) do
                    if it.label then sums[it.label] = (sums[it.label] or 0) + (it.size or 0) end
                end
                for _, entry in ipairs(items) do counts[entry.label] = sums[entry.label] or 0 end
            end
        end
    else
        for _, entry in ipairs(items) do counts[entry.label] = sdlogic.count_item(entry, ctx.ae) end
    end
    return counts, mode
end

-- 測試用：清掉快取
function sdlogic._reset_config_cache()
    parse_cache.path, parse_cache.mtime, parse_cache.data, parse_cache.checked_at = nil, nil, nil, nil
    built_cache.data, built_cache.items, built_cache.errors = nil, nil, nil
    last_good = nil
    last_log_text = nil
    draw_cache = {}
end

-- 全域鎖持有者若已不在設定檔中，或不再是特殊複製模式，就強制解鎖，
-- 避免其他複製物品永遠排隊。
function sdlogic.release_stale_lock(monitor_items)
    local current = _G.current_global_task
    if not current then return end
    for _, info in ipairs(monitor_items) do
        if info.key == current and info.mode_tag == "clone" then
            return
        end
    end
    _G.current_global_task = nil
    if component.isAvailable("modem") then
        component.modem.broadcast(201, "STOP_CLONE")
    end
end

-- 處理第一頁：系統時間顯示與微調
-- 第一頁：網路上所有電池(multimachine.supercapacitor)的電量
function sdlogic.render_page1()
    local ctx = main()
    local force = ctx.battery_rescan_requested
    ctx.battery_rescan_requested = false
    local list, sum = sdapi.read_all_batteries(force)
    local white, cyan, yellow, green, red, grey = 0xFFFFFF, 0x00FFFF, 0xFFEE00, 0x00FF00, 0xFF5555, 0xBBBBBB

    local function level_color(pct)
        if not pct then return grey end
        if pct >= ctx.high_threshold then return green end
        if pct >= ctx.energy_threshold then return yellow end
        return red
    end

    put(6, 11, "◆─────────────────────────────── BATTERY MONITOR / 電池電量 ───────────────────────────────◆", cyan)
    if #list == 0 then
        put(6, 13, fit("  找不到電池：網路上沒有 getName() 含 " .. tostring(ctx.battery_name) .. " 的 gt_machine。", 120), yellow)
        clear_rows(14, ctx.SCR_H)
        return
    end
    if sum.total > 0 then
        put(6, 13, fit(string.format("  共 %d 顆電池  |  合計 %s / %s  |  %.1f%%%s", sum.count,
            sdlogic.format_eu(sum.stored), sdlogic.format_eu(sum.total), sum.pct,
            sum.counted < sum.count and string.format("  (有 %d 顆無法讀取)", sum.count - sum.counted) or ""), 120),
            level_color(sum.pct))
    else
        put(6, 13, fit(string.format("  共 %d 顆電池  |  無法讀取電量", sum.count), 120), red)
    end
    put(6, 14, "  # |位址  |    目前電量    |      總容量      |  比例  | 電量條", grey)
    put(6, 15, "  ──+──────+────────────────+──────────────────+────────+──────────────────────", grey)

    local per_page = ctx.SCR_H - 15
    local shown = math.min(#list, per_page)
    for idx = 1, shown do
        local b = list[idx]
        local y = 15 + idx
        if idx == per_page and #list > per_page then
            put(6, y, fit(string.format("  … 另有 %d 顆未顯示", #list - per_page + 1), 100), yellow)
        elseif b.err then
            put(6, y, fit(string.format(" %02d |%s| %s", idx, fit(b.address:sub(1, 5), 6), b.err), 100), red)
        else
            local stored_txt = b.stored and sdlogic.format_eu(b.stored) or "?"
            local total_txt = b.total and sdlogic.format_eu(b.total) or "?"
            local filled = math.floor(b.pct / 100 * 20 + 0.5)
            filled = math.max(0, math.min(20, filled))
            put(6, y, string.format(" %02d |%s|%15s |%17s |%6.1f%% | ", idx, fit(b.address:sub(1, 5), 6), stored_txt, total_txt, b.pct)
                .. string.rep("█", filled) .. string.rep("░", 20 - filled) .. "  ", level_color(b.pct))
        end
    end
    clear_rows(15 + shown + 1, ctx.SCR_H)
end

-- 處理第二頁：AE2 核心庫存盤點、佇列智慧調度與補貨下單
-- 全域鎖持有者的顯示名稱
local function holder_label(items)
    for _, info in ipairs(items) do
        if info.key == _G.current_global_task then return info.label end
    end
    return tostring(_G.current_global_task)
end

function sdlogic.render_page2()
    local ctx = main()
    local t_start = ctx.get_now_time()
    local now_time = t_start
    -- 1. 讀取設定 (有快取：config_check_interval 秒內不碰檔案)
    local monitor_items, cfg_errors = sdlogic.load_hybrid_config()
    local t_cfg = ctx.get_now_time()

    sdlogic.release_stale_lock(monitor_items)

    -- 設定檔錯誤提示 (第 12 列)
    if cfg_errors[1] then
        local more = #cfg_errors > 1 and string.format(" (另有 %d 項)", #cfg_errors - 1) or ""
        put(6, 12, fit("⚠️ " .. cfg_errors[1] .. more, 150), 0xFF5555)
    else
        put(6, 12, string.rep(" ", 150), 0xFFFFFF)
    end

    -- 礦機摘要 (第 9 列)：有 miner 物品或有礦機上線時才顯示
    local has_miner_items = false
    for _, it in ipairs(monitor_items) do if it.mode_tag == "miner" then has_miner_items = true break end end
    local miner_text, miner_ok = require("sdminer").summary(has_miner_items)
    if miner_text then
        put(6, 9, fit(miner_text, 150), miner_ok and 0x55AFFF or 0xFF5555)
    else
        put(6, 9, string.rep(" ", 150), 0xFFFFFF)
    end

    -- 如果設定檔是空的或不存在，提示一下
    if #monitor_items == 0 then
        ctx.list_page, ctx.list_pages = 1, 1
        ctx.draw_pager()
        put(6, 17, fit(" ⚠️ 目前 ae_config.json 為空、格式錯誤或硬碟未正確掛載。", 90), 0xFFEE00)
        clear_rows(18, ctx.SCR_H)
        return
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

    -- 2. 查詢 AE2 庫存 (只用 label)
    local counts, query_mode = sdlogic.query_counts(monitor_items, ctx)
    local t_ae = ctx.get_now_time()

    -- 遍歷動態物品清單
    for idx, item_info in ipairs(monitor_items) do
        local item_name = item_info.label
        local item_key = item_info.key
        local count = counts[item_name]

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
        local color = 0xFFFFFF
        local item_cooldown = item_info.cooldown or ctx.default_cooldown
        local req_handle = ctx.active_ae_requests[item_key]
        local tag1, tag2, tag3 = 0, 0, 0
        
        -- 異步追蹤 AE2 訂單任務
        if req_handle then
            local is_done_ok, is_done = pcall(req_handle.isDone)
            local is_canceled_ok, is_canceled = pcall(req_handle.isCanceled)
            
            if is_done_ok and is_canceled_ok and not is_done and not is_canceled then
                tag3 = 1 -- 代表 AE 核心正在合成中
            else
                ctx.active_ae_requests[item_key] = nil
                ctx.last_order_time[item_key] = now_time + 60
                tag3 = 0
            end
        end
        
        local last_order = ctx.last_order_time[item_key] or 0
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
            color = 0xFF5555
            status_msg = "[⚠️ AE查詢失敗]"
            tag1 = 7
        elseif item_info.mode_tag == "miner" then
            -- 礦機模式：庫存不足時由 sdminer 把無人機派給礦機電腦，這裡只負責顯示狀態
            local sdminer = require("sdminer")
            local st = sdminer.status(item_name) or {}
            local assigned = st.assigned or 0
            if not sdminer.is_active() then
                color = 0xFF5555
                status_msg = "[⚠️ 礦機模組未啟用]"
                tag1 = 9
            elseif count >= item_info.target_quantity then
                if assigned > 0 then
                    color = 0x55AFFF
                    status_msg = string.format("[⛏ 常駐 %d台]", assigned)
                    tag1, tag2 = 8, assigned
                else
                    color = 0xFFFFFF
                    status_msg = "[✅庫存充裕安全]"
                end
            else
                local ratio = (item_info.target_quantity - count) / item_info.target_quantity
                local needed = st.needed or math.ceil(ratio * item_info.weight)
                if assigned >= needed then
                    color = 0x00FF00
                    status_msg = string.format("[⛏ 開採中 %d/%d台]", assigned, needed)
                    tag1, tag2 = 8, assigned
                elseif st.reason == "no_drone" then
                    color = 0xFFAA00
                    status_msg = string.format("[⚠️ 缺無人機 %d/%d]", assigned, needed)
                    tag1, tag2 = 9, needed
                elseif st.reason == "no_miner" then
                    color = 0xFFAA00
                    status_msg = string.format("[⚠️ 缺礦機 %d/%d]", assigned, needed)
                    tag1, tag2 = 9, needed
                else
                    color = 0xFFEE00
                    status_msg = string.format("[⏳ 等待調度 %d/%d]", assigned, needed)
                    tag1, tag2 = 9, needed
                end
            end
        elseif is_special_mode or (item_info.mode_tag == "restock" and count < item_info.target_quantity) then
            -- 狀況甲：特殊複製模式
            if is_special_mode then
                local target_circuit = item_info.circuit
                local priority = item_info.priority or 9 
                
                if count >= item_info.target_quantity then
                    if _G.current_global_task == item_key then
                        --print("[調度中心] 高優先級物品已達標，解鎖全域通道: " .. item_name)
                        _G.current_global_task = nil
                        if component.isAvailable("modem") then
                            component.modem.broadcast(201, "STOP_CLONE")
                        end
                    end
                    color = 0xFFFFFF
                    status_msg = "[✅庫存充裕安全]"
                    tag1, tag2, tag3 = 0, 0, 0
                else
                    if _G.current_global_task == nil then
                        _G.current_global_task = item_key
                    else
                        local current_running_priority = 9
                        for _, check_info in ipairs(monitor_items) do
                            if check_info.key == _G.current_global_task then
                                current_running_priority = check_info.priority or 9
                                break
                            end
                        end
                        
                        if priority < current_running_priority then
                            --print(string.format("[權重插隊] 發現更高優先級物資！強制換單 [%s] -> [%s]", _G.current_global_task, item_name))
                            _G.current_global_task = item_key
                            if component.isAvailable("modem") then
                                component.modem.broadcast(201, "KEEP_ALIVE", target_circuit, item_info.target_quantity, count)
                            end
                        end
                    end
                    
                    if _G.current_global_task == item_key then
                        color = 0x00FF00
                        status_msg = string.format("[📡 複製中: Cnf %d | Prio %d]", target_circuit, priority)
                        tag1 = 5
                        tag2 = target_circuit
                        
                        if component.isAvailable("modem") then
                            if type(component.modem.setStrength) == "function" then component.modem.setStrength(400) end
                            component.modem.broadcast(201, "KEEP_ALIVE", target_circuit, item_info.target_quantity, count)
                        end
                    else
                        color = 0xFFAA00
                        status_msg = string.format("[⏳ 排隊中 (P%d) | 鎖定者: %s]", priority, usub(holder_label(monitor_items), 4))
                        tag1 = 6
                        tag2 = 0
                    end
                end
                
            -- 狀況乙：常規 AE2 補貨邏輯
            elseif tag3 == 1 then
                color = 0x55AFFF 
                status_msg = "[🛠 訂單合成中...]"
                tag1 = 2; tag2 = 999
            elseif last_order > now_time or time_passed < item_cooldown then
                color = 0x55AFFF
                status_msg = string.format("[🛠 補貨冷卻: %ds]", remaining)
                tag1 = 2; tag2 = remaining
            else
                local success_craft, craftables = pcall(ctx.ae.getCraftables, {label = item_name})
                if success_craft and craftables and craftables[1] then
                    local target_recipe = craftables[1]
                    local success_req, request_handle = pcall(target_recipe.request, item_info.target_once)
                    if success_req and request_handle then 
                        ctx.last_order_time[item_key] = now_time
                        ctx.active_ae_requests[item_key] = request_handle
                        color = 0xFFEE00 
                        status_msg = string.format("[🚀 已下單 +%d]", item_info.target_once)
                        tag1 = 1
                    else
                        ctx.last_order_time[item_key] = now_time - item_cooldown + 30
                        color = 0xFF5555 
                        status_msg = "[❌ AE拒絕下單/無原料]"
                        tag1 = 3
                    end
                else
                    color = 0xFF5555
                    status_msg = "[⚠️ 未在AE中找到配方]"
                    tag1 = 4
                end
            end
        else
            if ctx.active_ae_requests[item_key] then ctx.active_ae_requests[item_key] = nil end
            if _G.current_global_task == item_key then _G.current_global_task = nil end
            color = count < 10 and 0xFF5555 or 0xFFFFFF
            status_msg = "[✅庫存充裕安全]"
            tag1, tag2, tag3 = 0, 0, 0
        end
        
        -- 渲染至螢幕 (只畫改變的列)
        local row_pos = 15 + (idx - first_idx + 1)
        if idx >= first_idx and idx <= last_idx and row_pos <= ctx.SCR_H then
            put(6, row_pos, string.format("  [%02d]|", idx) .. fit(item_name, 35) ..
                string.format("|%11s |", count_str) .. fit(status_msg, 28) .. "      ", color)
        end

        -- 快照紀錄
        table.insert(log_lines, string.format("%s=%d=%d=%d", item_name, tag1, tag2, tag3))
    end
    
    -- 清掉這一頁沒有用到的下方列 (清單縮短時)
    local shown = math.max(0, math.min(last_idx, #monitor_items) - first_idx + 1)
    clear_rows(15 + shown + 1, ctx.SCR_H)

    -- 覆蓋寫入狀態文本：內容沒變就不寫檔，少一次檔案系統操作
    local log_text = table.concat(log_lines, "\n") .. "\n"
    if log_text ~= last_log_text then
        local ok_log = pcall(function()
            local f = io.open(ctx.log_file_path, "w")
            if f then
                f:write(log_text)
                f:close()
            else
                error("open failed")
            end
        end)
        if ok_log then last_log_text = log_text end
    end

    -- 效能讀數 (第 10 列)：方便判斷慢在哪裡。單位是秒(遊戲 tick 換算)
    local t_end = ctx.get_now_time()
    ctx.perf = { total = t_end - t_start, cfg = t_cfg - t_start, ae = t_ae - t_cfg, mode = query_mode, n = #monitor_items }
    put(6, 10, fit(string.format("刷新耗時 %.2fs (設定 %.2f / AE2 %.2f / 其他 %.2f)  查詢模式: %s  物品: %d",
        ctx.perf.total, ctx.perf.cfg, ctx.perf.ae, ctx.perf.total - ctx.perf.cfg - ctx.perf.ae, query_mode, #monitor_items), 110), 0x777777)
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
