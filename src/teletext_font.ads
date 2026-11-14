-- ***************************************************************************
--                          AdaBeeb - Teletext_Font
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
--  SAA5050 character shapes for mode 7, loaded from a font file in the
--  B-Em "BEMTTX01" format (16 x 20 grey-scale pixels per character, three
--  banks of 96: alphanumerics, contiguous and separated graphics).
--  Without a file a built-in approximation is generated (sixel graphics
--  exact, letters from the OS ROM's 8 x 8 font, doubled).

with Types; use Types;

package Teletext_Font is

   Glyph_Width  : constant := 16;
   Glyph_Height : constant := 20;

   type Bank is (Alpha, Contiguous, Separated);

   subtype Code is Natural range 32 .. 127;
   subtype Level is Natural range 0 .. 15;   --  grey level (15 = ink)

   procedure Load (Path : String; Ok : out Boolean);

   procedure Build_Fallback (OS_ROM : Byte_Array);
   --  Use the OS ROM font (at $C000) for letters; called when no font
   --  file is found.

   function Loaded return Boolean;

   function Pixel_Level (B : Bank; C : Code; Row, Col : Natural)
     return Level;
   pragma Inline (Pixel_Level);
   --  Row 0 .. 19, Col 0 .. 15

end Teletext_Font;
