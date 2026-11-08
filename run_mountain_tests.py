"""robot/mountain_task.lua 的模擬測試：用真正的山體產生器 (殼起點、支撐規劃、材質) 蓋一座小山，
檢查無人機蓋出來的方塊和清單完全一致、每一塊都符合 OC 放置規則、ME 按需請求材料。

用法: python run_mountain_tests.py [repo 路徑]   (需要 pip install lupa numpy)
"""
import math
import pathlib
import sys

import numpy as np
from lupa.lua53 import LuaRuntime

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent).resolve()
SRC = (ROOT / "run_drone_tests.py").read_text(encoding="utf-8").split("results = []")[0]
ns = {"__file__": str(ROOT / "run_drone_tests.py"), "__name__": "sim"}
sys.argv = [sys.argv[0], str(ROOT)]
exec(SRC, ns)
Sim, Done = ns["Sim"], ns["Done"]
CODE = ns["minified"]((ROOT / "robot" / "mountain_task.lua").read_text(encoding="utf-8"))
sys.path.insert(0, str(ROOT / "mountain"))
import mountain as M  # noqa: E402

ITEM_NAME = dict(S="minecraft:stone", T="minecraft:stained_hardened_clay", C="minecraft:cobblestone",
                 N="minecraft:snow", G="minecraft:gravel", D="minecraft:dirt")
FUEL = "minecraft:coal_block"
ENTRY = dict(ITEM_NAME)            # 預期方塊以材料名稱記錄 (資料庫項目編號由程式自己決定)


