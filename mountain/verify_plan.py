"""檢查 mountain_cols_*.txt 的施工順序：每一塊放下去時，目標格的腳下或四個側邊必須已經有方塊 (OC 的放置規則)。
每台無人機各自獨立檢查 (只算自己蓋好的方塊 + 地面)，砂礫 (G) 另外檢查腳下要有方塊。
用法: python verify_plan.py <輸出資料夾>"""
import re
import sys
import pathlib

RUN = re.compile(r"([A-Z_])(\d+)")


def check(path):
    built = set()
    stats = dict(columns=0, blocks=0, no_support=0, gravel_float=0, hollow_in_run=0, first_bad=None)
    for line in open(path, encoding="utf-8"):
        x, z, h, mats = line.split()
        x, z, h = int(x), int(z), int(h)
        seq = []
        for m, n in RUN.findall(mats):
            seq += [m] * int(n)
        assert len(seq) == h, (line, len(seq), h)
        first = next(i for i, m in enumerate(seq) if m != "_")       # 0 起算
        if any(m == "_" for m in seq[first:]):
            stats["hollow_in_run"] += 1
        stats["columns"] += 1
        for i in range(first, h):
            layer = i + 1
            sup = layer == 1 or (x, z, layer - 1) in built or any(
                (x + dx, z + dz, layer) in built for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            if not sup:
                stats["no_support"] += 1
                stats["first_bad"] = stats["first_bad"] or (x, z, layer)
            if seq[i] == "G" and not (layer == 1 or (x, z, layer - 1) in built):
                stats["gravel_float"] += 1
            built.add((x, z, layer))
            stats["blocks"] += 1
    return stats


if __name__ == "__main__":
    d = pathlib.Path(sys.argv[1])
    bad = False
    for f in sorted(d.glob("mountain_cols_*.txt")):
        s = check(f)
        print(f.name, s)
        bad |= bool(s["no_support"] or s["gravel_float"] or s["hollow_in_run"])
    sys.exit(1 if bad else 0)
