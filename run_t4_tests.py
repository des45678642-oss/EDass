"""robot/mountain_t4.lua 的模擬測試 (假的 modem / event / io)：分批派發、整批回報後才送下一批、進度存檔、resume 接續。

用法: python run_t4_tests.py [repo 路徑]   (需要 pip install lupa)
"""
import os
import pathlib
import sys
import tempfile

from lupa.lua53 import LuaRuntime

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent).resolve()
T4 = (ROOT / "robot" / "mountain_t4.lua").read_text(encoding="utf-8")


def run(tmp, cmds, answer):
    """cmds：輸入的指令序列；answer(tag, id, payload) -> BATCH_DONE 的參數 tuple，或 None 表示不回。回傳送出的批次紀錄。"""
    os.chdir(tmp)
    lua = LuaRuntime(unpack_returned_tuples=True)
    sent, pending, cmds = [], [], list(cmds)

    def broadcast(port, *a):
        assert a[0] == "SERVER_CMD" and a[2] == "build_batch", a
        tag, bid, cruise, payload = a[1], a[3], a[4], a[5]
        assert len(a) + 1 <= 8 and len(payload.encode()) < 7000      # 封包部分數與大小上限
        sent.append((tag, bid, cruise, payload))
        r = answer(tag, bid, payload)
        if r is not None:
            pending.append(("modem_message", "l", "srv", 100, 0, tag, "DRONE_REPORT", "REPORT", "BATCH_DONE", bid) + tuple(r))

    idle = {"n": 0}

    def pull(*a):
        if pending:
            idle["n"] = 0
            return pending.pop(0)
        idle["n"] += 1
        if idle["n"] > 5:                      # 連續沒有任何回報：結束這次模擬 (真機上會一直等)
            raise RuntimeError("SIM_END")
        return (None,)

    def read(*a):
        return cmds.pop(0) if cmds else "exit"

    lua.globals()["_PY"] = lua.table_from({
        "broadcast": broadcast, "pull": pull, "read": read, "write": lambda *a: None})
    lua.execute("""
    local PY = _PY
    local modem = { open = function() end, broadcast = PY.broadcast }
    local mods = { component = { modem = modem }, event = { pull = function(...) return PY.pull(...) end } }
    function require(n) return mods[n] end
    io.read = function() return PY.read() end
    io.write = function() end
    print = function() end
    os.time = os.time
    """)
    try:
        lua.execute(T4)
    except Exception as e:
        if "SIM_END" not in str(e):
            raise
    return sent


def setup(a_lines, c_lines):
    tmp = tempfile.mkdtemp()
    pathlib.Path(tmp, "mountain_cols_B.txt").write_text("\n".join(a_lines) + "\n")
    pathlib.Path(tmp, "mountain_cols_C.txt").write_text("\n".join(c_lines) + "\n")
    return tmp


A = [f"{i} 1 3 S3" for i in range(100)]
C = [f"{i} 2 4 S4" for i in range(70)]
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


def t_all_batches():
    tmp = setup(A, C)
    sent = run(tmp, ["start", "y"], lambda tag, bid, payload: (payload.count(";") + 1, 0, ""))
    got = {"B": [], "C": []}
    for tag, bid, cruise, payload in sent:
        assert cruise == 203
        got[tag] += payload.split(";")
    assert got["B"] == A and got["C"] == C, (len(got["B"]), len(got["C"]))
    assert all(len(p.split(";")) <= 40 for _, _, _, p in sent)
    prog = pathlib.Path(tmp, "mountain_progress.txt").read_text()
    assert "B 100" in prog and "C 70" in prog, prog


def t_waits_for_ack():
    tmp = setup(A, C)
    sent = run(tmp, ["start", "y"], lambda tag, bid, payload: None)     # 都不回報：每台只會送出第一批
    assert [s[0] for s in sent] == ["B", "C"] and all(s[1] == 1 for s in sent), [(s[0], s[1]) for s in sent]


def t_resume():
    tmp = setup(A, C)
    state = {"n": 0}

    def answer(tag, bid, payload):          # 只回報前 3 批，之後 "斷線"
        state["n"] += 1
        return (payload.count(";") + 1, 0, "") if state["n"] <= 3 else None

    run(tmp, ["start", "y"], answer)
    prog1 = pathlib.Path(tmp, "mountain_progress.txt").read_text()
    sent = run(tmp, ["resume"], lambda tag, bid, payload: (payload.count(";") + 1, 0, ""))
    first = {}
    for tag, bid, cruise, payload in sent:
        first.setdefault(tag, payload.split(";")[0])
    done = dict((l.split()[0], int(l.split()[1])) for l in prog1.strip().splitlines())
    assert first["B"] == A[done["B"]] and first["C"] == C[done["C"]], (first, done)
    assert pathlib.Path(tmp, "mountain_progress.txt").read_text().split() == ["B", "100", pathlib.Path(tmp, "mountain_cols_B.txt").stat().st_size.__str__(), "C", "70", pathlib.Path(tmp, "mountain_cols_C.txt").stat().st_size.__str__()]


def t_failed_log():
    tmp = setup(A, C)
    run(tmp, ["start", "y"], lambda tag, bid, payload: (payload.count(";") + 1, 2 if tag == "B" and bid == 1 else 0, "-28,219,place@3;5,6,travel"))
    fb = pathlib.Path(tmp, "mountain_failed_B.txt").read_text().splitlines()
    assert fb == ["1 2 -28,219,place@3;5,6,travel"], fb
    assert pathlib.Path(tmp, "mountain_failed_C.txt").read_text() == ""


test("失敗的欄寫入 mountain_failed_<通道>.txt", t_failed_log)
test("兩台各自把清單分批送完，內容與順序不變，進度存檔", t_all_batches)
test("沒收到整批回報前不會送下一批", t_waits_for_ack)
test("中斷後 resume 從存檔的位置接著送", t_resume)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
