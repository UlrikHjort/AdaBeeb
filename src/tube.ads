-- ***************************************************************************
--                               AdaBeeb - Tube
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************
--  The Tube and a 6502 Second Processor: a 65C02 at 3 MHz with 64 KB RAM
--  and its 2 KB ROM (at &F000-&FFFF until it first reads the Tube's R1
--  status), talking to the host through the Tube ULA:
--
--    R1  parasite -> host 24-byte FIFO, host -> parasite 1 byte
--        (OSWRCH, events); host side also holds the control flags
--    R2  1 byte each way (OS call command bytes)
--    R3  1 or 2 bytes each way (V flag): data transfers, parasite NMI
--    R4  1 byte each way: transfer set-up, host IRQ / parasite IRQ
--
--  Control flags (host writes &FEE0, bit 7 sets / clears the others):
--  Q host IRQ from R4, I parasite IRQ from R1, J parasite IRQ from R4,
--  M parasite NMI from R3, V two-byte R3, P parasite reset, T clear.
--  Host registers at &FEE0-&FEE7, parasite registers at &FEF8-&FEFF.

with Ada.Streams;
with Types; use Types;

package Tube is

   Enabled : Boolean := False;
   --  A Second Processor is connected (takes effect at power-on).

   type Parasite_Type is (CPU_6502, CPU_Z80);
   Kind : Parasite_Type := CPU_6502;
   --  Which one: the 6502 Second Processor (65C02, 3 MHz, 2 KB ROM at
   --  &F000 until it reads R1's status) or the Z80 Second Processor (Z80,
   --  6 MHz, 4 KB ROM at &0000 until it fetches an instruction at &8000
   --  or above, back in for each NMI; the Tube registers are its I/O
   --  ports 0-7).

   function ROM_Name return String is
     (if Kind = CPU_Z80 then "z80tube.rom" else "6502tube.rom");

   procedure Load_ROM (Path : String; Ok : out Boolean);
   function ROM_Loaded return Boolean;

   procedure Reset;
   --  Host reset: the Tube ULA and the parasite processor.

   function Host_Read (Reg : Natural) return Byte;
   procedure Host_Write (Reg : Natural; Value : Byte);
   function Host_IRQ return Boolean;

   procedure Run (Host_Cycles : Natural);
   --  Run the parasite for the time of Host_Cycles (2 MHz) cycles.

   procedure Save_State (S : access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State (S : access Ada.Streams.Root_Stream_Type'Class);
   --  The ULA, the parasite's CPU and its 64 KB (not the ROM image), for
   --  the current Kind (the snapshot header records which).

   function Parasite_PC return Word;
   function Parasite_Peek (Addr : Word) return Byte;
   procedure Parasite_Poke (Addr : Word; Value : Byte);

   --  Debugging the parasite.  The hooks are installed by the debugger:
   --  Before runs ahead of each instruction, After once it has run (with
   --  its opcode), On_Access on every memory access the parasite makes.
   --  When Before or After returns True the parasite halts and stays
   --  halted until Resume; the instruction Resume continues with is not
   --  checked by Before again (so a breakpoint can be stepped past).

   type Before_Hook is access function (PC : Word; SP : Byte) return Boolean;
   type After_Hook is access function (Op : Byte) return Boolean;
   type Access_Hook is access procedure (Addr : Word; Is_Write : Boolean);
   Before    : Before_Hook := null;
   After     : After_Hook := null;
   On_Access : Access_Hook := null;

   function Halted return Boolean;
   procedure Resume;

   function Parasite_A return Byte;
   function Parasite_X return Byte;
   function Parasite_Y return Byte;
   function Parasite_SP return Byte;
   function Parasite_P return Byte;
   procedure Set_Parasite_PC (Addr : Word);

end Tube;
