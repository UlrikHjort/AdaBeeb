-- ***************************************************************************
--                            AdaBeeb - Rom_Dialog
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
--  The sideways ROM / RAM slots dialog.  Each slot can hold a ROM image
--  file, be sideways RAM, or be empty; the choices are kept per model in
--  the settings ("<model>_slot<N>" = "rom:<path>" | "ram" | "empty") and
--  applied at every power-on.

with Gtk.Window;

package Rom_Dialog is

   procedure Run (Parent : Gtk.Window.Gtk_Window; Changed : out Boolean);
   --  Show the dialog; Changed tells whether the machine needs a reset.

   procedure Apply_Saved;
   --  Apply the saved slot choices for the current model (call after
   --  Machine.Power_On, before the reset that lets the OS see them).

end Rom_Dialog;
