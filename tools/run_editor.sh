#!/bin/sh
# Runs the world editor during development (exported builds use the "World Editor" preset).
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
cd "$(dirname "$0")/.." && "$GODOT" --path . res://editor/editor_main.tscn "$@"
