#!/bin/bash
# Raise the dimension limit of the templated polynomial evaluators in PLib so that
# rational / high-degree surface caches (Dimension = (deg+1)*4, typically 16..40) take the
# unrolled path instead of eval_poly*_runtime.
set -e
f="$1/src/FoundationClasses/TKMath/PLib/PLib.cxx"
grep -q "constexpr int THE_MAX_OPT_DIM = 15;" "$f"
sed -i 's/constexpr int THE_MAX_OPT_DIM = 15;/constexpr int THE_MAX_OPT_DIM = 32;/' "$f"
grep -n "THE_MAX_OPT_DIM = " "$f"
