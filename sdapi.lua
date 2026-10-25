-- 檔案路徑：sdapi.lua
-- 電池相關的硬體 API：找出網路上所有 GT 蘭波頓超級電容(multimachine.supercapacitor)並讀取電量。
-- 參數(電池名稱、重新掃描間隔…)直接讀取主程式 touch_menu，不用傳遞。
local component = require("component")

local api = {}

-- 延遲載入主程式，避免與 touch_menu 載入時互相 require 造成循環
local function main() return require("touch_menu") end

-- ========================================================
-- 【數字解析】getSensorInformation 的數字可能有千分位逗號、顏色碼，也可能是科學記號 (1.5E10)
-- ========================================================
local function strip_codes(s)
    s = tostring(s)
    s = s:gsub("\194\167%w", "")          -- Minecraft 顏色碼 §a
    s = s:gsub("\27%[[%d;]*m", "")        -- ANSI 顏色碼
    return s
end

local function strip_commas(s)
    local prev
    repeat prev = s; s = s:gsub("(%d),(%d)", "%1%2") until s == prev
    return s
end

-- 回傳字串中依序出現的數字 (支援 1234 / 12.5 / 1.5E10 / 1.5e+10)
function api.numbers_in(s)
    s = strip_commas(strip_codes(s))
    local out, pos = {}, 1
    while true do
        local start = s:find("%d", pos)
        if not start then break end
        local tok = s:match("^%d+%.?%d*[eE][+-]?%d+", start) or s:match("^%d+%.?%d*", start)
        local n = tonumber(tok)
        if n then out[#out + 1] = n + 0.0 end
        pos = start + #tok
    end
    return out
end

-- 從 getSensorInformation() 的行列解析電量。成功回傳 { stored=, total=, pct= }，
-- 只有百分比時 stored/total 為 nil；解析不到回傳 nil, 原因
function api.parse_sensor(lines)
    if type(lines) ~= "table" then return nil, "沒有感測資料" end
    local stored, total, pct
    for _, raw in ipairs(lines) do
        local line = strip_codes(raw)
        local low = line:lower()
        local after = line:match("^[^:]*:(.*)$") or line     -- 冒號後面才是數值
        if low:find("used%s+capacity") then
            local p = strip_commas(after):match("([%d%.]+)%s*%%")
            if p and not pct then pct = tonumber(p) end
        elseif low:find("stored") and low:find("/", 1, true) then
            local nums = api.numbers_in(after)
            if #nums >= 2 and not (stored and total) then stored, total = nums[1], nums[2] end
        elseif low:find("stored") then
            local nums = api.numbers_in(after)
            if nums[1] and not stored then stored = nums[1] end
        elseif low:find("total") and (low:find("capacity") or low:find("eu")) then
            local nums = api.numbers_in(after)
            if nums[1] and not total then total = nums[1] end
        end
    end
    if stored and total and total > 0 then
        return { stored = stored, total = total, pct = math.min(100, stored / total * 100) }
    end
    if pct then return { pct = pct } end
    return nil, "無法解析電量資訊"
end

-- ========================================================
-- 【電池搜尋】掃描所有 gt_machine，getName() 含 multimachine.supercapacitor 的就是電池
-- 掃描要對每個元件呼叫 getName，比較慢，所以結果快取，間隔 battery_rescan_interval 秒才重掃
-- ========================================================
local cache = { list = nil, scanned_at = nil }

function api.find_batteries(force)
    local m = main()
    local now = m.get_now_time and m.get_now_time() or 0
    local interval = m.battery_rescan_interval or 60
    if not force and cache.list and cache.scanned_at and now >= cache.scanned_at and now - cache.scanned_at < interval then
        return cache.list
    end
    local list = {}
    local ok_list = pcall(function()
        for addr in component.list("gt_machine") do
            local ok, proxy = pcall(component.proxy, addr)
            if ok and proxy then
                local ok_name, name = pcall(proxy.getName)
                if ok_name and type(name) == "string" and name:find(m.battery_name or "multimachine.supercapacitor", 1, true) then
                    list[#list + 1] = { address = addr, proxy = proxy }
                end
            end
        end
    end)
    if not ok_list then list = {} end
    table.sort(list, function(a, b) return a.address < b.address end)
    cache.list, cache.scanned_at = list, now
    return list
end

-- 讀取單顆電池。回傳 { address=, stored=, total=, pct= } 或 { address=, err= }
function api.read_battery(b)
    local ok, lines = pcall(b.proxy.getSensorInformation)
    if not ok then return { address = b.address, err = "讀取失敗" } end
    local info, err = api.parse_sensor(lines)
    if not info then return { address = b.address, err = err } end
    info.address = b.address
    return info
end

-- 讀取網路上所有電池。回傳 陣列，另外回傳合計 { stored, total, pct, count }
function api.read_all_batteries(force_rescan)
    local result, sum_stored, sum_total, counted = {}, 0.0, 0.0, 0
    for _, b in ipairs(api.find_batteries(force_rescan)) do
        local info = api.read_battery(b)
        result[#result + 1] = info
        if info.stored and info.total then
            sum_stored = sum_stored + info.stored
            sum_total = sum_total + info.total
            counted = counted + 1
        end
    end
    local summary = { count = #result, counted = counted, stored = sum_stored, total = sum_total,
                      pct = sum_total > 0 and (sum_stored / sum_total * 100) or nil }
    return result, summary
end

-- 測試用：清掉快取
function api._reset_cache() cache.list, cache.scanned_at = nil, nil end

return api
