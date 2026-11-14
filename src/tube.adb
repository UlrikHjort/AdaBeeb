-- ***************************************************************************
--                               AdaBeeb - Tube
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
with MOS6502;

package body Tube is

   --  Status bits: data available to the reader / space for the writer
   Data_Avail  : constant Byte := 16#80#;
   Space_Avail : constant Byte := 16#40#;
   Both_Avail  : constant Byte := 16#C0#;

   Flag_Q : constant Byte := 16#01#;
   Flag_I : constant Byte := 16#02#;
   Flag_J : constant Byte := 16#04#;
   Flag_M : constant Byte := 16#08#;
   Flag_V : constant Byte := 16#10#;
   Flag_P : constant Byte := 16#20#;
   Flag_T : constant Byte := 16#40#;
   Flag_S : constant Byte := 16#80#;

   FIFO_Size : constant := 24;

   --  ULA state ("PH" = parasite to host, "HP" = host to parasite)
   PH1 : Byte_Array (0 .. FIFO_Size - 1) := (others => 0);
   PH1_Head, PH1_Tail, PH1_Count : Natural := 0;
   PH2, PH4, PH_Latch : Byte := 0;
   PH3 : Byte_Array (0 .. 1) := (others => 0);
   PH3_Pos : Natural := 1;
   HP1, HP2, HP4, HP_Latch : Byte := 0;
   HP3 : Byte_Array (0 .. 1) := (others => 0);
   HP3_Pos : Natural := 0;
   HStat, PStat : Byte_Array (0 .. 3) := (others => 0);
   Flags : Byte := 0;

   --  Parasite
   RAM : Byte_Array (0 .. 16#FFFF#) := (others => 0);
   ROM : Byte_Array (0 .. 16#07FF#) := (others => 16#FF#);
   Have_ROM : Boolean := False;
   ROM_In : Boolean := True;
   P_IRQ, P_NMI, P_NMI_Prev : Boolean := False;
   Credit : Integer := 0;            --  parasite cycles owed

   procedure Update_Interrupts is
   begin
      P_IRQ := ((Flags and Flag_I) /= 0 and then (PStat (0) and Data_Avail) /= 0)
        or else ((Flags and Flag_J) /= 0
                 and then (PStat (3) and Data_Avail) /= 0);
      P_NMI := (Flags and Flag_M) /= 0 and then (PStat (2) and Data_Avail) /= 0;
   end Update_Interrupts;

   function Host_IRQ return Boolean is
     (Enabled and then (Flags and Flag_Q) /= 0
      and then (HStat (3) and Data_Avail) /= 0);

   procedure Reset_Registers is
   begin
      PH1_Head := 0;
      PH1_Tail := 0;
      PH1_Count := 0;
      PH3_Pos := 1;
      HP3_Pos := 0;
      HStat := (Space_Avail, Space_Avail, Both_Avail, Space_Avail);
      PStat := (Space_Avail, 16#7F#, 16#3F#, 16#7F#);
   end Reset_Registers;

   function Parasite_Register_Read (Reg : Natural) return Byte;
   procedure Parasite_Register_Write (Reg : Natural; Value : Byte);

   function P_Read (Addr : Word) return Byte is
   begin
      if (Addr and 16#FFF8#) = 16#FEF8# then
         return Parasite_Register_Read (Natural (Addr and 7));
      elsif ROM_In and then Addr >= 16#F000# then
         return ROM (Natural (Addr and 16#07FF#));
      end if;
      return RAM (Natural (Addr));
   end P_Read;

   procedure P_Write (Addr : Word; Value : Byte) is
   begin
      if (Addr and 16#FFF8#) = 16#FEF8# then
         Parasite_Register_Write (Natural (Addr and 7), Value);
      else
         RAM (Natural (Addr)) := Value;
      end if;
   end P_Write;

   package CPU is new MOS6502 (Read => P_Read, Write => P_Write);

   procedure Reset_Parasite is
   begin
      ROM_In := True;
      CPU.CMOS := True;           --  the Second Processor's 65C02
      CPU.Reset;
      Credit := 0;
      P_NMI_Prev := False;
   end Reset_Parasite;

   procedure Reset is
   begin
      Reset_Registers;
      Flags := 0;
      Update_Interrupts;
      Reset_Parasite;
   end Reset;

   procedure Load_ROM (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      Open (F, In_File, Path);
      if Natural (Size (F)) /= ROM'Length then
         Close (F);
         return;
      end if;
      Byte_Array'Read (Stream (F), ROM);
      Close (F);
      Have_ROM := True;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Load_ROM;

   function ROM_Loaded return Boolean is (Have_ROM);

   ---------------------------------------------------------------------
   --  Host side (&FEE0-&FEE7)
   ---------------------------------------------------------------------

   function Host_Read (Reg : Natural) return Byte is
      V : Byte := 0;
   begin
      case Reg mod 8 is
         when 0 => V := (HStat (0) and Both_Avail) or Flags;
         when 1 =>
            if PH1_Count > 0 then
               V := PH1 (PH1_Head);
               PH1_Head := (PH1_Head + 1) mod FIFO_Size;
               PH1_Count := PH1_Count - 1;
               if PH1_Count = 0 then
                  HStat (0) := HStat (0) and not Data_Avail;
               end if;
               PStat (0) := PStat (0) or Space_Avail;
            else
               V := PH_Latch;
            end if;
         when 2 => V := HStat (1);
         when 3 =>
            V := PH2;
            HStat (1) := HStat (1) and not Data_Avail;
            PStat (1) := PStat (1) or Space_Avail;
         when 4 => V := HStat (2);
         when 5 =>
            if PH3_Pos > 0 then
               V := PH3 (0);
               PH3 (0) := PH3 (1);
               PH3_Pos := PH3_Pos - 1;
               if PH3_Pos = 0 then
                  HStat (2) := HStat (2) and not Data_Avail;
                  PStat (2) := PStat (2) or Both_Avail;
               end if;
            else
               V := PH_Latch;
            end if;
         when 6 => V := HStat (3);
         when others =>
            V := PH4;
            HStat (3) := HStat (3) and not Data_Avail;
            PStat (3) := PStat (3) or Space_Avail;
      end case;
      Update_Interrupts;
      return V;
   end Host_Read;

   procedure Host_Write (Reg : Natural; Value : Byte) is
   begin
      HP_Latch := Value;
      case Reg mod 8 is
         when 0 =>
            if (Value and Flag_S) /= 0 then
               if (Value and Flag_T) /= 0 and then (Flags and Flag_T) = 0 then
                  Reset_Registers;
               end if;
               Flags := Flags or (Value and 16#3F#);
            else
               if (Value and Flag_P) = 0 and then (Flags and Flag_P) /= 0 then
                  Reset_Parasite;
               end if;
               Flags := Flags and not (Value and 16#3F#);
            end if;
            HStat (0) := (HStat (0) and Both_Avail) or (Value and 16#3F#);
         when 1 =>
            HP1 := Value;
            PStat (0) := PStat (0) or Data_Avail;
            HStat (0) := HStat (0) and not Space_Avail;
         when 3 =>
            HP2 := Value;
            PStat (1) := PStat (1) or Data_Avail;
            HStat (1) := HStat (1) and not Space_Avail;
         when 5 =>
            if HP3_Pos < 2 then
               HP3 (HP3_Pos) := Value;
               HP3_Pos := HP3_Pos + 1;
               if HP3_Pos >= (if (Flags and Flag_V) /= 0 then 2 else 1) then
                  PStat (2) := PStat (2) or Data_Avail;
                  HStat (2) := HStat (2) and not Space_Avail;
               end if;
            end if;
         when 7 =>
            HP4 := Value;
            PStat (3) := PStat (3) or Data_Avail;
            HStat (3) := HStat (3) and not Space_Avail;
         when others => null;
      end case;
      Update_Interrupts;
   end Host_Write;

   ---------------------------------------------------------------------
   --  Parasite side (&FEF8-&FEFF)
   ---------------------------------------------------------------------

   function Parasite_Register_Read (Reg : Natural) return Byte is
      V : Byte := 0;
   begin
      case Reg is
         when 0 =>
            ROM_In := False;        --  the boot ROM pages itself out
            V := PStat (0) or Flags;
         when 1 =>
            V := HP1;
            PStat (0) := PStat (0) and not Data_Avail;
            HStat (0) := HStat (0) or Space_Avail;
         when 2 => V := PStat (1);
         when 3 =>
            V := HP2;
            PStat (1) := PStat (1) and not Data_Avail;
            HStat (1) := HStat (1) or Space_Avail;
         when 4 => V := PStat (2);
         when 5 =>
            if HP3_Pos > 0 then
               V := HP3 (0);
               HP3 (0) := HP3 (1);
               HP3_Pos := HP3_Pos - 1;
               if HP3_Pos = 0 then
                  HStat (2) := HStat (2) or Space_Avail;
                  PStat (2) := PStat (2) and not Data_Avail;
               end if;
            else
               V := HP_Latch;
            end if;
         when 6 => V := PStat (3);
         when others =>
            V := HP4;
            PStat (3) := PStat (3) and not Data_Avail;
            HStat (3) := HStat (3) or Space_Avail;
      end case;
      Update_Interrupts;
      return V;
   end Parasite_Register_Read;

   procedure Parasite_Register_Write (Reg : Natural; Value : Byte) is
   begin
      PH_Latch := Value;
      case Reg is
         when 1 =>
            if PH1_Count < FIFO_Size then
               PH1 (PH1_Tail) := Value;
               PH1_Tail := (PH1_Tail + 1) mod FIFO_Size;
               PH1_Count := PH1_Count + 1;
               HStat (0) := HStat (0) or Data_Avail;
               if PH1_Count = FIFO_Size then
                  PStat (0) := PStat (0) and not Space_Avail;
               end if;
            end if;
         when 3 =>
            PH2 := Value;
            HStat (1) := HStat (1) or Data_Avail;
            PStat (1) := PStat (1) and not Space_Avail;
         when 5 =>
            if PH3_Pos < 2 then
               PH3 (PH3_Pos) := Value;
               PH3_Pos := PH3_Pos + 1;
               if PH3_Pos >= (if (Flags and Flag_V) /= 0 then 2 else 1) then
                  HStat (2) := HStat (2) or Data_Avail;
                  PStat (2) := PStat (2) and not Both_Avail;
               end if;
            end if;
         when 7 =>
            PH4 := Value;
            HStat (3) := HStat (3) or Data_Avail;
            PStat (3) := PStat (3) and not Space_Avail;
         when others => null;
      end case;
      Update_Interrupts;
   end Parasite_Register_Write;

   ---------------------------------------------------------------------
   --  Running the parasite: 3 MHz, i.e. 3 cycles per 2 host cycles
   ---------------------------------------------------------------------

   procedure Run (Host_Cycles : Natural) is
      N : Natural;
   begin
      if not Enabled or else not Have_ROM then
         return;
      end if;
      Credit := Credit + Host_Cycles * 3;
      while Credit > 0 loop
         CPU.IRQ_Line := P_IRQ;
         if P_NMI and then not P_NMI_Prev then
            CPU.NMI_Pending := True;
         end if;
         P_NMI_Prev := P_NMI;
         CPU.Step (N);
         Credit := Credit - Integer (N) * 2;
      end loop;
   end Run;

   function Parasite_PC return Word is (CPU.PC);
   function Parasite_Peek (Addr : Word) return Byte is
     (if ROM_In and then Addr >= 16#F000# then ROM (Natural (Addr and 16#07FF#))
      else RAM (Natural (Addr)));

   procedure Parasite_Poke (Addr : Word; Value : Byte) is
   begin
      RAM (Natural (Addr)) := Value;
   end Parasite_Poke;

end Tube;
