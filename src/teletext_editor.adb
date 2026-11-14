-- ***************************************************************************
--                         AdaBeeb - Teletext_Editor
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
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Ada.Directories;
with System;

with Glib; use Glib;
with Gdk.Event; use Gdk.Event;
with Gdk.Types; use Gdk.Types;
with Gdk.Types.Keysyms; use Gdk.Types.Keysyms;
with Gtk.Box; use Gtk.Box;
with Gtk.Button; use Gtk.Button;
with Gtk.Check_Button; use Gtk.Check_Button;
with Gtk.Drawing_Area; use Gtk.Drawing_Area;
with Gtk.Enums; use Gtk.Enums;
with Gtk.Frame; use Gtk.Frame;
with Gtk.Grid; use Gtk.Grid;
with Gtk.Label; use Gtk.Label;
with Gtk.Radio_Button; use Gtk.Radio_Button;
with Gtk.Separator_Tool_Item; use Gtk.Separator_Tool_Item;
with Gtk.Tool_Button; use Gtk.Tool_Button;
with Gtk.Toggle_Button; use Gtk.Toggle_Button;
with Gtk.Toolbar; use Gtk.Toolbar;
with Gtk.Widget; use Gtk.Widget;
with Cairo; use Cairo;
with Cairo.Image_Surface;
with Cairo.Surface;

with Types; use Types;
with Interfaces; use Interfaces;
with Machine;
with Settings;
with Editor_Util; use Editor_Util;
with Teletext_Render; use Teletext_Render;

