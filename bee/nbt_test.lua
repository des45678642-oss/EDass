-- 引入必備模組 (請確保您的環境有 zzlib.lua 與 lib/nbt.lua)
local zzlib = require("zzlib")
local nbt = require("lib/nbt")
local component = require("component")

-- 獲取 1 號面、2 號槽位的物品數據
local itemStack = component.database.get(8)

-- ==================== 分頁列印控制中心 ====================
local lineCount = 0
local MAX_LINES = 30

local function smartPrint(text)
    print(text)
    lineCount = lineCount + 1
    
    -- 當行數達到 30 行時暫停
    if lineCount >= MAX_LINES then
        io.write("\n-- 已顯示 " .. MAX_LINES .. " 行，請按 [Enter] 鍵繼續下一頁 --")
        io.read() -- 等待使用者按任意鍵
        lineCount = 0 -- 重設計數器
    end
end
-- ==========================================================

-- ==================== NBT 結構文字產生器 ====================
-- 此函數專門用來將遞迴結構轉成文字，以便寫入 log.txt 檔案
local function buildNBTLogString(tagData, indent)
    indent = indent or ""
    if type(tagData) ~= "table" then return "" end
    
    local parts = {}
    
    if tagData._type == nbt.TAGS.COMPOUND then
        table.insert(parts, indent .. "{ (COMPOUND)\n")
        for k, v in pairs(tagData.value) do
            table.insert(parts, indent .. "  [" .. k .. "] =>\n")
            table.insert(parts, buildNBTLogString(v, indent .. "    "))
        end
        table.insert(parts, indent .. "}\n")
    elseif tagData._type == nbt.TAGS.LIST then
        table.insert(parts, indent .. "[ (LIST, 類型: " .. tostring(tagData._itemID) .. ")\n")
        for i, v in ipairs(tagData.value) do
            table.insert(parts, indent .. "  [" .. i .. "] =>\n")
            table.insert(parts, buildNBTLogString(v, indent .. "    "))
        end
        table.insert(parts, indent .. "]\n")
    else
        table.insert(parts, indent .. tostring(tagData.value) .. " (類型 ID: " .. tostring(tagData._type) .. ")\n")
    end
    
    return table.concat(parts)
end
-- ==========================================================

smartPrint("============ 開始 NBT 解壓縮與解碼測試 ============")

if itemStack and itemStack.tag then
    local rawTag = itemStack.tag
    smartPrint("1. 成功提取原始 Tag 字節，長度為: " .. #rawTag)
    
    -- 2. 第一步：使用 zzlib 進行 Gzip 解壓縮
    local gzipSuccess, uncompressedTag = pcall(zzlib.gunzip, rawTag)
    
    if not gzipSuccess then
        smartPrint("【失敗】Gzip 解壓縮失敗。錯誤原因: " .. tostring(uncompressedTag))
        smartPrint("提示：請確認該物品的 tag 是否真的為壓縮格式，或 zzlib 模組是否完整。")
    else
        smartPrint("2. Gzip 解壓縮成功！解壓後長度為: " .. #uncompressedTag)
        
        -- 3. 第二步：使用您的 nbt 模組解碼解壓後的二進位流
        local nbtSuccess, rootName, rootData = pcall(nbt.decode, uncompressedTag)
        
        if nbtSuccess then
            smartPrint("3. NBT 解碼成功！根節點名稱: " .. (type(rootName) == "table" and rootName.value or tostring(rootName)))
            smartPrint("--------------------------------------------------")
            
            -- 【關鍵新增步驟】在顯示之前，先生成並寫入完整 log.txt
            local logFile = io.open("log.txt", "w")
            if logFile then
                logFile:write("============ NBT 完整結構備份 ============\n")
                logFile:write("根節點名稱: " .. (type(rootName) == "table" and rootName.value or tostring(rootName)) .. "\n\n")
                logFile:write(buildNBTLogString(rootData))
                logFile:write("-------------------------------------------\n")
                logFile:close()
                smartPrint("【系統提示】完整 NBT 結構已成功保存至 log.txt 檔案。")
            else
                smartPrint("【警告】無法寫入 log.txt 檔案。")
            end
            
            smartPrint("準備顯示詳細結構內容...")
            smartPrint("--------------------------------------------------")
            
            -- 遞迴列印函數：用來格式化輸出解析後的 NBT 結構表到螢幕
            local function dumpNBT(tagData, indent)
                indent = indent or ""
                if type(tagData) ~= "table" then return end
                
                if tagData._type == nbt.TAGS.COMPOUND then
                    smartPrint(indent .. "{ (COMPOUND)")
                    for k, v in pairs(tagData.value) do
                        smartPrint(indent .. "  [" .. k .. "] =>")
                        dumpNBT(v, indent .. "    ")
                    end
                    smartPrint(indent .. "}")
                elseif tagData._type == nbt.TAGS.LIST then
                    smartPrint(indent .. "[ (LIST, 類型: " .. tostring(tagData._itemID) .. ")")
                    for i, v in ipairs(tagData.value) do
                        smartPrint(indent .. "  [" .. i .. "] =>")
                        dumpNBT(v, indent .. "    ")
                    end
                    smartPrint(indent .. "]")
                else
                    smartPrint(indent .. tostring(tagData.value) .. " (類型 ID: " .. tostring(tagData._type) .. ")")
                end
            end
            
            -- 執行螢幕結構輸出
            dumpNBT(rootData)
            smartPrint("--------------------------------------------------")
            
        else
            smartPrint("【失敗】NBT 解碼失敗。錯誤原因: " .. tostring(rootName))
        end
    end
else
    smartPrint("提示：該槽位是空的，或者該物品沒有額外的 NBT (.tag) 數據。")
end
