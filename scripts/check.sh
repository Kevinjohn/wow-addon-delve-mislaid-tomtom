#!/usr/bin/env sh
# Run the same checks locally that you'd want green before committing:
#   * luacheck over the addon (config in .luacheckrc; tests are excluded there)
#   * the behaviour harness in tests/run.lua
#
# Usage:  sh scripts/check.sh   (from the repo root, or anywhere)
set -e

cd "$(dirname "$0")/.."

echo "==> luacheck"
luacheck *.lua

# The tests target Lua 5.1 syntax, so any 5.1+ interpreter works — including
# LuaJIT. Use the first one we find.
LUA=""
for candidate in lua lua5.4 lua5.3 lua5.2 lua5.1 luajit; do
	if command -v "$candidate" >/dev/null 2>&1; then
		LUA="$candidate"
		break
	fi
done

if [ -z "$LUA" ]; then
	echo "error: no Lua interpreter found (tried lua, lua5.x, luajit)" >&2
	exit 1
fi

echo "==> tests ($LUA)"
"$LUA" tests/run.lua
