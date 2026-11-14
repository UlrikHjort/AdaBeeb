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

.PHONY: all tests b2tests clean
