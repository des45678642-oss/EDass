"""環湖山體產生器 (只做湖外圍；缺口那塊陸地保持平坦)。

輸入  : lake_map.bin (416x416 bytes，列 z、欄 x，0 = 陸地，1~5 = 水深；與 T4 讀的是同一份)。
        找不到時可用 --lake-py 指定 lake.py 自動重建。
輸出  : mountain_map.bin       每格山高 (方塊數，從 Y=82 往上疊)，列優先
        mountain_meta.json     畫布大小、外擴量、世界座標換算、方塊數等
        mountain_cols_A/B/C.txt 三台無人機各自的施工清單 (依角度平分工作量)，每行:
                               x_map z_map 高度 材質串   (材質串由下往上，如 S31T2S4N2)
        mountain_preview.png   高度圖 (世界座標)
        mountain_materials.png 表面材質與分區

座標:
  湖地圖座標 (x_map, z_map)；世界座標 X = -200.5 + x_map，Z = -49.5 - z_map (與無人機一致)。
  畫布座標 (cx, cz) = (x_map + ox, z_map + oz)，ox / oz 是外擴量，寫在 meta 裡。
  世界 Z 越小越往北，所以高度圖上方 = 北。
"""
import argparse
import json
import math
import os
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from scipy.ndimage import distance_transform_edt, gaussian_filter, grey_opening, label

LAKE_W = 416
WX0, WZ0 = -200.5, -49.5          # 湖地圖 (0,0) 對應的世界座標 (方塊中心)
GROUND_Y = 81                      # 湖岸地面最上面那層方塊的 Y；山從 GROUND_Y + 1 開始疊
MAX_Y = GROUND_Y + 128             # 建築高度上限 (地面 +128 = Y 209)
BITE_CX, BITE_CZ, BITE_R = 208, 304, 200 * 0.55   # 小圓 (月牙缺口) 的幾何，與 lake.py 相同
LAKE_BLOCKS, LAKE_COLUMNS = 323291, 82915
LAKE_SECONDS = 7 * 24 * 3600       # 湖大約一週
MATERIALS = {"S": "石頭", "T": "青色陶瓦", "C": "鵝卵石", "N": "雪", "G": "砂礫", "D": "泥土"}


def w2m(wx, wz):
    return wx - WX0, WZ0 - wz


def m2w(xm, zm):
    return WX0 + xm, WZ0 - zm


# ------------------------------------------------------------------ 輸入
def load_lake(path, lake_py=None):
    p = pathlib.Path(path)
    if not p.exists():
        if not lake_py:
            sys.exit(f"找不到 {p}；請提供 lake_map.bin，或用 --lake-py 指定 lake.py 重建")
        with tempfile.TemporaryDirectory() as tmp:
            src = pathlib.Path(lake_py).read_text(encoding="utf-8")
            src += "\nfinal_lake_map.astype('uint8').tofile('lake_map.bin')\n"
            (pathlib.Path(tmp) / "lake.py").write_text(src, encoding="utf-8")
            env = dict(os.environ, MPLBACKEND="Agg")
            subprocess.run([sys.executable, "lake.py"], cwd=tmp, env=env, check=True, capture_output=True)
            data = (pathlib.Path(tmp) / "lake_map.bin").read_bytes()
    else:
        data = p.read_bytes()
    if len(data) != LAKE_W * LAKE_W:
        sys.exit(f"lake_map.bin 大小應為 {LAKE_W * LAKE_W} bytes，實際 {len(data)}")
    return np.frombuffer(data, dtype=np.uint8).reshape(LAKE_W, LAKE_W)


# ------------------------------------------------------------------ 小工具
def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def fractal(shape, rng, sigmas=(28, 11, 4), amps=(1.0, 0.5, 0.25)):
    """低頻到高頻疊加的平滑雜訊，正規化到 0~1。"""
    out = np.zeros(shape)
    for s, a in zip(sigmas, amps):
        n = gaussian_filter(rng.random(shape), s, mode="reflect")
        n = (n - n.min()) / (n.max() - n.min() + 1e-9)
        out += a * n
    out /= sum(amps)
    return (out - out.min()) / (out.max() - out.min() + 1e-9)


class Canvas:
    """畫布與座標換算。"""

    def __init__(self, ox, oz, nx, nz):
        self.ox, self.oz, self.nx, self.nz = ox, oz, nx, nz

    def cell(self, xm, zm):
        return int(round(xm + self.ox)), int(round(zm + self.oz))

    def xm(self, cx):
        return cx - self.ox

    def zm(self, cz):
        return cz - self.oz


# ------------------------------------------------------------------ 既有地形 (無人機掃描)
def load_scan(path):
    """掃描檔每行 `bx bz top`：方塊座標與頂面座標 (整數；頂面 82 = 地面最上面那塊方塊的上表面)。"""
    rows = [tuple(int(float(t)) for t in ln.split()[:3]) for ln in pathlib.Path(path).read_text().splitlines() if ln.strip()]
    if not rows:
        sys.exit(f"{path} 是空的")
    return np.array(rows, dtype=np.int64)


