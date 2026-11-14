-- ***************************************************************************
--                             AdaBeeb - FDC8271
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
--  Intel 8271 floppy disc controller (BBC Model B, Acorn DFS), in the
--  non-DMA mode the BBC uses: every data byte raises INT (NMI) with the
--  data request bit, and the DFS NMI handler moves it through $FE84.
--
--  Registers: read 0 status, 1 result, 4 data;
--             write 0 command, 1 parameter, 2 reset, 4 data.

with Ada.Streams;
with Types; use Types;

package FDC8271 is

   procedure Reset;
   function Read (Reg : Natural) return Byte;
   procedure Write (Reg : Natural; Value : Byte);
   procedure Tick (Cycles : Natural);    --  2 MHz cycles

   function INT return Boolean;           --  NMI request
   function Motor_On return Boolean;      --  head loaded (drive LED)
   function Current_Track (Drive : Natural) return Natural;

   Fast_Seek : Boolean := True;
   --  Step the head in 0.5 ms instead of the specified rate.

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);

end FDC8271;
