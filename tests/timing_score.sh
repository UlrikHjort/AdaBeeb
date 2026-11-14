#!/bin/sh
# Mismatching lines of the timing-sensitive b2 tests (VTIMEOU, TIMINGS)
cd "$(dirname "$0")/.." || exit 1
T=${TMPDIR:-/tmp}/adabeeb_timing.$$; mkdir -p $T
total=0
for t in VTIMEOU TIMINGS; do
  bin/adabeeb --mkssd $T/t.ssd tests/b2/via/T.$t
  bin/adabeeb --headless 6000 --attach $T/t.ssd --type "CHAIN\"T.$t\"\n" > /dev/null
  bin/adabeeb --get $T/t.ssd O.$t $T/got > /dev/null
  tr '\r' '\n' < $T/got > $T/g; tr '\r' '\n' < tests/b2/via/O.$t > $T/w
  n=$(diff $T/w $T/g | grep -c '^<'); echo "$t $n"; total=$((total+n))
done
echo "total $total"; rm -rf $T