class MSim(Sim):
    """加上背包、ME 升級、資料庫，以及 OC 的放置規則 (目標格的腳下或四個側邊要有方塊)。"""

    def __init__(self, solid, start, supply=None, **kw):
        super().__init__(solid, start, **kw)
        self.slots = {s: [None, 0] for s in range(1, 9)}
        self.sel = 1
        self.blocks = {}                  # (x, y, z) -> 材質編號
        self.me_requests = 0
        self.supply = supply              # None = 無限；否則 {材料名稱: 剩餘數量}
        self.netitems = set(ITEM_NAME.values()) | {FUEL}   # ME 網路裡有的材料
        self.generator = False            # 是否裝了發電升級
        self.gen_count, self.gen_burn, self.gen_inserts = 0, 0, 0
        self.dbslots = {}                 # 資料庫項目 -> 材料名稱
        self.store_calls = 0
        self.place_fail = 0
        self.returned = 0                 # 還給 ME 的次數 (背包不夠時才會發生)

    def tick(self):
        if self.generator:
            if self.gen_burn <= 0 and self.gen_count > 0:
                self.gen_count -= 1
                self.gen_burn = 800
            if self.gen_burn > 0:
                self.gen_burn -= 1
                self.energy = min(self.max_energy, self.energy + 8)
        super().tick()

    def mplace(self):
        item, cnt = self.slots[self.sel]
        x, y, z = (math.floor(c) for c in self.p)
        tgt = (x, y - 1, z)
        if cnt <= 0 or tgt in self.solid:
            self.place_fail += 1
            return False
        # 放置射線：往下找腳下的方塊；找不到再朝四個側邊各射 0.65 格，只比目標格多伸進鄰格 0.15 格，
        # 所以無人機在目標格內偏離中心超過 0.15 (往那一側的反方向) 就打不到鄰格的方塊
        ox, oz = self.p[0] - (x + 0.5), self.p[2] - (z + 0.5)
        below = (tgt[0], tgt[1] - 1, tgt[2]) in self.solid
        side = any((tgt[0] + dx, tgt[1], tgt[2] + dz) in self.solid and ox * dx + oz * dz >= -0.15
                   for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        if not (below or side):
            self.place_fail += 1
            return False
        self.solid.add(tgt)
        self.blocks[tgt] = item
        self.slots[self.sel][1] -= 1
        return True

    def install(self, lua):
        sim = self
        g = lua.globals()

        def drone_move(dx, dy, dz):
            sim.target[0] += dx; sim.target[1] += dy; sim.target[2] += dz

        def select(s):
            sim.sel = int(s)
            return int(s)

        def store(flt, addr, entry, count=1):
            sim.store_calls += 1
            name = flt["name"]
            if name not in sim.netitems:
                return False
            sim.dbslots[int(entry)] = name
            return True

        def request(addr, entry, amount):
            s = sim.slots[sim.sel]
            item = sim.dbslots.get(int(entry))
            if item is None or (s[1] > 0 and s[0] != item):
                return 0
            have = sim.supply.get(item, 0) if sim.supply is not None else 10 ** 9
            n = min(int(amount), 64 - s[1], have)
            if n <= 0:
                return 0
            if sim.supply is not None:
                sim.supply[item] -= n
            s[0] = item
            s[1] += n
            sim.me_requests += 1
            return n

        def gen_insert(*a):
            s = sim.slots[sim.sel]
            if s[1] <= 0 or s[0] != FUEL:
                return False
            sim.gen_count += s[1]
            sim.gen_inserts += 1
            s[0], s[1] = None, 0
            return True

        def send_items(*a):
            s = sim.slots[sim.sel]
            n = s[1]
            if n:
                sim.returned += 1
            s[0], s[1] = None, 0
            return n

        comps = {
            "drone": lua.table_from({
                "setStatusText": lambda s: None, "move": drone_move,
                "getOffset": lambda: math.dist(sim.target, sim.p), "getVelocity": lambda: sim.vel,
                "select": select, "count": lambda s=None: sim.slots[int(s or sim.sel)][1],
                "place": lambda side=0: sim.mplace(),
                "detect": lambda side=0: ((True, "solid") if (math.floor(sim.p[0]), math.floor(sim.p[1]) - 1,
                                                              math.floor(sim.p[2])) in sim.solid else (False, "air")),
            }),
            "navigation": lua.table_from({"getPosition": lambda: tuple(sim.p), "getRange": lambda: 1e9}),
            "tunnel": lua.table_from({"send": lambda *a: sim.send(a)}),
            "generator": lua.table_from({"count": lambda: sim.gen_count, "insert": gen_insert}),
            "upgrade_me": lua.table_from({"requestItems": request, "sendItems": send_items, "store": store}),
            "database": lua.table_from({"address": "db", "clear": lambda e: sim.dbslots.pop(int(e), None) and None,
                                        "get": lambda e: (lua.table_from({"name": sim.dbslots[int(e)]}) if int(e) in sim.dbslots else None)}),
            "camera": lua.table_from({
                "distance": lambda x=0, y=0: sim.ray((-x, y, 1)),
                "distanceUp": lambda x=0, y=0: sim.ray((x, 1, y)),
                "distanceDown": lambda x=0, y=0: sim.ray((x, -1, y)),
            }),
        }
        if not self.camera:
            comps.pop("camera")
        if not self.generator:
            comps.pop("generator")
        g.component = lua.table_from({"list": lambda kind: (lambda *a: kind) if kind in comps else (lambda *a: None),
                                      "proxy": lambda addr: comps.get(addr)})
        self.queue = []

        def pull(timeout=None):
            if timeout is not None:
                for _ in range(max(1, round(timeout * 20))):
                    sim.tick()
                return None
            if not sim.queue:
                raise Done("idle")
            return sim.queue.pop(0)

        g.computer = lua.table_from({"pullSignal": pull, "energy": lambda: sim.energy, "maxEnergy": lambda: sim.max_energy})

    def run(self, batches, cruise):
        lua = LuaRuntime(unpack_returned_tuples=True)
        self.install(lua)
        for i, payload in enumerate(batches, 1):
            self.queue.append(("modem_message", "l", "r", 0, 0, "DRONE_CMD", "build_batch", i, cruise, payload))
        fn = lua.eval("function(code) return load(code) end")(CODE)
        try:
            fn()
        except Exception as e:
            if "idle" not in str(e):
                raise
        return self


def plan_lines(h, planned=True):
    """h：山高陣列 (已補邊)。回傳 (施工清單行, 預期方塊 {座標: 材質編號})。planned=False 時順序亂排 (負對照)。"""
    import re
    start0 = M.shell_start(h, 2)
    pts = [(int(z), int(x)) for z, x in zip(*np.nonzero(h))]
    ns_, order, bad = M.plan_support(h, start0, pts)
    start = start0.copy()
    if planned:                                         # 負對照 (planned=False) 用沒填坑的起點 + 列序
        for p, v in ns_.items():
            start[p] = v
        for p in bad:
            start[p] = 1
    cols, _, _, start = M.assign_materials(h, shell=2, start=start)
    seq_order = order + list(bad) if planned else sorted(pts)
    lines, expect = [], {}
    for p in seq_order:
        cz, cx = p
        xm, zm = cx + 205, cz + 60                     # 湖地圖座標 -> 世界方塊 X = 4 + cx、Z = -110 - cz
        lines.append(f"{xm} {zm} {int(h[p])} {cols[p]}")
        seq = []
        for m, c in re.findall(r"([A-Z_])(\d+)", cols[p]):
            seq += [m] * int(c)
        for layer, m in enumerate(seq, 1):
            if m != "_":
                expect[(4 + cx, 81 + layer, -110 - cz)] = ENTRY[m]
    return lines, expect


def small_mountain(n=9, planned=True):
    """用真正的產生器流程算一座 n×n 的小山。"""
    yy, xx = np.mgrid[0:n, 0:n]
    r = np.hypot(yy - (n - 1) / 2, xx - (n - 1) / 2)
    h = np.clip(np.round(10 - r * 2.2), 0, None).astype(int)
    h[2, 3] += 2                                       # 一個小突起，讓殼的底面不平
    h[5, 5] = max(h[5, 5] - 2, 1)                      # 一個小凹坑
    h = np.pad(h, 1)
    lines, expect = plan_lines(h, planned)
    return lines, expect, h


def basin_plateau(planned=True):
    """高原中間有個淺盆地 (比周圍低 1 格)：盆地的殼底比四周的殼底還低，沒有支撐。"""
    h = np.full((9, 9), 12)
    h[3:6, 3:6] = 11
    h = np.pad(h, 1)
    lines, expect = plan_lines(h, planned)
    return lines, expect, h


def make_sim(**kw):
    solid = {(x, y, z) for x in range(-5, 30) for z in range(-140, -90) for y in range(74, 82)}
    return MSim(solid, (4.5, 92.0, -109.5), **kw)


results = []


def test(name, fn):
    try:
        fn()
        print("PASS ", name)
        results.append(True)
    except Exception as e:
        import traceback
        traceback.print_exc()
        print("FAIL ", name, "->", repr(e))
        results.append(False)


def done_counts(sim):
    r = [x for x in sim.reports if x[2] == "BATCH_DONE"]
    return sum(int(x[4]) for x in r), sum(int(x[5]) for x in r), r


def t_build_matches_plan():
    lines, expect, h = small_mountain()
    sim = make_sim()
    batches = [";".join(lines[i:i + 20]) for i in range(0, len(lines), 20)]
    sim.run(batches, cruise=int(81 + h.max() + 4))
    done, failed, rep = done_counts(sim)
    got = {k: v for k, v in sim.blocks.items()}
    assert len(rep) == len(batches), (len(rep), len(batches), sim.reports[-3:])
    assert failed == 0 and done == len(lines), (done, failed, [r[7] for r in rep if r[7]])
    assert got == expect, (len(got), len(expect), list(set(expect.items()) ^ set(got.items()))[:5])


def t_me_on_demand():
    lines, expect, h = small_mountain()
    sim = make_sim()
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    mats = set(expect.values())
    assert len(mats) >= 2, mats
    assert sim.me_requests >= len(mats), (sim.me_requests, mats)       # 每種材料至少請求過一次
    assert sim.me_requests < len(expect) / 3                           # 不是每塊都請求 (有快取)


def t_me_empty():
    lines, expect, h = small_mountain()
    sim = make_sim(supply={ITEM_NAME["S"]: 5})                         # 石頭只有 5 個，其他材料沒有
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    kinds = [r[2] for r in sim.reports]
    assert "ERROR" in kinds and "BATCH_DONE" not in kinds, kinds


def t_blocked_column():
    lines, expect, h = small_mountain()
    sim = make_sim()
    # 在第一欄正上方放一塊懸空方塊 (模擬不明障礙)：該欄失敗，其他照常
    x, z = (int(v) for v in lines[0].split()[:2])
    bx, bz = math.floor(-200.5 + x), math.floor(-49.5 - z)
    sim.solid.add((bx, 150, bz))
    sim.solid.add((bx, 151, bz))
    sim.solid.add((bx, 152, bz))
    sim.run([";".join(lines[:15])], cruise=130)
    done, failed, rep = done_counts(sim)
    assert done + failed == 15, (done, failed)


def t_basin_needs_plan():
    # 負對照：亂序 (不考慮支撐) 一定有放不上去的方塊；規劃過的順序全部放得上去
    lines, expect, h = basin_plateau(planned=False)
    sim = make_sim()
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    assert sim.place_fail > 0, "負對照應該要失敗"
    lines, expect, h = basin_plateau(planned=True)
    sim = make_sim()
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    done, failed, _ = done_counts(sim)
    assert failed == 0 and sim.place_fail == 0 and sim.blocks == expect, (failed, sim.place_fail)


def t_stray_not_success():
    # OC 的 place 找不到目標會改放到四周並回傳 true：腳下沒有方塊就不能算成功
    lines, expect, h = basin_plateau(planned=False)
    sim = make_sim()
    orig = sim.mplace
    stray = {"n": 0}

    def mplace():
        if orig():
            return True
        x, y, z = (math.floor(c) for c in sim.p)
        sim.solid.add((x + 1, y, z)); stray["n"] += 1       # 放到旁邊去了
        return True

    sim.mplace = mplace
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    done, failed, rep = done_counts(sim)
    assert stray["n"] > 0 and failed > 0 and done + failed == len(lines), (stray, done, failed)
    assert all(v for v in [rep[0][6]]) and "side" in rep[0][6] or failed > 8, rep[0][6]


def t_db_auto_setup():
    lines, expect, h = small_mountain()
    sim = make_sim()
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    used = set(expect.values())
    assert sim.store_calls == len(used), (sim.store_calls, used)      # 每種用到的材料只寫一次資料庫
    assert sim.blocks == expect


def t_missing_material():
    lines, expect, h = small_mountain()
    sim = make_sim()
    sim.netitems.discard(ITEM_NAME["C"])                               # ME 裡沒有鵝卵石
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    err = [r for r in sim.reports if r[2] == "ERROR"]
    assert err and "cobblestone" in str(err[0][3]), sim.reports


def t_no_camera():
    lines, expect, h = small_mountain()
    sim = make_sim(camera=False)                                       # 沒裝攝影機：靠卡住偵測，照樣蓋得出來
    sim.run([";".join(lines[i:i + 20]) for i in range(0, len(lines), 20)], cruise=int(81 + h.max() + 4))
    done, failed, _ = done_counts(sim)
    assert failed == 0 and sim.blocks == expect, (done, failed, len(sim.blocks), len(expect))


def t_generator_fuel():
    lines, expect, h = small_mountain()
    sim = make_sim(energy=3000)
    sim.generator = True
    sim.run([";".join(lines[i:i + 20]) for i in range(0, len(lines), 20)], cruise=int(81 + h.max() + 4))
    done, failed, _ = done_counts(sim)
    assert sim.gen_inserts >= 1 and sim.gen_count + (800 if sim.gen_burn else 0) > 0, (sim.gen_inserts, sim.gen_count)
    assert failed == 0 and sim.blocks == expect          # 材料不被燃料占掉的槽影響


def t_no_fuel_not_fatal():
    lines, expect, h = small_mountain()
    sim = make_sim()
    sim.generator = True
    sim.netitems.discard(FUEL)                           # ME 裡沒有燃料：不致命 (電量夠就照蓋)
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    done, failed, _ = done_counts(sim)
    assert failed == 0 and sim.blocks == expect, (done, failed)


def t_eight_slots_no_thrash():
    # 8 格：6 種材料可以全部常駐，不需要把材料還給 ME (4 格時才會互相擠掉)
    lines, expect, h = small_mountain()
    sim = make_sim()
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    assert sim.blocks == expect and sim.returned == 0, sim.returned


def t_idempotent_rerun():
    # 同一批再送一次 (斷線重送、補蓋)：不會失敗，也不會多放或少放
    lines, expect, h = small_mountain()
    sim = make_sim()
    payload = ";".join(lines)
    sim.run([payload, payload], cruise=int(81 + h.max() + 4))
    done, failed, rep = done_counts(sim)
    assert len(rep) == 2 and failed == 0 and done == 2 * len(lines), (len(rep), done, failed, [r[6] for r in rep])
    assert sim.blocks == expect


def t_partial_column_resume():
    # 一欄蓋到一半 (前幾層已經在) 時續蓋：從已蓋的最高層接著往上
    lines, expect, h = small_mountain()
    sim = make_sim()
    first = lines[0].split()
    x, z, hh = int(first[0]), int(first[1]), int(first[2])
    bx, bz = math.floor(-200.5 + x), math.floor(-49.5 - z)
    mine = sorted((k for k in expect if k[0] == bx and k[2] == bz), key=lambda k: k[1])
    for k in mine[:max(1, len(mine) // 2)]:             # 預先放好下半段
        sim.solid.add(k)
        sim.blocks[k] = expect[k]
    sim.run([";".join(lines)], cruise=int(81 + h.max() + 4))
    done, failed, rep = done_counts(sim)
    assert failed == 0 and sim.blocks == expect, (done, failed, len(sim.blocks), len(expect))


def t_deferred_retry():
    # 把第一欄的支撐欄故意晚一批才送：第一欄在同批內失敗，之後會補蓋一次
    lines, expect, h = small_mountain()
    sim = make_sim()
    swapped = lines[1:] + lines[:1] if False else None
    # 取出一欄「需要鄰欄支撐」的欄 (殼起點 > 1)，放到整批最前面，它的支撐欄在它後面才會蓋好
    need = [i for i, l in enumerate(lines) if "_" in l.split()[3] and i > 5][0]
    reordered = [lines[need]] + lines[:need] + lines[need + 1:]
    sim.run([";".join(reordered)], cruise=int(81 + h.max() + 4))
    done, failed, rep = done_counts(sim)
    assert failed == 0 and done == len(lines) and sim.blocks == expect, (done, failed, rep[0][6] if rep else None)


test("蓋出來的方塊和清單完全一致、每塊都符合放置規則", t_build_matches_plan)
test("ME 按需請求：每種材料請求過、有快取不是每塊都請求", t_me_on_demand)
test("ME 供不出材料：回報 ERROR 並中止，不假裝完成", t_me_empty)
test("無法抵達的欄：記錄失敗，其餘繼續", t_blocked_column)
test("盆地高原：亂序放不上去，規劃過的順序全部放得上去", t_basin_needs_plan)
test("放到旁邊不算成功：腳下沒方塊就回報失敗", t_stray_not_success)
test("資料庫由程式自己寫入：每種材料只寫一次", t_db_auto_setup)
test("ME 網路沒有某材料：回報 ERROR 並指出材料名稱", t_missing_material)
test("沒裝攝影機：照樣蓋得出來", t_no_camera)
test("發電升級：批次開始補燃料，材料快取不受影響", t_generator_fuel)
test("ME 沒有燃料：不致命，電量夠就照蓋", t_no_fuel_not_fatal)
test("8 格背包：材料全部常駐，不用還給 ME", t_eight_slots_no_thrash)
test("同一批重送：重複執行安全", t_idempotent_rerun)
test("蓋到一半的欄：從已蓋的最高層續蓋", t_partial_column_resume)
test("失敗的欄在整批結束後補蓋一次", t_deferred_retry)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
