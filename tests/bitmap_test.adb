-- ***************************************************************************
--                           AdaBeeb - Bitmap_Test
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
--  Bitmap editor data test: pictures packed by Bitmap_Data are poked into
--  the emulated screen in each graphics mode; the video output must show
--  the same colours (checks the pixel packing against the video ULA).

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Types; use Types;
with Interfaces; use Interfaces;
with Machine;
with Video;
with Bitmap_Data;

procedure Bitmap_Test is
   Failures : Natural := 0;
   Ok : Boolean;

   procedure Check (Cond : Boolean; What : String) is
   begin
      Put_Line ((if Cond then "ok   " else "FAIL ") & What);
      if not Cond then
         Failures := Failures + 1;
      end if;
   end Check;

   procedure Frames (N : Natural) is
   begin
      for I in 1 .. N loop
         Machine.Run_Frame;
      end loop;
   end Frames;

   procedure Test_Mode (M : Natural) is
      use Bitmap_Data;
      Bad : Natural := 0;
      Steady : Natural;
   begin
      Machine.Type_Text ("MODE" & M'Image & ASCII.LF);
      Frames (60);
      Set_Mode (M);
      Steady := Natural'Min (Colours, 8);
      for Y in 0 .. 255 loop
         for X in 0 .. Width - 1 loop
            Put (X, Y, (X / 3 + Y / 5) mod Steady);
         end loop;
      end loop;
      declare
         D : constant Byte_Array := Screen_Bytes;
      begin
         for I in D'Range loop
            Machine.Poke (Word (Screen_Base + I), D (I));
         end loop;
      end;
      Frames (2);
      for Y in 0 .. 255 loop
         for X in 0 .. Width - 1 loop
            declare
               PW : constant Natural := 640 / Width;
               FX : constant Natural := 64 + X * PW + PW / 2;
               FY : constant Natural := (16 + Y) * 2;
            begin
               if Video.FB (FY, FX) /= RGB (Get (X, Y)) then
                  Bad := Bad + 1;
               end if;
            end;
         end loop;
      end loop;
      Check (Bad = 0, "MODE" & M'Image & " picture shown exactly (" &
             Bad'Image & " wrong pixels)");
      --  and read back from screen memory
      declare
         D : Byte_Array (0 .. Screen_Size - 1);
         Before : constant Byte_Array := Screen_Bytes;
      begin
         for I in D'Range loop
            D (I) := Machine.Peek (Word (Screen_Base + I));
         end loop;
         Clear;
         Set_Screen_Bytes (D);
         Check (Screen_Bytes = Before, "MODE" & M'Image & " read back");
      end;
   end Test_Mode;

begin
   Machine.Power_On (Machine.Model_B, "roms", Ok);
   Check (Ok, "power on");
   Frames (100);
   Test_Mode (0);
   Test_Mode (1);
   Test_Mode (2);
   Test_Mode (4);
   Test_Mode (5);
   if Failures > 0 then
      Put_Line (Failures'Image & " FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("all passed");
   end if;
end Bitmap_Test;
