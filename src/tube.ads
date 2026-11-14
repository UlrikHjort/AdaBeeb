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

with Types; use Types;

package Tube is

   Enabled : Boolean := False;
   --  A 6502 Second Processor is connected (takes effect at power-on).

   procedure Load_ROM (Path : String; Ok : out Boolean);
   function ROM_Loaded return Boolean;

   procedure Reset;
   --  Host reset: the Tube ULA and the parasite processor.

   function Host_Read (Reg : Natural) return Byte;
   procedure Host_Write (Reg : Natural; Value : Byte);
   function Host_IRQ return Boolean;

   procedure Run (Host_Cycles : Natural);
   --  Run the parasite for the time of Host_Cycles (2 MHz) cycles.

   function Parasite_PC return Word;
   function Parasite_Peek (Addr : Word) return Byte;
   procedure Parasite_Poke (Addr : Word; Value : Byte);

end Tube;
