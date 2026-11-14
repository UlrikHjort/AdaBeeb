-- ***************************************************************************
--                          AdaBeeb - Bitmap_Editor
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
--  The forge's bitmap editor: pictures in modes 0, 1, 2, 4 and 5 with
--  their real palettes (VDU 19), drawing tools, PNG import with
--  dithering, screen dumps with a BASIC loader, ACME export and a live
--  link to the emulator's screen.

with Gtk.Window; use Gtk.Window;

package Bitmap_Editor is
   procedure Open (Parent : Gtk_Window; File : String := "");
   function Is_Bitmap_File (Path : String) return Boolean;   --  .bbm
   function Is_Image_File (Path : String) return Boolean;    --  .png
end Bitmap_Editor;
