#!/bin/bash
# Perf lab: A/B measurement of an OCCT build variant against the CadQuery (conda-forge) baseline
# on the same machine. Builds FoundationClasses + ModelingData + ModelingAlgorithms twice
# (baseline, variant), runs a CadQuery-like workload and TKMath micro-benchmarks interleaved
# (A B A B ...), samples the variant with perf, and dumps disassembly of hot functions.
#
# Environment (all optional; the variant differs from the baseline only by what is set):
#   CC / CXX            baseline compilers (default gcc/g++)
#   VAR_CC / VAR_CXX    variant compilers (default: same as baseline)
#   MARCH               -march for the variant (default nocona, as conda-forge)
#   DISABLE_EXCEPTIONS  ON|OFF -> BUILD_RELEASE_DISABLE_EXCEPTIONS for the variant (default OFF)
#   LTO                 TRUE|FALSE for the variant (default TRUE)
#   EXTRA_CXXFLAGS      appended to CMAKE_CXX_FLAGS of the variant
#   EXTRA_LDFLAGS       appended to linker flags of the variant
#   PATCH               script in perf-lab/patches applied to the source tree before the variant build
#   PGO                 1 -> variant is a two-stage PGO build (-fprofile-generate, train, -fprofile-use)
#   OUT                 output directory (default perf-lab/out)
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-gcc}; CXX=${CXX:-g++}
VAR_CC=${VAR_CC:-$CC}; VAR_CXX=${VAR_CXX:-$CXX}
BASE_CC=$CC; BASE_CXX=$CXX
MARCH=${MARCH:-nocona}
DISABLE_EXCEPTIONS=${DISABLE_EXCEPTIONS:-OFF}
LTO=${LTO:-TRUE}
BASE_CXXFLAGS="-fvisibility-inlines-hidden -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -ffunction-sections -pipe -D_FORTIFY_SOURCE=2"
BASE_LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections"
EXTRA_CXXFLAGS=${EXTRA_CXXFLAGS:-}
EXTRA_LDFLAGS=${EXTRA_LDFLAGS:-}
PGO=${PGO:-0}
OUT=${OUT:-$SRC/perf-lab/out}
mkdir -p "$OUT"
TK="-lTKMesh -lTKShHealing -lTKOffset -lTKFillet -lTKBool -lTKBO -lTKPrim -lTKTopAlgo -lTKGeomAlgo -lTKBRep -lTKGeomBase -lTKG3d -lTKG2d -lTKMath -lTKernel"

echo "== machine"; lscpu | grep -E "Model name|^CPU\(s\)|MHz" | tee "$OUT/machine.txt"

# configure_build <builddir> <prefix> <march> <disable_exc> <lto> <extra cxx> <extra ld> <ccache 0|1>
configure_build() {
  local b=$1 p=$2 march=$3 dexc=$4 lto=$5 cx=$6 ld=$7 cc=$8
  local launcher=()
  [ "$cc" = 1 ] && launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  echo "== configure $b ($CXX, march=$march, exceptions disabled=$dexc, lto=$lto, cxx='$cx', ld='$ld')"
  cmake -S "$SRC" -B "$b" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" "${launcher[@]}" \
    -DCMAKE_INSTALL_PREFIX="$p" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$lto \
    -DBUILD_LIBRARY_TYPE=Shared \
    -DBUILD_MODULE_FoundationClasses=ON -DBUILD_MODULE_ModelingData=ON -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_Visualization=OFF -DBUILD_MODULE_ApplicationFramework=OFF \
    -DBUILD_MODULE_DataExchange=OFF -DBUILD_MODULE_Draw=OFF \
    -DUSE_TK=OFF -DUSE_FREETYPE=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_XLIB=OFF \
    -DBUILD_RELEASE_DISABLE_EXCEPTIONS=$dexc \
    -DINSTALL_DIR_LAYOUT=Unix \
    "-DCMAKE_CXX_FLAGS=-march=$march -mtune=haswell -g1 $BASE_CXXFLAGS $cx" \
    "-DCMAKE_C_FLAGS=-march=$march -mtune=haswell $BASE_CXXFLAGS" \
    "-DCMAKE_SHARED_LINKER_FLAGS=$BASE_LDFLAGS $ld" \
    "-DCMAKE_EXE_LINKER_FLAGS=$BASE_LDFLAGS $ld" \
    > "$OUT/configure-$(basename "$b").log" 2>&1 || { tail -50 "$OUT/configure-$(basename "$b").log"; exit 1; }
  echo "== build $b"
  ( time cmake --build "$b" --target install > "$OUT/build-$(basename "$b").log" 2>&1 ) 2>&1 | grep real || { tail -80 "$OUT/build-$(basename "$b").log"; exit 1; }
  ccache -s 2>/dev/null | grep -E "Hits|Misses" | head -2 || true
}

