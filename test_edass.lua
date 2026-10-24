-- Unit tests for EDass (OpenComputers). Run under plain Lua 5.3 with mocked OC APIs.
-- Globals expected from the runner: EDASS_DIR (source dir), TMP_DIR (writable dir).

package.path = EDASS_DIR .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
    -- each test starts from clean globals/mocks
    _G.current_global_task = nil
    Main = {
        realtime_path = TMP_DIR .. "/realtime.txt",
        config_file_path = TMP_DIR .. "/ae_config.json",
        log_file_path = TMP_DIR .. "/ae_log.txt",
        default_cooldown = 600, SCR_W = 160, SCR_H = 50,
        items_per_page = 35, list_page = 1, list_pages = 1,
        query_port = 102, relay_port = 100,
        active_ae_requests = {}, last_order_time = {},
        energy_threshold = 50, high_threshold = 60,
        now = 0, pager_draws = 0,
    }
    Main.get_now_time = function() return Main.now end
    Main.draw_pager = function() Main.pager_draws = Main.pager_draws + 1 end
    package.loaded.touch_menu = Main
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

local function write(path, text)
    local f = assert(io.open(path, "w")); f:write(text); f:close()
    mtimes[path] = (mtimes[path] or 0) + 1
end
local function cfg(json_text) write(TMP_DIR .. "/ae_config.json", json_text) end
local function read(path) local f = assert(io.open(path, "r")); local t = f:read("a"); f:close(); return t end

local function make_gpu()
    local g = { sets = {}, calls = {}, fg = 0 }
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

local function make_ctx(over)
    local ctx = Main
    ctx.gpu = make_gpu()
    ctx.ae = {
        getItemsInNetwork = function() return {} end,
        getCraftables = function() return { { request = function() return { isDone = function() return false end, isCanceled = function() return false end } end } } end,
    }
    ctx.db = make_db({ [1] = { label = "Iron" }, [2] = { label = "鐵錠" }, [3] = { label = "Gold" }, [4] = { label = "Clone A" }, [5] = { label = "Clone B" } })
    for k, v in pairs(over or {}) do ctx[k] = v end
    return ctx
end

local function render(ctx, now) ctx.now = now; sdlogic.render_page2() end
local function load_cfg(path, db) Main.config_file_path = path; Main.db = db; return sdapi.load_hybrid_config() end

-- ========== sdjson ==========
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

-- ========== sdlogic: config loading (JSON) ==========
local function sample_db()
    return make_db({
        [1] = { name = "minecraft:iron_ingot", damage = 0, label = "Iron" },
        [2] = { name = "mod:ingot", damage = 5, label = "鐵錠" },
        [4] = { name = "mod:a", damage = 0, label = "Clone A" },
        [5] = { name = "mod:b", damage = 0, label = "Clone B" },
    })
end

test("config: fields resolved from database.get; blank cooldown stays nil", function()
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
    Main.db = sample_db()
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0); eq(#items, 1)
    local it = items[1]
    eq(it.slot, 1); eq(it.name, "minecraft:iron_ingot"); eq(it.damage, 0); eq(it.label, "Iron")
    eq(it.target_quantity, 100); eq(it.target_once, 10); eq(it.cooldown, nil); eq(it.mode_tag, "restock")
end)

