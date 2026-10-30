local comp = require("component")
local event = require("event")
local shell = require("shell")
local modem_addr = nil
for addr in comp.list("modem") do modem_addr = addr break end
local tp_addr = nil
for addr in comp.list("transposer") do tp_addr = addr break end
if not modem_addr or not tp_addr then
    print("❌ 核心硬體缺失：本機未安裝網絡卡(Modem)或未連線轉運器(Transposer)！")
    return
end
local modem = comp.proxy(modem_addr)
local tp = comp.proxy(tp_addr)
local PORT = 300 
local gt_name = "unknown_gt_device"
local side_input_bus = nil
local side_ender_chest = nil
local processed_packets = {}
local PACKET_TIMEOUT = 2
local function initHardware()
    local gt_addr = nil
    for addr in comp.list("gt_machine") do gt_addr = addr break end
    if gt_addr then
        local g_machine = comp.proxy(gt_addr)
        local success, name = pcall(g_machine.getName)
        if success and name then gt_name = tostring(name) end
    end
    for side = 0, 5 do
        local success, invName = pcall(tp.getInventoryName, side)
        if success and invName and invName ~= "" then
            if invName:sub(1, 3) == "gt." then
                side_input_bus = side
            elseif invName:find("enderchest") or invName:find("ender_chest") then side_ender_chest = side end
        end
    end
end
initHardware()
shell.execute("cls")
print("--------------------------------------------------")
print("  -> 機器名稱 : " .. gt_name)
print("--------------------------------------------------")
local registered = false
modem.open(PORT)
modem.setStrength(16)
print("正在註冊 (Port " .. PORT .. ")...")
while not registered do
    modem.broadcast(PORT, "MINER_REGISTER", gt_name)
    local raw_event = { event.pull(2, "modem_message") }
    if raw_event[1] then
        local port = raw_event[4]
        local cmd = raw_event[6]
        if port == PORT and cmd == "REG_SUCCESS" then
            registered = true
			print("註冊完成")
        end
    end
end
local function findAvailableRecycleSlot()
    if not side_ender_chest then return nil end
    for slot = 19, 27 do
        local stack = tp.getStackInSlot(side_ender_chest, slot)
        if not stack or (stack.size < (stack.maxSize or 64)) then
            return slot
        end
    end
    return nil
end
local function emergencyClearSlot1()
    local stack = tp.getStackInSlot(side_input_bus, 1)
    if stack and stack.size > 0 then
        local recycle_slot = findAvailableRecycleSlot()
        if recycle_slot then
            local success, moved = pcall(tp.transferItem, side_input_bus, side_ender_chest, stack.size, 1, recycle_slot)
            if success and moved and moved > 0 then
                os.sleep(0.05) 
                return true
            end
        end
    end
    return false
end
while true do
    local raw_event = { event.pull("modem_message") }
    local remoteAddr = raw_event[3]
    local port       = raw_event[4]
    local cmd  = raw_event[6] 
    local arg1 = raw_event[7] 
    local arg2 = raw_event[8] 
    local arg3 = raw_event[9]
    if port == PORT then
        local packet_fingerprint = string.format("%s_%s_%s", tostring(cmd), tostring(arg1), tostring(arg2))
        local now = os.time()
        for sig, ts in pairs(processed_packets) do
            if os.difftime(now, ts) > PACKET_TIMEOUT then processed_packets[sig] = nil end
        end
        if not processed_packets[packet_fingerprint] then
            processed_packets[packet_fingerprint] = now
            print(string.format("[指令] 代碼: %s | 來自: [%s...]", tostring(cmd), tostring(remoteAddr:sub(1,8))))
            if cmd == "PUSH_MATERIAL" then
                local ender_slot = tonumber(arg1)
                local count      = tonumber(arg2)
                if side_input_bus and side_ender_chest and ender_slot and count then
                    print(string.format("執行投料：終界箱[%d] 數量: %d", ender_slot, count))
                    local success, moved = pcall(tp.transferItem, side_ender_chest, side_input_bus, count, ender_slot, 1)
                    if success or (moved or 0) == 1 then print(string.format("成功，已送入 %d 個物品。", moved)) end
                end
            elseif cmd == "PULL_BACK" then
                print("物品回收...")
                if side_input_bus and side_ender_chest then
                    local loop_safety = 0
                    local total_moved = 0
                    while loop_safety < 30 do
                        local stack = tp.getStackInSlot(side_input_bus, 1)
                        if stack and stack.size > 0 then
                            local target_recycle_slot = findAvailableRecycleSlot()
                            if not target_recycle_slot then print("[回收中斷] 終界箱回收區(19~27)已完全塞滿！") break end
                            local success, moved = pcall(tp.transferItem, side_input_bus, side_ender_chest, stack.size, 1, target_recycle_slot)
                            if success and moved and moved > 0 then
                                total_moved = total_moved + moved
                                os.sleep(0.05) 
                            else break end
                        else break end
                        loop_safety = loop_safety + 1
                    end
                    print(string.format("回收完成。本次累計回收耗材總數: %d 個。", total_moved))
                end
            elseif cmd == "SET_MACHINE" then
                local hatch = tonumber(arg1)
                local id    = tonumber(arg2)
                local value = tonumber(arg3)
                local current_gt_addr = nil
                for addr in comp.list("gt_machine") do current_gt_addr = addr break end
                if current_gt_addr and hatch and id and value then
                    print(string.format("執行調整參數：setParameters(hatch:%d, id:%d, value:%d)", hatch, id, value))
                    local success, err = pcall(comp.invoke, current_gt_addr, "setParameters", hatch, id, value)
                    if success then print("成功！") else print("失敗原因: " .. tostring(err)) end
                end
            elseif cmd == "REG_RESET" then modem.broadcast(PORT, "MINER_REGISTER", gt_name) end
        end
    end
end