# lib_dir <prefix>
lib_dir() { dirname "$(find "$1" -name 'libTKMath.so*' | head -1)"; }
inc_dir() { local i="$1/include/opencascade"; [ -d "$i" ] || i=$(find "$1" -name gp_Pnt.hxx -printf '%h\n' | head -1); echo "$i"; }

# build_programs <prefix> <tag> <march> <extra cxx flags>
build_programs() {
  local inc lib; inc=$(inc_dir "$1"); lib=$(lib_dir "$1")
  echo "$lib" > "$OUT/libdir-$2"
  "$CXX" -std=c++17 -O2 -g -march=$3 -fno-omit-frame-pointer $4 -I"$inc" "$SRC/perf-lab/workload.cpp" -o "$OUT/workload-$2" -L"$lib" $TK -Wl,-rpath,"$lib" -Wl,--disable-new-dtags
  "$CXX" -std=c++17 -O2 -g -march=$3 $4 -I"$inc" "$SRC/perf-lab/bench.cpp" -o "$OUT/bench-$2" -L"$lib" -lTKMath -lTKernel -Wl,-rpath,"$lib" -Wl,--disable-new-dtags
}

# ---------------- baseline (conda-forge configuration) ----------------
configure_build "$SRC/build-base" "$SRC/install-base" nocona OFF TRUE "" "" 1
build_programs "$SRC/install-base" base nocona ""