test("config: clone mode needs circuit; priority defaults to 9", function()
    cfg('{"items":[{"slot":4,"mode_tag":"clone","target_quantity":500,"circuit":2,"priority":1},{"slot":5,"mode_tag":"clone","target_quantity":5,"circuit":24}]}')
    Main.db = sample_db()
    local items, errs = sdlogic.load_hybrid_config()
    eq(#errs, 0)
    eq(items[1].circuit, 2); eq(items[1].priority, 1); eq(items[1].target_once, 0)
    eq(items[2].priority, 9)
end)

test("config: bad entries are skipped with an error, good ones still load", function()
    cfg([[{"items":[
        {"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10},
        {"slot":"x","mode_tag":"restock"},
        {"slot":2,"mode_tag":"bogus","target_quantity":1},
        {"slot":2,"mode_tag":"restock","target_quantity":1},
        {"slot":2,"mode_tag":"restock","target_quantity":-5,"target_once":1},
        {"slot":2,"mode_tag":"restock","target_quantity":5,"target_once":1,"cooldown":"fast"},
        {"slot":4,"mode_tag":"clone","target_quantity":5},
        {"slot":4,"mode_tag":"clone","target_quantity":5,"circuit":99},
        {"slot":5,"mode_tag":"clone","target_quantity":5,"circuit":1,"priority":12},
        {"slot":77,"mode_tag":"monitor"},
        7, null,
        {"slot":2,"mode_tag":"monitor"}
    ]}]])
    Main.db = sample_db()
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 2); eq(items[1].label, "Iron"); eq(items[2].label, "鐵錠")
    eq(#errs, 11)
    for _, e in ipairs(errs) do truthy(type(e) == "string" and e ~= "") end
end)

test("config: missing file / invalid JSON / no database / wrong shape are reported, not thrown", function()
    Main.db = sample_db()
    Main.config_file_path = TMP_DIR .. "/nope.json"
    local items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); eq(#errs, 1)
    Main.config_file_path = TMP_DIR .. "/ae_config.json"
    cfg('{"items": [ oops ]}')
    items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); truthy(errs[1]:find("JSON", 1, true))
    cfg('[1,2]')
    items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); truthy(errs[1]:find("items", 1, true))
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"}]}')
    Main.db = nil
    items, errs = sdlogic.load_hybrid_config(); eq(#items, 0); truthy(errs[1]:find("database", 1, true))
end)

test("config: file that goes bad keeps the last good config (and says so)", function()
    Main.db = sample_db()
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"}]}')
    local items = sdlogic.load_hybrid_config(); eq(#items, 1)
    cfg('{"items":[{"slot":1,')                     -- half-saved file
    local items2, errs = sdlogic.load_hybrid_config()
    eq(#items2, 1, "last good config kept"); eq(#errs, 1)
end)

test("config: unchanged file is not re-parsed (lastModified cache)", function()
    Main.db = sample_db()
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"}]}')
    eq(#sdlogic.load_hybrid_config(), 1)
    local f = assert(io.open(Main.config_file_path, "w")); f:write('{"items":[]}'); f:close()  -- no mtime bump
    eq(#sdlogic.load_hybrid_config(), 1, "cached")
    cfg('{"items":[]}')
    eq(#sdlogic.load_hybrid_config(), 0, "re-read after mtime change")
end)

test("config: database slot emptied after config load -> error entry, others fine", function()
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"},{"slot":2,"mode_tag":"monitor"}]}')
    Main.db = sample_db()
    eq(#sdlogic.load_hybrid_config(), 2)
    Main.db = make_db({ [1] = { name = "x", damage = 0, label = "Iron" } })
    local items, errs = sdlogic.load_hybrid_config()
    eq(#items, 1); eq(#errs, 1); truthy(errs[1]:find("2", 1, true))
end)

test("config: json 'database' address prefix selects the database component", function()
    avail.database = nil
    local special = make_db({ [1] = { name = "n", damage = 0, label = "FromSpecial" } })
    listings = { ["9ee0-db"] = "database" }
    local saved = component.proxy
    component.proxy = function(addr) if addr == "9ee0-db" then return special end return { address = addr } end
    cfg('{"database":"9EE0","items":[{"slot":1,"mode_tag":"monitor"}]}')
    Main.db = sample_db()
    local items = sdlogic.load_hybrid_config()
    eq(items[1].label, "FromSpecial")
    cfg('{"database":"zzzz","items":[{"slot":1,"mode_tag":"monitor"}]}')
    items = sdlogic.load_hybrid_config()
    eq(items[1].label, "Iron", "unknown prefix falls back to the main program's db")
    component.proxy = saved; listings = {}
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
    sdapi.local_tick_time(86400)  -- still within hour<24 carry logic
end)

test("read_saved_time honours Main.realtime_path (was hardcoded)", function()
    write(TMP_DIR .. "/other_time.txt", "date=2030-01-02\ntime=03:04:05\n")
    Main.realtime_path = TMP_DIR .. "/other_time.txt"
    local t, d = sdapi.read_saved_time()
    eq(t, "03:04:05"); eq(d, "2030-01-02")
end)

test("read_saved_time fallback placeholders when file missing", function()
    Main.realtime_path = TMP_DIR .. "/does_not_exist.txt"
    local t, d = sdapi.read_saved_time()
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
    _G.current_global_task = "Removed"
    sdlogic.release_stale_lock({ { label = "Clone A", mode_tag = "clone" } })
    eq(_G.current_global_task, nil); eq(broadcasts[1][2], "STOP_CLONE")
end)

test("stale lock: holder switched to normal restock mode -> released", function()
    _G.current_global_task = "Clone A"
    sdlogic.release_stale_lock({ { label = "Clone A", mode_tag = "restock" } })
    eq(_G.current_global_task, nil)
end)

test("lock kept while holder is still a special-mode item", function()
    broadcasts = {}
    _G.current_global_task = "Clone A"
    sdlogic.release_stale_lock({ { label = "Clone A", mode_tag = "clone" } })
    eq(_G.current_global_task, "Clone A"); eq(#broadcasts, 0)
end)

test("render_page2 with empty config releases a held lock", function()
    cfg('{"items":[]}')
    _G.current_global_task = "Clone A"
    local ctx = make_ctx()
    render(ctx, 10)
    eq(_G.current_global_task, nil)
end)

test("priority pre-emption: lower number wins the lock; satisfied item unlocks", function()
    broadcasts = {}
    cfg('{"items":[{"slot":4,"mode_tag":"clone","target_quantity":500,"circuit":2,"priority":5},{"slot":5,"mode_tag":"clone","target_quantity":500,"circuit":3,"priority":1}]}')
    local ctx = make_ctx()
    render(ctx, 10)
    eq(_G.current_global_task, "Clone B", "high-priority item should hold the lock")
    -- Clone B reaches target -> lock released, Clone A takes over on next pass
    ctx.ae.getItemsInNetwork = function() return { { label = "Clone B", size = 500 } } end
    render(ctx, 20)
    render(ctx, 30)
    eq(_G.current_global_task, "Clone A")
    local saw_stop = false
    for _, b in ipairs(broadcasts) do if b[2] == "STOP_CLONE" then saw_stop = true end end
    truthy(saw_stop, "STOP_CLONE not broadcast")
end)

-- ========== sdlogic: restock logic ==========
test("default cooldown (600s) is applied when config leaves it blank", function()
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
    local ctx = make_ctx()
    ctx.last_order_time["Iron"] = 100
    render(ctx, 110)  -- 10s after the last order
    local row = row_text(ctx.gpu, 16)
    truthy(row, "row rendered")
    truthy(row:find("590", 1, true), "expected 590s remaining, got: " .. row)
    eq(#ctx.ae.getCraftables({}), 1)
end)

test("restock places an order when cooldown elapsed and stock is low", function()
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
    local ctx = make_ctx()
    local requested
    ctx.ae.getCraftables = function() return { { request = function(n) requested = n; return { isDone = function() return false end, isCanceled = function() return false end } end } } end
    render(ctx, 5000)
    eq(requested, 10)
    truthy(ctx.active_ae_requests["Iron"])
    truthy(read(ctx.log_file_path):find("Iron=1=0=0", 1, true))
end)

test("no order when stock >= target_quantity", function()
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 500 } } end
    local called = false
    ctx.ae.getCraftables = function() called = true; return {} end
    render(ctx, 5000)
    eq(called, false)
end)

test("AE query failure is NOT treated as 0 stock (no order, error status, log tag 7)", function()
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
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
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"}]}')
    local ctx = make_ctx()
    local called = false
    ctx.ae.getCraftables = function() called = true; return {} end
    render(ctx, 5000)
    eq(called, false); eq(_G.current_global_task, nil)
    truthy(read(ctx.log_file_path):find("Iron=0=0=0", 1, true))
end)

test("config errors are shown on row 12 and the valid items still render", function()
    cfg('{"items":[{"slot":1,"mode_tag":"monitor"},{"slot":"bad","mode_tag":"monitor"}]}')
    local ctx = make_ctx()
    render(ctx, 5000)
    local msg
    for _, st in ipairs(ctx.gpu.sets) do if st.y == 12 and st.s:find("slot", 1, true) then msg = st.s end end
    truthy(msg, "error line on row 12")
    truthy(row_text(ctx.gpu, 16):find("Iron", 1, true))
end)

test("restock mode only takes the clone path when mode_tag is clone", function()
    cfg('{"items":[{"slot":4,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
    local ctx = make_ctx()
    render(ctx, 5000)
    eq(_G.current_global_task, nil)
end)

test("render rows stay on screen (no writes below SCR_H)", function()
    local rows, slots = {}, {}
    for i = 1, 60 do
        rows[#rows + 1] = '{"slot":' .. i .. ',"mode_tag":"restock","target_quantity":1,"target_once":1}'
        slots[i] = { label = "Item" .. i }
    end
    cfg('{"items":[' .. table.concat(rows, ",") .. ']}')
    local ctx = make_ctx({ db = make_db(slots) })
    render(ctx, 5000)
    for _, s in ipairs(ctx.gpu.sets) do truthy(s.y <= 50, "write at row " .. s.y) end
end)

test("rows with CJK names keep fixed column layout", function()
    cfg('{"items":[{"slot":1,"mode_tag":"restock","target_quantity":100,"target_once":10},{"slot":2,"mode_tag":"restock","target_quantity":100,"target_once":10}]}')
    local ctx = make_ctx()
    ctx.last_order_time.Iron = 5000; ctx.last_order_time["鐵錠"] = 5000
    render(ctx, 5001)
    local a, b = row_text(ctx.gpu, 16), row_text(ctx.gpu, 17)
    eq(utf8.len(a), utf8.len(b), "rows must have equal character width")
end)

-- ========== sdlogic: battery / jukebox ==========
local function battery(pct)
    return { getSensorInformation = function() return { "Used Capacity: " .. pct .. "%" } end }
end
test("low battery starts jukebox via ctx.jukebox; recovery stops it", function()
    _G.is_low_power_alert, _G.jukebox_loop_counter = nil, nil
    local plays, stops = 0, 0
    local ctx = make_ctx({ battery = battery(30), jukebox = { play = function() plays = plays + 1 end, stop = function() stops = stops + 1 end } })
    sdlogic.check_battery_and_play()
    eq(plays, 1, "plays immediately on alert")
    for _ = 1, 11 do sdlogic.check_battery_and_play() end   -- 55s more: not yet 60
    eq(plays, 1)
    sdlogic.check_battery_and_play()                          -- 60s
    eq(plays, 2)
    ctx.battery = battery(65)
    sdlogic.check_battery_and_play()
    eq(stops, 1); eq(_G.is_low_power_alert, false)
end)

test("battery between thresholds keeps previous state (hysteresis)", function()
    _G.is_low_power_alert, _G.jukebox_loop_counter = false, 0
    local plays = 0
    local ctx = make_ctx({ battery = battery(55), jukebox = { play = function() plays = plays + 1 end, stop = function() end } })
    sdlogic.check_battery_and_play()
    eq(plays, 0)
end)


-- ========== paging (page 2 item list) ==========
local function many_items(n)
    local rows, slots = {}, {}
    for i = 1, n do
        rows[#rows + 1] = '{"slot":' .. i .. ',"mode_tag":"restock","target_quantity":1,"target_once":1}'
        slots[i] = { label = "Item" .. i }
    end
    cfg('{"items":[' .. table.concat(rows, ",") .. ']}')
    return slots
end

test("paging: page 1 shows items 1-35, all items still processed", function()
    local ctx = make_ctx({ db = make_db(many_items(40)) })
    render(ctx, 5000)
    eq(ctx.list_pages, 2); eq(ctx.list_page, 1)
    truthy(row_text(ctx.gpu, 16):find("Item1 ", 1, true), "row 16 = item 1")
    truthy(row_text(ctx.gpu, 50):find("Item35", 1, true), "row 50 = item 35")
    for _, s in ipairs(ctx.gpu.sets) do truthy(not s.s:find("Item36", 1, true), "item 36 leaked onto page 1") end
    local log = read(ctx.log_file_path)
    local n = 0; for _ in log:gmatch("[^\n]+") do n = n + 1 end
    eq(n, 40, "all 40 items must still be tracked/ordered")
    truthy(ctx.pager_draws >= 1)
end)

test("paging: page 2 shows the remaining items starting at row 16", function()
    local ctx = make_ctx({ db = make_db(many_items(40)) })
    ctx.list_page = 2
    render(ctx, 5000)
    truthy(row_text(ctx.gpu, 16):find("Item36", 1, true), "row 16 = item 36")
    truthy(row_text(ctx.gpu, 20):find("Item40", 1, true), "row 20 = item 40")
    truthy(row_text(ctx.gpu, 21) == nil, "no row beyond item 40")
    truthy(row_text(ctx.gpu, 16):find("[36]", 1, true), "index number keeps global numbering")
end)

test("paging: out-of-range page is clamped when the list shrinks", function()
    local ctx = make_ctx({ db = make_db(many_items(10)) })
    ctx.list_page = 3
    render(ctx, 5000)
    eq(ctx.list_page, 1); eq(ctx.list_pages, 1)
end)

-- ========== sdquery (remote AE2 queries) ==========
local function fake_modem()
    local m = { sent = {} }
    function m.send(...) m.sent[#m.sent + 1] = { ... } end
    return m
end
local sdquery = require("sdquery")

test("query: returns AE count for a database slot", function()
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 100 }, { label = "Iron", size = 23 }, { label = "Gold", size = 9 } } end
    local modem = fake_modem()
    sdquery.process(modem, "r1", "UUID-X", 777, "1,3")
    eq(#modem.sent, 3)
    local a = modem.sent[1]
    eq(a[1], "UUID-X"); eq(a[2], 777); eq(a[3], "AE_QUERY_REPLY"); eq(a[4], "r1")
    eq(a[5], 1); eq(a[6], true); eq(a[7], "Iron"); eq(a[8], 123)
    eq(modem.sent[2][8], 9)
    eq(modem.sent[3][3], "AE_QUERY_DONE"); eq(modem.sent[3][5], 2)
end)

test("query: empty database slot and bad slot report an error, not a crash", function()
    local ctx = make_ctx()
    local modem = fake_modem()
    sdquery.process(modem, "r2", "UUID-X", 777, "99")
    eq(modem.sent[1][6], false); truthy(modem.sent[1][7]:find("空", 1, true)); eq(modem.sent[1][8], 0)
    ctx.db = { get = function() error("bad slot") end }
    modem.sent = {}
    sdquery.process(modem, "r3", "UUID-X", 777, "1")
    eq(modem.sent[1][6], false)
end)

test("query: no ME controller -> error reply", function()
    local ctx = make_ctx(); ctx.ae = nil
    local modem = fake_modem()
    sdquery.process(modem, "r4", "UUID-X", 777, "1")
    eq(modem.sent[1][6], false)
end)

test("query: reply goes through server.lua FORWARD_CMD when relay uuid given", function()
    local ctx = make_ctx()
    local modem = fake_modem()
    sdquery.process(modem, "r5", "ASKER", 555, "1", "RELAY")
    local a = modem.sent[1]
    eq(a[1], "RELAY"); eq(a[2], 100); eq(a[3], "FORWARD_CMD"); eq(a[4], "ASKER"); eq(a[5], 555); eq(a[6], "AE_QUERY_REPLY")
end)

test("query: accepts a numeric slot and caps request size", function()
    make_ctx()
    local modem = fake_modem()
    sdquery.process(modem, "r6", "A", 1, 1)
    eq(#modem.sent, 2)
    local many = {}; for i = 1, 200 do many[i] = i end
    modem.sent = {}
    sdquery.process(modem, "r7", "A", 1, table.concat(many, ","))
    eq(#modem.sent, 61)  -- 60 slots + DONE
end)

test("query: modem_message handler ignores other ports/messages, answers AE_QUERY", function()
    make_ctx()
    local modem = fake_modem()
    local saved = component.proxy
    component.proxy = function() return modem end
    sdquery._on_modem_message("modem_message", "L", "R", 999, 0, "AE_QUERY", "x", "A", 1, "1")
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "OTHER", "x", "A", 1, "1")
    eq(#modem.sent, 0)
    sdquery._on_modem_message("modem_message", "L", "R", 102, 0, "AE_QUERY", "x", "A", 1, "1")
    eq(#modem.sent, 2)
    component.proxy = saved
end)

-- ========== touch_menu: module wiring ==========
test("touch_menu loads without a database component and binds screen before drawing", function()
    package.loaded.touch_menu = nil
    avail = { modem = true, me_controller = false }
    listings = { ["6429-gpu"] = "gpu", ["a875-scr"] = "screen" }
    local gpu = make_gpu()
    gpu.getResolution = function() return 160, 50 end
    local binds = {}
    component.proxy = function(addr)
        if addr == "6429-gpu" then return gpu end
        return { address = addr }
    end
    rawset(component, "gpu", gpu)
    -- flatten gpu calls order
    local order = {}
    gpu.bind = function() order[#order + 1] = "bind" end
    gpu.setResolution = function() order[#order + 1] = "setResolution" end
    gpu.fill = function() order[#order + 1] = "fill" end
    local ok, menu = pcall(require, "touch_menu")
    truthy(ok, "require failed: " .. tostring(menu))
    local started = menu.start()
    eq(started, true)
    eq(order[1], "bind", "bind must precede any drawing")
    -- AE2 query listener registered by start()
    truthy(listeners.modem_message, "query listener not registered")
    -- page-2 pager buttons
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
    menu.handle_touch(10, 4)             -- back to page 1 tab, then no pager
    menu.handle_touch(85, 4)
    eq(menu.list_page, 1, "pager must be inactive on the clock page / reset on switch")
    -- sub-modules read the main program's parameters directly
    eq(menu.query_port, 102); eq(menu.items_per_page, 35); truthy(menu.get_now_time)
    menu.stop()
    eq(listeners.modem_message, nil, "listener must be removed on stop")
    component.proxy = function(addr) return { address = addr } end
    rawset(component, "gpu", nil)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
return failed
