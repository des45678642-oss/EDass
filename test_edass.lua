-- Unit tests for EDass (OpenComputers). Run under plain Lua 5.3 with mocked OC APIs.
-- Globals expected from the runner: EDASS_DIR (source dir), TMP_DIR (writable dir).

package.path = EDASS_DIR .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
    -- each test starts from clean globals/mocks
    _G.current_global_task = nil
    _G.time_file_path = TMP_DIR .. "/realtime.txt"
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
package.loaded.filesystem = { exists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end return false end }
package.loaded.internet = { request = function() error("no network in tests") end }
package.loaded.event = { timer = function(_, cb) return "timer" end, pull = function() end, cancel = function() end }
package.loaded.term = { clear = function() end }
package.loaded.thread = { create = function(fn) return { kill = function() end } end }

local sdapi = require("sdapi")
local sdlogic = require("sdlogic")

local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end
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
    local ctx = {
        gpu = make_gpu(), SCR_W = 160, SCR_H = 50,
        config_file_path = TMP_DIR .. "/ae_config.txt",
        log_file_path = TMP_DIR .. "/ae_log.txt",
        default_cooldown = 600,
        active_ae_requests = {}, last_order_time = {},
        ae = {
            getItemsInNetwork = function() return {} end,
            getCraftables = function() return { { request = function() return { isDone = function() return false end, isCanceled = function() return false end } end } } end,
        },
        db = make_db({ [1] = { label = "Iron" }, [2] = { label = "鐵錠" }, [3] = { label = "Gold" }, [4] = { label = "Clone A" }, [5] = { label = "Clone B" } }),
        energy_threshold = 50, high_threshold = 60,
    }
    for k, v in pairs(over or {}) do ctx[k] = v end
    return ctx
end

