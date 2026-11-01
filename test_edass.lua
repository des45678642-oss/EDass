-- Unit tests for EDass (OpenComputers). Run under plain Lua 5.3 with mocked OC APIs.
-- Globals expected from the runner: EDASS_DIR (source dir), TMP_DIR (writable dir).

package.path = EDASS_DIR .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local Main

local function test(name, fn)
    -- each test starts from clean globals/mocks
    _G.current_global_task = nil
    Main = {
        battery_name = "multimachine.supercapacitor", battery_rescan_interval = 60,
        config_check_interval = 0, query_mode = "auto", query_full_threshold = 8,
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
    if package.loaded.sdminer and package.loaded.sdminer._reset then package.loaded.sdminer._reset() end
    OPENED = {}
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
OPENED = {}
component.invoke = function(addr, method, ...) if method == "open" then OPENED[#OPENED + 1] = { addr = addr, port = ... } end end

package.loaded.component = component
package.loaded.computer = { uptime = function() return uptime end }
local mtimes = {}
local fs_calls = { exists = 0, lastModified = 0 }
package.loaded.filesystem = {
    exists = function(p) fs_calls.exists = fs_calls.exists + 1; local f = io.open(p, "r"); if f then f:close(); return true end return false end,
    lastModified = function(p) fs_calls.lastModified = fs_calls.lastModified + 1; return mtimes[p] end,
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
local sdminer = require("sdminer")

local function write(path, text)
    local f = assert(io.open(path, "w")); f:write(text); f:close()
    mtimes[path] = (mtimes[path] or 0) + 1
end
local function read(path) local f = assert(io.open(path, "r")); local t = f:read("a"); f:close(); return t end
local function cfg(json_text) write(Main.config_file_path, json_text) end

local function make_gpu()
    local g = { sets = {}, calls = {} }
    function g.set(x, y, s) g.sets[#g.sets + 1] = { x = x, y = y, s = s, fg = g.fg } end
    function g.fill() end
    function g.setForeground(c) g.fg = c end
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
local function key_of(label) return label end   -- state key == label (AE2 searches by label only)
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

test("config: label is the identity - a second entry with the same label is flagged", function()
    cfg([[{"items":[
        {"name":"a:x","damage":0,"label":"Iron","mode_tag":"monitor"},
        {"name":"b:x","damage":0,"label":"Iron","mode_tag":"monitor"},
        {"name":"a:x","damage":1,"label":"Iron","mode_tag":"monitor"},
        {"name":"a:y","damage":0,"label":"Iron Dust","mode_tag":"monitor"}
    ]}]])
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 2); eq(#errs, 2); truthy(errs[1]:find("label", 1, true))
    eq(items[1].key, "Iron"); eq(items[2].label, "Iron Dust")
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

test("count_item: label-only, filtered query; failures give nil + message", function()
    local seen
    local ae = { getItemsInNetwork = function(filter) seen = filter; return {
        { label = "Iron", name = "minecraft:iron_ingot", damage = 0, size = 100 },
        { label = "Iron", name = "other:iron_ingot", damage = 3, size = 50 },
        { label = "Iron Dust", name = "x", damage = 0, size = 7 },
        { label = "Iron", name = "minecraft:iron_ingot", damage = 0, size = 23 },
    } end }
    local n = sdlogic.count_item({ name = "ignored", damage = 99, label = "Iron" }, ae)
    eq(n, 173, "name/damage do not take part in the search"); eq(seen.label, "Iron"); eq(seen.name, nil); eq(seen.damage, nil)
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

test("scan: identity is the label; same label with other name/damage is reported as skipped", function()
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron"), [2] = stack("a:x", 1, "Iron"), [3] = stack("a:x", 0, "Iron Dust"), [4] = stack("b:y", 0, "Iron") })
    cfg_items({ entry("Iron", "monitor", { name = "a:x" }) })
    local n, added, skipped = sdlogic.scan_database()
    eq(n, 1); eq(added[1], "Iron Dust")
    eq(#skipped, 1); eq(skipped[1], "Iron", "reported once")
    local _, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0, "scan never creates duplicate labels")
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

test("duplicate label in the config: only the first entry is active (one order, error shown)", function()
    cfg([[{"items":[
        {"name":"a:x","damage":0,"label":"Iron","mode_tag":"restock","target_quantity":100,"target_once":10},
        {"name":"b:x","damage":0,"label":"Iron","mode_tag":"restock","target_quantity":100,"target_once":20}]}]])
    local ctx = make_ctx()
    local requests = {}
    ctx.ae.getCraftables = function() return { { request = function(n) requests[#requests + 1] = n; return { isDone = function() return false end, isCanceled = function() return false end } end } } end
    render(ctx, 5000)
    eq(#requests, 1); eq(requests[1], 10)
    truthy(row_text(ctx.gpu, 12):find("重複的 label", 1, true))
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
    eq(a.id, "r1"); eq(a.key, "Iron"); eq(a.ok, true); eq(a.count, 123); eq(a.name, nil, "label-only replies")
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

test("query: counts by label only (other name/damage with the same label are included)", function()
    cfg_items({ entry("Iron", "monitor") })
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", name = "a:x", damage = 0, size = 5 }, { label = "Iron", name = "b:x", damage = 2, size = 7 } } end
    local m = fake_modem()
    sdquery.process(m, { id = "r5", reply_to = "U", reply_port = 1, keys = { "Iron" } })
    eq(#m.sent, 2); eq(body(m, 1).count, 12)
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


-- ========== batteries (page 1) ==========
local function fake_battery(name, lines, opts)
    opts = opts or {}
    local calls = { getName = 0, sensor = 0 }
    return {
        calls = calls,
        getName = function() calls.getName = calls.getName + 1; if opts.name_error then error("no name") end; return name end,
        getSensorInformation = function() calls.sensor = calls.sensor + 1; if opts.sensor_error then error("offline") end; return lines end,
    }
end
local function install_machines(machines)
    listings = {}
    for addr, m in pairs(machines) do listings[addr] = "gt_machine" end
    local saved = component.proxy
    component.proxy = function(addr) return machines[addr] or { address = addr } end
    return function() component.proxy = saved; listings = {} end
end
local LSC = "multimachine.supercapacitor"

test("sensor parse: separate Stored / Total lines with commas and colour codes", function()
    local info = assert(sdapi.parse_sensor({ "Operational Data:", "\194\167aEU Stored: \194\167f1,500,000,000 EU", "\194\167bTotal Capacity: 2,000,000,000 EU", "Used Capacity: 75.0%" }))
    eq(info.stored, 1.5e9); eq(info.total, 2e9); eq(info.pct, 75.0)
end)

test("sensor parse: scientific notation in every spelling", function()
    for _, pair in ipairs({ { "1.5E10", 1.5e10 }, { "1.5e10", 1.5e10 }, { "1.5E+10", 1.5e10 }, { "2E9", 2e9 }, { "9.223372036854775807E18", 9.223372036854775807e18 } }) do
        local info = assert(sdapi.parse_sensor({ "EU Stored: " .. pair[1] .. " EU", "Total Capacity: 9.3E18 EU" }), pair[1])
        eq(info.stored, pair[2], pair[1])
    end
end)

test("sensor parse: one line 'Stored/Total: a / b' (also with sci notation)", function()
    local info = assert(sdapi.parse_sensor({ "EU Stored/Total Capacity: 1.0E9 / 4,000,000,000" }))
    eq(info.stored, 1e9); eq(info.total, 4e9); eq(info.pct, 25.0)
end)

test("sensor parse: only a percentage, garbage, zero total, wrong type", function()
    local info = assert(sdapi.parse_sensor({ "Used Capacity: 45.5%" }))
    eq(info.pct, 45.5); eq(info.stored, nil)
    eq((sdapi.parse_sensor({ "hello", "world" })), nil)
    eq((sdapi.parse_sensor({ "EU Stored: 0", "Total Capacity: 0" })), nil)
    eq((sdapi.parse_sensor("nope")), nil)
    eq((sdapi.parse_sensor({})), nil)
    local over = assert(sdapi.parse_sensor({ "EU Stored: 5E9", "Total Capacity: 4E9" }))
    eq(over.pct, 100, "percentage is capped")
end)

test("numbers_in: thousands separators, sci notation, several numbers", function()
    local n = sdapi.numbers_in("1,234,567 / 2.5E3 / 7 EU")
    eq(n[1], 1234567); eq(n[2], 2500); eq(n[3], 7); eq(#n, 3)
end)

test("find_batteries: only gt_machines whose getName() is multimachine.supercapacitor", function()
    sdapi._reset_cache()
    local restore = install_machines({
        ["bbbb"] = fake_battery(LSC, {}), ["aaaa"] = fake_battery(LSC, {}),
        ["cccc"] = fake_battery("multimachine.blastfurnace", {}), ["dddd"] = fake_battery(nil, {}, { name_error = true }),
    })
    local list = sdapi.find_batteries(true)
    restore()
    eq(#list, 2); eq(list[1].address, "aaaa"); eq(list[2].address, "bbbb", "sorted by address")
end)

test("find_batteries: result is cached until battery_rescan_interval or a forced rescan", function()
    sdapi._reset_cache()
    local m = fake_battery(LSC, {})
    local restore = install_machines({ ["aaaa"] = m })
    Main.now = 100
    sdapi.find_batteries(); sdapi.find_batteries()
    eq(m.calls.getName, 1, "second call served from cache")
    Main.now = 130; sdapi.find_batteries()
    eq(m.calls.getName, 1, "still inside the 60s interval")
    Main.now = 161; sdapi.find_batteries()
    eq(m.calls.getName, 2, "rescanned after the interval")
    sdapi.find_batteries(true)
    eq(m.calls.getName, 3, "forced rescan")
    restore()
end)

test("read_all_batteries: one broken battery does not break the others; summary only counts readable ones", function()
    sdapi._reset_cache()
    local restore = install_machines({
        ["aaaa"] = fake_battery(LSC, { "EU Stored: 1E9", "Total Capacity: 4E9" }),
        ["bbbb"] = fake_battery(LSC, nil, { sensor_error = true }),
        ["cccc"] = fake_battery(LSC, { "EU Stored: 3E9", "Total Capacity: 4E9" }),
        ["dddd"] = fake_battery(LSC, { "nothing useful" }),
    })
    local list, sum = sdapi.read_all_batteries(true)
    restore()
    eq(#list, 4); eq(list[2].err, "讀取失敗"); truthy(list[4].err)
    eq(sum.count, 4); eq(sum.counted, 2); eq(sum.stored, 4e9); eq(sum.total, 8e9); eq(sum.pct, 50.0)
end)

test("format_eu: readable units", function()
    eq(sdlogic.format_eu(999), "999 EU"); eq(sdlogic.format_eu(1500), "1.50KEU")
    eq(sdlogic.format_eu(1.5e9), "1.50GEU"); eq(sdlogic.format_eu(9.2e18), "9.20EEU"); eq(sdlogic.format_eu(nil), "?")
end)

test("page 1 shows every battery plus the total, and no clock any more", function()
    sdapi._reset_cache()
    local restore = install_machines({
        ["aaaa1111"] = fake_battery(LSC, { "EU Stored: 3E9", "Total Capacity: 4E9" }),
        ["bbbb2222"] = fake_battery(LSC, { "EU Stored: 1E9", "Total Capacity: 4E9" }),
        ["cccc3333"] = fake_battery(LSC, { "EU Stored: 0.5E9", "Total Capacity: 4E9" }),
        ["dddd4444"] = fake_battery("other.machine", {}),
    })
    local ctx = make_ctx()
    sdlogic.render_page1()
    restore()
    local all = {}
    for _, st in ipairs(ctx.gpu.sets) do all[#all + 1] = st.s end
    local text = table.concat(all, "\n")
    truthy(text:find("共 3 顆電池", 1, true), "summary")
    truthy(text:find("4.50GEU / 12.00GEU", 1, true), "total stored / total capacity: " .. text)
    truthy(text:find("37.5%", 1, true))
    truthy(not text:find("REALWORLD", 1, true) and not text:find("TIME", 1, true) and not text:find("DATE", 1, true), "clock removed")
    local r16, r17, r18 = row_text(ctx.gpu, 16), row_text(ctx.gpu, 17), row_text(ctx.gpu, 18)
    truthy(r16:find("aaaa1", 1, true) and r16:find("75.0%", 1, true) and r16:find("3.00GEU", 1, true))
    truthy(r17:find("25.0%", 1, true)); truthy(r18:find("12.5%", 1, true))
    truthy(r16:find("█", 1, true) and r16:find("░", 1, true), "bar")
    eq(row_text(ctx.gpu, 19), nil)
end)

test("page 1 colours follow the thresholds (>=60 green, >=50 yellow, else red)", function()
    sdapi._reset_cache()
    local restore = install_machines({
        ["aaaa"] = fake_battery(LSC, { "Used Capacity: 80%" }), ["bbbb"] = fake_battery(LSC, { "Used Capacity: 55%" }),
        ["cccc"] = fake_battery(LSC, { "Used Capacity: 20%" }),
    })
    local ctx = make_ctx()
    sdlogic.render_page1()
    restore()
    local function fg(y) for i = #ctx.gpu.sets, 1, -1 do if ctx.gpu.sets[i].y == y then return ctx.gpu.sets[i].fg end end end
    eq(fg(16), 0x00FF00); eq(fg(17), 0xFFEE00); eq(fg(18), 0xFF5555)
    truthy(row_text(ctx.gpu, 16):find("?", 1, true), "percentage-only battery has unknown stored/total")
end)

test("page 1: no battery on the network -> clear message; unreadable one is shown in red", function()
    sdapi._reset_cache()
    local ctx = make_ctx()
    listings = {}
    sdlogic.render_page1()
    truthy(row_text(ctx.gpu, 13):find("找不到電池", 1, true))
    sdapi._reset_cache(); sdlogic.reset_draw_cache()
    local restore = install_machines({ ["aaaa"] = fake_battery(LSC, nil, { sensor_error = true }) })
    sdlogic.render_page1()
    restore()
    truthy(row_text(ctx.gpu, 16):find("讀取失敗", 1, true))
    truthy(row_text(ctx.gpu, 13):find("無法讀取電量", 1, true))
end)

test("page 1: more batteries than rows -> last row says how many are hidden", function()
    sdapi._reset_cache()
    local machines = {}
    for i = 1, 40 do machines[string.format("b%03d", i)] = fake_battery(LSC, { "Used Capacity: 70%" }) end
    local restore = install_machines(machines)
    local ctx = make_ctx()
    sdlogic.render_page1()
    restore()
    truthy(row_text(ctx.gpu, 50):find("另有 6 顆未顯示", 1, true), row_text(ctx.gpu, 50))
    for _, st in ipairs(ctx.gpu.sets) do truthy(st.y <= 50) end
end)

test("page 1: unchanged data is not redrawn; a changed battery redraws only its row", function()
    sdapi._reset_cache()
    local b1 = fake_battery(LSC, { "EU Stored: 1E9", "Total Capacity: 4E9" })
    local b2 = fake_battery(LSC, { "EU Stored: 2E9", "Total Capacity: 4E9" })
    local restore = install_machines({ ["aaaa"] = b1, ["bbbb"] = b2 })
    local ctx = make_ctx()
    sdlogic.render_page1()
    local first = #ctx.gpu.sets
    sdlogic.render_page1()
    eq(#ctx.gpu.sets, first, "identical frame -> zero gpu.set calls")
    b2.getSensorInformation = function() return { "EU Stored: 3E9", "Total Capacity: 4E9" } end
    sdlogic.render_page1()
    local changed = {}
    for i = first + 1, #ctx.gpu.sets do changed[ctx.gpu.sets[i].y] = true end
    truthy(changed[17] and changed[13], "row 17 (battery 2) and the summary changed")
    truthy(not changed[16], "battery 1 row untouched")
    sdlogic.reset_draw_cache()
    local before = #ctx.gpu.sets
    sdlogic.render_page1()
    truthy(#ctx.gpu.sets > before, "reset_draw_cache forces a full redraw")
    restore()
end)

-- ========== speed: caches and query modes ==========
test("config cache: inside config_check_interval the file system is not touched at all", function()
    cfg_items({ restock("Iron") })
    Main.config_check_interval = 10
    Main.now = 100
    eq(#sdlogic.load_hybrid_config(), 1)
    fs_calls.exists, fs_calls.lastModified = 0, 0
    for _ = 1, 20 do Main.now = Main.now + 0.4; sdlogic.load_hybrid_config() end
    eq(fs_calls.exists + fs_calls.lastModified, 0, "no fs calls inside the interval")
    Main.now = 111
    sdlogic.load_hybrid_config()
    eq(fs_calls.lastModified, 1, "one cheap lastModified check after the interval")
    cfg_items({ restock("Iron"), restock("Gold") })         -- edited by hand
    Main.now = 125
    eq(#sdlogic.load_hybrid_config(), 2, "edit picked up after the next check")
end)

test("config cache: validated items are reused while the file is unchanged", function()
    cfg_items({ restock("Iron") })
    Main.config_check_interval = 10
    local a = sdlogic.load_hybrid_config()
    local b = sdlogic.load_hybrid_config()
    truthy(a == b, "same table instance: nothing rebuilt")
end)

test("config cache: scan_database makes new items visible immediately", function()
    Main.config_check_interval = 3600
    Main.db = db_with({ [1] = stack("a:x", 0, "Iron") })
    cfg('{"items":[]}')
    eq(#sdlogic.load_hybrid_config(), 0)
    eq((sdlogic.scan_database()), 1)
    eq(#sdlogic.load_hybrid_config(), 1, "no waiting for the check interval")
end)

test("query mode auto: few items -> one filtered call per label", function()
    local list = {}
    for i = 1, 3 do list[i] = restock("Item" .. i) end
    cfg_items(list)
    local ctx = make_ctx()
    local calls = {}
    ctx.ae.getItemsInNetwork = function(filter) calls[#calls + 1] = filter and filter.label or "ALL"; return {} end
    render(ctx, 5000)
    eq(#calls, 3); eq(calls[1], "Item1")
    eq(ctx.perf.mode, "filter")
end)

test("query mode auto: many items -> ONE unfiltered call, counts summed per label", function()
    local list = {}
    for i = 1, 12 do list[i] = restock("Item" .. i, 1000, 10) end
    cfg_items(list)
    local ctx = make_ctx()
    local calls = 0
    ctx.ae.getItemsInNetwork = function(filter)
        calls = calls + 1
        eq(filter, nil, "unfiltered")
        return { { label = "Item1", size = 5 }, { label = "Item1", size = 6, name = "other", damage = 4 }, { label = "Item2", size = 7 }, { label = "Unrelated", size = 99 } }
    end
    render(ctx, 5000)
    eq(calls, 1); eq(ctx.perf.mode, "full")
    truthy(row_text(ctx.gpu, 16):find("11", 1, true), "Item1 = 5 + 6")
    truthy(row_text(ctx.gpu, 17):find("7", 1, true))
    truthy(row_text(ctx.gpu, 18):find("0", 1, true), "labels not in the network count as 0")
end)

test("query mode can be forced; a failed full scan marks every item as failed (never 0)", function()
    cfg_items({ restock("Iron"), restock("Gold") })
    local ctx = make_ctx({ query_mode = "full" })
    local calls = 0
    ctx.ae.getItemsInNetwork = function() calls = calls + 1; error("down") end
    local ordered = false
    ctx.ae.getCraftables = function() ordered = true; return {} end
    render(ctx, 5000)
    eq(calls, 1); eq(ctx.perf.mode, "full"); eq(ordered, false)
    truthy(row_text(ctx.gpu, 16):find("AE查詢失敗", 1, true) and row_text(ctx.gpu, 17):find("AE查詢失敗", 1, true))
end)

test("page 2 draw cache: an identical refresh sends nothing to the gpu", function()
    cfg_items({ restock("Iron"), restock("Gold") })
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 500 }, { label = "Gold", size = 500 } } end
    render(ctx, 5000)
    local first = #ctx.gpu.sets
    truthy(first > 0)
    render(ctx, 5005)
    local new_rows = {}
    for i = first + 1, #ctx.gpu.sets do new_rows[#new_rows + 1] = ctx.gpu.sets[i].y end
    for _, y in ipairs(new_rows) do eq(y, 10, "only the changing perf line may be redrawn (row " .. y .. ")") end
end)

test("page 2 draw cache: rows below a shorter list are blanked", function()
    cfg_items({ restock("A"), restock("B"), restock("C"), restock("D") })
    local ctx = make_ctx()
    render(ctx, 5000)
    truthy(row_text(ctx.gpu, 19):find("D", 1, true))
    cfg_items({ restock("A"), restock("B") })
    Main.config_check_interval = 0
    render(ctx, 5005)
    eq(row_text(ctx.gpu, 19):match("^%s*$") ~= nil, true, "row 19 blanked")
    eq(row_text(ctx.gpu, 18):match("^%s*$") ~= nil, true, "row 18 blanked")
    truthy(row_text(ctx.gpu, 17):find("B", 1, true))
end)

test("empty config message is fully replaced when items appear again", function()
    cfg('{"items":[]}')
    local ctx = make_ctx()
    render(ctx, 5000)
    truthy(row_text(ctx.gpu, 17):find("為空", 1, true))
    cfg_items({ restock("Iron") })
    render(ctx, 5005)
    local r = row_text(ctx.gpu, 17)
    truthy(not r:find("為空", 1, true))
end)

test("log file is only rewritten when its content changes", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 500 } } end
    render(ctx, 5000)
    truthy(read(ctx.log_file_path):find("Iron=0=0=0", 1, true))
    write(ctx.log_file_path, "SENTINEL")
    render(ctx, 5005)
    eq(read(ctx.log_file_path), "SENTINEL", "unchanged state -> no write")
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 1 } } end
    ctx.last_order_time[key_of("Iron")] = 5005                  -- in cooldown -> different tag
    render(ctx, 5010)
    truthy(read(ctx.log_file_path):find("Iron=2", 1, true), "changed state -> rewritten")
end)

test("timing readout: perf table and the line on row 10", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    local t = 0
    ctx.get_now_time = function() t = t + 0.05; return t end
    render(ctx, 0)
    truthy(ctx.perf.total > 0 and ctx.perf.n == 1)
    local row = row_text(ctx.gpu, 10)
    truthy(row:find("刷新耗時", 1, true) and row:find("設定", 1, true) and row:find("AE2", 1, true) and row:find("filter", 1, true), row)
end)


-- ========== miner mode (port of space_main) ==========
local DRONE = "gtnhintergalactic:item.MiningDrone"
local function drone(level, n) return { name = DRONE, damage = level - 1, size = n or 1 } end

local function make_chest(stacks, size)
    local tp = { size = size or 27, stacks = stacks, calls = { getAllStacks = 0 } }
    tp.getInventorySize = function() return tp.size end
    tp.getAllStacks = function() tp.calls.getAllStacks = tp.calls.getAllStacks + 1; return { getAll = function() return tp.stacks end } end
    return tp
end

local function miner_item(label, target, extra)
    local t = { name = "mod:" .. label, damage = 0, label = label, mode_tag = "miner", target_quantity = target,
                distance = 91, weight = 1, limit = 0, min_miner_tier = 1, min_drone_tier = 3, max_drone_tier = 5 }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

local function make_miner_modem()
    local mm = { sent = {}, strength = 400, order = {} }
    function mm.send(to, port, ...)
        mm.sent[#mm.sent + 1] = { to = to, port = port, args = { ... }, strength = mm.strength }
    end
    function mm.broadcast(port, ...)
        mm.sent[#mm.sent + 1] = { broadcast = true, port = port, args = { ... }, strength = mm.strength }
    end
    function mm.getStrength() return mm.strength end
    function mm.setStrength(v) mm.strength = v end
    return mm
end

-- builds a complete miner environment; returns helpers
local function miner_env(opts)
    opts = opts or {}
    local ctx = make_ctx()
    local mm = make_miner_modem()
    rawset(component, "modem", mm)
    avail.modem = true
    listings = { ["modem-a"] = "modem" }
    local tp
    if not opts.no_transposer then tp = make_chest(opts.chest or {}) end
    for k, v in pairs({ miner_port = 300, miner_strength = 16, miner_chest_side = 2, drone_item_name = DRONE,
        miner_cooldown = 300, miner_dispatch_interval = 5, miner_msgs_per_tick = 4, miner_settle = 2 }) do ctx[k] = v end
    ctx.miner_transposer = tp
    ctx.now = 1000
    cfg_items(opts.items or {})
    local stock = opts.stock or {}
    ctx.ae.getItemsInNetwork = function(filter)
        if opts.ae_down then error("ae down") end
        local out = {}
        for label, n in pairs(stock) do if not filter or filter.label == label then out[#out + 1] = { label = label, size = n } end end
        return out
    end
    local env = { ctx = ctx, mm = mm, tp = tp, stock = stock }
    function env.register(uuid, name) sdminer._on_modem_message("modem_message", "L", uuid, 300, 0, "MINER_REGISTER", name) end
    function env.tick(n) for _ = 1, n or 1 do ctx.now = ctx.now + 1; sdminer.tick() end end
    function env.sent_to(uuid)
        local out = {}
        for _, m in ipairs(mm.sent) do if m.to == uuid then out[#out + 1] = m end end
        return out
    end
    function env.cmds(uuid)
        local out = {}
        for _, m in ipairs(env.sent_to(uuid)) do out[#out + 1] = m.args[1] end
        return out
    end
    function env.start() local ok, err = sdminer.start(); return ok, err end
    function env.run_until_dispatch()   -- tick until the first dispatch pass has happened
        for _ = 1, 30 do env.tick(1); if sdminer._state().phase ~= "cleaning" then break end end
    end
    function env.done() rawset(component, "modem", modem); listings = {} end
    return env
end

test("miner: tier is the first number in the reported GT name", function()
    eq(sdminer.extract_tier("multimachine.miner.t3"), 3); eq(sdminer.extract_tier("T 12 Miner"), 12)
    eq(sdminer.extract_tier("unknown_gt_device"), 1); eq(sdminer.extract_tier(nil), 1)
end)

test("miner: not available without a transposer; summary says why; refresh does nothing", function()
    local env = miner_env({ no_transposer = true, items = { miner_item("Ore", 1000) } })
    local ok, err = env.start()
    eq(ok, false); truthy(err:find("transposer", 1, true))
    eq(sdminer.is_active(), false); eq(sdminer.refresh_now(), false)
    local text, active = sdminer.summary(true)
    truthy(text:find("未啟用", 1, true)); eq(active, false)
    eq((sdminer.summary(false)), nil, "nothing to show when no miner items")
    env.done()
end)

test("miner: start opens the port, listens, broadcasts REG_RESET at miner strength and restores the old strength", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) } })
    eq(env.start(), true)
    local opened = false
    for _, o in ipairs(OPENED) do if o.port == 300 then opened = true end end
    truthy(opened, "port 300 opened"); truthy(listeners.modem_message, "listener registered")
    env.tick(1)
    local b = env.mm.sent[1]
    truthy(b and b.broadcast and b.args[1] == "REG_RESET" and b.port == 300)
    eq(b.strength, 16, "sent at miner strength"); eq(env.mm.strength, 400, "previous strength restored")
    env.done()
end)

test("miner: registration replies REG_SUCCESS - also for known miners and during cooldown", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) } })
    env.start()
    env.register("miner-aaaa", "multimachine.miner.t2")
    eq(sdminer._state().miners["miner-aaaa"].tier, 2)
    env.register("miner-aaaa", "multimachine.miner.t4")                 -- rebooted miner registers again
    eq(sdminer._state().miners["miner-aaaa"].tier, 4)
    local success = 0
    for _, m in ipairs(env.sent_to("miner-aaaa")) do if m.args[1] == "REG_SUCCESS" then success = success + 1 end end
    eq(success, 2, "original only answered the first registration")
    sdminer._state().phase = "cooldown"; sdminer._state().cooldown_until = 1e9
    env.register("miner-bbbb", "t1")
    truthy(sdminer._state().miners["miner-bbbb"], "new miner accepted during cooldown")
    env.done()
end)

test("miner: stage 1 assigns the highest drone inside the level range (slot is 1-based)", function()
    local env = miner_env({
        items = { miner_item("Ore", 1000, { min_drone_tier = 3, max_drone_tier = 5 }) }, stock = { Ore = 400 },
        chest = { [0] = drone(4, 2), [3] = drone(5, 1), [4] = drone(9, 5), [6] = drone(3, 3) },
    })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(3)
    local cmds = env.sent_to("m1")
    local set, push
    for _, m in ipairs(cmds) do
        if m.args[1] == "SET_MACHINE" then set = m end
        if m.args[1] == "PUSH_MATERIAL" then push = m end
    end
    truthy(set and push, "both commands sent")
    eq(set.args[2], 0); eq(set.args[3], 0); eq(set.args[4], 91); eq(set.port, 300); eq(set.strength, 16)
    eq(push.args[2], 4, "level-5 drone sits in 0-based index 3 -> slot 4"); eq(push.args[3], 1)
    local order = env.cmds("m1")
    local si, pi
    for i, c in ipairs(order) do if c == "SET_MACHINE" then si = i elseif c == "PUSH_MATERIAL" then pi = i end end
    truthy(si < pi, "SET_MACHINE before PUSH_MATERIAL")
    local st = sdminer.status("Ore")
    eq(st.assigned, 1); eq(st.needed, 1); eq(st.reason, nil)
    env.done()
end)

test("miner: the recipe field names are min_drone_tier / max_drone_tier (a level outside the range is never used in strict mode)", function()
    local env = miner_env({
        items = { miner_item("Ore", 1000, { min_drone_tier = 7, max_drone_tier = 12 }) }, stock = { Ore = 100 },
        chest = { [0] = drone(3, 4), [1] = drone(5, 4) },
    })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(3)
    eq(#env.sent_to("m1"), 1, "only REG_SUCCESS - nothing pushed")
    eq(sdminer.status("Ore").reason, "no_drone"); eq(sdminer.status("Ore").assigned, 0)
    env.done()
end)

test("miner: number of miners = ceil(shortage ratio * weight); later passes do not add more", function()
    local items = { miner_item("Ore", 1000, { weight = 5 }) }
    local env = miner_env({ items = items, stock = { Ore = 500 }, chest = { [0] = drone(4, 20) } })
    env.start()
    for i = 1, 5 do env.register("m" .. i, "t1") end
    env.run_until_dispatch(); env.tick(8)
    local busy = 0
    for _, st in pairs(sdminer._state().miners) do if st.busy then busy = busy + 1 end end
    eq(busy, 3, "ceil(0.5 * 5)")
    eq(sdminer.status("Ore").needed, 3)
    env.tick(30)                                     -- many more dispatch passes
    busy = 0
    for _, st in pairs(sdminer._state().miners) do if st.busy then busy = busy + 1 end end
    eq(busy, 3, "miners already on the item count towards the need")
    env.done()
end)

test("miner: drones are reserved within a pass (a stack of 2 is never handed out 3 times)", function()
    local env = miner_env({ items = { miner_item("Ore", 1000, { weight = 5 }) }, stock = { Ore = 0 }, chest = { [0] = drone(4, 2) } })
    env.start()
    for i = 1, 5 do env.register("m" .. i, "t1") end
    env.run_until_dispatch(); env.tick(8)
    local pushes = 0
    for _, m in ipairs(env.mm.sent) do if m.args[1] == "PUSH_MATERIAL" then pushes = pushes + 1 end end
    eq(pushes, 2); eq(sdminer.status("Ore").reason, "no_drone"); eq(sdminer.status("Ore").assigned, 2)
    eq(sdminer._state().drones, 0)
    eq(sdminer._state().phase, "cooldown", "no drones left -> saturated -> cooldown")
    env.done()
end)

test("miner: min_miner_tier is checked against the tier parsed from the GT name", function()
    local env = miner_env({ items = { miner_item("Ore", 1000, { min_miner_tier = 2 }) }, stock = { Ore = 0 }, chest = { [0] = drone(4, 5) } })
    env.start(); env.register("low", "t1"); env.register("high", "t3")
    env.run_until_dispatch(); env.tick(4)
    truthy(sdminer._state().miners.high.busy); truthy(not sdminer._state().miners.low.busy)
    env.done()
    local env2 = miner_env({ items = { miner_item("Ore", 1000, { min_miner_tier = 5 }) }, stock = { Ore = 0 }, chest = { [0] = drone(4, 5) } })
    sdminer._reset(); env2.start(); env2.register("low", "t1")
    env2.run_until_dispatch(); env2.tick(2)
    eq(sdminer.status("Ore").reason, "no_miner")
    env2.done()
end)

test("miner: stage 2 gives idle miners the limit=1 items that are already satisfied (fallback drone allowed)", function()
    local env = miner_env({
        items = { miner_item("Full", 1000, { limit = 1, min_drone_tier = 3, max_drone_tier = 5 }), miner_item("Full0", 1000, { limit = 0 }) },
        stock = { Full = 5000, Full0 = 5000 }, chest = { [2] = drone(9, 3) },      -- only an out-of-range drone
    })
    env.start(); env.register("m1", "t1"); env.register("m2", "t1")
    env.run_until_dispatch(); env.tick(6)
    eq(sdminer._state().miners.m1.item, "Full"); eq(sdminer._state().miners.m2.item, "Full")
    eq(sdminer.status("Full").assigned, 2); eq(sdminer.status("Full0").assigned, 0, "limit=0 items never get idle miners")
    local push
    for _, m in ipairs(env.sent_to("m1")) do if m.args[1] == "PUSH_MATERIAL" then push = m end end
    eq(push.args[2], 3, "fallback drone from slot index 2 -> slot 3")
    env.done()
end)

test("miner: strict stage-1 items never take a fallback drone, stage 2 can", function()
    local env = miner_env({
        items = { miner_item("Need", 1000, { limit = 1, min_drone_tier = 7, max_drone_tier = 9 }) },
        stock = { Need = 10 }, chest = { [0] = drone(2, 3) },
    })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(4)
    eq(sdminer._state().miners.m1.busy, false, "needy item must not be fed a wrong-level drone")
    env.done()
end)

test("miner: when miners/drones are short, the item with the biggest shortage ratio is served first", function()
    local env = miner_env({
        items = { miner_item("Mild", 1000), miner_item("Severe", 1000) },      -- config order puts Mild first
        stock = { Mild = 800, Severe = 100 }, chest = { [0] = drone(4, 1) },
    })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(4)
    eq(sdminer._state().miners.m1.item, "Severe")
    eq(sdminer.status("Mild").reason, "no_miner", "the other item reports why it got nothing")
    env.done()
end)

test("miner: AE query failure -> no assignment for that item", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) }, ae_down = true, chest = { [0] = drone(4, 5) } })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(4)
    eq(sdminer.status("Ore").reason, "query"); eq(sdminer._state().miners.m1.busy, false)
    env.done()
end)

test("miner: commands are sent at most miner_msgs_per_tick per second and the chest is not re-read before they are delivered", function()
    local env = miner_env({ items = { miner_item("Ore", 1000, { weight = 6 }) }, stock = { Ore = 0 }, chest = { [0] = drone(4, 30) } })
    env.start()
    for i = 1, 12 do env.register("m" .. i, "t1") end            -- 6 needed of 12 -> never saturated -> several passes
    env.run_until_dispatch()
    local scans = {}
    local orig = env.tp.getAllStacks
    env.tp.getAllStacks = function(...)
        local st = sdminer._state()
        scans[#scans + 1] = { queued = #st.queue, since_send = env.ctx.now - st.last_send }
        return orig(...)
    end
    local per_tick, last = {}, #env.mm.sent
    for _ = 1, 40 do
        env.tick(1)
        per_tick[#per_tick + 1] = #env.mm.sent - last
        last = #env.mm.sent
    end
    for _, n in ipairs(per_tick) do truthy(n <= 4, "<= 4 messages per tick, got " .. n) end
    truthy(#scans >= 1, "dispatch passes happened")
    for _, sc in ipairs(scans) do
        eq(sc.queued, 0, "chest is only read when nothing is queued")
        truthy(sc.since_send >= 2, "and after the settle time, got " .. sc.since_send)
    end
    env.done()
end)

test("miner: saturation -> cooldown -> global clean (PULL_BACK) -> new cycle", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) }, stock = { Ore = 0 }, chest = { [0] = drone(4, 5) } })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(5)
    eq(sdminer._state().phase, "cooldown", "all miners busy")
    local text = sdminer.summary(true)
    truthy(text:find("冷卻", 1, true) and text:find("忙碌 1", 1, true), text)
    env.ctx.now = sdminer._state().cooldown_until - 1; env.tick(1)       -- cooldown over (this tick enqueues and sends PULL_BACK)
    local pulled = false
    for _, c in ipairs(env.cmds("m1")) do if c == "PULL_BACK" then pulled = true end end
    truthy(pulled, "PULL_BACK sent to every miner")
    eq(sdminer._state().miners.m1.busy, false); eq(sdminer.status("Ore"), nil)
    env.tick(10)
    truthy(sdminer._state().phase ~= "cleaning", "back to dispatching")
    env.done()
end)

test("miner: manual refresh button (refresh_now) recycles immediately, even during cooldown", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) }, stock = { Ore = 0 }, chest = { [0] = drone(4, 5) } })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(5)
    eq(sdminer._state().phase, "cooldown")
    eq(sdminer.refresh_now(), true)
    env.tick(1)
    local pulled = false
    for _, c in ipairs(env.cmds("m1")) do if c == "PULL_BACK" then pulled = true end end
    truthy(pulled); eq(sdminer._state().miners.m1.busy, false)
    env.done()
end)

test("miner: an unsaturated cycle is refreshed after miner_cooldown seconds", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) }, stock = { Ore = 5000 }, chest = { [0] = drone(4, 5) } })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(5)
    eq(sdminer._state().phase, "dispatch", "nothing to do, miner idle -> keeps watching the stock")
    env.ctx.now = sdminer._state().cycle_started + 301; env.tick(1)
    local pulled = false
    for _, c in ipairs(env.cmds("m1")) do if c == "PULL_BACK" then pulled = true end end
    truthy(pulled, "periodic refresh")
    env.done()
end)

test("miner: stock that drops later triggers an assignment in a following pass", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) }, stock = { Ore = 5000 }, chest = { [0] = drone(4, 5) } })
    env.start(); env.register("m1", "t1")
    env.run_until_dispatch(); env.tick(5)
    eq(sdminer._state().miners.m1.busy, false)
    env.stock.Ore = 100
    env.tick(8)
    eq(sdminer._state().miners.m1.busy, true)
    env.done()
end)

test("miner: stop() removes the listener; the miners are left alone", function()
    local env = miner_env({ items = { miner_item("Ore", 1000) } })
    env.start()
    truthy(listeners.modem_message)
    sdminer.stop()
    eq(listeners.modem_message, nil); eq(sdminer.is_active(), false)
    env.done()
end)

-- ========== miner config validation + page 2 display ==========
test("config: miner entries - defaults, and every invalid field is reported", function()
    cfg_items({
        { name = "a", damage = 0, label = "Min", mode_tag = "miner", target_quantity = 100, distance = 91 },
        { name = "a", damage = 0, label = "NoDist", mode_tag = "miner", target_quantity = 100 },
        { name = "a", damage = 0, label = "NoTarget", mode_tag = "miner", target_quantity = 0, distance = 1 },
        { name = "a", damage = 0, label = "BadWeight", mode_tag = "miner", target_quantity = 5, distance = 1, weight = 0 },
        { name = "a", damage = 0, label = "BadLimit", mode_tag = "miner", target_quantity = 5, distance = 1, limit = 2 },
        { name = "a", damage = 0, label = "BadRange", mode_tag = "miner", target_quantity = 5, distance = 1, min_drone_tier = 6, max_drone_tier = 3 },
        { name = "a", damage = 0, label = "BadMinerTier", mode_tag = "miner", target_quantity = 5, distance = 1, min_miner_tier = 0 },
        { name = "a", damage = 0, label = "Full", mode_tag = "miner", target_quantity = 50, distance = 12.5, weight = 2.5, limit = 1,
          min_miner_tier = 3, min_drone_tier = 4, max_drone_tier = 8 },
    })
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 2); eq(#errs, 6)
    local d = items[1]
    eq(d.mode_tag, "miner"); eq(d.min_miner_tier, 1); eq(d.min_drone_tier, 0); eq(d.max_drone_tier, 99)
    eq(d.weight, 1); eq(d.limit, 0); eq(d.distance, 91); eq(d.target_once, 0)
    local f = items[2]
    eq(f.min_miner_tier, 3); eq(f.min_drone_tier, 4); eq(f.max_drone_tier, 8); eq(f.weight, 2.5); eq(f.limit, 1); eq(f.distance, 12.5)
end)

test("page 2: miner rows show working / missing drones / resident / not enabled, plus the summary line", function()
    local env = miner_env({
        items = { miner_item("Working", 1000, { weight = 5 }), miner_item("Starved", 1000, { min_drone_tier = 20, max_drone_tier = 30 }),
                  miner_item("Resident", 1000, { limit = 1 }), miner_item("Plain", 1000) },
        stock = { Working = 500, Starved = 0, Resident = 9000, Plain = 9000 }, chest = { [0] = drone(4, 30) },
    })
    env.start()
    for i = 1, 5 do env.register("m" .. i, "t1") end
    env.run_until_dispatch(); env.tick(12)
    local ctx = env.ctx
    ctx.gpu = make_gpu()
    sdlogic.render_page2()
    local function row(label)
        for y = 16, 20 do local r = row_text(ctx.gpu, y); if r and r:find(label, 1, true) then return r end end
    end
    truthy(row("Working"):find("開採中 3/3", 1, true), row("Working"))
    truthy(row("Starved"):find("缺無人機", 1, true), row("Starved"))
    truthy(row("Resident"):find("常駐", 1, true), row("Resident"))
    truthy(row("Plain"):find("庫存充裕安全", 1, true))
    local summary = row_text(ctx.gpu, 9)
    truthy(summary:find("礦機 5 台", 1, true), summary)
    truthy(read(ctx.log_file_path):find("Working=8=3=0", 1, true), "log tag 8 = mining")
    truthy(read(ctx.log_file_path):find("Starved=9=", 1, true), "log tag 9 = waiting")
    env.done()
end)

test("page 2: miner item while the module is off -> clear warning, not a crash", function()
    local env = miner_env({ no_transposer = true, items = { miner_item("Ore", 1000) }, stock = { Ore = 0 } })
    env.start()
    local ctx = env.ctx
    ctx.gpu = make_gpu()
    sdlogic.render_page2()
    truthy(row_text(ctx.gpu, 16):find("礦機模組未啟用", 1, true))
    truthy(row_text(ctx.gpu, 9):find("未啟用", 1, true))
    env.done()
end)

test("page 2: no miner items and no miners -> row 9 stays empty", function()
    cfg_items({ restock("Iron") })
    local ctx = make_ctx()
    render(ctx, 5000)
    truthy(row_text(ctx.gpu, 9):match("^%s*$") ~= nil)
end)

-- ========== touch_menu: module wiring ==========
local function load_real_menu(with_database, extra)
    package.loaded.touch_menu = nil
    avail = { modem = true, database = with_database or false }
    listings = { ["6429-gpu"] = "gpu", ["a875-scr"] = "screen" }
    local me_types = { fluid_interface = true, me_interface = true, me_controller = true }
    local me_set = {}
    for addr, spec in pairs(extra or {}) do
        listings[addr] = spec.type
        if me_types[spec.type] then avail[spec.type] = true; rawset(component, spec.type, spec.proxy); me_set[spec.type] = true end
    end
    local gpu = make_gpu()
    local order = {}
    gpu.bind = function() order[#order + 1] = "bind" end
    gpu.setResolution = function() order[#order + 1] = "setResolution" end
    gpu.fill = function() order[#order + 1] = "fill" end
    local saved_proxy = component.proxy
    component.proxy = function(addr)
        if addr == "6429-gpu" then return gpu end
        if extra and extra[addr] then return extra[addr].proxy end
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
        for t in pairs(me_set) do rawset(component, t, nil) end
        avail = { modem = true }; listings = {}
    end
    return ok, menu, gpu, order, cleanup
end

test("touch_menu loads without a database component and binds screen before drawing", function()
    local ok, menu, gpu, order, cleanup = load_real_menu(false)
    truthy(ok, "require failed: " .. tostring(menu))
    menu.config_file_path = TMP_DIR .. "/menu_cfg.json"
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
    eq(menu.realtime_path, nil, "clock settings are gone")
    menu.stop()
    eq(listeners.modem_message, nil, "listener must be removed on stop")
    cleanup()
end)

test("touch_menu: first page is the battery view, and switching to it rescans the batteries", function()
    sdapi._reset_cache()
    local ok, menu, gpu, order, cleanup = load_real_menu(false)
    truthy(ok, "require failed: " .. tostring(menu))
    local bat = fake_battery(LSC, { "EU Stored: 2E9", "Total Capacity: 4E9" })
    local restore_machines = install_machines({ ["a875-bat"] = bat })
    listings["6429-gpu"] = "gpu"; listings["a875-scr"] = "screen"
    local proxy_with_machines = component.proxy
    component.proxy = function(addr) if addr == "6429-gpu" then return gpu end return proxy_with_machines(addr) end
    menu.config_file_path = TMP_DIR .. "/menu_cfg4.json"
    menu.start()
    local text = {}
    for _, st in ipairs(gpu.sets) do text[#text + 1] = st.s end
    local all = table.concat(text, "\n")
    truthy(all:find("電池電量", 1, true), "tab label")
    truthy(all:find("共 1 顆電池", 1, true) and all:find("50.0%", 1, true), "battery rendered on start")
    truthy(not all:find("REALWORLD", 1, true))
    local scans = bat.calls.getName
    menu.handle_touch(40, 4)             -- AE2 page
    menu.handle_touch(10, 4)             -- back to batteries
    truthy(bat.calls.getName > scans, "page switch forces a rescan")
    menu.stop()
    restore_machines()
    cleanup()
end)

test("touch_menu: start() scans the database; the scan button adds items found later", function()
    local ok, menu, gpu, order, cleanup = load_real_menu(true)
    truthy(ok, "require failed: " .. tostring(menu))
    local path = TMP_DIR .. "/menu_cfg2.json"
    os.remove(path); os.remove(path .. ".bak")
    menu.config_file_path = path
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
    menu.config_file_path = path
    menu.start()
    truthy(menu.scan_message and menu.scan_message.color == 0xFF5555, "error colour")
    menu.handle_touch(40, 4); menu.handle_touch(120, 4)
    truthy(menu.scan_message.text:find("失敗", 1, true))
    eq(read(path), "{ broken", "broken file untouched")
    menu.stop()
    cleanup()
end)


test("touch_menu: with a transposer + modem the miner module starts and the button asks for a refresh", function()
    local chest = make_chest({ [0] = drone(4, 3) })
    local ok, menu, gpu, order, cleanup = load_real_menu(false, { ["tp00-xx"] = { type = "transposer", proxy = chest }, ["mo00-xx"] = { type = "modem", proxy = {} } })
    truthy(ok, "require failed: " .. tostring(menu))
    eq(menu.miner_transposer, chest); eq(menu.miner_port, 300); eq(menu.miner_chest_side, 1)
    menu.config_file_path = TMP_DIR .. "/menu_cfg5.json"
    os.remove(menu.config_file_path)
    menu.start()
    eq(sdminer.is_active(), true)
    local opened = false
    for _, o in ipairs(OPENED) do if o.port == 300 then opened = true end end
    truthy(opened)
    menu.handle_touch(40, 4)                      -- AE2 page
    menu.handle_touch(145, 4)                     -- miner re-dispatch button
    truthy(menu.scan_message.text:find("重新分配", 1, true), menu.scan_message.text)
    menu.stop()
    eq(sdminer.is_active(), false)
    cleanup()
end)

test("touch_menu: without a transposer the miner button explains why instead of failing", function()
    local ok, menu, gpu, order, cleanup = load_real_menu(false)
    truthy(ok)
    eq(menu.miner_transposer, nil)
    menu.config_file_path = TMP_DIR .. "/menu_cfg6.json"
    menu.start()
    eq(sdminer.is_active(), false)
    menu.handle_touch(40, 4); menu.handle_touch(145, 4)
    truthy(menu.scan_message.text:find("未啟用", 1, true))
    menu.stop()
    cleanup()
end)


-- ===================== fluids (GTNH 2.9: fluid_interface) =====================
local function fluid_stack(fname, flabel, amount)
    return { name = "NotEnoughItems:neiFluidDisplay", damage = 0, label = "drop of " .. flabel,
             fluid = { amount = amount or 144, id = 3, label = flabel, name = fname } }
end

test("scan: a database fluid becomes a monitor entry keyed by the fluid label, with the registry name", function()
    Main.db = db_with({ [1] = fluid_stack("ic2uumatter", "UU-Matter"), [2] = stack("a:x", 0, "Iron") })
    cfg_items({})
    local n, added = sdlogic.scan_database()
    eq(n, 2); eq(added[1], "UU-Matter")
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0); eq(#items, 2)
    eq(items[1].label, "UU-Matter"); eq(items[1].fluid, "ic2uumatter"); eq(items[1].mode_tag, "monitor")
    eq(items[2].fluid, nil, "plain items have no fluid field")
    eq((sdlogic.scan_database()), 0, "second scan adds nothing")
end)

test("fluid entry: restock/clone/miner are rejected, bad fluid field is an error", function()
    cfg_items({ restock("UU", 10, 1, { fluid = "ic2uumatter" }), entry("Bad", "monitor", { fluid = 5 }),
                entry("OK", "monitor", { fluid = "water" }) })
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 1); eq(items[1].label, "OK"); eq(#errs, 2)
end)

test("count_item: fluids are summed in mB from getFluidsInNetwork by registry name", function()
    local calls = 0
    local ae = { getFluidsInNetwork = function() calls = calls + 1; return {
        { name = "ic2uumatter", label = "UU-Matter", amount = 1000 },
        { name = "ic2uumatter", label = "UU-Matter", amount = 234 },
        { name = "water", label = "Water", amount = 5 },
    } end, getItemsInNetwork = function() error("items must not be queried for a fluid") end }
    eq(sdlogic.count_item({ label = "UU-Matter", fluid = "ic2uumatter" }, ae), 1234)
    eq(sdlogic.count_item({ label = "Nothing", fluid = "nope" }, ae), 0)
    eq(sdlogic.count_item({ label = "Water", fluid = "wrongname" }, ae), 5, "falls back to the label")
    local n, err = sdlogic.count_item({ label = "X", fluid = "x" }, { getItemsInNetwork = function() return {} end })
    eq(n, nil); truthy(err, "an ME component without fluid support gives an error, not 0")
    local n2 = sdlogic.count_item({ label = "X", fluid = "x" }, { getFluidsInNetwork = function() error("boom") end })
    eq(n2, nil)
end)

test("count_item: a single fluid uses getFluidInNetwork({name=}) and falls back to the full list", function()
    local seen
    local ae = { getFluidInNetwork = function(f) seen = f; return { amount = 111, size = 111, label = "UU-Matter", name = "ic2uumatter" } end,
                 getFluidsInNetwork = function() error("full list must not be needed") end }
    eq(sdlogic.count_item({ label = "UU-Matter", fluid = "ic2uumatter" }, ae), 111); eq(seen.name, "ic2uumatter")
    ae.getFluidInNetwork = function() return nil end
    eq(sdlogic.count_item({ label = "UU-Matter", fluid = "ic2uumatter" }, ae), 0, "absent fluid is 0")
    ae.getFluidInNetwork = function() error("not supported") end
    ae.getFluidsInNetwork = function() return { { name = "ic2uumatter", amount = 42 } } end
    eq(sdlogic.count_item({ label = "UU-Matter", fluid = "ic2uumatter" }, ae), 42, "error falls back")
end)

test("query_counts: fluids are fetched with a single call whatever the query mode", function()
    local fcalls, icalls = 0, {}
    local ae = {
        getFluidsInNetwork = function() fcalls = fcalls + 1; return { { name = "f1", label = "F1", amount = 7 }, { name = "f2", label = "F2", amount = 9 } } end,
        getItemsInNetwork = function(filter) icalls[#icalls + 1] = filter and filter.label or "ALL"; return { { label = "Iron", size = 3 } } end,
    }
    local items = { entry("F1", "monitor", { fluid = "f1" }), entry("F2", "monitor", { fluid = "f2" }), entry("Iron", "monitor") }
    for _, mode in ipairs({ "filter", "full", "auto" }) do
        fcalls, icalls = 0, {}
        local counts = sdlogic.query_counts(items, { ae = ae, query_mode = mode })
        eq(counts.F1, 7, mode); eq(counts.F2, 9, mode); eq(counts.Iron, 3, mode); eq(fcalls, 1, mode)
        eq(#icalls, 1, mode)
    end
    local only = sdlogic.query_counts({ items[1] }, { ae = ae, query_mode = "full" })
    eq(only.F1, 7)
    local down = sdlogic.query_counts({ items[1] }, { ae = { getFluidsInNetwork = function() error("x") end }, query_mode = "full" })
    eq(down.F1, nil, "failed fluid query stays nil (shown as ?)")
end)

test("touch_menu picks fluid_interface before me_interface and me_controller", function()
    local fi, mi = { tag = "fi" }, { tag = "mi" }
    local ok, menu, _, _, cleanup = load_real_menu(false, { ["fi00-xx"] = { type = "fluid_interface", proxy = fi }, ["mi00-xx"] = { type = "me_interface", proxy = mi } })
    truthy(ok); eq(menu.ae, fi)
    cleanup()
    local ok2, menu2, _, _, cleanup2 = load_real_menu(false, { ["mi00-xx"] = { type = "me_interface", proxy = mi } })
    truthy(ok2); eq(menu2.ae, mi, "falls back to me_interface on older packs")
    cleanup2()
end)

print(string.format("\n%d passed, %d failed", passed, failed))
return failed
