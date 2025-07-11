#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

rm -r bin
rm -r include

mkdir bin
mkdir include

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DIR="$PROJECT_ROOT/demos/NRI/bin"
INCLUDE_DIR="$PROJECT_ROOT/demos/NRI/include"

mkdir -p "$BIN_DIR" "$INCLUDE_DIR"

ln -sf "$PROJECT_ROOT/external/NRI/_Bin/Release" "$BIN_DIR/NRI"
ln -sf "$PROJECT_ROOT/external/glfw/build/src/Debug" "$BIN_DIR/GLFW"

ln -sf "$PROJECT_ROOT/external/NRI/Include" "$INCLUDE_DIR/NRI"
ln -sf "$PROJECT_ROOT/external/glfw/include/GLFW" "$INCLUDE_DIR/GLFW"