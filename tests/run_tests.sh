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
# Snapshot with the Second Processor: a variable in parasite memory survives
snap=$(mktemp)
bin/adabeeb --b --tube --headless 300 --type 'A%=4321\n' --save-snapshot "$snap" > /dev/null
out=$(bin/adabeeb --b --tube --headless 60 --load-snapshot "$snap" --type-at 5 'PRINT A%\n' --screen)
rm -f "$snap"
if echo "$out" | grep -q "^ *4321 *$"; then
  echo "ok   tube: snapshot keeps the second processor's state"
else
  echo "FAIL tube snapshot"; fail=1
fi
# Speech: SOUND -1 speaks a PHROM word (needs roms/phroma.rom)
if [ -f roms/phroma.rom ]; then
  w=$(mktemp --suffix=.wav)
  loud() {
    bin/adabeeb --b $1 --headless 300 --type-at 150 'SOUND -1,148,0,0\n' --wav "$w" > /dev/null 2>&1
    python3 -I -c "
import wave,struct,sys
f=wave.open(sys.argv[1]); n=f.getnframes(); r=f.getframerate()
d=struct.unpack('<%dh'%n,f.readframes(n))[int(3.5*r):]
print(max(abs(x) for x in d) if d else 0)" "$w"
  }
  with=$(loud --speech); without=$(loud "")
  rm -f "$w"
  if [ "$with" -gt 2000 ] && [ "$without" -lt 100 ]; then
    echo "ok   speech: SOUND -1 speaks a PHROM word (peak $with, $without without the chip)"
  else
    echo "FAIL speech (peak $with with the chip, $without without)"; fail=1
  fi
else
  echo "skip speech: roms/phroma.rom not present"
fi
exit $fail
