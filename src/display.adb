-- ***************************************************************************
--                             AdaBeeb - Display
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
with Teletext_Font;

package body Display is
   pragma Suppress (All_Checks);

   use Teletext_Font;

   --  Position of the visible framebuffer area relative to the syncs
   H_Off   : constant := 176;     --  framebuffer pixels after HSYNC start
   V_Off   : constant := 16;      --  scanlines after VSYNC start
   TT_Shift : constant := 48;     --  teletext pipeline delay (3 chars)

   --  CRTC
   Regs : array (0 .. 17) of Byte := (others => 0);
   Addr_Reg : Natural := 0;

   HC        : Natural := 0;       --  horizontal character counter
   Line      : Natural := 0;       --  scanline within the character row
   Row       : Natural := 0;       --  character row
   In_Adjust : Boolean := False;
   Adj_Count : Natural := 0;
   MA        : Natural := 0;
   MA_Row    : Natural := 0;
   VDisp     : Boolean := True;
   In_VSync  : Boolean := False;
   VSync_Left : Natural := 0;
   Fields    : Natural := 0;

   --  Beam position on the "TV"
   Beam_X    : Integer := 0;
   Beam_Line : Integer := 0;

   Phase     : Natural := 0;       --  1 MHz character clock divider

   --  Video ULA
   Ctrl     : Byte := 0;
   Pal      : array (0 .. 15) of Byte := (others => 0);
   Col_Of   : array (0 .. 15) of Pixel := (others => 0);

   Cursor_Mask_E, Cursor_Mask_O : Unsigned_8 := 0;

   --  SAA5050 state for the current scanline
   TT_Fg, TT_Bg : Byte := 7;
   TT_Graphics, TT_Separated, TT_Hold, TT_DH, TT_Flash,
   TT_Conceal : Boolean := False;
   TT_Held : Natural := 32;
   TT_Held_Sep : Boolean := False;
   TT_Row_DH  : Boolean := False;    --  this row has double height
   TT_Bottom  : Boolean := False;    --  this row shows lower halves

   Screen_Len : constant array (0 .. 3) of Natural :=
     (16#4000#, 16#5000#, 16#2000#, 16#2800#);

   procedure Update_Colours is
      C : Byte;
   begin
      for I in 0 .. 15 loop
         C := Pal (I);
         if (C and 8) /= 0 and then (Ctrl and 1) /= 0 then
            C := C xor 7;
         end if;
         Col_Of (I) := Video.Colours (C and 7);
      end loop;
   end Update_Colours;

   procedure Reset is
   begin
      Regs := (others => 0);
      Addr_Reg := 0;
      HC := 0;
      Line := 0;
      Row := 0;
      In_Adjust := False;
      Adj_Count := 0;
      MA := 0;
      MA_Row := 0;
      VDisp := True;
      In_VSync := False;
      VSync_Left := 0;
      Beam_X := 0;
      Beam_Line := 0;
      Phase := 0;
      Ctrl := 0;
      Pal := (others => 0);
      Update_Colours;
      Cursor_Mask_E := 0;
      Cursor_Mask_O := 0;
      Frame_Done := False;
   end Reset;

   function Interlace_Video return Boolean is ((Regs (8) and 3) = 3);

   function Lines_Per_Row return Natural is
     (if Interlace_Video then Natural (Regs (9) and 16#1F#) / 2 + 1
      else Natural (Regs (9) and 16#1F#) + 1);

   procedure Start_VSync is
   begin
      In_VSync := True;
      VSync_Left := Natural (Shift_Right (Regs (3), 4));
      if VSync_Left = 0 then
         VSync_Left := 16;
      end if;
      VSync_Changed (True);
      Beam_Line := 0;
      Frame_Done := True;
      Fields := Fields + 1;
   end Start_VSync;

   procedure New_Frame is
   begin
      Row := 0;
      Line := 0;
      In_Adjust := False;
      MA_Row := Natural (Regs (12) and 16#3F#) * 256 + Natural (Regs (13));
      VDisp := Regs (6) /= 0;
      TT_Bottom := False;
      TT_Row_DH := False;
   end New_Frame;

   procedure End_Of_Scanline is
      LPR : constant Natural := Lines_Per_Row;
      New_Row : Boolean := False;
   begin
      if In_VSync then
         VSync_Left := VSync_Left - 1;
         if VSync_Left = 0 then
            In_VSync := False;
            VSync_Changed (False);
         end if;
      end if;

      if In_Adjust then
         Adj_Count := Adj_Count + 1;
         if Adj_Count >= Natural (Regs (5) and 16#1F#) then
            New_Frame;
            New_Row := True;
         end if;
      elsif Line + 1 >= LPR then
         Line := 0;
         MA_Row := (MA_Row + Natural (Regs (1))) mod 16#4000#;
         TT_Bottom := (if TT_Bottom then False else TT_Row_DH);
         TT_Row_DH := False;
         if Row >= Natural (Regs (4) and 16#7F#) then
            if (Regs (5) and 16#1F#) /= 0 then
               In_Adjust := True;
               Adj_Count := 0;
               Row := Row + 1;
            else
               New_Frame;
            end if;
         else
            Row := (Row + 1) mod 128;
         end if;
         New_Row := True;
      else
         Line := Line + 1;
      end if;

      if New_Row and then not In_Adjust then
         if Row = Natural (Regs (6) and 16#7F#) then
            VDisp := False;
         end if;
         if Row = Natural (Regs (7) and 16#7F#) and then not In_VSync then
            Start_VSync;
         end if;
      end if;
      MA := MA_Row;
   end End_Of_Scanline;

   function Cursor_On_Raster (RA : Natural) return Boolean is
      Start_R : constant Natural := Natural (Regs (10) and 16#1F#);
      End_R   : constant Natural := Natural (Regs (11) and 16#1F#);
   begin
      if Start_R <= End_R then
         return RA >= Start_R and then RA <= End_R;
      else
         return RA >= Start_R or else RA <= End_R;   --  wraps (split)
      end if;
   end Cursor_On_Raster;

   function Cursor_Blink_On return Boolean is
   begin
      case Shift_Right (Regs (10), 5) and 3 is
         when 0 => return True;
         when 1 => return False;
         when 2 => return (Fields / 8) mod 2 = 0;
         when others => return (Fields / 16) mod 2 = 0;
      end case;
   end Cursor_Blink_On;

   procedure Put (Y, X : Integer; P : Pixel) is
   begin
      Video.FB (Y, X) := P;
   end Put;
   pragma Inline (Put);

   function Blend (Bg, Fg : Pixel; L : Level) return Pixel is
   begin
      if L = 0 then
         return Bg;
      elsif L = 15 then
         return Fg;
      end if;
      declare
         R : U32 := 0;
         Sh : Natural := 0;
      begin
         for Ch in 0 .. 2 loop
            declare
               B : constant U32 := Shift_Right (Bg, Sh) and 255;
               F : constant U32 := Shift_Right (Fg, Sh) and 255;
               V : constant U32 :=
                 (B * U32 (15 - L) + F * U32 (L)) / 15;
            begin
               R := R or Shift_Left (V, Sh);
            end;
            Sh := Sh + 8;
         end loop;
         return R;
      end;
   end Blend;

   procedure TT_Reset_Line is
   begin
      TT_Fg := 7;
      TT_Bg := 0;
      TT_Graphics := False;
      TT_Separated := False;
      TT_Hold := False;
      TT_DH := False;
      TT_Flash := False;
      TT_Conceal := False;
      TT_Held := 32;
      TT_Held_Sep := False;
   end TT_Reset_Line;

   --  One teletext character (16 pixels wide, or 8 at the fast clock)
   procedure TT_Char (Data : Byte; Y, X, W : Integer;
                      Cur_E, Cur_O : Boolean) is
      C : constant Natural := Natural (Data and 16#7F#);
      Glyph : Natural := 32;
      Bk : Bank := Alpha;
      L : constant Natural :=
        Natural'Min (9, Line * 10 / Natural'Max (1, Lines_Per_Row));
      Fg_P, Bg_P : Pixel;
      Visible : Boolean := True;
      Is_DH : Boolean;
   begin
      if C < 32 then
         --  set-at attributes
         case C is
            when 16#09# => TT_Flash := False;
            when 16#0C# =>
               if TT_DH then
                  TT_Held := 32;
               end if;
               TT_DH := False;
            when 16#18# => TT_Conceal := True;
            when 16#19# => TT_Separated := False;
            when 16#1A# => TT_Separated := True;
            when 16#1C# => TT_Bg := 0;
            when 16#1D# => TT_Bg := TT_Fg;
            when 16#1E# => TT_Hold := True;
            when others => null;
         end case;
         if TT_Hold and then TT_Graphics then
            Glyph := TT_Held;
            Bk := (if TT_Held_Sep then Separated else Contiguous);
         end if;
      else
         Glyph := C;
         if TT_Graphics and then (C / 32) mod 2 = 1 then
            Bk := (if TT_Separated then Separated else Contiguous);
            TT_Held := C;
            TT_Held_Sep := TT_Separated;
         end if;
      end if;

      Is_DH := TT_DH;
      Fg_P := Video.Colours (TT_Fg);
      Bg_P := Video.Colours (TT_Bg);
      if (TT_Flash and then (Fields / 16) mod 4 = 3) or else TT_Conceal then
         Visible := False;
      end if;
      if TT_Bottom and then not Is_DH then
         Visible := False;
      end if;

      for Half in 0 .. 1 loop
         declare
            F_Row : constant Natural :=
              (if Is_DH then (if TT_Bottom then 10 + L else L)
               else 2 * L + Half);
            Cur : constant Boolean := (if Half = 0 then Cur_E else Cur_O);
            P : Pixel;
         begin
            for I in 0 .. W - 1 loop
               if Visible and then Glyph /= 32 then
                  P := Blend (Bg_P, Fg_P,
                              Pixel_Level (Bk, Glyph, F_Row,
                                           (I * 16) / W));
               else
                  P := Bg_P;
               end if;
               if Cur then
                  P := P xor 16#FFFFFF#;
               end if;
               Put (2 * Y + Half, X + I, P);
            end loop;
         end;
      end loop;

      --  set-after attributes
      if C < 32 then
         case C is
            when 16#01# .. 16#07# =>
               TT_Fg := Byte (C);
               if TT_Graphics then
                  TT_Held := 32;
               end if;
               TT_Graphics := False;
               TT_Conceal := False;
            when 16#08# => TT_Flash := True;
            when 16#0D# =>
               if not TT_DH then
                  TT_Held := 32;
               end if;
               TT_DH := True;
               TT_Row_DH := True;
            when 16#11# .. 16#17# =>
               TT_Fg := Byte (C - 16);
               if not TT_Graphics or else not TT_Hold then
                  TT_Held := 32;     --  kept only while hold is on
               end if;
               TT_Graphics := True;
               TT_Conceal := False;
            when 16#1F# => TT_Hold := False;
            when others => null;
         end case;
      end if;
   end TT_Char;

   procedure Do_Char is
      Fast : constant Boolean := (Ctrl and 16#10#) /= 0;
      W : constant Integer := (if Fast then 8 else 16);
      Teletext : constant Boolean := (Ctrl and 2) /= 0;
      Disp_Skew : constant Byte := Shift_Right (Regs (8), 4) and 3;
      Disp : constant Boolean :=
        HC < Natural (Regs (1)) and then VDisp and then not In_Adjust
        and then Disp_Skew /= 3;
      Y : constant Integer := Beam_Line - V_Off;
      X : Integer;
      Cur_E, Cur_O : Boolean;
   begin
      --  Horizontal sync: the TV starts a new line
      if HC = Natural (Regs (2)) and then (Regs (3) and 16#0F#) /= 0 then
         Beam_X := 0;
         Beam_Line := Beam_Line + 1;
      elsif Beam_X >= 1024 + 64 then
         Beam_X := 0;                      --  free-running line timebase
         Beam_Line := Beam_Line + 1;
      end if;
      if Beam_Line >= 340 then
         Beam_Line := 0;                   --  no VSYNC: TV timebase
         Frame_Done := True;
         Fields := Fields + 1;
      end if;

      if HC = 0 then
         TT_Reset_Line;
      end if;

      --  Cursor: CRTC match, delayed by the cursor skew, then the ULA's
      --  cursor segments
      if Disp and then MA = Natural (Regs (14) and 16#3F#) * 256 +
                              Natural (Regs (15))
        and then (Regs (8) and 16#C0#) /= 16#C0#
        and then Cursor_Blink_On
      then
         declare
            RA_E : constant Natural :=
              (if Interlace_Video then 2 * Line else Line);
            RA_O : constant Natural :=
              (if Interlace_Video then 2 * Line + 1 else Line);
            Offset : constant Integer :=
              Integer (Shift_Right (Regs (8), 6) and 3) -
              Integer (Disp_Skew) - (if Teletext then 2 else 0);
            Segs : Unsigned_8 := 0;
         begin
            for S in 0 .. 3 loop
               if (S = 0 and then (Ctrl and 16#80#) /= 0)
                 or else (S = 1 and then (Ctrl and 16#40#) /= 0)
                 or else (S >= 2 and then (Ctrl and 16#20#) /= 0)
               then
                  if Offset + S >= 0 then
                     Segs := Segs or Shift_Left (1, Offset + S);
                  end if;
               end if;
            end loop;
            if Cursor_On_Raster (RA_E) then
               Cursor_Mask_E := Cursor_Mask_E or Segs;
            end if;
            if Cursor_On_Raster (RA_O) then
               Cursor_Mask_O := Cursor_Mask_O or Segs;
            end if;
         end;
      end if;
      Cur_E := (Cursor_Mask_E and 1) /= 0;
      Cur_O := (Cursor_Mask_O and 1) /= 0;

      X := Beam_X - H_Off + (if Teletext then TT_Shift else 0);
      if Y >= 0 and then Y < Video.Lines and then X >= 0
        and then X + W <= Video.Width
      then
         if Teletext then
            if Disp then
               declare
                  A : constant Natural :=
                    16#3C00# + (MA mod 16#400#) +
                    (if (MA / 16#800#) mod 2 = 1 then 16#4000# else 0);
               begin
                  TT_Char (Mem_Read (A), Y, X, W, Cur_E, Cur_O);
               end;
            else
               for I in 0 .. W - 1 loop
                  Put (2 * Y, X + I, 0);
                  Put (2 * Y + 1, X + I, 0);
               end loop;
            end if;
         else
            declare
               RA : constant Natural := Line;
               Rate : constant Natural :=
                 Natural (Shift_Right (Ctrl, 2) and 3);
               PW : constant Natural := 2 ** (3 - Rate);
               SR : Unsigned_8;
               Idx : Natural;
               P : Pixel;
               Pos : Integer := X;
               Dim : constant Boolean := Video.Scanlines;
            begin
               if Disp and then RA < 8 then
                  declare
                     A : Natural := (MA mod 16#2000#) * 8 + RA;
                  begin
                     if A >= 16#8000# then
                        A := A - Screen_Len (Screen_Size);
                     end if;
                     SR := Mem_Read (A mod 16#8000#);
                  end;
                  for N in 1 .. W / PW loop
                     Idx := Natural (Shift_Right (SR, 4) and 8) +
                       Natural (Shift_Right (SR, 3) and 4) +
                       Natural (Shift_Right (SR, 2) and 2) +
                       Natural (Shift_Right (SR, 1) and 1);
                     SR := Shift_Left (SR, 1) or 1;
                     P := Col_Of (Idx);
                     for I in 1 .. PW loop
                        Put (2 * Y, Pos,
                             (if Cur_E then P xor 16#FFFFFF# else P));
                        Put (2 * Y + 1, Pos,
                             (if Cur_O then P xor 16#FFFFFF# else P));
                        Pos := Pos + 1;
                     end loop;
                  end loop;
                  if Dim then
                     for I in X .. X + W - 1 loop
                        Video.FB (2 * Y + 1, I) :=
                          Shift_Right (Video.FB (2 * Y + 1, I), 1)
                          and 16#7F7F7F#;
                     end loop;
                  end if;
               else
                  P := 0;
                  for I in 0 .. W - 1 loop
                     Put (2 * Y, X + I, (if Cur_E then 16#FFFFFF# else 0));
                     Put (2 * Y + 1, X + I,
                          (if Cur_O then 16#FFFFFF# else 0));
                  end loop;
               end if;
            end;
         end if;
      elsif Teletext and then Disp then
         --  keep the SAA5050 attribute state right off-screen
         declare
            A : constant Natural :=
              16#3C00# + (MA mod 16#400#) +
              (if (MA / 16#800#) mod 2 = 1 then 16#4000# else 0);
            D : constant Natural := Natural (Mem_Read (A) and 16#7F#);
         begin
            case D is
               when 16#01# .. 16#07# =>
                  TT_Fg := Byte (D); TT_Graphics := False;
               when 16#11# .. 16#17# =>
                  TT_Fg := Byte (D - 16); TT_Graphics := True;
               when 16#0D# => TT_DH := True; TT_Row_DH := True;
               when 16#0C# => TT_DH := False;
               when 16#1C# => TT_Bg := 0;
               when 16#1D# => TT_Bg := TT_Fg;
               when 16#19# => TT_Separated := False;
               when 16#1A# => TT_Separated := True;
               when others => null;
            end case;
         end;
      end if;
      Cursor_Mask_E := Shift_Right (Cursor_Mask_E, 1);
      Cursor_Mask_O := Shift_Right (Cursor_Mask_O, 1);

      --  Advance
      Beam_X := Beam_X + W;
      MA := (MA + 1) mod 16#4000#;
      if HC >= Natural (Regs (0)) then
         HC := 0;
         End_Of_Scanline;
      else
         HC := HC + 1;
      end if;
   end Do_Char;

   procedure Tick (Cycles : Natural) is
   begin
      for I in 1 .. Cycles loop
         if (Ctrl and 16#10#) /= 0 then
            Do_Char;
            Phase := 0;
         else
            Phase := Phase + 1;
            if Phase >= 2 then
               Phase := 0;
               Do_Char;
            end if;
         end if;
      end loop;
   end Tick;

   Reg_Mask : constant array (0 .. 17) of Byte :=
     (16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#7F#, 16#1F#, 16#7F#, 16#7F#,
      16#F3#, 16#1F#, 16#7F#, 16#1F#, 16#3F#, 16#FF#, 16#3F#, 16#FF#,
      16#3F#, 16#FF#);

   procedure CRTC_Write (Reg : Natural; Value : Byte) is
   begin
      if Reg mod 2 = 0 then
         Addr_Reg := Natural (Value and 16#1F#);
      elsif Addr_Reg <= 15 then
         Regs (Addr_Reg) := Value and Reg_Mask (Addr_Reg);
      end if;
   end CRTC_Write;

   function CRTC_Read (Reg : Natural) return Byte is
   begin
      if Reg mod 2 = 1 and then Addr_Reg in 14 .. 17 then
         return Regs (Addr_Reg);
      end if;
      return 0;
   end CRTC_Read;

   procedure ULA_Write (Reg : Natural; Value : Byte) is
   begin
      if Reg mod 2 = 0 then
         Ctrl := Value;
      else
         Pal (Natural (Shift_Right (Value, 4))) := (Value and 16#0F#) xor 7;
      end if;
      Update_Colours;
   end ULA_Write;

   function CRTC_Register (R : Natural) return Byte is
     (if R <= 17 then Regs (R) else 0);
   function ULA_Control return Byte is (Ctrl);
   function Palette_Entry (Logical : Natural) return Byte is
     (Pal (Logical mod 16));
   function Current_Line return Natural is (Natural'Max (0, Beam_Line));
   function Teletext_Mode return Boolean is ((Ctrl and 2) /= 0);
   function Field_Count return Natural is (Fields);

   function Screen_Start return Natural is
      S : constant Natural :=
        Natural (Regs (12) and 16#3F#) * 256 + Natural (Regs (13));
   begin
      if (S / 16#2000#) mod 2 = 1 then
         return 16#3C00# + (S mod 16#400#) +
           (if (S / 16#800#) mod 2 = 1 then 16#4000# else 0);
      end if;
      return (S * 8) mod 16#8000#;
   end Screen_Start;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      for R of Regs loop
         Byte'Write (S, R);
      end loop;
      Natural'Write (S, Addr_Reg);
      Natural'Write (S, HC);
      Natural'Write (S, Line);
      Natural'Write (S, Row);
      Boolean'Write (S, In_Adjust);
      Natural'Write (S, Adj_Count);
      Natural'Write (S, MA);
      Natural'Write (S, MA_Row);
      Boolean'Write (S, VDisp);
      Boolean'Write (S, In_VSync);
      Natural'Write (S, VSync_Left);
      Natural'Write (S, Fields);
      Integer'Write (S, Beam_X);
      Integer'Write (S, Beam_Line);
      Natural'Write (S, Phase);
      Byte'Write (S, Ctrl);
      for P of Pal loop
         Byte'Write (S, P);
      end loop;
      Natural'Write (S, Screen_Size);
      Boolean'Write (S, TT_Bottom);
      Boolean'Write (S, TT_Row_DH);
   end Save_State;

   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
      N : Natural;
   begin
      for R of Regs loop
         Byte'Read (S, R);
      end loop;
      Natural'Read (S, Addr_Reg);
      Natural'Read (S, HC);
      Natural'Read (S, Line);
      Natural'Read (S, Row);
      Boolean'Read (S, In_Adjust);
      Natural'Read (S, Adj_Count);
      Natural'Read (S, MA);
      Natural'Read (S, MA_Row);
      Boolean'Read (S, VDisp);
      Boolean'Read (S, In_VSync);
      Natural'Read (S, VSync_Left);
      Natural'Read (S, Fields);
      Integer'Read (S, Beam_X);
      Integer'Read (S, Beam_Line);
      Natural'Read (S, Phase);
      Byte'Read (S, Ctrl);
      for P of Pal loop
         Byte'Read (S, P);
      end loop;
      Natural'Read (S, N);
      Screen_Size := N mod 4;
      Boolean'Read (S, TT_Bottom);
      Boolean'Read (S, TT_Row_DH);
      Update_Colours;
   end Load_State;

end Display;
