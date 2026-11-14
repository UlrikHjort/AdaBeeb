-- ***************************************************************************
--                            AdaBeeb - Char_Data
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
with Machine;

package body Char_Data is

   Font : array (Char_Code) of Glyph := (others => (others => 0));
   ROM_Loaded : Boolean := False;

   function ROM_Glyph (C : Char_Code) return Glyph is
      G : Glyph := (others => 0);
   begin
      if C <= 126 then
         for R in Row_Range loop
            G (R) := Machine.Peek (16#C000# + Word ((C - 32) * 8 + R));
         end loop;
      elsif C = 127 then
         G := (others => 16#FF#);
      end if;
      return G;
   end ROM_Glyph;

   procedure Ensure is
   begin
      if not ROM_Loaded then
         Load_ROM;
      end if;
   end Ensure;

   function Get (C : Char_Code) return Glyph is
   begin
      Ensure;
      return Font (C);
   end Get;

   procedure Put (C : Char_Code; G : Glyph) is
   begin
      Ensure;
      Font (C) := G;
   end Put;

   function Changed (C : Char_Code) return Boolean is
     (Get (C) /= ROM_Glyph (C));

   procedure Load_ROM is
   begin
      for C in Char_Code loop
         Font (C) := ROM_Glyph (C);
      end loop;
      ROM_Loaded := True;
   end Load_ROM;

   function Pixel (G : Glyph; X, Y : Row_Range) return Boolean is
     ((Shift_Right (G (Y), 7 - X) and 1) /= 0);

   procedure Set_Pixel (G : in out Glyph; X, Y : Row_Range; On : Boolean) is
      M : constant Byte := Shift_Left (1, 7 - X);
   begin
      G (Y) := (if On then G (Y) or M else G (Y) and not M);
   end Set_Pixel;

   procedure Invert (G : in out Glyph) is
   begin
      for R of G loop
         R := not R;
      end loop;
   end Invert;

   procedure Mirror_X (G : in out Glyph) is
      O : constant Glyph := G;
   begin
      for Y in Row_Range loop
         for X in Row_Range loop
            Set_Pixel (G, X, Y, Pixel (O, 7 - X, Y));
         end loop;
      end loop;
   end Mirror_X;

   procedure Mirror_Y (G : in out Glyph) is
      O : constant Glyph := G;
   begin
      for Y in Row_Range loop
         G (Y) := O (7 - Y);
      end loop;
   end Mirror_Y;

   procedure Shift (G : in out Glyph; DX, DY : Integer) is
      O : constant Glyph := G;
   begin
      for Y in Row_Range loop
         for X in Row_Range loop
            Set_Pixel (G, X, Y, Pixel (O, (X - DX) mod 8, (Y - DY) mod 8));
         end loop;
      end loop;
   end Shift;

   procedure Rotate (G : in out Glyph) is
      O : constant Glyph := G;
   begin
      for Y in Row_Range loop
         for X in Row_Range loop
            Set_Pixel (G, X, Y, Pixel (O, Y, 7 - X));
         end loop;
      end loop;
   end Rotate;

   procedure Flood_Fill (G : in out Glyph; X, Y : Row_Range; On : Boolean) is
      Target : constant Boolean := Pixel (G, X, Y);
      procedure Fill (PX, PY : Integer) is
      begin
         if PX not in Row_Range or else PY not in Row_Range then
            return;
         end if;
         if Pixel (G, PX, PY) /= Target then
            return;
         end if;
         Set_Pixel (G, PX, PY, On);
         Fill (PX + 1, PY);
         Fill (PX - 1, PY);
         Fill (PX, PY + 1);
         Fill (PX, PY - 1);
      end Fill;
   begin
      if Target /= On then
         Fill (X, Y);
      end if;
   end Flood_Fill;

   procedure Load (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      Ensure;
      Open (F, In_File, Path);
      declare
         Size : constant Natural := Natural (Ada.Streams.Stream_IO.Size (F));
         First : constant Natural := (if Size <= 256 then 224 else 32);
         D : Byte_Array (0 .. Size - 1);
      begin
         Byte_Array'Read (Stream (F), D);
         Close (F);
         if Size = 0 or else Size mod 8 /= 0 then
            return;
         end if;
         for I in 0 .. Size / 8 - 1 loop
            exit when First + I > 255;
            for R in Row_Range loop
               Font (First + I) (R) := D (I * 8 + R);
            end loop;
         end loop;
         Ok := True;
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
      D : Byte_Array (0 .. 224 * 8 - 1);
   begin
      Ensure;
      for C in Char_Code loop
         for R in Row_Range loop
            D ((C - 32) * 8 + R) := Font (C) (R);
         end loop;
      end loop;
      Create (F, Out_File, Path);
      Byte_Array'Write (Stream (F), D);
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Save;

   function Img (N : Natural) return String is
     (Trim (N'Image, Ada.Strings.Left));

   function VDU_Line (C : Char_Code) return String is
      R : Unbounded_String := To_Unbounded_String ("VDU 23," & Img (C));
   begin
      for B of Get (C) loop
         Append (R, "," & Img (Natural (B)));
      end loop;
      return To_String (R);
   end VDU_Line;

   function BASIC_Text (Only_Changed : Boolean := True) return String is
      R : Unbounded_String;
      N : Natural := 10;
      Lower : Boolean := False;
   begin
      for C in Char_Code range 32 .. 223 loop
         if Changed (C) then
            Lower := True;
         end if;
      end loop;
      Append (R, Img (N) & " REM Characters from the AdaBeeb Forge" &
              ASCII.LF);
      N := N + 10;
      if Lower then
         Append (R, Img (N) & " *FX20,6" & ASCII.LF);
         N := N + 10;
      end if;
      for C in Char_Code loop
         if not Only_Changed or else Changed (C) or else C >= 224 then
            if not Only_Changed or else Changed (C) then
               Append (R, Img (N) & " " & VDU_Line (C) & ASCII.LF);
               N := N + 10;
            end if;
         end if;
      end loop;
      return To_String (R);
   end BASIC_Text;

   function Asm_Text (Label : String) return String is
      R : Unbounded_String;
      First : Char_Code := 224;
      function Bin (B : Byte) return String is
         S : String (1 .. 8);
      begin
         for I in 0 .. 7 loop
            S (I + 1) := (if (Shift_Right (B, 7 - I) and 1) /= 0 then '#'
                          else '.');
         end loop;
         return S;
      end Bin;
   begin
      for C in Char_Code range 32 .. 223 loop
         if Changed (C) then
            First := 32;
            exit;
         end if;
      end loop;
      Append (R, "; characters" & First'Image & " .. 255 (8 bytes each, " &
              "top row first) - AdaBeeb Forge" & ASCII.LF &
              "; define them with OSWORD 10 / VDU 23, or copy to the font" &
              " area" & ASCII.LF);
      Append (R, Label & ASCII.LF);
      for C in First .. Char_Code'Last loop
         declare
            G : constant Glyph := Get (C);
         begin
            Append (R, "        ; character" & C'Image & ASCII.LF);
            for Y in Row_Range loop
               Append (R, "        !byte %" & Bin (G (Y)) & ASCII.LF);
            end loop;
         end;
      end loop;
      return To_String (R);
   end Asm_Text;

   function RAM_Address (Read : not null Reader; C : Char_Code)
     return Integer is
      Group : constant Natural := C / 32;          --  1 .. 7
      Page : constant Byte := Read (16#0367# + Word (Group));
   begin
      if Page = 16#0C# and then Group not in 4 | 7 then
         return -1;                      --  font not exploded: ROM
      end if;
      if Page >= 16#80# then
         return -1;
      end if;
      return Natural (Page) * 256 + (C mod 32) * 8;
   end RAM_Address;

end Char_Data;
