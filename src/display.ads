-- ***************************************************************************
--                             AdaBeeb - Display
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
--  BBC Micro display: Motorola 6845 CRTC, the video ULA (palette, pixel
--  serialiser, cursor) and the SAA5050 teletext character generator.
--
--  Emulated one character clock at a time (2 MHz in modes 0-3, 1 MHz in
--  modes 4-7), writing straight into Video.FB, so palette, mode and CRTC
--  changes made in the middle of a frame show where they happen.

with Ada.Streams;
with Types; use Types;

generic
   with function Mem_Read (Addr : Natural) return Byte;
   --  Screen memory (15-bit address, after wrap-around and teletext
   --  address translation).
   with procedure VSync_Changed (Active : Boolean);
   --  The CRTC's VSYNC output (system VIA CA1).
package Display is

   procedure Reset;

   procedure Tick (Cycles : Natural);
   --  Advance by Cycles of the 2 MHz system clock.

   --  CPU access
   procedure CRTC_Write (Reg : Natural; Value : Byte);  --  Reg 0 = address
   function CRTC_Read (Reg : Natural) return Byte;
   procedure ULA_Write (Reg : Natural; Value : Byte);   --  0 control, 1 pal

   Screen_Size : Natural range 0 .. 3 := 0;
   --  Addressable latch bits C0/C1 (hardware scroll wrap-around size).

   Frame_Done : Boolean := False;
   --  Set at the start of each vertical sync (or when the TV's own
   --  timebase runs out without one).

   --  Inspection
   function CRTC_Register (R : Natural) return Byte;
   function ULA_Control return Byte;
   function Palette_Entry (Logical : Natural) return Byte;
   --  Physical colour 0 .. 15 (bit 3 = flashing)
   function Current_Line return Natural;     --  scanlines since VSYNC
   function Teletext_Mode return Boolean;
   function Screen_Start return Natural;     --  CPU address of R12/R13
   function Field_Count return Natural;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Display;
