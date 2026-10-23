import sys, tempfile, pathlib
from lupa.lua53 import LuaRuntime
d = pathlib.Path(sys.argv[1]).resolve()
t = tempfile.mkdtemp(prefix="edass_")
lua = LuaRuntime()
lua.globals().EDASS_DIR = str(d).replace("\\", "/")
lua.globals().TMP_DIR = t.replace("\\", "/")
failed = lua.execute(open(d / "test_edass.lua", encoding="utf-8").read())
sys.exit(1 if failed else 0)
