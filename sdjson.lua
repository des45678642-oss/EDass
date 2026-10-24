-- 檔案路徑：sdjson.lua
-- 精簡版 JSON 解碼器 (OpenOS 沒有內建 JSON)。只提供 decode；出錯時回傳 nil, "訊息 (行 X 列 Y)"。
-- 相容 Lua 5.2 / 5.3。
local json = {}

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local MAX_DEPTH = 32

-- 編碼 Unicode 碼位為 UTF-8 (不依賴 utf8 函式庫)
local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + (cp >> 6), 0x80 + (cp & 0x3F)) end
    if cp < 0x10000 then
        return string.char(0xE0 + (cp >> 12), 0x80 + ((cp >> 6) & 0x3F), 0x80 + (cp & 0x3F))
    end
    return string.char(0xF0 + (cp >> 18), 0x80 + ((cp >> 12) & 0x3F), 0x80 + ((cp >> 6) & 0x3F), 0x80 + (cp & 0x3F))
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

function json.decode(str)
    if type(str) ~= "string" then return nil, "輸入不是字串" end
    local pos = 1
    if str:sub(1, 3) == "\239\187\191" then pos = 4 end  -- UTF-8 BOM

    local function fail(msg, at)
        at = at or pos
        local line, col = 1, 1
        for i = 1, at - 1 do
            if str:byte(i) == 10 then line = line + 1; col = 1 else col = col + 1 end
        end
        error({ json_error = string.format("%s (行 %d 列 %d)", msg, line, col) }, 0)
    end

    local function skip_ws()
        pos = str:find("[^ \t\r\n]", pos) or (#str + 1)
    end

    local parse_value

    local function parse_string()
        local start = pos
        pos = pos + 1                         -- 跳過開頭引號
        local buf = {}
        while true do
            local s, e = str:find('["\\%c]', pos)
            if not s then fail("字串沒有結尾", start) end
            buf[#buf + 1] = str:sub(pos, s - 1)
            local c = str:sub(s, s)
            if c == '"' then
                pos = s + 1
                return table.concat(buf)
            elseif c == "\\" then
                local n = str:sub(s + 1, s + 1)
                if n == "u" then
                    local hex = str:match("^%x%x%x%x", s + 2)
                    if not hex then fail("無效的 \\u 跳脫", s) end
                    local cp = tonumber(hex, 16)
                    local used = 6
                    if cp >= 0xD800 and cp <= 0xDBFF then      -- 代理對
                        local low = str:match("^\\u(%x%x%x%x)", s + 6)
                        low = low and tonumber(low, 16)
                        if low and low >= 0xDC00 and low <= 0xDFFF then
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                            used = 12
                        else
                            fail("無效的代理對", s)
                        end
                    end
                    buf[#buf + 1] = utf8_char(cp)
                    pos = s + used
                elseif ESCAPES[n] then
                    buf[#buf + 1] = ESCAPES[n]
                    pos = s + 2
                else
                    fail("無效的跳脫字元 \\" .. n, s)
                end
            else
                fail("字串中不允許未跳脫的控制字元", s)
            end
        end
    end

    local function parse_number()
        local num = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        local int_part = str:match("^-?%d+", pos)
        if not int_part or int_part:match("^-?0%d") then fail("無效的數字") end
        local n = tonumber(num)
        if not n then fail("無效的數字") end
        pos = pos + #num
        return n
    end

    local function parse_literal(word, value)
        if str:sub(pos, pos + #word - 1) == word then
            pos = pos + #word
            return value
        end
        fail("無效的值")
    end

    local function parse_array(depth)
        local arr = {}
        pos = pos + 1
        skip_ws()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            arr[#arr + 1] = parse_value(depth + 1)
            skip_ws()
            local c = str:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1; return arr
            else fail("陣列中預期 ',' 或 ']'") end
        end
    end

    local function parse_object(depth)
        local obj = {}
        pos = pos + 1
        skip_ws()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip_ws()
            if str:sub(pos, pos) ~= '"' then fail("物件的鍵必須是字串") end
            local key = parse_string()
            skip_ws()
            if str:sub(pos, pos) ~= ":" then fail("鍵後面預期 ':'") end
            pos = pos + 1
            obj[key] = parse_value(depth + 1)
            skip_ws()
            local c = str:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1; return obj
            else fail("物件中預期 ',' 或 '}'") end
        end
    end

    function parse_value(depth)
        if depth > MAX_DEPTH then fail("巢狀層數過深") end
        skip_ws()
        local c = str:sub(pos, pos)
        if c == "{" then return parse_object(depth)
        elseif c == "[" then return parse_array(depth)
        elseif c == '"' then return parse_string()
        elseif c == "t" then return parse_literal("true", true)
        elseif c == "f" then return parse_literal("false", false)
        elseif c == "n" then return parse_literal("null", json.null)
        elseif c == "-" or c:match("%d") then return parse_number()
        elseif c == "" then fail("內容意外結束")
        else fail("無法辨識的字元 '" .. c .. "'") end
    end

    local ok, result = pcall(function()
        local v = parse_value(0)
        skip_ws()
        if pos <= #str then fail("JSON 結尾後還有多餘內容") end
        return v
    end)
    if ok then return result end
    if type(result) == "table" and result.json_error then return nil, result.json_error end
    return nil, "JSON 解析錯誤: " .. tostring(result)
end

return json
