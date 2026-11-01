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

「樣板」指 `strategy.initialize` 內 `templateGenes[1..3]`；每一項基因都要符合，包含採蜜對象與特殊效果。

## 除了品種，其餘基因都對著樣板雄蜂提純
只有 `species` 以配種目標為準；其他基因（含採蜜對象 `flowerProvider`、特殊效果 `effect`）在 `strategy.purify` 裡一律改成樣板雄蜂的基因來強制提純：

- `beeData.getTargetGenes` 回傳的目標帶有 `followAssistant = true`，`purify` 看到後把除 `species`、`speed` 以外的目標基因換成樣板雄蜂的基因，`effect` 一律是 `forestry.effectNone`。
- 這樣拿到品種對、但採蜜對象或特殊效果與查詢（database 虛構蜜蜂）不一致的蜜蜂時，不會因為「找不到目標基因」報錯，而是被提純成樣板基因。
- `speed` 保留原本的規則（品種自帶速度與樣板速度取高者），沒有跟著樣板；如果要連速度也跟樣板，改 `strategy.lua` 裡 `chromosome ~= "speed"` 那一行。
- 初始化階段（`beeData.initialized == false`）的目標是明確寫死的樣板基因，沒有 `followAssistant`，行為不變。
- 以 database 虛構蜜蜂做查詢排序的 `beeData.getDroneTag` 仍不看採蜜對象（那是找蜜蜂的查詢，不是提純）。
- 樣板雄蜂本身需要帶 `forestry.effectNone`，否則 `purify` 會報目標基因不存在。

## 沒有適合的蜂箱
不再只報錯，會顯示公主蜂需要的環境、突變的額外要求，以及目前配置的蜂箱，例如：

```
没有适合的蜂箱：公主蜂需要 温度 寒冷，湿度 一般；突变额外要求 温度 炙热。当前配置的蜂箱：#1 温度 一般 湿度 一般
```

## 純化程式 `purify.lua`
1. 把要純化的雄蜂（公主蜂可選）放進機器人物品欄。
2. 執行 `purify`，輸入品種 UID（直接回車 = 選雄蜂最多的品種）。
3. 目標基因取自 `beeData.getTargetGenes(species)`，需要先完成初始化；沒有放公主蜂時使用 ME 內的始祖種公主蜂。
4. 純化後把蜜蜂送回 ME 網路（採蜜對象與特殊效果也已對著樣板雄蜂提純）。

## 測試
```
python run_bee_tests.py bee
```
用 Python 的 `lupa`（Lua 5.3）加上模擬的 OC 元件。涵蓋 base64/JSON 往返、`data.json` 讀寫與損毀檔案處理、舊 `data.txt` 轉換、基因比對、無蜂箱訊息、對著樣板雄蜂提純（簡化的繁殖模擬）。**沒有**在遊戲內跑過：`purify` 整套演算法、ME 與機器人操作都需要實機驗證。
