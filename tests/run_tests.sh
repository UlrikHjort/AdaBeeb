#!/bin/sh
# Builds and runs the AdaBeeb test programs (debugger, bitmap/ULA, CPU).
cd "$(dirname "$0")/.." || exit 1
mkdir -p obj/tests
gprbuild -q -P tests/tests.gpr -j0 || exit 1
fail=0
bin/debug_test || fail=1
bin/bitmap_test || fail=1
bin/cpu_test tests/6502_functional_test.bin || fail=1
bin/cpu_test tests/65C02_extended_opcodes_test.bin 24F1 cmos || fail=1
# 6502 Second Processor: BASIC runs in the parasite (PAGE = &800)
out=$(bin/adabeeb --tube --headless 400 --type 'PRINT ~PAGE\n' --screen)
if echo "$out" | grep -q "TUBE 6502" && echo "$out" | grep -q "^ *800 *$"; then
  echo "ok   tube: second processor boots, BASIC at PAGE &800"
else
  echo "FAIL tube"; fail=1
fi
exit $fail
