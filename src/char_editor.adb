-- ***************************************************************************
--                           AdaBeeb - Char_Editor
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
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Characters.Handling;
with Ada.Directories;

with Glib; use Glib;
with Gdk.Event; use Gdk.Event;
with Gdk.Types; use Gdk.Types;
with Gdk.Types.Keysyms; use Gdk.Types.Keysyms;
with Gtk.Box; use Gtk.Box;
with Gtk.Check_Button; use Gtk.Check_Button;
with Gtk.Drawing_Area; use Gtk.Drawing_Area;
with Gtk.Enums; use Gtk.Enums;
with Gtk.Frame; use Gtk.Frame;
with Gtk.GEntry; use Gtk.GEntry;
with Gtk.Label; use Gtk.Label;
with Gtk.Separator_Tool_Item; use Gtk.Separator_Tool_Item;
with Gtk.Tool_Button; use Gtk.Tool_Button;
with Gtk.Toggle_Button; use Gtk.Toggle_Button;
with Gtk.Toolbar; use Gtk.Toolbar;
with Gtk.Widget; use Gtk.Widget;
with Cairo; use Cairo;

with Types; use Types;
with Machine;
with Settings;
with Editor_Util; use Editor_Util;
with Char_Data; use Char_Data;

package body Char_Editor is

   Cell : constant := 40;           --  editor pixel size
   Set_Scale : constant := 2;       --  overview: 16 x 16 per character

   Win      : Gtk_Window := null;
   Grid, Overview, Text_Area : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Live     : Gtk_Check_Button;
   Sample   : Gtk_Entry;

   Current  : Char_Code := 224;
   File     : Unbounded_String;
   Painting : Boolean := False;
   Paint_On : Boolean := True;
   Clip     : Glyph := (others => 0);

   Max_Undo : constant := 64;
   type Undo_Entry is record
      Code : Char_Code := 32;
      G    : Glyph := (others => 0);
   end record;
   Undo_Stack : array (1 .. Max_Undo) of Undo_Entry;
   Undo_Count : Natural := 0;

   function Is_Char_File (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
   begin
      return L'Length > 4 and then L (L'Last - 3 .. L'Last) = ".udg";
   end Is_Char_File;

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   function Peek (A : Word) return Byte is (Machine.Peek (A));

   procedure Send_Glyph (C : Char_Code; Count : in out Natural) is
      A : constant Integer := RAM_Address (Peek'Access, C);
      G : constant Glyph := Get (C);
   begin
      if A >= 0 then
         for Y in Row_Range loop
            Machine.Poke (Word (A + Y), G (Y));
         end loop;
         Count := Count + 1;
      end if;
   end Send_Glyph;

   procedure Send_To_Emulator (Quiet : Boolean := False) is
      N : Natural := 0;
      Lower_Changed : Boolean := False;
   begin
      for C in Char_Code loop
         if C < 224 and then Changed (C)
           and then RAM_Address (Peek'Access, C) < 0
         then
            Lower_Changed := True;
         end if;
         Send_Glyph (C, N);
      end loop;
      if not Quiet then
         Status.Set_Text
           ("sent" & N'Image & " characters to the emulator's font" &
            (if Lower_Changed
             then "; codes below 224 need *FX20,6 (Explode font) first"
             else ""));
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
      N : Natural := 0;
   begin
      for C in Char_Code loop
         declare
            A : constant Integer := RAM_Address (Peek'Access, C);
            G : Glyph;
         begin
            if A >= 0 then
               for Y in Row_Range loop
                  G (Y) := Machine.Peek (Word (A + Y));
               end loop;
               Put (C, G);
               N := N + 1;
            end if;
         end;
      end loop;
      Status.Set_Text ("grabbed" & N'Image &
                       " characters from the emulator's font memory");
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Drawing
   ---------------------------------------------------------------------

   procedure Show_Status is
   begin
      Status.Set_Text ("character" & Current'Image &
                       (if Current in 33 .. 126
                        then " '" & Character'Val (Current) & "'" else "") &
                       ":  " & VDU_Line (Current));
   end Show_Status;

   procedure Redraw_All is
   begin
      Grid.Queue_Draw;
      Overview.Queue_Draw;
      Text_Area.Queue_Draw;
   end Redraw_All;

   procedure Changed_Glyph is
      N : Natural := 0;
   begin
      Show_Status;
      Redraw_All;
      if Live.Get_Active then
         Send_Glyph (Current, N);
      end if;
   end Changed_Glyph;

   procedure Draw_Glyph (Cr : Cairo_Context; G : Glyph;
                         X0, Y0 : Gdouble; Scale : Gdouble) is
   begin
      for Y in Row_Range loop
         for X in Row_Range loop
            if Char_Data.Pixel (G, X, Y) then
               Rectangle (Cr, X0 + Gdouble (X) * Scale,
                          Y0 + Gdouble (Y) * Scale, Scale, Scale);
            end if;
         end loop;
      end loop;
      Cairo.Fill (Cr);
   end Draw_Glyph;

   function On_Grid_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Set_Colour (Cr, 0);
      Paint (Cr);
      Set_Colour (Cr, 7);
      Draw_Glyph (Cr, Get (Current), 0.0, 0.0, Gdouble (Cell));
      Set_Source_Rgb (Cr, 0.3, 0.3, 0.3);
      Set_Line_Width (Cr, 1.0);
      for I in 0 .. 8 loop
         Move_To (Cr, Gdouble (I * Cell) + 0.5, 0.0);
         Line_To (Cr, Gdouble (I * Cell) + 0.5, Gdouble (8 * Cell));
         Move_To (Cr, 0.0, Gdouble (I * Cell) + 0.5);
         Line_To (Cr, Gdouble (8 * Cell), Gdouble (I * Cell) + 0.5);
      end loop;
      Stroke (Cr);
      return True;
   end On_Grid_Draw;

   --  Overview: 16 columns x 14 rows, codes 32 .. 255
   CW : constant := 8 * Set_Scale + 4;

   function On_Overview_Draw (Self : access Gtk_Widget_Record'Class;
                              Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Set_Source_Rgb (Cr, 0.12, 0.12, 0.18);
      Paint (Cr);
      for C in Char_Code loop
         declare
            I : constant Natural := C - 32;
            X : constant Gdouble := Gdouble ((I mod 16) * CW + 2);
            Y : constant Gdouble := Gdouble ((I / 16) * CW + 2);
         begin
            if C = Current then
               Set_Source_Rgb (Cr, 0.9, 0.6, 0.0);
               Rectangle (Cr, X - 2.0, Y - 2.0, Gdouble (CW), Gdouble (CW));
               Cairo.Fill (Cr);
            end if;
            if Changed (C) then
               Set_Colour (Cr, 6);
            else
               Set_Colour (Cr, 7);
            end if;
            Draw_Glyph (Cr, Get (C), X, Y, Gdouble (Set_Scale));
         end;
      end loop;
      return True;
   end On_Overview_Draw;

   function On_Text_Draw (Self : access Gtk_Widget_Record'Class;
                          Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
      T : constant String := Sample.Get_Text;
      X : Gdouble := 4.0;
   begin
      Set_Colour (Cr, 4);
      Paint (Cr);
      Set_Colour (Cr, 7);
      for Ch of T loop
         if Character'Pos (Ch) in Char_Code then
            Draw_Glyph (Cr, Get (Character'Pos (Ch)), X, 4.0, 2.0);
         end if;
         X := X + 16.0;
      end loop;
      --  the current character tiled, to see how it joins up
      for TY in 0 .. 2 loop
         for TX in 0 .. 5 loop
            Draw_Glyph (Cr, Get (Current), 4.0 + Gdouble (TX * 16),
                        28.0 + Gdouble (TY * 16), 2.0);
         end loop;
      end loop;
      return True;
   end On_Text_Draw;

   ---------------------------------------------------------------------
   --  Editing
   ---------------------------------------------------------------------

   procedure Push_Undo is
   begin
      if Undo_Count = Max_Undo then
         Undo_Stack (1 .. Max_Undo - 1) := Undo_Stack (2 .. Max_Undo);
         Undo_Count := Undo_Count - 1;
      end if;
      Undo_Count := Undo_Count + 1;
      Undo_Stack (Undo_Count) := (Current, Get (Current));
   end Push_Undo;

   procedure Undo is
   begin
      if Undo_Count > 0 then
         Current := Undo_Stack (Undo_Count).Code;
         Put (Current, Undo_Stack (Undo_Count).G);
         Undo_Count := Undo_Count - 1;
         Changed_Glyph;
      end if;
   end Undo;

   procedure Paint_At (EX, EY : Gdouble; Fill_It : Boolean) is
      PX : constant Integer := Integer (Gdouble'Floor (EX / Gdouble (Cell)));
      PY : constant Integer := Integer (Gdouble'Floor (EY / Gdouble (Cell)));
      G : Glyph := Get (Current);
   begin
      if PX not in Row_Range or else PY not in Row_Range then
         return;
      end if;
      if Fill_It then
         Flood_Fill (G, PX, PY, Paint_On);
      elsif Char_Data.Pixel (G, PX, PY) = Paint_On then
         return;
      else
         Set_Pixel (G, PX, PY, Paint_On);
      end if;
      Put (Current, G);
      Changed_Glyph;
   end Paint_At;

   function On_Grid_Press (Self : access Gtk_Widget_Record'Class;
                           Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
   begin
      Push_Undo;
      Paint_On := Event.Button /= 3;
      Painting := True;
      Paint_At (Event.X, Event.Y, (Event.State and Shift_Mask) /= 0);
      return True;
   end On_Grid_Press;

   function On_Grid_Release (Self : access Gtk_Widget_Record'Class;
                             Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Painting := False;
      return True;
   end On_Grid_Release;

   function On_Grid_Motion (Self : access Gtk_Widget_Record'Class;
                            Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
   begin
      if Painting then
         Paint_At (Event.X, Event.Y, False);
      end if;
      return True;
   end On_Grid_Motion;

   function On_Overview_Press (Self : access Gtk_Widget_Record'Class;
                               Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      CX : constant Integer := Integer (Gdouble'Floor (Event.X / Gdouble (CW)));
      CY : constant Integer := Integer (Gdouble'Floor (Event.Y / Gdouble (CW)));
   begin
      if CX in 0 .. 15 and then CY in 0 .. 13 then
         Current := 32 + CY * 16 + CX;
         Show_Status;
         Redraw_All;
      end if;
      return True;
   end On_Overview_Press;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   procedure Load_File (Path : String) is
      Ok : Boolean;
   begin
      Load (Path, Ok);
      if Ok then
         File := To_Unbounded_String (Path);
         Win.Set_Title ("Character editor - " &
                        Ada.Directories.Simple_Name (Path));
         Status.Set_Text ("loaded " & Path);
      else
         Status.Set_Text ("cannot read " & Path);
      end if;
      Redraw_All;
   end Load_File;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
   begin
      if Ask or else File = Null_Unbounded_String then
         declare
            P : constant String :=
              Choose_File (Win, "Save characters", True,
                           "Character sets (*.udg)", "*.udg", "font.udg");
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String
              (if Is_Char_File (P) then P else P & ".udg");
         end;
      end if;
      Save (To_String (File), Ok);
      Status.Set_Text ((if Ok then "saved " else "cannot write ") &
                       To_String (File));
      Win.Set_Title ("Character editor - " &
                     Ada.Directories.Simple_Name (To_String (File)));
   end Save_File;

   function Base_Of (Ext : String) return String is
     (if File = Null_Unbounded_String then "font" & Ext
      else Ada.Directories.Base_Name (To_String (File)) & Ext);

   procedure Export_BASIC is
      P : constant String :=
        Choose_File (Win, "Export as BASIC (VDU 23 lines)", True,
                     "BASIC programs (*.bas)", "*.bas", Base_Of (".bas"));
      Ok : Boolean;
   begin
      if P /= "" then
         Write_Text (P, BASIC_Text, Ok);
         Status.Set_Text ((if Ok then "wrote " else "cannot write ") & P);
      end if;
   end Export_BASIC;

   procedure Export_Asm is
      P : constant String :=
        Choose_File (Win, "Export as ACME source", True,
                     "Assembly sources (*.asm)", "*.asm", Base_Of (".asm"));
      Ok : Boolean;
   begin
      if P /= "" then
         Write_Text (P, Asm_Text (Ada.Directories.Base_Name (P)), Ok);
         Status.Set_Text ((if Ok then "wrote " else "cannot write ") & P);
      end if;
   end Export_Asm;

   ---------------------------------------------------------------------
   --  Actions
   ---------------------------------------------------------------------

   type Action is
     (A_ROM, A_Open, A_Save, A_Save_As, A_Export_BASIC, A_Export_Asm,
      A_Copy, A_Paste, A_Undo,
      A_Clear, A_Invert, A_Mirror_X, A_Mirror_Y, A_Rotate,
      A_Left, A_Right, A_Up, A_Down, A_From_ROM,
      A_Show, A_Explode, A_Grab);

   procedure Do_Action (A : Action) is
      G : Glyph := Get (Current);
   begin
      case A is
         when A_ROM =>
            Load_ROM;
            File := Null_Unbounded_String;
            Win.Set_Title ("Character editor");
            Redraw_All;
            return;
         when A_Open =>
            declare
               P : constant String :=
                 Choose_File (Win, "Open characters", False,
                              "Character sets (*.udg)", "*.udg");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
            return;
         when A_Save => Save_File (False); return;
         when A_Save_As => Save_File (True); return;
         when A_Export_BASIC => Export_BASIC; return;
         when A_Export_Asm => Export_Asm; return;
         when A_Copy =>
            Clip := G;
            Status.Set_Text ("copied character" & Current'Image);
            return;
         when A_Undo => Undo; return;
         when A_Show => Send_To_Emulator; return;
         when A_Explode =>
            Machine.Type_Text ("*FX20,6" & ASCII.LF);
            Status.Set_Text ("typed *FX20,6 in the emulator: all characters"
                             & " are definable now (PAGE moves up)");
            return;
         when A_Grab =>
            Grab_From_Emulator;
            Redraw_All;
            return;
         when others => null;
      end case;
      Push_Undo;
      case A is
         when A_Paste => G := Clip;
         when A_Clear => G := (others => 0);
         when A_Invert => Invert (G);
         when A_Mirror_X => Mirror_X (G);
         when A_Mirror_Y => Mirror_Y (G);
         when A_Rotate => Rotate (G);
         when A_Left => Shift (G, -1, 0);
         when A_Right => Shift (G, 1, 0);
         when A_Up => Shift (G, 0, -1);
         when A_Down => Shift (G, 0, 1);
         when A_From_ROM => G := ROM_Glyph (Current);
         when others => null;
      end case;
      Put (Current, G);
      Changed_Glyph;
   end Do_Action;

   Tool_Items : array (Action) of Gtk_Tool_Button;

   procedure On_Tool (Item : access Gtk_Tool_Button_Record'Class) is
   begin
      for A in Action loop
         if Gtk_Tool_Button (Item) = Tool_Items (A) then
            Do_Action (A);
            return;
         end if;
      end loop;
   end On_Tool;

   procedure On_Live (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Self.Get_Active then
         Send_To_Emulator;
      end if;
   end On_Live;

   function On_Sample (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Text_Area.Queue_Draw;
      return False;
   end On_Sample;

   function On_Key (Self : access Gtk_Widget_Record'Class;
                    Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self);
      Ctrl : constant Boolean := (Event.State and Control_Mask) /= 0;
      K : constant Gdk_Key_Type := Event.Keyval;
      procedure Move (D : Integer) is
      begin
         Current := 32 + (Current - 32 + D) mod 224;
         Show_Status;
         Redraw_All;
      end Move;
   begin
      if Sample.Has_Focus then
         return False;
      end if;
      if Ctrl and then K = GDK_LC_z then
         Undo;
      elsif Ctrl and then K = GDK_LC_c then
         Do_Action (A_Copy);
      elsif Ctrl and then K = GDK_LC_v then
         Do_Action (A_Paste);
      elsif Ctrl and then K = GDK_LC_s then
         Save_File (False);
      elsif K = GDK_Left or else K = GDK_Page_Up then
         Move (-1);
      elsif K = GDK_Right or else K = GDK_Page_Down then
         Move (1);
      elsif K = GDK_Up then
         Move (-16);
      elsif K = GDK_Down then
         Move (16);
      else
         return False;
      end if;
      return True;
   end On_Key;

   function On_Delete (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if File /= Null_Unbounded_String then
         Settings.Set ("udg_file", To_String (File));
      end if;
      Win.Hide;
      return True;
   end On_Delete;

   procedure Build is
      VBox, HBox, Right : Gtk_Box;
      Tools : Gtk_Toolbar;
      Frame : Gtk_Frame;

      procedure Tool (Label : String; A : Action; Tip : String;
                      Icon : String := "") is
      begin
         Gtk_New (Tool_Items (A), Label => Label);
         if Icon /= "" then
            Tool_Items (A).Set_Icon_Name (Icon);
         end if;
         Tool_Items (A).Set_Tooltip_Text (Tip);
         Tool_Items (A).Set_Is_Important (True);
         Tool_Items (A).On_Clicked (On_Tool'Access);
         Tools.Insert (Tool_Items (A));
      end Tool;

      procedure Sep is
         S : Gtk_Separator_Tool_Item;
      begin
         Gtk_New (S);
         Tools.Insert (S);
      end Sep;

      function Area (W, H : Gint) return Gtk_Drawing_Area is
         A : Gtk_Drawing_Area;
      begin
         Gtk_New (A);
         A.Set_Size_Request (W, H);
         A.Add_Events (Button_Press_Mask or Button_Release_Mask
                       or Button_Motion_Mask);
         return A;
      end Area;
   begin
      Gtk_New (Win);
      Win.Set_Title ("Character editor");
      Win.Set_Default_Size (900, 640);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Tool ("OS font", A_ROM, "Start from the OS font", "document-new");
      Tool ("Open", A_Open, "Open a .udg file", "document-open");
      Tool ("Save", A_Save, "Save (Ctrl+S)", "document-save");
      Tool ("Save as", A_Save_As, "Save under a new name");
      Tool ("Export BASIC", A_Export_BASIC,
            "Write VDU 23 lines for the changed characters");
      Tool ("Export .asm", A_Export_Asm, "Write ACME !byte lines");
      Sep;
      Tool ("Copy", A_Copy, "Copy the character (Ctrl+C)");
      Tool ("Paste", A_Paste, "Paste into this character (Ctrl+V)");
      Tool ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Text);
      Tool ("Clear", A_Clear, "Clear the character");
      Tool ("Invert", A_Invert, "Invert");
      Tool ("Flip H", A_Mirror_X, "Mirror left-right");
      Tool ("Flip V", A_Mirror_Y, "Mirror top-bottom");
      Tool ("Rotate", A_Rotate, "Rotate 90 degrees clockwise");
      Tool ("<", A_Left, "Scroll left (wraps)");
      Tool (">", A_Right, "Scroll right (wraps)");
      Tool ("^", A_Up, "Scroll up (wraps)");
      Tool ("v", A_Down, "Scroll down (wraps)");
      Tool ("From font", A_From_ROM, "Restore the OS definition");
      Sep;
      Tool ("Show in emulator", A_Show,
            "Copy the characters into the running OS's font memory");
      Tool ("Explode font", A_Explode,
            "Type *FX20,6 so that codes 32-223 can be redefined too");
      Tool ("Grab from emulator", A_Grab,
            "Copy the definitions from the running OS");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 8);
      VBox.Pack_Start (HBox, Expand => True, Fill => True);

      Grid := Area (8 * Cell + 1, 8 * Cell + 1);
      Grid.On_Draw (On_Grid_Draw'Access);
      Grid.On_Button_Press_Event (On_Grid_Press'Access);
      Grid.On_Button_Release_Event (On_Grid_Release'Access);
      Grid.On_Motion_Notify_Event (On_Grid_Motion'Access);
      Gtk_New (Frame, "Character (left: draw, right: erase, shift: fill)");
      Frame.Add (Grid);
      Frame.Set_Valign (Align_Start);
      HBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 6);

      Gtk_New_Vbox (Right, Spacing => 6);
      HBox.Pack_Start (Right, Expand => True, Fill => True);

      Overview := Area (16 * CW, 14 * CW);
      Overview.On_Draw (On_Overview_Draw'Access);
      Overview.On_Button_Press_Event (On_Overview_Press'Access);
      Gtk_New (Frame, "Codes 32-255 (changed ones in cyan)");
      Frame.Add (Overview);
      Right.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New (Sample);
      Sample.Set_Text ("Hello " & Character'Val (224) & Character'Val (225) &
                       Character'Val (226));
      Sample.On_Key_Release_Event (On_Sample'Access);
      Right.Pack_Start (Sample, Expand => False, Fill => False);
      Text_Area := Area (400, 80);
      Text_Area.On_Draw (On_Text_Draw'Access);
      Right.Pack_Start (Text_Area, Expand => False, Fill => False);

      Gtk_New (Live, "Live in emulator (every change goes to the OS font)");
      Live.On_Toggled (On_Live'Access);
      Right.Pack_Start (Live, Expand => False, Fill => False);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      Status.Set_Selectable (True);
      VBox.Pack_Start (Status, Expand => False, Fill => False, Padding => 4);
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
      pragma Unreferenced (Parent);
   begin
      if Win = null then
         Build;
         Win.Show_All;
         declare
            Last : constant String := Settings.Get ("udg_file", "");
         begin
            if File = "" and then Last /= ""
              and then Ada.Directories.Exists (Last)
            then
               Load_File (Last);
            elsif File = "" then
               Load_ROM;
            end if;
         end;
         Show_Status;
      end if;
      if File /= "" then
         if Ada.Directories.Exists (File) then
            Load_File (Ada.Directories.Full_Name (File));
         else
            Load_ROM;
            Char_Editor.File := To_Unbounded_String (File);
         end if;
      end if;
      Redraw_All;
      Win.Show_All;
      Win.Present;
   end Open;

end Char_Editor;
