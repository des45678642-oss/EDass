local component = require("component")
--local serialization = require("serialization")
_G.package.loaded.config = nil

local strategy, mutations, device

local function initialize()
    require("boot").checkHardware()
    print("加载中...")
    mutations = require("mutations")
    device = require("device")
    strategy = require("strategy")
end

local function main()
    print("请输入需要培育的蜜蜂:")
    local species = io.read()
    if mutations[species] then
        strategy.task(species)
    else
        error("未发现突变路径")
    end
end

local suc, err = pcall(initialize)
if suc then
    suc, err = pcall(main)
    if not suc then
        print("发生错误: " .. err)
        device.destruct()
    end
else
    print("发生错误: " .. err)
end
