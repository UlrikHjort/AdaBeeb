-- ***************************************************************************
--                               AdaBeeb - Tape
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
--  Cassette interface: UEF tape images (plain or gzip-compressed) played
--  into the 6850 ACIA through the serial ULA, one byte time (8.33 ms at
--  1200 baud) per step.  Bytes the computer writes while the motor runs
--  are recorded and can be saved as a new UEF.

with Ada.Streams;
with Types; use Types;

package Tape is

   procedure Attach (Path : String; Ok : out Boolean);
   procedure Detach;
   function Present return Boolean;
   function Name return String;
   procedure Rewind;
   function Position_Percent return Natural;

   procedure Reset;

   --  Serial ULA ($FE10)
   procedure Serial_ULA_Write (Value : Byte);
   function Motor return Boolean;

   --  6850 ACIA ($FE08 / $FE09)
   function ACIA_Read (Reg : Natural) return Byte;
   procedure ACIA_Write (Reg : Natural; Value : Byte);
   function IRQ return Boolean;

   procedure Tick (Cycles : Natural);   --  2 MHz cycles

   function First_Block_Is_BASIC return Boolean;
   --  The first file's execution address is BASIC's ($8023 / $801F).

   function Recorded_Bytes return Natural;
   procedure Save_Recording (Path : String; Ok : out Boolean);
   --  Write what was saved to tape as an (uncompressed) UEF file.

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Tape;
