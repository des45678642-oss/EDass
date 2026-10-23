-- 檔案路徑：sdquery.lua
-- 讓其他電腦(經由 server.lua 中繼或直接)查詢 AE2 物品數量。
-- 只能查「已經存在於 database 組件格子裡」的物品，查詢以 database 格子編號為單位。
--
-- 請求 (送到本機 query_port，預設 102)：
--   "AE_QUERY", 請求編號, 回覆電腦UUID, 回覆埠號, "1,2,64", [中繼電腦UUID]
--   第 6 個參數可省略；填入 server.lua 所在電腦的 UUID 時，回覆會透過
--   該電腦的 FORWARD_CMD (Port 100) 轉發，否則直接回覆到「回覆電腦UUID」。
--
-- 回覆 (每個格子一則 + 一則結束訊息)：
--   "AE_QUERY_REPLY", 請求編號, 格子編號, 成功(boolean), 物品名稱(失敗時為錯誤訊息), 數量
--   "AE_QUERY_DONE",  請求編號, 查詢的格子總數
local component = require("component")
local event = require("event")

local sdquery = {}

-- 延遲載入主程式(直接讀取其參數，不用傳遞)
local function main() return require("touch_menu") end

local MAX_SLOTS = 60
local listener = nil

-- 以物品名稱統計 AE2 網路內的總數量
function sdquery.count_for_label(label)
    local m = main()
    if not m.ae then return nil, "找不到 ME 控制器/介面" end
    local ok, items = pcall(m.ae.getItemsInNetwork, { label = label })
    if not ok or type(items) ~= "table" then
        ok, items = pcall(m.ae.getItemsInNetwork)
        if not ok or type(items) ~= "table" then return nil, "AE2 查詢失敗" end
    end
    local total = 0
    for _, item in ipairs(items) do
        if item.label == label then total = total + (item.size or 0) end
    end
    return total
end

-- 查詢單一 database 格子，回傳 label, count 或 nil, 錯誤訊息
function sdquery.query_slot(slot)
    local m = main()
    if not m.db then return nil, "找不到 database 組件" end
    local ok, stack = pcall(m.db.get, slot)
    if not ok then return nil, "格子編號無效" end
    if not stack or not stack.label then return nil, "database 該格子是空的" end
    local count, err = sdquery.count_for_label(stack.label)
    if not count then return nil, err end
    return stack.label, count
end

local function parse_slots(raw)
    local slots = {}
    if type(raw) == "number" then
        slots[1] = math.floor(raw)
    else
        for n in tostring(raw or ""):gmatch("%d+") do
            if #slots >= MAX_SLOTS then break end
            slots[#slots + 1] = tonumber(n)
        end
    end
    return slots
end

local function reply(modem, via, reply_to, reply_port, ...)
    local m = main()
    if via and via ~= "" then
        modem.send(via, m.relay_port, "FORWARD_CMD", reply_to, reply_port, ...)
    else
        modem.send(reply_to, reply_port, ...)
    end
end

-- 處理一則請求；modem 為收到請求的那張網卡 (用同一張回覆)
function sdquery.process(modem, req_id, reply_to, reply_port, slots_raw, via)
    if not reply_to or not reply_port then return false end
    local slots = parse_slots(slots_raw)
    for _, slot in ipairs(slots) do
        local label, count_or_err = sdquery.query_slot(slot)
        if label then
            reply(modem, via, reply_to, reply_port, "AE_QUERY_REPLY", req_id, slot, true, label, count_or_err)
        else
            reply(modem, via, reply_to, reply_port, "AE_QUERY_REPLY", req_id, slot, false, count_or_err, 0)
        end
    end
    reply(modem, via, reply_to, reply_port, "AE_QUERY_DONE", req_id, #slots)
    return true
end

local function on_modem_message(_, local_addr, _, port, _, msg, req_id, reply_to, reply_port, slots_raw, via)
    local m = main()
    if port ~= m.query_port or msg ~= "AE_QUERY" then return end
    local ok, err = pcall(function()
        sdquery.process(component.proxy(local_addr), req_id, reply_to, reply_port, slots_raw, via)
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
