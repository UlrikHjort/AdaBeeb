-- ***************************************************************************
--                         AdaBeeb - Teletext_Render
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
--  Renders a whole mode 7 screen (40 x 25 character codes) with the
--  SAA5050 rules: set-at / set-after control codes, mosaics (contiguous
--  and separated), hold graphics, double height, flash, conceal,
--  background colour.  Used by the teletext editor.

with Types; use Types;

package Teletext_Render is

   Cols : constant := 40;
   Rows : constant := 25;
   Char_W : constant := 16;
   Char_H : constant := 20;
   Width  : constant := Cols * Char_W;     --  640
   Height : constant := Rows * Char_H;     --  500

   type Screen is array (0 .. Rows - 1, 0 .. Cols - 1) of Byte;
   type Image is array (0 .. Height - 1, 0 .. Width - 1) of Pixel;

   procedure Render (S : Screen; Img : out Image;
                     Flash_On : Boolean := True;
                     Reveal : Boolean := False);

   type Cell_Info is record
      Graphics : Boolean := False;   --  graphics mode (not a control cell)
      Control  : Boolean := False;   --  a control code (shown as space)
      Fg, Bg   : Byte := 0;
      Double   : Boolean := False;
   end record;
   function Info (S : Screen; Row, Col : Natural) return Cell_Info;
   --  The attributes in effect at a cell.

   function Control_Name (Code : Byte) return String;
   --  Short name of a control code 0 .. 31 ("red", "gfx grn", "dbl" ...)

end Teletext_Render;
