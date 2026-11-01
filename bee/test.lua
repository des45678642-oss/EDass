-- 🌟 引入機器人的記憶體大腦與 OC 內建序列化解碼庫
local bot = require("bot")
local serialization = require("serialization")
local io = require("io")

print("🔍 [記憶體解碼器啟動] 正在將 32 格蜜蜂 Table 數據翻譯為可讀純文字...")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

for slot = 1, 16 do
    local item = bot.inventory[slot]
    
    -- 判定是否為公主蜂或雄蜂的 Table 物件
    if item and (item.type == "beePrincess" or item.type == "beeDrone" or item.species) then
        print(string.format("🎒 [背包第 %02d 格] 蜜蜂實體: %s (%s)", slot, tostring(item.label or "未知蜜蜂"), tostring(item.type or "others")))
        print("------------------------------------------------------------")
        
        -- 🌟 【核心解碼步驟】：將記憶體中的 Table 物件轉換為人類可讀的排版文字
        -- 🌟 第二個參數傳入 true，可以開啟自動縮進排版（Pretty Print），讓結構變無比精美
        local decodedText = serialization.serialize(item, true)
        
        -- 直接將解碼後的完好文字打印在螢幕上！
        print(decodedText)

        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    end
end

print("🏁 32格 Table 結構全部解碼翻譯完畢！")
