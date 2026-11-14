-- ***************************************************************************
--                            AdaBeeb - Char_Data
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
--  User-defined characters (VDU 23) for the forge's character editor:
--  codes 32 .. 255, 8 x 8 pixels, one byte per row (bit 7 = left).
--
--  .udg files hold 8 bytes per character for codes 32 .. 255 (1792
--  bytes); shorter files of whole characters are taken to start at 224.

with Types; use Types;

package Char_Data is

   subtype Char_Code is Natural range 32 .. 255;
   subtype Row_Range is Natural range 0 .. 7;
   type Glyph is array (Row_Range) of Byte;

   function Get (C : Char_Code) return Glyph;
   procedure Put (C : Char_Code; G : Glyph);

   function ROM_Glyph (C : Char_Code) return Glyph;
   --  The OS's own definition (32 .. 126 from the ROM font; 127 is a
   --  block, 128 .. 255 start blank).
   function Changed (C : Char_Code) return Boolean;   --  differs from ROM

   function Pixel (G : Glyph; X, Y : Row_Range) return Boolean;
   procedure Set_Pixel (G : in out Glyph; X, Y : Row_Range; On : Boolean);
   procedure Invert (G : in out Glyph);
   procedure Mirror_X (G : in out Glyph);
   procedure Mirror_Y (G : in out Glyph);
   procedure Shift (G : in out Glyph; DX, DY : Integer);   --  wraps
   procedure Rotate (G : in out Glyph);                    --  90 degrees
   procedure Flood_Fill (G : in out Glyph; X, Y : Row_Range; On : Boolean);

   procedure Load_ROM;                   --  every character from the OS
   procedure Load (Path : String; Ok : out Boolean);
   procedure Save (Path : String; Ok : out Boolean);

   function VDU_Line (C : Char_Code) return String;
   --  "VDU 23,224,24,60,126,255,24,24,36,66"
   function BASIC_Text (Only_Changed : Boolean := True) return String;
   --  Numbered BASIC lines defining the characters with VDU 23
   function Asm_Text (Label : String) return String;
   --  ACME source: a label and one !byte line per character (224 .. 255,
   --  or all codes when lower ones were changed)

   type Reader is access function (Addr : Word) return Byte;
   function RAM_Address (Read : not null Reader; C : Char_Code)
     return Integer;
   --  Where the running OS keeps the definition of C (from its font
   --  location table at &0368), -1 when it comes from the ROM.

end Char_Data;
