--不依賴任何 OC 組件的蜜蜂判斷函式 (方便在電腦上單獨測試)
local M = {}

M.EFFECT_NONE = "forestry.effectNone"

M.ALL_CHROMOSOMES = { "species", "speed", "lifespan", "fertility", "flowering", "flowerProvider", "territory", "effect",
    "temperatureTolerance", "humidityTolerance", "nocturnal", "tolerantFlyer", "caveDwelling" }

--database 虛構蜜蜂只能指定品種，其採蜜對象與特殊效果是品種預設值，和實際蜜蜂對不起來，所以比對時一律忽略
M.IGNORED = { flowerProvider = true, effect = true }

--回傳不含被忽略基因的基因表 (每次回傳新表)
function M.compareChromosomes()
    local list = {}
    for _, chromosome in ipairs(M.ALL_CHROMOSOMES) do
        if not M.IGNORED[chromosome] then list[#list + 1] = chromosome end
    end
    return list
end

local COMPARE = M.compareChromosomes()

--升序的槽位清單 (inventory 是以槽位為鍵的稀疏表，pairs 的順序不固定)
function M.sortedSlots(inventory)
    local slots = {}
    for slot in pairs(inventory) do
        if type(slot) == "number" and slot > 0 then slots[#slots + 1] = slot end
    end
    table.sort(slots)
    return slots
end

--所有參與比對的基因是否都為純合
function M.isHomozygous(bee)
    for _, chromosome in ipairs(COMPARE) do
        local gene = bee[chromosome]
        if not gene or gene[1] ~= gene[2] then return false end
    end
    return true
end

--蜜蜂是否符合樣板基因表 (純合且等於樣板；樣板裡的 flowerProvider / effect 不比)
function M.matchesTemplate(bee, genes)
    for chromosome, wanted in pairs(genes) do
        if not M.IGNORED[chromosome] then
            local gene = bee[chromosome]
            if not gene or gene[1] ~= wanted or gene[2] ~= wanted then return false end
        end
    end
    return true
end

function M.effectIsNone(bee)
    return bee.effect ~= nil and bee.effect[1] == M.EFFECT_NONE and bee.effect[2] == M.EFFECT_NONE
end

--輸出前是否需要把特殊效果洗成無效果：公主蜂或雄蜂有任何一個效果基因不是 effectNone
function M.needsEffectWash(...)
    for _, bee in ipairs({ ... }) do
        if not M.effectIsNone(bee) then return true end
    end
    return false
end

--初始化時，把玩家放進物品欄的「已培育完成」雄蜂分類。
--templates: { [1]=凜冬樣板, [2]=石頭樣板, [3]=凜冬(含石頭性狀)樣板 } (strategy.initialize 的 templateGenes)
--回傳 { template1=槽位, template2=槽位, template3=槽位, common=槽位, cultivated=槽位 }，沒有的鍵為 nil
function M.classifyAdopted(inventory, templates)
    local found = {}
    local function put(kind, slot)
        if not found[kind] then found[kind] = slot end
    end
    for _, slot in ipairs(M.sortedSlots(inventory)) do
        local bee = inventory[slot]
        if bee.type == "beeDrone" and bee.species then
            local species = bee.species[1]
            if bee.species[2] == species and M.isHomozygous(bee) then
                if species == "forestry.speciesCultivated" then
                    put("cultivated", slot)
                elseif species == "forestry.speciesCommon" then
                    put("common", slot)
                end
            end
            for i = 1, 3 do
                if templates[i] and M.matchesTemplate(bee, templates[i]) then put("template" .. i, slot) end
            end
        end
    end
    return found
end

--純化程式用：從物品欄挑出要純化的品種、公主蜂與雄蜂。
--wanted_species 為 nil 時，取雄蜂數量最多的品種。回傳 品種, 公主蜂槽位(可為 nil), 雄蜂槽位；失敗回傳 nil, 訊息
function M.pickPurifyInputs(inventory, wanted_species)
    local slots = M.sortedSlots(inventory)
    local counts = {}
    for _, slot in ipairs(slots) do
        local bee = inventory[slot]
        if bee.type == "beeDrone" and bee.species then
            for i = 1, 2 do
                counts[bee.species[i]] = (counts[bee.species[i]] or 0) + (bee.size or 1)
            end
        end
    end
    local species = wanted_species
    if not species or species == "" then
        local best = 0
        for _, slot in ipairs(slots) do
            local bee = inventory[slot]
            if bee.type == "beeDrone" and bee.species and counts[bee.species[1]] > best then
                best, species = counts[bee.species[1]], bee.species[1]
            end
        end
    end
    if not species then return nil, "物品欄內沒有雄蜂" end

    local function carries(bee)
        return bee.species and (bee.species[1] == species or bee.species[2] == species)
    end
    local function purity(bee)
        local n = 0
        for _, chromosome in ipairs(COMPARE) do
            if bee[chromosome] and bee[chromosome][1] == bee[chromosome][2] then n = n + 1 end
        end
        return n
    end
    local droneSlot, princessSlot
    for _, slot in ipairs(slots) do
        local bee = inventory[slot]
        if bee.type == "beeDrone" and carries(bee) then
            local d = droneSlot and inventory[droneSlot]
            --優先挑純合度高的，再挑數量多的
            if not d or purity(bee) > purity(d) or (purity(bee) == purity(d) and (bee.size or 1) > (d.size or 1)) then
                droneSlot = slot
            end
        elseif bee.type == "beePrincess" then
            if not princessSlot or (carries(bee) and not carries(inventory[princessSlot])) then
                princessSlot = slot
            end
        end
    end
    if not droneSlot then return nil, "物品欄內沒有攜帶 " .. species .. " 的雄蜂" end
    return species, princessSlot, droneSlot
end

return M
