# EDass

OpenComputers touch panel (`touch_menu.lua`) with an AE2 stock monitor, plus the relay computer program (`server.lua`).

## Structure
- `touch_menu.lua` – main program. Holds all parameters (hardware, paths, ports) as fields of its module table; the other modules read them directly via `require("touch_menu")` instead of having them passed in.
- `sdlogic.lua` – config loading (`load_hybrid_config`), database scan / migration, page rendering, restock logic, global clone lock, low-battery jukebox, `count_item`.
- `sdapi.lua` – battery discovery and `getSensorInformation` parsing (page 1).
- `sdjson.lua` – small JSON decoder/encoder (OpenOS has none).
- `sdquery.lua` – answers AE2 count queries sent over the network.
- `sdminer.lua` – miner scheduling (the logic of `space_main.lua`, running inside `touch_menu`).
- `server.lua` – relay computer.
- `space_miner.lua` – runs on each miner computer (unchanged). `space_main.lua` / `space_recipe.lua` – the original standalone master and its test recipes, kept for reference; no longer needed once `touch_menu` has a transposer.
- `convert_config.py` – one-off converter from the very old `ae_config.txt`.

## Config: `/mnt/4c8/ae_config.json`
```json
{
  "database": "9ee0",
  "items": [
    {"name": "minecraft:iron_ingot", "damage": 0, "label": "Iron Ingot", "mode_tag": "restock", "target_quantity": 20000, "target_once": 150, "cooldown": 600},
    {"name": "mod:thing", "damage": 3, "label": "Thing", "mode_tag": "clone", "target_quantity": 10000, "circuit": 1, "priority": 3},
    {"name": "mod:other", "damage": 0, "label": "Other", "mode_tag": "monitor"}
  ]
}
```
- AE2 is searched **by `label` only** (`getItemsInNetwork` on `fluid_interface` first, then `me_interface`, then `me_controller` — GTNH 2.9 broke the item query on the old components), so `label` is the item's identity: a second entry with the same label is flagged as an error. `name` and `damage` are stored for when an item has to be written into a database; they do not take part in any search.
- `mode_tag`
  - `restock` – order `target_once` crafts when stock is below `target_quantity`. `cooldown` seconds between orders (omit → `default_cooldown`).
  - `clone` – global-lock replication machine at `circuit` (1-24), `priority` 1-9 (lower wins, default 9).
  - `monitor` – display only.
  - `miner` – see below.
- `database` (optional) – address prefix of the database component to use for scanning.
- Bad entries are skipped and shown in red on row 12 of page 2. If the file is temporarily unparsable, the last good config is kept.

### The database is only used to add items
- **At start-up** `touch_menu` (1) converts old entries that only have a `slot` (fills in name/damage/label from the database and removes `slot`), then (2) scans the database and appends every item that is not in the file yet.
- **`🔍 掃描新增物品` button** (page 2) does step (2) immediately. The result is shown on row 13.
- Items whose label is already in the file are skipped (the scan message tells you if their name/damage differ).
- New items are added as `"mode_tag": "monitor"` (display only, nothing is ordered) with `target_quantity` 0; edit the file to turn on restocking.
- Items already in the file are never changed or removed. Before every write the old file is copied to `ae_config.json.bak`, the new file is read back and validated, and the old content is restored if that fails. A file that is not valid JSON is never overwritten.

Log codes written to `ae_log.txt` (`label=tag1=tag2=tag3`): 0 ok, 1 ordered, 2 cooldown, 3 AE refused, 4 no pattern, 5 cloning, 6 queued, **7 AE2 query failed (never treated as 0 stock)**.

## Miner mode (`mode_tag: "miner"`)
`touch_menu` takes over the job of `space_main.lua`: for every `miner` item whose AE2 stock is below `target_quantity` it assigns miner computers (`space_miner.lua`, port 300) and hands each one a mining drone from the shared ender chest. The computer running `touch_menu` therefore needs a **modem** and a **transposer next to the shared ender chest** (`miner_chest_side`, default 1 — same as `space_main.lua`).

```json
{"name": "mod:ore", "damage": 0, "label": "Some Ore", "mode_tag": "miner",
 "target_quantity": 10000, "min_miner_tier": 1, "min_drone_tier": 3, "max_drone_tier": 5,
 "distance": 91, "weight": 5, "limit": 1}
```
Fields are the ones from `space_recipe.lua` (`target_amount` is now `target_quantity`): `min_miner_tier` (default 1), `min_drone_tier` (0) / `max_drone_tier` (99), `distance` (required), `weight` (1), `limit` (0 or 1).

How it works (same as `space_main`): stage 1 – items below target get `ceil(shortage ratio × weight)` miners, using the highest drone inside the level range, never a drone outside it. Stage 2 – miners that are still idle are spread randomly over satisfied items with `limit: 1`, and here the highest-level drone in the chest may be used as a fallback. When every miner is busy or the chest has no drones left, the scheduler waits `miner_cooldown` (300 s), recalls everything (`PULL_BACK`) and starts over; the page-2 button `⛏ 重新分配礦機` does that immediately (the old "press Enter"). Page 2 row 9 shows miners / busy / phase / drones left, and each miner row shows `開採中 a/n台`, `缺無人機`, `缺礦機`, `常駐` or `等待調度`. Log codes 8 (mining, tag2 = miners) and 9 (waiting, tag2 = miners needed).