package body Teletext_Editor is

   Win      : Gtk_Window := null;
   Canvas   : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Live, Codes_Check, Reveal_Check : Gtk_Check_Button;
   Mode_Text, Mode_Draw : Gtk_Radio_Button;
   Surf     : Cairo_Surface;

   Scr : Screen := (others => (others => 32));
   Img : access Image := new Image;
   Cur_Row, Cur_Col : Natural := 0;
   File : Unbounded_String;
   Painting : Boolean := False;
   Paint_On : Boolean := True;

   Max_Undo : constant := 32;
   type Screen_Access is access Screen;
   Undo_Stack : array (1 .. Max_Undo) of Screen_Access;
   Undo_Count : Natural := 0;

   function Is_Teletext_File (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
   begin
      return L'Length > 3 and then L (L'Last - 2 .. L'Last) = ".m7";
   end Is_Teletext_File;

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   function Emu_Address (I : Natural) return Word is
      Start : constant Natural := Machine.Screen_Start;
   begin
      return Word (16#7C00# + (Start - 16#7C00# + I) mod 16#400#);
   end Emu_Address;

   procedure Send_To_Emulator (Quiet : Boolean := False) is
   begin
      if not Machine.Teletext_Mode then
         if not Quiet then
            Machine.Type_Text ("MODE 7" & ASCII.LF);
            Status.Set_Text ("the emulator was not in mode 7: typed MODE 7;"
                             & " click Show again when it has cleared");
         end if;
         return;
      end if;
      for R in 0 .. Rows - 1 loop
         for C in 0 .. Cols - 1 loop
            Machine.Screen_Poke (Emu_Address (R * Cols + C), Scr (R, C));
         end loop;
      end loop;
      if not Quiet then
         Status.Set_Text ("the screen is on the emulator's mode 7 display");
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
   begin
      if not Machine.Teletext_Mode then
         Status.Set_Text ("the emulator is not showing mode 7");
         return;
      end if;
      for R in 0 .. Rows - 1 loop
         for C in 0 .. Cols - 1 loop
            Scr (R, C) := Machine.Screen_Peek (Emu_Address (R * Cols + C));
         end loop;
      end loop;
      Status.Set_Text ("grabbed the emulator's mode 7 screen");
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Drawing
   ---------------------------------------------------------------------

   procedure Show_Status is
      B : constant Byte := Scr (Cur_Row, Cur_Col);
      Info_C : constant Cell_Info := Info (Scr, Cur_Row, Cur_Col);
      Name : constant String := Control_Name (B);
   begin
      Status.Set_Text
        ("row" & Cur_Row'Image & " col" & Cur_Col'Image & "  code" &
         Natural (B)'Image & " (&" & Hex2 (Natural (B)) & ")" &
         (if (B and 16#7F#) < 32 then "  control: " & Name
          elsif Info_C.Graphics then "  graphics, " &
            Physical_Name (Info_C.Fg)
          else "  text, " & Physical_Name (Info_C.Fg)) &
         "  on " & Physical_Name (Info_C.Bg) &
         "  |  screen address &" &
         Hex4 (16#7C00# + Cur_Row * Cols + Cur_Col));
   end Show_Status;

   Flash_Phase : Boolean := True;

   procedure Update_Image is
      Stride : constant Natural :=
        Natural (Cairo.Image_Surface.Get_Stride (Surf)) / 4;
      Addr : constant System.Address :=
        Cairo.Image_Surface.Get_Data_Generic (Surf);
      type Pixels is array (0 .. Height - 1, 0 .. Stride - 1) of Pixel;
      Dst : Pixels;
      for Dst'Address use Addr;
      pragma Import (Ada, Dst);
   begin
      Render (Scr, Img.all, Flash_Phase, Reveal_Check.Get_Active);
      Cairo.Surface.Flush (Surf);
      for Y in 0 .. Height - 1 loop
         for X in 0 .. Width - 1 loop
            Dst (Y, X) := Img (Y, X);
         end loop;
      end loop;
      Cairo.Surface.Mark_Dirty (Surf);
   end Update_Image;

   procedure Redraw is
   begin
      Update_Image;
      Canvas.Queue_Draw;
      Show_Status;
   end Redraw;

   procedure Changed is
   begin
      Redraw;
      if Live.Get_Active then
         Send_To_Emulator (Quiet => True);
      end if;
   end Changed;

   function On_Canvas_Draw (Self : access Gtk_Widget_Record'Class;
                            Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Set_Source_Surface (Cr, Surf, 0.0, 0.0);
      Paint (Cr);
      if Codes_Check.Get_Active then
         Select_Font_Face (Cr, "Sans", Cairo_Font_Slant_Normal,
                           Cairo_Font_Weight_Normal);
         Set_Font_Size (Cr, 7.0);
         for R in 0 .. Rows - 1 loop
            for C in 0 .. Cols - 1 loop
               declare
                  B : constant Byte := Scr (R, C) and 16#7F#;
               begin
                  if B < 32 then
                     Set_Source_Rgba (Cr, 0.5, 0.5, 0.5, 0.55);
                     Rectangle (Cr, Gdouble (C * Char_W) + 1.0,
                                Gdouble (R * Char_H) + 1.0,
                                Gdouble (Char_W) - 2.0,
                                Gdouble (Char_H) - 2.0);
                     Cairo.Fill (Cr);
                     Set_Source_Rgb (Cr, 1.0, 1.0, 1.0);
                     Move_To (Cr, Gdouble (C * Char_W) + 1.0,
                              Gdouble (R * Char_H) + 12.0);
                     Show_Text (Cr, Control_Name (B));
                  end if;
               end;
            end loop;
         end loop;
      end if;
      --  cursor
      Set_Source_Rgb (Cr, 1.0, 0.6, 0.0);
      Set_Line_Width (Cr, 2.0);
      Rectangle (Cr, Gdouble (Cur_Col * Char_W) + 1.0,
                 Gdouble (Cur_Row * Char_H) + 1.0,
                 Gdouble (Char_W) - 2.0, Gdouble (Char_H) - 2.0);
      Stroke (Cr);
      return True;
   end On_Canvas_Draw;

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
      Undo_Stack (Undo_Count) := new Screen'(Scr);
   end Push_Undo;

   procedure Undo is
   begin
      if Undo_Count > 0 then
         Scr := Undo_Stack (Undo_Count).all;
         Undo_Count := Undo_Count - 1;
         Changed;
      end if;
   end Undo;

   procedure Advance is
   begin
      if Cur_Col < Cols - 1 then
         Cur_Col := Cur_Col + 1;
      elsif Cur_Row < Rows - 1 then
         Cur_Col := 0;
         Cur_Row := Cur_Row + 1;
      end if;
   end Advance;

   procedure Put_Code (B : Byte) is
   begin
      Push_Undo;
      Scr (Cur_Row, Cur_Col) := B;
      Advance;
      Changed;
   end Put_Code;

   Sixel_Bit : constant array (0 .. 5) of Byte :=
     (1, 2, 4, 8, 16, 64);

   procedure Paint_At (EX, EY : Gdouble) is
      X : constant Integer := Integer (Gdouble'Floor (EX));
      Y : constant Integer := Integer (Gdouble'Floor (EY));
   begin
      if X < 0 or else Y < 0 or else X >= Width or else Y >= Height then
         return;
      end if;
      declare
         C : constant Natural := X / Char_W;
         R : constant Natural := Y / Char_H;
         YI : constant Natural := Y mod Char_H;
         SX : constant Natural := (X mod Char_W) / 8;
         SY : constant Natural := (if YI < 6 then 0 elsif YI < 14 then 1
                                   else 2);
         Inf : constant Cell_Info := Info (Scr, R, C);
         B : Byte := Scr (R, C);
         Bit : constant Byte := Sixel_Bit (SY * 2 + SX);
      begin
         Cur_Row := R;
         Cur_Col := C;
         if not Inf.Graphics then
            Status.Set_Text ("no graphics colour code before this cell: " &
                             "put a graphics colour (gred, ggrn ...) to " &
                             "its left first");
            return;
         end if;
         if (B and 16#20#) = 0 then
            B := 16#A0#;               --  an empty mosaic
         end if;
         B := (if Paint_On then B or Bit else B and not Bit) or 16#A0#;
         if B /= Scr (R, C) then
            Scr (R, C) := B;
            Changed;
         end if;
      end;
   end Paint_At;

   function On_Press (Self : access Gtk_Widget_Record'Class;
                      Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
   begin
      Canvas.Grab_Focus;
      if Mode_Draw.Get_Active then
         Push_Undo;
         Paint_On := Event.Button /= 3;
         Painting := True;
         Paint_At (Event.X, Event.Y);
      else
         declare
            C : constant Integer :=
              Integer (Gdouble'Floor (Event.X)) / Char_W;
            R : constant Integer :=
              Integer (Gdouble'Floor (Event.Y)) / Char_H;
         begin
            if C in 0 .. Cols - 1 and then R in 0 .. Rows - 1 then
               Cur_Col := C;
               Cur_Row := R;
               Canvas.Queue_Draw;
               Show_Status;
            end if;
         end;
      end if;
      return True;
   end On_Press;

   function On_Release (Self : access Gtk_Widget_Record'Class;
                        Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      Painting := False;
      return True;
   end On_Release;

   function On_Motion (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
   begin
      if Painting then
         Paint_At (Event.X, Event.Y);
      end if;
      return True;
   end On_Motion;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   function To_Bytes return Byte_Array is
      D : Byte_Array (0 .. Rows * Cols - 1);
   begin
      for R in 0 .. Rows - 1 loop
         for C in 0 .. Cols - 1 loop
            D (R * Cols + C) := Scr (R, C);
         end loop;
      end loop;
      return D;
   end To_Bytes;

   procedure Load_File (Path : String) is
      Ok : Boolean;
      D : constant Byte_Array := Read_Bytes (Path, Ok);
   begin
      if not Ok then
         Status.Set_Text ("cannot read " & Path);
         return;
      end if;
      Scr := (others => (others => 32));
      for I in 0 .. Natural'Min (D'Length, Rows * Cols) - 1 loop
         Scr (I / Cols, I mod Cols) := D (D'First + I);
      end loop;
      File := To_Unbounded_String (Path);
      Win.Set_Title ("Teletext editor - " & Ada.Directories.Simple_Name (Path));
      Undo_Count := 0;
      Redraw;
   end Load_File;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
   begin
      if Ask or else File = Null_Unbounded_String then
         declare
            P : constant String :=
              Choose_File (Win, "Save mode 7 screen", True,
                           "Mode 7 screens (*.m7)", "*.m7", "screen.m7");
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String
              (if Is_Teletext_File (P) then P else P & ".m7");
         end;
      end if;
      Write_Bytes (To_String (File), To_Bytes, Ok);
      if Ok then
         Write_Inf (To_String (File), 16#7C00#, 16#7C00#);
      end if;
      Status.Set_Text ((if Ok then "saved " & To_String (File) &
                          "  (*LOAD it at &7C00 in MODE 7)"
                        else "cannot write " & To_String (File)));
      Win.Set_Title ("Teletext editor - " &
                     Ada.Directories.Simple_Name (To_String (File)));
   end Save_File;

   function Img_N (N : Natural) return String is
     (Trim (N'Image, Ada.Strings.Left));

   function Base_Of (Ext : String) return String is
     (if File = Null_Unbounded_String then "screen" & Ext
      else Ada.Directories.Base_Name (To_String (File)) & Ext);

   procedure Export_BASIC is
      P : constant String :=
        Choose_File (Win, "Export as BASIC", True,
                     "BASIC programs (*.bas)", "*.bas", Base_Of (".bas"));
      T : Unbounded_String;
      D : constant Byte_Array := To_Bytes;
      Ok : Boolean;
      N : Natural := 100;
   begin
      if P = "" then
         return;
      end if;
      Append (T, "10 REM Mode 7 screen from the AdaBeeb Forge" & ASCII.LF &
              "20 MODE 7:VDU 23;8202;0;0;0;" & ASCII.LF &
              "30 FOR A%=&7C00 TO &7FE7:READ B%:?A%=B%:NEXT" & ASCII.LF &
              "40 A$=GET$:MODE 7:END" & ASCII.LF);
      for L in 0 .. 49 loop
         Append (T, Img_N (N) & " DATA ");
         for K in 0 .. 19 loop
            Append (T, Img_N (Natural (D (L * 20 + K))) &
                    (if K < 19 then "," else ""));
         end loop;
         Append (T, ASCII.LF);
         N := N + 10;
      end loop;
      Write_Text (P, To_String (T), Ok);
      Status.Set_Text ((if Ok then "wrote " else "cannot write ") & P);
   end Export_BASIC;

   procedure Export_Asm is
      P : constant String :=
        Choose_File (Win, "Export as ACME source", True,
                     "Assembly sources (*.asm)", "*.asm", Base_Of (".asm"));
      T : Unbounded_String;
      Ok : Boolean;
   begin
      if P = "" then
         return;
      end if;
      Append (T, "; mode 7 screen (40 x 25) - AdaBeeb Forge" & ASCII.LF &
              "; copy the 1000 bytes to &7C00 in MODE 7" & ASCII.LF &
              Ada.Directories.Base_Name (P) & ASCII.LF);
      for R in 0 .. Rows - 1 loop
         Append (T, "        !byte ");
         for C in 0 .. Cols - 1 loop
            Append (T, "$" & Hex2 (Natural (Scr (R, C))) &
                    (if C < Cols - 1 then "," else ""));
         end loop;
         Append (T, ASCII.LF);
      end loop;
      Write_Text (P, To_String (T), Ok);
      Status.Set_Text ((if Ok then "wrote " else "cannot write ") & P);
   end Export_Asm;

   ---------------------------------------------------------------------
   --  Actions
   ---------------------------------------------------------------------

   type Action is
     (A_New, A_Open, A_Save, A_Save_As, A_Export_BASIC, A_Export_Asm,
      A_Undo, A_Clear_Row, A_Insert_Row, A_Delete_Row,
      A_Show, A_Grab);

   procedure Do_Action (A : Action) is
   begin
      case A is
         when A_New =>
            Push_Undo;
            Scr := (others => (others => 32));
            File := Null_Unbounded_String;
            Win.Set_Title ("Teletext editor");
            Changed;
         when A_Open =>
            declare
               P : constant String :=
                 Choose_File (Win, "Open mode 7 screen", False,
                              "Mode 7 screens (*.m7)", "*.m7");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Save => Save_File (False);
         when A_Save_As => Save_File (True);
         when A_Export_BASIC => Export_BASIC;
         when A_Export_Asm => Export_Asm;
         when A_Undo => Undo;
         when A_Clear_Row =>
            Push_Undo;
            for C in 0 .. Cols - 1 loop
               Scr (Cur_Row, C) := 32;
            end loop;
            Changed;
         when A_Insert_Row =>
            Push_Undo;
            for R in reverse Cur_Row + 1 .. Rows - 1 loop
               for C in 0 .. Cols - 1 loop
                  Scr (R, C) := Scr (R - 1, C);
               end loop;
            end loop;
            for C in 0 .. Cols - 1 loop
               Scr (Cur_Row, C) := 32;
            end loop;
            Changed;
         when A_Delete_Row =>
            Push_Undo;
            for R in Cur_Row .. Rows - 2 loop
               for C in 0 .. Cols - 1 loop
                  Scr (R, C) := Scr (R + 1, C);
               end loop;
            end loop;
            for C in 0 .. Cols - 1 loop
               Scr (Rows - 1, C) := 32;
            end loop;
            Changed;
         when A_Show => Send_To_Emulator;
         when A_Grab =>
            Push_Undo;
            Grab_From_Emulator;
            Redraw;
      end case;
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

   --  Control code buttons
   type Code_Button is record
      Button : Gtk_Button;
      Code   : Byte := 0;
   end record;
   Code_Buttons : array (1 .. 32) of Code_Button;
   Code_Count : Natural := 0;

   procedure On_Code (Self : access Gtk_Button_Record'Class) is
   begin
      for I in 1 .. Code_Count loop
         if Gtk_Button (Self) = Code_Buttons (I).Button then
            Put_Code (128 + Code_Buttons (I).Code);
            Canvas.Grab_Focus;
            return;
         end if;
      end loop;
   end On_Code;

   procedure On_Toggle (Self : access Gtk_Toggle_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Redraw;
   end On_Toggle;

   procedure On_Live (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Self.Get_Active then
         Send_To_Emulator;
      end if;
   end On_Live;

   function On_Key (Self : access Gtk_Widget_Record'Class;
                    Event : Gdk_Event_Key) return Boolean is
      pragma Unreferenced (Self);
      Ctrl : constant Boolean := (Event.State and Control_Mask) /= 0;
      K : constant Gdk_Key_Type := Event.Keyval;
   begin
      if Ctrl and then K = GDK_LC_z then
         Undo;
      elsif Ctrl and then K = GDK_LC_s then
         Save_File (False);
      elsif K = GDK_Left then
         Cur_Col := (if Cur_Col > 0 then Cur_Col - 1 else 0);
      elsif K = GDK_Right then
         Cur_Col := Natural'Min (Cols - 1, Cur_Col + 1);
      elsif K = GDK_Up then
         Cur_Row := (if Cur_Row > 0 then Cur_Row - 1 else 0);
      elsif K = GDK_Down then
         Cur_Row := Natural'Min (Rows - 1, Cur_Row + 1);
      elsif K = GDK_Home then
         Cur_Col := 0;
      elsif K = GDK_End then
         Cur_Col := Cols - 1;
      elsif K = GDK_Return then
         Cur_Col := 0;
         Cur_Row := Natural'Min (Rows - 1, Cur_Row + 1);
      elsif K = GDK_BackSpace then
         if Cur_Col > 0 then
            Cur_Col := Cur_Col - 1;
            Push_Undo;
            Scr (Cur_Row, Cur_Col) := 32;
            Changed;
         end if;
      elsif K = GDK_Delete then
         Push_Undo;
         Scr (Cur_Row, Cur_Col) := 32;
         Changed;
      elsif not Ctrl and then K in 16#20# .. 16#7E# then
         Put_Code (Byte (K));
      else
         return False;
      end if;
      Canvas.Queue_Draw;
      Show_Status;
      return True;
   end On_Key;

   function On_Delete (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if File /= Null_Unbounded_String then
         Settings.Set ("m7_file", To_String (File));
      end if;
      Win.Hide;
      return True;
   end On_Delete;

   procedure Build is
      VBox, HBox, Side : Gtk_Box;
      Tools : Gtk_Toolbar;
      Frame : Gtk_Frame;
      G : Gtk_Grid;
      Row_N : Gint := 0;

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

      procedure Code (Label : String; C : Byte; Col : Gint; Tip : String) is
         B : Gtk_Button;
      begin
         Gtk_New (B, Label);
         B.Set_Tooltip_Text (Tip & " (code" & Natural (128 + C)'Image & ")");
         B.On_Clicked (On_Code'Access);
         B.Set_Can_Focus (False);
         Code_Count := Code_Count + 1;
         Code_Buttons (Code_Count) := (B, C);
         G.Attach (B, Col, Row_N);
      end Code;

      Names : constant array (Byte range 1 .. 7) of String (1 .. 7) :=
        ("red    ", "green  ", "yellow ", "blue   ", "magenta", "cyan   ",
         "white  ");
   begin
      Gtk_New (Win);
      Win.Set_Title ("Teletext editor");
      Win.Set_Default_Size (1000, 640);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Tool ("New", A_New, "Blank screen", "document-new");
      Tool ("Open", A_Open, "Open a .m7 screen", "document-open");
      Tool ("Save", A_Save, "Save (Ctrl+S)", "document-save");
      Tool ("Save as", A_Save_As, "Save under a new name");
      Tool ("Export BASIC", A_Export_BASIC,
            "Write a BASIC program that shows the screen");
      Tool ("Export .asm", A_Export_Asm, "Write ACME !byte lines");
      Tool ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      Sep;
      Tool ("Clear row", A_Clear_Row, "Blank the cursor's row");
      Tool ("Insert row", A_Insert_Row, "Insert a blank row at the cursor");
      Tool ("Delete row", A_Delete_Row, "Delete the cursor's row");
      Sep;
      Tool ("Show in emulator", A_Show,
            "Copy the screen to the emulator's mode 7 display");
      Tool ("Grab from emulator", A_Grab,
            "Take the mode 7 screen of the running program");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 8);
      VBox.Pack_Start (HBox, Expand => True, Fill => True);

      Gtk_New (Canvas);
      Canvas.Set_Size_Request (Width, Height);
      Canvas.Set_Can_Focus (True);
      Canvas.Add_Events (Button_Press_Mask or Button_Release_Mask
                         or Button_Motion_Mask or Key_Press_Mask);
      Canvas.On_Draw (On_Canvas_Draw'Access);
      Canvas.On_Button_Press_Event (On_Press'Access);
      Canvas.On_Button_Release_Event (On_Release'Access);
      Canvas.On_Motion_Notify_Event (On_Motion'Access);
      Gtk_New (Frame);
      Frame.Add (Canvas);
      Frame.Set_Valign (Align_Start);
      HBox.Pack_Start (Frame, Expand => False, Fill => False, Padding => 4);

      Gtk_New_Vbox (Side, Spacing => 4);
      HBox.Pack_Start (Side, Expand => True, Fill => True);
      Gtk_New (Mode_Text, Widget_SList.Null_List,
               "Type text (click a cell, type)");
      Gtk_New (Mode_Draw, Mode_Text.Get_Group,
               "Draw graphics (left: set, right: clear)");
      Side.Pack_Start (Mode_Text, Expand => False, Fill => False);
      Side.Pack_Start (Mode_Draw, Expand => False, Fill => False);
      Gtk_New (Codes_Check, "Show control codes");
      Codes_Check.Set_Active (True);
      Codes_Check.On_Toggled (On_Toggle'Access);
      Side.Pack_Start (Codes_Check, Expand => False, Fill => False);
      Gtk_New (Reveal_Check, "Reveal concealed text");
      Reveal_Check.On_Toggled (On_Toggle'Access);
      Side.Pack_Start (Reveal_Check, Expand => False, Fill => False);
      Gtk_New (Live, "Live in emulator");
      Live.On_Toggled (On_Live'Access);
      Side.Pack_Start (Live, Expand => False, Fill => False);

      Gtk_New (Frame, "Control codes (inserted at the cursor)");
      Gtk_New (G);
      G.Set_Row_Spacing (2);
      G.Set_Column_Spacing (2);
      for C in Byte range 1 .. 7 loop
         Code (Trim (Names (C), Ada.Strings.Right), C, 0,
               "Text in " & Trim (Names (C), Ada.Strings.Right));
         Code ("g " & Trim (Names (C), Ada.Strings.Right), C + 16, 1,
               "Graphics in " & Trim (Names (C), Ada.Strings.Right));
         Row_N := Row_N + 1;
      end loop;
      Code ("new bg", 16#1D#, 0, "Background = current colour");
      Code ("black bg", 16#1C#, 1, "Black background");
      Row_N := Row_N + 1;
      Code ("double", 16#0D#, 0, "Double height (repeat on the next row)");
      Code ("normal", 16#0C#, 1, "Normal height");
      Row_N := Row_N + 1;
      Code ("flash", 16#08#, 0, "Flashing");
      Code ("steady", 16#09#, 1, "Steady");
      Row_N := Row_N + 1;
      Code ("contig.", 16#19#, 0, "Contiguous graphics");
      Code ("separated", 16#1A#, 1, "Separated graphics");
      Row_N := Row_N + 1;
      Code ("hold", 16#1E#, 0, "Hold graphics");
      Code ("release", 16#1F#, 1, "Release graphics");
      Row_N := Row_N + 1;
      Code ("conceal", 16#18#, 0, "Conceal (until revealed)");
      Frame.Add (G);
      Side.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      Status.Set_Selectable (True);
      VBox.Pack_Start (Status, Expand => False, Fill => False, Padding => 4);

      Surf := Cairo.Image_Surface.Create
        (Cairo.Image_Surface.Cairo_Format_RGB24, Width, Height);
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
      pragma Unreferenced (Parent);
   begin
      if Win = null then
         Build;
         Win.Show_All;
         declare
            Last : constant String := Settings.Get ("m7_file", "");
         begin
            if File = "" and then Last /= ""
              and then Ada.Directories.Exists (Last)
            then
               Load_File (Last);
            end if;
         end;
      end if;
      if File /= "" then
         if Ada.Directories.Exists (File) then
            Load_File (Ada.Directories.Full_Name (File));
         else
            Teletext_Editor.File := To_Unbounded_String (File);
         end if;
      end if;
      Redraw;
      Win.Show_All;
      Win.Present;
      Canvas.Grab_Focus;
   end Open;

end Teletext_Editor;
