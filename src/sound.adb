-- ***************************************************************************
--                              AdaBeeb - Sound
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

package body Sound is
   pragma Suppress (All_Checks);

   type Nat_Array is array (Channel_Index) of Natural;

   Periods  : Nat_Array := (others => 1023);
   Volumes  : Nat_Array := (others => 15);
   Counters : Nat_Array := (others => 0);
   Outputs  : array (Channel_Index) of Boolean := (others => False);
   Noise_Reg : Natural := 0;
   LFSR      : Unsigned_16 := 16#4000#;
   Latched   : Natural := 0;           --  register 0 .. 7 (channel*2 + vol)

   CPU_Hz : Natural := 2_000_000;

   --  250 kHz chip ticks per CPU cycle: one every 8 cycles at 2 MHz
   Prescale : Natural := 0;

   --  Sample generation: box filter over the chip ticks of one sample
   Tick_Acc   : Integer := 0;     --  sum of outputs during this sample
   Tick_Count : Natural := 0;
   Phase      : Natural := 0;     --  in units of 1 / Sample_Rate ticks
   DC         : Float := 0.0;     --  DC blocker state

   --  2 dB per attenuation step, 15 = silent
   Vol_Table : constant array (0 .. 15) of Integer :=
     (8191, 6506, 5168, 4105, 3261, 2590, 2057, 1634,
      1298, 1031, 819, 650, 517, 410, 326, 0);

   procedure Reset is
   begin
      Periods := (others => 1023);
      Volumes := (others => 15);
      Counters := (others => 0);
      Outputs := (others => False);
      Noise_Reg := 0;
      LFSR := 16#4000#;
      Latched := 0;
      Prescale := 0;
      Tick_Acc := 0;
      Tick_Count := 0;
      Phase := 0;
      DC := 0.0;
   end Reset;

   procedure Set_Clock (Hz : Natural) is
   begin
      CPU_Hz := Hz;
   end Set_Clock;

   procedure Write (Value : Byte) is
      Reg  : Natural;
      Data : constant Natural := Natural (Value and 16#0F#);
   begin
      if (Value and 16#80#) /= 0 then
         Latched := Natural (Shift_Right (Value, 4) and 7);
         Reg := Latched;
         if Reg mod 2 = 1 then
            Volumes (Channel_Index (Reg / 2)) := Data;
         elsif Reg = 6 then
            Noise_Reg := Data mod 8;
            LFSR := 16#4000#;
         else
            Periods (Channel_Index (Reg / 2)) :=
              (Periods (Channel_Index (Reg / 2)) / 16) * 16 + Data;
         end if;
      else
         Reg := Latched;
         if Reg mod 2 = 1 then
            Volumes (Channel_Index (Reg / 2)) := Data;
         elsif Reg = 6 then
            Noise_Reg := Data mod 8;
            LFSR := 16#4000#;
         else
            Periods (Channel_Index (Reg / 2)) :=
              Periods (Channel_Index (Reg / 2)) mod 16 +
              Natural (Value and 16#3F#) * 16;
         end if;
      end if;
   end Write;

   function Tone_Period (C : Channel_Index) return Natural is
     (if Periods (C) = 0 then 1024 else Periods (C));

   procedure Chip_Tick is
      Level : Integer := 0;
      Noise_Period : Natural;
      Fb : Unsigned_16;
   begin
      for C in Channel_Index range 0 .. 2 loop
         if Counters (C) = 0 then
            Counters (C) := Tone_Period (C);
            Outputs (C) := not Outputs (C);
            if C = 2 and then Noise_Reg mod 4 = 3 then
               --  noise clocked by channel 2's output (rising edge)
               if Outputs (C) then
                  Fb := (if Noise_Reg >= 4
                         then (LFSR xor Shift_Right (LFSR, 1)) and 1
                         else LFSR and 1);
                  LFSR := Shift_Right (LFSR, 1) or Shift_Left (Fb, 14);
               end if;
            end if;
         end if;
         Counters (C) := Counters (C) - 1;
      end loop;

      if Noise_Reg mod 4 /= 3 then
         if Counters (3) = 0 then
            Noise_Period := 16 * 2 ** (Noise_Reg mod 4);
            Counters (3) := Noise_Period;
            Outputs (3) := not Outputs (3);
            if Outputs (3) then
               Fb := (if Noise_Reg >= 4
                      then (LFSR xor Shift_Right (LFSR, 1)) and 1
                      else LFSR and 1);
               LFSR := Shift_Right (LFSR, 1) or Shift_Left (Fb, 14);
            end if;
         end if;
         Counters (3) := Counters (3) - 1;
      end if;

      for C in Channel_Index range 0 .. 2 loop
         if Outputs (C) or else Periods (C) = 1 then
            --  period 1 toggles at 125 kHz: an effectively constant level
            --  (used for sampled sound through the volume register)
            Level := Level + Vol_Table (Volumes (C));
         end if;
      end loop;
      if (LFSR and 1) /= 0 then
         Level := Level + Vol_Table (Volumes (3));
      end if;
      Tick_Acc := Tick_Acc + Level;
      Tick_Count := Tick_Count + 1;
   end Chip_Tick;

   Chip_Hz : constant := 250_000;

   procedure Clock (Cycles : Natural) is
      Div : constant Natural := Natural'Max (1, CPU_Hz / Chip_Hz);
   begin
      for I in 1 .. Cycles loop
         Prescale := Prescale + 1;
         if Prescale >= Div then
            Prescale := 0;
            Chip_Tick;
            Phase := Phase + Sample_Rate;
            if Phase >= Chip_Hz then
               Phase := Phase - Chip_Hz;
               declare
                  Avg : constant Float :=
                    Float (Tick_Acc) / Float (Natural'Max (1, Tick_Count));
                  Out_V : Float;
               begin
                  DC := DC + (Avg - DC) * 0.0015;
                  Out_V := (Avg - DC) * 1.2;
                  Out_V := Float'Max (-32767.0, Float'Min (32767.0, Out_V));
                  if Sink /= null then
                     Sink (Sample (Integer (Out_V)));
                  end if;
               end;
               Tick_Acc := 0;
               Tick_Count := 0;
            end if;
         end if;
      end loop;
   end Clock;

   function Period (C : Channel_Index) return Natural is (Periods (C));
   function Attenuation (C : Channel_Index) return Natural is (Volumes (C));
   function Noise_Control return Natural is (Noise_Reg);

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      for C in Channel_Index loop
         Natural'Write (S, Periods (C));
         Natural'Write (S, Volumes (C));
         Natural'Write (S, Counters (C));
         Boolean'Write (S, Outputs (C));
      end loop;
      Natural'Write (S, Noise_Reg);
      Unsigned_16'Write (S, LFSR);
      Natural'Write (S, Latched);
   end Save_State;

   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      for C in Channel_Index loop
         Natural'Read (S, Periods (C));
         Natural'Read (S, Volumes (C));
         Natural'Read (S, Counters (C));
         Boolean'Read (S, Outputs (C));
      end loop;
      Natural'Read (S, Noise_Reg);
      Unsigned_16'Read (S, LFSR);
      Natural'Read (S, Latched);
   end Load_State;

end Sound;
