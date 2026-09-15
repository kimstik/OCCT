#!/bin/bash
# Perf lab: build OCCT (FoundationClasses + ModelingData + ModelingAlgorithms) in a CadQuery-like
# configuration, build the workload/bench programs against it, time them, sample with perf,
# and dump disassembly of hot functions.
#
# Environment (all optional):
#   CC / CXX            compilers (default gcc/g++)
#   MARCH               -march value (default nocona, as conda-forge)
#   DISABLE_EXCEPTIONS  ON|OFF -> BUILD_RELEASE_DISABLE_EXCEPTIONS (default OFF, as conda-forge)
#   LTO                 TRUE|FALSE -> CMAKE_INTERPROCEDURAL_OPTIMIZATION (default TRUE, as conda-forge)
#   BASE_CXXFLAGS       conda-forge compiler activation flags (default below)
#   BASE_LDFLAGS        conda-forge linker flags (default below)
#   EXTRA_CXXFLAGS      appended to CMAKE_CXX_FLAGS
#   EXTRA_LDFLAGS       appended to shared/exe linker flags
#   PATCH               name of a script in perf-lab/patches to apply to the source tree before building
#   PGO                 1 -> two-stage build: -fprofile-generate, train on workload, -fprofile-use
#   OUT                 output directory for results (default perf-lab/out)
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-gcc}; CXX=${CXX:-g++}
MARCH=${MARCH:-nocona}
DISABLE_EXCEPTIONS=${DISABLE_EXCEPTIONS:-OFF}
LTO=${LTO:-TRUE}
BASE_CXXFLAGS=${BASE_CXXFLAGS:--fvisibility-inlines-hidden -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -ffunction-sections -pipe -D_FORTIFY_SOURCE=2}
BASE_LDFLAGS=${BASE_LDFLAGS:--Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections}
EXTRA_CXXFLAGS=${EXTRA_CXXFLAGS:-}
EXTRA_LDFLAGS=${EXTRA_LDFLAGS:-}
PGO=${PGO:-0}
OUT=${OUT:-$SRC/perf-lab/out}
BUILD=${BUILD:-$SRC/build}
PREFIX=${PREFIX:-$SRC/install}
mkdir -p "$OUT"

if [ -n "${PATCH:-}" ]; then
  bash "$SRC/perf-lab/patches/$PATCH" "$SRC"
fi

TK="-lTKMesh -lTKShHealing -lTKOffset -lTKFillet -lTKBool -lTKBO -lTKPrim -lTKTopAlgo -lTKGeomAlgo -lTKBRep -lTKGeomBase -lTKG3d -lTKG2d -lTKMath -lTKernel"

# configure_build <builddir> <prefix> <extra cxx flags> <extra ld flags> <use ccache 0|1>
configure_build() {
  local b=$1 p=$2 cx=$3 ld=$4 cc=$5
  local launcher=()
  [ "$cc" = 1 ] && launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  echo "== configure ($CXX, march=$MARCH, exceptions disabled=$DISABLE_EXCEPTIONS, lto=$LTO, cxx='$cx', ld='$ld')"
  cmake -S "$SRC" -B "$b" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" "${launcher[@]}" \
    -DCMAKE_INSTALL_PREFIX="$p" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$LTO \
    -DBUILD_LIBRARY_TYPE=Shared \
    -DBUILD_MODULE_FoundationClasses=ON -DBUILD_MODULE_ModelingData=ON -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_Visualization=OFF -DBUILD_MODULE_ApplicationFramework=OFF \
    -DBUILD_MODULE_DataExchange=OFF -DBUILD_MODULE_Draw=OFF \
    -DUSE_TK=OFF -DUSE_FREETYPE=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_XLIB=OFF \
    -DBUILD_RELEASE_DISABLE_EXCEPTIONS=$DISABLE_EXCEPTIONS \
    -DINSTALL_DIR_LAYOUT=Unix \
    "-DCMAKE_CXX_FLAGS=-march=$MARCH -mtune=haswell -g1 $BASE_CXXFLAGS $cx" \
    "-DCMAKE_C_FLAGS=-march=$MARCH -mtune=haswell $BASE_CXXFLAGS" \
    "-DCMAKE_SHARED_LINKER_FLAGS=$BASE_LDFLAGS $ld" \
    "-DCMAKE_EXE_LINKER_FLAGS=$BASE_LDFLAGS $ld" \
    > "$OUT/configure.log" 2>&1 || { tail -50 "$OUT/configure.log"; exit 1; }
  echo "== build ($b)"
  ( time cmake --build "$b" --target install > "$OUT/build.log" 2>&1 ) 2>&1 | grep real || { tail -80 "$OUT/build.log"; exit 1; }
  ccache -s 2>/dev/null | grep -E "Hits|Misses" | head -2 || true
}

