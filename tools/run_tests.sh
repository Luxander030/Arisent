#!/bin/sh
# Usage: tools/run_tests.sh [filter]
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
FILTER='^Godot Engine|^$|leaked|at: (cleanup|clear|finalize|~)|resources still in use|PagedAllocator|RID allocations|^\[|^\s*$|reimport|loading_editor'
cd "$(dirname "$0")/.." || exit 1
# Refresh the class cache so new class_name scripts are visible.
"$GODOT" --headless --path . --import 2>&1 | grep -E "ERROR|Error" | grep -v "^\s*$"
"$GODOT" --headless --path . --script res://tests/run_tests.gd -- "$@" 2>&1 | grep -vE "$FILTER"
