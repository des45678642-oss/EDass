# EDass

OpenComputers touch panel (`touch_menu.lua`) with an AE2 stock monitor, plus the relay computer program (`server.lua`).

## Structure
- `touch_menu.lua` – main program. Holds all parameters (hardware, paths, ports) as fields of its module table; the other modules read them directly via `require("touch_menu")` instead of having them passed in.
- `sdlogic.lua` – config loading (`load_hybrid_config`), page rendering, restock logic, global clone lock, low-battery jukebox, `count_item`.
- `sdapi.lua` – clock helpers (network sync, local tick).
- `sdjson.lua` – small JSON decoder (OpenOS has none).
- `sdquery.lua` – answers AE2 count queries sent over the network.
- `server.lua` – relay computer.
- `convert_config.py` – one-off converter from the old `ae_config.txt`.

## Config: `/mnt/4c8/ae_config.json`
```json
{
  "database": "9ee0",
  "items": [
    {"slot": 1,  "mode_tag": "restock", "target_quantity": 20000, "target_once": 150, "cooldown": 600},
    {"slot": 64, "mode_tag": "clone",   "target_quantity": 10000, "circuit": 1, "priority": 3},
    {"slot": 46, "mode_tag": "monitor"}
  ]
}
```
- `slot` – database slot. `name`, `damage` and `label` are filled in at load time with `database.get(slot)`; stock is then read with `me_interface.getItemsInNetwork({label = label})` (falls back to `me_controller`), counting only results whose `name`/`damage` also match.
- `mode_tag`
  - `restock` – order `target_once` crafts when stock is below `target_quantity`. `cooldown` seconds between orders (omit → `default_cooldown`).
  - `clone` – global-lock replication machine at `circuit` (1-24), `priority` 1-9 (lower wins, default 9).
  - `monitor` – display only.
- `database` (optional) – address prefix of the database component to use.
- Bad entries are skipped and shown in red on row 12 of page 2. If the file is temporarily unparsable, the last good config is kept.
- Convert an old file: `python convert_config.py ae_config.txt ae_config.json`.

Log codes written to `ae_log.txt` (`label=tag1=tag2=tag3`): 0 ok, 1 ordered, 2 cooldown, 3 AE refused, 4 no pattern, 5 cloning, 6 queued, **7 AE2 query failed (never treated as 0 stock)**.

## Page 2 paging
When the config has more items than fit on screen (35 rows), the `◀ 上一頁` / `下一頁 ▶` buttons next to the tabs switch pages. All items are still checked and restocked every cycle; only the display is paged.

## AE2 query protocol (port `query_port`, default 102)
Only items that already exist in a **database** slot can be queried; queries are by database slot number.

Request (send to the touch_menu computer, directly or through `server.lua`):

    "AE_QUERY", request_id, reply_to_uuid, reply_port, "1,2,64" [, relay_uuid]

Via the relay, send to `server.lua` on port 100:

    "FORWARD_CMD", touch_menu_uuid, 102, "AE_QUERY", request_id, reply_to_uuid, reply_port, "1,2,64", relay_uuid

If `relay_uuid` is given, replies are sent back through the relay's `FORWARD_CMD` (port 100); otherwise directly to `reply_to_uuid:reply_port`.

Replies (one per slot, then a terminator):

    "AE_QUERY_REPLY", request_id, slot, ok(boolean), label_or_error, count
    "AE_QUERY_DONE",  request_id, number_of_slots

At most 60 slots per request.

## Tests
Needs Python with `lupa` (`pip install lupa`):

    python run_tests.py .
