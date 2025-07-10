#!/bin/bash

# Builds all of the non-zig dependencies with complex build steps.

rm -rf external/
mkdir external/

echo "Building NRI..."

if [ ! $NRI_SRC ]; then
    echo "`NRI_SRC` must be set to the root of NRI's repository."
    exit -1
fi

NRI_BUILD_ROOT="external/NRI"
NRI_SRC=$(realpath $NRI_SRC)

echo "Resolved NRI source to \"$NRI_SRC\""

mkdir -p $NRI_BUILD_ROOT
cd $NRI_BUILD_ROOT

mkdir -p "build"
cd "build"
cmake $NRI_SRC \
    -DCMAKE_SOURCE_DIR="/dev/null" \
    -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="${NRI_BUILD_ROOT}bin" \
    -DNRI_ENABLE_IMGUI_EXTENSION=ON \
    -DCMAKE_MSVC_RUNTIME_LIBRARY="MultiThreaded$<$<CONFIG:Debug>:Debug>" # If on windows, statically link the MSVC runtime; required for it to work properly with Zig.
cmake --build . --config Release -j $(nproc)
cd ..