-- 驗證「無 individual 時，只靠 NBT 能不能判斷始祖種」
-- 用法：把要測的蜜蜂放進資料庫升級的第 8 格（可改 slot），執行 nbt_natural_test
-- 先測一隻始祖種，再測一隻培育出來的蜜蜂，把兩次的輸出貼給我
local component = require("component")
local database = component.database
local analyzeGenes = require("analyzeGenes") -- 載入您寫好的 analyzeGenes 模組
local robot = require("robot")
local inventory_controller = component.inventory_controller
local slot = 1
local stack = inventory_controller.getStackInInternalSlot(slot)
if not stack or not stack.tag then
    print("槽位 " .. slot .. " 是空的或沒有 NBT")
    return
end
local lines = {}
local function log(s) print(s) lines[#lines + 1] = s end
log("槽位 " .. slot .. " : " .. tostring(stack.label))
log("原始      : " .. analyzeGenes.debug(stack))
local saved = stack.individual
stack.individual = nil
log("無individual: " .. analyzeGenes.debug(stack))
log("NBT判斷始祖種 = " .. tostring(analyzeGenes.isNatural(stack)))
log("individual 原本的 isNatural = " .. tostring(saved and saved.isNatural))
local f = io.open("natural_test.txt", "a")
if f then f:write(table.concat(lines, "\n") .. "\n\n") f:close() print("已追加寫入 natural_test.txt") end
