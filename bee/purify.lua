--纯化程序：把放进机器人物品栏的蜜蜂提纯成目标品种的样板基因 (与 bee.lua 的 optimizeSpecies 相同，但蜜蜂来自物品栏而不是 ME 网络)
--用法：把要纯化的雄蜂 (公主蜂可选，没有就使用 ME 内的始祖种公主蜂) 放进物品栏，运行 purify，回答品种 (直接回车则选雄蜂最多的品种)
_G.package.loaded.config = nil

local boot = require("boot")
local beeUtil = require("beeUtil")

local bot, beeData, strategy, device, robot, upgrade_me

local function sendBeesToME()
    for _, slot in ipairs(beeUtil.sortedSlots(bot.inventory)) do
        local bee = bot.inventory[slot]
        if bee.type == "beeDrone" or bee.type == "beePrincess" then
            robot.select(slot)
            upgrade_me.sendItems()
        end
    end
end

local function main()
    print("加载中...")
    require("mutations")
    device = require("device")
    strategy = require("strategy")
    bot = require("bot")
    beeData = require("beeData")
    robot = require("robot")
    upgrade_me = require("component").upgrade_me

    if not beeData.initialized then
        error("尚未完成初始化，请先运行 bee 完成初始化后再使用纯化程序")
    end
    print("请把要纯化的雄蜂（以及可选的公主蜂）放进机器人物品栏")
    io.write("要纯化的品种UID（例如 forestry.speciesCommon，直接回车=自动选择雄蜂最多的品种）：")
    local wanted = io.read()
    if wanted ~= nil then wanted = wanted:match("^%s*(.-)%s*$") end

    local species, princessSlot, droneSlot = beeUtil.pickPurifyInputs(bot.inventory, wanted)
    if not species then
        error(princessSlot)
    end
    print("纯化品种：" .. species)
    local targetGenes = beeData.getTargetGenes(species)

    if not princessSlot then
        print("物品栏内没有公主蜂，从ME网络取用始祖种公主蜂")
        princessSlot = bot.checkItem({name = "Forestry:beePrincessGE", tag = beeData.getPrincessTag(true)}, 1)
        if not princessSlot then
            error("缺少公主蜂")
        end
    end
    local assistantDroneSlot = strategy.getAssistantDrones()
    local pureDrone, pureProcess = strategy.purify(princessSlot, droneSlot, targetGenes, assistantDroneSlot, ":purifyInput")
    if not pureDrone then
        error("纯化过程中发生基因丢失，请放入更多该品种的雄蜂后重试")
    end
    print("纯化完成，正在把蜜蜂送回ME网络")
    sendBeesToME()
    device.destruct()
    return pureProcess
end

local suc, err = pcall(boot.checkHardware)
if suc then
    suc, err = pcall(main)
    if not suc then
        print("发生错误: " .. tostring(err))
        local ok, d = pcall(require, "device")
        if ok then d.destruct() end
    end
else
    print("发生错误: " .. tostring(err))
end
