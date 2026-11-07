"""robot/scan_task.lua 的模擬測試 (沿用 run_drone_tests.py 的方塊世界、無人機與攝影機模擬)。

用法: python run_scan_tests.py [repo 路徑]   (需要 pip install lupa)
"""
import math
import pathlib
import sys

from lupa.lua53 import LuaRuntime

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent).resolve()
SRC = (ROOT / "run_drone_tests.py").read_text(encoding="utf-8").split("results = []")[0]
ns = {"__file__": str(ROOT / "run_drone_tests.py"), "__name__": "sim"}
sys.argv = [sys.argv[0], str(ROOT)]
exec(SRC, ns)
Sim, Done = ns["Sim"], ns["Done"]
SCAN = (ROOT / "robot" / "scan_task.lua").read_text(encoding="utf-8")


def make_world(height):
    """height(x, z) -> 該格最上面那塊方塊的 Y。回傳 solid 集合 (世界方塊座標)。"""
    solid = set()
    for x in range(-40, 41):
        for z in range(-40, 41):
            for y in range(75, height(x, z) + 1):
                solid.add((x, y, z))
    return solid


def run_scan(sim, args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    sim.install(lua)
    sim.queue.append(("modem_message", "l", "r", 0, 0, "DRONE_CMD", "scan_region") + tuple(args))
    fn = lua.eval("function(code) return load(code) end")(SCAN)
    try:
        fn()
    except Exception as e:
        if "idle" not in str(e):
            raise
    return sim


def decode(sim):
    """和 scan_collect.lua 相同的解碼：回傳 {(bx, bz): top}，以及最後一則狀態。"""
    pts, last = {}, None
    for r in sim.reports:
        if r[:2] != ["DRONE_REPORT", "REPORT"]:
            continue
        kind = r[2]
        if kind == "SCAN":
            z, x, step, csv = int(r[3]), int(r[4]), int(r[5]), r[6]
            for v in csv.split(","):
                pts[(x, z)] = int(v)
                x += step
        last = kind
    return pts, last


results = []


def test(name, f):
    try:
        f()
        results.append(True)
        print("PASS ", name)
    except Exception as e:
        results.append(False)
        print("FAIL ", name, "\n     ", repr(e))


def hill(x, z):
    h = 81 + int(round(18 * math.exp(-((x - 5) ** 2 + (z + 3) ** 2) / 120.0)))
    if x >= 14:                                # 一道 10 格高的陡坎
        h += 10
    return h


def t_heights():
    sim = Sim(make_world(hill), start=(-24.5, 100.0, -24.5))
    run_scan(sim, (-24, 23, -24, 23, 2))
    pts, last = decode(sim)
    assert last == "SCAN_DONE", (last, sim.reports[-1:])
    assert len(pts) == 24 * 24, len(pts)
    bad = [(k, v, hill(*k) + 1) for k, v in pts.items() if abs(v - (hill(*k) + 1)) > 1]
    assert len(bad) <= 0.02 * len(pts), f"誤差超過 1 格的點: {len(bad)}/{len(pts)} 例: {bad[:3]}"
    assert sim.collisions < 50, f"撞到太多次: {sim.collisions}"


def t_flat_ground_is_82():
    sim = Sim(make_world(lambda x, z: 81), start=(-10.5, 90.0, -10.5))
    run_scan(sim, (-10, 9, -10, 9, 3))
    pts, last = decode(sim)
    assert last == "SCAN_DONE", last
    assert set(pts.values()) == {82}, set(pts.values())


def t_no_camera():
    sim = Sim(make_world(hill), start=(0.5, 100.0, 0.5), camera=False)
    run_scan(sim, (0, 5, 0, 5, 1))
    pts, last = decode(sim)
    assert last == "ERROR" and not pts, (last, pts)


def t_terrain_too_deep():
    # 起點在 40 格高空 (超過攝影機 32 格)：要先往下降才量得到
    sim = Sim(make_world(lambda x, z: 81), start=(-5.5, 125.0, -5.5))
    run_scan(sim, (-5, 4, -5, 4, 3))
    pts, last = decode(sim)
    assert last == "SCAN_DONE" and set(pts.values()) == {82}, (last, set(pts.values()))


def t_axes_swapped():
    # 導航座標：nav_x = -world_z，nav_z = world_x (軸互換 + 一軸反向)；結果仍要對上世界座標
    sim = Sim(make_world(lambda x, z: 81 + (x % 5)), start=(-5.5, 100.0, -5.5),
              nav=lambda p: (-p[2], p[1], p[0]))
    run_scan(sim, (-5, 4, -5, 4, 3))
    pts, last = decode(sim)
    assert last == "SCAN_DONE" and pts, last
    for (x, z), v in pts.items():
        assert abs(v - (82 + x % 5)) <= 1, (x, z, v)


def t_out_of_range():
    sim = Sim(make_world(lambda x, z: 81), start=(-5.5, 100.0, -5.5), nav_range=3)
    run_scan(sim, (-5, 4, -5, 4, 3))
    assert decode(sim)[1] == "ERROR", decode(sim)[1]


def t_low_energy():
    # 電池只有 1500 點、補充很慢：沒有電量管理會在半路沒電；有的話應該慢慢完成
    sim = Sim(make_world(lambda x, z: 81 + (x % 5)), start=(-5.5, 100.0, -5.5), energy=1500)
    run_scan(sim, (-5, 4, -5, 4, 3))
    pts, last = decode(sim)
    assert not sim.dead and last == "SCAN_DONE" and pts, (sim.dead, last)


test("起伏地形：每個取樣點的頂面高度誤差 ≤ 1 格", t_heights)
test("平地：全部量到 82 (地面最上面那塊的上表面)", t_flat_ground_is_82)
test("沒裝攝影機：回報 ERROR 不亂飛", t_no_camera)
test("起點太高 (超出攝影機 32 格)：先降低高度再量", t_terrain_too_deep)
test("導航軸互換/反向：自動校正後座標仍正確", t_axes_swapped)
test("掃描範圍超出導航範圍：回報 ERROR", t_out_of_range)
test("低電量：自動懸停充電，不會中途沒電", t_low_energy)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
