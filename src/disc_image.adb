-- ***************************************************************************
--                            AdaBeeb - Disc_Image
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
with Ada.Streams.Stream_IO;
with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Interfaces; use Interfaces;

package body Disc_Image is

   Image_Size : constant := 2 * Max_Tracks * Sectors_Per_Track * Sector_Size;
   type Image_Data is array (0 .. Image_Size - 1) of Byte;
   type Image_Access is access Image_Data;

   type Drive_State is record
      Data     : Image_Access := null;
      Is_Present : Boolean := False;
      RO       : Boolean := False;
      Dirty    : Boolean := False;
      Double   : Boolean := False;
      Num_Tracks : Natural := 0;
      File     : Unbounded_String;
   end record;

   Drives : array (Drive_Number) of Drive_State;

   function Offset (D : Drive_Number; Side : Side_Number;
                    Track, Sector : Natural) return Natural is
     (if Drives (D).Double
      then ((Track * 2 + Side) * Sectors_Per_Track + Sector) * Sector_Size
      else (Track * Sectors_Per_Track + Sector) * Sector_Size);

   procedure Attach (D : Drive_Number; Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Size : Natural;
      Ext : constant String := Ada.Characters.Handling.To_Lower
        (Ada.Directories.Extension (Path));
   begin
      Ok := False;
      Detach (D);
      Open (F, In_File, Path);
      Size := Natural (Ada.Streams.Stream_IO.Size (F));
      if Size > Image_Size then
         Close (F);
         return;
      end if;
      if Drives (D).Data = null then
         Drives (D).Data := new Image_Data;
      end if;
      Drives (D).Data.all := (others => 16#E5#);
      declare
         subtype Buf_T is Byte_Array (0 .. Size - 1);
         Buf : Buf_T;
      begin
         Buf_T'Read (Stream (F), Buf);
         for I in Buf'Range loop
            Drives (D).Data (I) := Buf (I);
         end loop;
      end;
      Close (F);
      Drives (D).Double := Ext = "dsd";
      declare
         Per_Track : constant Natural :=
           Sectors_Per_Track * Sector_Size *
           (if Drives (D).Double then 2 else 1);
      begin
         Drives (D).Num_Tracks :=
           Natural'Max (40, Natural'Min (Max_Tracks,
                                         (Size + Per_Track - 1) / Per_Track));
         if Drives (D).Num_Tracks > 40 then
            Drives (D).Num_Tracks := Max_Tracks;
         end if;
      end;
      Drives (D).Is_Present := True;
      Drives (D).Dirty := False;
      Drives (D).File := To_Unbounded_String (Path);
      --  Read-only file: a write-protected disc
      begin
         Open (F, Append_File, Path);
         Close (F);
         Drives (D).RO := False;
      exception
         when others => Drives (D).RO := True;
      end;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Ok := False;
   end Attach;

   procedure Flush (D : Drive_Number) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Per_Track : constant Natural :=
        Sectors_Per_Track * Sector_Size *
        (if Drives (D).Double then 2 else 1);
      Size : constant Natural := Drives (D).Num_Tracks * Per_Track;
   begin
      if not Drives (D).Is_Present or else not Drives (D).Dirty
        or else Drives (D).RO
      then
         return;
      end if;
      Create (F, Out_File, To_String (Drives (D).File));
      declare
         subtype Buf_T is Byte_Array (0 .. Size - 1);
         Buf : Buf_T;
      begin
         for I in Buf'Range loop
            Buf (I) := Drives (D).Data (I);
         end loop;
         Buf_T'Write (Stream (F), Buf);
      end;
      Close (F);
      Drives (D).Dirty := False;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Flush;

   procedure Detach (D : Drive_Number) is
   begin
      Flush (D);
      Drives (D).Is_Present := False;
      Drives (D).File := Null_Unbounded_String;
   end Detach;

   function Present (D : Drive_Number) return Boolean is
     (Drives (D).Is_Present);
   function Read_Only (D : Drive_Number) return Boolean is (Drives (D).RO);
   function Sides (D : Drive_Number) return Natural is
     (if Drives (D).Double then 2 else 1);
   function Tracks (D : Drive_Number) return Natural is
     (Drives (D).Num_Tracks);
   function Path (D : Drive_Number) return String is
     (To_String (Drives (D).File));
   function Name (D : Drive_Number) return String is
     (if Drives (D).Is_Present
      then Ada.Directories.Simple_Name (To_String (Drives (D).File))
      else "");

   function Has_Sector (D : Drive_Number; Side : Side_Number;
                        Track, Sector : Natural) return Boolean is
     (Drives (D).Is_Present and then Track < Drives (D).Num_Tracks
      and then Sector < Sectors_Per_Track
      and then (Side = 0 or else Drives (D).Double));

   function Get (D : Drive_Number; Side : Side_Number;
                 Track, Sector, Offset : Natural) return Byte is
   begin
      if not Has_Sector (D, Side, Track, Sector) then
         return 16#E5#;
      end if;
      return Drives (D).Data
        (Disc_Image.Offset (D, Side, Track, Sector) + Offset mod 256);
   end Get;

   procedure Put (D : Drive_Number; Side : Side_Number;
                  Track, Sector, Offset : Natural; Value : Byte) is
   begin
      if Has_Sector (D, Side, Track, Sector) and then not Drives (D).RO then
         Drives (D).Data
           (Disc_Image.Offset (D, Side, Track, Sector) + Offset mod 256) :=
           Value;
         Drives (D).Dirty := True;
      end if;
   end Put;

   procedure Format_Track (D : Drive_Number; Side : Side_Number;
                           Track : Natural) is
   begin
      if Drives (D).Is_Present and then not Drives (D).RO
        and then Track < Max_Tracks
      then
         if Track >= Drives (D).Num_Tracks then
            Drives (D).Num_Tracks := Max_Tracks;
         end if;
         for S in 0 .. Sectors_Per_Track - 1 loop
            for I in 0 .. Sector_Size - 1 loop
               Put (D, Side, Track, S, I, 16#E5#);
            end loop;
         end loop;
      end if;
   end Format_Track;

   ---------------------------------------------------------------------
   --  Catalogue
   ---------------------------------------------------------------------

   function Cat (D : Drive_Number; Side : Side_Number; Sec, Off : Natural)
     return Byte is (Get (D, Side, 0, Sec, Off));

   function Catalogue (D : Drive_Number; Side : Side_Number := 0)
     return File_List is
      N : constant Natural :=
        Natural'Min (31, Natural (Cat (D, Side, 1, 5)) / 8);
      R : File_List (1 .. N);
   begin
      if not Present (D) then
         return R (1 .. 0);
      end if;
      for I in 1 .. N loop
         declare
            Base : constant Natural := I * 8;
            Mixed : constant Natural := Natural (Cat (D, Side, 1, Base + 6));
            F : File_Info;
         begin
            for J in 0 .. 6 loop
               F.Name (J + 3) := Character'Val
                 (Natural (Cat (D, Side, 0, Base + J)) mod 128);
            end loop;
            F.Name (1) := Character'Val
              (Natural (Cat (D, Side, 0, Base + 7)) mod 128);
            F.Name (2) := '.';
            F.Locked := Cat (D, Side, 0, Base + 7) >= 128;
            F.Load := Natural (Cat (D, Side, 1, Base)) +
              Natural (Cat (D, Side, 1, Base + 1)) * 256 +
              ((Mixed / 4) mod 4) * 65536;
            F.Exec := Natural (Cat (D, Side, 1, Base + 2)) +
              Natural (Cat (D, Side, 1, Base + 3)) * 256 +
              ((Mixed / 64) mod 4) * 65536;
            F.Length := Natural (Cat (D, Side, 1, Base + 4)) +
              Natural (Cat (D, Side, 1, Base + 5)) * 256 +
              ((Mixed / 16) mod 4) * 65536;
            F.Start_Sector := Natural (Cat (D, Side, 1, Base + 7)) +
              (Mixed mod 4) * 256;
            R (I) := F;
         end;
      end loop;
      return R;
   end Catalogue;

   function Boot_Option (D : Drive_Number; Side : Side_Number := 0)
     return Natural is
     (if Present (D) then (Natural (Cat (D, Side, 1, 6)) / 16) mod 4 else 0);

   function Title (D : Drive_Number; Side : Side_Number := 0)
     return String is
      R : Unbounded_String;
      C : Byte;
   begin
      for I in 0 .. 11 loop
         C := (if I < 8 then Cat (D, Side, 0, I) else Cat (D, Side, 1, I - 8));
         exit when C = 0;
         if C in 32 .. 126 then
            Append (R, Character'Val (C));
         end if;
      end loop;
      return Ada.Strings.Fixed.Trim (To_String (R), Ada.Strings.Right);
   end Title;

   procedure Set_Boot_Option (D : Drive_Number; Option : Natural) is
      B : constant Byte := Cat (D, 0, 1, 6);
   begin
      Put (D, 0, 0, 1, 6, (B and 16#CF#) or Byte ((Option mod 4) * 16));
   end Set_Boot_Option;

   function File_Name (F : File_Info) return String is
      N : constant String :=
        Ada.Strings.Fixed.Trim (F.Name (3 .. 9), Ada.Strings.Right);
   begin
      return (if F.Name (1) = '$' then N else F.Name (1) & "." & N);
   end File_Name;

   function Read_File (D : Drive_Number; Side : Side_Number;
                       F : File_Info) return Byte_Array is
      R : Byte_Array (0 .. F.Length - 1);
      Abs_Sector : Natural;
   begin
      for I in R'Range loop
         Abs_Sector := F.Start_Sector + I / 256;
         R (I) := Get (D, Side, Abs_Sector / 10, Abs_Sector mod 10, I mod 256);
      end loop;
      return R;
   end Read_File;

   procedure Create_Image (Path : String; Tracks : Natural;
                           Title : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Sectors : constant Natural := Tracks * Sectors_Per_Track;
      Size : constant Natural := Sectors * Sector_Size;
      subtype Buf_T is Byte_Array (0 .. Size - 1);
      Buf : Buf_T := (others => 16#E5#);
   begin
      Ok := False;
      Buf (0 .. 511) := (others => 0);
      for I in 0 .. 11 loop
         declare
            C : constant Byte :=
              (if I < Title'Length
               then Character'Pos (Title (Title'First + I)) else 0);
         begin
            if I < 8 then
               Buf (I) := C;
            else
               Buf (256 + I - 8) := C;
            end if;
         end;
      end loop;
      Buf (256 + 6) := Byte (Sectors / 256);
      Buf (256 + 7) := Byte (Sectors mod 256);
      Create (F, Out_File, Path);
      Buf_T'Write (Stream (F), Buf);
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Create_Image;

   procedure Add_File (D : Drive_Number; Name : String; Data : Byte_Array;
                       Load, Exec : Natural; Ok : out Boolean) is
      Dir : Character := '$';
      Base_Name : Unbounded_String;
      Files : constant File_List := Catalogue (D);
      Total : constant Natural :=
        Natural (Cat (D, 0, 1, 7)) + (Natural (Cat (D, 0, 1, 6)) mod 4) * 256;
      Max_End : Natural := 2;
      Start : Natural;
      Needed : constant Natural := (Data'Length + 255) / 256;
      Keep : File_List (1 .. Files'Length);
      Keep_N : Natural := 0;
      Padded : String (1 .. 7) := (others => ' ');
   begin
      Ok := False;
      if not Present (D) or else Read_Only (D) then
         return;
      end if;
      if Name'Length >= 2 and then Name (Name'First + 1) = '.' then
         Dir := Ada.Characters.Handling.To_Upper (Name (Name'First));
         Base_Name := To_Unbounded_String (Name (Name'First + 2 .. Name'Last));
      else
         Base_Name := To_Unbounded_String (Name);
      end if;
      for I in 1 .. Natural'Min (7, Length (Base_Name)) loop
         Padded (I) := Element (Base_Name, I);
      end loop;
      --  drop a file of the same name
      for F of Files loop
         if not (F.Name (1) = Dir and then
                 Ada.Characters.Handling.To_Upper (F.Name (3 .. 9)) =
                 Ada.Characters.Handling.To_Upper (Padded))
         then
            Keep_N := Keep_N + 1;
            Keep (Keep_N) := F;
            Max_End := Natural'Max
              (Max_End, F.Start_Sector + (F.Length + 255) / 256);
         end if;
      end loop;
      if Keep_N >= 31 then
         return;
      end if;
      Start := Max_End;
      if Total > 0 and then Start + Needed > Total then
         return;
      end if;
      --  data
      for I in Data'Range loop
         declare
            S : constant Natural := Start + (I - Data'First) / 256;
         begin
            Put (D, 0, S / 10, S mod 10, (I - Data'First) mod 256, Data (I));
         end;
      end loop;
      --  catalogue: new file first (highest start sector), then the rest
      declare
         procedure Write_Entry (Index : Positive; F : File_Info) is
            B : constant Natural := Index * 8;
            Mixed : constant Natural :=
              (F.Start_Sector / 256) mod 4 +
              ((F.Load / 65536) mod 4) * 4 +
              ((F.Length / 65536) mod 4) * 16 +
              ((F.Exec / 65536) mod 4) * 64;
         begin
            for J in 0 .. 6 loop
               Put (D, 0, 0, 0, B + J, Character'Pos (F.Name (J + 3)));
            end loop;
            Put (D, 0, 0, 0, B + 7, Character'Pos (F.Name (1)) +
                   (if F.Locked then 128 else 0));
            Put (D, 0, 0, 1, B, Byte (F.Load mod 256));
            Put (D, 0, 0, 1, B + 1, Byte ((F.Load / 256) mod 256));
            Put (D, 0, 0, 1, B + 2, Byte (F.Exec mod 256));
            Put (D, 0, 0, 1, B + 3, Byte ((F.Exec / 256) mod 256));
            Put (D, 0, 0, 1, B + 4, Byte (F.Length mod 256));
            Put (D, 0, 0, 1, B + 5, Byte ((F.Length / 256) mod 256));
            Put (D, 0, 0, 1, B + 6, Byte (Mixed));
            Put (D, 0, 0, 1, B + 7, Byte (F.Start_Sector mod 256));
         end Write_Entry;
         New_F : File_Info;
      begin
         New_F.Name (1) := Dir;
         New_F.Name (2) := '.';
         New_F.Name (3 .. 9) := Padded;
         New_F.Load := Load mod 16#40000#;
         New_F.Exec := Exec mod 16#40000#;
         New_F.Length := Data'Length;
         New_F.Start_Sector := Start;
         Write_Entry (1, New_F);
         for I in 1 .. Keep_N loop
            Write_Entry (I + 1, Keep (I));
         end loop;
         Put (D, 0, 0, 1, 5, Byte ((Keep_N + 1) * 8));
         Put (D, 0, 0, 1, 4, Cat (D, 0, 1, 4) + 1);
      end;
      Flush (D);
      Ok := True;
   end Add_File;

end Disc_Image;
