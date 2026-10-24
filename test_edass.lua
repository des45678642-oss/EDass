-- Unit tests for EDass (OpenComputers). Run under plain Lua 5.3 with mocked OC APIs.
-- Globals expected from the runner: EDASS_DIR (source dir), TMP_DIR (writable dir).

package.path = EDASS_DIR .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local Main

local function test(name, fn)
    -- each test starts from clean globals/mocks
    _G.current_global_task = nil
    Main = {
        realtime_path = TMP_DIR .. "/realtime.txt",
        config_file_path = TMP_DIR .. "/ae_config.json",
        log_file_path = TMP_DIR .. "/ae_log.txt",
        default_cooldown = 600, SCR_W = 160, SCR_H = 50,
        items_per_page = 35, list_page = 1, list_pages = 1,
        query_port = 102, relay_port = 100, database_slots = 81,
        active_ae_requests = {}, last_order_time = {},
        energy_threshold = 50, high_threshold = 60,
        now = 0, pager_draws = 0,
    }
    Main.get_now_time = function() return Main.now end
    Main.draw_pager = function() Main.pager_draws = Main.pager_draws + 1 end
    package.loaded.touch_menu = Main
    os.remove(Main.config_file_path); os.remove(Main.config_file_path .. ".bak")
    if package.loaded.sdlogic and package.loaded.sdlogic._reset_config_cache then package.loaded.sdlogic._reset_config_cache() end
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS  " .. name)
    else failed = failed + 1; print("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

-- ---------- mocks ----------
local uptime = 1000
local broadcasts = {}
local modem = { broadcast = function(...) broadcasts[#broadcasts + 1] = { ... } end,
                setStrength = function() end }
local avail = { modem = true }
local component_mt = {}
local component = setmetatable({ modem = modem }, component_mt)
-- like OpenOS: indexing a missing primary component throws
component_mt.__index = function(_, k) error("no primary '" .. k .. "' available", 2) end
function component.isAvailable(name) return avail[name] == true end
local listings = {}
function component.list(filter)
    local addrs = {}
    for addr, ctype in pairs(listings) do
        if not filter or ctype == filter then addrs[#addrs + 1] = { addr, ctype } end
    end
    table.sort(addrs, function(a, b) return a[1] < b[1] end)
    local i = 0
    return function() i = i + 1; if addrs[i] then return addrs[i][1], addrs[i][2] end end
end
component.proxy = function(addr) return { address = addr } end
component.invoke = function() end

package.loaded.component = component
package.loaded.computer = { uptime = function() return uptime end }
local mtimes = {}
package.loaded.filesystem = {
    exists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end return false end,
    lastModified = function(p) return mtimes[p] end,
}
package.loaded.internet = { request = function() error("no network in tests") end }
local listeners = {}
package.loaded.event = {
    timer = function(_, cb) return "timer" end, pull = function() end, cancel = function() end,
    listen = function(name, fn) listeners[name] = fn; return true end,
    ignore = function(name, fn) if listeners[name] == fn then listeners[name] = nil end return true end,
}
package.loaded.term = { clear = function() end }
package.loaded.thread = { create = function(fn) return { kill = function() end } end }

local sdapi = require("sdapi")
local sdlogic = require("sdlogic")
local sdjson = require("sdjson")
local sdquery = require("sdquery")

local function write(path, text)
    local f = assert(io.open(path, "w")); f:write(text); f:close()
    mtimes[path] = (mtimes[path] or 0) + 1
end
local function read(path) local f = assert(io.open(path, "r")); local t = f:read("a"); f:close(); return t end
local function cfg(json_text) write(Main.config_file_path, json_text) end

local function make_gpu()
    local g = { sets = {}, calls = {} }
    function g.set(x, y, s) g.sets[#g.sets + 1] = { x = x, y = y, s = s } end
    function g.fill() end
    function g.setForeground() end
    function g.setBackground() end
    function g.setResolution() g.calls[#g.calls + 1] = "setResolution" end
    function g.bind() g.calls[#g.calls + 1] = "bind" end
    return g
end

local function make_db(slots)
    return { get = function(slot) return slots[slot] end }
end

local function row_text(gpu, y)
    for i = #gpu.sets, 1, -1 do if gpu.sets[i].y == y then return gpu.sets[i].s end end
end

-- config item helpers: entries carry name/damage/label (no database needed)
local function key_of(label) return "mod:" .. label .. "@0@" .. label end
local function entry(label, mode, extra)
    local t = { name = "mod:" .. label, damage = 0, label = label, mode_tag = mode }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local function restock(label, target, once, extra)
    local t = entry(label, "restock", { target_quantity = target or 100, target_once = once or 10 })
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local function clone(label, target, circuit, priority)
    return entry(label, "clone", { target_quantity = target, circuit = circuit, priority = priority })
end
local function cfg_items(list) cfg(assert(sdjson.encode({ items = list }))) end

local function make_ctx(over)
    local ctx = Main
    ctx.gpu = make_gpu()
    ctx.ae = {
        getItemsInNetwork = function() return {} end,
        getCraftables = function() return { { request = function() return { isDone = function() return false end, isCanceled = function() return false end } end } } end,
    }
    for k, v in pairs(over or {}) do ctx[k] = v end
    return ctx
end

local function render(ctx, now) ctx.now = now; sdlogic.render_page2() end

-- ========== sdjson: decode ==========
test("json: scalars, nesting, escapes, unicode, BOM", function()
    local v = assert(sdjson.decode('\239\187\191{"a":[1,2.5,-3e2,true,false,null],"s":"x\\n\\"\\u9435\\ud83d\\ude00","o":{}}'))
    eq(v.a[1], 1); eq(v.a[2], 2.5); eq(v.a[3], -300); eq(v.a[4], true); eq(v.a[5], false); eq(v.a[6], sdjson.null)
    eq(v.s, 'x\n"鐵😀'); eq(next(v.o), nil)
end)

test("json: malformed input returns nil + position, never throws", function()
    local bad = { '', '{', '{"a":}', '{"a":1,}', '[1 2]', '{"a":1} x', '"abc', '{"a":01}', '{a:1}', '[1,]', '{"a":"\\q"}', '{"a":"\\ud800"}', 'nul', '"a\nb"' }
    for _, text in ipairs(bad) do
        local v, err = sdjson.decode(text)
        eq(v, nil, "should reject: " .. text)
        truthy(type(err) == "string" and err ~= "", "error message for: " .. text)
    end
    local _, err = sdjson.decode('{\n  "a": ,\n}')
    truthy(err:find("行 2", 1, true), "reports the line: " .. err)
    eq((sdjson.decode(nil)), nil)
end)

test("json: deep nesting is rejected instead of overflowing the stack", function()
    local v, err = sdjson.decode(string.rep("[", 500) .. string.rep("]", 500))
    eq(v, nil); truthy(err)
end)

-- ========== sdjson: encode ==========
test("json encode: round-trips and keeps a stable, readable key order", function()
    local data = { database = "9ee0", note = "x", items = {
        { priority = 3, label = "鐵錠", name = "mod:ingot", damage = 5, mode_tag = "clone", target_quantity = 1.5, circuit = 2 },
        { label = "A\"B\\C\n\t\1", name = "n", damage = 0, mode_tag = "monitor" },
    } }
    local text = assert(sdjson.encode(data))
    local back = assert(sdjson.decode(text))
    eq(back.database, "9ee0"); eq(back.items[1].label, "鐵錠"); eq(back.items[1].target_quantity, 1.5)
    eq(back.items[2].label, "A\"B\\C\n\t\1")
    local a, b, c, d = text:find('"name"', 1, true), text:find('"damage"', 1, true), text:find('"label"', 1, true), text:find('"mode_tag"', 1, true)
    truthy(a < b and b < c and c < d, "name < damage < label < mode_tag")
    truthy(text:find('"database"', 1, true) < text:find('"items"', 1, true))
    local lines = 0; for _ in text:gmatch("\n") do lines = lines + 1 end
    eq(lines, 8, "one line per item plus structure")
    eq(text:sub(-1), "\n")
end)

test("json encode: integers have no .0, null, empty table, compact mode", function()
    eq(assert(sdjson.encode({ a = 2.0, b = 3, c = -0.25, d = sdjson.null, e = {} }, { compact = true })),
       '{"a": 2, "b": 3, "c": -0.25, "d": null, "e": []}')
end)

test("json encode: rejects NaN, cycles, functions, non-string keys (returns nil, err)", function()
    local cyc = {}; cyc.me = cyc
    for _, v in ipairs({ { x = 0 / 0 }, cyc, { f = print }, { [true] = 1, x = 1 } }) do
        local text, err = sdjson.encode(v)
        eq(text, nil); truthy(err)
    end
end)

-- ========== sdlogic: config loading (name/damage/label stored in JSON) ==========
test("config: name/damage/label come straight from the JSON (no database needed)", function()
    Main.db = nil
    cfg_items({ restock("Iron", 100, 10) })
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0); eq(#items, 1)
    local it = items[1]
    eq(it.name, "mod:Iron"); eq(it.damage, 0); eq(it.label, "Iron"); eq(it.key, key_of("Iron"))
    eq(it.target_quantity, 100); eq(it.target_once, 10); eq(it.cooldown, nil); eq(it.mode_tag, "restock")
end)

test("config: clone mode needs circuit; priority defaults to 9", function()
    cfg_items({ clone("Clone A", 500, 2, 1), clone("Clone B", 5, 24, nil) })
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0)
    eq(items[1].circuit, 2); eq(items[1].priority, 1); eq(items[1].target_once, 0)
    eq(items[2].priority, 9)
end)

test("config: bad entries are skipped with an error, good ones still load", function()
    cfg([[{"items":[
        {"name":"a","damage":0,"label":"Good","mode_tag":"monitor"},
        {"name":"a","damage":0,"mode_tag":"monitor"},
        {"damage":0,"label":"NoName","mode_tag":"monitor"},
        {"name":"a","label":"NoDamage","mode_tag":"monitor"},
        {"name":"a","damage":-1,"label":"NegDamage","mode_tag":"monitor"},
        {"name":"a","damage":0,"label":"Bogus","mode_tag":"bogus"},
        {"name":"a","damage":0,"label":"NoTarget","mode_tag":"restock","target_once":1},
        {"name":"a","damage":0,"label":"NegTarget","mode_tag":"restock","target_quantity":-5,"target_once":1},
        {"name":"a","damage":0,"label":"NoOnce","mode_tag":"restock","target_quantity":5},
        {"name":"a","damage":0,"label":"BadCd","mode_tag":"restock","target_quantity":5,"target_once":1,"cooldown":"fast"},
        {"name":"a","damage":0,"label":"NoCircuit","mode_tag":"clone","target_quantity":5},
        {"name":"a","damage":0,"label":"BigCircuit","mode_tag":"clone","target_quantity":5,"circuit":99},
        {"name":"a","damage":0,"label":"BadPrio","mode_tag":"clone","target_quantity":5,"circuit":1,"priority":12},
        7, null,
        {"name":"b","damage":1,"label":"Good2","mode_tag":"monitor"}
    ]}]])
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 2); eq(items[1].label, "Good"); eq(items[2].label, "Good2")
    eq(#errs, 14)
    for _, e in ipairs(errs) do truthy(type(e) == "string" and e ~= "") end
end)

test("config: same label with different name/damage are separate items; exact duplicates are flagged", function()
    cfg([[{"items":[
        {"name":"a:x","damage":0,"label":"Iron","mode_tag":"monitor"},
        {"name":"b:x","damage":0,"label":"Iron","mode_tag":"monitor"},
        {"name":"a:x","damage":1,"label":"Iron","mode_tag":"monitor"},
        {"name":"a:x","damage":0,"label":"Iron","mode_tag":"monitor"}
    ]}]])
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 3); eq(#errs, 1); truthy(errs[1]:find("重複", 1, true))
    truthy(items[1].key ~= items[2].key and items[1].key ~= items[3].key)
end)

test("config: legacy entry with only a slot is reported as 'not migrated yet'", function()
    cfg('{"items":[{"slot":3,"mode_tag":"monitor"}]}')
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 0); eq(#errs, 1); truthy(errs[1]:find("slot 3", 1, true))
end)

test("config: missing file / invalid JSON / wrong shape are reported, not thrown", function()
    Main.config_file_path = TMP_DIR .. "/nope.json"
    local items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); eq(#errs, 1)
    Main.config_file_path = TMP_DIR .. "/ae_config.json"
    cfg('{"items": [ oops ]}')
    items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); truthy(errs[1]:find("JSON", 1, true))
    cfg('[1,2]')
    items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); truthy(errs[1]:find("items", 1, true))
end)

test("config: file that goes bad keeps the last good config (and says so)", function()
    cfg_items({ entry("Iron", "monitor") })
    eq(#sdlogic.load_hybrid_config(), 1)
    cfg('{"items":[{"name":"x",')                    -- half-saved file
    local items2, errs = sdlogic.load_hybrid_config()
    eq(#items2, 1, "last good config kept"); eq(#errs, 1)
end)

test("config: unchanged file is not re-parsed (lastModified cache)", function()
    cfg_items({ entry("Iron", "monitor") })
    eq(#sdlogic.load_hybrid_config(), 1)
    local f = assert(io.open(Main.config_file_path, "w")); f:write('{"items":[]}'); f:close()  -- no mtime bump
    eq(#sdlogic.load_hybrid_config(), 1, "cached")
    cfg('{"items":[]}')
    eq(#sdlogic.load_hybrid_config(), 0, "re-read after mtime change")
end)

test("count_item: filtered query; name+damage guard against label collisions", function()
    local seen
    local ae = { getItemsInNetwork = function(filter) seen = filter; return {
        { label = "Iron", name = "minecraft:iron_ingot", damage = 0, size = 100 },
        { label = "Iron", name = "other:iron_ingot", damage = 0, size = 50 },
        { label = "Iron", name = "minecraft:iron_ingot", damage = 3, size = 7 },
        { label = "Iron", name = "minecraft:iron_ingot", damage = 0, size = 23 },
    } end }
    local n = sdlogic.count_item({ name = "minecraft:iron_ingot", damage = 0, label = "Iron" }, ae)
    eq(n, 123); eq(seen.label, "Iron")
    local nothing, err = sdlogic.count_item({ label = "Iron" }, { getItemsInNetwork = function() error("boom") end })
    eq(nothing, nil); truthy(err)
    eq((sdlogic.count_item({ label = "Iron" }, nil)), nil)
end)

-- ========== database scan / migration ==========
local function stack(name, damage, label) return { name = name, damage = damage, label = label } end
local function db_with(list)
    local slots = {}
    for i, st in pairs(list) do slots[i] = st end
    return make_db(slots)
end

test("scan: adds database items missing from the JSON as monitor entries", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron"), [2] = stack("b:y", 3, "鐵錠"), [9] = stack("c:z", 0, "Gold") })
    cfg_items({ restock("Iron", 100, 10, { name = "a:x" }) })
    local n, added = sdlogic.scan_database()
    eq(n, 2); eq(added[1], "鐵錠"); eq(added[2], "Gold")
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0); eq(#items, 3)
    eq(items[1].mode_tag, "restock", "existing entry untouched"); eq(items[1].target_quantity, 100)
    eq(items[2].name, "b:y"); eq(items[2].damage, 3); eq(items[2].mode_tag, "monitor"); eq(items[2].target_quantity, 0)
end)

test("scan: running it twice adds nothing the second time", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron") })
    cfg('{"items":[]}')
    eq((sdlogic.scan_database()), 1)
    eq((sdlogic.scan_database()), 0)
    eq(#sdlogic.load_hybrid_config(), 1)
end)

test("scan: identity is name+damage+label (a different damage or label is a new item)", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron"), [2] = stack("a:x", 1, "Iron"), [3] = stack("a:x", 0, "Iron Dust") })
    cfg_items({ entry("Iron", "monitor", { name = "a:x" }) })
    eq((sdlogic.scan_database()), 2)
end)

test("scan: duplicates inside the database and unusable stacks are ignored", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron"), [2] = stack("a:x", 0, "Iron"), [3] = { name = "a:x", damage = 0 },
        [4] = { label = "NoName", damage = 0 }, [5] = stack("a:x", nil, "NoDamage") })
    cfg('{"items":[]}')
    local n, added = sdlogic.scan_database()
    eq(n, 2); eq(added[2], "NoDamage")
    eq(#sdlogic.load_hybrid_config(), 2, "damage defaults to 0")
end)

test("scan: other JSON keys are preserved, a .bak of the old file is written", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron") })
    local original = '{"database":"zz","note":"keep me","items":[]}'
    cfg(original)
    eq((sdlogic.scan_database()), 1)
    local back = assert(sdjson.decode(read(Main.config_file_path)))
    eq(back.database, "zz"); eq(back.note, "keep me"); eq(#back.items, 1)
    eq(read(Main.config_file_path .. ".bak"), original)
end)

test("scan: creates the config file when it does not exist yet", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron") })
    eq((sdlogic.scan_database()), 1)
    eq(#sdlogic.load_hybrid_config(), 1)
end)

test("scan: refuses to touch a config file that is not valid JSON", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron") })
    cfg('{"items": [ broken ')
    local n, err = sdlogic.scan_database()
    eq(n, nil); truthy(err)
    eq(read(Main.config_file_path), '{"items": [ broken ', "file must not be overwritten")
end)

test("scan: no database -> error; honours a 'database' address prefix; slot limit", function()
    Main.db = nil
    cfg('{"items":[]}')
    local n, err = sdlogic.scan_database(); eq(n, nil); truthy(err:find("database", 1, true))
    local special = db_with({ [1] = stack("s:s", 0, "FromSpecial"), [4] = stack("s:s", 0, "TooFar") })
    listings = { ["9ee0-db"] = "database" }
    local saved = component.proxy
    component.proxy = function(addr) if addr == "9ee0-db" then return special end return { address = addr } end
    cfg('{"database":"9EE0","items":[]}')
    Main.db = db_with({ [1] = stack("m:m", 0, "FromMain") })
    Main.database_slots = 3
    local count, added = sdlogic.scan_database()
    eq(count, 1); eq(added[1], "FromSpecial")
    component.proxy = saved; listings = {}
end)

test("migrate: legacy slot entries are converted to name/damage/label, slot removed, fields kept", function()
    Main.db = db_with({ [1] = stack("a:x", 2, "Iron") })
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10,"cooldown":300},{"slot":9,"mode_tag":"monitor"}]}')
    local n, err = sdlogic.migrate_legacy_slots()
    eq(n, 1); eq(err, nil)
    local back = assert(sdjson.decode(read(Main.config_file_path)))
    local it = back.items[1]
    eq(it.name, "a:x"); eq(it.damage, 2); eq(it.label, "Iron"); eq(it.slot, nil)
    eq(it.target_quantity, 100); eq(it.target_once, 10); eq(it.cooldown, 300); eq(it.mode_tag, "restock")
    eq(back.items[2].slot, 9, "empty database slot stays legacy (reported by the loader)")
end)

test("migrate: nothing pending is a no-op; no database -> error and file untouched", function()
    Main.db = nil
    cfg_items({ entry("Iron", "monitor") })
    eq((sdlogic.migrate_legacy_slots()), 0)
    local legacy = '{"items":[{"slot":1,"mode_tag":"monitor"}]}'
    cfg(legacy)
    local n, err = sdlogic.migrate_legacy_slots()
    eq(n, 0); truthy(err)
    eq(read(Main.config_file_path), legacy)
end)

test("init_config: migrates, then scans, and returns a one-line message", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron"), [2] = stack("b:y", 0, "Gold") })
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"}]}')
    local msg = sdlogic.init_config()
    truthy(msg:find("轉換 1", 1, true) and msg:find("新增 1", 1, true), msg)
    eq((sdlogic.init_config()), nil, "second run has nothing to report")
    eq(#sdlogic.load_hybrid_config(), 2)
end)

test("the repo's real ae_config.json (slot format) migrates cleanly on first start", function()
    local real = read(EDASS_DIR .. "/ae_config.json")
    local slots = {}
    for i = 1, 81 do slots[i] = stack("mod:item" .. i, i % 3, "Item " .. i) end
    Main.db = make_db(slots)
    cfg(real)
    local before = assert(sdjson.decode(real))
    local msg, had_error = sdlogic.init_config()
    truthy(msg:find("轉換 " .. #before.items, 1, true), msg)
    eq(had_error, false)
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0, tostring(errs[1])); eq(#items, #before.items + 0 + (81 - #before.items))  -- scan adds the other database items
    -- the originally configured items keep their settings and order
    local first = assert(sdjson.decode(read(Main.config_file_path))).items
    for i, old in ipairs(before.items) do
        eq(first[i].label, "Item " .. old.slot); eq(first[i].mode_tag, old.mode_tag)
        eq(first[i].target_quantity, old.target_quantity); eq(first[i].slot, nil)
    end
    for i = #before.items + 1, #first do eq(first[i].mode_tag, "monitor") end
end)

-- ========== sdapi: clock ==========
test("days in month incl. leap years", function()
    eq(sdapi.get_days_in_month(2, 2024), 29); eq(sdapi.get_days_in_month(2, 2100), 28)
    eq(sdapi.get_days_in_month(2, 2000), 29); eq(sdapi.get_days_in_month(12, 2026), 31)
end)

test("clock tick: second/minute/hour rollover", function()
    write(Main.realtime_path, "date=2026-10-24\ntime=23:59:59\ntype=net\n")
    sdapi.local_tick_time(1)
    local t, d = sdapi.read_saved_time()
    eq(t, "00:00:00"); eq(d, "2026-10-25")
end)

test("clock tick: month and year rollover, leap day", function()
    write(Main.realtime_path, "date=2026-12-31\ntime=23:59:59\n")
    sdapi.local_tick_time(1)
    local t, d = sdapi.read_saved_time(); eq(d, "2027-01-01"); eq(t, "00:00:00")
    write(Main.realtime_path, "date=2024-02-28\ntime=23:59:59\n")
    sdapi.local_tick_time(1)
    t, d = sdapi.read_saved_time(); eq(d, "2024-02-29")
end)

test("read_saved_time honours Main.realtime_path", function()
    write(TMP_DIR .. "/other_time.txt", "date=2030-01-02\ntime=03:04:05\n")
    Main.realtime_path = TMP_DIR .. "/other_time.txt"
    local t, d = sdapi.read_saved_time()
    eq(t, "03:04:05"); eq(d, "2030-01-02")
end)

test("read_saved_time fallback placeholders when file missing", function()
    Main.realtime_path = TMP_DIR .. "/does_not_exist.txt"
    local t = sdapi.read_saved_time()
    eq(t, "--:--:--")
end)

test("update_time survives network failure (no throw, file untouched)", function()
    write(Main.realtime_path, "date=2026-01-01\ntime=00:00:00\ntype=calc\n")
    sdapi.update_time()
    truthy(read(Main.realtime_path):find("type=calc", 1, true))
end)

test("update_time parses server HTML (table-style response)", function()
    local chunks = { '<span id="time">12:34:56</span>', '<span id="date">2026-10-24</span>' }
    local i = 0
    package.loaded.internet.request = function()
        return { read = function() i = i + 1; return chunks[i] end }
    end
    write(Main.realtime_path, "")
    sdapi.update_time()
    local t, d = sdapi.read_saved_time()
    eq(t, "12:34:56"); eq(d, "2026-10-24")
    package.loaded.internet.request = function() error("no network in tests") end
end)

test("update_time gives up after the deadline instead of hanging", function()
    package.loaded.internet.request = function()
        return { read = function() uptime = uptime + 3; return "x" end }  -- never ends
    end
    sdapi.update_time()   -- must return
    package.loaded.internet.request = function() error("no network in tests") end
end)

-- ========== sdlogic: text helpers ==========
test("fit pads/truncates by characters, never splits UTF-8", function()
    eq(sdlogic.fit("鐵錠", 5), "鐵錠   ")
    eq(sdlogic.fit("abcdef", 3), "abc")
    eq(sdlogic.fit("鐵錠鋼", 2), "鐵錠")
    eq(sdlogic.usub("鐵錠鋼鎳", 2), "鐵錠")
    eq(utf8.len(sdlogic.usub("鐵錠鋼鎳", 3)), 3)
end)

-- ========== sdlogic: global lock ==========
test("stale lock: holder removed from config -> released + STOP_CLONE", function()
    broadcasts = {}
    _G.current_global_task = key_of("Removed")
    sdlogic.release_stale_lock({ { key = key_of("Clone A"), mode_tag = "clone" } })
    eq(_G.current_global_task, nil); eq(broadcasts[1][2], "STOP_CLONE")
end)

test("stale lock: holder switched to normal restock mode -> released", function()
    _G.current_global_task = key_of("Clone A")
    sdlogic.release_stale_lock({ { key = key_of("Clone A"), mode_tag = "restock" } })
    eq(_G.current_global_task, nil)
end)

test("lock kept while holder is still a clone-mode item", function()
    broadcasts = {}
    _G.current_global_task = key_of("Clone A")
    sdlogic.release_stale_lock({ { key = key_of("Clone A"), mode_tag = "clone" } })
    eq(_G.current_global_task, key_of("Clone A")); eq(#broadcasts, 0)
end)

test("render_page2 with empty config releases a held lock", function()
    cfg('{"items":[]}')
    _G.current_global_task = key_of("Clone A")
    local ctx = make_ctx()
    render(ctx, 10)
    eq(_G.current_global_task, nil)
end)

test("priority pre-emption: lower number wins the lock; satisfied item unlocks", function()
    broadcasts = {}
    cfg_items({ clone("Clone A", 500, 2, 5), clone("Clone B", 500, 3, 1) })
    local ctx = make_ctx()
    render(ctx, 10)
    eq(_G.current_global_task, key_of("Clone B"), "high-priority item should hold the lock")
    ctx.ae.getItemsInNetwork = function() return { { label = "Clone B", size = 500 } } end
    render(ctx, 20)
    render(ctx, 30)
    eq(_G.current_global_task, key_of("Clone A"))
    local saw_stop = false
    for _, b in ipairs(broadcasts) do if b[2] == "STOP_CLONE" then saw_stop = true end end
    truthy(saw_stop, "STOP_CLONE not broadcast")
    local shown
    for _, st in ipairs(ctx.gpu.sets) do if st.y == 16 then shown = st.s end end
    truthy(shown and shown:find("Prio 5", 1, true), "Clone A (row 16) shows it now runs: " .. tostring(shown))
end)

-- ========== sdlogic: restock logic ==========
test("default cooldown (600s) is applied when config leaves it blank", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    ctx.last_order_time[key_of("Iron")] = 100
    render(ctx, 110)  -- 10s after the last order
    local row = row_text(ctx.gpu, 16)
    truthy(row, "row rendered")
    truthy(row:find("590", 1, true), "expected 590s remaining, got: " .. row)
end)

test("restock places an order when cooldown elapsed and stock is low", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    local requested
    ctx.ae.getCraftables = function() return { { request = function(n) requested = n; return { isDone = function() return false end, isCanceled = function() return false end } end } } end
    render(ctx, 5000)
    eq(requested, 10)
    truthy(ctx.active_ae_requests[key_of("Iron")])
    truthy(read(ctx.log_file_path):find("Iron=1=0=0", 1, true))
end)

test("same label, different item: cooldown/orders are tracked separately", function()
    cfg([[{"items":[
        {"name":"a:x","damage":0,"label":"Iron","mode_tag":"restock","target_quantity":100,"target_once":10},
        {"name":"b:x","damage":0,"label":"Iron","mode_tag":"restock","target_quantity":100,"target_once":20}]}]])
    local ctx = make_ctx()
    local requests = {}
    ctx.ae.getCraftables = function() return { { request = function(n) requests[#requests + 1] = n; return { isDone = function() return false end, isCanceled = function() return false end } end } } end
    render(ctx, 5000)
    eq(#requests, 2, "second item must not be blocked by the first one's cooldown")
end)

test("no order when stock >= target_quantity", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 500 } } end
    local called = false
    ctx.ae.getCraftables = function() called = true; return {} end
    render(ctx, 5000)
    eq(called, false)
end)

test("AE query failure is NOT treated as 0 stock (no order, error status, log tag 7)", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() error("ae offline") end
    local ordered = false
    ctx.ae.getCraftables = function() ordered = true; return {} end
    render(ctx, 5000)
    eq(ordered, false)
    truthy(row_text(ctx.gpu, 16):find("AE查詢失敗", 1, true))
    truthy(read(ctx.log_file_path):find("Iron=7=0=0", 1, true))
end)

test("monitor mode never orders and never takes the clone lock", function()
    cfg_items({ entry("Iron", "monitor") })
    local ctx = make_ctx()
    local called = false
    ctx.ae.getCraftables = function() called = true; return {} end
    render(ctx, 5000)
    eq(called, false); eq(_G.current_global_task, nil)
    truthy(read(ctx.log_file_path):find("Iron=0=0=0", 1, true))
end)

test("config errors are shown on row 12 and the valid items still render", function()
    cfg('{"items":[{"name":"a","damage":0,"label":"Iron","mode_tag":"monitor"},{"label":"","mode_tag":"monitor"}]}')
    local ctx = make_ctx()
    render(ctx, 5000)
    local msg
    for _, st in ipairs(ctx.gpu.sets) do if st.y == 12 and st.s:find("label", 1, true) then msg = st.s end end
    truthy(msg, "error line on row 12")
    truthy(row_text(ctx.gpu, 16):find("Iron", 1, true))
end)

test("restock mode only takes the clone path when mode_tag is clone", function()
    cfg_items({ restock("Clone A") })
    local ctx = make_ctx()
    render(ctx, 5000)
    eq(_G.current_global_task, nil)
end)

test("render rows stay on screen (no writes below SCR_H)", function()
    local list = {}
    for i = 1, 60 do list[i] = restock("Item" .. i, 1, 1) end
    cfg_items(list)
    local ctx = make_ctx()
    render(ctx, 5000)
    for _, s in ipairs(ctx.gpu.sets) do truthy(s.y <= 50, "write at row " .. s.y) end
end)

test("rows with CJK names keep fixed column layout", function()
    cfg_items({ restock("Iron"), restock("鐵錠") })
    local ctx = make_ctx()
    ctx.last_order_time[key_of("Iron")] = 5000; ctx.last_order_time[key_of("鐵錠")] = 5000
    render(ctx, 5001)
    local a, b = row_text(ctx.gpu, 16), row_text(ctx.gpu, 17)
    eq(utf8.len(a), utf8.len(b), "rows must have equal character width")
end)

-- ========== sdlogic: battery / jukebox ==========
local function battery(pct)
    return { getSensorInformation = function() return { "Used Capacity: " .. pct .. "%" } end }
end
test("low battery starts jukebox via the bound jukebox; recovery stops it", function()
    _G.is_low_power_alert, _G.jukebox_loop_counter = nil, nil
    local plays, stops = 0, 0
    make_ctx({ battery = battery(30), jukebox = { play = function() plays = plays + 1 end, stop = function() stops = stops + 1 end } })
    sdlogic.check_battery_and_play()
    eq(plays, 1, "plays immediately on alert")
    for _ = 1, 11 do sdlogic.check_battery_and_play() end   -- 55s more: not yet 60
    eq(plays, 1)
    sdlogic.check_battery_and_play()                          -- 60s
    eq(plays, 2)
    Main.battery = battery(65)
    sdlogic.check_battery_and_play()
    eq(stops, 1); eq(_G.is_low_power_alert, false)
end)

test("battery between thresholds keeps previous state (hysteresis)", function()
    _G.is_low_power_alert, _G.jukebox_loop_counter = false, 0
    local plays = 0
    make_ctx({ battery = battery(55), jukebox = { play = function() plays = plays + 1 end, stop = function() end } })
    sdlogic.check_battery_and_play()
    eq(plays, 0)
end)

-- ========== paging (page 2 item list) ==========
local function many_items(n)
    local list = {}
    for i = 1, n do list[i] = restock("Item" .. i, 1, 1) end
    cfg_items(list)
end

test("paging: page 1 shows items 1-35, all items still processed", function()
    many_items(40)
    local ctx = make_ctx()
    render(ctx, 5000)
    eq(ctx.list_pages, 2); eq(ctx.list_page, 1)
    truthy(row_text(ctx.gpu, 16):find("Item1 ", 1, true), "row 16 = item 1")
    truthy(row_text(ctx.gpu, 50):find("Item35", 1, true), "row 50 = item 35")
    for _, s in ipairs(ctx.gpu.sets) do truthy(not s.s:find("Item36", 1, true), "item 36 leaked onto page 1") end
    local n = 0; for _ in read(ctx.log_file_path):gmatch("[^\n]+") do n = n + 1 end
    eq(n, 40, "all 40 items must still be tracked/ordered")
    truthy(ctx.pager_draws >= 1)
end)

test("paging: page 2 shows the remaining items starting at row 16", function()
    many_items(40)
    local ctx = make_ctx()
    ctx.list_page = 2
    render(ctx, 5000)
    truthy(row_text(ctx.gpu, 16):find("Item36", 1, true), "row 16 = item 36")
    truthy(row_text(ctx.gpu, 20):find("Item40", 1, true), "row 20 = item 40")
    truthy(row_text(ctx.gpu, 21) == nil, "no row beyond item 40")
    truthy(row_text(ctx.gpu, 16):find("[36]", 1, true), "index number keeps global numbering")
end)

test("paging: out-of-range page is clamped when the list shrinks", function()
    many_items(10)
    local ctx = make_ctx()
    ctx.list_page = 3
    render(ctx, 5000)
    eq(ctx.list_page, 1); eq(ctx.list_pages, 1)
end)

-- ========== sdquery (remote AE2 queries) ==========
-- OpenComputers allows at most 8 values per network message
local function fake_modem()
    local m = { sent = {} }
    function m.send(...)
        local n = select("#", ...) - 2          -- address and port are not counted
        if n > 8 then error("packet has too many parts (" .. n .. ")") end
        m.sent[#m.sent + 1] = { ... }
    end
    return m
end
local function body(m, i) return assert(sdjson.decode(m.sent[i][4])) end   -- direct replies: {to, port, type, json}

test("query: returns the AE count for a registered label", function()
    cfg_items({ entry("Iron", "monitor"), entry("Gold", "monitor") })
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 100 }, { label = "Iron", size = 23 }, { label = "Gold", size = 9 } } end
    local m = fake_modem()
    truthy(sdquery.process(m, { id = "r1", reply_to = "UUID-X", reply_port = 777, keys = { "Iron", "Gold" } }))
    eq(#m.sent, 3)
    eq(m.sent[1][1], "UUID-X"); eq(m.sent[1][2], 777); eq(m.sent[1][3], "AE_QUERY_REPLY")
    local a = body(m, 1)
    eq(a.id, "r1"); eq(a.key, "Iron"); eq(a.ok, true); eq(a.count, 123); eq(a.name, "mod:Iron"); eq(a.damage, 0)
    eq(body(m, 2).count, 9)
    eq(m.sent[3][3], "AE_QUERY_DONE"); eq(body(m, 3).n, 2)
end)

test("query: unregistered label and AE failure report errors, not crashes", function()
    cfg_items({ entry("Iron", "monitor") })
    local ctx = make_ctx()
    local m = fake_modem()
    sdquery.process(m, { id = "r2", reply_to = "U", reply_port = 1, keys = { "Nope", 42 } })
    eq(body(m, 1).ok, false); truthy(body(m, 1).error:find("登錄", 1, true))
    eq(body(m, 2).ok, false); eq(body(m, 2).key, "42")
    m.sent = {}
    ctx.ae.getItemsInNetwork = function() error("down") end
    sdquery.process(m, { id = "r3", reply_to = "U", reply_port = 1, keys = { "Iron" } })
    eq(body(m, 1).ok, false); truthy(body(m, 1).error)
    m.sent = {}
    ctx.ae = nil
    sdquery.process(m, { id = "r4", reply_to = "U", reply_port = 1, keys = { "Iron" } })
    eq(body(m, 1).ok, false)
end)

test("query: same label registered twice (different name) -> one reply each", function()
    cfg([[{"items":[
        {"name":"a:x","damage":0,"label":"Iron","mode_tag":"monitor"},
        {"name":"b:x","damage":0,"label":"Iron","mode_tag":"monitor"}]}]])
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", name = "a:x", damage = 0, size = 5 }, { label = "Iron", name = "b:x", damage = 0, size = 7 } } end
    local m = fake_modem()
    sdquery.process(m, { id = "r5", reply_to = "U", reply_port = 1, keys = { "Iron" } })
    eq(#m.sent, 3); eq(body(m, 1).count, 5); eq(body(m, 2).count, 7)
end)

test("query: via relay -> FORWARD_CMD with only 5 parts (fits the 8-part limit)", function()
    cfg_items({ entry("Iron", "monitor") })
    make_ctx()
    local m = fake_modem()
    sdquery.process(m, { id = "r6", reply_to = "ASKER", reply_port = 555, via = "RELAY", keys = { "Iron" } })
    local a = m.sent[1]
    eq(a[1], "RELAY"); eq(a[2], 100); eq(a[3], "FORWARD_CMD"); eq(a[4], "ASKER"); eq(a[5], 555); eq(a[6], "AE_QUERY_REPLY")
    eq(select("#", table.unpack(a)) - 2, 5)
    eq(assert(sdjson.decode(a[7])).key, "Iron")
end)

test("query: caps the number of keys and ignores requests without a reply address", function()
    cfg_items({ entry("Iron", "monitor") })
    make_ctx()
    local m = fake_modem()
    local many = {}; for i = 1, 200 do many[i] = "Iron" end
    sdquery.process(m, { id = "r7", reply_to = "A", reply_port = 1, keys = many })
    eq(#m.sent, 61)  -- 60 replies + DONE
    eq(sdquery.process(m, { id = "r8", keys = { "Iron" } }), false)
    eq(sdquery.process(m, "garbage"), false)
end)

test("query: modem_message handler only answers AE_QUERY on query_port with valid JSON", function()
    cfg_items({ entry("Iron", "monitor") })
    make_ctx()
    local m = fake_modem()
    local saved = component.proxy
    component.proxy = function() return m end
    local good = '{"id":"x","reply_to":"A","reply_port":1,"keys":["Iron"]}'
    sdquery._on_modem_message("modem_message", "L", "R", 999, 0, "AE_QUERY", good)
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "OTHER", good)
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "AE_QUERY", "{not json")
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "AE_QUERY", 12345)
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "AE_QUERY", string.rep("x", 9000))
    eq(#m.sent, 0)
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "AE_QUERY", good)
    eq(#m.sent, 2)
    component.proxy = saved
end)

-- ========== touch_menu: module wiring ==========
local function load_real_menu(with_database)
    package.loaded.touch_menu = nil
    avail = { modem = true, database = with_database or false }
    listings = { ["6429-gpu"] = "gpu", ["a875-scr"] = "screen" }
    local gpu = make_gpu()
    local order = {}
    gpu.bind = function() order[#order + 1] = "bind" end
    gpu.setResolution = function() order[#order + 1] = "setResolution" end
    gpu.fill = function() order[#order + 1] = "fill" end
    local saved_proxy = component.proxy
    component.proxy = function(addr)
        if addr == "6429-gpu" then return gpu end
        return { address = addr }
    end
    rawset(component, "gpu", gpu)
    if with_database then
        rawset(component, "database", db_with({ [1] = stack("a:x", 0, "Iron"), [2] = stack("b:y", 0, "Gold") }))
    end
    local ok, menu = pcall(require, "touch_menu")
    local function cleanup()
        component.proxy = saved_proxy
        rawset(component, "gpu", nil); rawset(component, "database", nil)
        avail = { modem = true }; listings = {}
    end
    return ok, menu, gpu, order, cleanup
end

test("touch_menu loads without a database component and binds screen before drawing", function()
    local ok, menu, gpu, order, cleanup = load_real_menu(false)
    truthy(ok, "require failed: " .. tostring(menu))
    menu.config_file_path = TMP_DIR .. "/menu_cfg.json"; menu.realtime_path = TMP_DIR .. "/menu_time.txt"
    eq(menu.start(), true)
    eq(order[1], "bind", "bind must precede any drawing")
    truthy(listeners.modem_message, "query listener not registered")
    menu.handle_touch(40, 4)             -- "AE2" tab
    menu.list_pages = 3
    menu.handle_touch(85, 4)             -- next
    eq(menu.list_page, 2)
    menu.handle_touch(85, 4)
    eq(menu.list_page, 3)
    menu.handle_touch(85, 4)             -- already last: no change
    eq(menu.list_page, 3)
    menu.handle_touch(70, 4)             -- prev
    eq(menu.list_page, 2)
    menu.handle_touch(10, 4)             -- back to the clock page
    menu.handle_touch(85, 4)
    eq(menu.list_page, 1, "pager must be inactive on the clock page / reset on switch")
    eq(menu.query_port, 102); eq(menu.items_per_page, 35); truthy(menu.get_now_time)
    menu.stop()
    eq(listeners.modem_message, nil, "listener must be removed on stop")
    cleanup()
end)

test("touch_menu: start() scans the database; the scan button adds items found later", function()
    local ok, menu, gpu, order, cleanup = load_real_menu(true)
    truthy(ok, "require failed: " .. tostring(menu))
    local path = TMP_DIR .. "/menu_cfg2.json"
    os.remove(path); os.remove(path .. ".bak")
    menu.config_file_path = path; menu.realtime_path = TMP_DIR .. "/menu_time.txt"
    -- start(): init scan registers the 2 items already in the database
    eq(menu.start(), true)
    local items = sdlogic.load_hybrid_config()
    eq(#items, 2); eq(items[1].mode_tag, "monitor")
    truthy(menu.scan_message and menu.scan_message.text:find("新增 2", 1, true), "init message")
    -- a new item shows up in the database, user presses the scan button on page 2
    local db = component.database
    local slots = { [1] = stack("a:x", 0, "Iron"), [2] = stack("b:y", 0, "Gold"), [3] = stack("c:z", 0, "Copper") }
    rawset(component, "database", db_with(slots))
    menu.db = component.database
    menu.handle_touch(40, 4)                -- go to page 2
    menu.handle_touch(120, 4)               -- scan button
    eq(#sdlogic.load_hybrid_config(), 3)
    truthy(menu.scan_message.text:find("新增 1", 1, true) and menu.scan_message.text:find("Copper", 1, true), menu.scan_message.text)
    local shown = false
    for _, st in ipairs(gpu.sets) do if st.y == 13 and st.s:find("Copper", 1, true) then shown = true end end
    truthy(shown, "result message drawn on row 13")
    menu.handle_touch(120, 4)               -- nothing new the second time
    truthy(menu.scan_message.text:find("沒有新增", 1, true))
    menu.handle_touch(10, 4)
    menu.handle_touch(120, 4)               -- scan button is inactive on the clock page
    eq(#sdlogic.load_hybrid_config(), 3)
    menu.stop()
    cleanup()
end)

test("touch_menu: scan failure is shown, not thrown", function()
    local ok, menu, gpu, order, cleanup = load_real_menu(true)
    truthy(ok)
    local path = TMP_DIR .. "/menu_cfg3.json"
    write(path, "{ broken")
    menu.config_file_path = path; menu.realtime_path = TMP_DIR .. "/menu_time.txt"
    menu.start()
    truthy(menu.scan_message and menu.scan_message.color == 0xFF5555, "error colour")
    menu.handle_touch(40, 4); menu.handle_touch(120, 4)
    truthy(menu.scan_message.text:find("失敗", 1, true))
    eq(read(path), "{ broken", "broken file untouched")
    menu.stop()
    cleanup()
end)

print(string.format("\n%d passed, %d failed", passed, failed))
return failed