# locate <prefix>: sets INC, LIB (and LD_LIBRARY_PATH) for the installed tree
locate() {
  INC="$1/include/opencascade"
  [ -d "$INC" ] || INC=$(find "$1" -name gp_Pnt.hxx -printf '%h\n' | head -1)
  LIB=$(dirname "$(find "$1" -name 'libTKMath.so*' | head -1)")
  export LD_LIBRARY_PATH="$LIB"
  echo "INC=$INC LIB=$LIB"; ls "$LIB" | head -3
}

# build_programs <cxx flags for the programs>
build_programs() {
  "$CXX" -std=c++17 -O2 -g -march=$MARCH -fno-omit-frame-pointer $1 -I"$INC" "$SRC/perf-lab/workload.cpp" -o "$OUT/workload" -L"$LIB" $TK -Wl,-rpath,"$LIB"
  "$CXX" -std=c++17 -O2 -g -march=$MARCH $1 -I"$INC" "$SRC/perf-lab/bench.cpp" -o "$OUT/bench" -L"$LIB" -lTKMath -lTKernel -Wl,-rpath,"$LIB"
}

if [ "$PGO" = 1 ]; then
  PROF="$SRC/pgo-data"; mkdir -p "$PROF"
  PGOGEN="-fprofile-generate -fprofile-update=single -fprofile-dir=$PROF"
  PGOUSE="-fprofile-use -fprofile-partial-training -fprofile-correction -Wno-missing-profile -fprofile-dir=$PROF"
  case "$CXX" in clang*) PGOGEN="-fprofile-generate=$PROF"; PGOUSE="-fprofile-use=$PROF/merged.profdata";; esac
  configure_build "$BUILD-gen" "$PREFIX-gen" "$EXTRA_CXXFLAGS $PGOGEN" "$EXTRA_LDFLAGS $PGOGEN" 0
  locate "$PREFIX-gen"
  build_programs "$PGOGEN"
  echo "== PGO training"
  "$OUT/workload" 2 > /dev/null; "$OUT/workload" 1 mesh > /dev/null; "$OUT/workload" 2 extrema > /dev/null
  case "$CXX" in clang*) llvm-profdata merge -o "$PROF/merged.profdata" "$PROF"/*.profraw;; esac
  ls "$PROF" | head -3; du -sh "$PROF"
  rm -rf "$BUILD" "$PREFIX"
  configure_build "$BUILD" "$PREFIX" "$EXTRA_CXXFLAGS $PGOUSE" "$EXTRA_LDFLAGS $PGOUSE" 0
  locate "$PREFIX"
  build_programs "$PGOUSE"
else
  configure_build "$BUILD" "$PREFIX" "$EXTRA_CXXFLAGS" "$EXTRA_LDFLAGS" 1
  locate "$PREFIX"
  build_programs ""
fi
grep -E "CMAKE_CXX_FLAGS_RELEASE|No_Exception" "$BUILD/CMakeCache.txt" | head -3 || true

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

echo "== disassembly of hot functions"
{
  for lib in TKMath TKGeomBase TKG3d TKBO TKBRep; do
    so=$(ls "$LIB"/lib$lib.so* | head -1)
    echo "### $lib: size $(stat -c %s "$so"), PLT calls total $(objdump -d "$so" | grep -c '@plt>' || true)"
    echo "top PLT targets:"
    objdump -d "$so" | grep -oE '<[^>]+@plt>' | sort | uniq -c | sort -rn | head -25 | c++filt
  done
  echo
  so=$(ls "$LIB"/libTKMath.so* | head -1)
  for pat in _ZN4PLib26NoDerivativeEvalPolynomial _ZNK15BSplSLib_Cache2D0 _ZNK15BSplCLib_Cache2D0 _ZN8BSplCLib4Bohm _ZN8BSplCLib11InsertKnotsEibRK18NCollection_Array1I6gp_Pnt _ZN8BSplSLib2D0; do
    sym=$(nm -D --defined-only "$so" | awk -v p="$pat" '$3 ~ "^"p {print $3; exit}')
    [ -n "$sym" ] || { echo "### $pat: not found"; continue; }
    echo "### $(echo "$sym" | c++filt)"
    objdump -d --no-show-raw-insn -C --disassemble="$sym" "$so" | grep -vE "^$|file format|Disassembly" | head -400
    echo
  done
} > "$OUT/disasm.txt" 2>&1
grep -E "^### " "$OUT/disasm.txt" | head -20

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
