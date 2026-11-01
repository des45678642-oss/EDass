local M = {}

function M.getTemperatureLevel(temperature, biomeTypes)
    for _, biomeType in ipairs(biomeTypes) do
        if biomeType == "nether" then
            return 3 --地狱
        end
    end
    if temperature <= 0 then
        return -2 --严寒
    elseif temperature < 0.35 then
        return -1 --寒冷
    elseif temperature < 0.85 then
        return 0 --一般
    elseif temperature <= 1 then
        return 1 --温暖
    else
        return 2 --炙热
    end
end

function M.getHumidityLevel(rainfall)
    if rainfall <= 0.2 then
        return -1 --干旱
    elseif rainfall <= 0.8 then
        return 0 --一般
    else
        return 1 --潮湿
    end
end

function M.getTemperatureRange(temperatureGene, toleranceGene)
    if not temperatureGene or not toleranceGene then
        return nil
    end
    local temperatureUpperLimit, temperatureLowerLimit = temperatureGene, temperatureGene
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "UP_" then
        temperatureUpperLimit = temperatureUpperLimit + tonumber(toleranceGene:sub(-1))
    end
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "DOW" then
        temperatureLowerLimit = temperatureLowerLimit - tonumber(toleranceGene:sub(-1))
    end
    return math.max(temperatureLowerLimit, -2), math.min(temperatureUpperLimit, 3)
end

function M.getHumidityRange(humidityGene, toleranceGene)
    if not humidityGene or not toleranceGene then
        return nil
    end
    local humidityUpperLimit, humidityLowerLimit = humidityGene, humidityGene
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "UP_" then
        humidityUpperLimit = humidityUpperLimit + tonumber(toleranceGene:sub(-1))
    end
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "DOW" then
        humidityLowerLimit = humidityLowerLimit - tonumber(toleranceGene:sub(-1))
    end
    return math.max(humidityLowerLimit, -1), math.min(humidityUpperLimit, 1)
end

local temperatureNames = { [-2] = "严寒", [-1] = "寒冷", [0] = "一般", [1] = "温暖", [2] = "炙热", [3] = "地狱" }
local humidityNames = { [-1] = "干旱", [0] = "一般", [1] = "潮湿" }

function M.temperatureName(level)
    return level and temperatureNames[level] or "未知"
end

function M.humidityName(level)
    return level and humidityNames[level] or "未知"
end

local function rangeText(low, high, nameFunc)
    if low == nil or high == nil then return "未知" end
    if low == high then return nameFunc(low) end
    return nameFunc(low) .. "~" .. nameFunc(high)
end

--公主蜂需要的蜂箱环境，例如 "温度 一般~温暖，湿度 一般"
function M.describeNeed(temperatureGene, temperatureTolerance, humidityGene, humidityTolerance)
    local tLow, tHigh = M.getTemperatureRange(temperatureGene, temperatureTolerance)
    local hLow, hHigh = M.getHumidityRange(humidityGene, humidityTolerance)
    return "温度 " .. rangeText(tLow, tHigh, M.temperatureName) .. "，湿度 " .. rangeText(hLow, hHigh, M.humidityName)
end

--突变额外要求的环境 (mutations.lua 里的 temperature/humidity/biome/biomeType，数字或 {下限,上限})
function M.describeMutationNeed(mutation)
    if type(mutation) ~= "table" then return nil end
    local parts = {}
    local function range(value, nameFunc)
        if type(value) == "table" then return rangeText(value[1], value[2], nameFunc) end
        return nameFunc(value)
    end
    if mutation.temperature then parts[#parts + 1] = "温度 " .. range(mutation.temperature, M.temperatureName) end
    if mutation.humidity then parts[#parts + 1] = "湿度 " .. range(mutation.humidity, M.humidityName) end
    if mutation.biome then parts[#parts + 1] = "生物群系 " .. tostring(mutation.biome) end
    if mutation.biomeType then parts[#parts + 1] = "群系类型 " .. tostring(mutation.biomeType) end
    if #parts == 0 then return nil end
    return table.concat(parts, "，")
end

return M
