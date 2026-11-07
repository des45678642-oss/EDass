"""無人機 robot/drone_task.lua 的避障模擬測試。

用法: python run_drone_tests.py [repo 路徑]   (需要 pip install lupa)

以簡化的方塊世界模擬無人機移動 (每 tick 每軸最多 0.4 格、撞到實心方塊就停)、
導航升級與 Computronics 攝影機 (無人機的 distance() 永遠朝南 +Z)。
"""
import math
import pathlib
import sys

from lupa.lua53 import LuaRuntime

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent).resolve()
CODE = (ROOT / "robot" / "drone_task.lua").read_text(encoding="utf-8")


class Done(Exception):
    pass


class Sim:
    def __init__(self, solid=(), start=(-200.5, 76.0, -49.5), camera=True):
        self.solid = set(solid)
        for x in range(-260, -140):          # 基岩 y=74
            for z in range(-110, 10):
                self.solid.add((x, 74, z))
        self.p = list(start)
        self.target = list(start)
        self.vel = 0.0
        self.reports = []
        self.placed = []
        self.collisions = 0
        self.camera = camera
        self.ticks = 0

    def is_solid(self, x, y, z):
        return (math.floor(x), math.floor(y), math.floor(z)) in self.solid

    def tick(self):
        self.ticks += 1
        if self.ticks > 200000:
            raise Done("timeout")
        moved = 0.0
        for a in range(3):
            delta = max(-0.4, min(0.4, self.target[a] - self.p[a]))
            if abs(delta) < 1e-9:
                continue
            q = list(self.p)
            q[a] += delta
            # 無人機有體積：檢查移動方向前緣 0.3 格
            probe = list(q)
            probe[a] += 0.3 * (1 if delta > 0 else -1)
            if self.is_solid(*probe):
                self.collisions += 1
                continue
            self.p = q
            moved += delta * delta
        self.vel = math.sqrt(moved) * 20

    def ray(self, d):
        length = math.sqrt(sum(c * c for c in d))
        step = 0.05
        n = int(32 * length / step)
        for k in range(1, n + 1):
            pt = [self.p[i] + d[i] * k * step / length for i in range(3)]
            if self.is_solid(*pt):
                return math.dist(pt, self.p)
        return -1.0

    def install(self, lua):
        sim = self
        g = lua.globals()

        def drone_move(dx, dy, dz):
            sim.target[0] += dx; sim.target[1] += dy; sim.target[2] += dz

        drone = lua.table_from({
            "setStatusText": lambda s: None,
            "move": drone_move,
            "getOffset": lambda: math.dist(sim.target, sim.p),
            "getVelocity": lambda: sim.vel,
            "select": lambda s: None,
            "place": lambda side: sim.place(),
        })
        nav = lua.table_from({"getPosition": lambda: (sim.p[0], sim.p[1], sim.p[2])})
        tunnel = lua.table_from({"send": lambda *a: sim.report(a)})
        cam = lua.table_from({
            "distance": lambda x=0, y=0: sim.ray((-x, y, 1)),
            "distanceUp": lambda x=0, y=0: sim.ray((x, 1, y)),
            "distanceDown": lambda x=0, y=0: sim.ray((x, -1, y)),
        })
        comps = {"drone": drone, "navigation": nav, "tunnel": tunnel, "inventory_controller": lua.table()}
        if self.camera:
            comps["camera"] = cam

        def c_list(kind):
            return (lambda *a: kind) if kind in comps else (lambda *a: None)

        def c_proxy(addr):
            return comps.get(addr)

        g.component = lua.table_from({"list": c_list, "proxy": c_proxy})
        self.queue = []

        def pull(timeout=None):
            if timeout is not None:
                for _ in range(max(1, round(timeout * 20))):
                    sim.tick()
                return None
            if not sim.queue:
                raise Done("idle")
            return sim.queue.pop(0)

        g.computer = lua.table_from({"pullSignal": pull})

    def place(self):
        x, y, z = (math.floor(c) for c in self.p)
        self.solid.add((x, y - 1, z))
        self.placed.append(y - 1)
        return True

    def report(self, args):
        self.reports.append(list(args))

    def run(self, x, z, dp, sY):
        lua = LuaRuntime(unpack_returned_tuples=True)
        self.install(lua)
        # 參數順序與 server.lua 轉發的 DRONE_CMD 一致
        self.queue.append(("modem_message", "local", "remote", 0, 0, "DRONE_CMD", "build_point", x, z, dp, sY))
        fn = lua.eval("function(code) return load(code) end")(CODE)
        try:
            fn()
        except Exception as e:  # lupa 會把 Python 例外包起來
            if "idle" not in str(e):
                raise
        return self


