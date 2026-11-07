"""robot/server.lua 檔案下載的模擬測試 (模擬 component / event / filesystem)。

用法: python run_server_tests.py [repo 路徑]   (需要 pip install lupa)
"""
import pathlib
import sys
import tempfile

from lupa.lua53 import LuaRuntime

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent).resolve()
SERVER = (ROOT / "robot" / "server.lua").read_text(encoding="utf-8")
MODEM = "0456aae326c34ae5882179ef965ed130"
CLIENT = "client-addr-0001"


def run(files, requests):
    """requests: list of (檔名, 標籤或 None)。每個請求後客戶端回 CONTINUE。回傳 modem.send 紀錄。"""
    tmp = pathlib.Path(tempfile.mkdtemp())
    for name, data in files.items():
        (tmp / name).write_bytes(data.encode("utf-8"))
    lua = LuaRuntime(unpack_returned_tuples=True)
    sent = []
    script = []
    for name, flags in requests:
        ev = ["modem_message", MODEM, CLIENT, 101, 0, "GET_FILE", name]
        if flags is not None:
            ev.append(flags)
        script.append(ev)
        script.append(["modem_message", MODEM, CLIENT, 101, 0, "CONTINUE"])

    def pull(*a):
        if not script:
            raise RuntimeError("SCRIPT_END")
        return lua.table_from(script.pop(0), 1) if False else tuple(script.pop(0))

    modem = lua.table_from({
        "address": MODEM,
        "open": lambda *a: True,
        "setStrength": lambda *a: 0,
        "send": lambda *a: sent.append(list(a)),
        "broadcast": lambda *a: True,
    })
    lua.globals().__setitem__("_PY", lua.table_from({"pull": pull, "modem": modem, "tmp": str(tmp)}))
    prelude = """
    local PY = _PY
    local real_open = io.open
    io.open = function(path, mode)
      path = path:gsub("^/mnt/4c8/", PY.tmp .. "/")
      return real_open(path, mode)
    end
    os.sleep = function() end
    local mods = {
      component = { list = function(t) return function() return nil end end,
                    type = function() return "modem" end, proxy = function() return PY.modem end,
                    isAvailable = function() return false end, invoke = function() end, modem = PY.modem },
      event = { pull = function(...) return PY.pull(...) end },
      filesystem = { canonical = function(p) return (p:gsub("//+", "/"):gsub("/$", "")) end,
                     concat = function(a, b) return a .. "/" .. b end,
                     exists = function(p) local f = io.open(p, "r") if f then f:close() return true end return false end,
                     isDirectory = function() return false end },
    }
    function require(n) return mods[n] end
    """
    lua.execute(prelude)
    try:
        lua.execute(SERVER)
    except Exception as e:
        if "SCRIPT_END" not in str(e):
            raise
    return [s for s in sent if len(s) > 2 and s[1] == 101]


def kinds(sent):
    return [s[2] for s in sent]


results = []


def test(name, fn):
    try:
        fn()
        print("PASS ", name)
        results.append(True)
    except Exception as e:
        print("FAIL ", name, "->", repr(e))
        results.append(False)


LUA_SRC = "-- 註解\nlocal a = 1  -- 尾端註解\n\n    print(\"-- 字串裡的 -- 要保留\", a)\n"


def t_default_lines():
    sent = run({"a.lua": LUA_SRC}, [("a.lua", None)])
    k = kinds(sent)
    assert k[0] == "FILE_START" and k.count("FILE_LINE") == 4 and k[-1] == "FILE_END", k
    assert sent[1][4] == "-- 註解", sent[1]          # 預設不精簡，原樣逐行


def t_block_single():
    sent = run({"a.lua": LUA_SRC}, [("a.lua", "block")])
    blocks = [s for s in sent if s[2] == "FILE_BLOCK"]
    assert len(blocks) == 1 and blocks[0][5] == LUA_SRC, blocks
    assert blocks[0][3] == 1 and blocks[0][4] == 1
    assert "FILE_LINE" not in kinds(sent)


def t_block_multi():
    data = "x" * 20000
    sent = run({"big.txt": data}, [("big.txt", "block")])
    blocks = [s for s in sent if s[2] == "FILE_BLOCK"]
    assert len(blocks) == 3 and all(len(b[5]) <= 7000 for b in blocks), [len(b[5]) for b in blocks]
    assert "".join(b[5] for b in blocks) == data


def t_minify():
    sent = run({"a.lua": LUA_SRC}, [("a.lua", "block,minify")])
    b = [s for s in sent if s[2] == "FILE_BLOCK"][0][5]
    assert b == 'local a = 1\nprint("-- 字串裡的 -- 要保留", a)', repr(b)
    sent = run({"a.lua": LUA_SRC}, [("a.lua", "minify")])
    lines = [s[4] for s in sent if s[2] == "FILE_LINE"]
    assert lines == ['local a = 1', 'print("-- 字串裡的 -- 要保留", a)'], lines


def t_not_minified_by_default_block():
    sent = run({"a.lua": LUA_SRC}, [("a.lua", "block")])
    assert "-- 註解" in [s for s in sent if s[2] == "FILE_BLOCK"][0][5]


def t_block_line_count():
    # FILE_START 的行數要和客戶端 f:lines() 數的一致 (結尾有無換行都一樣)
    for data, n in (("a\nb\n", 2), ("a\nb", 2), ("a\n\nb\n", 3), ("x", 1)):
        sent = run({"a.txt": data}, [("a.txt", "block")])
        assert sent[0][2] == "FILE_START" and sent[0][4] == n, (data, sent[0])


test("預設：逐行、不精簡 (與舊行為相同)", t_default_lines)
test("block：小檔一塊傳完，內容原樣", t_block_single)
test("block：大檔依位元組切塊，每塊 ≤ 7000，合併後相同", t_block_multi)
test("minify：只在有標籤時精簡 (字串裡的 -- 保留)", t_minify)
test("只寫 block 不會精簡", t_not_minified_by_default_block)
test("block：FILE_START 的行數與 f:lines() 一致", t_block_line_count)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
