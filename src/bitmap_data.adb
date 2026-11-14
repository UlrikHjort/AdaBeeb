-- ***************************************************************************
--                           AdaBeeb - Bitmap_Data
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
with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;
with System;
with Cairo; use Cairo;
with Cairo.Image_Surface;
with Cairo.Png;
with Cairo.Surface;
with Video;

package body Bitmap_Data is

   Cur_Mode : Mode_Number := 1;
   Pix : constant Grid_Access := new Pixel_Grid'(others => (others => 0));
   Pal : Byte_Array (0 .. 15) := (others => 0);

   function Mode return Mode_Number is (Cur_Mode);
   function Width return Natural is
     (case Cur_Mode is when 0 => 640, when 1 | 4 => 320, when others => 160);
   function Height return Natural is (256);
   function Colours return Natural is
     (case Cur_Mode is when 0 | 4 => 2, when 1 | 5 => 4, when others => 16);
   function Screen_Base return Natural is
     (if Cur_Mode <= 2 then 16#3000# else 16#5800#);
   function Screen_Size return Natural is
     (if Cur_Mode <= 2 then 20480 else 10240);
   function Bits return Natural is
     (case Colours is when 2 => 1, when 4 => 2, when others => 4);
   function Cols return Natural is (if Cur_Mode <= 2 then 80 else 40);

   procedure Default_Palette is
   begin
      Pal := (others => 0);
      case Colours is
         when 2 => Pal (0) := 0; Pal (1) := 7;
         when 4 => Pal (0 .. 3) := (0, 1, 3, 7);
         when others =>
            for I in 0 .. 15 loop
               Pal (I) := Byte (I);
            end loop;
      end case;
   end Default_Palette;

   function Palette_Is_Default return Boolean is
      Save : constant Byte_Array := Pal;
      R : Boolean;
   begin
      Default_Palette;
      R := Pal = Save;
      Pal := Save;
      return R;
   end Palette_Is_Default;

   procedure Set_Mode (M : Mode_Number; Keep_Picture : Boolean := False) is
      Old_W : constant Natural := Width;
      Old : constant Pixel_Grid := Pix.all;
   begin
      Cur_Mode := (if Valid_Mode (M) then M else 1);
      Default_Palette;
      if Keep_Picture then
         for Y in 0 .. 255 loop
            for X in 0 .. Width - 1 loop
               Pix (Y, X) := Old (Y, X * Old_W / Width) mod Colours;
            end loop;
         end loop;
      else
         Pix.all := (others => (others => 0));
      end if;
   end Set_Mode;

   function Get (X, Y : Natural) return Logical is
     (if X < Width and then Y < 256 then Pix (Y, X) else 0);

   procedure Put (X, Y : Natural; C : Logical) is
   begin
      if X < Width and then Y < 256 then
         Pix (Y, X) := C mod Colours;
      end if;
   end Put;

   procedure Clear (C : Logical := 0) is
   begin
      Pix.all := (others => (others => C mod Colours));
   end Clear;

   function Physical (L : Logical) return Byte is (Pal (L));

   procedure Set_Physical (L : Logical; P : Byte) is
   begin
      Pal (L) := P mod 16;
   end Set_Physical;

   function RGB (L : Logical) return Pixel is
     (Video.Colours (Pal (L) and 7));

   procedure Line (X0, Y0, X1, Y1 : Integer; C : Logical) is
      DX : constant Integer := abs (X1 - X0);
      DY : constant Integer := -abs (Y1 - Y0);
      SX : constant Integer := (if X0 < X1 then 1 else -1);
      SY : constant Integer := (if Y0 < Y1 then 1 else -1);
      Err : Integer := DX + DY;
      X : Integer := X0;
      Y : Integer := Y0;
      E2 : Integer;
   begin
      loop
         if X >= 0 and then Y >= 0 then
            Put (X, Y, C);
         end if;
         exit when X = X1 and then Y = Y1;
         E2 := 2 * Err;
         if E2 >= DY then
            Err := Err + DY;
            X := X + SX;
         end if;
         if E2 <= DX then
            Err := Err + DX;
            Y := Y + SY;
         end if;
      end loop;
   end Line;

   procedure Rect (X0, Y0, X1, Y1 : Integer; C : Logical; Filled : Boolean) is
      L : constant Integer := Integer'Min (X0, X1);
      R : constant Integer := Integer'Max (X0, X1);
      T : constant Integer := Integer'Min (Y0, Y1);
      B : constant Integer := Integer'Max (Y0, Y1);
   begin
      if Filled then
         for Y in T .. B loop
            for X in L .. R loop
               if X >= 0 and then Y >= 0 then
                  Put (X, Y, C);
               end if;
            end loop;
         end loop;
      else
         Line (L, T, R, T, C);
         Line (L, B, R, B, C);
         Line (L, T, L, B, C);
         Line (R, T, R, B, C);
      end if;
   end Rect;

   procedure Ellipse (X0, Y0, X1, Y1 : Integer; C : Logical;
                      Filled : Boolean) is
      CX : constant Float := Float (X0 + X1) / 2.0;
      CY : constant Float := Float (Y0 + Y1) / 2.0;
      RX : constant Float := Float'Max (0.5, abs (Float (X1 - X0)) / 2.0);
      RY : constant Float := Float'Max (0.5, abs (Float (Y1 - Y0)) / 2.0);
   begin
      for Y in Integer'Min (Y0, Y1) .. Integer'Max (Y0, Y1) loop
         for X in Integer'Min (X0, X1) .. Integer'Max (X0, X1) loop
            declare
               DX : constant Float := (Float (X) - CX) / RX;
               DY : constant Float := (Float (Y) - CY) / RY;
               D : constant Float := DX * DX + DY * DY;
               Edge : constant Float :=
                 1.0 - 2.0 / Float'Min (RX, RY) - 0.15;
            begin
               if X >= 0 and then Y >= 0 and then D <= 1.0
                 and then (Filled or else D >= Edge)
               then
                  Put (X, Y, C);
               end if;
            end;
         end loop;
      end loop;
   end Ellipse;

   procedure Flood_Fill (X, Y : Natural; C : Logical) is
      Target : constant Logical := Get (X, Y);
      type Point is record
         X, Y : Natural;
      end record;
      type Stack_T is array (1 .. 640 * 256) of Point;
      type Stack_Access is access Stack_T;
      Stack : constant Stack_Access := new Stack_T;
      Top : Natural := 0;
      procedure Push (PX, PY : Integer) is
      begin
         if PX >= 0 and then PY >= 0 and then PX < Width and then PY < 256
           and then Pix (PY, PX) = Target and then Top < Stack'Last
         then
            Pix (PY, PX) := C;
            Top := Top + 1;
            Stack (Top) := (PX, PY);
         end if;
      end Push;
   begin
      if Target = C mod Colours then
         return;
      end if;
      Push (X, Y);
      while Top > 0 loop
         declare
            P : constant Point := Stack (Top);
         begin
            Top := Top - 1;
            Push (P.X + 1, P.Y);
            Push (P.X - 1, P.Y);
            Push (P.X, P.Y + 1);
            Push (P.X, P.Y - 1);
         end;
      end loop;
   end Flood_Fill;

   ---------------------------------------------------------------------
   --  Screen memory
   ---------------------------------------------------------------------

   function Address (Col, Y : Natural) return Natural is
     ((Y / 8) * Cols * 8 + Col * 8 + Y mod 8);

   function Pack (X0, Y : Natural) return Byte is
      B : Byte := 0;
      PPB : constant Natural := 8 / Bits;
   begin
      for N in 0 .. PPB - 1 loop
         declare
            C : constant Byte := Byte (Get (X0 + N, Y));
         begin
            case Bits is
               when 1 =>
                  B := B or Shift_Left (C and 1, 7 - N);
               when 2 =>
                  B := B or Shift_Left (Shift_Right (C, 1) and 1, 7 - N)
                    or Shift_Left (C and 1, 3 - N);
               when others =>
                  B := B or Shift_Left (Shift_Right (C, 3) and 1, 7 - N)
                    or Shift_Left (Shift_Right (C, 2) and 1, 5 - N)
                    or Shift_Left (Shift_Right (C, 1) and 1, 3 - N)
                    or Shift_Left (C and 1, 1 - N);
            end case;
         end;
      end loop;
      return B;
   end Pack;

   procedure Unpack (B : Byte; X0, Y : Natural) is
      PPB : constant Natural := 8 / Bits;
      C : Byte;
   begin
      for N in 0 .. PPB - 1 loop
         case Bits is
            when 1 =>
               C := Shift_Right (B, 7 - N) and 1;
            when 2 =>
               C := Shift_Left (Shift_Right (B, 7 - N) and 1, 1)
                 or (Shift_Right (B, 3 - N) and 1);
            when others =>
               C := Shift_Left (Shift_Right (B, 7 - N) and 1, 3)
                 or Shift_Left (Shift_Right (B, 5 - N) and 1, 2)
                 or Shift_Left (Shift_Right (B, 3 - N) and 1, 1)
                 or (Shift_Right (B, 1 - N) and 1);
         end case;
         Put (X0 + N, Y, Logical (C));
      end loop;
   end Unpack;

   function Screen_Bytes return Byte_Array is
      D : Byte_Array (0 .. Screen_Size - 1) := (others => 0);
      PPB : constant Natural := 8 / Bits;
   begin
      for Y in 0 .. 255 loop
         for Col in 0 .. Cols - 1 loop
            D (Address (Col, Y)) := Pack (Col * PPB, Y);
         end loop;
      end loop;
      return D;
   end Screen_Bytes;

   procedure Set_Screen_Bytes (D : Byte_Array) is
      PPB : constant Natural := 8 / Bits;
   begin
      for Y in 0 .. 255 loop
         for Col in 0 .. Cols - 1 loop
            declare
               A : constant Natural := Address (Col, Y);
            begin
               if A < D'Length then
                  Unpack (D (D'First + A), Col * PPB, Y);
               end if;
            end;
         end loop;
      end loop;
   end Set_Screen_Bytes;

   ---------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------

   procedure Load (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      Open (F, In_File, Path);
      declare
         Size : constant Natural := Natural (Ada.Streams.Stream_IO.Size (F));
         D : Byte_Array (0 .. Size - 1);
      begin
         Byte_Array'Read (Stream (F), D);
         Close (F);
         if Size > 21 and then D (0 .. 3) = (66, 66, 77, 49) then  --  BBM1
            Set_Mode (Natural (D (4)));
            for I in 0 .. 15 loop
               Pal (I) := D (5 + I) and 15;
            end loop;
            Set_Screen_Bytes (D (21 .. D'Last));
            Ok := True;
         elsif Size in 10240 | 20480 then
            --  raw screen dump: mode 5 / mode 1 unless already set alike
            if Size = 10240 and then Cur_Mode <= 2 then
               Set_Mode (5);
            elsif Size = 20480 and then Cur_Mode > 2 then
               Set_Mode (1);
            end if;
            Set_Screen_Bytes (D);
            Ok := True;
         end if;
      end;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Load;

   procedure Save (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Head : Byte_Array (0 .. 20);
   begin
      Head (0 .. 4) := (66, 66, 77, 49, Byte (Cur_Mode));
      Head (5 .. 20) := Pal;
      Create (F, Out_File, Path);
      Byte_Array'Write (Stream (F), Head);
      Byte_Array'Write (Stream (F), Screen_Bytes);
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Save;

   procedure Import_Image (Path : String; Dither : Boolean; Ok : out Boolean)
   is
      Surf : Cairo_Surface;
      use type Cairo_Status;
   begin
      Ok := False;
      Surf := Cairo.Png.Create_From_Png (Path);
      if Cairo.Surface.Status (Surf) /= Cairo_Status_Success then
         return;
      end if;
      declare
         IW : constant Natural :=
           Natural (Cairo.Image_Surface.Get_Width (Surf));
         IH : constant Natural :=
           Natural (Cairo.Image_Surface.Get_Height (Surf));
         Stride : constant Natural :=
           Natural (Cairo.Image_Surface.Get_Stride (Surf)) / 4;
         Addr : constant System.Address :=
           Cairo.Image_Surface.Get_Data_Generic (Surf);
         type Pixels is array (0 .. IH - 1, 0 .. Stride - 1) of U32;
         Src : Pixels;
         for Src'Address use Addr;
         pragma Import (Ada, Src);
         W : constant Natural := Width;
         type Err_Row is array (-1 .. 640) of Float;
         Err_R, Err_G, Err_B, Nxt_R, Nxt_G, Nxt_B : Err_Row :=
           (others => 0.0);
         --  The screen is 4:3 at 640 x 512 square pixels
         Scale : constant Float :=
           Float'Min (640.0 / Float (IW), 512.0 / Float (IH));
         OX : constant Float := (640.0 - Float (IW) * Scale) / 2.0;
         OY : constant Float := (512.0 - Float (IH) * Scale) / 2.0;
      begin
         if IW = 0 or else IH = 0 then
            Cairo.Surface.Destroy (Surf);
            return;
         end if;
         Cairo.Surface.Flush (Surf);
         for Y in 0 .. 255 loop
            Nxt_R := (others => 0.0);
            Nxt_G := (others => 0.0);
            Nxt_B := (others => 0.0);
            for X in 0 .. W - 1 loop
               declare
                  --  centre of the BBC pixel in 640 x 512 space
                  PX : constant Float :=
                    (Float (X) + 0.5) * 640.0 / Float (W);
                  PY : constant Float := Float (Y) * 2.0 + 1.0;
                  SX : constant Integer :=
                    Integer (Float'Floor ((PX - OX) / Scale));
                  SY : constant Integer :=
                    Integer (Float'Floor ((PY - OY) / Scale));
                  R, G, B : Float := 0.0;
                  Best : Logical := 0;
                  Best_D : Float := Float'Last;
               begin
                  if SX in 0 .. IW - 1 and then SY in 0 .. IH - 1 then
                     declare
                        P : constant U32 := Src (SY, SX);
                     begin
                        R := Float (Shift_Right (P, 16) and 255);
                        G := Float (Shift_Right (P, 8) and 255);
                        B := Float (P and 255);
                     end;
                  end if;
                  if Dither then
                     R := R + Err_R (X);
                     G := G + Err_G (X);
                     B := B + Err_B (X);
                  end if;
                  for L in 0 .. Colours - 1 loop
                     declare
                        Q : constant Pixel := RGB (L);
                        DR : constant Float :=
                          R - Float (Shift_Right (Q, 16) and 255);
                        DG : constant Float :=
                          G - Float (Shift_Right (Q, 8) and 255);
                        DB : constant Float := B - Float (Q and 255);
                        D : constant Float :=
                          0.3 * DR * DR + 0.59 * DG * DG + 0.11 * DB * DB;
                     begin
                        if D < Best_D then
                           Best_D := D;
                           Best := L;
                        end if;
                     end;
                  end loop;
                  Pix (Y, X) := Best;
                  if Dither then
                     declare
                        Q : constant Pixel := RGB (Best);
                        ER : constant Float :=
                          R - Float (Shift_Right (Q, 16) and 255);
                        EG : constant Float :=
                          G - Float (Shift_Right (Q, 8) and 255);
                        EB : constant Float := B - Float (Q and 255);
                     begin
                        Err_R (X + 1) := Err_R (X + 1) + ER * 7.0 / 16.0;
                        Err_G (X + 1) := Err_G (X + 1) + EG * 7.0 / 16.0;
                        Err_B (X + 1) := Err_B (X + 1) + EB * 7.0 / 16.0;
                        Nxt_R (X - 1) := Nxt_R (X - 1) + ER * 3.0 / 16.0;
                        Nxt_G (X - 1) := Nxt_G (X - 1) + EG * 3.0 / 16.0;
                        Nxt_B (X - 1) := Nxt_B (X - 1) + EB * 3.0 / 16.0;
                        Nxt_R (X) := Nxt_R (X) + ER * 5.0 / 16.0;
                        Nxt_G (X) := Nxt_G (X) + EG * 5.0 / 16.0;
                        Nxt_B (X) := Nxt_B (X) + EB * 5.0 / 16.0;
                        Nxt_R (X + 1) := Nxt_R (X + 1) + ER / 16.0;
                        Nxt_G (X + 1) := Nxt_G (X + 1) + EG / 16.0;
                        Nxt_B (X + 1) := Nxt_B (X + 1) + EB / 16.0;
                     end;
                  end if;
               end;
            end loop;
            Err_R := Nxt_R;
            Err_G := Nxt_G;
            Err_B := Nxt_B;
         end loop;
      end;
      Cairo.Surface.Destroy (Surf);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Import_Image;

   function Img (N : Natural) return String is
     (Trim (N'Image, Ada.Strings.Left));

   function Loader_BASIC (Data_Name : String) return String is
      R : Unbounded_String;
      N : Natural := 30;
      Save_Pal : constant Byte_Array := Pal;
   begin
      Append (R, "10 REM Picture from the AdaBeeb Forge" & ASCII.LF &
              "20 MODE " & Img (Cur_Mode) & ":VDU 23;8202;0;0;0;" &
              ASCII.LF);
      Default_Palette;
      for L in 0 .. Colours - 1 loop
         if Save_Pal (L) /= Pal (L) then
            Append (R, Img (N) & " VDU 19," & Img (L) & "," &
                    Img (Natural (Save_Pal (L))) & ";0;" & ASCII.LF);
            N := N + 10;
         end if;
      end loop;
      Pal := Save_Pal;
      Append (R, Img (N) & " *LOAD " & Data_Name & " " &
              (if Cur_Mode <= 2 then "3000" else "5800") & ASCII.LF);
      Append (R, Img (N + 10) & " A$=GET$" & ASCII.LF);
      return To_String (R);
   end Loader_BASIC;

   function Snapshot return Picture is
     ((M => Cur_Mode, Pix => new Pixel_Grid'(Pix.all), Pal => Pal));

   procedure Restore (P : Picture) is
   begin
      Cur_Mode := P.M;
      Pix.all := P.Pix.all;
      Pal := P.Pal;
   end Restore;

begin
   Default_Palette;
end Bitmap_Data;
