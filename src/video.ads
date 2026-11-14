-- ***************************************************************************
--                              AdaBeeb - Video
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
--  The framebuffer shared between the display hardware and the GUI.
--
--  Horizontally one framebuffer pixel is one 16 MHz video ULA pixel
--  (mode 0 pixel), 48 us of the 64 us line.  Vertically each scanline of
--  a field is two framebuffer rows: the two interlaced fields of mode 7
--  are shown together (rows 2n / 2n+1), the other modes repeat each line.

with Types; use Types;

package Video is

   Width       : constant := 768;
   Lines       : constant := 288;          --  visible scanlines per field
   Height      : constant := 2 * Lines;

   type Frame is array (0 .. Height - 1, 0 .. Width - 1) of Pixel;
   type Frame_Access is access all Frame;
   FB : constant Frame_Access := new Frame'(others => (others => 0));

   --  Physical BBC colours (bit 0 red, bit 1 green, bit 2 blue)
   type Palette is array (Byte range 0 .. 7) of Pixel;
   Colours : constant Palette :=
     (16#000000#, 16#FF0000#, 16#00FF00#, 16#FFFF00#,
      16#0000FF#, 16#FF00FF#, 16#00FFFF#, 16#FFFFFF#);

   Scanlines : Boolean := False;
   --  Darken the odd framebuffer row of non-teletext modes (CRT look).

end Video;
