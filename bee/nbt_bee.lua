local component = require("component")
local database = component.database
local analyzeGenes = require("analyzeGenes") -- 載入您寫好的 analyzeGenes 模組

-- 1. 自訂一個格式化對照表，讓輸出的數值變成看得懂的中文
local readable = {
    lifespan = { "早夭", "較短壽", "短壽", "不足寿", "一般", "足壽", "長壽", "較長壽", "最長壽", "永生" },
    speed = { "最慢", "較慢", "慢速", "一般", "快速", "較快", "最快", "急速" },
    flowering = { "最慢", "較慢", "慢速", "平均", "快速", "較快", "最快", "最大速度" },
    fertility = function(v) return v .. "x" end,
    territory = { "平均(9x6x9)", "大(11x8x11)", "較大(13x12x13)", "最大(15x13x15)" },
    temperature = { [-2]="嚴寒", [-1]="寒冷", [0]="一般", [1]="溫暖", [2]="炙熱", [3]="地獄" },
    humidity = { [-1]="乾旱", [0]="一般", [1]="潮濕" },
    bool = function(v) return v and "是" or "否" end
}

-- 2. 獲取資料庫中的物品（請確保槽位與您的實際環境一致，這裡設定為 8 號槽位）
local slot = 8
local itemStack = database.get(slot)

if not itemStack or not itemStack.tag then
    print("【錯誤】槽位 " .. slot .. " 是空的，或者該物品不包含 NBT (.tag) 數據！")
    return
end

-- 3. 補全建構 analyzeBee 所需的 individual 基礎結構
itemStack.individual = itemStack.individual or {}
itemStack.individual.isNatural = itemStack.individual.isNatural or false
itemStack.individual.generation = itemStack.individual.generation or 0
-- 如果遊戲內 API 沒有回傳 ident，預設嘗試用原本的 NBT 或預設顯性（可根據實際狀況調整）
itemStack.individual.ident = itemStack.individual.ident or nil 

print("正在分析蜜蜂基因...")
local success, res = pcall(analyzeGenes, itemStack)

if not success then
    print("【分析失敗】原因: " .. tostring(res))
    return
end

-- 4. 建立要輸出的文字內容
local output = {}
local function log(text)
    print(text)
    table.insert(output, text)
end

log("=================== 蜜蜂基因自動分析報告 ===================")
log(string.format("物品名稱: %s (%s)", res.label or "未知", res.name))
log(string.format("世代類型: %s (第 %d 代)", res.isNatural and "始祖種" or "人工培育", res.generation))
log(string.format("蜜蜂類型: %s", res.type == "beePrincess" and "公主蜂 👑" or "雄蜂 ♂"))
log("------------------------------------------------------------")

-- 輔助函式：用來漂亮列印 主/副 基因
local function printGene(title, resPair, map)
    local activeVal, inactiveVal = resPair[1], resPair[2]
    local activeStr, inactiveStr
    
    if type(map) == "function" then
        activeStr = map(activeVal)
        inactiveStr = map(inactiveVal)
    elseif type(map) == "table" then
        activeStr = map[activeVal] or tostring(activeVal)
        inactiveStr = map[inactiveVal] or tostring(inactiveVal)
    else
        activeStr = tostring(activeVal)
        inactiveStr = tostring(inactiveVal)
    end
    
    log(string.format("  %-12s : 【主】%-12s  |  【副】%-12s", title, activeStr, inactiveStr))
end

-- 5. 開始輸出各項基因
printGene("種族 (Species)", res.species)
printGene("壽命 (Lifespan)", res.lifespan, readable.lifespan)
printGene("工作速度 (Speed)", res.speed, readable.speed)
printGene("授粉速度 (Flower)", res.flowering, readable.flowering)
printGene("生育能力 (Fertility)", res.fertility, readable.fertility)
printGene("活動範圍 (Territory)", res.territory, readable.territory)
printGene("最適溫度 (Temp)", res.temperature, readable.temperature)
printGene("溫度適應 (TempTol)", res.temperatureTolerance)
printGene("最適濕度 (Humid)", res.humidity, readable.humidity)
printGene("濕度適應 (HumidTol)", res.humidityTolerance)
printGene("夜行性 (Nocturnal)", res.nocturnal, readable.bool)
printGene("耐雨飛行 (Flyer)", res.tolerantFlyer, readable.bool)
printGene("穴居性 (Cave)", res.caveDwelling, readable.bool)
printGene("採蜜對象 (Provider)", res.flowerProvider)
printGene("特殊效果 (Effect)", res.effect)
log("============================================================")

-- 6. 同步保存至 bee_result.txt
local f = io.open("bee_result.txt", "w")
if f then
    f:write(table.concat(output, "\n"))
    f:close()
    print("【系統提示】完整分析結果已成功保存至 bee_result.txt")
else
    print("【警告】無法寫入 bee_result.txt 檔案。")
end
