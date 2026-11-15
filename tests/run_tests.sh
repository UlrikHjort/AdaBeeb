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
# Z80 Second Processor: its client ROM boots and takes the language over
# the Tube (then asks for the CP/M disc, as the real one does)
if [ -f roms/z80tube.rom ]; then
  out=$(bin/adabeeb --b --z80 --headless 300 --screen)
  if echo "$out" | grep -q "TUBE Z80 64K" && echo "$out" | grep -q "Insert CP/M"; then
    echo "ok   z80: second processor boots and asks for CP/M"
  else
    echo "FAIL z80 tube"; fail=1
  fi
else
  echo "skip z80: roms/z80tube.rom not present"
fi
# Econet: NFS logs on to the built-in file server, SAVEs, LOADs and RUNs
d=$(mktemp -d)
out=$(bin/adabeeb --b --econet 201 --econet-dir "$d" --headless 1500 --type '*NET\n*I AM TEST\n10 PRINT "NET"+"WORKS"\nSAVE "PROG"\nNEW\nLOAD "PROG"\nRUN\n*CAT\n' --screen)
if echo "$out" | grep -q "^NETWORKS" && echo "$out" | grep -q "PROG *WR/r" && [ -f "$d/PROG" ]; then
  echo "ok   econet: file server SAVE / LOAD / *CAT"
else
  echo "FAIL econet file server"; fail=1
fi
rm -rf "$d"
# Econet between two instances: station 202 sends to station 201
rx='*NET\n10 DIM C% 20,B% 50:?C%=0:C%?1=&7F:C%?2=&50:C%?3=0:C%?4=0:C%!5=B%:C%!9=B%+40\n20 A%=&11:X%=C%:Y%=C% DIV 256:CALL &FFF1:N%=?C%\n30 REPEAT A%=&33:X%=N%:Y%=0:U%=(USR&FFF4 AND &FF00) DIV 256:UNTIL U%>=128\n40 PRINT "GOT ";$B%\nRUN\n'
tx='*NET\n10 DIM C% 20,B% 50:$B%="HELLO":?C%=&80:C%?1=&50:C%?2=201:C%?3=0:C%!4=B%:C%!8=B%+6\n20 A%=&10:X%=C%:Y%=C% DIV 256:CALL &FFF1\n30 REPEAT A%=&32:U%=(USR&FFF4 AND &FF00) DIV 256:UNTIL (U% AND &80)=0\n40 PRINT "TX ";~U%\nRUN\n'
r=$(mktemp)
bin/adabeeb --b --econet 201 --headless 6000 --type "$rx" --screen > "$r" &
sleep 3
txout=$(bin/adabeeb --b --econet 202 --headless 4000 --type "$tx" --screen)
wait
if grep -q "GOT HELLO" "$r" && echo "$txout" | grep -q "^TX 0"; then
  echo "ok   econet: a message between two AdaBeeb instances"
else
  echo "FAIL econet between instances"; fail=1
fi
rm -f "$r"
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
