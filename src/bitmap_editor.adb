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
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Ada.Directories;
with System;

with Glib; use Glib;
with Glib.Main;
with Gdk.Event; use Gdk.Event;
with Gdk.Types; use Gdk.Types;
with Gdk.Types.Keysyms; use Gdk.Types.Keysyms;
with Gtk.Box; use Gtk.Box;
with Gtk.Check_Button; use Gtk.Check_Button;
with Gtk.Drawing_Area; use Gtk.Drawing_Area;
with Gtk.Enums; use Gtk.Enums;
with Gtk.Frame; use Gtk.Frame;
with Gtk.Label; use Gtk.Label;
with Gtk.Radio_Button; use Gtk.Radio_Button;
with Gtk.Scrolled_Window; use Gtk.Scrolled_Window;
with Gtk.Separator_Tool_Item; use Gtk.Separator_Tool_Item;
with Gtk.Tool_Button; use Gtk.Tool_Button;
with Gtk.Toggle_Button; use Gtk.Toggle_Button;
with Gtk.Toolbar; use Gtk.Toolbar;
with Gtk.Widget; use Gtk.Widget;
with Cairo; use Cairo;
with Cairo.Image_Surface;
with Cairo.Surface;
with Cairo.Pattern;

with Types; use Types;
with Interfaces; use Interfaces;
with Machine;
with Settings;
with Editor_Util; use Editor_Util;
with Bitmap_Data; use Bitmap_Data;