-- ========== sdapi: config parsing ==========
test("config: empty cooldown stays nil so default_cooldown can apply", function()
    write(TMP_DIR .. "/c.txt", "[items]\n1=100=10\n")
    local items = sdapi.load_hybrid_config(TMP_DIR .. "/c.txt", make_db({ [1] = { label = "Iron" } }))
    eq(#items, 1); eq(items[1].name, "Iron"); eq(items[1].min_stock, 100); eq(items[1].req_qty, 10)
    eq(items[1].cooldown, nil, "cooldown"); eq(items[1].priority, 9)
end)

test("config: special mode fields (circuit=cooldown field, priority)", function()
    write(TMP_DIR .. "/c.txt", "[items]\n4=500=0=2=1\n")
    local items = sdapi.load_hybrid_config(TMP_DIR .. "/c.txt", make_db({ [4] = { label = "Clone A" } }))
    eq(items[1].cooldown, 2); eq(items[1].priority, 1); eq(items[1].req_qty, 0)
end)

test("config: skips comments, unknown slots and missing db; parses fluids", function()
    write(TMP_DIR .. "/c.txt", "# note\n[settings]\ntarget_database=x\n[items]\n1=5=5\n9=5=5\n[fluids]\n  water  \n")
    local items, fluids = sdapi.load_hybrid_config(TMP_DIR .. "/c.txt", make_db({ [1] = { label = "Iron" } }))
    eq(#items, 1); eq(#fluids, 1); eq(fluids[1], "water")
    local a, b = sdapi.load_hybrid_config(TMP_DIR .. "/c.txt", nil)
    eq(#a, 0); eq(#b, 0)
    local c = sdapi.load_hybrid_config(TMP_DIR .. "/nope.txt", make_db({}))
    eq(#c, 0)
end)

-- ========== sdapi: clock ==========
test("days in month incl. leap years", function()
    eq(sdapi.get_days_in_month(2, 2024), 29); eq(sdapi.get_days_in_month(2, 2100), 28)
    eq(sdapi.get_days_in_month(2, 2000), 29); eq(sdapi.get_days_in_month(12, 2026), 31)
end)

test("clock tick: second/minute/hour rollover", function()
    write(_G.time_file_path, "date=2026-10-24\ntime=23:59:59\ntype=net\n")
    sdapi.local_tick_time(1)
    local t, d = sdapi.read_saved_time()
    eq(t, "00:00:00"); eq(d, "2026-10-25")
end)

test("clock tick: month and year rollover, leap day", function()
    write(_G.time_file_path, "date=2026-12-31\ntime=23:59:59\n")
    sdapi.local_tick_time(1)
    local t, d = sdapi.read_saved_time(); eq(d, "2027-01-01"); eq(t, "00:00:00")
    write(_G.time_file_path, "date=2024-02-28\ntime=23:59:59\n")
    sdapi.local_tick_time(1)
    t, d = sdapi.read_saved_time(); eq(d, "2024-02-29")
    sdapi.local_tick_time(86400)  -- still within hour<24 carry logic
end)

test("read_saved_time honours _G.time_file_path (was hardcoded)", function()
    write(TMP_DIR .. "/other_time.txt", "date=2030-01-02\ntime=03:04:05\n")
    _G.time_file_path = TMP_DIR .. "/other_time.txt"
    local t, d = sdapi.read_saved_time()
    eq(t, "03:04:05"); eq(d, "2030-01-02")
end)

test("read_saved_time fallback placeholders when file missing", function()
    _G.time_file_path = TMP_DIR .. "/does_not_exist.txt"
    local t, d = sdapi.read_saved_time()
    eq(t, "--:--:--")
end)

test("update_time survives network failure (no throw, file untouched)", function()
    write(_G.time_file_path, "date=2026-01-01\ntime=00:00:00\ntype=calc\n")
    sdapi.update_time()
    truthy(read(_G.time_file_path):find("type=calc", 1, true))
end)

test("update_time parses server HTML (table-style response)", function()
    local chunks = { '<span id="time">12:34:56</span>', '<span id="date">2026-10-24</span>' }
    local i = 0
    package.loaded.internet.request = function()
        return { read = function() i = i + 1; return chunks[i] end }
    end
    write(_G.time_file_path, "")
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
    sdlogic.release_stale_lock({ { name = "Clone A", min_stock = 10, req_qty = 0 } })
    eq(_G.current_global_task, nil); eq(broadcasts[1][2], "STOP_CLONE")
end)

test("stale lock: holder switched to normal restock mode -> released", function()
    _G.current_global_task = "Clone A"
    sdlogic.release_stale_lock({ { name = "Clone A", min_stock = 10, req_qty = 5 } })
    eq(_G.current_global_task, nil)
end)

test("lock kept while holder is still a special-mode item", function()
    broadcasts = {}
    _G.current_global_task = "Clone A"
    sdlogic.release_stale_lock({ { name = "Clone A", min_stock = 10, req_qty = 0 } })
    eq(_G.current_global_task, "Clone A"); eq(#broadcasts, 0)
end)

test("render_page2 with empty config releases a held lock", function()
    write(TMP_DIR .. "/ae_config.txt", "[items]\n")
    _G.current_global_task = "Clone A"
    local ctx = make_ctx()
    sdlogic.render_page2(ctx, sdapi, 10)
    eq(_G.current_global_task, nil)
end)

test("priority pre-emption: lower number wins the lock; satisfied item unlocks", function()
    broadcasts = {}
    write(TMP_DIR .. "/ae_config.txt", "[items]\n4=500=0=2=5\n5=500=0=3=1\n")
    local ctx = make_ctx()
    sdlogic.render_page2(ctx, sdapi, 10)
    eq(_G.current_global_task, "Clone B", "high-priority item should hold the lock")
    -- Clone B reaches target -> lock released, Clone A takes over on next pass
    ctx.ae.getItemsInNetwork = function() return { { label = "Clone B", size = 500 } } end
    sdlogic.render_page2(ctx, sdapi, 20)
    sdlogic.render_page2(ctx, sdapi, 30)
    eq(_G.current_global_task, "Clone A")
    local saw_stop = false
    for _, b in ipairs(broadcasts) do if b[2] == "STOP_CLONE" then saw_stop = true end end
    truthy(saw_stop, "STOP_CLONE not broadcast")
end)

-- ========== sdlogic: restock logic ==========
test("default cooldown (600s) is applied when config leaves it blank", function()
    write(TMP_DIR .. "/ae_config.txt", "[items]\n1=100=10\n")
    local ctx = make_ctx()
    ctx.last_order_time["Iron"] = 100
    sdlogic.render_page2(ctx, sdapi, 110)  -- 10s after the last order
    local row = row_text(ctx.gpu, 16)
    truthy(row, "row rendered")
    truthy(row:find("590", 1, true), "expected 590s remaining, got: " .. row)
    eq(#ctx.ae.getCraftables({}), 1)
end)

test("restock places an order when cooldown elapsed and stock is low", function()
    write(TMP_DIR .. "/ae_config.txt", "[items]\n1=100=10\n")
    local ctx = make_ctx()
    local requested
    ctx.ae.getCraftables = function() return { { request = function(n) requested = n; return { isDone = function() return false end, isCanceled = function() return false end } end } } end
    sdlogic.render_page2(ctx, sdapi, 5000)
    eq(requested, 10)
    truthy(ctx.active_ae_requests["Iron"])
    truthy(read(ctx.log_file_path):find("Iron=1=0=0", 1, true))
end)

test("no order when stock >= min_stock", function()
    write(TMP_DIR .. "/ae_config.txt", "[items]\n1=100=10\n")
    local ctx = make_ctx()
    ctx.ae.getItemsInNetwork = function() return { { label = "Iron", size = 500 } } end
    local called = false
    ctx.ae.getCraftables = function() called = true; return {} end
    sdlogic.render_page2(ctx, sdapi, 5000)
    eq(called, false)
end)

test("render rows stay on screen (no writes below SCR_H)", function()
    local lines = { "[items]" }
    local slots = {}
    for i = 1, 60 do lines[#lines + 1] = i .. "=1=1"; slots[i] = { label = "Item" .. i } end
    write(TMP_DIR .. "/ae_config.txt", table.concat(lines, "\n") .. "\n")
    local ctx = make_ctx({ db = make_db(slots) })
    sdlogic.render_page2(ctx, sdapi, 5000)
    for _, s in ipairs(ctx.gpu.sets) do truthy(s.y <= 50, "write at row " .. s.y) end
end)

test("rows with CJK names keep fixed column layout", function()
    write(TMP_DIR .. "/ae_config.txt", "[items]\n1=100=10\n2=100=10\n")
    local ctx = make_ctx()
    ctx.last_order_time.Iron = 5000; ctx.last_order_time["鐵錠"] = 5000
    sdlogic.render_page2(ctx, sdapi, 5001)
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
    sdlogic.check_battery_and_play(ctx)
    eq(plays, 1, "plays immediately on alert")
    for _ = 1, 11 do sdlogic.check_battery_and_play(ctx) end   -- 55s more: not yet 60
    eq(plays, 1)
    sdlogic.check_battery_and_play(ctx)                          -- 60s
    eq(plays, 2)
    ctx.battery = battery(65)
    sdlogic.check_battery_and_play(ctx)
    eq(stops, 1); eq(_G.is_low_power_alert, false)
end)

test("battery between thresholds keeps previous state (hysteresis)", function()
    _G.is_low_power_alert, _G.jukebox_loop_counter = false, 0
    local plays = 0
    local ctx = make_ctx({ battery = battery(55), jukebox = { play = function() plays = plays + 1 end, stop = function() end } })
    sdlogic.check_battery_and_play(ctx)
    eq(plays, 0)
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
    menu.stop()
    component.proxy = function(addr) return { address = addr } end
    rawset(component, "gpu", nil)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
return failed
