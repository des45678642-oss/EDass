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

ENTRY = dict(S=1, T=2, C=3, N=4, G=5, D=6)


class MSim(Sim):
    """加上背包、ME 升級、資料庫，以及 OC 的放置規則 (目標格的腳下或四個側邊要有方塊)。"""

    def __init__(self, solid, start, supply=None, **kw):
        super().__init__(solid, start, **kw)
        self.slots = {s: [None, 0] for s in range(1, 5)}
        self.sel = 1
        self.blocks = {}                  # (x, y, z) -> 材質編號
        self.me_requests = 0
        self.supply = supply              # None = 無限；否則 {材質編號: 剩餘數量}
        self.place_fail = 0

    def mplace(self):
        item, cnt = self.slots[self.sel]
        x, y, z = (math.floor(c) for c in self.p)
        tgt = (x, y - 1, z)
        if cnt <= 0 or tgt in self.solid:
            self.place_fail += 1
            return False
        if not any((tgt[0] + dx, tgt[1] + dy, tgt[2] + dz) in self.solid
                   for dx, dy, dz in ((0, -1, 0), (1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1))):
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

        def request(addr, entry, amount):
            s = sim.slots[sim.sel]
            entry = int(entry)
            if s[1] > 0 and s[0] != entry:
                return 0
            have = sim.supply.get(entry, 0) if sim.supply is not None else 10 ** 9
            n = min(int(amount), 64 - s[1], have)
            if n <= 0:
                return 0
            if sim.supply is not None:
                sim.supply[entry] -= n
            s[0] = entry
            s[1] += n
            sim.me_requests += 1
            return n

        def send_items(*a):
            s = sim.slots[sim.sel]
            n = s[1]
            s[0], s[1] = None, 0
            return n

        comps = {
            "drone": lua.table_from({
                "setStatusText": lambda s: None, "move": drone_move,
                "getOffset": lambda: math.dist(sim.target, sim.p), "getVelocity": lambda: sim.vel,
                "select": select, "count": lambda s=None: sim.slots[int(s or sim.sel)][1],
                "place": lambda side=0: sim.mplace(),
            }),
            "navigation": lua.table_from({"getPosition": lambda: tuple(sim.p), "getRange": lambda: 1e9}),
            "tunnel": lua.table_from({"send": lambda *a: sim.send(a)}),
            "upgrade_me": lua.table_from({"requestItems": request, "sendItems": send_items}),
            "database": lua.table_from({"address": "db"}),
            "camera": lua.table_from({
                "distance": lambda x=0, y=0: sim.ray((-x, y, 1)),
                "distanceUp": lambda x=0, y=0: sim.ray((x, 1, y)),
                "distanceDown": lambda x=0, y=0: sim.ray((x, -1, y)),
            }),
        }
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
    sim = make_sim(supply={1: 5})                                      # 石頭只有 5 個，其他材料沒有
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


test("蓋出來的方塊和清單完全一致、每塊都符合放置規則", t_build_matches_plan)
test("ME 按需請求：每種材料請求過、有快取不是每塊都請求", t_me_on_demand)
test("ME 供不出材料：回報 ERROR 並中止，不假裝完成", t_me_empty)
test("無法抵達的欄：記錄失敗，其餘繼續", t_blocked_column)
test("盆地高原：亂序放不上去，規劃過的順序全部放得上去", t_basin_needs_plan)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
