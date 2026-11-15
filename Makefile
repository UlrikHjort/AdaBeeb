# AdaBeeb build helpers
all:
	mkdir -p bin obj
	gprbuild -P emu.gpr -j0
	ln -sf adabeeb bin/adabeeb-forge

tests: all
	sh tests/run_tests.sh
	sh tests/basic_test.sh

clean:
	gprclean -q -P emu.gpr
	rm -rf obj bin

# Accuracy tests from the b2 emulator (several minutes): VIA, timing and
# the Master's CMOS NOPs, compared with output recorded on real machines
b2tests: all
	python3 -I tests/b2_tests.py via
	python3 -I tests/b2_tests.py --master cmos

# Z80 core: Frank Cringle's instruction exercisers (about 40 s each)
z80tests: all
	gprbuild -q -P tests/tests.gpr z80_test.adb
	bin/z80_test tests/z80/zexdoc.com
	bin/z80_test tests/z80/zexall.com

.PHONY: all tests b2tests z80tests clean