# ---------------- variant ----------------
CC=$VAR_CC; CXX=$VAR_CXX
if [ -n "${PATCH:-}" ]; then bash "$SRC/perf-lab/patches/$PATCH" "$SRC"; fi
if [ "$PGO" = 1 ]; then
  # Both stages use the same build directory so that the profile file names
  # (mangled object paths under -fprofile-dir) match between generate and use.
  PROF="$SRC/pgo-data"; mkdir -p "$PROF"
  PGOGEN="-fprofile-generate -fprofile-update=single -fprofile-dir=$PROF"
  PGOUSE="-fprofile-use -fprofile-partial-training -fprofile-correction -fprofile-dir=$PROF"
  case "$CXX" in clang*) PGOGEN="-fprofile-generate=$PROF"; PGOUSE="-fprofile-use=$PROF/merged.profdata";; esac
  configure_build "$SRC/build-var" "$SRC/install-gen" "$MARCH" "$DISABLE_EXCEPTIONS" "$LTO" "$EXTRA_CXXFLAGS $PGOGEN" "$EXTRA_LDFLAGS $PGOGEN" 0
  build_programs "$SRC/install-gen" gen "$MARCH" "$PGOGEN"
  echo "== PGO training"
  export LD_LIBRARY_PATH=$(cat "$OUT/libdir-gen")
  "$OUT/workload-gen" 2 > /dev/null; "$OUT/workload-gen" 1 mesh > /dev/null; "$OUT/workload-gen" 2 extrema > /dev/null
  unset LD_LIBRARY_PATH
  case "$CXX" in clang*) llvm-profdata merge -o "$PROF/merged.profdata" "$PROF"/*.profraw;; esac
  echo "profile files: $(find "$PROF" -name '*.gcda' -o -name '*.profraw' | wc -l), $(du -sh "$PROF" | cut -f1)"
  rm -rf "$SRC/install-gen"
  configure_build "$SRC/build-var" "$SRC/install-var" "$MARCH" "$DISABLE_EXCEPTIONS" "$LTO" "$EXTRA_CXXFLAGS $PGOUSE" "$EXTRA_LDFLAGS $PGOUSE" 0
  echo "missing-profile warnings: $(grep -c 'missing-profile' "$OUT/build-build-var.log")"
  build_programs "$SRC/install-var" var "$MARCH" "$PGOUSE -Wno-missing-profile"
else
  configure_build "$SRC/build-var" "$SRC/install-var" "$MARCH" "$DISABLE_EXCEPTIONS" "$LTO" "$EXTRA_CXXFLAGS" "$EXTRA_LDFLAGS" 1
  build_programs "$SRC/install-var" var "$MARCH" ""
fi
grep -E "CMAKE_CXX_FLAGS_RELEASE|No_Exception" "$SRC/build-var/CMakeCache.txt" | head -3 || true

CC=$BASE_CC; CXX=$BASE_CXX
# ---------------- A/B timings, interleaved on the same machine ----------------
run() { local v=$1; shift; LD_LIBRARY_PATH=$(cat "$OUT/libdir-$v") "$OUT/$1-$v" "${@:2}"; }
echo "== timings (A = baseline, B = variant)"
{
  for i in 1 2 3; do
    for v in base var; do
      echo "### $v workload (5 reps)"; run $v workload 5 | tail -12
    done
  done
  for i in 1 2 3; do
    for v in base var; do echo "### $v mesh"; run $v workload 2 mesh | tail -1; done
    for v in base var; do echo "### $v extrema"; run $v workload 5 extrema | tail -1; done
  done
  for i in 1 2 3; do
    for v in base var; do echo "### $v bench"; run $v bench; done
  done
} 2>&1 | tee "$OUT/timings.txt"

# ---------------- summary table ----------------
python3 - "$OUT/timings.txt" <<'PY' | tee "$OUT/summary.txt"
import re, sys
t = open(sys.argv[1]).read()
blocks = re.split(r'^### ', t, flags=re.M)[1:]
d = {}
for b in blocks:
    head, _, body = b.partition('\n')
    v, kind = head.split()[0], head.split()[1]
    if kind == 'workload':
        for m in re.finditer(r'^total ([\d.]+) s', body, re.M): d.setdefault((v, 'workload5'), []).append(float(m.group(1)))
        for m in re.finditer(r'^  (\S.*?)\s{2,}([\d.]+) s', body, re.M): d.setdefault((v, 'stage:' + m.group(1).strip()), []).append(float(m.group(2)))
    elif kind == 'mesh':
        for m in re.finditer(r'mesh phase ([\d.]+) s', body): d.setdefault((v, 'mesh2'), []).append(float(m.group(1)))
    elif kind == 'extrema':
        for m in re.finditer(r'extrema phase ([\d.]+) s', body): d.setdefault((v, 'extrema5'), []).append(float(m.group(1)))
    elif kind == 'bench':
        for m in re.finditer(r'^(\S+)\s+([\d.]+) ns/op', body, re.M): d.setdefault((v, 'bench:' + m.group(1)), []).append(float(m.group(2)))
keys = sorted({k for _, k in d}, key=lambda k: (k.startswith('bench'), k.startswith('stage'), k))
print(f"{'metric':36s} {'base(min)':>10s} {'var(min)':>10s} {'delta':>7s}   base runs")
for k in keys:
    a, b = d.get(('base', k)), d.get(('var', k))
    if not a or not b: continue
    print(f"{k:36s} {min(a):10.3f} {min(b):10.3f} {100*(min(b)/min(a)-1):+6.1f}%   {' '.join('%.3f'%x for x in a)}")
PY

# ---------------- analysis of the variant (errors here must not fail the job) ----------------
set +e +o pipefail
LIB=$(lib_dir "$SRC/install-var")
echo "== disassembly of hot functions"
{
  for lib in TKMath TKGeomBase TKG3d TKBO TKBRep; do
    so=$(ls "$LIB"/lib$lib.so* | head -1)
    echo "### $lib: size $(stat -c %s "$so"), PLT calls total $(objdump -d "$so" | grep -c '@plt>')"
    echo "top PLT targets:"
    objdump -d "$so" | grep -oE '<[^>]+@plt>' | sort | uniq -c | sort -rn | head -25 | c++filt
  done
  echo
  so=$(ls "$LIB"/libTKMath.so* | head -1)
  for pat in _ZN4PLib26NoDerivativeEvalPolynomial _ZNK15BSplSLib_Cache2D0 _ZNK15BSplCLib_Cache2D0 _ZN8BSplCLib4Bohm _ZN8BSplCLib11InsertKnotsEibRK18NCollection_Array1I6gp_Pnt _ZN8BSplSLib2D0 _ZN8BSplSLib2D1; do
    sym=$(nm -D --defined-only "$so" | awk -v p="$pat" '$3 ~ "^"p {print $3; exit}')
    [ -n "$sym" ] || { echo "### $pat: not found"; continue; }
    echo "### $(echo "$sym" | c++filt)"
    objdump -d --no-show-raw-insn -C --disassemble="$sym" "$so" | grep -vE "^$|file format|Disassembly" | head -400
    echo
  done
} > "$OUT/disasm.txt" 2>&1
grep -E "^### " "$OUT/disasm.txt" | head -20

echo "== perf (variant)"
if command -v perf >/dev/null 2>&1; then
  sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1
  sudo sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1
  export LD_LIBRARY_PATH="$LIB"
  perf record -q -e cpu-clock -F 997 --call-graph dwarf,16384 -o "$OUT/perf.data" "$OUT/workload-var" 3 > /dev/null 2>&1 || \
  perf record -q -e cpu-clock -F 997 -g -o "$OUT/perf.data" "$OUT/workload-var" 3 > /dev/null 2>&1
  if [ -f "$OUT/perf.data" ]; then
    perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 0.3 -g none 2>/dev/null | grep -v "^#" | grep -v "^$" | head -120 > "$OUT/perf-flat.txt"
    perf report -i "$OUT/perf.data" --stdio --children --percent-limit 1 -g none 2>/dev/null | grep -v "^#" | grep -v "^$" | head -150 > "$OUT/perf-children.txt"
    perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 1 -g caller,0.5,callee --max-stack 12 2>/dev/null | head -600 > "$OUT/perf-callers.txt"
    perf report -i "$OUT/perf.data" --stdio --no-children --sort dso --percent-limit 0.5 -g none 2>/dev/null | grep -v "^#" | grep -v "^$" | head -40 > "$OUT/perf-dso.txt"
    for sym in "BSplSLib::D1" "BSplSLib::D0" "BSplCLib::Bohm" "Extrema_GenExtPS::BuildGrid" "SVD_Decompose" "PLib::EvalPolynomial" "BSplSLib_Cache::D0Local" "nextafter" "malloc" "_int_free" "GeomAdaptor_Curve::EvalD1"; do
      echo "########## callers of $sym"
      perf report -i "$OUT/perf.data" --stdio --children --symbol-filter="$sym" -g caller,0.3,callee --max-stack 16 2>/dev/null | grep -v "^#" | grep -v "^$" | head -80
    done > "$OUT/perf-symbols.txt" 2>&1
    rm -f "$OUT/perf.data"
    echo "--- flat top 30"; head -30 "$OUT/perf-flat.txt"
    echo "--- per dso"; cat "$OUT/perf-dso.txt"
  fi
fi
echo "== done"
