# Third-party material

AdaBeeb itself is under the MIT licence (`LICENSE`). The following parts
come from other projects and keep their own licences.

## Included

| What | Where | Author | Licence |
|------|-------|--------|---------|
| 6502 functional and 65C02 extended opcode tests (binaries) | `tests/6502_functional_test.bin`, `tests/65C02_extended_opcodes_test.bin` | Klaus Dormann | GPL v3 (`tests/COPYING-GPL-3.0.txt`) |
| b2 test programs, recorded output and reference images | `tests/b2/` | Tom Seddon and the b2 contributors (see `tests/b2/README.md`) | GPL v3 (`tests/COPYING-GPL-3.0.txt`) |
| ZEXDOC / ZEXALL Z80 instruction exercisers | `tests/z80/` | Frank D. Cringle | GPL v2 (`tests/z80/COPYING-GPL-2.0.txt`) |
| TMS5220 energy, pitch, reflection coefficient and chirp tables | `src/speech.adb` | from MAME's `tms5110r.hxx` | BSD-3-Clause (below) |

These test files are separate programs and data used by `make tests`,
`make b2tests` and `make z80tests`; they are not linked into AdaBeeb.

### BSD-3-Clause notice for the TMS5220 tables

Copyright (c) Frank Palazzolo, Couriersud, Jonathan Gevaryahu (MAME)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Consulted, not copied

The behaviour of some hardware and protocols was worked out by reading
other projects' documentation and source; no code was copied from them:
BeebEm (Econet ADLC behaviour), aund by Ben Harris and Simon Tatham (the
Acorn file server protocol), b-em (the Z80 Second Processor's memory
map), and MAME (the TMS5220's synthesis order).

## Not included

No ROM images, disc or tape images, or speech PHROMs are part of this
repository. The README explains which files are needed and where
AdaBeeb looks for them; they are copyright Acorn Computers and others.
