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

-- ========================================================
-- encode：輸出穩定、好讀的 JSON (鍵的順序固定，方便手動編輯與比對差異)
-- 最上層物件逐行排版；items 陣列每筆物品佔一行。回傳 text 或 nil, 錯誤訊息。
-- 注意：空的 table 一律輸出為 []。
-- ========================================================
local KEY_ORDER = { "database", "items", "name", "damage", "label", "mode_tag", "target_quantity",
                    "target_once", "cooldown", "circuit", "priority" }
local KEY_RANK = {}
for i, k in ipairs(KEY_ORDER) do KEY_RANK[k] = i end

local function encode_string(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return '\\\\' end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then error({ json_error = "無法編碼 NaN/Infinity" }, 0) end
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then return string.format("%d", n) end
    return string.format("%.14g", n)
end

local function is_array(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return true end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do
        if type(k) ~= "string" then error({ json_error = "物件的鍵必須是字串" }, 0) end
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        local ra, rb = KEY_RANK[a], KEY_RANK[b]
        if ra and rb then return ra < rb end
        if ra then return true end
        if rb then return false end
        return a < b
    end)
    return keys
end

local function encode_value(v, depth, compact, seen)
    local tv = type(v)
    if v == json.null or v == nil then return "null" end
    if tv == "string" then return encode_string(v) end
    if tv == "number" then return encode_number(v) end
    if tv == "boolean" then return tostring(v) end
    if tv ~= "table" then error({ json_error = "無法編碼型別 " .. tv }, 0) end
    if seen[v] then error({ json_error = "資料有循環參照" }, 0) end
    seen[v] = true
    local inline = compact or depth >= 2
    local pad = inline and "" or string.rep("  ", depth + 1)
    local nl = inline and "" or "\n"
    local sep = inline and ", " or (",\n")
    local parts = {}
    local out
    if is_array(v) then
        for i = 1, #v do parts[#parts + 1] = pad .. encode_value(v[i], depth + 1, compact, seen) end
        if #parts == 0 then out = "[]"
        else out = "[" .. nl .. table.concat(parts, sep) .. nl .. (inline and "" or string.rep("  ", depth)) .. "]" end
    else
        for _, k in ipairs(sorted_keys(v)) do
            parts[#parts + 1] = pad .. encode_string(k) .. ": " .. encode_value(v[k], depth + 1, compact, seen)
        end
        out = "{" .. nl .. table.concat(parts, sep) .. nl .. (inline and "" or string.rep("  ", depth)) .. "}"
    end
    seen[v] = nil
    return out
end

function json.encode(value, opts)
    local ok, result = pcall(encode_value, value, 0, opts and opts.compact, {})
    if ok then return result .. ((opts and opts.compact) and "" or "\n") end
    if type(result) == "table" and result.json_error then return nil, result.json_error end
    return nil, "JSON 編碼錯誤: " .. tostring(result)
end

return json
