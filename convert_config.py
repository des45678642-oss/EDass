"""Convert the old ae_config.txt into ae_config.json.

Usage: python convert_config.py ae_config.txt [ae_config.json]

Old line format:  slot=min_stock=req_qty=cooldown=priority
  min_stock > 0 and req_qty > 0  -> mode_tag "restock"  (cooldown = seconds)
  min_stock > 0 and req_qty == 0 -> mode_tag "clone"    (old cooldown field = circuit number)
  anything else (e.g. just "46") -> mode_tag "monitor"
"""
import json
import re
import sys

LINE = re.compile(r"^(\d+)=?(\d*)=?(\d*)=?(\d*)=?(\d*)$")


def convert(text):
    out = {"database": None, "items": []}
    section = None
    for raw in text.splitlines():
        line = re.sub(r"[\x00-\x1f]", "", raw)
        if not line or line.startswith("#"):
            continue
        low = line.lower()
        if "[items]" in low:
            section = "items"
            continue
        if "[fluids]" in low:
            section = "fluids"
            continue
        if "[settings]" in low:
            continue
        m = re.match(r"^target_database\s*=\s*(\S+)", line)
        if m:
            out["database"] = m.group(1)
            continue
        if section != "items":
            continue
        m = LINE.match(line)
        if not m:
            continue
        slot, mn, req, cd, prio = (int(g) if g else None for g in m.groups())
        if slot is None or slot <= 0:
            continue
        mn = mn or 0
        req = req or 0
        if mn > 0 and req == 0:
            item = {"slot": slot, "mode_tag": "clone", "target_quantity": mn,
                    "circuit": cd if cd else 1, "priority": prio if prio else 9}
        elif mn > 0 and req > 0:
            item = {"slot": slot, "mode_tag": "restock", "target_quantity": mn, "target_once": req}
            if cd is not None:
                item["cooldown"] = cd
        else:
            item = {"slot": slot, "mode_tag": "monitor"}
        out["items"].append(item)
    if out["database"] is None:
        del out["database"]
    return out


def dumps(data):
    lines = ["{"]
    if "database" in data:
        lines.append('  "database": %s,' % json.dumps(data["database"]))
    lines.append('  "items": [')
    rows = ["    " + json.dumps(i, ensure_ascii=False) for i in data["items"]]
    lines.append(",\n".join(rows))
    lines.append("  ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        data = convert(f.read())
    text = dumps(data)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
