# bee/ — 蜜蜂機器人

入口：`bee.lua`（培育指定品種）、`purify.lua`（純化放進物品欄的蜜蜂）。

## data.txt → data.json
`beeData.lua` 現在把記錄存成 `data.json`：

```json
{
  "initialized": true,
  "speedLevel": 8,
  "assistantDroneTag": "H4sIAAAAAAAA...",
  "assistantPrincessTag": "H4sIAAAAAAAA...",
  "usingPrincessTag": "H4sIAAAAAAAA..."
}
```

- 三個 `*Tag` 是 gzip 壓縮的二進位 NBT，JSON 放不下原始位元組，所以存檔時轉 base64，讀檔時還原成**一模一樣的位元組**。`bot.lua` 的 `checkItem` / `checkItemByTag` 用 `stack.tag ~= filter.tag` 比對，所以 `bot.lua` 不需要改，轉換只發生在 `beeData`/`beeStore` 這一層。
- 寫檔先寫 `data.json.tmp`、讀回驗證，再換掉正式檔。
- 找不到 `data.json` 時，若 `data.txt` 讀得出來就自動轉成 `data.json`；兩者都沒有才建立新檔。
- `data.json` 存在但壞掉時**直接報錯**，不會當成全新資料覆蓋（否則輔助蜜蜂紀錄會全部遺失並重新初始化）。
- `json.lua` 與根目錄的 `sdjson.lua` 相同，`beeStore.lua` 負責 base64 與讀寫。

## 初始化時放入已培育完成的蜜蜂
`strategy.initialize()` 一開始會停下來讓你放蜜蜂（沒有就直接按回車）。物品欄內的**純合雄蜂**會被辨識並跳過對應步驟：

| 放入 | 效果 |
|---|---|
| 田野蜂 | 直接完成初始化（設為樣板雄蜂） |
| 寻常蜂 + 石頭樣板蜂 | 直接培育田野蜂 |
| 石頭樣板蜂 + 凛冬樣板蜂（含石頭性狀） | 直接培育寻常蜂 |
| 單獨一種樣板蜂 | 跳過它對應的提純步驟 |

「樣板」指 `strategy.initialize` 內 `templateGenes[1..3]`；比對時不看採蜜對象與特殊效果。

## 比對時忽略採蜜對象與特殊效果
database 虛構出來的蜜蜂只能指定品種，採蜜對象（`flowerProvider`）與特殊效果（`effect`）是品種預設值，和實際蜜蜂對不起來。現在所有比對（`strategy`、`beeData` 的基因表，`getDroneTag` 評分，`isTemplatedGenes`）都**不含這兩項**（`beeUtil.IGNORED`）。

輸出前一定會洗成無效果：`purify` 在目標 `effect` 為 `forestry.effectNone` 時，若公主蜂或雄蜂有任一個效果基因不是 `forestry.effectNone`，會再針對 `effect` 單獨提純一次（`純化` 的第 6 個參數 `chromosomes`）。公主蜂、雄蜂、樣板雄蜂都沒有 `effectNone` 基因時會明確報錯。

注意：`breedDrones` 仍然要求**全部**基因純合（含採蜜對象與效果），否則後代會分裂成多種基因型；採蜜對象目前靠樣板蜂遺傳，沒有被強制提純。

## 沒有適合的蜂箱
不再只報錯，會顯示公主蜂需要的環境、突變的額外要求，以及目前配置的蜂箱，例如：

```
没有适合的蜂箱：公主蜂需要 温度 寒冷，湿度 一般；突变额外要求 温度 炙热。当前配置的蜂箱：#1 温度 一般 湿度 一般
```

## 純化程式 `purify.lua`
1. 把要純化的雄蜂（公主蜂可選）放進機器人物品欄。
2. 執行 `purify`，輸入品種 UID（直接回車 = 選雄蜂最多的品種）。
3. 目標基因取自 `beeData.getTargetGenes(species)`，需要先完成初始化；沒有放公主蜂時使用 ME 內的始祖種公主蜂。
4. 純化後（含洗去特殊效果）把蜜蜂送回 ME 網路。

## 測試
```
python run_bee_tests.py bee
```
用 Python 的 `lupa`（Lua 5.3）加上模擬的 OC 元件。涵蓋 base64/JSON 往返、`data.json` 讀寫與損毀檔案處理、舊 `data.txt` 轉換、基因比對、無蜂箱訊息、洗特殊效果（模擬繁殖）。**沒有**在遊戲內跑過：`purify` 整套演算法、ME 與機器人操作都需要實機驗證。