results = []


def test(name, f):
    try:
        f()
        results.append(True)
        print("PASS ", name)
    except Exception as e:
        results.append(False)
        print("FAIL ", name, "\n     ", e)


def wall(x0, x1, y0, y1, z0, z1):
    return {(x, y, z) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1) for z in range(z0, z1 + 1)}


def last_status(s):
    assert s.reports, "沒有回報"
    return s.reports[-1][3]


def t_clear():
    s = Sim().run(0, 10, 1, 79)              # 目標在北方 10 格，柱高 (79-1)-74 = 4 層
    assert last_status(s) == "SUCCESS", s.reports
    assert s.placed == [75, 76, 77, 78], s.placed
    assert s.collisions == 0, s.collisions


def t_blind_wall_north():
    # 北方 (攝影機看不到) 在航道高度有一道牆：撞到後爬升越過
    w = wall(-215, -185, 74, 86, -56, -56)
    s = Sim(w).run(0, 10, 1, 79)
    assert last_status(s) == "SUCCESS", s.reports
    assert s.placed == [75, 76, 77, 78], s.placed
    assert s.collisions > 0, "北方應該要靠碰撞偵測"


def t_camera_wall_south():
    # 南方 (攝影機看得到) 的牆：不碰撞直接爬過去
    w = wall(-215, -185, 74, 88, -44, -44)
    s = Sim(w).run(0, -10, 1, 79)
    assert last_status(s) == "SUCCESS", s.reports
    assert s.collisions == 0, f"南方應該用攝影機先看到，卻撞了 {s.collisions} 次"


def t_wall_too_high():
    w = wall(-215, -185, 74, 120, -56, -56)
    s = Sim(w).run(0, 10, 1, 79)
    assert last_status(s) == "BLOCKED", s.reports
    assert s.placed == [], s.placed


def t_roof():
    w = wall(-203, -198, 80, 80, -52, -47)
    s = Sim(w).run(0, 10, 1, 79)
    assert last_status(s) == "BLOCKED", s.reports
    assert s.collisions == 0, "上方有屋頂應該用攝影機看到，不要撞"


def t_column_obstacle():
    # 目標柱子裡 y=77 已經有方塊
    w = {(-201, 77, -60)}
    s = Sim(w).run(0, 10, 1, 79)        # 目標 (-200.5, -59.5) → 方塊格 (-201, -60)
    assert last_status(s) == "BLOCKED", s.reports
    assert s.collisions == 0, s.collisions


def t_no_camera():
    w = wall(-215, -185, 74, 86, -44, -44)
    s = Sim(w, camera=False).run(0, -10, 1, 79)
    assert last_status(s) == "SUCCESS", s.reports


test("沒有障礙：照原本流程打樁並回報 SUCCESS", t_clear)
test("北方的牆 (攝影機死角)：撞到後自動爬升越過", t_blind_wall_north)
test("南方的牆：攝影機先看到，不碰撞就爬過", t_camera_wall_south)
test("牆太高 (超過 MAXUP)：回報 BLOCKED 不打樁", t_wall_too_high)
test("起飛點上方有屋頂：回報 BLOCKED", t_roof)
test("目標柱子裡已有方塊：回報 BLOCKED", t_column_obstacle)
test("沒裝攝影機：仍可靠碰撞偵測越過障礙", t_no_camera)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
