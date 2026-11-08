"""把已經產生好的 mountain_cols_*.txt 依新的施工順序重排 (不改山的形狀和材質，只改順序)。
順序規則見 mountain.py 的 order_bands：分帶 (每帶 24 層)，同一帶切成小塊，每塊從最低的地方開始往上蓋。
用法: python reorder_cols.py <輸入資料夾> <輸出資料夾> [tile=6] [band=24]
輸出後請用 verify_plan.py 檢查。"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from mountain import order_bands  # noqa: E402


def reorder(src, dst, band=24, tile=6):
    rows, fill, hh = {}, {}, {}
    for line in open(src, encoding="utf-8"):
        x, z, h, mats = line.split()
        p = (int(z), int(x))
        lead = re.match(r"_(\d+)", mats)
        fill[p] = int(lead.group(1)) + 1 if lead else 1
        hh[p] = int(h)
        rows[p] = line.rstrip("\n")
    order, bad = order_bands(list(rows), fill, hh, band, tile)
    order += bad                                    # 理論上沒有；保守地接在最後
    assert len(order) == len(rows) and set(order) == set(rows)
    with open(dst, "w", encoding="utf-8") as f:
        for p in order:
            f.write(rows[p] + "\n")
    return len(order), len(bad)


if __name__ == "__main__":
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    tile = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    band = int(sys.argv[4]) if len(sys.argv) > 4 else 24
    dst.mkdir(parents=True, exist_ok=True)
    for f in sorted(src.glob("mountain_cols_*.txt")):
        n, bad = reorder(f, dst / f.name, band, tile)
        print(f"{f.name}: {n:,} 欄，接不上 {bad}")
