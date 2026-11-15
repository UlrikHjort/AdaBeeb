-- ***************************************************************************
--                              AdaBeeb - Speech
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
with Interfaces; use Interfaces;

package body Speech is

   ---------------------------------------------------------------------
   --  TMS5220 coefficient tables, as measured from decapped chips (from
   --  MAME's tms5110r.hxx: Copyright (c) Frank Palazzolo, Couriersud,
   --  Jonathan Gevaryahu; BSD-3-Clause, see THIRD_PARTY.md for the full
   --  notice and conditions)
   ---------------------------------------------------------------------

   Energy_Table : constant array (0 .. 15) of Integer :=
     (0, 1, 2, 3, 4, 6, 8, 11, 16, 23, 33, 47, 63, 85, 114, 0);

   Pitch_Table : constant array (0 .. 63) of Integer :=
     (0, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
      30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 46, 48,
      50, 52, 53, 56, 58, 60, 62, 65, 68, 70, 72, 76, 78, 80, 84, 86,
      91, 94, 98, 101, 105, 109, 114, 118, 122, 127, 132, 137, 142, 148,
      153, 159);

   K_Bits : constant array (1 .. 10) of Natural :=
     (5, 5, 4, 4, 4, 4, 4, 3, 3, 3);

   K_Table : constant array (1 .. 10, 0 .. 31) of Integer :=
     (1 => (-501, -498, -497, -495, -493, -491, -488, -482,
            -478, -474, -469, -464, -459, -452, -445, -437,
            -412, -380, -339, -288, -227, -158, -81, -1,
            80, 157, 226, 287, 337, 379, 411, 436),
      2 => (-328, -303, -274, -244, -211, -175, -138, -99,
            -59, -18, 24, 64, 105, 143, 180, 215,
            248, 278, 306, 331, 354, 374, 392, 408,
            422, 435, 445, 455, 463, 470, 476, 506),
      3 => (-441, -387, -333, -279, -225, -171, -117, -63,
            -9, 45, 98, 152, 206, 260, 314, 368, others => 0),
      4 => (-328, -273, -217, -161, -106, -50, 5, 61,
            116, 172, 228, 283, 339, 394, 450, 506, others => 0),
      5 => (-328, -282, -235, -189, -142, -96, -50, -3,
            43, 90, 136, 182, 229, 275, 322, 368, others => 0),
      6 => (-256, -212, -168, -123, -79, -35, 10, 54,
            98, 143, 187, 232, 276, 320, 365, 409, others => 0),
      7 => (-308, -260, -212, -164, -117, -69, -21, 27,
            75, 122, 170, 218, 266, 314, 361, 409, others => 0),
      8 => (-256, -161, -66, 29, 124, 219, 314, 409, others => 0),
      9 => (-256, -176, -96, -15, 65, 146, 226, 307, others => 0),
      10 => (-205, -132, -59, 14, 87, 160, 234, 307, others => 0));

   Chirp : constant array (0 .. 51) of Integer :=
     (16#00#, 16#03#, 16#0F#, 16#28#, 16#4C#, 16#6C#, 16#71#, 16#50#,
      16#25#, 16#26#, 16#4C#, 16#44#, 16#1A#, 16#32#, 16#3B#, 16#13#,
      16#37#, 16#1A#, 16#25#, 16#1F#, 16#1D#, others => 0);

   Interp_Shift : constant array (0 .. 7) of Natural :=
     (0, 3, 3, 3, 2, 2, 1, 1);

   ---------------------------------------------------------------------
   --  PHROMs (TMS6100): 16 KB each, selected by address bits 14-17
   ---------------------------------------------------------------------

   type PHROM_Data is array (0 .. 16#3FFF#) of Byte;
   PHROMs : array (PHROM_Number) of PHROM_Data := (others => (others => 0));
   Loaded : array (PHROM_Number) of Boolean := (others => False);

   procedure Load_PHROM (N : PHROM_Number; Path : String; Ok : out Boolean)
   is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      Open (F, In_File, Path);
      if Natural (Size (F)) /= PHROM_Data'Length then
         Close (F);
         return;
      end if;
      PHROM_Data'Read (Stream (F), PHROMs (N));
      Close (F);
      Loaded (N) := True;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Load_PHROM;

   function Present return Boolean is (Enabled and then Loaded (15));

   ---------------------------------------------------------------------
   --  Chip state
   ---------------------------------------------------------------------

   Address    : Natural := 0;        --  PHROM address (chip in bits 14-17)
   Load_Count : Natural := 0;        --  address nibbles loaded in a row
   Bit_Pos    : Natural := 0;        --  next bit of the PHROM byte
   Data_Reg   : Byte := 0;
   Data_Ready : Boolean := False;    --  next read returns Data_Reg

   Speaking   : Boolean := False;    --  talk status
   Ext_Mode   : Boolean := False;    --  speak external: writes go to FIFO
   Ext_Wait   : Boolean := False;    --  ... and speech has not started
   FIFO       : Byte_Array (0 .. 15) := (others => 0);
   FIFO_Head, FIFO_Count, FIFO_Bit : Natural := 0;
   Int_Line   : Boolean := False;
   Was_Low, Was_Empty : Boolean := False;

   --  Synthesis
   type K_Values is array (1 .. 10) of Float;
   Cur_E, Tgt_E, Cur_P, Tgt_P : Float := 0.0;
   Cur_K, Tgt_K : K_Values := (others => 0.0);
   Old_Silent : Boolean := True;
   Old_Voiced : Boolean := False;
   Stopping   : Boolean := False;
   IP         : Natural := 0;        --  interpolation period 0 .. 7
   IP_Sample  : Natural := 0;        --  sample within it, 0 .. 24
   Pitch_Count : Natural := 0;
   LFSR       : Unsigned_16 := 16#1FFF#;
   B          : array (0 .. 9) of Float := (others => 0.0);
   Raw_Out, Smooth : Float := 0.0;
   Cycle_Acc  : Natural := 0;

   Cycles_Per_Sample : constant := 250;     --  8 kHz from the 2 MHz clock
   Gain : constant Float := 12_000.0;

   function VSM_Byte (A : Natural) return Byte is
      Chip : constant PHROM_Number := (A / 16#4000#) mod 16;
   begin
      return (if Loaded (Chip) then PHROMs (Chip) (A mod 16#4000#) else 0);
   end VSM_Byte;

   procedure Next_Address is
   begin
      Address := (Address / 16#4000#) * 16#4000# +
        (Address mod 16#4000# + 1) mod 16#4000#;
   end Next_Address;

   --  Serial data: bits come least significant first from each byte and
   --  are assembled most significant first into each parameter
   function VSM_Bit return Natural is
      Bit : constant Natural :=
        Natural (Shift_Right (VSM_Byte (Address), Bit_Pos) and 1);
   begin
      Bit_Pos := Bit_Pos + 1;
      if Bit_Pos = 8 then
         Bit_Pos := 0;
         Next_Address;
      end if;
      return Bit;
   end VSM_Bit;

   function FIFO_Low return Boolean is (Ext_Mode and then FIFO_Count < 8);
   function FIFO_Empty return Boolean is (Ext_Mode and then FIFO_Count = 0);

   procedure Check_FIFO_Interrupts is
   begin
      if FIFO_Low and then not Was_Low then
         Int_Line := True;
      end if;
      if FIFO_Empty and then not Was_Empty then
         Int_Line := True;
      end if;
      Was_Low := FIFO_Low;
      Was_Empty := FIFO_Empty;
   end Check_FIFO_Interrupts;

   function FIFO_Bit_Get return Natural is
      Bit : Natural;
   begin
      if FIFO_Count = 0 then
         return 0;
      end if;
      Bit := Natural (Shift_Right (FIFO (FIFO_Head), FIFO_Bit) and 1);
      FIFO_Bit := FIFO_Bit + 1;
      if FIFO_Bit = 8 then
         FIFO_Bit := 0;
         FIFO_Head := (FIFO_Head + 1) mod 16;
         FIFO_Count := FIFO_Count - 1;
         Check_FIFO_Interrupts;
      end if;
      return Bit;
   end FIFO_Bit_Get;

   function Get_Bits (N : Natural) return Natural is
      V : Natural := 0;
   begin
      for I in 1 .. N loop
         V := V * 2 + (if Ext_Mode then FIFO_Bit_Get else VSM_Bit);
      end loop;
      return V;
   end Get_Bits;

   function VSM_Bits (N : Natural) return Natural is
      V : Natural := 0;
   begin
      for I in 1 .. N loop
         V := V * 2 + VSM_Bit;
      end loop;
      return V;
   end VSM_Bits;

   procedure Stop_Speaking is
   begin
      if Speaking then
         Int_Line := True;            --  talk status went low
      end if;
      Speaking := False;
      Ext_Mode := False;
      Ext_Wait := False;
      FIFO_Count := 0;
      FIFO_Head := 0;
      FIFO_Bit := 0;
      Was_Low := False;
      Was_Empty := False;
   end Stop_Speaking;

   procedure Start_Speaking is
   begin
      Speaking := True;
      Ext_Wait := False;
      Stopping := False;
      IP := 0;
      IP_Sample := 0;
      Cur_E := 0.0;
      Tgt_E := 0.0;
      Cur_P := 0.0;
      Tgt_P := 0.0;
      Cur_K := (others => 0.0);
      Tgt_K := (others => 0.0);
      Old_Silent := True;
      Old_Voiced := False;
      B := (others => 0.0);
      Pitch_Count := 0;
   end Start_Speaking;

   procedure Reset is
   begin
      Stop_Speaking;
      Int_Line := False;
      Address := 0;
      Load_Count := 0;
      Bit_Pos := 0;
      Data_Ready := False;
      Raw_Out := 0.0;
      Smooth := 0.0;
      Cycle_Acc := 0;
   end Reset;

   ---------------------------------------------------------------------
   --  CPU interface
   ---------------------------------------------------------------------

   procedure Write (Value : Byte) is
      Cmd : constant Natural := Natural (Shift_Right (Value, 4) and 7);
   begin
      if not Present then
         return;
      end if;
      if Ext_Mode then
         --  speak external: everything written goes into the FIFO
         if FIFO_Count < 16 then
            FIFO ((FIFO_Head + FIFO_Count) mod 16) := Value;
            FIFO_Count := FIFO_Count + 1;
         end if;
         Was_Low := FIFO_Low;
         Was_Empty := FIFO_Empty;
         if Ext_Wait and then FIFO_Count >= 9 then
            Start_Speaking;
         end if;
         return;
      end if;
      if Cmd /= 4 then
         Load_Count := 0;
      end if;
      case Cmd is
         when 1 =>                               --  read byte
            Data_Reg := Byte (VSM_Bits (8));
            Data_Ready := True;
         when 3 =>                               --  read and branch
            declare
               Lo : constant Natural := Natural (VSM_Byte (Address));
               Hi : Natural;
            begin
               Next_Address;
               Hi := Natural (VSM_Byte (Address));
               Address := (Address / 16#4000#) * 16#4000# +
                 (Lo + Hi * 256) mod 16#4000#;
               Bit_Pos := 0;
            end;
         when 4 =>                               --  load address nibble
            if Load_Count = 0 then
               Address := 0;
            end if;
            Address := Address +
              Natural (Value and 16#0F#) * 16 ** Load_Count;
            Load_Count := (Load_Count + 1) mod 5;
            Bit_Pos := 0;
         when 5 =>                               --  speak
            Start_Speaking;
         when 6 =>                               --  speak external
            Stop_Speaking;
            Int_Line := False;
            Ext_Mode := True;
            Ext_Wait := True;
            Was_Low := True;
            Was_Empty := True;
         when 7 =>                               --  reset
            Stop_Speaking;
            Int_Line := False;
         when others =>
            null;
      end case;
   end Write;

   function Read return Byte is
   begin
      if not Present then
         return 16#FF#;
      end if;
      if Data_Ready then
         Data_Ready := False;
         return Data_Reg;
      end if;
      Int_Line := False;
      return (if Speaking or else Ext_Wait then 16#80# else 0) or
        (if FIFO_Low then 16#40# else 0) or
        (if FIFO_Empty then 16#20# else 0);
   end Read;

   function Ready return Boolean is (Present);
   function Interrupt return Boolean is (Present and then Int_Line);
   function Talking return Boolean is (Speaking);
   function Output return Float is (Smooth * Gain);

   ---------------------------------------------------------------------
   --  Synthesis
   ---------------------------------------------------------------------

   procedure Parse_Frame is
      E : constant Natural := Get_Bits (4);
      Silent, Voiced : Boolean;
   begin
      if E = 0 then
         Tgt_E := 0.0;
         Silent := True;
         Voiced := Old_Voiced;
      elsif E = 15 then
         Tgt_E := 0.0;
         Stopping := True;
         Silent := True;
         Voiced := Old_Voiced;
      else
         declare
            Repeat : constant Boolean := Get_Bits (1) = 1;
            P : constant Natural := Get_Bits (6);
         begin
            Silent := False;
            Voiced := P /= 0;
            Tgt_E := Float (Energy_Table (E));
            Tgt_P := Float (Pitch_Table (P));
            if not Repeat then
               for I in 1 .. 4 loop
                  Tgt_K (I) := Float (K_Table (I, Get_Bits (K_Bits (I))));
               end loop;
               if Voiced then
                  for I in 5 .. 10 loop
                     Tgt_K (I) := Float (K_Table (I, Get_Bits (K_Bits (I))));
                  end loop;
               else
                  Tgt_K (5 .. 10) := (others => 0.0);
               end if;
            end if;
         end;
      end if;
      --  No interpolation into speech from silence or across a change
      --  between voiced and unvoiced: the new values apply at once
      if (Old_Silent and then not Silent)
        or else (not Silent and then not Old_Silent
                 and then Voiced /= Old_Voiced)
      then
         Cur_E := Tgt_E;
         Cur_P := Tgt_P;
         Cur_K := Tgt_K;
      end if;
      Old_Silent := Silent;
      Old_Voiced := Voiced;
   end Parse_Frame;

   procedure Interpolate (Shift : Natural) is
      D : constant Float := Float (2 ** Shift);
   begin
      Cur_E := Cur_E + (Tgt_E - Cur_E) / D;
      Cur_P := Cur_P + (Tgt_P - Cur_P) / D;
      for I in Cur_K'Range loop
         Cur_K (I) := Cur_K (I) + (Tgt_K (I) - Cur_K (I)) / D;
      end loop;
   end Interpolate;

   function Excitation return Float is
      Period : constant Natural := Natural (Cur_P);
   begin
      if Old_Voiced and then Period > 0 then
         if Pitch_Count >= Period then
            Pitch_Count := 0;
         end if;
         return R : constant Float :=
           Float (Chirp (Natural'Min (Pitch_Count, 51))) / 128.0
         do
            Pitch_Count := Pitch_Count + 1;
         end return;
      else
         declare
            Fb : constant Unsigned_16 :=
              (LFSR xor Shift_Right (LFSR, 2) xor Shift_Right (LFSR, 3)
               xor Shift_Right (LFSR, 12)) and 1;
         begin
            LFSR := Shift_Right (LFSR, 1) or Shift_Left (Fb, 12);
            return (if (LFSR and 1) /= 0 then -0.5 else 0.5);
         end;
      end if;
   end Excitation;

   procedure Step_Sample is
      F : Float;
   begin
      if not Speaking then
         Raw_Out := 0.0;
      else
         if IP_Sample = 0 then
            if IP = 0 then
               --  frame boundary: the old frame's values are reached
               Interpolate (0);
               if Stopping then
                  Stop_Speaking;
                  Raw_Out := 0.0;
                  Smooth := Smooth * 0.5;
                  return;
               end if;
               if Ext_Mode and then FIFO_Count = 0 then
                  Stop_Speaking;                  --  ran out of data
                  return;
               end if;
               Parse_Frame;
            else
               Interpolate (Interp_Shift (IP));
            end if;
         end if;
         --  ten-stage lattice filter
         F := Excitation * Cur_E / 128.0;
         --  (stage I reads the delayed B (I - 1) and leaves B (I) for the
         --  next sample; going down, each B is read before it is replaced)
         for I in reverse 1 .. 10 loop
            F := F - Cur_K (I) / 512.0 * B (I - 1);
            if I < 10 then
               B (I) := B (I - 1) + Cur_K (I) / 512.0 * F;
            end if;
         end loop;
         B (0) := F;
         Raw_Out := Float'Max (-1.0, Float'Min (1.0, F));
         IP_Sample := IP_Sample + 1;
         if IP_Sample = 25 then
            IP_Sample := 0;
            IP := (IP + 1) mod 8;
         end if;
      end if;
      Smooth := Smooth + (Raw_Out - Smooth) * 0.6;
   end Step_Sample;

   procedure Clock (Cycles : Natural) is
   begin
      if not Present then
         return;
      end if;
      Cycle_Acc := Cycle_Acc + Cycles;
      while Cycle_Acc >= Cycles_Per_Sample loop
         Cycle_Acc := Cycle_Acc - Cycles_Per_Sample;
         Step_Sample;
      end loop;
   end Clock;

end Speech;