Differences from `space_main.lua` (all intentional):
1. Runs inside `touch_menu` without blocking (messages are queued, 4 per second); stock comes from AE2 by label instead of the mock database; recipes come from `ae_config.json`.
2. The original read `cfg.min_drone` / `cfg.max_drone`, but the recipe fields are called `min_drone_tier` / `max_drone_tier`, so the level range was never applied (any drone was accepted). The range is now respected.
3. Miners that registered during the cooldown were lost (the code used an undefined `ev_event`, hidden by `pcall`). Registration is now handled at all times.
4. A miner that is already known and registers again (e.g. after a reboot) now gets `REG_SUCCESS` again; before it stayed stuck in its registration loop.
5. The "no drones left" check looped over the iterator object instead of the `getAll()` result, so it always saw an empty chest and the cooldown started after every pass. It now reads the chest properly, and a cycle is limited to `miner_cooldown` seconds so the periodic refresh still happens.
6. Miners already mining an item count towards the number it needs; before, every pass added another `needed` miners.
7. Drones are reserved while a pass is planned and the chest is not read again until the commands have been delivered (+`miner_settle` seconds); before, a stack could be handed out more often than it had drones.
8. Items are served by biggest shortage ratio first (before: arbitrary order).
9. The modem strength is 16 only while sending to miners and is restored afterwards (the clone machine broadcast needs 400 on the same card).

Not changed: miners are never removed from the roster when they go offline (there is no heartbeat in the protocol). The AE2 restock/clone logic still only runs while page 2 is shown; the miner scheduling runs on every page.

## Fluids (GTNH 2.9)
A fluid in the database is a `NotEnoughItems:neiFluidDisplay` stack whose `fluid` field holds `{amount, id, label, name}`. Scanning stores it as a normal `monitor` entry, keyed by the **fluid's label**, plus the registry name:

```json
{"name": "NotEnoughItems:neiFluidDisplay", "damage": 0, "label": "UU-Matter", "fluid": "ic2uumatter", "mode_tag": "monitor", "target_quantity": 0}
```

Fluid entries are counted in mB with one `getFluidsInNetwork()` call per refresh (summed by registry name, falling back to the label), whatever `query_mode` is. They support `monitor` only; `restock`/`clone`/`miner` on a fluid is reported as a config error. Remote queries (`AE_QUERY`) work for fluids too, with the label as the key. Needs a `fluid_interface` component; with only `me_interface` the entry shows `?` and the page-2 error line explains why.

## Page 1: batteries
Shows every `gt_machine` on the network whose `getName()` contains `multimachine.supercapacitor`: address, stored EU, total capacity, percentage and a bar, plus the combined total. The numbers come from `getSensorInformation()` and are parsed tolerantly: `EU Stored` and `Total Capacity` as separate lines or as `stored / total` on one line, thousands separators, colour codes and scientific notation (`1.5E10`); if only `Used Capacity: xx%` is available just the percentage is shown. Colours follow `high_energy_threshold` / `low_energy_threshold` (green / yellow / red).
The machine search calls `getName()` on every `gt_machine`, so it is cached (`battery_rescan_interval`, 60 s) and forced again whenever you switch to the page.
The jukebox alarm still watches the single battery at `battery_address` (`20b2`) and is unchanged.

## Speed
- Config: the parsed JSON and the validated items are cached; the file is not touched at all for `config_check_interval` seconds (10), then only `lastModified` is checked. Scans/conversions reload immediately.
- Drawing: only rows whose text or colour changed are sent to the GPU, and the log file is only rewritten when its content changed.
- AE2 stock: `query_mode` = `filter` (one `getItemsInNetwork({label})` per item), `full` (one call for the whole network) or `auto` (default: `full` when there are more than `query_full_threshold` = 8 items). Every component call costs at least one game tick, so with many items `full` is normally much faster.
- Row 10 of page 2 shows the last refresh time split into config / AE2 / other, and the query mode, so you can see what is slow on your world.

## Page 2 paging
When the config has more items than fit on screen (35 rows), the `◀ 上一頁` / `下一頁 ▶` buttons next to the tabs switch pages. All items are still checked and restocked every cycle; only the display is paged.

## AE2 query protocol (port `query_port`, default 102)
Items must be registered in `ae_config.json` first (put them in the database and scan). Queries accept **labels only**.

OpenComputers allows at most 8 values per network message, so the content is one JSON string.

Request, sent directly to the touch_menu computer:

    "AE_QUERY", '{"id":"r1","reply_to":"<uuid>","reply_port":777,"keys":["Iron Ingot","Thing"],"via":"<relay uuid, optional>"}'

Through the relay, send to `server.lua` on port 100:

    "FORWARD_CMD", <touch_menu uuid>, 102, "AE_QUERY", '{...same JSON...}'

If `via` is given, replies are sent back through that computer's `FORWARD_CMD` (port 100); otherwise directly to `reply_to:reply_port`.

Replies (one per key, then a terminator):

    "AE_QUERY_REPLY", '{"id":"r1","key":"Iron Ingot","ok":true,"count":123}'
    "AE_QUERY_REPLY", '{"id":"r1","key":"Nope","ok":false,"error":"..."}'
    "AE_QUERY_DONE",  '{"id":"r1","n":2}'

At most 60 keys per request.

## Tests
Needs Python with `lupa` (`pip install lupa`):

    python run_tests.py .
