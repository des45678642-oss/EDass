--data.json 的讀寫。蜜蜂的 tag 是 gzip 壓縮過的二進位 NBT，JSON 放不下原始位元組，
--所以存檔時轉成 base64、讀檔時還原成「一模一樣的位元組」，這樣 bot.checkItem 用 stack.tag ~= filter.tag 比對時才會相等。
local json = require("json")

local M = {}

M.TAG_FIELDS = { "assistantDroneTag", "assistantPrincessTag", "usingPrincessTag" }

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.b64encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = n // 262144, (n // 4096) % 64, (n // 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:byte(i)] = i - 1 end

--回傳 原始字串；格式錯誤回傳 nil, 訊息
function M.b64decode(s)
    if #s % 4 ~= 0 or s:find("[^A-Za-z0-9+/=]") then return nil, "不是合法的 base64" end
    local out = {}
    for i = 1, #s, 4 do
        local a, b, c, d = s:byte(i, i + 3)
        if a == 61 or b == 61 then return nil, "不是合法的 base64" end
        local pad = (c == 61 and 1 or 0) + (d == 61 and 1 or 0)
        if (c == 61 and d ~= 61) or (pad > 0 and i + 3 < #s) then return nil, "不是合法的 base64" end
        local n = B64_INDEX[a] * 262144 + B64_INDEX[b] * 4096 + (B64_INDEX[c] or 0) * 64 + (B64_INDEX[d] or 0)
        local chunk = string.char(n // 65536, (n // 256) % 256, n % 256)
        out[#out + 1] = pad == 0 and chunk or chunk:sub(1, 3 - pad)
    end
    return table.concat(out)
end

--把記憶體裡的資料轉成 JSON 文字 (tag 轉 base64)
function M.encode(data)
    local copy = {}
    for k, v in pairs(data) do copy[k] = v end
    for _, field in ipairs(M.TAG_FIELDS) do
        if type(copy[field]) == "string" then copy[field] = M.b64encode(copy[field]) end
    end
    return json.encode(copy)
end

--回傳 資料表；失敗回傳 nil, 錯誤訊息
function M.decode(text)
    local data, err = json.decode(text)
    if type(data) ~= "table" or data == json.null or data[1] ~= nil then return nil, err or "內容不是 JSON 物件" end
    for _, field in ipairs(M.TAG_FIELDS) do
        local v = data[field]
        if v == json.null then
            data[field] = nil
        elseif v ~= nil then
            if type(v) ~= "string" then return nil, field .. " 必須是字串" end
            local raw, derr = M.b64decode(v)
            if not raw then return nil, field .. ": " .. derr end
            data[field] = raw
        end
    end
    if data.speedLevel == json.null then data.speedLevel = nil end
    if data.initialized ~= nil and type(data.initialized) ~= "boolean" then return nil, "initialized 必須是 true/false" end
    if data.speedLevel ~= nil and type(data.speedLevel) ~= "number" then return nil, "speedLevel 必須是數字" end
    return data
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

--先寫暫存檔、讀回驗證，再換掉正式檔；寫到一半斷電也不會留下半份 data.json
function M.save(path, data)
    local text, err = M.encode(data)
    if not text then return false, err end
    local tmp = path .. ".tmp"
    local f, oerr = io.open(tmp, "wb")
    if not f then return false, "無法寫入 " .. tmp .. ": " .. tostring(oerr) end
    f:write(text)
    f:close()
    local back = M.decode(read_all(tmp) or "")
    if not back then
        os.remove(tmp)
        return false, "寫入後驗證失敗，已保留原本的 " .. path
    end
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then return false, "無法取代 " .. path .. ": " .. tostring(rerr) end
    return true
end

--讀 path。回傳 資料表, 來源("json"|"legacy")；檔案不存在回傳 nil；
--檔案存在但壞掉回傳 nil, 錯誤訊息 (呼叫端不可以直接當成全新資料覆蓋掉它)。
--legacy_path/unserialize 是舊版 data.txt 與 serialization.unserialize，讀得出來就轉成 JSON。
function M.load(path, legacy_path, unserialize)
    local text = read_all(path)
    if text then
        local data, err = M.decode(text)
        if not data then return nil, path .. " 無法解析: " .. tostring(err) end
        return data, "json"
    end
    if legacy_path and unserialize then
        local old = read_all(legacy_path)
        if old then
            local ok, data = pcall(unserialize, old)
            if ok and type(data) == "table" then return data, "legacy" end
        end
    end
    return nil
end

return M