def grid_existing(scan, cv, spike=7):
    """掃描點 -> (E 既有地形高度 (比地面高幾格), M 既有地形遮罩)。"""
    nz, nx = cv.nz, cv.nx
    rel = scan[:, 2] - (GROUND_Y + 1)
    vals, cnt = np.unique(rel, return_counts=True)
    mode = int(vals[cnt.argmax()])
    if 0 < abs(mode) <= 3:                       # 最常出現的高度應該是地面 (0)，有固定偏差就扣掉
        rel = rel - mode
    cx = (scan[:, 0] + 201 + cv.ox).astype(int)  # 方塊 bx 的中心 = bx+0.5 = -200.5 + x_map  =>  x_map = bx + 201
    cz = (-50 - scan[:, 1] + cv.oz).astype(int)  # 方塊 bz 的中心 = bz+0.5 = -49.5 - z_map  =>  z_map = -50 - bz
    ok = (cx >= 0) & (cx < nx) & (cz >= 0) & (cz < nz)
    E = np.full((nz, nx), np.nan)
    E[cz[ok], cx[ok]] = rel[ok]
    x0, x1, z0, z1 = cx[ok].min(), cx[ok].max() + 1, cz[ok].min(), cz[ok].max() + 1
    sub = E[z0:z1, x0:x1]
    idx = distance_transform_edt(np.isnan(sub), return_distances=False, return_indices=True)
    out = np.zeros((nz, nx))
    out[z0:z1, x0:x1] = sub[idx[0], idx[1]]       # 掃描範圍內，沒取樣的格子用最近的取樣值補滿
    out = np.clip(out, 0, None)
    if spike > 1:
        out = grey_opening(out, size=(spike, spike))   # 去掉樹木等細小突起
    M = out > 2
    lab, n = label(M)
    if n:
        small = np.bincount(lab.ravel()) < 80
        small[0] = False
        M &= ~small[lab]
    return out, M


