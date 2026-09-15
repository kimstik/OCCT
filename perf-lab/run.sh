#!/bin/bash
# Perf lab: build OCCT (FoundationClasses + ModelingData + ModelingAlgorithms) in a CadQuery-like
# configuration, build the workload/bench programs against it, time them, and sample with perf.
#
# Environment (all optional):
#   CC / CXX            compilers (default gcc/g++)
#   MARCH               -march value (default nocona, as conda-forge)
#   DISABLE_EXCEPTIONS  ON|OFF -> BUILD_RELEASE_DISABLE_EXCEPTIONS (default OFF, as conda-forge)
#   LTO                 TRUE|FALSE -> CMAKE_INTERPROCEDURAL_OPTIMIZATION (default TRUE, as conda-forge)
#   EXTRA_CXXFLAGS      appended to CMAKE_CXX_FLAGS
#   PATCH               name of a script in perf-lab/patches to apply to the source tree before building
#   OUT                 output directory for results (default perf-lab/out)
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-gcc}; CXX=${CXX:-g++}
MARCH=${MARCH:-nocona}
DISABLE_EXCEPTIONS=${DISABLE_EXCEPTIONS:-OFF}
LTO=${LTO:-TRUE}
EXTRA_CXXFLAGS=${EXTRA_CXXFLAGS:-}
OUT=${OUT:-$SRC/perf-lab/out}
BUILD=${BUILD:-$SRC/build}
PREFIX=${PREFIX:-$SRC/install}
mkdir -p "$OUT"

if [ -n "${PATCH:-}" ]; then
  bash "$SRC/perf-lab/patches/$PATCH" "$SRC"
fi

echo "== configure ($CXX, march=$MARCH, exceptions disabled=$DISABLE_EXCEPTIONS, lto=$LTO, extra='$EXTRA_CXXFLAGS')"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$LTO \
  -DBUILD_LIBRARY_TYPE=Shared \
  -DBUILD_MODULE_FoundationClasses=ON -DBUILD_MODULE_ModelingData=ON -DBUILD_MODULE_ModelingAlgorithms=ON \
  -DBUILD_MODULE_Visualization=OFF -DBUILD_MODULE_ApplicationFramework=OFF \
  -DBUILD_MODULE_DataExchange=OFF -DBUILD_MODULE_Draw=OFF \
  -DUSE_TK=OFF -DUSE_FREETYPE=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_XLIB=OFF \
  -DBUILD_RELEASE_DISABLE_EXCEPTIONS=$DISABLE_EXCEPTIONS \
  -DINSTALL_DIR_LAYOUT=Unix \
  "-DCMAKE_CXX_FLAGS=-march=$MARCH -mtune=haswell -g1 $EXTRA_CXXFLAGS" \
  "-DCMAKE_C_FLAGS=-march=$MARCH -mtune=haswell" \
  > "$OUT/configure.log" 2>&1 || { tail -50 "$OUT/configure.log"; exit 1; }
grep -E "CMAKE_CXX_FLAGS_RELEASE|No_Exception" "$BUILD/CMakeCache.txt" | head -5 || true

echo "== build"
time cmake --build "$BUILD" --target install > "$OUT/build.log" 2>&1 || { tail -80 "$OUT/build.log"; exit 1; }
ccache -s | head -6 || true

INC="$PREFIX/include/opencascade"
LIB="$PREFIX/lib"
[ -d "$INC" ] || INC=$(find "$PREFIX" -name gp_Pnt.hxx -printf '%h\n' | head -1)
[ -f "$LIB/libTKMath.so" ] || LIB=$(find "$PREFIX" -name libTKMath.so -printf '%h\n' | head -1)
TK="-lTKMesh -lTKShHealing -lTKOffset -lTKFillet -lTKBool -lTKBO -lTKPrim -lTKTopAlgo -lTKGeomAlgo -lTKBRep -lTKGeomBase -lTKG3d -lTKG2d -lTKMath -lTKernel"

echo "== build workload/bench"
"$CXX" -std=c++17 -O2 -g -march=$MARCH -fno-omit-frame-pointer -I"$INC" "$SRC/perf-lab/workload.cpp" -o "$OUT/workload" -L"$LIB" $TK -Wl,-rpath,"$LIB"
"$CXX" -std=c++17 -O2 -g -march=$MARCH -I"$INC" "$SRC/perf-lab/bench.cpp" -o "$OUT/bench" -L"$LIB" -lTKMath -lTKernel -Wl,-rpath,"$LIB"

echo "== timings"
{
  echo "### workload (5 reps) x3"
  for i in 1 2 3; do "$OUT/workload" 5 | tail -12; done
  echo "### mesh phase (2 reps) x3"
  for i in 1 2 3; do "$OUT/workload" 2 mesh | tail -1; done
  echo "### extrema phase (5 reps) x3"
  for i in 1 2 3; do "$OUT/workload" 5 extrema | tail -1; done
  echo "### bench x3 (min per row is what matters)"
  for i in 1 2 3; do "$OUT/bench"; done
} 2>&1 | tee "$OUT/timings.txt"

echo "== perf"
if command -v perf >/dev/null 2>&1; then
  sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true
  sudo sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1 || true
  # cpu-clock: works inside VMs without PMU access
  perf record -q -e cpu-clock -F 997 --call-graph dwarf,16384 -o "$OUT/perf.data" "$OUT/workload" 3 > /dev/null 2>&1 || \
  perf record -q -e cpu-clock -F 997 -g -o "$OUT/perf.data" "$OUT/workload" 3 > /dev/null 2>&1 || true
  if [ -f "$OUT/perf.data" ]; then
    perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 0.3 -g none 2>/dev/null \
      | grep -v "^#" | grep -v "^$" | head -120 > "$OUT/perf-flat.txt" || true
    perf report -i "$OUT/perf.data" --stdio --children --percent-limit 1 -g none 2>/dev/null \
      | grep -v "^#" | grep -v "^$" | head -150 > "$OUT/perf-children.txt" || true
    perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 1 -g caller,0.5,callee --max-stack 12 2>/dev/null \
      | head -600 > "$OUT/perf-callers.txt" || true
    perf report -i "$OUT/perf.data" --stdio --no-children --sort dso --percent-limit 0.5 -g none 2>/dev/null \
      | grep -v "^#" | grep -v "^$" | head -40 > "$OUT/perf-dso.txt" || true
    rm -f "$OUT/perf.data"
    echo "--- flat top 40"; head -40 "$OUT/perf-flat.txt"
    echo "--- per dso"; cat "$OUT/perf-dso.txt"
  fi
fi
echo "== done"
