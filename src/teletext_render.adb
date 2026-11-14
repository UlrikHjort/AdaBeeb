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
with Interfaces; use Interfaces;
with Video;
with Teletext_Font; use Teletext_Font;

package body Teletext_Render is

   type Row_State is record
      Fg, Bg : Byte := 7;
      Graphics, Separated, Hold, DH, Flash, Conceal : Boolean := False;
      Held : Natural := 32;
      Held_Sep : Boolean := False;
   end record;

   procedure Start_Row (St : out Row_State) is
   begin
      St := (Fg => 7, Bg => 0, Held => 32, others => False);
   end Start_Row;

   --  The character shown at a cell and the attributes for drawing it;
   --  updates St with the set-after effects.
   procedure Step (St : in out Row_State; Data : Byte;
                   Glyph : out Natural; Bk : out Bank;
                   Fg, Bg : out Byte; DH, Flash, Conceal : out Boolean;
                   Is_Control, Is_Graphics : out Boolean) is
      C : constant Natural := Natural (Data and 16#7F#);
   begin
      Glyph := 32;
      Bk := Alpha;
      Is_Control := C < 32;
      if C < 32 then
         case C is
            when 16#09# => St.Flash := False;
            when 16#0C# =>
               if St.DH then
                  St.Held := 32;
               end if;
               St.DH := False;
            when 16#18# => St.Conceal := True;
            when 16#19# => St.Separated := False;
            when 16#1A# => St.Separated := True;
            when 16#1C# => St.Bg := 0;
            when 16#1D# => St.Bg := St.Fg;
            when 16#1E# => St.Hold := True;
            when others => null;
         end case;
         if St.Hold and then St.Graphics then
            Glyph := St.Held;
            Bk := (if St.Held_Sep then Separated else Contiguous);
         end if;
      else
         Glyph := C;
         if St.Graphics and then (C / 32) mod 2 = 1 then
            Bk := (if St.Separated then Separated else Contiguous);
            St.Held := C;
            St.Held_Sep := St.Separated;
         end if;
      end if;
      Fg := St.Fg;
      Bg := St.Bg;
      DH := St.DH;
      Flash := St.Flash;
      Conceal := St.Conceal;
      Is_Graphics := St.Graphics;
      if C < 32 then
         case C is
            when 16#01# .. 16#07# =>
               St.Fg := Byte (C);
               if St.Graphics then
                  St.Held := 32;
               end if;
               St.Graphics := False;
               St.Conceal := False;
            when 16#08# => St.Flash := True;
            when 16#0D# =>
               if not St.DH then
                  St.Held := 32;
               end if;
               St.DH := True;
            when 16#11# .. 16#17# =>
               St.Fg := Byte (C - 16);
               if not St.Graphics or else not St.Hold then
                  St.Held := 32;     --  kept only while hold is on
               end if;
               St.Graphics := True;
               St.Conceal := False;
            when 16#1F# => St.Hold := False;
            when others => null;
         end case;
      end if;
   end Step;

   function Blend (Bg, Fg : Pixel; L : Level) return Pixel is
      R : U32 := 0;
      Sh : Natural := 0;
   begin
      if L = 0 then
         return Bg;
      elsif L = 15 then
         return Fg;
      end if;
      for Ch in 0 .. 2 loop
         declare
            B : constant U32 := Shift_Right (Bg, Sh) and 255;
            F : constant U32 := Shift_Right (Fg, Sh) and 255;
         begin
            R := R or Shift_Left ((B * U32 (15 - L) + F * U32 (L)) / 15, Sh);
         end;
         Sh := Sh + 8;
      end loop;
      return R;
   end Blend;

   procedure Render (S : Screen; Img : out Image;
                     Flash_On : Boolean := True;
                     Reveal : Boolean := False) is
      Bottom : Boolean := False;      --  this row shows lower halves
      Row_DH : Boolean;
   begin
      for R in 0 .. Rows - 1 loop
         declare
            St : Row_State;
         begin
            Start_Row (St);
            Row_DH := False;
            for C in 0 .. Cols - 1 loop
               declare
                  Glyph : Natural;
                  Bk : Bank;
                  Fg, Bg : Byte;
                  DH, Flash, Conceal, Ctl, Gfx : Boolean;
                  FP, BP : Pixel;
                  Visible : Boolean;
               begin
                  Step (St, S (R, C), Glyph, Bk, Fg, Bg, DH, Flash, Conceal,
                        Ctl, Gfx);
                  if DH then
                     Row_DH := True;
                  end if;
                  FP := Video.Colours (Fg);
                  BP := Video.Colours (Bg);
                  Visible := Glyph /= 32
                    and then (not Flash or else Flash_On)
                    and then (not Conceal or else Reveal)
                    and then (not Bottom or else DH);
                  for Y in 0 .. Char_H - 1 loop
                     declare
                        F_Row : constant Natural :=
                          (if DH then (if Bottom then 10 + Y / 2 else Y / 2)
                           else Y);
                     begin
                        for X in 0 .. Char_W - 1 loop
                           Img (R * Char_H + Y, C * Char_W + X) :=
                             (if Visible
                              then Blend (BP, FP,
                                          Pixel_Level (Bk, Glyph, F_Row, X))
                              else BP);
                        end loop;
                     end;
                  end loop;
               end;
            end loop;
            Bottom := (if Bottom then False else Row_DH);
         end;
      end loop;
   end Render;

   function Info (S : Screen; Row, Col : Natural) return Cell_Info is
      St : Row_State;
      Glyph : Natural;
      Bk : Bank;
      Fg, Bg : Byte;
      DH, Flash, Conceal, Ctl, Gfx : Boolean;
      R : Cell_Info;
   begin
      Start_Row (St);
      for C in 0 .. Col loop
         Step (St, S (Row, C), Glyph, Bk, Fg, Bg, DH, Flash, Conceal, Ctl,
               Gfx);
      end loop;
      R.Graphics := Gfx and then not Ctl;
      R.Control := Ctl;
      R.Fg := Fg;
      R.Bg := Bg;
      R.Double := DH;
      return R;
   end Info;

   function Control_Name (Code : Byte) return String is
      Colours : constant array (Byte range 1 .. 7) of String (1 .. 3) :=
        ("red", "grn", "yel", "blu", "mag", "cyn", "wht");
      C : constant Byte := Code and 16#1F#;
   begin
      case C is
         when 1 .. 7 => return Colours (C);
         when 16#11# .. 16#17# => return "g" & Colours (C - 16);
         when 16#08# => return "fsh";
         when 16#09# => return "std";
         when 16#0C# => return "nrm";
         when 16#0D# => return "dbl";
         when 16#18# => return "cnc";
         when 16#19# => return "con";
         when 16#1A# => return "sep";
         when 16#1C# => return "bbg";
         when 16#1D# => return "nbg";
         when 16#1E# => return "hld";
         when 16#1F# => return "rel";
         when others => return "";
      end case;
   end Control_Name;

end Teletext_Render;
