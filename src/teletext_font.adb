-- ***************************************************************************
--                          AdaBeeb - Teletext_Font
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
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with Ada.Streams;
with Interfaces; use Interfaces;

package body Teletext_Font is

   type Glyph is array (0 .. Glyph_Height - 1, 0 .. Glyph_Width - 1)
     of Level;
   type Glyph_Set is array (Bank, Code) of Glyph;
   type Glyph_Set_Access is access Glyph_Set;

   Glyphs : constant Glyph_Set_Access :=
     new Glyph_Set'(others => (others => (others => (others => 0))));
   Is_Loaded : Boolean := False;

   function Loaded return Boolean is (Is_Loaded);

   function Pixel_Level (B : Bank; C : Code; Row, Col : Natural)
     return Level is (Glyphs (B, C) (Row, Col));

   procedure Load (Path : String; Ok : out Boolean) is
      F : File_Type;
      Size : Natural;
   begin
      Ok := False;
      Open (F, In_File, Path);
      Size := Natural (Ada.Streams.Stream_IO.Size (F));
      declare
         use Ada.Streams;
         Data : Stream_Element_Array (0 .. Stream_Element_Offset (Size) - 1);
         Last : Stream_Element_Offset;
         Pos  : Natural;
         W, H : Natural;
      begin
         Read (F, Data, Last);
         Close (F);
         if Size < 12 or else
           Character'Val (Data (0)) /= 'B' or else
           Character'Val (Data (3)) /= 'T'
         then
            return;
         end if;
         W := Natural (Data (8));
         H := Natural (Data (9));        --  stored lines (two rows each)
         if W /= Glyph_Width or else H * 2 /= Glyph_Height then
            return;
         end if;
         Pos := 11 + Natural (Data (10));
         if Size < Pos + 3 * 96 * W * H then
            return;
         end if;
         for B in Bank loop
            for C in Code loop
               for L in 0 .. H - 1 loop
                  for X in 0 .. W - 1 loop
                     declare
                        V : constant Natural :=
                          Natural (Data (Stream_Element_Offset (Pos)));
                     begin
                        Glyphs (B, C) (2 * L, X) := V / 16;
                        Glyphs (B, C) (2 * L + 1, X) := V mod 16;
                     end;
                     Pos := Pos + 1;
                  end loop;
               end loop;
            end loop;
         end loop;
         Is_Loaded := True;
         Ok := True;
      end;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Load;

   procedure Build_Fallback (OS_ROM : Byte_Array) is
      Ink : constant Level := 15;
      --  find the 8 x 8 font: the shape of "A"
      A_Glyph : constant Byte_Array (0 .. 7) :=
        (16#3C#, 16#66#, 16#66#, 16#7E#, 16#66#, 16#66#, 16#66#, 16#00#);
      Base : Natural := OS_ROM'First;
   begin
      for P in OS_ROM'First + 33 * 8 .. OS_ROM'Last - 8 loop
         if OS_ROM (P .. P + 7) = A_Glyph then
            Base := P - 33 * 8;
            exit;
         end if;
      end loop;
      for C in Code loop
         --  Alphanumerics from the 8 x 8 OS font, doubled horizontally and
         --  stretched to 18 of the 20 rows
         for R in 0 .. 17 loop
            for X in 0 .. 15 loop
               declare
                  Off : constant Natural := (C - 32) * 8 + (R * 8) / 18;
                  B : constant Byte :=
                    (if Base + Off <= OS_ROM'Last then OS_ROM (Base + Off)
                     else 0);
               begin
                  Glyphs (Alpha, C) (R + 1, X) :=
                    (if (Shift_Right (B, 7 - X / 2) and 1) /= 0
                     then Ink else 0);
               end;
            end loop;
         end loop;

         --  Sixels: 2 x 3 blocks; bit 5 of the cell set is bit 6 of C
         for Sep in Boolean loop
            declare
               BK : constant Bank := (if Sep then Separated else Contiguous);
               Bits : constant Natural :=
                 (C mod 32) + (if (C / 64) mod 2 = 1 then 32 else 0);
            begin
               if (C / 32) mod 2 = 1 then
                  for R in 0 .. 19 loop
                     for X in 0 .. 15 loop
                        declare
                           Cell_Row : constant Natural :=
                             (if R < 6 then 0 elsif R < 14 then 1 else 2);
                           Row_In : constant Natural :=
                             (case Cell_Row is when 0 => R,
                              when 1 => R - 6, when others => R - 14);
                           Row_H : constant Natural :=
                             (if Cell_Row = 1 then 8 else 6);
                           Cell_Col : constant Natural := X / 8;
                           Bit : constant Natural := Cell_Row * 2 + Cell_Col;
                           On : Boolean := (Bits / 2 ** Bit) mod 2 = 1;
                        begin
                           if Sep and then (X mod 8 < 2
                                            or else Row_In >= Row_H - 2)
                           then
                              On := False;
                           end if;
                           Glyphs (BK, C) (R, X) := (if On then Ink else 0);
                        end;
                     end loop;
                  end loop;
               else
                  Glyphs (BK, C) := Glyphs (Alpha, C);   --  blast-through
               end if;
            end;
         end loop;
      end loop;
      Is_Loaded := True;
   end Build_Fallback;

end Teletext_Font;
