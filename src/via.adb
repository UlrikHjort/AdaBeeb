-- ***************************************************************************
--                               AdaBeeb - VIA
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

package body VIA is

   procedure Write_Reg (V : in out Chip; Reg : Natural; Value : Byte);

   procedure Reset (V : in out Chip) is
   begin
      V := (others => <>);
   end Reset;

   --  One phi2 (1 MHz) cycle.  A counter write takes effect on the next
   --  cycle (load), then the counter decrements; it signals on the
   --  transition 0 -> FFFF.  In free-run mode timer 1 then reloads from
   --  the latch on the following cycle (period N + 2).
   procedure Tick_One (V : in out Chip) is
   begin
      if V.T1_Load then
         V.T1_Counter := V.T1_Latch;
         V.T1_Load := False;
         if V.T1_Expired and then (V.ACR and 16#40#) = 0 then
            V.T1_Armed := False;   --  one-shot by the reload: disarm too
         end if;
         V.T1_Expired := False;
      elsif V.T1_Counter = 0 then
         V.T1_Counter := 16#FFFF#;
         V.T1_Load := True;          --  reloads in both modes
         if V.T1_Armed then
            V.IFR := V.IFR or IFR_T1;
            V.T1_Expired := True;
            if (V.ACR and 16#40#) /= 0 then
               V.PB7 := not V.PB7;    --  free run: stays armed
            else
               V.PB7 := True;
               V.T1_Armed := False;
            end if;
         end if;
      else
         V.T1_Counter := V.T1_Counter - 1;
      end if;

      if V.T2_Load then
         V.T2_Load := False;
      elsif (V.ACR and 16#20#) = 0 then
         if V.T2_Counter = 0 then
            V.T2_Counter := 16#FFFF#;
            if V.T2_Armed then
               V.IFR := V.IFR or IFR_T2;
               V.T2_Armed := False;
            end if;
         else
            V.T2_Counter := V.T2_Counter - 1;
         end if;
      end if;
   end Tick_One;

   procedure Tick (V : in out Chip; Cycles : Natural) is
   begin
      for I in 1 .. Cycles loop
         Tick_One (V);
         --  a counter read in this cycle also clears a flag set by the
         --  clock edge that ends it
         if V.Clear_Pending /= 0 then
            V.IFR := V.IFR and not V.Clear_Pending;
            V.Clear_Pending := 0;
         end if;
      end loop;
   end Tick;

   procedure Count_PB6 (V : in out Chip) is
      Pins : constant Byte :=
        (V.ORB and V.DDRB) or (V.Port_B_In and not V.DDRB);
      Level : constant Boolean := (Pins and 16#40#) /= 0;
   begin
      if (V.ACR and 16#20#) /= 0 and then V.PB6_Prev and then not Level then
         if V.T2_Counter = 0 then
            V.T2_Counter := 16#FFFF#;
         else
            V.T2_Counter := V.T2_Counter - 1;
            if V.T2_Counter = 0 and then V.T2_Armed then
               V.IFR := V.IFR or IFR_T2;
               V.T2_Armed := False;
            end if;
         end if;
      end if;
      V.PB6_Prev := Level;
   end Count_PB6;

   function Read (V : in out Chip; Reg : Natural) return Byte is
   begin
      case Reg mod 16 is
         when 0 =>
            V.IFR := V.IFR and not
              (if (V.PCR and 16#A0#) = 16#20# then IFR_CB1
               else IFR_CB1 or IFR_CB2);
            declare
               R : Byte := (V.ORB and V.DDRB) or (V.Port_B_In and not V.DDRB);
            begin
               if (V.ACR and 16#80#) /= 0 then
                  R := (R and 16#7F#) or (if V.PB7 then 16#80# else 0);
               end if;
               return R;
            end;
         when 1 =>
            V.IFR := V.IFR and not
              (if (V.PCR and 16#0A#) = 16#02# then IFR_CA1
               else IFR_CA1 or IFR_CA2);
            return (V.ORA and V.DDRA) or (V.Port_A_In and not V.DDRA);
         when 15 =>
            return (V.ORA and V.DDRA) or (V.Port_A_In and not V.DDRA);
         when 2 => return V.DDRB;
         when 3 => return V.DDRA;
         when 4 =>
            --  A read in the 1 MHz cycle that timer 1 timed out in does
            --  not clear its flag: setting it wins (b2's TIMINGS test,
            --  recorded on a real BBC)
            if not V.T1_Expired then
               V.IFR := V.IFR and not IFR_T1;
            end if;
            return Byte (V.T1_Counter mod 256);
         when 5 => return Byte ((V.T1_Counter / 256) mod 256);
         when 6 => return Byte (V.T1_Latch mod 256);
         when 7 => return Byte ((V.T1_Latch / 256) mod 256);
         when 8 =>
            V.IFR := V.IFR and not IFR_T2;
            return Byte (V.T2_Counter mod 256);
         when 9 => return Byte ((V.T2_Counter / 256) mod 256);
         when 10 =>
            V.IFR := V.IFR and not IFR_SR;
            return V.SR;
         when 11 => return V.ACR;
         when 12 => return V.PCR;
         when 13 =>
            return V.IFR or (if IRQ (V) then 16#80# else 0);
         when others =>
            return V.IER or 16#80#;
      end case;
   end Read;

   procedure Write (V : in out Chip; Reg : Natural; Value : Byte) is
   begin
      Write_Reg (V, Reg, Value);
      if Reg mod 16 in 0 | 2 then
         Count_PB6 (V);              --  PB6 may have changed level
      end if;
   end Write;

   procedure Write_Reg (V : in out Chip; Reg : Natural; Value : Byte) is
   begin
      case Reg mod 16 is
         when 0 =>
            V.ORB := Value;
            V.IFR := V.IFR and not
              (if (V.PCR and 16#A0#) = 16#20# then IFR_CB1
               else IFR_CB1 or IFR_CB2);
         when 1 =>
            V.ORA := Value;
            V.IFR := V.IFR and not
              (if (V.PCR and 16#0A#) = 16#02# then IFR_CA1
               else IFR_CA1 or IFR_CA2);
         when 15 => V.ORA := Value;
         when 2 => V.DDRB := Value;
         when 3 => V.DDRA := Value;
         when 4 | 6 =>
            V.T1_Latch := (V.T1_Latch / 256) * 256 + Integer (Value);
         when 5 =>
            V.T1_Latch := Integer (Value) * 256 + V.T1_Latch mod 256;
            V.T1_Load := True;
            V.T1_Expired := False;
            V.IFR := V.IFR and not IFR_T1;
            V.T1_Armed := True;
            V.PB7 := False;
         when 7 =>
            V.T1_Latch := Integer (Value) * 256 + V.T1_Latch mod 256;
            V.IFR := V.IFR and not IFR_T1;
         when 8 =>
            V.T2_Latch_Lo := Value;
         when 9 =>
            V.T2_Counter := Integer (Value) * 256 + Integer (V.T2_Latch_Lo);
            V.T2_Load := True;
            V.IFR := V.IFR and not IFR_T2;
            V.T2_Armed := True;
         when 10 =>
            V.SR := Value;
            V.IFR := V.IFR and not IFR_SR;
         when 11 => V.ACR := Value;
         when 12 => V.PCR := Value;
         when 13 =>
            V.IFR := V.IFR and not (Value and 16#7F#);
         when others =>
            if (Value and 16#80#) /= 0 then
               V.IER := V.IER or (Value and 16#7F#);
            else
               V.IER := V.IER and not (Value and 16#7F#);
            end if;
      end case;
   end Write_Reg;

   procedure Set_CA1 (V : in out Chip; Level : Boolean) is
      Positive_Edge : constant Boolean := (V.PCR and 1) /= 0;
   begin
      if Level /= V.CA1 then
         if Level = Positive_Edge then
            V.IFR := V.IFR or IFR_CA1;
         end if;
         V.CA1 := Level;
      end if;
   end Set_CA1;

   procedure Set_CA2 (V : in out Chip; Level : Boolean) is
   begin
      if Level /= V.CA2 then
         if (V.PCR and 16#08#) = 0
           and then Level = ((V.PCR and 16#04#) /= 0)
         then
            V.IFR := V.IFR or IFR_CA2;
         end if;
         V.CA2 := Level;
      end if;
   end Set_CA2;

   procedure Set_CB1 (V : in out Chip; Level : Boolean) is
   begin
      if Level /= V.CB1 then
         if Level = ((V.PCR and 16#10#) /= 0) then
            V.IFR := V.IFR or IFR_CB1;
         end if;
         V.CB1 := Level;
      end if;
   end Set_CB1;

   procedure Set_CB2 (V : in out Chip; Level : Boolean) is
   begin
      if Level /= V.CB2 then
         if (V.PCR and 16#80#) = 0
           and then Level = ((V.PCR and 16#40#) /= 0)
         then
            V.IFR := V.IFR or IFR_CB2;
         end if;
         V.CB2 := Level;
      end if;
   end Set_CB2;

   function CA2_High (V : Chip) return Boolean is
     (if (V.PCR and 16#0C#) = 16#0C# then (V.PCR and 16#02#) /= 0 else True);

   function CB2_High (V : Chip) return Boolean is
     (if (V.PCR and 16#C0#) = 16#C0# then (V.PCR and 16#20#) /= 0 else True);

end VIA;
