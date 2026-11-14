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

with Ada.Strings.Fixed;
with Glib; use Glib;
with Gtk.Button; use Gtk.Button;
with Gtk.Check_Button; use Gtk.Check_Button;
with Gtk.Dialog; use Gtk.Dialog;
with Gtk.Grid; use Gtk.Grid;
with Gtk.Label; use Gtk.Label;
with Gtk.Toggle_Button; use Gtk.Toggle_Button;
with Gtk.Widget; use Gtk.Widget;


with Machine; use Machine;
with Settings;
with Editor_Util;

package body Rom_Dialog is

   function Prefix return String is
     (case Machine.Model is
        when Model_B => "b",
        when Model_B_Plus => "bplus",
        when Master_128 => "master");

   function Key (Slot : Natural) return String is
     (Prefix & "_slot" & Ada.Strings.Fixed.Trim (Slot'Image,
                                                 Ada.Strings.Left));

   procedure Apply (Slot : Natural; Value : String) is
      Ok : Boolean;
   begin
      if Value = "ram" then
         Machine.Clear_Slot (Slot);
         Machine.Set_Sideways_RAM (Slot, True);
      elsif Value = "empty" then
         Machine.Clear_Slot (Slot);
      elsif Value'Length > 4 and then Value (Value'First .. Value'First + 3)
        = "rom:"
      then
         Machine.Clear_Slot (Slot);
         Machine.Load_Sideways_ROM
           (Slot, Value (Value'First + 4 .. Value'Last), Ok);
      end if;
   end Apply;

   procedure Apply_Saved is
   begin
      for Slot in 0 .. 15 loop
         declare
            V : constant String := Settings.Get (Key (Slot), "");
         begin
            if V /= "" then
               Apply (Slot, V);
            end if;
         end;
      end loop;
   end Apply_Saved;

   --  Dialog widgets
   Titles : array (0 .. 15) of Gtk_Label;
   Loads, Empties : array (0 .. 15) of Gtk_Button;
   RAMs : array (0 .. 15) of Gtk_Check_Button;
   Dlg : Gtk_Dialog;
   Any_Change : Boolean := False;
   Updating : Boolean := False;

   procedure Refresh (Slot : Natural) is
      T : constant String := Machine.ROM_Title (Slot);
   begin
      Titles (Slot).Set_Text (if T = "" then "-" else T);
      Updating := True;
      RAMs (Slot).Set_Active (Machine.Slot_Is_RAM (Slot));
      Updating := False;
   end Refresh;

   procedure Change (Slot : Natural; Value : String) is
   begin
      Apply (Slot, Value);
      Settings.Set (Key (Slot), Value);
      Any_Change := True;
      Refresh (Slot);
   end Change;

   procedure On_Load (Self : access Gtk_Button_Record'Class) is
   begin
      for S in Loads'Range loop
         if Gtk_Button (Self) = Loads (S) then
            declare
               P : constant String :=
                 Editor_Util.Choose_File
                   (Gtk.Window.Gtk_Window (Dlg),
                    "ROM image for slot" & S'Image, False,
                    "ROM images (*.rom)", "*.rom");
            begin
               if P /= "" then
                  Change (S, "rom:" & P);
               end if;
            end;
         end if;
      end loop;
   end On_Load;

   procedure On_Empty (Self : access Gtk_Button_Record'Class) is
   begin
      for S in Empties'Range loop
         if Gtk_Button (Self) = Empties (S) then
            Change (S, "empty");
         end if;
      end loop;
   end On_Empty;

   procedure On_RAM (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Updating then
         return;
      end if;
      for S in RAMs'Range loop
         if Gtk_Check_Button (Self) = RAMs (S) then
            Change (S, (if Self.Get_Active then "ram" else "empty"));
         end if;
      end loop;
   end On_RAM;

   procedure Run (Parent : Gtk.Window.Gtk_Window; Changed : out Boolean) is
      G : Gtk_Grid;
      L : Gtk_Label;
      W : Gtk_Widget;
      R : Gtk_Response_Type;
      pragma Unreferenced (W, R);
   begin
      Any_Change := False;
      Gtk_New (Dlg, "Sideways ROMs and RAM", Parent, Modal);
      Gtk_New (G);
      G.Set_Row_Spacing (2);
      G.Set_Column_Spacing (8);
      G.Set_Border_Width (8);
      for Slot in reverse 0 .. 15 loop
         declare
            Row : constant Gint := Gint (15 - Slot);
         begin
            Gtk_New (L, "Slot" & Slot'Image);
            G.Attach (L, 0, Row);
            Gtk_New (Titles (Slot), "");
            Titles (Slot).Set_Width_Chars (32);
            Titles (Slot).Set_Alignment (0.0, 0.5);
            G.Attach (Titles (Slot), 1, Row);
            Gtk_New (Loads (Slot), "Load ROM...");
            Loads (Slot).On_Clicked (On_Load'Access);
            G.Attach (Loads (Slot), 2, Row);
            Gtk_New (Empties (Slot), "Empty");
            Empties (Slot).On_Clicked (On_Empty'Access);
            G.Attach (Empties (Slot), 3, Row);
            Gtk_New (RAMs (Slot), "RAM");
            RAMs (Slot).On_Toggled (On_RAM'Access);
            G.Attach (RAMs (Slot), 4, Row);
            Refresh (Slot);
         end;
      end loop;
      Gtk_New (L, "Changes are kept for this model and take effect with a "
               & "power-on reset when the dialog closes.");
      G.Attach (L, 0, 16, 5, 1);
      Dlg.Get_Content_Area.Pack_Start (G);
      W := Dlg.Add_Button ("_Close", Gtk_Response_Close);
      Dlg.Show_All;
      R := Dlg.Run;
      Dlg.Destroy;
      Changed := Any_Change;
   end Run;

end Rom_Dialog;
