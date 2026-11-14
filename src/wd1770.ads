-- ***************************************************************************
--                              AdaBeeb - WD1770
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
--  Western Digital WD1770 floppy disc controller as fitted to the BBC
--  Master: drive control latch at &FE24 (bits 0-1 drive select, bit 2
--  reset (low), bit 4 side, bit 5 single density) and the controller's
--  registers at &FE28-&FE2B (status/command, track, sector, data).
--  DRQ and INTRQ both raise NMI.  Works on the same DFS images as the
--  8271 (10 sectors of 256 bytes per track, single density).

with Ada.Streams;
with Types; use Types;

package WD1770 is

   procedure Reset;
   procedure Write_Control (Value : Byte);
   procedure Write_Control_Acorn (Value : Byte);
   --  The B+'s latch at &FE80 (bits 0-1 drive, 2 side, 3 single density,
   --  5 reset low)
   function Read (Reg : Natural) return Byte;       --  0 .. 3
   procedure Write (Reg : Natural; Value : Byte);
   procedure Tick (Cycles : Natural);

   function NMI return Boolean;
   function Motor_On return Boolean;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);

end WD1770;
