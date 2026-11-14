#!/bin/sh
# Type a BASIC program into the emulated BBC and check that the ROM's own
# tokeniser stores exactly the bytes our tokeniser produces.
cd "$(dirname "$0")/.." || exit 1
T=${TMPDIR:-/tmp}/adabeeb_basic_test.$$
mkdir -p "$T"
fail=0
for src in tests/basic_ii.bas; do
  cp "$src" "$T/prog.bas"
  bin/adabeeb --basic "$T/prog.bas" > /dev/null || { echo "FAIL tokenize $src"; fail=1; continue; }
  text=$(awk '{printf "%s\\n", $0}' "$src")
  bin/adabeeb --headless 8000 --type "$text" --dump "$T/ram.bin" > /dev/null
  python3 -I - "$T/prog" "$T/ram.bin" "$src" <<'PY' || fail=1
import sys
ours=open(sys.argv[1],'rb').read(); ram=open(sys.argv[2],'rb').read()
page=ram[0x18]*256
rom=ram[page:page+len(ours)]
if rom==ours:
    print("ok  ", sys.argv[3], len(ours), "bytes")
    sys.exit(0)
i=next(k for k in range(len(ours)) if k>=len(rom) or rom[k]!=ours[k])
print("FAIL", sys.argv[3], "first difference at offset", i)
print(" ours:", ours[max(0,i-12):i+12].hex(' '))
print(" rom: ", rom[max(0,i-12):i+12].hex(' '))
sys.exit(1)
PY
done
rm -rf "$T"
exit $fail
