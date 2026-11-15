-- ***************************************************************************
--                                AdaBeeb - Z80
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
--  Zilog Z80 CPU core.
--
--  Instruction-stepped with T-state counts: all documented instructions,
--  the CB / DD / ED / FD / DDCB / FDCB prefixes, the undocumented IXH /
--  IXL / IYH / IYL forms, SLL, and the undocumented X / Y flag bits.
--  Interrupt modes 0 / 1 (as RST 38H) and 2 (vector from I and Ack_Byte),
--  NMI, HALT and the one-instruction delay after EI.
--  Memory and I/O are generic formal subprograms; Fetch_Hook sees every
--  opcode fetch (M1), for machines that page memory on it.

with Types; use Types;

generic
   with function Read (Addr : Word) return Byte;
   with procedure Write (Addr : Word; Value : Byte);
   with function In_Port (Port : Word) return Byte;
   with procedure Out_Port (Port : Word; Value : Byte);
   with procedure Fetch_Hook (Addr : Word) is null;
package Z80 is

   A, F, B, C, D, E, H, L : Byte := 0;
   A2, F2, B2, C2, D2, E2, H2, L2 : Byte := 0;    --  alternate set
   IX, IY : Word := 16#FFFF#;
   SP : Word := 16#FFFF#;
   PC : Word := 0;
   I, R : Byte := 0;
   IFF1, IFF2 : Boolean := False;
   IM : Natural range 0 .. 2 := 0;
   Halted : Boolean := False;

   INT_Line    : Boolean := False;   --  level, active when True
   Ack_Byte    : Byte := 16#FF#;
   --  What the bus holds when an interrupt is acknowledged: the low byte
   --  of the vector address in mode 2 (the Acorn Z80 board gives &FE).
   NMI_Pending : Boolean := False;   --  set on the NMI edge

   procedure Reset;
   procedure Step (T_States : out Natural);
   --  Execute one instruction (or take an interrupt) and return its
   --  length in T-states.

end Z80;
