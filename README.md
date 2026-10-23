# EDass

OpenComputers touch panel (`touch_menu.lua`) with an AE2 stock monitor, plus the relay computer program (`server.lua`).

## Structure
- `touch_menu.lua` – main program. Holds all parameters (hardware, paths, ports) as fields of its module table; `sdapi`, `sdlogic` and `sdquery` read them directly via `require("touch_menu")` instead of having them passed in.
- `sdapi.lua` – config parsing and clock helpers.
- `sdlogic.lua` – page rendering, restock logic, global clone lock, low-battery jukebox.
- `sdquery.lua` – answers AE2 count queries sent over the network.
- `server.lua` – relay computer.

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
