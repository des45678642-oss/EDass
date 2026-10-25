# EDass

OpenComputers touch panel (`touch_menu.lua`) with an AE2 stock monitor, plus the relay computer program (`server.lua`).

## Structure
- `touch_menu.lua` – main program. Holds all parameters (hardware, paths, ports) as fields of its module table; the other modules read them directly via `require("touch_menu")` instead of having them passed in.
- `sdlogic.lua` – config loading (`load_hybrid_config`), database scan / migration, page rendering, restock logic, global clone lock, low-battery jukebox, `count_item`.
- `sdapi.lua` – battery discovery and `getSensorInformation` parsing (page 1).
- `sdjson.lua` – small JSON decoder/encoder (OpenOS has none).
- `sdquery.lua` – answers AE2 count queries sent over the network.
- `server.lua` – relay computer.
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
- AE2 is searched **by `label` only** (`me_interface.getItemsInNetwork`, falls back to `me_controller`), so `label` is the item's identity: a second entry with the same label is flagged as an error. `name` and `damage` are stored for when an item has to be written into a database; they do not take part in any search.
- `mode_tag`
  - `restock` – order `target_once` crafts when stock is below `target_quantity`. `cooldown` seconds between orders (omit → `default_cooldown`).
  - `clone` – global-lock replication machine at `circuit` (1-24), `priority` 1-9 (lower wins, default 9).
  - `monitor` – display only.
- `database` (optional) – address prefix of the database component to use for scanning.
- Bad entries are skipped and shown in red on row 12 of page 2. If the file is temporarily unparsable, the last good config is kept.

### The database is only used to add items
- **At start-up** `touch_menu` (1) converts old entries that only have a `slot` (fills in name/damage/label from the database and removes `slot`), then (2) scans the database and appends every item that is not in the file yet.
- **`🔍 掃描新增物品` button** (page 2) does step (2) immediately. The result is shown on row 13.
- Items whose label is already in the file are skipped (the scan message tells you if their name/damage differ).
- New items are added as `"mode_tag": "monitor"` (display only, nothing is ordered) with `target_quantity` 0; edit the file to turn on restocking.
- Items already in the file are never changed or removed. Before every write the old file is copied to `ae_config.json.bak`, the new file is read back and validated, and the old content is restored if that fails. A file that is not valid JSON is never overwritten.

Log codes written to `ae_log.txt` (`label=tag1=tag2=tag3`): 0 ok, 1 ordered, 2 cooldown, 3 AE refused, 4 no pattern, 5 cloning, 6 queued, **7 AE2 query failed (never treated as 0 stock)**.

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
