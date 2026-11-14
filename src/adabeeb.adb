-- ***************************************************************************
--                             AdaBeeb - AdaBeeb
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
--  AdaBeeb - a BBC Micro emulator written in Ada with GtkAda.
--
--  Usage: adabeeb [options] [file.ssd|file.dsd|file.uef|file.bas|...]
--    --master / --bplus / --b   BBC Master 128 / Model B+ / Model B
--                       (default: last used, Model B)
--    --roms DIR         ROM directory (default: roms/ next to the program)
--    --rom N=FILE       load a sideways ROM into slot N (0-15)
--    --swram N          make slot N sideways RAM
--    --no-swram         Model B without its default sideways RAM (4-7)
--    --tube             connect a 6502 Second Processor
--    --links HEX        keyboard links (start-up options), default 00
--    --attach FILE      insert a disc image in drive 0 without booting
--    --headless N       run N frames without GUI, then save a screenshot
--    --png FILE         screenshot file for headless mode (default shot.png)
--    --type TEXT        type TEXT after boot (use \n for RETURN)
--    --type-at F TEXT   type TEXT at frame F (repeatable)
--    --screen           headless: print the screen text after the run
--    --wav FILE         headless: record the sound output to a WAV file
--    --dump FILE        headless: write the 32 KB of main RAM after the run
--    --save-tape FILE   headless: save what was written to tape as a UEF
--    --basic SRC        tokenize a BBC BASIC text file and exit
--    --list FILE        list a tokenised BBC BASIC file and exit
--    --asm SRC          assemble a 6502 source file and exit
--    --mkssd OUT FILE..  write a new SSD with the files (BeebLink style:
--                       a FILE.inf gives the BBC name and load / exec)
--    --get SSD NAME OUT copy file NAME (e.g. O.RESULT) out of a disc image
--    --forge [SRC]      open the forge (assembler IDE and debugger)

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Directories;
with Ada.Characters.Handling;
with Ada.Streams.Stream_IO;
with Types; use Types;
with Machine;
with Blit;
with Keyboard;
with Sound;
with Wav_Sink;
with GUI;
with Basic;
with Disc_Image;
with Tube;
with Asm;