# ------------------------------------------------------------------ 高度圖
def build(lake, peak=128, reach=80, beach=6, seed=7, z_limit=-16, bridges=(), canyon=None, excludes=(), bridge_blend=12.0, peak_low=None, peak_toward=None,
          relief_west=0.45, scan=None, scan_spike=7, scan_blend=40.0):
    """回傳 (高度圖 uint8, Canvas, 水遮罩, 缺口遮罩, 說明 dict)。

    z_limit : 世界 Z 的上限 (方塊座標，山不可超過)。南側 (z_map 小的那邊) 空間不夠時剖面會縮短。
    bridges : [(x0, x1, z0, z1), ...] 世界座標的矩形，範圍內保持平地，外圍 bridge_blend 格漸變。
    excludes: [(x0, x1, z0, z1), ...] 世界座標的矩形 = 已有的搬遷地形，不蓋山 (高度歸 0，不漸變)。
    relief_west: 西側 (X 越小) 額外加的起伏幅度 (0 = 不加)。
    scan    : load_scan() 的結果；有的話，掃描到的既有地形不蓋，山在它周圍 scan_blend 格內漸漸接到它的高度。
    canyon  : dict(x=世界X, z0=起點世界Z, width=谷底半寬, wall=壁寬, wiggle=彎曲幅度, period=彎曲週期) 或 None
    """
    zmin_map = int(math.ceil(w2m(0, z_limit)[1] * -1 - 1)) + 1     # 允許的最小 z_map (含 1 格安全距離)
    zmin_map = int(math.ceil(-49.5 - z_limit - 1)) + 1
    m_side = int(math.ceil(reach)) + 4
    m_south = min(m_side, -zmin_map)
    cv = Canvas(ox=m_side, oz=m_south, nx=LAKE_W + 2 * m_side, nz=LAKE_W + m_side + m_south)
    nz, nx = cv.nz, cv.nx

    water = np.zeros((nz, nx), bool)
    water[cv.oz:cv.oz + LAKE_W, cv.ox:cv.ox + LAKE_W] = lake > 0

    zz, xx = np.mgrid[0:nz, 0:nx]
    xm_, zm_ = xx - cv.ox, zz - cv.oz
    inside_map = (xm_ >= 0) & (xm_ < LAKE_W) & (zm_ >= 0) & (zm_ < LAKE_W)
    bite = ((xm_ - BITE_CX) ** 2 + (zm_ - BITE_CZ) ** 2 <= BITE_R ** 2) & inside_map
    scope = ~bite & ~water                         # 只蓋外圍；缺口維持平坦

    rng = np.random.default_rng(seed)
    d, (iz, ix) = distance_transform_edt(~water, return_indices=True)

    # 南側限制：沿「離最近水面的方向」往南能用的空間不夠時，縮短剖面 (坡度會稍微變陡)
    dz = zz - iz
    with np.errstate(divide="ignore", invalid="ignore"):
        south = np.where(d > 0, -dz / np.maximum(d, 1e-9), 0.0)
    room = (iz - cv.oz) - zmin_map - 2
    r_dir = np.where(south > 0.05, np.minimum(reach, room / np.maximum(south, 0.05)), reach)
    scale = gaussian_filter(np.clip(r_dir / reach, 0.35, 1.0), 6)

    warp = fractal((nz, nx), rng, sigmas=(30, 14), amps=(1.0, 0.4))
    ds = (d + (warp - 0.5) * 0.25 * reach) / scale        # 讓山脊線彎曲不規則

    rise, crest = 0.40 * reach, 0.15 * reach
    fall = reach - beach - rise - crest
    env = smoothstep((ds - beach) / rise) * (1.0 - smoothstep((ds - beach - rise - crest) / fall))

    # 不蓋山的陸地 (缺口) 與畫布南緣：山要在靠近它們前漸漸降到 0，避免懸崖
    blocked = (~water & ~scope) | (zm_ < zmin_map + 3)
    if blocked.any():
        env = env * smoothstep(distance_transform_edt(~blocked) / 25.0)

    ridged = 1.0 - np.abs(2 * fractal((nz, nx), rng) - 1)
    smooth = fractal((nz, nx), rng, sigmas=(18, 7), amps=(1.0, 0.5))
    shape = 0.45 + 0.55 * (0.6 * smooth + 0.4 * ridged)
    h = env * shape
    if peak_low is not None and peak_toward is not None:
        # 山高隨方位變化：朝 peak_toward (世界座標，例如搬遷地形的中心) 的那一側最高 = peak，背面最低 = peak_low
        tx, tz = w2m(*peak_toward)
        a0 = math.atan2(tz - 208, tx - 208)
        diff = np.arctan2(zm_ - 208, xm_ - 208) - a0
        w = ((1 + np.cos(diff)) / 2) ** 1.5
        h = h * (peak_low + (peak - peak_low) * w) / peak
    h = h * (peak / h.max())                     # 最高處剛好到 peak
    if relief_west > 0:
        wf = smoothstep((BITE_CX - xm_) / (LAKE_W / 2 + 1))            # 0 (湖中線以東) -> 1 (最西側)
        extra = fractal((nz, nx), rng, sigmas=(22, 9, 4), amps=(1.0, 0.6, 0.3))
        h = np.minimum(h * (1 + relief_west * wf * (2 * extra - 1)), peak)

    info = {}
    # ---- 峽谷：沿一條彎曲中線把山切開，谷底降回地面
    if canyon:
        x0m, z0m = w2m(canyon["x"], canyon["z0"])
        wig, per = canyon.get("wiggle", 8.0), canyon.get("period", 90.0)
        cx_line = x0m + cv.ox + wig * np.sin(2 * np.pi * (zz - cv.oz - z0m) / per)
        dc = np.abs(xx - cx_line)
        half = canyon.get("width", 5.0) * (0.75 + 0.5 * fractal((nz, nx), rng, sigmas=(12, 5), amps=(1.0, 0.5)))
        c = smoothstep((dc - half) / canyon.get("wall", 10.0))
        c = np.where(zz - cv.oz >= z0m, c, 1.0)
        h = h * c
        info["canyon_cells"] = int(((c < 0.5) & (h >= 0)).sum())
    # ---- 平橋讓位
    for (bx0, bx1, bz0, bz1) in bridges:
        xa, xb = sorted((w2m(bx0, 0)[0], w2m(bx1, 0)[0]))
        za, zb = sorted((w2m(0, bz0)[1], w2m(0, bz1)[1]))
        rect = (xm_ >= xa) & (xm_ <= xb) & (zm_ >= za) & (zm_ <= zb)
        h = h * smoothstep(distance_transform_edt(~rect) / bridge_blend)

    existing = E = None
    if scan is not None:
        E, existing = grid_existing(scan, cv, scan_spike)
        existing &= ~bite & ~water
        d_ex, (jz, jx) = distance_transform_edt(~existing, return_indices=True)
        wgt = 1.0 - smoothstep(d_ex / scan_blend)
        h = np.where(scope & ~existing, h * (1 - wgt) + E[jz, jx] * wgt, h)    # 靠近既有地形時，高度漸漸接到它
        h[existing] = 0                                                         # 既有地形不用蓋
        info["existing_cells"] = int(existing.sum())
    for (ex0, ex1, ez0, ez1) in excludes:
        xa, xb = sorted((w2m(ex0, 0)[0], w2m(ex1, 0)[0]))
        za, zb = sorted((w2m(0, ez0)[1], w2m(0, ez1)[1]))
        h[(xm_ >= xa) & (xm_ <= xb) & (zm_ >= za) & (zm_ <= zb)] = 0
    h = np.rint(h)
    h[~scope] = 0
    h[water] = 0
    h[zm_ < zmin_map + 1] = 0
    h = np.clip(h, 0, 255).astype(np.uint8)
    disp = h.astype(float)
    if existing is not None:
        disp[existing] = E[existing]
    info["display"], info["existing"] = disp, existing
    return h, cv, water, bite, info


def stats(h):
    return int((h > 0).sum()), int(h.astype(np.int64).sum()), int(h.max())


