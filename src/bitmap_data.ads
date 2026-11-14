-- ***************************************************************************
--                           AdaBeeb - Bitmap_Data
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
--  Bitmap pictures for the forge's bitmap editor, in the BBC's graphics
--  modes: 0 (640 x 256, 2 colours), 1 (320 x 256, 4), 2 (160 x 256, 16),
--  4 (320 x 256, 2) and 5 (160 x 256, 4).  Pixels are logical colours;
--  the palette maps them to physical colours (0-7, 8-15 flashing) as
--  VDU 19 does.
--
--  Screen memory layout as on the machine: character rows of 8 lines,
--  8 consecutive bytes per character cell, pixels packed in each byte as
--  the video ULA reads them (pixel n of a 4-colour byte has colour bits
--  7-n and 3-n, etc.).
--
--  .bbm files: "BBM1", mode, 16 palette bytes, then the screen memory.

with Types; use Types;

package Bitmap_Data is

   subtype Mode_Number is Natural range 0 .. 5;   --  3 is not graphics
   function Valid_Mode (M : Natural) return Boolean is (M in 0 | 1 | 2 | 4 | 5);

   procedure Set_Mode (M : Mode_Number; Keep_Picture : Boolean := False);
   function Mode return Mode_Number;
   function Width return Natural;          --  640, 320 or 160
   function Height return Natural;         --  256
   function Colours return Natural;        --  2, 4 or 16
   function Screen_Base return Natural;    --  &3000 or &5800
   function Screen_Size return Natural;    --  20480 or 10240

   subtype Logical is Natural range 0 .. 15;
   function Get (X, Y : Natural) return Logical;
   procedure Put (X, Y : Natural; C : Logical);
   procedure Clear (C : Logical := 0);

   function Physical (L : Logical) return Byte;   --  0 .. 15
   procedure Set_Physical (L : Logical; P : Byte);
   procedure Default_Palette;
   function Palette_Is_Default return Boolean;
   function RGB (L : Logical) return Pixel;       --  steady colour

   procedure Line (X0, Y0, X1, Y1 : Integer; C : Logical);
   procedure Rect (X0, Y0, X1, Y1 : Integer; C : Logical; Filled : Boolean);
   procedure Ellipse (X0, Y0, X1, Y1 : Integer; C : Logical;
                      Filled : Boolean);
   procedure Flood_Fill (X, Y : Natural; C : Logical);

   function Screen_Bytes return Byte_Array;
   procedure Set_Screen_Bytes (D : Byte_Array);

   procedure Load (Path : String; Ok : out Boolean);
   procedure Save (Path : String; Ok : out Boolean);

   procedure Import_Image (Path : String; Dither : Boolean; Ok : out Boolean);
   --  A PNG scaled to the screen (4:3) and matched to the palette.

   function Loader_BASIC (Data_Name : String) return String;
   --  MODE, VDU 19 for the palette and *LOAD of the screen dump.

   --  Snapshot for undo
   type Picture is private;
   function Snapshot return Picture;
   procedure Restore (P : Picture);

private
   type Pixel_Grid is array (0 .. 255, 0 .. 639) of Logical;
   type Grid_Access is access Pixel_Grid;
   type Picture is record
      M   : Mode_Number := 1;
      Pix : Grid_Access := null;
      Pal : Byte_Array (0 .. 15) := (others => 0);
   end record;
end Bitmap_Data;
