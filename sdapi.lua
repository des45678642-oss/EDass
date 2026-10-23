-- 檔案路徑：sdapi.lua
-- 時間相關函式。參數(檔案路徑…)直接讀取主程式 touch_menu，不再用傳遞的方式。
-- 設定檔載入 load_hybrid_config 已移到 sdlogic.lua。
local io = require("io")
local computer = require("computer")
local internet = require("internet")

local api = {}

-- 延遲載入主程式，避免與 touch_menu 載入時互相 require 造成循環
local function main() return require("touch_menu") end

function api.update_time()
    local MY_SERVER_URL = "http://192.168.212.103:8080"
    local path = main().realtime_path
    local result, response = pcall(internet.request, MY_SERVER_URL)
    if result and response then
        local html_content = ""
        -- 讀取設有 5 秒上限，避免伺服器無回應時卡死計時器回呼
        local deadline = computer.uptime() + 5
        local read = (type(response) == "table" and type(response.read) == "function") and response.read or response
        repeat
            local ok, chunk = pcall(read)
            if not ok then chunk = nil end
            if chunk then html_content = html_content .. chunk end
        until not chunk or computer.uptime() > deadline
        local raw_time = string.match(html_content, 'id="time">([^<]+)</span>')
        local raw_date = string.match(html_content, 'id="date">([^<]+)</span>')
        if raw_time and raw_date then
            local file = io.open(path, "w")
            if file then
                file:write("date=" .. raw_date .. "\n")
                file:write("time=" .. raw_time .. "\n")
                file:write("type=net\n")
                file:flush()
                file:close()
            end
        end
    end
end

function api.get_days_in_month(month, year)
    local days = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if month == 2 and ((year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)) then return 29 end
    return days[month]
end

function api.local_tick_time(seconds_to_add)
    local path = main().realtime_path
    local file = io.open(path, "r")
    local cur_date, cur_time = nil, nil
    if file then
        for line in file:lines() do
            local d = string.match(line, "^date=(.-)$")
            local t = string.match(line, "^time=(.-)$")
            if d then cur_date = d end
            if t then cur_time = t end
        end
        file:close()
    end
    if cur_date and cur_time then
        local y, mo, d = string.match(cur_date, "(%d%d%d%d)%-(%d%d)%-(%d%d)")
        local h, m, s = string.match(cur_time, "(%d%d):(%d%d):(%d%d)")
        local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
        local hour, min, sec = tonumber(h), tonumber(m), tonumber(s)
        sec = sec + seconds_to_add
        if sec >= 60 then min = min + math.floor(sec / 60); sec = sec % 60 end
        if min >= 60 then hour = hour + math.floor(min / 60); min = min % 60 end
        if hour >= 24 then
            local days_to_add = math.floor(hour / 24)
            hour = hour % 24
            day = day + days_to_add
            while true do
                local max_days = api.get_days_in_month(month, year)
                if day > max_days then
                    day = day - max_days
                    month = month + 1
                    if month > 12 then month = 1; year = year + 1 end
                else break end
            end
        end
        local date_part = string.format("%04d-%02d-%02d", year, month, day)
        local time_part = string.format("%02d:%02d:%02d", hour, min, sec)
        local w_file = io.open(path, "w")
        if w_file then
            w_file:write("date=" .. date_part .. "\n")
            w_file:write("time=" .. time_part .. "\n")
            w_file:write("type=calc\n")
            w_file:flush()
            w_file:close()
        end
    end
end

function api.read_saved_time()
    local realtime_path = main().realtime_path
    local file = io.open(realtime_path, "r")
    local file_date, file_time = "----- --:--", "--:--:--"
    if file then
        for line in file:lines() do
            local d = string.match(line, "^date=(.-)$")
            local t = string.match(line, "^time=(.-)$")
            if d then file_date = d end
            if t then file_time = t end
        end
        file:close()
    end
    return file_time, file_date
end

return api
