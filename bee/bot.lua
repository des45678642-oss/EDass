--管理机器人的物品栏与位置
---@diagnostic disable: inject-field, undefined-field, assign-type-mismatch, duplicate-set-field, need-check-nil
local component = require("component")
local computer = require("computer")
local robot = require("robot")
local event = require("event")

local analyzeGenes = require("analyzeGenes")

local inventory_controller = component.inventory_controller
local upgrade_me = component.upgrade_me
local database = component.database

local M = {}
local inventorySize = robot.inventorySize()
if inventorySize < 32 then
    error("物品栏升级过少")
end

--监听inventory_changed事件，维护物品栏映射表
--事件处理函数只负责登记“哪一格变了”，真正的分析（会用到数据库升级与 os.sleep）在处理函数之外进行：
--1. 避免在事件处理函数里再嵌套 os.sleep/event.pull，造成事件重入；
--2. 机器人移动期间不做分析，移动结束后再统一刷新。
M.inventory, M.inventoryLabel = {}, nil
local pendingSlots, pendingOrder, processing, busy = {}, {}, false, 0

local function logError(msg)
    local f = io.open("/home/bot_error.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. tostring(msg) .. "\n") f:close() end
end

local function analyzeSlot(slot)
    local stack = inventory_controller.getStackInInternalSlot(slot)
    if stack then
        local success, result = xpcall(analyzeGenes, debug.traceback, stack)
        if success then
            M.inventory[slot] = result
        else
            M.inventory[slot] = stack
            M.inventory[slot].type = "others"
            --记录分析失败的原因，否则蜜蜂会静悄悄变成 others，之后在别处报出莫名其妙的错误
            M.inventory[slot].analyzeError = result
            if stack.name == "Forestry:beeDroneGE" or stack.name == "Forestry:beePrincessGE" then
                logError("第" .. slot .. "格蜜蜂分析失败: " .. tostring(result))
                print("警告：第" .. slot .. "格蜜蜂分析失败（详情见 /home/bot_error.log）")
            end
        end
        M.inventory[slot].inventoryLabel = M.inventoryLabel
    else
        M.inventory[slot] = nil
    end
end

--取得物品后，等事件更新映射表可能来不及；这里直接读取该格并同步刷新，最多等约1秒
function M.refreshSlot(slot)
    for _ = 1, 20 do
        if M.inventory[slot] then return true end
        if robot.count(slot) > 0 then
            local ok, err = pcall(analyzeSlot, slot)
            if not ok then logError("刷新物品栏第" .. slot .. "格失败: " .. tostring(err)) end
            if M.inventory[slot] then return true end
        end
        os.sleep(0.05)
    end
    return M.inventory[slot] ~= nil
end

function M.flushInventory()
    if processing or busy > 0 then return end
    processing = true
    while #pendingOrder > 0 do
        local slot = table.remove(pendingOrder, 1)
        pendingSlots[slot] = nil
        local ok, err = pcall(analyzeSlot, slot)
        if not ok then logError("更新物品栏第" .. slot .. "格失败: " .. tostring(err)) end
    end
    processing = false
end

function M.updateInventory(_, slot)
    if not pendingSlots[slot] then
        pendingSlots[slot] = true
        pendingOrder[#pendingOrder + 1] = slot
    end
    if busy == 0 and not processing then
        M.flushInventory()
    end
    return true
end
event.listen("inventory_changed", M.updateInventory)

local function beginBusy() busy = busy + 1 end
local function endBusy()
    busy = busy - 1
    if busy == 0 then M.flushInventory() end
end

--robot库物品栏操作函数重定向
local t, e = robot.transferTo, inventory_controller.equip
function M.equip()
    local previousLabel = M.inventoryLabel
    M.inventoryLabel = M.inventory[0] and M.inventory[0].inventoryLabel
    M.inventory[0] = M.inventory[robot.select()]
    e()
    os.sleep(0)
    M.inventoryLabel = previousLabel
end
function M.transfer(previousSlot, targetSlot)
    if not M.inventory[previousSlot]then
        return false
    end
    local previousSlotLabel, targetSlotLabel = M.inventory[previousSlot] and M.inventory[previousSlot].inventoryLabel, M.inventory[targetSlot] and M.inventory[targetSlot].inventoryLabel
    robot.select(previousSlot)
    local result = t(targetSlot)
    os.sleep(0.1)
    if M.inventory[targetSlot] then
        M.inventory[targetSlot].inventoryLabel = previousSlotLabel
    end
    if M.inventory[previousSlot] then
        M.inventory[previousSlot].inventoryLabel = targetSlotLabel
    end
    return result
end
robot.transferTo, inventory_controller.equip = M.transfer, M.equip
local inventoryChangerList = {
    {robot, "drop"}, {robot, "dropDown"}, {robot, "dropUp"}, {robot, "suck"}, {robot, "suckDown"}, {robot, "suckUp"},
    {inventory_controller, "dropIntoSlot"}, {inventory_controller, "suckFromSlot"}, {upgrade_me, "requestItems"}
}
for _, pack in pairs(inventoryChangerList) do--对于可能改变物品栏的函数，在结束后执行一个sleep(0.01)等待异步操作更新物品栏映射表
    local lib, funcName = pack[1], pack[2]
    local previousFunc = lib[funcName]
    lib[funcName] = function(...)
        local result = previousFunc(...)
        os.sleep(0.01)
        return result
    end
end

--robot库移动函数重定向
local position,direction = {x=0,y=1,z=0},{x=0,z=-1}
local f, b, u, d, l, r = robot.forward, robot.back, robot.up, robot.down, robot.turnLeft, robot.turnRight
function M.up()
    beginBusy()
    while not u() do
        os.sleep(0)
    end
    position.y = position.y + 1
    endBusy()
end
function M.down()
    beginBusy()
    while not d() do
        os.sleep(0)
    end
    position.y = position.y - 1
    endBusy()
end
function M.forward()
    beginBusy()
    while not f() do
        os.sleep(0)
    end
    position.x=position.x+direction.x
    position.z=position.z+direction.z
    endBusy()
end
function M.back()
    beginBusy()
    while not b() do
        os.sleep(0)
    end
    position.x = position.x - direction.x
    position.z = position.z - direction.z
    endBusy()
end
robot.forward, robot.back, robot.up, robot.down = M.forward, M.back, M.up, M.down
function M.turnLeft()
    l()
    direction.x, direction.z = -direction.z, direction.x
end
function M.turnRight()
    r()
    direction.x, direction.z = direction.z, -direction.x
end
robot.turnLeft, robot.turnRight = M.turnLeft, M.turnRight
function M.turnTo(targetX, targetZ)
    if math.abs(targetX) + math.abs(targetZ) ~= 1 or targetX * targetZ ~= 0 then
        error("错误的调用bot.turnTo()")
    end
	if direction.x ~= targetX or direction.z ~= targetZ then
		if (direction.x ~= 0 and direction.x+targetX == 0) or (direction.z ~= 0 and direction.z + targetZ == 0) then
			M.turnRight() M.turnRight()
		elseif direction.x == targetZ and direction.z + targetX == 0 then
			M.turnLeft()
		elseif direction.z == targetX and direction.x + targetZ == 0 then
			M.turnRight()
		end
	end
end
function M.moveXZTo(targetX, targetZ)
    local movedX = false
    local function moveX()
        if position.x > targetX then
            M.turnTo(-1,0)
            for i=1,position.x-targetX do
                M.forward()
            end
        elseif position.x < targetX then
            M.turnTo(1,0)
            for i=1,targetX-position.x do
                M.forward()
            end
        end
        movedX = true
    end
    if direction.x * (targetX - position.x) > 0 or direction.z * (targetZ - position.z) < 0 then
        moveX()
    end
	if position.z > targetZ then
		M.turnTo(0,-1)
		for i=1,position.z- targetZ do
            M.forward()
        end
	elseif position.z < targetZ then
		M.turnTo(0,1)
		for i=1, targetZ -position.z do
            M.forward()
        end
	end
    if not movedX then
        moveX()
    end
end
function M.moveYTo(targetY)
    if targetY > position.y then
        for i=1,targetY-position.y do
            M.up()
        end
    elseif targetY < position.y then
        for i=1,position.y-targetY do
            M.down()
        end
    end
end

--充电
function M.charge()
    local previousPosition = {x=position.x, y=position.y, z=position.z}
    local previousDirection = {x=direction.x, z=direction.z}
    if computer.energy() < 5000 then
        M.moveYTo(2)
        M.moveXZTo(0,0)
        M.moveYTo(1)
        local targetEnergy = computer.maxEnergy() - 100
        while computer.energy() < targetEnergy do
            os.sleep(0.5)
        end
        M.moveYTo(2)
        M.moveXZTo(previousPosition.x, previousPosition.z)
        M.moveYTo(previousPosition.y)
        M.turnTo(previousDirection.x, previousDirection.z)
    end
    return true
end
event.timer(120, M.charge, math.huge)

--物品栏管理函数
function M.getEmptySlotCount()
    local count = 0
    for i=1,inventorySize do
        if not M.inventory[i] then
            count = count + 1
        end
    end
    return count
end
function M.selectEmptySlot()
    for i=1,inventorySize do
        if not M.inventory[i] and robot.count(i) == 0 then
            return robot.select(i)
        end
    end
    return nil
end
function M.selectUsedSlot()
    for i=1,inventorySize do
        if M.inventory[i] and robot.count(i) > 0 then
            return robot.select(i)
        end
    end
    return nil
end
function M.getItemsWithLabel(inventoryLabel)
    local result = {}
    for i=1,inventorySize do
        if M.inventory[i] and M.inventory[i].inventoryLabel == inventoryLabel then
            table.insert(result, i)
        end
    end
    return result
end
function M.clearItem(inventoryLabel)
    for i=1,inventorySize do
        if M.inventory[i] and M.inventory[i].inventoryLabel == inventoryLabel then
            if M.inventory[i].type == "beePrincess" or M.inventory[i].type == "beeDrone" then
                robot.select(i)
                robot.dropUp()
            else
                robot.select(i)
                upgrade_me.sendItems()
            end
        end
    end
end
function M.checkItem(filter, request)
    if not filter or not filter.name then
        error("错误的调用bot.checkItem()")
    end
    --[神秘小补丁
    if filter.tag then
        if filter.name == "Forestry:beeDroneGE" or filter.name == "Forestry:beePrincessGE" then
            local speciesGenes = analyzeGenes({name=filter.name,tag=filter.tag,individual={}}).species
            database.set(1, filter.name, 0, '{IsAnalyzed:1b,Genome:{Chromosomes:[0:{Slot:0b,UID0:"'..speciesGenes[1]..'",UID1:"'..speciesGenes[2]..'"}]}}')
            local label = database.get(1).label
            return M.checkItemByTag({tag=filter.tag,label=label}, request)
        else
            error("错误的调用bot.checkItem()：不支持tag查询的物品")
        end
    end
    --]]
    local function isEqual(stack, _filter)
        if (_filter.name and stack.name ~= _filter.name) or (_filter.damage and stack.damage ~= _filter.damage) or (_filter.tag and stack.tag ~= _filter.tag) then
            return false
        end
        return true
    end
    if request then
        request = type(request) == "number" and request or 1
    else
        request = 0
    end
    local slotList, count = {}, 0
    for slot,item in pairs(M.inventory) do
        if slot ~= 0 and isEqual(item, filter) then
            table.insert(slotList, slot)
            count = count + robot.count(slot)
        end
    end
    local targetSlot
    for _, slot in pairs(slotList) do
        if targetSlot then
            if not isEqual(M.inventory[targetSlot], M.inventory[slot]) then
                error("错误的调用bot.checkItem()")
            end
            M.transfer(slot, targetSlot)
        else
            targetSlot = slot
            request = math.min(request, M.inventory[slot].maxSize or 64)
        end
    end
    if targetSlot and robot.count(targetSlot) >= request then
        return targetSlot
    end
    local stackList = upgrade_me.getItemsInNetwork(filter)
    if not stackList then
        error("超出ME网络范围")
    elseif not stackList[1] then
        return nil
    elseif request == 0 then
        return true
    end
    if targetSlot then
        robot.select(targetSlot)
    else
        targetSlot = M.selectEmptySlot()
        if not targetSlot then
            error("物品栏已满")
        end
        request = math.min(request, stackList[1].maxSize)
    end
    database.clear(1)
    upgrade_me.store(filter, database.address, 1)
    local stack = database.get(1)
    if M.inventory[targetSlot] and not isEqual(M.inventory[targetSlot], stack) then
        error("错误的调用bot.checkItem()")
    end
    if stack then
        upgrade_me.requestItems(database.address, 1, request - count)
        if M.refreshSlot(targetSlot) then
            return targetSlot
        end
    end
    return nil
end
function M.checkItemByTag(filter, request)
    if not filter or not filter.tag or not filter.label then
        error("错误的调用bot.checkItemByTag()")
    end
    if request then
        request = type(request) == "number" and request or 1
    else
        request = 0
    end
    local slotList, count = {}, 0
    for slot, item in pairs(M.inventory) do
        if slot ~= 0 and item.label == filter.label and item.tag == filter.tag then
            table.insert(slotList, slot)
            count = count + robot.count(slot)
        end
    end
    local targetSlot
    for _, slot in pairs(slotList) do
        if targetSlot then
            if M.inventory[targetSlot].tag ~= M.inventory[slot].tag then
                error("错误的调用bot.checkItemByTag()")
            end
            M.transfer(slot, targetSlot)
        else
            targetSlot = slot
            request = math.min(request, M.inventory[slot].maxSize or 64)
        end
    end
    if targetSlot and robot.count(targetSlot) >= request then
        return targetSlot
    end
    local i = 1
    while database.clear(i) do
        i = i + 1
    end
    local stackList = upgrade_me.getItemsInNetwork({label=filter.label})
    local dbIdx
    for i = 1, math.min(#stackList, 81) do
        if stackList[i].tag == filter.tag then
            dbIdx = i
            break
        end
    end
    if not dbIdx then
        return nil
    elseif request == 0 then
        return true
    end
    if targetSlot then
        robot.select(targetSlot)
    else
        targetSlot = M.selectEmptySlot()
        if not targetSlot then
            error("物品栏已满")
        end
        request = math.min(request, stackList[dbIdx].maxSize)
    end
    upgrade_me.store({label=filter.label}, database.address, 1)
    local stack = database.get(dbIdx)
    if stack and stack.tag == filter.tag then
        upgrade_me.requestItems(database.address, dbIdx, request - count)
        if M.refreshSlot(targetSlot) then
            return targetSlot
        end
    end
    return nil
end


local crafterArea = {[1]=true,[2]=true,[3]=true,[5]=true,[6]=true,[7]=true,[9]=true,[10]=true,[11]=true}
function M.clearCrafterArea()
    if M.getEmptySlotCount() < 9 then
        return false
    end
    for slot,_ in pairs(crafterArea) do
        if M.inventory[slot] then
            for i=1,inventorySize do
                if not crafterArea[i] and not M.inventory[i] then
                    M.transfer(slot, i)
                    os.sleep(0)
                end
            end
        end
    end
    return true
end

--初始化物品栏映射表
for i=1,inventorySize do
    M.updateInventory(nil, i)
end
M.equip()
M.equip()

return M

--[[
inventoryName
简易蜂房/蜂箱"tile.for.apiculture"
诱变机"tile.gendustry.mutatron"
基因压印机"tile.gendustry.imprinter"
基因采样机"tile.gendustry.sampler"
基因转换机"tile.gendustry.transposer"
基因复制机"tile.gendustry.replicator"
]]