procedure AdaBeeb is
   Model    : Machine.Model_Type := Machine.Model_B;
   Model_Given : Boolean := False;
   ROM_Dir  : Unbounded_String;
   Headless : Natural := 0;
   PNG      : Unbounded_String := To_Unbounded_String ("shot.png");
   File     : Unbounded_String;
   Text     : Unbounded_String;
   Wav      : Unbounded_String;
   Print_Screen : Boolean := False;
   Attach_File : Unbounded_String;
   Dump : Unbounded_String;
   Save_Tape : Unbounded_String;
   type Timed_Text is record
      Frame : Natural := 0;
      Text  : Unbounded_String;
   end record;
   Timed : array (1 .. 32) of Timed_Text;
   Timed_Count : Natural := 0;
   type ROM_Arg is record
      Slot : Natural := 0;
      Path : Unbounded_String;
   end record;
   ROM_Args : array (1 .. 16) of ROM_Arg;
   ROM_Count : Natural := 0;
   SWRAM : array (0 .. 15) of Boolean := (others => False);
   I  : Positive := 1;
   Ok : Boolean;

   --  Files the forge opens itself (sources and editor files)
   function Forge_File_Type (Path : String) return Boolean is
      L : constant String := Ada.Characters.Handling.To_Lower (Path);
      function Ends (E : String) return Boolean is
        (L'Length > E'Length
         and then L (L'Last - E'Length + 1 .. L'Last) = E);
   begin
      return Asm.Is_Source (Path) or else Basic.Is_Source (Path)
        or else Ends (".m7") or else Ends (".udg") or else Ends (".bbm")
        or else Ends (".disc") or else Ends (".png");
   end Forge_File_Type;

   function Unescape (S : String) return String is
      R : Unbounded_String;
      J : Positive := S'First;
   begin
      while J <= S'Last loop
         if S (J) = '\' and then J < S'Last and then S (J + 1) = 'n' then
            Append (R, ASCII.LF);
            J := J + 2;
         else
            Append (R, S (J));
            J := J + 1;
         end if;
      end loop;
      return To_String (R);
   end Unescape;

   function Default_ROM_Dir return String is
      Exe : constant String := Command_Name;
      Dir : constant String :=
        (if Ada.Strings.Fixed.Index (Exe, "/") > 0
         then Ada.Directories.Containing_Directory (Exe) else ".");
   begin
      if Ada.Directories.Exists (Dir & "/../roms") then
         return Dir & "/../roms";
      end if;
      return "roms";
   end Default_ROM_Dir;

   function Hex_Value (S : String) return Natural is
      V : Natural := 0;
   begin
      for C of S loop
         case C is
            when '0' .. '9' => V := (V mod 16#100000#) * 16 + Character'Pos (C) - 48;
            when 'a' .. 'f' => V := (V mod 16#100000#) * 16 + Character'Pos (C) - 87;
            when 'A' .. 'F' => V := (V mod 16#100000#) * 16 + Character'Pos (C) - 55;
            when others => null;
         end case;
      end loop;
      return V;
   end Hex_Value;
   function Read_All (Path : String; Ok : out Boolean) return Byte_Array is
      package SIO renames Ada.Streams.Stream_IO;
      F : SIO.File_Type;
   begin
      SIO.Open (F, SIO.In_File, Path);
      declare
         D : Byte_Array (0 .. Natural (SIO.Size (F)) - 1);
      begin
         Byte_Array'Read (SIO.Stream (F), D);
         SIO.Close (F);
         Ok := True;
         return D;
      end;
   exception
      when others =>
         Ok := False;
         return (1 .. 0 => 0);
   end Read_All;

   --  BBC name and addresses from Host.inf ("D.NAME load exec ..."), or
   --  from the host name (#xx escapes decoded) with load = exec = 0
   procedure Parse_Inf (Host : String; Name : out Unbounded_String;
                        Load, Exec : out Natural) is
      Simple : constant String := Ada.Directories.Simple_Name (Host);
      Decoded : Unbounded_String;
      J : Natural := Simple'First;
   begin
      while J <= Simple'Last loop
         if Simple (J) = '#' and then J + 2 <= Simple'Last then
            Append (Decoded, Character'Val
                      (Hex_Value (Simple (J + 1 .. J + 2))));
            J := J + 3;
         else
            Append (Decoded, Simple (J));
            J := J + 1;
         end if;
      end loop;
      Name := Decoded;
      Load := 0;
      Exec := 0;
      if Ada.Directories.Exists (Host & ".inf") then
         declare
            F : File_Type;
         begin
            Open (F, In_File, Host & ".inf");
            declare
               L : constant String := Get_Line (F);
               Words : array (1 .. 3) of Unbounded_String;
               N : Natural := 0;
               In_Word : Boolean := False;
            begin
               for C of L loop
                  if C = ' ' or else C = ASCII.HT then
                     In_Word := False;
                  else
                     if not In_Word then
                        N := N + 1;
                        In_Word := True;
                     end if;
                     if N <= 3 then
                        Append (Words (N), C);
                     end if;
                  end if;
               end loop;
               if N >= 1 then
                  Name := Words (1);
               end if;
               if N >= 2 then
                  Load := Hex_Value (To_String (Words (2))) mod 16#40000#;
               end if;
               if N >= 3 then
                  Exec := Hex_Value (To_String (Words (3))) mod 16#40000#;
               end if;
            end;
            Close (F);
         exception
            when others => null;
         end;
      end if;
   end Parse_Inf;

begin
   ROM_Dir := To_Unbounded_String (Default_ROM_Dir);
   while I <= Argument_Count loop
      declare
         A : constant String := Argument (I);
         function Next return String is
         begin
            I := I + 1;
            return (if I <= Argument_Count then Argument (I) else "");
         end Next;
      begin
         if A = "--master" or else A = "--b" or else A = "--bplus" then
            Model := (if A = "--master" then Machine.Master_128
                      elsif A = "--bplus" then Machine.Model_B_Plus
                      else Machine.Model_B);
            Model_Given := True;
         elsif A = "--roms" then
            ROM_Dir := To_Unbounded_String (Next);
         elsif A = "--rom" then
            declare
               S : constant String := Next;
               Eq : constant Natural := Ada.Strings.Fixed.Index (S, "=");
            begin
               if Eq > 0 and then ROM_Count < ROM_Args'Last then
                  ROM_Count := ROM_Count + 1;
                  ROM_Args (ROM_Count) :=
                    (Natural'Value (S (S'First .. Eq - 1)),
                     To_Unbounded_String (S (Eq + 1 .. S'Last)));
               end if;
            end;
         elsif A = "--tube" then
            Tube.Enabled := True;
         elsif A = "--no-swram" then
            Machine.Model_B_SWRAM := False;
         elsif A = "--swram" then
            SWRAM (Natural'Value (Next) mod 16) := True;
         elsif A = "--links" then
            Keyboard.Links := Byte (Hex_Value (Next) mod 256);
         elsif A = "--headless" then
            Headless := Natural'Value (Next);
         elsif A = "--png" then
            PNG := To_Unbounded_String (Next);
         elsif A = "--type" then
            Text := To_Unbounded_String (Unescape (Next));
         elsif A = "--type-at" then
            declare
               F : constant Natural := Natural'Value (Next);
               T : constant String := Unescape (Next);
            begin
               if Timed_Count < Timed'Last then
                  Timed_Count := Timed_Count + 1;
                  Timed (Timed_Count) := (F, To_Unbounded_String (T));
               end if;
            end;
         elsif A = "--attach" then
            Attach_File := To_Unbounded_String (Next);
         elsif A = "--save-tape" then
            Save_Tape := To_Unbounded_String (Next);
         elsif A = "--dump" then
            Dump := To_Unbounded_String (Next);
         elsif A = "--forge" then
            GUI.Open_Forge := True;
            if I < Argument_Count and then Argument (I + 1) (1) /= '-' then
               GUI.Forge_File := To_Unbounded_String (Next);
            end if;
         elsif A = "--basic" then
            declare
               PRG : Unbounded_String;
            begin
               Basic.Report := Put_Line'Access;
               Basic.Build (Next, Basic.Basic_II, PRG, Ok);
               Set_Exit_Status (if Ok then 0 else 1);
               return;
            end;
         elsif A = "--list" then
            declare
               T : constant String := Basic.List_PRG (Next, Ok);
            begin
               Put (T);
               Set_Exit_Status (if Ok then 0 else 1);
               return;
            end;
         elsif A = "--asm" then
            declare
               PRG : Unbounded_String;
            begin
               Asm.Report := Put_Line'Access;
               Asm.Build (Next, PRG, Ok);
               Set_Exit_Status (if Ok then 0 else 1);
               return;
            end;
         elsif A = "--mkssd" then
            declare
               Out_Path : constant String := Next;
            begin
               Disc_Image.Create_Image (Out_Path, 80, "TEST", Ok);
               if Ok then
                  Disc_Image.Attach (0, Out_Path, Ok);
               end if;
               while Ok and then I < Argument_Count loop
                  declare
                     Host : constant String := Next;
                     Data_Ok : Boolean;
                     Name : Unbounded_String;
                     Load, Exec : Natural := 0;
                     Data : constant Byte_Array :=
                       Read_All (Host, Data_Ok);
                  begin
                     Parse_Inf (Host, Name, Load, Exec);
                     if not Data_Ok then
                        Put_Line ("cannot read " & Host);
                        Ok := False;
                     else
                        Disc_Image.Add_File (0, To_String (Name), Data,
                                             Load, Exec, Ok);
                        if not Ok then
                           Put_Line ("cannot add " & To_String (Name));
                        end if;
                     end if;
                  end;
               end loop;
               Disc_Image.Detach (0);
               Set_Exit_Status (if Ok then 0 else 1);
               return;
            end;
         elsif A = "--get" then
            declare
               SSD : constant String := Next;
               Name : constant String := Next;
               Out_Path : constant String := Next;
               Found : Boolean := False;
            begin
               Disc_Image.Attach (0, SSD, Ok);
               if Ok then
                  for F of Disc_Image.Catalogue (0) loop
                     if Disc_Image.File_Name (F) = Name
                       or else "$." & Disc_Image.File_Name (F) = Name
                     then
                        declare
                           package SIO renames Ada.Streams.Stream_IO;
                           OF_F : SIO.File_Type;
                        begin
                           SIO.Create (OF_F, SIO.Out_File, Out_Path);
                           Byte_Array'Write
                             (SIO.Stream (OF_F),
                              Disc_Image.Read_File (0, 0, F));
                           SIO.Close (OF_F);
                           Found := True;
                        end;
                     end if;
                  end loop;
               end if;
               if not Found then
                  Put_Line ("no file " & Name & " on " & SSD);
               end if;
               Set_Exit_Status (if Found then 0 else 1);
               return;
            end;
         elsif A = "--screen" then
            Print_Screen := True;
         elsif A = "--wav" then
            Wav := To_Unbounded_String (Next);
         elsif A'Length > 0 and then A (A'First) /= '-' then
            File := To_Unbounded_String (A);
         else
            Put_Line ("unknown option " & A);
            Set_Exit_Status (2);
            return;
         end if;
      end;
      I := I + 1;
   end loop;

   Machine.Power_On (Model, To_String (ROM_Dir), Ok);
   if not Ok then
      Put_Line ("Cannot start: " & Machine.Error_Message);
      Set_Exit_Status (1);
      return;
   end if;
   for R of ROM_Args (1 .. ROM_Count) loop
      Machine.Load_Sideways_ROM (R.Slot, To_String (R.Path), Ok);
      if not Ok then
         Put_Line ("cannot load ROM " & To_String (R.Path));
      end if;
   end loop;
   for S in SWRAM'Range loop
      if SWRAM (S) then
         Machine.Set_Sideways_RAM (S, True);
      end if;
   end loop;
   Machine.Reset;

   if Headless > 0 then
      if Length (Wav) > 0 then
         Sound.Sink := Wav_Sink.Push'Access;
      end if;
      if Length (Attach_File) > 0 then
         Machine.Attach (To_String (Attach_File), Ok);
         if not Ok then
            Put_Line ("cannot attach " & To_String (Attach_File));
         end if;
      end if;
      if Length (File) > 0 then
         Machine.Autostart (To_String (File), Ok);
         if not Ok then
            Put_Line ("cannot start " & To_String (File) & ": " &
                        Machine.Error_Message);
         end if;
      end if;
      for F in 1 .. Headless loop
         if Length (Text) > 0 and then F >= 60
           and then (Machine.At_Prompt or else F >= 400)
           and then not Machine.Autostart_Busy
         then
            Machine.Type_Text (To_String (Text));
            Text := Null_Unbounded_String;
         end if;
         for T of Timed (1 .. Timed_Count) loop
            if T.Frame = F then
               Machine.Type_Text (To_String (T.Text));
            end if;
         end loop;
         Machine.Run_Frame;
      end loop;
      Blit.Save_PNG (To_String (PNG));
      if Length (Wav) > 0 then
         Wav_Sink.Save (To_String (Wav));
      end if;
      if Length (Save_Tape) > 0 then
         Machine.Save_Tape_Recording (To_String (Save_Tape), Ok);
         Put_Line ("tape recording:" & Machine.Tape_Recorded'Image &
                   " bytes" & (if Ok then "" else " (not written)"));
      end if;
      if Length (Dump) > 0 then
         declare
            package SIO renames Ada.Streams.Stream_IO;
            F : SIO.File_Type;
         begin
            SIO.Create (F, SIO.Out_File, To_String (Dump));
            for Addr in 0 .. 16#7FFF# loop
               Byte'Write (SIO.Stream (F), Machine.RAM_Peek (Addr));
            end loop;
            SIO.Close (F);
         end;
      end if;
      if Print_Screen then
         Put (Machine.Screen_Text);
      end if;
      Put_Line (Machine.Debug_Info);
      Machine.Shutdown;
      return;
   end if;

   if Ada.Strings.Fixed.Index (Command_Name, "forge") > 0 then
      GUI.Open_Forge := True;
   end if;
   if GUI.Open_Forge and then Length (File) > 0
     and then Forge_File_Type (To_String (File))
   then
      GUI.Forge_File := File;
      File := Null_Unbounded_String;
   end if;
   GUI.Run (Model, To_String (ROM_Dir), To_String (File),
            To_String (Attach_File), Model_Given);
end AdaBeeb;
