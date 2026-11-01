import sys, tempfile, pathlib
from lupa.lua53 import LuaRuntime
d = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "bee").resolve()
t = tempfile.mkdtemp(prefix="bee_")
lua = LuaRuntime()
lua.globals().BEE_DIR = str(d).replace("\\", "/")
lua.globals().TMP_DIR = t.replace("\\", "/")
failed = lua.execute(open(d / "test_bee.lua", encoding="utf-8").read())
sys.exit(1 if failed else 0)