package body Bitmap_Editor is

   Win      : Gtk_Window := null;
   Canvas, Pal_Area : Gtk_Drawing_Area;
   Status   : Gtk_Label;
   Live, Dither_Check, Zoom_Check : Gtk_Check_Button;
   Surf     : Cairo_Surface;

   type Tool_Kind is (Pencil, Line_Tool, Rect_Tool, Box_Tool, Oval_Tool,
                      Disc_Tool, Fill_Tool, Pick_Tool);
   Tool_Names : constant array (Tool_Kind) of access constant String :=
     (new String'("Pencil"), new String'("Line"), new String'("Rectangle"),
      new String'("Filled rect."), new String'("Ellipse"),
      new String'("Filled ellipse"), new String'("Fill"),
      new String'("Pick colour"));
   Tool_Buttons : array (Tool_Kind) of Gtk_Radio_Button;
   Mode_Buttons : array (Mode_Number) of Gtk_Radio_Button;
   Current_Tool : Tool_Kind := Pencil;

   Ink   : Logical := 1;
   Paper : Logical := 0;
   File  : Unbounded_String;
   Dragging : Boolean := False;
   Drag_Colour : Logical := 1;
   Start_X, Start_Y, Last_X, Last_Y : Integer := 0;
   Updating : Boolean := False;

   Max_Undo : constant := 24;
   Undo_Stack : array (1 .. Max_Undo) of Picture;
   Undo_Count : Natural := 0;

   function Is_Bitmap_File (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
   begin
      return L'Length > 4 and then L (L'Last - 3 .. L'Last) = ".bbm";
   end Is_Bitmap_File;

   function Is_Image_File (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
   begin
      return L'Length > 4 and then L (L'Last - 3 .. L'Last) = ".png";
   end Is_Image_File;

   function Zoom return Natural is (if Zoom_Check.Get_Active then 2 else 1);

   ---------------------------------------------------------------------
   --  Emulator link
   ---------------------------------------------------------------------

   Pending_Show : Boolean := False;

   function ULA_Index (L : Logical) return Natural is
     (case Colours is
        when 2 => (if L = 0 then 0 else 15),
        when 4 => (L / 2) * 8 + (L mod 2) * 2,
        when others => L);

   procedure Poke_Screen is
      D : constant Byte_Array := Screen_Bytes;
      Base : constant Natural := Screen_Base;
      Start : constant Natural := Machine.Screen_Start;
      Off : constant Natural :=
        (if Start >= Base then Start - Base else 0);
   begin
      for I in D'Range loop
         Machine.Screen_Poke (Word (Base + (Off + I) mod Screen_Size), D (I));
      end loop;
   end Poke_Screen;

   function Mode_Matches return Boolean is
     (Machine.Screen_Mode = Mode and then not Machine.Teletext_Mode);

   procedure Request_Mode is
      Cmd : Unbounded_String := To_Unbounded_String
        ("MODE" & Mode'Image & ":VDU 23;8202;0;0;0;");
   begin
      for L in 0 .. Colours - 1 loop
         declare
            Def_Saved : constant Byte := Physical (L);
         begin
            Append (Cmd, ":VDU 19," & Trim (L'Image, Ada.Strings.Left) & "," &
                    Trim (Natural (Def_Saved)'Image, Ada.Strings.Left) &
                    ";0;");
         end;
      end loop;
      Machine.Type_Text (To_String (Cmd) & ASCII.LF);
      Pending_Show := True;
   end Request_Mode;

   function On_Pending (Unused : Integer) return Boolean;
   package Timer_Sources is new Glib.Main.Generic_Sources (Integer);

   function On_Pending (Unused : Integer) return Boolean is
   begin
      if not Pending_Show then
         return False;
      end if;
      if Machine.Typing_Busy then
         return True;
      end if;
      Pending_Show := False;
      Poke_Screen;
      Status.Set_Text ("the picture is on the emulator's screen (MODE" &
                       Mode'Image & ")");
      return False;
   end On_Pending;

   procedure Send_To_Emulator (Quiet : Boolean := False) is
      Id : Glib.Main.G_Source_Id;
      pragma Unreferenced (Id);
      Pal_Ok : Boolean := True;
   begin
      for L in 0 .. Colours - 1 loop
         if (Machine.ULA_Palette (ULA_Index (L)) and 15) /= Physical (L) then
            Pal_Ok := False;
         end if;
      end loop;
      if Mode_Matches and then Pal_Ok then
         Poke_Screen;
         if not Quiet then
            Status.Set_Text ("the picture is on the emulator's screen");
         end if;
      elsif not Quiet and then not Pending_Show then
         Request_Mode;
         Id := Timer_Sources.Timeout_Add (100, On_Pending'Access, 0);
         Status.Set_Text ("typing MODE" & Mode'Image &
                          " and the palette in the emulator ...");
      end if;
   end Send_To_Emulator;

   procedure Grab_From_Emulator is
      M : constant Integer := Machine.Screen_Mode;
   begin
      if not Valid_Mode (M) or else Machine.Teletext_Mode then
         Status.Set_Text ("the emulator is not in a graphics mode " &
                          "(0, 1, 2, 4 or 5)");
         return;
      end if;
      Set_Mode (M);
      declare
         D : Byte_Array (0 .. Screen_Size - 1);
         Base : constant Natural := Screen_Base;
         Start : constant Natural := Machine.Screen_Start;
         Off : constant Natural :=
           (if Start >= Base then Start - Base else 0);
      begin
         for I in D'Range loop
            D (I) := Machine.Screen_Peek (Word (Base + (Off + I) mod Screen_Size));
         end loop;
         Set_Screen_Bytes (D);
      end;
      for L in 0 .. Colours - 1 loop
         Set_Physical (L, Machine.ULA_Palette (ULA_Index (L)) and 15);
      end loop;
      Updating := True;
      Mode_Buttons (Mode).Set_Active (True);
      Updating := False;
      Status.Set_Text ("grabbed the MODE" & M'Image & " screen");
   end Grab_From_Emulator;

   ---------------------------------------------------------------------
   --  Drawing
   ---------------------------------------------------------------------

   procedure Update_Image is
      Stride : constant Natural :=
        Natural (Cairo.Image_Surface.Get_Stride (Surf)) / 4;
      Addr : constant System.Address :=
        Cairo.Image_Surface.Get_Data_Generic (Surf);
      type Pixels is array (0 .. 511, 0 .. Stride - 1) of Pixel;
      Dst : Pixels;
      for Dst'Address use Addr;
      pragma Import (Ada, Dst);
      PW : constant Natural := 640 / Width;
      Cols_RGB : array (Logical) of Pixel;
   begin
      for L in Logical loop
         Cols_RGB (L) := RGB (L);
      end loop;
      Cairo.Surface.Flush (Surf);
      for Y in 0 .. 255 loop
         for X in 0 .. Width - 1 loop
            declare
               P : constant Pixel := Cols_RGB (Get (X, Y));
            begin
               for I in 0 .. PW - 1 loop
                  Dst (2 * Y, X * PW + I) := P;
                  Dst (2 * Y + 1, X * PW + I) := P;
               end loop;
            end;
         end loop;
      end loop;
      Cairo.Surface.Mark_Dirty (Surf);
   end Update_Image;

   procedure Redraw is
   begin
      Update_Image;
      Canvas.Set_Size_Request (Gint (640 * Zoom), Gint (512 * Zoom));
      Canvas.Queue_Draw;
      Pal_Area.Queue_Draw;
   end Redraw;

   procedure Changed is
   begin
      Redraw;
      if Live.Get_Active then
         Send_To_Emulator (Quiet => True);
      end if;
   end Changed;

   function To_Screen_X (X : Integer) return Gdouble is
     (Gdouble (X * (640 / Width) * Zoom));
   function To_Screen_Y (Y : Integer) return Gdouble is
     (Gdouble (Y * 2 * Zoom));

   function On_Canvas_Draw (Self : access Gtk_Widget_Record'Class;
                            Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Save (Cr);
      Cairo.Scale (Cr, Gdouble (Zoom), Gdouble (Zoom));
      Set_Source_Surface (Cr, Surf, 0.0, 0.0);
      Cairo.Pattern.Set_Filter (Get_Source (Cr),
                                Cairo.Pattern.Cairo_Filter_Nearest);
      Paint (Cr);
      Restore (Cr);
      if Dragging and then Current_Tool in Line_Tool .. Disc_Tool then
         --  rubber band
         Set_RGB (Cr, RGB (Drag_Colour) xor 16#808080#);
         Set_Line_Width (Cr, 1.0);
         declare
            PW : constant Gdouble := Gdouble ((640 / Width) * Zoom);
            X0 : constant Gdouble := To_Screen_X (Start_X) + PW / 2.0;
            Y0 : constant Gdouble := To_Screen_Y (Start_Y) + Gdouble (Zoom);
            X1 : constant Gdouble := To_Screen_X (Last_X) + PW / 2.0;
            Y1 : constant Gdouble := To_Screen_Y (Last_Y) + Gdouble (Zoom);
         begin
            case Current_Tool is
               when Line_Tool =>
                  Move_To (Cr, X0, Y0);
                  Line_To (Cr, X1, Y1);
               when Rect_Tool | Box_Tool =>
                  Rectangle (Cr, Gdouble'Min (X0, X1), Gdouble'Min (Y0, Y1),
                             abs (X1 - X0), abs (Y1 - Y0));
               when others =>
                  Save (Cr);
                  Translate (Cr, (X0 + X1) / 2.0, (Y0 + Y1) / 2.0);
                  Cairo.Scale (Cr, Gdouble'Max (1.0, abs (X1 - X0) / 2.0),
                               Gdouble'Max (1.0, abs (Y1 - Y0) / 2.0));
                  Arc (Cr, 0.0, 0.0, 1.0, 0.0, 6.2832);
                  Restore (Cr);
            end case;
            Stroke (Cr);
         end;
      end if;
      return True;
   end On_Canvas_Draw;

   --  Palette panel: logical colours on the first row, the 16 physical
   --  colours (8-15 flashing) below
   Swatch : constant := 34;

   function On_Pal_Draw (Self : access Gtk_Widget_Record'Class;
                         Cr : Cairo_Context) return Boolean is
      pragma Unreferenced (Self);
   begin
      Set_Source_Rgb (Cr, 0.85, 0.85, 0.85);
      Paint (Cr);
      for L in 0 .. Colours - 1 loop
         declare
            X : constant Gdouble := Gdouble ((L mod 8) * Swatch + 2);
            Y : constant Gdouble := Gdouble ((L / 8) * Swatch + 18);
         begin
            Set_RGB (Cr, RGB (L));
            Rectangle (Cr, X, Y, Gdouble (Swatch - 4), Gdouble (Swatch - 4));
            Cairo.Fill (Cr);
            if (Physical (L) and 8) /= 0 then      --  flashing: stripes
               Set_Colour (Cr, (Physical (L) and 7) xor 7);
               Rectangle (Cr, X, Y + Gdouble (Swatch - 12), Gdouble (Swatch - 4),
                          6.0);
               Cairo.Fill (Cr);
            end if;
            if L = Ink or else L = Paper then
               Set_Source_Rgb (Cr, (if L = Ink then 1.0 else 0.0), 0.4, 0.0);
               Set_Line_Width (Cr, 3.0);
               Rectangle (Cr, X - 1.0, Y - 1.0, Gdouble (Swatch - 2),
                          Gdouble (Swatch - 2));
               Stroke (Cr);
            end if;
            Set_Source_Rgb (Cr, 0.5, 0.5, 0.5);
            Move_To (Cr, X + 2.0, Y + 12.0);
            Show_Text (Cr, Trim (L'Image, Ada.Strings.Left));
         end;
      end loop;
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Move_To (Cr, 2.0, 12.0);
      Show_Text (Cr, "logical colours (left: ink, right: paper)");
      Move_To (Cr, 2.0, Gdouble (2 * Swatch + 34));
      Show_Text (Cr, "physical colours: click to set the ink colour (VDU 19)");
      for P in 0 .. 15 loop
         declare
            X : constant Gdouble := Gdouble ((P mod 8) * Swatch + 2);
            Y : constant Gdouble := Gdouble ((P / 8) * Swatch + 2 * Swatch + 40);
         begin
            Set_Colour (Cr, Byte (P) and 7);
            Rectangle (Cr, X, Y, Gdouble (Swatch - 4), Gdouble (Swatch - 4));
            Cairo.Fill (Cr);
            if P >= 8 then
               Set_Colour (Cr, (Byte (P) and 7) xor 7);
               Rectangle (Cr, X, Y + Gdouble (Swatch - 12),
                          Gdouble (Swatch - 4), 6.0);
               Cairo.Fill (Cr);
            end if;
         end;
      end loop;
      return True;
   end On_Pal_Draw;

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
      Undo_Stack (Undo_Count) := Snapshot;
   end Push_Undo;

   procedure Undo is
   begin
      if Undo_Count > 0 then
         Restore (Undo_Stack (Undo_Count));
         Undo_Count := Undo_Count - 1;
         Updating := True;
         Mode_Buttons (Mode).Set_Active (True);
         Updating := False;
         Changed;
      end if;
   end Undo;

   procedure Pixel_At (EX, EY : Gdouble; X, Y : out Integer) is
   begin
      X := Integer (Gdouble'Floor (EX / Gdouble ((640 / Width) * Zoom)));
      Y := Integer (Gdouble'Floor (EY / Gdouble (2 * Zoom)));
   end Pixel_At;

   procedure Show_Position (X, Y : Integer) is
   begin
      if X in 0 .. Width - 1 and then Y in 0 .. 255 then
         Status.Set_Text
           ("x" & X'Image & " y" & Y'Image & "  (graphics" &
            Natural (X * 1280 / Width)'Image & "," &
            Natural (1023 - Y * 4)'Image & ")  colour" &
            Natural (Get (X, Y))'Image & "  |  MODE" & Mode'Image & "," &
            Natural (Colours)'Image & " colours  |  " &
            Tool_Names (Current_Tool).all);
      end if;
   end Show_Position;

   function On_Press (Self : access Gtk_Widget_Record'Class;
                      Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      X, Y : Integer;
   begin
      Pixel_At (Event.X, Event.Y, X, Y);
      if X not in 0 .. Width - 1 or else Y not in 0 .. 255 then
         return True;
      end if;
      Drag_Colour := (if Event.Button = 3 then Paper else Ink);
      case Current_Tool is
         when Pick_Tool =>
            if Event.Button = 3 then
               Paper := Get (X, Y);
            else
               Ink := Get (X, Y);
            end if;
            Pal_Area.Queue_Draw;
         when Fill_Tool =>
            Push_Undo;
            Flood_Fill (X, Y, Drag_Colour);
            Changed;
         when Pencil =>
            Push_Undo;
            Put (X, Y, Drag_Colour);
            Dragging := True;
            Last_X := X;
            Last_Y := Y;
            Changed;
         when others =>
            Start_X := X;
            Start_Y := Y;
            Last_X := X;
            Last_Y := Y;
            Dragging := True;
      end case;
      return True;
   end On_Press;

   function On_Motion (Self : access Gtk_Widget_Record'Class;
                       Event : Gdk_Event_Motion) return Boolean is
      pragma Unreferenced (Self);
      X, Y : Integer;
   begin
      Pixel_At (Event.X, Event.Y, X, Y);
      Show_Position (X, Y);
      if Dragging then
         X := Integer'Max (0, Integer'Min (Width - 1, X));
         Y := Integer'Max (0, Integer'Min (255, Y));
         if Current_Tool = Pencil then
            Bitmap_Data.Line (Last_X, Last_Y, X, Y, Drag_Colour);
            Last_X := X;
            Last_Y := Y;
            Changed;
         else
            Last_X := X;
            Last_Y := Y;
            Canvas.Queue_Draw;
         end if;
      end if;
      return True;
   end On_Motion;

   function On_Release (Self : access Gtk_Widget_Record'Class;
                        Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self, Event);
   begin
      if Dragging and then Current_Tool /= Pencil then
         Push_Undo;
         case Current_Tool is
            when Line_Tool =>
               Bitmap_Data.Line (Start_X, Start_Y, Last_X, Last_Y,
                                 Drag_Colour);
            when Rect_Tool =>
               Rect (Start_X, Start_Y, Last_X, Last_Y, Drag_Colour, False);
            when Box_Tool =>
               Rect (Start_X, Start_Y, Last_X, Last_Y, Drag_Colour, True);
            when Oval_Tool =>
               Ellipse (Start_X, Start_Y, Last_X, Last_Y, Drag_Colour, False);
            when Disc_Tool =>
               Ellipse (Start_X, Start_Y, Last_X, Last_Y, Drag_Colour, True);
            when others => null;
         end case;
         Dragging := False;
         Changed;
      end if;
      Dragging := False;
      return True;
   end On_Release;

   function On_Pal_Press (Self : access Gtk_Widget_Record'Class;
                          Event : Gdk_Event_Button) return Boolean is
      pragma Unreferenced (Self);
      CX : constant Integer := Integer (Gdouble'Floor ((Event.X - 2.0) /
                                                       Gdouble (Swatch)));
   begin
      if CX not in 0 .. 7 then
         return True;
      end if;
      if Event.Y >= 18.0 and then Event.Y < Gdouble (18 + 2 * Swatch) then
         declare
            L : constant Integer :=
              CX + 8 * Integer (Gdouble'Floor ((Event.Y - 18.0) /
                                               Gdouble (Swatch)));
         begin
            if L in 0 .. Colours - 1 then
               if Event.Button = 3 then
                  Paper := L;
               else
                  Ink := L;
               end if;
            end if;
         end;
      elsif Event.Y >= Gdouble (2 * Swatch + 40) then
         declare
            P : constant Integer :=
              CX + 8 * Integer (Gdouble'Floor
                                  ((Event.Y - Gdouble (2 * Swatch + 40)) /
                                   Gdouble (Swatch)));
         begin
            if P in 0 .. 15 then
               Push_Undo;
               Set_Physical (Ink, Byte (P));
               Changed;
            end if;
         end;
      end if;
      Pal_Area.Queue_Draw;
      return True;
   end On_Pal_Press;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   procedure Sync_Mode_Buttons is
   begin
      Updating := True;
      Mode_Buttons (Mode).Set_Active (True);
      Updating := False;
      Ink := Natural'Min (Ink, Colours - 1);
      Paper := Natural'Min (Paper, Colours - 1);
   end Sync_Mode_Buttons;

   procedure Load_File (Path : String) is
      Ok : Boolean;
   begin
      if Is_Image_File (Path) then
         Push_Undo;
         Import_Image (Path, Dither_Check.Get_Active, Ok);
         Status.Set_Text ((if Ok then "imported " else "cannot read ") & Path);
      else
         Load (Path, Ok);
         if Ok then
            File := To_Unbounded_String (Path);
            Win.Set_Title ("Bitmap editor - " &
                           Ada.Directories.Simple_Name (Path));
            Undo_Count := 0;
         end if;
         Status.Set_Text ((if Ok then "loaded " else "cannot read ") & Path);
      end if;
      Sync_Mode_Buttons;
      Redraw;
   end Load_File;

   procedure Save_File (Ask : Boolean) is
      Ok : Boolean;
   begin
      if Ask or else File = Null_Unbounded_String then
         declare
            P : constant String :=
              Choose_File (Win, "Save picture", True,
                           "AdaBeeb pictures (*.bbm)", "*.bbm",
                           "picture.bbm");
         begin
            if P = "" then
               return;
            end if;
            File := To_Unbounded_String
              (if Is_Bitmap_File (P) then P else P & ".bbm");
         end;
      end if;
      Save (To_String (File), Ok);
      Status.Set_Text ((if Ok then "saved " else "cannot write ") &
                       To_String (File));
      Win.Set_Title ("Bitmap editor - " &
                     Ada.Directories.Simple_Name (To_String (File)));
   end Save_File;

   function Base_Of (Ext : String) return String is
     (if File = Null_Unbounded_String then "picture" & Ext
      else Ada.Directories.Base_Name (To_String (File)) & Ext);

   procedure Export_Dump is
      P : constant String :=
        Choose_File (Win, "Export screen dump (*LOAD-able) and loader",
                     True, "Screen dumps", "*", Base_Of (""));
      Ok : Boolean;
   begin
      if P = "" then
         return;
      end if;
      Write_Bytes (P, Screen_Bytes, Ok);
      if Ok then
         Write_Inf (P, Screen_Base, Screen_Base);
         declare
            Name : constant String :=
              Ada.Characters.Handling.To_Upper
                (Ada.Directories.Base_Name (P));
            Short : constant String :=
              Name (Name'First .. Name'First + Natural'Min (7, Name'Length)
                    - 1);
         begin
            Write_Text (P & ".bas", Loader_BASIC (Short), Ok);
         end;
      end if;
      Status.Set_Text
        ((if Ok then "wrote " & P & " (+ .inf), and " & P &
            ".bas that shows it; put both on a disc (Build -> disc)"
          else "cannot write " & P));
   end Export_Dump;

   procedure Export_Asm is
      P : constant String :=
        Choose_File (Win, "Export as ACME source (+ binary)", True,
                     "Assembly sources (*.asm)", "*.asm", Base_Of (".asm"));
      Ok : Boolean;
   begin
      if P = "" then
         return;
      end if;
      declare
         Bin : constant String :=
           P (P'First .. P'Last - (if Index (P, ".asm") > 0 then 4 else 0))
           & ".scr";
      begin
         Write_Bytes (Bin, Screen_Bytes, Ok);
         if Ok then
            Write_Text
              (P, "; MODE" & Mode'Image & " picture - AdaBeeb Forge" &
                 ASCII.LF & "; the screen memory, to be copied to &" &
                 Hex4 (Screen_Base) & ASCII.LF &
                 Ada.Directories.Base_Name (P) & ASCII.LF &
                 "        !binary """ & Ada.Directories.Simple_Name (Bin) &
                 """" & ASCII.LF, Ok);
         end if;
         Status.Set_Text ((if Ok then "wrote " & P & " and " & Bin
                           else "cannot write " & P));
      end;
   end Export_Asm;

   ---------------------------------------------------------------------
   --  Actions
   ---------------------------------------------------------------------

   type Action is
     (A_New, A_Open, A_Save, A_Save_As, A_Import, A_Export_Dump,
      A_Export_Asm, A_Undo, A_Clear, A_Show, A_Grab);

   procedure Do_Action (A : Action) is
   begin
      case A is
         when A_New =>
            Push_Undo;
            Set_Mode (Mode);
            File := Null_Unbounded_String;
            Win.Set_Title ("Bitmap editor");
            Changed;
         when A_Open =>
            declare
               P : constant String :=
                 Choose_File (Win, "Open picture", False,
                              "Pictures (*.bbm)", "*.bbm");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Save => Save_File (False);
         when A_Save_As => Save_File (True);
         when A_Import =>
            declare
               P : constant String :=
                 Choose_File (Win, "Import a PNG image", False,
                              "PNG images", "*.png");
            begin
               if P /= "" then
                  Load_File (P);
               end if;
            end;
         when A_Export_Dump => Export_Dump;
         when A_Export_Asm => Export_Asm;
         when A_Undo => Undo;
         when A_Clear =>
            Push_Undo;
            Clear (Paper);
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

   procedure On_Mode (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Updating or else not Self.Get_Active then
         return;
      end if;
      for M in Mode_Number loop
         if Mode_Buttons (M) /= null
           and then Gtk_Radio_Button (Self) = Mode_Buttons (M)
           and then M /= Mode
         then
            Push_Undo;
            Set_Mode (M, Keep_Picture => True);
            Ink := Natural'Min (Ink, Colours - 1);
            Paper := Natural'Min (Paper, Colours - 1);
            Changed;
         end if;
      end loop;
   end On_Mode;

   procedure On_Tool_Kind (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      if Self.Get_Active then
         for T in Tool_Kind loop
            if Gtk_Radio_Button (Self) = Tool_Buttons (T) then
               Current_Tool := T;
            end if;
         end loop;
      end if;
   end On_Tool_Kind;

   procedure On_Zoom (Self : access Gtk_Toggle_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Redraw;
   end On_Zoom;

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
         Settings.Set ("bbm_file", To_String (File));
      end if;
      Win.Hide;
      return True;
   end On_Delete;

   procedure Build is
      VBox, HBox, Side : Gtk_Box;
      Tools : Gtk_Toolbar;
      Frame : Gtk_Frame;
      Scroll : Gtk_Scrolled_Window;
      Box : Gtk_Box;

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

      Mode_Group : Widget_SList.GSlist := Widget_SList.Null_List;
      Tool_Group : Widget_SList.GSlist := Widget_SList.Null_List;
   begin
      Gtk_New (Win);
      Win.Set_Title ("Bitmap editor");
      Win.Set_Default_Size (1060, 680);
      Win.On_Delete_Event (On_Delete'Access);
      Win.On_Key_Press_Event (On_Key'Access);
      Gtk_New_Vbox (VBox);
      Win.Add (VBox);

      Gtk_New (Tools);
      Tools.Set_Style (Toolbar_Both_Horiz);
      Tool ("New", A_New, "Blank picture in this mode", "document-new");
      Tool ("Open", A_Open, "Open a .bbm picture or a screen dump",
            "document-open");
      Tool ("Save", A_Save, "Save (Ctrl+S)", "document-save");
      Tool ("Save as", A_Save_As, "Save under a new name");
      Tool ("Import PNG", A_Import,
            "Convert an image to this mode and palette");
      Tool ("Export dump", A_Export_Dump,
            "Write the screen memory (*LOAD-able, .inf) and a BASIC loader");
      Tool ("Export .asm", A_Export_Asm,
            "Write the screen memory and an ACME source including it");
      Tool ("Undo", A_Undo, "Undo (Ctrl+Z)", "edit-undo");
      Tool ("Clear", A_Clear, "Fill with the paper colour");
      Sep;
      Tool ("Show in emulator", A_Show,
            "Put the picture on the emulator's screen (switching MODE)");
      Tool ("Grab from emulator", A_Grab,
            "Take the running program's screen and palette");
      VBox.Pack_Start (Tools, Expand => False, Fill => False);

      Gtk_New_Hbox (HBox, Spacing => 6);
      VBox.Pack_Start (HBox, Expand => True, Fill => True);

      Gtk_New (Canvas);
      Canvas.Set_Size_Request (640, 512);
      Canvas.Add_Events (Button_Press_Mask or Button_Release_Mask
                         or Button_Motion_Mask or Pointer_Motion_Mask);
      Canvas.On_Draw (On_Canvas_Draw'Access);
      Canvas.On_Button_Press_Event (On_Press'Access);
      Canvas.On_Button_Release_Event (On_Release'Access);
      Canvas.On_Motion_Notify_Event (On_Motion'Access);
      Gtk_New (Scroll);
      Scroll.Add (Canvas);
      HBox.Pack_Start (Scroll, Expand => True, Fill => True, Padding => 4);

      Gtk_New_Vbox (Side, Spacing => 4);
      HBox.Pack_Start (Side, Expand => False, Fill => False);

      Gtk_New (Frame, "Mode");
      Gtk_New_Hbox (Box, Spacing => 2);
      for M in Mode_Number loop
         if Valid_Mode (M) then
            Gtk_New (Mode_Buttons (M), Mode_Group,
                     Trim (M'Image, Ada.Strings.Left));
            Mode_Group := Mode_Buttons (M).Get_Group;
            Mode_Buttons (M).On_Toggled (On_Mode'Access);
            Box.Pack_Start (Mode_Buttons (M), Expand => False, Fill => False);
         end if;
      end loop;
      Frame.Add (Box);
      Side.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New (Frame, "Tool");
      Gtk_New_Vbox (Box, Spacing => 0);
      for T in Tool_Kind loop
         Gtk_New (Tool_Buttons (T), Tool_Group, Tool_Names (T).all);
         Tool_Group := Tool_Buttons (T).Get_Group;
         Tool_Buttons (T).On_Toggled (On_Tool_Kind'Access);
         Box.Pack_Start (Tool_Buttons (T), Expand => False, Fill => False);
      end loop;
      Frame.Add (Box);
      Side.Pack_Start (Frame, Expand => False, Fill => False);

      Gtk_New (Pal_Area);
      Pal_Area.Set_Size_Request (8 * Swatch + 4, 4 * Swatch + 44);
      Pal_Area.Add_Events (Button_Press_Mask);
      Pal_Area.On_Draw (On_Pal_Draw'Access);
      Pal_Area.On_Button_Press_Event (On_Pal_Press'Access);
      Side.Pack_Start (Pal_Area, Expand => False, Fill => False);

      Gtk_New (Dither_Check, "Dither when importing");
      Dither_Check.Set_Active (True);
      Side.Pack_Start (Dither_Check, Expand => False, Fill => False);
      Gtk_New (Zoom_Check, "Zoom x2");
      Zoom_Check.On_Toggled (On_Zoom'Access);
      Side.Pack_Start (Zoom_Check, Expand => False, Fill => False);
      Gtk_New (Live, "Live in emulator");
      Live.On_Toggled (On_Live'Access);
      Side.Pack_Start (Live, Expand => False, Fill => False);

      Gtk_New (Status, "");
      Status.Set_Halign (Align_Start);
      Status.Set_Selectable (True);
      VBox.Pack_Start (Status, Expand => False, Fill => False, Padding => 4);

      Surf := Cairo.Image_Surface.Create
        (Cairo.Image_Surface.Cairo_Format_RGB24, 640, 512);
      Updating := True;
      Mode_Buttons (Mode).Set_Active (True);
      Updating := False;
   end Build;

   procedure Open (Parent : Gtk.Window.Gtk_Window; File : String := "") is
      pragma Unreferenced (Parent);
   begin
      if Win = null then
         Build;
         Win.Show_All;
         declare
            Last : constant String := Settings.Get ("bbm_file", "");
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
            Bitmap_Editor.File := To_Unbounded_String (File);
         end if;
      end if;
      Redraw;
      Win.Show_All;
      Win.Present;
   end Open;

end Bitmap_Editor;
