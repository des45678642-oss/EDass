-- 檔案路徑：sdquery.lua
-- 讓其他電腦(經由 server.lua 中繼或直接)查詢 AE2 物品數量。
-- 只能查「已登錄在 ae_config.json 裡」的物品 (物品要先放進 database 並掃描新增)。
-- 查詢只接受 label (AE2 端也只用 label 搜尋，name/damage 不參與查詢)。
--
-- OpenComputers 一則網路訊息最多 8 個參數，所以內容一律包成「一個 JSON 字串」。
--
-- 請求 (送到本機 query_port，預設 102)：
--   "AE_QUERY", '{"id":"r1","reply_to":"<回覆電腦UUID>","reply_port":777,"keys":["Iron","鐵錠"],"via":"<中繼UUID，可省略>"}'
--   經 server.lua 中繼時，改送到中繼電腦的 Port 100：
--   "FORWARD_CMD", <touch_menu 電腦UUID>, 102, "AE_QUERY", '{...同上...}'
--   有填 via 時，回覆會透過該電腦的 FORWARD_CMD (Port 100) 轉發，否則直接回覆到 reply_to。
--
-- 回覆 (每個物品一則 + 一則結束訊息)：
--   "AE_QUERY_REPLY", '{"id":"r1","key":"Iron","ok":true,"count":123}'
--   "AE_QUERY_REPLY", '{"id":"r1","key":"Gold","ok":false,"error":"..."}'
--   "AE_QUERY_DONE",  '{"id":"r1","n":2}'
local component = require("component")
local event = require("event")
local sdlogic = require("sdlogic")
local json = require("sdjson")

local sdquery = {}

-- 延遲載入主程式(直接讀取其參數，不用傳遞)
local function main() return require("touch_menu") end

local MAX_KEYS = 60
local MAX_PAYLOAD = 8192
local listener = nil

-- 送出回覆。全部包成單一 JSON 字串，經中繼時總共 5 個參數，遠低於 8 個的上限
local function reply(modem, via, reply_to, reply_port, msg_type, body)
    local text = json.encode(body, { compact = true })
    if not text then return end
    if via and via ~= "" then
        modem.send(via, main().relay_port, "FORWARD_CMD", reply_to, reply_port, msg_type, text)
    else
        modem.send(reply_to, reply_port, msg_type, text)
    end
end

-- 處理一則(已解碼的)請求；modem 為收到請求的那張網卡 (用同一張回覆)
function sdquery.process(modem, request)
    if type(request) ~= "table" then return false end
    local reply_to, reply_port, id = request.reply_to, request.reply_port, request.id
    local via = request.via
    if type(reply_to) ~= "string" or type(reply_port) ~= "number" then return false end
    if type(via) ~= "string" then via = nil end
    local keys = type(request.keys) == "table" and request.keys or {}

    local items = sdlogic.load_hybrid_config()
    local m = main()
    local n = 0
    for idx, key in ipairs(keys) do
        if idx > MAX_KEYS then break end
        n = n + 1
        local matched = false
        if type(key) == "string" then
            for _, item in ipairs(items) do
                if item.label == key then
                    matched = true
                    local count, err = sdlogic.count_item(item, m.ae)
                    if count then
                        reply(modem, via, reply_to, reply_port, "AE_QUERY_REPLY",
                            { id = id, key = key, ok = true, count = count })
                    else
                        reply(modem, via, reply_to, reply_port, "AE_QUERY_REPLY",
                            { id = id, key = key, ok = false, error = err })
                    end
                end
            end
        end
        if not matched then
            reply(modem, via, reply_to, reply_port, "AE_QUERY_REPLY",
                { id = id, key = tostring(key), ok = false, error = "未登錄的物品 (請先放進 database 並掃描新增)" })
        end
    end
    reply(modem, via, reply_to, reply_port, "AE_QUERY_DONE", { id = id, n = n })
    return true
end

local function on_modem_message(_, local_addr, _, port, _, msg, payload)
    local m = main()
    if port ~= m.query_port or msg ~= "AE_QUERY" then return end
    if type(payload) ~= "string" or #payload > MAX_PAYLOAD then return end
    local request = json.decode(payload)
    if type(request) ~= "table" then return end
    local ok, err = pcall(function()
        sdquery.process(component.proxy(local_addr), request)
    end)
    if not ok then io.stderr:write("AE_QUERY 處理失敗: " .. tostring(err) .. "\n") end
end
sdquery._on_modem_message = on_modem_message

function sdquery.start()
    if listener then return true end
    local m = main()
    for addr in component.list("modem") do
        pcall(component.invoke, addr, "open", m.query_port)
    end
    listener = on_modem_message
    event.listen("modem_message", listener)
    return true
end

function sdquery.stop()
    if listener then
        event.ignore("modem_message", listener)
        listener = nil
    end
end

return sdquery