def max_step(h):
    hh = h.astype(np.int16)
    return int(max(np.abs(np.diff(hh, axis=0)).max(), np.abs(np.diff(hh, axis=1)).max()))


# ------------------------------------------------------------------ 材質
def shell_start(h, t):
    """每欄「殼」的起始層 (1 起算)。第 1..start-1 層是空心，start..h 層要蓋 (實心時 start = 1)。

    殼 = 距離空氣 (頂面或側面露出的那一格) 在 t 步以內 (曼哈頓距離) 的所有方塊，所以頂面和側面都至少有 t 層厚。
    每欄的殼一定是從某一層一路蓋到頂，所以只要比較鄰近欄位的高度就能算出來。"""
    hh = h.astype(np.int32)
    if t <= 0:
        return np.ones_like(hh)
    nz, nx = hh.shape
    pad = np.pad(hh, t)
    start = hh - t + 1
    for dz in range(-t, t + 1):
        for dx in range(-t, t + 1):
            r = abs(dx) + abs(dz)
            if 0 < r <= t:
                nb = pad[t + dz:t + dz + nz, t + dx:t + dx + nx]
                start = np.minimum(start, nb + 1 - (t - r))
    return np.clip(start, 1, None)


def assign_materials(h, seed=11, interior="S", shell=0, start=None):
    """每欄回傳由下往上的材質串。只有看得到的層 (比任一鄰欄高的部分、頂面) 才挑表面材質，其餘一律 interior；
    shell > 0 時，殼以內的空心部分用 "_" 表示 (不用蓋)。砂礫只出現在頂面，下面一定有實心層墊著，不會掉。"""
    rng = np.random.default_rng(seed)
    nz, nx = h.shape
    n_strata = fractal((nz, nx), rng, sigmas=(14, 6), amps=(1.0, 0.5))
    n_patch = fractal((nz, nx), rng, sigmas=(10, 4), amps=(1.0, 0.5))
    n_low = fractal((nz, nx), rng, sigmas=(16, 6), amps=(1.0, 0.5))
    hp = np.pad(h.astype(np.int16), 1)
    nb_min = np.minimum.reduce([hp[:-2, 1:-1], hp[2:, 1:-1], hp[1:-1, :-2], hp[1:-1, 2:]])
    nb_max = np.maximum.reduce([hp[:-2, 1:-1], hp[2:, 1:-1], hp[1:-1, :-2], hp[1:-1, 2:]])
    hmax = max(1, int(h.max()))
    if start is None:
        start = shell_start(h, shell)
    cols, totals = {}, dict.fromkeys(MATERIALS, 0)
    top_mat = np.full((nz, nx), "", dtype="<U1")
    for cz, cx in zip(*np.nonzero(h)):
        hh = int(h[cz, cx])
        e = max(0, min(int(nb_min[cz, cx]), hh - 1))           # 1..e 層被鄰欄擋住看不到；頂面一定看得到
        slope = hh - int(nb_min[cz, cx])                        # 側面裸露的高度
        flat = slope <= 2
        s1, p1, l1 = n_strata[cz, cx], n_patch[cz, cx], n_low[cz, cx]
        st = int(start[cz, cx])
        seq = (["_"] * (st - 1) + [interior] * max(0, e - st + 1)) if st <= e else ["_"] * (st - 1)
        for layer in range(max(e + 1, st), hh + 1):
            y = GROUND_Y + layer
            rel = layer / hmax                                  # 0~1：佔最高山高的比例
            top = layer == hh
            m = "S"
            if p1 > 0.58 and (slope >= 1 or top):
                m = "C"
            if not top and slope >= 1 and math.sin(y * 0.9 + s1 * 8) > 0.3:
                m = "T"
            if top and flat and rel < 0.32 + 0.17 * l1 and l1 > 0.3:
                m = "G"
            if top and flat and l1 > 0.82 and rel < 0.66:
                m = "G"
            if top and flat and rel < 0.14 + 0.08 * l1:
                m = "D"                                         # 低處用泥土
            if top and flat and rel >= 0.77 + 0.17 * l1:
                m = "N"
            if top and m == "G" and hh - st + 1 < 2:
                m = "S"                                         # 殼只剩一層：砂礫下面沒有東西墊著會掉，改石頭
            seq.append(m)
        top_mat[cz, cx] = seq[-1]
        runs, prev, cnt = [], seq[0], 0
        for m in seq:
            if m == prev:
                cnt += 1
            else:
                runs.append(f"{prev}{cnt}")
                prev, cnt = m, 1
            if m != "_":
                totals[m] += 1
        runs.append(f"{prev}{cnt}")
        cols[(cz, cx)] = "".join(runs)
    return cols, totals, top_mat, start


