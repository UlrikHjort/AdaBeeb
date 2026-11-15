--  Runs a CP/M .COM program (ZEXDOC / ZEXALL) on the Z80 core with a
--  minimal BDOS: functions 2 (print character) and 9 (print string).
--  Exit status 1 when the output reports an error.
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line; use Ada.Command_Line;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with Types; use Types;
with Z80;

procedure Z80_Test is
   Mem : Byte_Array (0 .. 16#FFFF#) := (others => 0);

   function Rd (A : Word) return Byte is (Mem (Natural (A)));
   procedure Wr (A : Word; V : Byte) is
   begin
      Mem (Natural (A)) := V;
   end Wr;
   function Inp (P : Word) return Byte is (16#FF#);
   procedure Outp (P : Word; V : Byte) is null;

   package CPU is new Z80 (Rd, Wr, Inp, Outp);

   Output : Unbounded_String;
   procedure Emit (Ch : Character) is
   begin
      Put (Ch);
      Append (Output, Ch);
      if Ch = ASCII.LF then
         Flush;
      end if;
   end Emit;

   T, Total : Long_Long_Integer := 0;
   N : Natural;
begin
   declare
      use Ada.Streams.Stream_IO;
      F : Ada.Streams.Stream_IO.File_Type;
      Len : Natural;
   begin
      Open (F, Ada.Streams.Stream_IO.In_File, Argument (1));
      Len := Natural (Size (F));
      declare
         Data : Byte_Array (0 .. Len - 1);
      begin
         Byte_Array'Read (Ada.Streams.Stream_IO.Stream (F), Data);
         Mem (16#100# .. 16#100# + Len - 1) := Data;
      end;
      Close (F);
   end;
   Mem (5 .. 7) := (16#C3#, 16#00#, 16#FE#);      --  JP FE00 (BDOS)
   Mem (16#FE00#) := 16#C9#;                       --  RET
   CPU.Reset;
   CPU.PC := 16#100#;
   CPU.SP := 16#FE00#;
   loop
      if CPU.PC = 16#FE00# then
         case CPU.C is
            when 2 => Emit (Character'Val (CPU.E));
            when 9 =>
               declare
                  A : Word := Shift_Left (Word (CPU.D), 8) or Word (CPU.E);
               begin
                  while Mem (Natural (A)) /= Character'Pos ('$') loop
                     Emit (Character'Val (Mem (Natural (A))));
                     A := A + 1;
                  end loop;
               end;
            when others => null;
         end case;
      end if;
      exit when CPU.PC = 0;
      CPU.Step (N);
      Total := Total + Long_Long_Integer (N);
   end loop;
   T := Total;
   New_Line;
   Put_Line ("T-states:" & T'Image);
   if Ada.Strings.Fixed.Index (To_String (Output), "ERROR") > 0
     or else Ada.Strings.Fixed.Index (To_String (Output), "Tests complete") = 0
   then
      Set_Exit_Status (Failure);
   end if;
end Z80_Test;
