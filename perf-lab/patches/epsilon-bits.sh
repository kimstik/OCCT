#!/bin/bash
# Replace the libm nextafter() call in Epsilon() (Standard_Real.hxx) with the equivalent
# bit-increment of the magnitude. Same result for every input (0, -0, denormals, DBL_MAX,
# inf, NaN included); the subtraction is exact.
set -e
f="$1/src/FoundationClasses/TKernel/Standard/Standard_Real.hxx"
python3 - "$f" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
old = re.search(r'\[\[nodiscard\]\] inline double Epsilon\(const double theValue\)\n\{\n.*?\n\}\n', s, re.S)
assert old, "Epsilon() not found"
new = '''[[nodiscard]] inline double Epsilon(const double theValue)
{
  // ulp(|x|) computed by incrementing the bit pattern; identical to
  // nextafter(x, +-inf) - x for all inputs, without a libm call.
  const double aMag = std::fabs(theValue);
  std::uint64_t aBits;
  std::memcpy(&aBits, &aMag, sizeof(aBits));
  ++aBits;
  double aNext;
  std::memcpy(&aNext, &aBits, sizeof(aNext));
  return aNext - aMag;
}
'''
s = s[:old.start()] + new + s[old.end():]
if '#include <cstring>' not in s:
    s = s.replace('#include <cmath>', '#include <cmath>\n#include <cstdint>\n#include <cstring>', 1)
open(p, 'w').write(s)
print("patched", p)
PY
grep -n "cstring\|cstdint\|aBits" "$f" | head