def order_bands(ok, fill, h, band=24, tile=6):
    """施工順序：由低到高分帶 (每帶 band 層)；同一帶再切成 tile×tile 的小塊，小塊之間用蛇形列序，
    每一塊「從最低的地方開始」(殼起點最低、接得上的欄)，再往相鄰、較高的欄一路蓋上去。
    還沒有接點的欄先跳過，等相鄰的塊蓋好再回來。tile=0 時退回整帶的蛇形列序。
    fill、h 是 {(a, b): 值}；回傳 (順序, 接不上的欄)。(逐層嚴格由低到高路徑太長，所以折衷成分帶 + 小塊。)"""
    import heapq
    bands = {}
    for p in ok:
        bands.setdefault((fill[p] - 1) // band, []).append(p)
    built, order, bad = set(), [], []

    def can(p):
        if fill[p] <= 1:
            return True
        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (p[0] + dz, p[1] + dx)
            if n in built and fill[n] <= fill[p] <= h[n]:
                return True
        return False

    def raster(p):
        return (p[0], p[1] if p[0] % 2 == 0 else -p[1])

    for b in sorted(bands):
        left = []
        if tile:
            groups = {}
            for p in bands[b]:
                groups.setdefault((p[0] // tile, p[1] // tile), []).append(p)
            for k in sorted(groups, key=lambda k: (k[0], k[1] if k[0] % 2 == 0 else -k[1])):
                pending = set(groups[k])
                by_raster = sorted(groups[k], key=raster)
                cnt = 0
                while pending:
                    seed = None                       # 這一塊裡接得上的欄中最低的
                    for p in by_raster:
                        if p in pending and can(p) and (seed is None or fill[p] < fill[seed]):
                            seed = p
                    if seed is None:
                        break
                    pq, queued = [(fill[seed], cnt, seed)], {seed}
                    cnt += 1
                    while pq:
                        _, _, p = heapq.heappop(pq)
                        if p not in pending or not can(p):
                            continue
                        pending.discard(p)
                        built.add(p)
                        order.append(p)
                        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                            n = (p[0] + dz, p[1] + dx)
                            if n in pending and n not in queued:
                                queued.add(n)
                                heapq.heappush(pq, (fill[n], cnt, n))
                                cnt += 1
                left.extend(pending)
        else:
            left = list(bands[b])
        todo = sorted(left, key=raster)
        while todo:
            nxt = []
            for p in todo:
                if can(p):
                    built.add(p)
                    order.append(p)
                else:
                    nxt.append(p)
            if len(nxt) == len(todo):                # 這一帶剩下的都接不上：留給「無法支撐」
                bad.extend(nxt)
                break
            todo = nxt
    return order, bad


def plan_support(h, start, pts, center=(208, 208), cv=None, band=24, tile=6):
    """決定一台無人機的「殼起點」與施工順序，保證每一欄的第一塊都放得上去。

    OC 的放置規則：目標格的鄰格 (腳下、四個側邊) 有方塊就放得上去。一欄的殼是 start..h 一路蓋到頂，
    第一塊 (start 層) 的支撐只可能是：start==1 (腳下是地面)，或鄰欄在同一層已有方塊 (鄰欄 start' <= start <= h')。
    殼的底面如果有「凹坑」(鄰欄的底都比它高)，坑底那塊就沒有支撐，所以把坑填到溢出高度 (priority-flood)：
    填完後每欄都有一個起點不比自己高的鄰欄，沿著它一路走一定會走到地面。
    只看本台自己負責的欄，不依賴別台 (別台蓋的進度不一定同步)。

    回傳 (新起點 dict, 施工順序 list, 無法支撐 list)。"""
    import heapq
    mine = set(pts)
    fill, done = {}, set()
    pq = []
    for p in pts:
        if start[p] <= 1:
            fill[p] = 1
            heapq.heappush(pq, (1, p))
    parent = {}
    while pq:
        lv, p = heapq.heappop(pq)
        if p in done:
            continue
        done.add(p)
        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (p[0] + dz, p[1] + dx)
            if n in mine and n not in done:
                v = max(int(start[n]), lv)
                if n not in fill or v < fill[n]:
                    fill[n] = v
                    parent[n] = p
                    heapq.heappush(pq, (v, n))
    bad = [p for p in pts if p not in done or fill[p] > h[p]]
    ok = [p for p in pts if p in done and fill[p] <= h[p]]

    def ang(p):
        if cv is not None:
            return math.atan2(cv.zm(p[0]) - center[0], cv.xm(p[1]) - center[1])
        return math.atan2(p[0] - center[0], p[1] - center[1])

    order, bad2 = order_bands(ok, fill, h, band, tile)
    bad.extend(bad2)
    new_start = {p: fill[p] for p in order}
    return new_start, order, bad


def split_for_drones(h, cv, cols, parts=3, start=None):
    """依「繞湖中心的角度」把工作量平分給 parts 台無人機；每台內部用蛇形列序，相鄰欄接著蓋。"""
    pts = list(cols.keys())
    ang = {p: math.atan2(cv.zm(p[0]) - 208, cv.xm(p[1]) - 208) for p in pts}
    order = sorted(pts, key=lambda p: ang[p])
    wt = (lambda p: int(h[p]) - int(start[p]) + 1) if start is not None else (lambda p: int(h[p]))
    total = sum(wt(p) for p in pts)
    groups, acc, g = [[] for _ in range(parts)], 0, 0
    for p in order:
        groups[g].append(p)
        acc += wt(p)
        if acc >= total * (g + 1) / parts and g < parts - 1:
            g += 1
    for g in range(parts):
        groups[g].sort(key=lambda p: (p[0], p[1] if p[0] % 2 == 0 else -p[1]))
    return groups


def estimate_days(columns, blocks, drones, per_layer):
    t_col = (LAKE_SECONDS - LAKE_BLOCKS * per_layer) / LAKE_COLUMNS   # 由湖一週反推每欄固定開銷
    return (columns * t_col + blocks * per_layer) / drones / 86400


# ------------------------------------------------------------------ 預覽
def _extent(cv):
    return [WX0 - cv.ox - 0.5, WX0 + (cv.nx - cv.ox) - 0.5, WZ0 + cv.oz + 0.5, WZ0 - (cv.nz - cv.oz) + 0.5]


def preview(disp, cv, water, bite, bridges, canyon, z_limit, path, excludes=(), existing=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import ListedColormap

    ext = _extent(cv)
    fig, ax = plt.subplots(figsize=(10, 10))
    ax.set_facecolor("#c9b98a")
    ax.imshow(np.where(water, 1, np.nan), cmap=ListedColormap(["#3a7bd5"]), origin="lower", extent=ext, vmin=0, vmax=1)
    ax.imshow(np.where(bite, 1, np.nan), cmap=ListedColormap(["#e8dfb8"]), origin="lower", extent=ext, vmin=0, vmax=1)
    im = ax.imshow(np.ma.masked_where(disp <= 0, disp + GROUND_Y), cmap="terrain", origin="lower", extent=ext,
                   vmin=GROUND_Y, vmax=MAX_Y)
    if existing is not None:
        ax.contour(existing.astype(float), levels=[0.5], origin="lower", extent=ext, colors="k", linewidths=1.2, linestyles=":")
    ax.axhline(z_limit, color="r", lw=1.2, ls="--")
    ax.text(ext[0] + 4, z_limit - 6, f"Z={z_limit} 上限", color="r", fontsize=9, va="top")
    for (x0, x1, z0, z1) in bridges:
        ax.add_patch(plt.Rectangle((min(x0, x1), min(z0, z1)), abs(x1 - x0), abs(z1 - z0), fill=False, ec="m", lw=1.5))
    for (x0, x1, z0, z1) in excludes:
        ax.add_patch(plt.Rectangle((min(x0, x1), min(z0, z1)), abs(x1 - x0), abs(z1 - z0), fill=True, fc="#00000022", ec="k", lw=1.2, ls=":"))
        ax.text((x0 + x1) / 2, (z0 + z1) / 2, "既有搬遷地形\n(不蓋山)", ha="center", va="center", fontsize=11)
    if canyon:
        ax.plot([canyon["x"]], [canyon["z0"]], "k^", ms=8)
    fig.colorbar(im, ax=ax, label="方塊頂面 Y（地面 81，上限 %d）" % MAX_Y, shrink=0.8)
    ax.set_title("環湖山體高度圖（世界座標，上方 = 北；虛線框 = 既有地形）")
    ax.set_xlabel("世界 X")
    ax.set_ylabel("世界 Z")
    ax.set_aspect("equal")
    fig.savefig(path, bbox_inches="tight", dpi=110)
    plt.close(fig)


MAT_COLORS = {"S": "#8a8a8a", "T": "#4b5563", "C": "#b4b0a6", "G": "#d2b48c", "N": "#ffffff", "D": "#7a5230"}


def preview_materials(top_mat, groups, cv, water, path, tags="ABC"):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import ListedColormap

    keys = list(MAT_COLORS)
    code = {"": np.nan, **{k: i for i, k in enumerate(keys)}}
    img = np.vectorize(lambda c: code[c], otypes=[float])(top_mat)
    ext = _extent(cv)
    fig, ax = plt.subplots(figsize=(10, 10))
    ax.set_facecolor("#b6a97e")
    ax.imshow(np.where(water, 1, np.nan), cmap=ListedColormap(["#3a7bd5"]), origin="lower", extent=ext, vmin=0, vmax=1)
    ax.imshow(img, cmap=ListedColormap([MAT_COLORS[k] for k in keys]), origin="lower", extent=ext, vmin=-0.5, vmax=len(keys) - 0.5)
    for g, pts in enumerate(groups):
        if pts:
            mid = sorted(pts, key=lambda p: math.atan2(cv.zm(p[0]) - 208, cv.xm(p[1]) - 208))[len(pts) // 2]
            wx, wz = m2w(cv.xm(mid[1]), cv.zm(mid[0]))
            ax.text(wx, wz, tags[g], color="r", fontsize=22, ha="center", va="center", alpha=0.8)
    ax.legend([plt.Rectangle((0, 0), 1, 1, fc=MAT_COLORS[k]) for k in keys], [MATERIALS[k] for k in keys], loc="upper right")
    ax.set_title("表面材質（紅字 = 負責的無人機）")
    ax.set_aspect("equal")
    fig.savefig(path, bbox_inches="tight", dpi=110)
    plt.close(fig)


def shell_blocks(h, t):
    st = shell_start(h, t)
    m = h > 0
    return int((h.astype(np.int64)[m] - st[m] + 1).sum())


def table(lake, a, scan=None):
    note = "、".join(x for x in ("橋通道" if a.bridge else "", "掃描地形" if scan is not None else "", "排除範圍" if a.exclude else "") if x)
    print(f"湖: {LAKE_COLUMNS:,} 欄 / {LAKE_BLOCKS:,} 方塊 (單台一週)。套用: 南限 Z={a.z_limit}、{note or '無額外限制'}、殼厚 {a.shell}")
    print(f"{'峰高':>5}{'背面':>5}{'山寬':>6}{'實心方塊':>12}{'殼狀方塊':>12}{'殼=湖的':>9}{'1台':>6}{'3台':>6}  (天，每層 0.5s，以殼狀計)")
    for peak, low, reach in [(47, None, 80), (80, 40, 120), (128, 50, 140), (128, None, 160), (128, None, 220)]:
        h, cv, _, _, _ = build(lake, peak, reach, a.beach, a.seed, a.z_limit, a.bridge, None, a.exclude, a.bridge_blend,
                               low, a.peak_toward if low else None, a.relief_west, scan, a.scan_spike, a.scan_blend)
        c, b, _ = stats(h)
        sb = shell_blocks(h, a.shell)
        print(f"{peak:>5}{(low or '-'):>5}{reach:>6}{b:>12,}{sb:>12,}{sb / LAKE_BLOCKS:>8.1f}×"
              f"{estimate_days(c, sb, 1, 0.5):>6.0f}{estimate_days(c, sb, 3, 0.5):>6.0f}")


# ------------------------------------------------------------------ 主程式
def parse_rect(s):
    v = [float(t) for t in s.split(",")]
    if len(v) != 4:
        raise argparse.ArgumentTypeError("格式: x0,x1,z0,z1 (世界座標)")
    return tuple(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lake", default="lake_map.bin")
    ap.add_argument("--lake-py")
    ap.add_argument("--peak", type=int, default=MAX_Y - GROUND_Y, help="最高山高 (預設 128 = 頂面 Y 209)")
    ap.add_argument("--reach", type=int, default=80, help="山從湖岸往外延伸的總寬度 (格)")
    ap.add_argument("--beach", type=int, default=6)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--z-limit", type=int, default=-16, help="世界 Z 上限 (山不可超過)")
    ap.add_argument("--peak-low", type=int, help="背面最低山高；和 --peak-toward 一起用，山高會朝該方向漸漸升高")
    ap.add_argument("--peak-toward", type=lambda t: tuple(float(v) for v in t.split(",")), help="x,z 世界座標：山最高的方向 (例如搬遷地形中心)")
    ap.add_argument("--relief-west", type=float, default=0.45, help="西側額外起伏幅度 (0 = 不加)")
    ap.add_argument("--bridge", type=parse_rect, action="append", default=[], help="橋/道路讓位矩形 x0,x1,z0,z1 (世界座標，可重複)")
    ap.add_argument("--bridge-blend", type=float, default=12.0, help="通道兩側的漸變寬度 (格)")
    ap.add_argument("--existing", help="無人機掃描檔 (每行 bx bz top)；掃到的既有地形不蓋，山會接到它")
    ap.add_argument("--scan-spike", type=int, default=7, help="去掉樹木用的視窗大小 (1 = 不處理)")
    ap.add_argument("--scan-blend", type=float, default=40.0, help="山接到既有地形的漸變寬度 (格)")
    ap.add_argument("--exclude", type=parse_rect, action="append", default=[], help="還沒掃描前，先用矩形粗略排除既有地形 x0,x1,z0,z1")
    ap.add_argument("--canyon-x", type=float, help="峽谷中線世界 X；不給就不做峽谷")
    ap.add_argument("--canyon-z0", type=float, default=-449.5, help="峽谷起點世界 Z (往北切到山外)")
    ap.add_argument("--canyon-width", type=float, default=5.0)
    ap.add_argument("--canyon-wall", type=float, default=10.0)
    ap.add_argument("--shell", type=int, default=2, help="殼厚 (層)；0 = 全實心。至少 2，砂礫下才一定有實心層墊著")
    ap.add_argument("--interior", choices=list("SC"), default="S", help="殼裡看不到的部分用石頭(S)還是鵝卵石(C)")
    ap.add_argument("--drones", type=int, default=3)
    ap.add_argument("--tags", default=None, help="每台無人機的通道標籤，例如 AC (預設 ABC 的前 N 個)；檔名 mountain_cols_<標籤>.txt")
    ap.add_argument("--table", action="store_true", help="只印各種高度/山寬的工程量比較")
    ap.add_argument("--out", default=".")
    a = ap.parse_args()
    if a.shell == 1:
        sys.exit("--shell 至少要 2 (或 0 = 全實心)")

    lake = load_lake(a.lake, a.lake_py)
    scan = load_scan(a.existing) if a.existing else None
    canyon = None if a.canyon_x is None else dict(x=a.canyon_x, z0=a.canyon_z0, width=a.canyon_width, wall=a.canyon_wall)
    if a.table:
        table(lake, a, scan)
        return
    h, cv, water, bite, info = build(lake, a.peak, a.reach, a.beach, a.seed, a.z_limit, a.bridge, canyon, a.exclude,
                                     a.bridge_blend, a.peak_low, a.peak_toward, a.relief_west, scan, a.scan_spike, a.scan_blend)
    cols_n, solid_blocks, top = stats(h)
    assert GROUND_Y + top <= MAX_Y, "超過高度上限"

    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    h.tofile(out / "mountain_map.bin")
    tags = a.tags or "ABC"[:a.drones]
    assert len(tags) >= a.drones, "--tags 的標籤數要不少於 --drones"
    start0 = shell_start(h, a.shell)
    pts_all = [(int(z), int(x)) for z, x in zip(*np.nonzero(h))]
    groups = split_for_drones(h, cv, {p: "" for p in pts_all}, a.drones, start0)
    start = start0.copy()
    bad_all = 0
    if a.shell > 0:
        new_groups = []
        for pts in groups:
            ns, order, bad = plan_support(h, start0, pts, cv=cv)
            for p, v in ns.items():
                start[p] = v
            for p in bad:                       # 理論上很少；先保守地蓋成實心 (從地面疊上去)，並回報數量
                start[p] = 1
            bad_all += len(bad)
            new_groups.append(order + list(bad))
        groups = new_groups
    cols, totals, top_mat, start = assign_materials(h, interior=a.interior, shell=a.shell, start=start)
    blocks = int((h.astype(np.int64)[h > 0] - start[h > 0] + 1).sum())
    files = []
    for g, pts in enumerate(groups):
        name = f"mountain_cols_{tags[g]}.txt"
        with open(out / name, "w", encoding="utf-8") as f:
            for (cz, cx) in pts:
                f.write(f"{cv.xm(cx)} {cv.zm(cz)} {int(h[cz, cx])} {cols[(cz, cx)]}\n")
        files.append((name, len(pts), sum(int(h[p]) - int(start[p]) + 1 for p in pts)))
    meta = dict(canvas_w=cv.nx, canvas_h=cv.nz, ox=cv.ox, oz=cv.oz, world_x0=WX0, world_z0=WZ0,
                ground_y=GROUND_Y, max_y=GROUND_Y + top, z_limit=a.z_limit, peak=a.peak, reach=a.reach, shell=a.shell,
                columns=cols_n, solid_blocks=solid_blocks, blocks=blocks, materials=totals,
                cruise_y_min=GROUND_Y + top + 3, existing_cells=info.get("existing_cells", 0),
                drones=[dict(file=n, columns=c, blocks=b) for n, c, b in files])
    (out / "mountain_meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    preview(info["display"], cv, water, bite, a.bridge, canyon, a.z_limit, out / "mountain_preview.png", a.exclude, info["existing"])
    preview_materials(top_mat, groups, cv, water, out / "mountain_materials.png", tags)

    print(f"畫布 {cv.nx}×{cv.nz}（左右外擴 {cv.ox}、南側外擴 {cv.oz}）| 欄數 {cols_n:,}")
    print(f"實心 {solid_blocks:,} 方塊 → 殼厚 {a.shell}：{blocks:,} 方塊（湖的 {blocks / LAKE_BLOCKS:.1f}×，省 {100 * (1 - blocks / solid_blocks):.0f}%）")
    if a.shell > 0:
        thin = int(((h > 0) & (h - start + 1 < 2)).sum())
        print(f"殼支撐規劃：凹坑填平後殼只剩 1 層的欄 {thin:,}；沒有任何可接鄰欄而改蓋實心的欄 {bad_all:,}")
    print(f"最高頂面 Y={GROUND_Y + top} | 相鄰最大落差 {max_step(h)} | 無人機巡航高度至少 Y={GROUND_Y + top + 3}"
          + (f" | 既有地形 {info['existing_cells']:,} 欄" if scan is not None else ""))
    print("材質用量:", "、".join(f"{MATERIALS[k]} {v:,}（{v / 64:,.0f} 組）" for k, v in totals.items()))
    for n, c, b in files:
        print(f"  {n}: {c:,} 欄 / {b:,} 方塊")
    print("工期估算 (以湖一週反推每欄開銷；每層耗時是未知數，列三種情況):")
    for pl in (0.3, 0.5, 0.8):
        print(f"  每層 {pl}s: 1 台 {estimate_days(cols_n, blocks, 1, pl):.0f} 天 / 2 台 {estimate_days(cols_n, blocks, 2, pl):.0f} 天"
              f" / 3 台 {estimate_days(cols_n, blocks, 3, pl):.0f} 天")


if __name__ == "__main__":
    main()
