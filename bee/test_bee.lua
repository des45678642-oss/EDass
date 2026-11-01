-- Unit tests for the bee/ programs. Plain Lua 5.3 with mocked OpenComputers APIs.
-- Globals from the runner: BEE_DIR (source dir), TMP_DIR (writable dir).
package.path = BEE_DIR .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS  " .. name)
    else failed = failed + 1; print("FAIL  " .. name); print("      " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end
local function contains(s, sub, msg)
    if not tostring(s):find(sub, 1, true) then error((msg or "contains") .. ": '" .. tostring(sub) .. "' not in '" .. tostring(s) .. "'", 2) end
end
local function write(path, text) local f = assert(io.open(path, "wb")); f:write(text); f:close() end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local t = f:read("*a"); f:close(); return t end

local store = require("beeStore")
local beeUtil = require("beeUtil")
local environment = require("environment")

-- ---------------------------------------------------------------- base64 / store
test("base64 round-trips every byte value and every length", function()
    local all = {}
    for i = 0, 255 do all[#all + 1] = string.char(i) end
    local s = table.concat(all)
    for n = 0, 9 do
        local piece = s:sub(1, n)
        eq(store.b64decode(store.b64encode(piece)), piece, "len " .. n)
    end
    eq(store.b64decode(store.b64encode(s)), s)
    eq(store.b64encode("Man"), "TWFu"); eq(store.b64encode("Ma"), "TWE="); eq(store.b64encode("M"), "TQ==")
    eq((store.b64decode("abc")), nil); eq((store.b64decode("a=bc")), nil); eq((store.b64decode("ab!d")), nil)
end)

local real_tags = {
    assistantDroneTag = "\31\139\8\0\0\0\0\0\0\255\r\n\0\1\2\"\\ \200\255",
    assistantPrincessTag = "\0\0\0",
    usingPrincessTag = "plain",
}

test("store: encode/decode keeps the binary tags byte for byte and writes valid JSON", function()
    local data = { initialized = true, speedLevel = 8 }
    for k, v in pairs(real_tags) do data[k] = v end
    local text = assert(store.encode(data))
    truthy(not text:find("[\128-\255]"), "no raw high bytes in the file")
    local back = assert(store.decode(text))
    eq(back.initialized, true); eq(back.speedLevel, 8)
    for k, v in pairs(real_tags) do eq(back[k], v, k) end
end)

test("store: the real old data.txt content converts to JSON and back unchanged", function()
    local old = read(BEE_DIR .. "/data.txt")
    if not old then return end
    local chunk = assert(load("return " .. old, "=data", "t", {}))
    local data = chunk()
    local back = assert(store.decode(assert(store.encode(data))))
    for _, f in ipairs(store.TAG_FIELDS) do eq(back[f], data[f], f) end
    eq(back.speedLevel, data.speedLevel); eq(back.initialized, data.initialized)
end)

test("store: bad documents are rejected with a message", function()
    local d, e = store.decode("{ broken"); eq(d, nil); truthy(e)
    eq((store.decode("[1,2]")), nil)
    eq((store.decode('{"assistantDroneTag": 5}')), nil)
    eq((store.decode('{"assistantDroneTag": "###"}')), nil)
    eq((store.decode('{"initialized": "yes"}')), nil)
    eq((store.decode('{"speedLevel": "fast"}')), nil)
end)

test("store: save is atomic, load reads it back, corrupt file is reported not replaced", function()
    local path = TMP_DIR .. "/bee_data.json"
    os.remove(path)
    eq(store.load(path), nil, "missing file")
    local data = { initialized = false, usingPrincessTag = real_tags.assistantDroneTag }
    assert(store.save(path, data))
    eq(read(path .. ".tmp"), nil, "no leftover temp file")
    local back, source = store.load(path)
    eq(source, "json"); eq(back.usingPrincessTag, real_tags.assistantDroneTag)
    data.speedLevel = 3
    assert(store.save(path, data))
    eq(store.load(path).speedLevel, 3)
    write(path, "{ \"initialized\": ")
    local nothing, err = store.load(path)
    eq(nothing, nil); contains(err, path)
    eq(read(path), "{ \"initialized\": ", "corrupt file untouched")
end)

test("store: legacy data.txt is used when there is no data.json", function()
    local path, legacy = TMP_DIR .. "/bee_data2.json", TMP_DIR .. "/bee_data2.txt"
    os.remove(path)
    write(legacy, '{initialized=true,speedLevel=5,usingPrincessTag="a\\0b"}')
    local unserialize = function(text) return assert(load("return " .. text, "=d", "t", {}))() end
    local data, source = store.load(path, legacy, unserialize)
    eq(source, "legacy"); eq(data.speedLevel, 5); eq(data.usingPrincessTag, "a\0b")
    write(legacy, "garbage((")
    eq(store.load(path, legacy, unserialize), nil, "unreadable legacy file is ignored")
end)

-- ---------------------------------------------------------------- beeData (JSON persistence through the real module)
local function pair(a, b) return { a, b == nil and a or b } end
local function make_bee(kind, over)
    local bee = { type = kind, name = kind == "beeDrone" and "Forestry:beeDroneGE" or "Forestry:beePrincessGE", size = 1, isNatural = true,
        species = pair("forestry.speciesCultivated"), speed = pair(5), lifespan = pair(1), fertility = pair(4), flowering = pair(1),
        flowerProvider = pair("extrabees.flower.rock"), territory = pair(1), effect = pair("forestry.effectNone"),
        temperatureTolerance = pair("BOTH_5"), humidityTolerance = pair("BOTH_5"), nocturnal = pair(true),
        tolerantFlyer = pair(true), caveDwelling = pair(true), tag = "TAG" }
    for k, v in pairs(over or {}) do bee[k] = v end
    return bee
end

test("beeData: updates go to data.json (tags as base64) and survive a reload with identical bytes", function()
    local path = TMP_DIR .. "/bee_data3.json"
    os.remove(path); os.remove(path .. ".bak")
    _G.BEE_DATA_PATH, _G.BEE_LEGACY_PATH = path, TMP_DIR .. "/nonexistent.txt"
    local bot = { inventory = {}, checkItem = function() return 1 end }
    package.loaded.component = { database = {}, upgrade_me = {}, inventory_controller = {} }
    package.loaded.bot = bot
    package.loaded.analyzeGenes = function() error("unused") end
    package.loaded.doUntil = function(f) return f() end
    package.loaded.serialization = { unserialize = function() return nil end }
    package.loaded.beeData = nil
    local beeData = require("beeData")
    eq(beeData.initialized, false)
    truthy(read(path), "fresh data.json is created")
    bot.inventory[3] = make_bee("beeDrone", { tag = real_tags.assistantDroneTag })
    local updated = beeData.updateAssistantDrone(3)
    eq(updated, true); eq(beeData.initialized, true, "homozygous Cultivated drone completes initialization")
    local text = read(path)
    truthy(not text:find("[\128-\255]"), "file holds no raw bytes")
    package.loaded.beeData = nil
    local again = require("beeData")
    eq(again.initialized, true)
    local droneTag = again.getAssistantBeesTag()
    eq(droneTag, real_tags.assistantDroneTag, "tag bytes identical after reload")
    -- a corrupt data.json must stop the program instead of silently re-initialising
    write(path, "{ nope")
    package.loaded.beeData = nil
    local ok, err = pcall(require, "beeData")
    eq(ok, false); contains(err, "無法解析")
    eq(read(path), "{ nope")
    _G.BEE_DATA_PATH, _G.BEE_LEGACY_PATH = nil, nil
    package.loaded.beeData = nil
end)

-- ---------------------------------------------------------------- beeUtil
test("beeUtil: compare list leaves out flowerProvider and effect only", function()
    local list = beeUtil.compareChromosomes()
    eq(#list, 11)
    for _, c in ipairs(list) do truthy(c ~= "flowerProvider" and c ~= "effect") end
end)

test("beeUtil: purity and template matching ignore flowerProvider/effect", function()
    local bee = make_bee("beeDrone", { flowerProvider = { "a", "b" }, effect = { "forestry.effectGlacial", "forestry.effectNone" } })
    truthy(beeUtil.isHomozygous(bee))
    bee.speed = { 5, 6 }
    eq(beeUtil.isHomozygous(bee), false)
    local tpl = { species = "forestry.speciesCultivated", fertility = 4, flowerProvider = "zzz", effect = "forestry.effectGlacial" }
    truthy(beeUtil.matchesTemplate(make_bee("beeDrone"), tpl))
    eq(beeUtil.matchesTemplate(make_bee("beeDrone", { fertility = pair(3) }), tpl), false)
end)

test("beeUtil: effect wash is needed unless every given bee is pure effectNone", function()
    local none, glacial = make_bee("beeDrone"), make_bee("beeDrone", { effect = { "forestry.effectNone", "forestry.effectGlacial" } })
    eq(beeUtil.needsEffectWash(none, none), false)
    eq(beeUtil.needsEffectWash(none, glacial), true)
    eq(beeUtil.needsEffectWash(glacial, none), true)
end)

test("beeUtil: classifyAdopted finds finished bees by kind", function()
    local t1 = { species = "forestry.speciesWintry", speed = 2, nocturnal = false }
    local t2 = { species = "extrabees.species.rock", speed = 2, nocturnal = true }
    local inv = {
        [2] = make_bee("beeDrone", { species = pair("forestry.speciesCommon") }),
        [4] = make_bee("beeDrone", { species = pair("forestry.speciesCultivated"), speed = { 5, 6 } }),
        [5] = make_bee("beeDrone", { species = pair("extrabees.species.rock"), speed = pair(2) }),
        [6] = make_bee("beePrincess", { species = pair("forestry.speciesCultivated") }),
        [7] = make_bee("beeDrone", { species = pair("forestry.speciesCultivated") }),
    }
    local found = beeUtil.classifyAdopted(inv, { t1, t2 })
    eq(found.common, 2); eq(found.template2, 5); eq(found.cultivated, 7, "hybrid slot 4 and princess 6 are not accepted")
    eq(found.template1, nil)
end)

test("beeUtil: pickPurifyInputs chooses species, purest drone and a princess", function()
    local inv = {
        [1] = make_bee("beeDrone", { species = pair("a"), size = 5 }),
        [2] = make_bee("beeDrone", { species = pair("b"), size = 9 }),
        [3] = make_bee("beeDrone", { species = pair("b"), size = 3, speed = { 1, 2 } }),
        [4] = make_bee("beePrincess", { species = pair("a") }),
        [5] = make_bee("beePrincess", { species = pair("b") }),
    }
    local species, princess, drone = beeUtil.pickPurifyInputs(inv, nil)
    eq(species, "b"); eq(drone, 2, "purer stack wins"); eq(princess, 5, "princess carrying the species")
    species, princess, drone = beeUtil.pickPurifyInputs(inv, "a")
    eq(species, "a"); eq(drone, 1); eq(princess, 4)
    local none, msg = beeUtil.pickPurifyInputs(inv, "zzz"); eq(none, nil); contains(msg, "zzz")
    none, msg = beeUtil.pickPurifyInputs({ [1] = make_bee("beePrincess") }, nil); eq(none, nil); truthy(msg)
    local _, p = beeUtil.pickPurifyInputs({ [1] = make_bee("beeDrone", { species = pair("a") }) }, nil)
    eq(p, nil, "no princess in the inventory")
end)

-- ---------------------------------------------------------------- environment text
test("environment: need description names temperature and humidity ranges", function()
    eq(environment.describeNeed(0, "NONE", 0, "NONE"), "温度 一般，湿度 一般")
    eq(environment.describeNeed(0, "BOTH_1", -1, "UP_1"), "温度 寒冷~温暖，湿度 干旱~一般")
    eq(environment.describeNeed(3, "BOTH_5", 1, "DOWN_5"), "温度 严寒~地狱，湿度 干旱~潮湿")
    eq(environment.describeMutationNeed({ temperature = { -1, 0 }, humidity = 1, biome = "Forest" }), "温度 寒冷~一般，湿度 潮湿，生物群系 Forest")
    eq(environment.describeMutationNeed({ name = "x" }), nil)
end)

-- ---------------------------------------------------------------- apiary / device: no suitable hive
local function load_apiary_stack(apiary_cfg)
    local bot = { inventory = {}, getItemsWithLabel = function() return {} end, checkItem = function() return nil end }
    package.loaded.component = { inventory_controller = {}, upgrade_me = {}, beekeeper = {}, database = {} }
    package.loaded.robot = {}
    package.loaded.bot = bot
    package.loaded.tools = {}
    package.loaded.doUntil = function(f) return f() end
    package.loaded.config = { apiary = apiary_cfg, worldAccelerator_tier = 1 }
    package.loaded.apiary, package.loaded.device, package.loaded.mutations = nil, nil, nil
    package.loaded.biomes = nil
    local apiary = require("apiary")
    local device = require("device")
    return bot, apiary, device
end
local function cfg16(map) local t = {}; for i = 1, 16 do t[i] = map[i] or 0 end; return t end

local function find_biome(name)
    local biomes = require("biomes")
    for i, b in ipairs(biomes) do if b.name == name then return i end end
    error("biome not found " .. name)
end

test("device.nextGeneration without a suitable hive reports the needed temperature and humidity", function()
    local bot, apiary, device = load_apiary_stack(cfg16({ [1] = find_biome("Forest") }))
    bot.inventory[1] = make_bee("beePrincess", { temperature = pair(-1), humidity = pair(0), temperatureTolerance = pair("NONE"), humidityTolerance = pair("NONE") })
    bot.inventory[2] = make_bee("beeDrone")
    local ok, err = pcall(device.nextGeneration, 1, 2)
    eq(ok, false)
    contains(err, "没有适合的蜂箱"); contains(err, "温度 寒冷"); contains(err, "湿度 一般")
    contains(err, "#1 温度 一般 湿度 一般", "lists the hive that exists")
    truthy(not tostring(err):find("错误的调用strategy"))
    local msg = apiary.describeMissing(1, { temperature = 2, foundation = { label = "Lava" } })
    contains(msg, "突变额外要求 温度 炙热"); contains(msg, "Lava")
end)

test("a hive in range is still found", function()
    local bot, apiary = load_apiary_stack(cfg16({ [1] = find_biome("Forest") }))
    bot.inventory[1] = make_bee("beePrincess", { temperature = pair(0), humidity = pair(0), temperatureTolerance = pair("NONE"), humidityTolerance = pair("NONE") })
    eq(apiary.checkNextGeneration(1, false), 1)
end)

-- ---------------------------------------------------------------- strategy.purify: effect is washed to effectNone
local function load_strategy()
    local bot = { inventory = {}, inventoryLabel = nil }
    function bot.getItemsWithLabel(label)
        local r = {}
        for _, slot in ipairs(beeUtil.sortedSlots(bot.inventory)) do
            if bot.inventory[slot].inventoryLabel == label then r[#r + 1] = slot end
        end
        return r
    end
    local robot = { selected = 1 }
    function robot.select(s) robot.selected = s; return s end
    function robot.count(s) return bot.inventory[s] and bot.inventory[s].size or 0 end
    function robot.dropUp() bot.inventory[robot.selected] = nil end
    local calls = { breed = 0 }
    local device = {}
    function device.nextGeneration(princessSlot, droneSlot)
        calls.breed = calls.breed + 1
        local pr, dr = bot.inventory[princessSlot], bot.inventory[droneSlot]
        pr.effect = { "forestry.effectNone", "forestry.effectNone" }   -- the assistant drone passes effectNone on
        dr.size = dr.size + 2
        dr.effect = { "forestry.effectNone", "forestry.effectNone" }
    end
    package.loaded.component = { upgrade_me = {} }
    package.loaded.robot, package.loaded.bot, package.loaded.device = robot, bot, device
    package.loaded.beeData = { initialized = true }
    package.loaded.doUntil = function(f) return f() end
    package.loaded.strategy = nil
    return require("strategy"), bot, calls
end

local TARGET = { species = "forestry.speciesCultivated", speed = 5, lifespan = 1, fertility = 4, flowering = 1, territory = 1,
    effect = "forestry.effectNone", temperatureTolerance = "BOTH_5", humidityTolerance = "BOTH_5",
    nocturnal = true, tolerantFlyer = true, caveDwelling = true, flowerProvider = "extrabees.flower.rock" }

test("purify: differing flowerProvider is ignored, effect is washed to effectNone before returning", function()
    local strategy, bot, calls = load_strategy()
    local glacial = { "forestry.effectGlacial", "forestry.effectGlacial" }
    bot.inventory[1] = make_bee("beePrincess", { effect = glacial, flowerProvider = pair("forestry.flowersSnow"), inventoryLabel = nil })
    bot.inventory[2] = make_bee("beeDrone", { effect = glacial, size = 16, flowerProvider = pair("forestry.flowersSnow") })
    bot.inventory[3] = make_bee("beeDrone", { size = 20 })   -- assistant drone: pure, effectNone
    local drone, princess = strategy.purify(1, 2, TARGET, 3, ":test")
    truthy(drone, "purify returned a drone")
    truthy(beeUtil.effectIsNone(bot.inventory[princess]), "princess effect washed")
    truthy(beeUtil.effectIsNone(bot.inventory[drone]), "drone effect washed")
    truthy(calls.breed > 0, "a wash generation was bred")
end)

test("purify: already effectNone bees are not washed (no extra breeding)", function()
    local strategy, bot, calls = load_strategy()
    bot.inventory[1] = make_bee("beePrincess", { flowerProvider = pair("forestry.flowersSnow") })
    bot.inventory[2] = make_bee("beeDrone", { size = 16, flowerProvider = pair("forestry.flowersSnow") })
    bot.inventory[3] = make_bee("beeDrone", { size = 20 })
    local drone = strategy.purify(1, 2, TARGET, 3, ":test")
    truthy(drone)
    eq(calls.breed, 0)
end)

test("purify: refuses to wash when no effectNone gene exists anywhere", function()
    local strategy, bot = load_strategy()
    local glacial = { "forestry.effectGlacial", "forestry.effectGlacial" }
    bot.inventory[1] = make_bee("beePrincess", { effect = glacial })
    bot.inventory[2] = make_bee("beeDrone", { effect = glacial, size = 16 })
    bot.inventory[3] = make_bee("beeDrone", { effect = glacial, size = 20 })
    local ok, err = pcall(strategy.purify, 1, 2, TARGET, 3, ":test")
    eq(ok, false); contains(err, "effectNone")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
return failed
