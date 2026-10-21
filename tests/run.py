#!/usr/bin/env python3
"""Run the PocketBook Wi-Fi patch simulation under LuaJIT (via lupa).

    pip install lupa
    git clone --depth 1 https://github.com/koreader/koreader /path/to/koreader
    python3 tests/run.py /path/to/koreader

    # Same scenarios against a tree with upstream/pocketbook-wifi.diff applied (no userpatch):
    python3 tests/run.py --upstream /path/to/patched-koreader
"""
import os
import sys

from lupa import luajit21

here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
upstream = "--upstream" in args
args = [a for a in args if a != "--upstream"]
ko_dir = os.path.abspath(args[0] if args else os.path.join(here, "..", "..", "koreader"))

lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
g.KO_DIR = ko_dir
g.TESTS_DIR = here
g.UPSTREAM = upstream
g.PATCH = os.path.join(here, "..", "patches", "2-pocketbook-wifi.lua")
report, failed = lua.execute('return dofile(TESTS_DIR .. "/test_wifi.lua")')
print(report)
print(f"\n{int(failed)} failed")
sys.exit(1 if failed else 0)
