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
with Z80;

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
   ROM : Byte_Array (0 .. 16#0FFF#) := (others => 16#FF#);
   Have_ROM : Boolean := False;
   ROM_In : Boolean := True;
   P_IRQ, P_NMI, P_NMI_Prev : Boolean := False;
   Credit : Integer := 0;            --  parasite cycles owed
   Is_Halted : Boolean := False;     --  stopped by a debugger hook
   Skip_Before : Boolean := False;

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
      if On_Access /= null then
         On_Access (Addr, False);
      end if;
      if (Addr and 16#FFF8#) = 16#FEF8# then
         return Parasite_Register_Read (Natural (Addr and 7));
      elsif ROM_In and then Addr >= 16#F000# then
         return ROM (Natural (Addr and 16#07FF#));
      end if;
      return RAM (Natural (Addr));
   end P_Read;

   procedure P_Write (Addr : Word; Value : Byte) is
   begin
      if On_Access /= null then
         On_Access (Addr, True);
      end if;
      if (Addr and 16#FFF8#) = 16#FEF8# then
         Parasite_Register_Write (Natural (Addr and 7), Value);
      else
         RAM (Natural (Addr)) := Value;
      end if;
   end P_Write;

   package CPU is new MOS6502 (Read => P_Read, Write => P_Write);

   --  The Z80 parasite
   function Z_Read (Addr : Word) return Byte is
     (if ROM_In and then Addr < 16#1000# then ROM (Natural (Addr))
      else RAM (Natural (Addr)));

   procedure Z_Write (Addr : Word; Value : Byte) is
   begin
      RAM (Natural (Addr)) := Value;
   end Z_Write;

   function Z_In (Port : Word) return Byte is
     (Parasite_Register_Read (Natural (Port and 7)));

   procedure Z_Out (Port : Word; Value : Byte) is
   begin
      Parasite_Register_Write (Natural (Port and 7), Value);
   end Z_Out;

   procedure Z_Fetch (Addr : Word) is
   begin
      if Addr >= 16#8000# then
         ROM_In := False;          --  the boot ROM pages itself out
      end if;
   end Z_Fetch;

   package ZCPU is new Z80 (Read => Z_Read, Write => Z_Write,
                            In_Port => Z_In, Out_Port => Z_Out,
                            Fetch_Hook => Z_Fetch);

   procedure Reset_Parasite is
   begin
      ROM_In := True;
      if Kind = CPU_Z80 then
         ZCPU.Reset;
         ZCPU.Ack_Byte := 16#FE#;   --  mode 2 vector at I * 256 + &FE
      else
         CPU.CMOS := True;        --  the Second Processor's 65C02
         CPU.Reset;
      end if;
      Credit := 0;
      P_NMI_Prev := False;
      Is_Halted := False;
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
      Have_ROM := False;
      Open (F, In_File, Path);
      declare
         Len : constant Natural := (if Kind = CPU_Z80 then 4096 else 2048);
      begin
         if Natural (Size (F)) /= Len then
            Close (F);
            return;
         end if;
         ROM := (others => 16#FF#);
         Byte_Array'Read (Stream (F), ROM (0 .. Len - 1));
      end;
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
            if Kind = CPU_6502 then
               ROM_In := False;     --  the boot ROM pages itself out
            end if;
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
      if Is_Halted then
         return;
      end if;
      if Kind = CPU_Z80 then
         --  6 MHz: three T-states per 2 MHz host cycle
         Credit := Credit + Host_Cycles * 3;
         while Credit > 0 loop
            ZCPU.INT_Line := P_IRQ;
            if P_NMI and then not P_NMI_Prev then
               ZCPU.NMI_Pending := True;
               ROM_In := True;     --  an NMI pages the ROM in: its &0066
            end if;                --  jumps to the handler at &FC61
            P_NMI_Prev := P_NMI;
            ZCPU.Step (N);
            Credit := Credit - Integer (N);
         end loop;
         return;
      end if;
      Credit := Credit + Host_Cycles * 3;
      while Credit > 0 loop
         if Before /= null then
            if not Skip_Before and then Before (CPU.PC, CPU.SP) then
               Is_Halted := True;
               Credit := 0;
               return;
            end if;
            Skip_Before := False;
         end if;
         CPU.IRQ_Line := P_IRQ;
         if P_NMI and then not P_NMI_Prev then
            CPU.NMI_Pending := True;
         end if;
         P_NMI_Prev := P_NMI;
         if After /= null then
            declare
               Op : constant Byte := Parasite_Peek (CPU.PC);
            begin
               CPU.Step (N);
               Credit := Credit - Integer (N) * 2;
               if After (Op) then
                  Is_Halted := True;
                  Credit := 0;
                  return;
               end if;
            end;
         else
            CPU.Step (N);
            Credit := Credit - Integer (N) * 2;
         end if;
      end loop;
   end Run;

   function Halted return Boolean is (Is_Halted);

   procedure Resume is
   begin
      if Is_Halted then
         Is_Halted := False;
         Skip_Before := True;
      end if;
   end Resume;

   function Parasite_A return Byte is (CPU.A);
   function Parasite_X return Byte is (CPU.X);
   function Parasite_Y return Byte is (CPU.Y);
   function Parasite_SP return Byte is (CPU.SP);
   function Parasite_P return Byte is (CPU.Get_P);

   procedure Set_Parasite_PC (Addr : Word) is
   begin
      CPU.PC := Addr;
   end Set_Parasite_PC;

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   procedure Save_State (S : access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte_Array'Write (S, PH1);
      Natural'Write (S, PH1_Head);
      Natural'Write (S, PH1_Tail);
      Natural'Write (S, PH1_Count);
      Byte'Write (S, PH2);
      Byte'Write (S, PH4);
      Byte'Write (S, PH_Latch);
      Byte_Array'Write (S, PH3);
      Natural'Write (S, PH3_Pos);
      Byte'Write (S, HP1);
      Byte'Write (S, HP2);
      Byte'Write (S, HP4);
      Byte'Write (S, HP_Latch);
      Byte_Array'Write (S, HP3);
      Natural'Write (S, HP3_Pos);
      Byte_Array'Write (S, HStat);
      Byte_Array'Write (S, PStat);
      Byte'Write (S, Flags);
      Byte_Array'Write (S, RAM);
      Boolean'Write (S, ROM_In);
      Boolean'Write (S, P_NMI_Prev);
      Integer'Write (S, Credit);
      Byte'Write (S, CPU.A);
      Byte'Write (S, CPU.X);
      Byte'Write (S, CPU.Y);
      Byte'Write (S, CPU.SP);
      Word'Write (S, CPU.PC);
      Byte'Write (S, CPU.Get_P);
      Boolean'Write (S, CPU.NMI_Pending);
      if Kind = CPU_Z80 then
         Byte_Array'Write (S, (ZCPU.A, ZCPU.F, ZCPU.B, ZCPU.C, ZCPU.D,
                               ZCPU.E, ZCPU.H, ZCPU.L, ZCPU.A2, ZCPU.F2,
                               ZCPU.B2, ZCPU.C2, ZCPU.D2, ZCPU.E2, ZCPU.H2,
                               ZCPU.L2, ZCPU.I, ZCPU.R));
         Word'Write (S, ZCPU.IX);
         Word'Write (S, ZCPU.IY);
         Word'Write (S, ZCPU.SP);
         Word'Write (S, ZCPU.PC);
         Boolean'Write (S, ZCPU.IFF1);
         Boolean'Write (S, ZCPU.IFF2);
         Natural'Write (S, ZCPU.IM);
         Boolean'Write (S, ZCPU.Halted);
         Boolean'Write (S, ZCPU.NMI_Pending);
      end if;
   end Save_State;

   procedure Load_State (S : access Ada.Streams.Root_Stream_Type'Class) is
      P : Byte;
   begin
      Byte_Array'Read (S, PH1);
      Natural'Read (S, PH1_Head);
      Natural'Read (S, PH1_Tail);
      Natural'Read (S, PH1_Count);
      Byte'Read (S, PH2);
      Byte'Read (S, PH4);
      Byte'Read (S, PH_Latch);
      Byte_Array'Read (S, PH3);
      Natural'Read (S, PH3_Pos);
      Byte'Read (S, HP1);
      Byte'Read (S, HP2);
      Byte'Read (S, HP4);
      Byte'Read (S, HP_Latch);
      Byte_Array'Read (S, HP3);
      Natural'Read (S, HP3_Pos);
      Byte_Array'Read (S, HStat);
      Byte_Array'Read (S, PStat);
      Byte'Read (S, Flags);
      Byte_Array'Read (S, RAM);
      Boolean'Read (S, ROM_In);
      Boolean'Read (S, P_NMI_Prev);
      Integer'Read (S, Credit);
      Byte'Read (S, CPU.A);
      Byte'Read (S, CPU.X);
      Byte'Read (S, CPU.Y);
      Byte'Read (S, CPU.SP);
      Word'Read (S, CPU.PC);
      Byte'Read (S, P);
      CPU.Set_P (P);
      Boolean'Read (S, CPU.NMI_Pending);
      CPU.CMOS := True;
      CPU.Jammed := False;
      if Kind = CPU_Z80 then
         declare
            Regs : Byte_Array (0 .. 17);
            M : Natural;
         begin
            Byte_Array'Read (S, Regs);
            ZCPU.A := Regs (0);  ZCPU.F := Regs (1);  ZCPU.B := Regs (2);
            ZCPU.C := Regs (3);  ZCPU.D := Regs (4);  ZCPU.E := Regs (5);
            ZCPU.H := Regs (6);  ZCPU.L := Regs (7);  ZCPU.A2 := Regs (8);
            ZCPU.F2 := Regs (9); ZCPU.B2 := Regs (10); ZCPU.C2 := Regs (11);
            ZCPU.D2 := Regs (12); ZCPU.E2 := Regs (13); ZCPU.H2 := Regs (14);
            ZCPU.L2 := Regs (15); ZCPU.I := Regs (16); ZCPU.R := Regs (17);
            Word'Read (S, ZCPU.IX);
            Word'Read (S, ZCPU.IY);
            Word'Read (S, ZCPU.SP);
            Word'Read (S, ZCPU.PC);
            Boolean'Read (S, ZCPU.IFF1);
            Boolean'Read (S, ZCPU.IFF2);
            Natural'Read (S, M);
            ZCPU.IM := M mod 3;
            Boolean'Read (S, ZCPU.Halted);
            Boolean'Read (S, ZCPU.NMI_Pending);
         end;
      end if;
      Update_Interrupts;
   end Load_State;

   function Parasite_PC return Word is
     (if Kind = CPU_Z80 then ZCPU.PC else CPU.PC);
   function Parasite_Peek (Addr : Word) return Byte is
     (if Kind = CPU_Z80 then Z_Read (Addr)
      elsif ROM_In and then Addr >= 16#F000#
      then ROM (Natural (Addr and 16#07FF#))
      else RAM (Natural (Addr)));

   procedure Parasite_Poke (Addr : Word; Value : Byte) is
   begin
      RAM (Natural (Addr)) := Value;
   end Parasite_Poke;

end Tube;
