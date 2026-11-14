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
--  Acorn DFS disc images: .ssd (single sided) and .dsd (double sided,
--  tracks interleaved side 0 / side 1), 10 sectors of 256 bytes per
--  track, 40 or 80 tracks.  Images are held in memory and written back
--  to the file after every write command.

with Types; use Types;

package Disc_Image is

   Sectors_Per_Track : constant := 10;
   Sector_Size       : constant := 256;
   Max_Tracks        : constant := 80;

   type Drive_Number is range 0 .. 1;
   subtype Side_Number is Natural range 0 .. 1;

   procedure Attach (D : Drive_Number; Path : String; Ok : out Boolean);
   procedure Detach (D : Drive_Number);
   procedure Flush (D : Drive_Number);   --  write back if modified

   function Present (D : Drive_Number) return Boolean;
   function Read_Only (D : Drive_Number) return Boolean;
   function Sides (D : Drive_Number) return Natural;
   function Tracks (D : Drive_Number) return Natural;
   function Name (D : Drive_Number) return String;   --  file name
   function Path (D : Drive_Number) return String;

   function Has_Sector (D : Drive_Number; Side : Side_Number;
                        Track, Sector : Natural) return Boolean;
   function Get (D : Drive_Number; Side : Side_Number;
                 Track, Sector, Offset : Natural) return Byte;
   procedure Put (D : Drive_Number; Side : Side_Number;
                  Track, Sector, Offset : Natural; Value : Byte);
   procedure Format_Track (D : Drive_Number; Side : Side_Number;
                           Track : Natural);

   --  Catalogue (side 0 of drive 0 unless given)
   type File_Info is record
      Name   : String (1 .. 9) := (others => ' ');   --  "D.NAME   "
      Length : Natural := 0;
      Load, Exec : Natural := 0;     --  18-bit addresses
      Start_Sector : Natural := 0;
      Locked : Boolean := False;
   end record;
   type File_List is array (Positive range <>) of File_Info;

   function Catalogue (D : Drive_Number; Side : Side_Number := 0)
     return File_List;
   function Boot_Option (D : Drive_Number; Side : Side_Number := 0)
     return Natural;
   function Title (D : Drive_Number; Side : Side_Number := 0) return String;
   procedure Set_Boot_Option (D : Drive_Number; Option : Natural);

   function File_Name (F : File_Info) return String;
   --  "NAME" for files in directory $, "D.NAME" otherwise

   function Read_File (D : Drive_Number; Side : Side_Number;
                       F : File_Info) return Byte_Array;

   procedure Create_Image (Path : String; Tracks : Natural;
                           Title : String; Ok : out Boolean);
   --  A blank, formatted single-sided image with an empty catalogue.

   procedure Add_File (D : Drive_Number; Name : String; Data : Byte_Array;
                       Load, Exec : Natural; Ok : out Boolean);
   --  Write a file to side 0 (replacing one of the same name).

end Disc_Image;
