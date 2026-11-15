-- ***************************************************************************
--                             AdaBeeb - Machine
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
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Directories;
with Ada.Characters.Handling;
with Interfaces; use Interfaces;

with MOS6502;
with VIA;
with Display;
with Sound;
with Keyboard;
with Disasm;
with Teletext_Font;
with FDC8271;
with WD1770;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Environment_Variables;
with Disc_Image;
with Tape;
with Tube;
with Speech;
with Asm;
with Basic;

package body Machine is

   ---------------------------------------------------------------------
   --  Memory
   ---------------------------------------------------------------------

   RAM : Byte_Array (0 .. 16#FFFF#) := (others => 0);
   OS  : Byte_Array (0 .. 16#3FFF#) := (others => 16#FF#);

   type ROM_Bank is array (0 .. 16#3FFF#) of Byte;
   type Bank_Set is array (0 .. 15) of ROM_Bank;
   type Bank_Set_Access is access Bank_Set;
   Banks : constant Bank_Set_Access := new Bank_Set'(others =>
                                                     (others => 16#FF#));
   Bank_Is_RAM : array (0 .. 15) of Boolean := (others => False);
   Bank_Used   : array (0 .. 15) of Boolean := (others => False);
   ROMSEL : Natural := 15;

   Current_Model : Model_Type := Model_B;
   function Master return Boolean is (Current_Model = Master_128);
   function B_Plus return Boolean is (Current_Model = Model_B_Plus);
   function Has_1770 return Boolean is (Current_Model /= Model_B);

   --  Master 128 paging: RAM (16#8000# .. 16#8FFF#) is ANDY (ROMSEL bit 7),
   --  RAM (16#9000# .. 16#AFFF#) is HAZEL (ACCCON bit 3, at &C000) and
   --  RAM (16#B000# .. 16#FFFF#) is the LYNNE shadow of &3000-&7FFF.
   ACCCON : Byte := 0;
   ANDY   : Boolean := False;
   Instr_PC : Word := 0;      --  address of the executing instruction

   --  CMOS RAM / real-time clock (HD146818)
   CMOS : Byte_Array (0 .. 63) := (others => 0);
   CMOS_Addr : Natural := 0;
   CMOS_Enabled : Boolean := False;
   CMOS_Data : Byte := 16#FF#;
   CMOS_Old_D : Boolean := False;
   Err : Unbounded_String;
   Frames : Natural := 0;
   Total_Cycles : Long_Long_Integer := 0;

   ---------------------------------------------------------------------
   --  Chips
   ---------------------------------------------------------------------

   Sys_VIA, User_VIA : VIA.Chip;
   IC32 : Byte := 0;               --  addressable latch
   Speech_On : Boolean := False;   --  speech upgrade fitted and working
   Speech_Data : Byte := 16#FF#;   --  what the speech chip drives
   VIA_Phase : Natural := 0;       --  1 MHz clock divider

   --  The display shows the shadow RAM: ACCCON bit 0 (Master), bit 7 (B+)
   function Shadow_Display return Boolean is
     (if Master then (ACCCON and 1) /= 0
      elsif B_Plus then (ACCCON and 16#80#) /= 0 else False);

   function Screen_Read (Addr : Natural) return Byte is
     (if Shadow_Display and then Addr mod 16#8000# >= 16#3000#
      then RAM (16#8000# + Addr mod 16#8000#)
      else RAM (Addr mod 16#8000#));
   pragma Inline (Screen_Read);

   procedure VSync_Changed (Active : Boolean) is
   begin
      VIA.Set_CA1 (Sys_VIA, Active);
   end VSync_Changed;

   package CRTC is new Display (Mem_Read => Screen_Read,
                                VSync_Changed => VSync_Changed);

   --  ADC (uPD7002)
   ADC_Status : Byte := 16#40#;
   ADC_High, ADC_Low : Byte := 0;
   ADC_Time : Integer := 0;
   Axes : array (Axis_Index) of Float := (others => 0.0);

   procedure Set_Axis (A : Axis_Index; Value : Float) is
   begin
      Axes (A) := Float'Max (-1.0, Float'Min (1.0, Value));
   end Set_Axis;

   function Axis_Value (Ch : Natural) return Natural is
      V : Float := Axes (Axis_Index (Ch));
      J : constant Byte :=
        (if Ch <= 1 then Keyboard.Joy1 else Keyboard.Joy2);
   begin
      --  Switched joystick from the keyboard overrides the axis
      if Ch mod 2 = 0 then
         if (J and 4) /= 0 then
            V := -1.0;
         elsif (J and 8) /= 0 then
            V := 1.0;
         end if;
      else
         if (J and 1) /= 0 then
            V := -1.0;
         elsif (J and 2) /= 0 then
            V := 1.0;
         end if;
      end if;
      --  left / up = high values
      return Natural (Float'Max (0.0, Float'Min (65535.0,
                       32760.0 - V * 32760.0)));
   end Axis_Value;

   procedure ADC_Complete is
      V : constant Natural := Axis_Value (Natural (ADC_Status and 3));
   begin
      ADC_Status := (ADC_Status and 16#0F#) or 16#40# or
        Byte ((V / 16#4000#) * 16);
      ADC_High := Byte (V / 256);
      ADC_Low := Byte (V mod 256);
      VIA.Set_CB1 (Sys_VIA, False);
   end ADC_Complete;

   ---------------------------------------------------------------------
   --  System VIA: slow data bus, addressable latch, keyboard, sound
   ---------------------------------------------------------------------

   function SDB_Out return Byte is
     ((Sys_VIA.ORA and Sys_VIA.DDRA) or not Sys_VIA.DDRA);

   procedure Update_Keyboard_IRQ is
      Level : Boolean;
   begin
      if (IC32 and 8) /= 0 then
         Level := Keyboard.Any_Key;            --  auto-scan
      else
         Level := Keyboard.Column_Active
           (Natural (SDB_Out and 16#0F#));
      end if;
      VIA.Set_CA2 (Sys_VIA, Level);
   end Update_Keyboard_IRQ;

   function CMOS_Bus return Byte;

   procedure Update_Sys_Port_A_Pins is
      S : constant Byte := SDB_Out;
      Down : Boolean;
   begin
      if (IC32 and 8) = 0 then
         Down := Keyboard.Key_Down (Natural (S and 16#0F#),
                                    Natural (Shift_Right (S, 4) and 7));
         Sys_VIA.Port_A_In := (if Down then S or 16#80# else S and 16#7F#);
      else
         Sys_VIA.Port_A_In := S;
      end if;
      Sys_VIA.Port_A_In := Sys_VIA.Port_A_In and CMOS_Bus;
      if Speech_On and then (IC32 and 2) = 0 then
         Sys_VIA.Port_A_In := Sys_VIA.Port_A_In and Speech_Data;
      end if;
   end Update_Sys_Port_A_Pins;

   procedure Update_Sys_Port_B_Pins is
      V : Byte := 16#FF#;
   begin
      if (Keyboard.Joy1 and 16#10#) /= 0 then
         V := V and not 16#10#;
      end if;
      if (Keyboard.Joy2 and 16#10#) /= 0 then
         V := V and not 16#20#;
      end if;
      if Speech_On then
         --  PB7 = READY, PB6 = interrupt (both active low); without the
         --  chip they are pulled high, which is how the OS knows
         if Speech.Ready then
            V := V and not 16#80#;
         end if;
         if Speech.Interrupt then
            V := V and not 16#40#;
         end if;
      end if;
      Sys_VIA.Port_B_In := V;
   end Update_Sys_Port_B_Pins;

   function BCD (N : Natural) return Byte is (Byte ((N / 10) * 16 + N mod 10));

   function CMOS_Get (A : Natural) return Byte is
      use Ada.Calendar;
      Now : constant Time := Clock;
      Y, Mo, Da, H, Mi, Se : Natural;
      Sub : Formatting.Second_Duration;
      Yr : Year_Number;
      Mn : Month_Number;
      Dy : Day_Number;
      Hr : Formatting.Hour_Number;
      Mt : Formatting.Minute_Number;
      Sc : Formatting.Second_Number;
   begin
      Formatting.Split (Now, Yr, Mn, Dy, Hr, Mt, Sc, Sub,
                        Time_Zone => Ada.Calendar.Time_Zones.UTC_Time_Offset);
      Y := Yr; Mo := Mn; Da := Dy; H := Hr; Mi := Mt; Se := Sc;
      case A is
         when 0 => return BCD (Se);
         when 2 => return BCD (Mi);
         when 4 => return BCD (H);
         when 6 =>
            --  1 = Sunday .. 7 = Saturday
            return Byte ((Formatting.Day_Name'Pos
                            (Formatting.Day_Of_Week (Now)) + 1) mod 7 + 1);
         when 7 => return BCD (Da);
         when 8 => return BCD (Mo);
         when 9 => return BCD (Y mod 100);
         when 10 => return 16#20#;              --  no update in progress
         when 12 => return 0;
         when 13 => return 16#80#;              --  valid RAM and time
         when others => return CMOS (A);
      end case;
   end CMOS_Get;

   procedure CMOS_Update is
      RW : constant Boolean := (IC32 and 2) /= 0;
      D  : constant Boolean := (IC32 and 4) /= 0;
   begin
      if Master and then D /= CMOS_Old_D and then CMOS_Enabled then
         if not RW and then not D then
            if CMOS_Addr >= 10 then           --  clock writes are ignored
               CMOS (CMOS_Addr) := SDB_Out;
            end if;
         elsif RW and then D then
            CMOS_Data := CMOS_Get (CMOS_Addr);
         end if;
      end if;
      CMOS_Old_D := D;
   end CMOS_Update;

   function CMOS_Bus return Byte is
     (if Master and then CMOS_Enabled and then (IC32 and 6) = 6
      then CMOS_Data else 16#FF#);

   procedure Sys_Port_Written is
      PB : constant Byte := (Sys_VIA.ORB and Sys_VIA.DDRB) or
        ((not Sys_VIA.DDRB) and 16#0F#);
      Bit : constant Natural := Natural (PB and 7);
      Old : constant Byte := IC32;
   begin
      if (PB and 8) /= 0 then
         IC32 := IC32 or Shift_Left (1, Bit);
      else
         IC32 := IC32 and not Shift_Left (1, Bit);
      end if;
      if (Old and 1) /= 0 and then (IC32 and 1) = 0 then
         Sound.Write (SDB_Out);           --  sound write enable went low
      end if;
      if Speech_On then
         if (Old and 4) /= 0 and then (IC32 and 4) = 0 then
            Speech.Write (SDB_Out);        --  speech write select
         end if;
         if (Old and 2) /= 0 and then (IC32 and 2) = 0 then
            Speech_Data := Speech.Read;    --  speech read select
         end if;
      end if;
      CRTC.Screen_Size := Natural (Shift_Right (IC32, 4) and 3);
      Keyboard.Caps_LED := (IC32 and 16#40#) = 0;
      if Master then
         declare
            Full : constant Byte := (Sys_VIA.ORB and Sys_VIA.DDRB) or
              not Sys_VIA.DDRB;
         begin
            if (Full and 16#80#) /= 0 then          --  address strobe
               CMOS_Addr := Natural (SDB_Out and 63);
            end if;
            CMOS_Enabled := (Full and 16#40#) /= 0;
         end;
         CMOS_Update;
      end if;
      Update_Keyboard_IRQ;
   end Sys_Port_Written;

   ---------------------------------------------------------------------
   --  Debugger state used by the bus
   ---------------------------------------------------------------------

   use type Tube.Parasite_Type;
   function Tube_On return Boolean is (Tube.Enabled and then Tube.ROM_Loaded);
   function Tube_6502 return Boolean is
     (Tube_On and then Tube.Kind = Tube.CPU_6502);
   --  BASIC, programs started from Forge and the debugger follow a 6502
   --  parasite; with a Z80 one they stay on the host
   function Tube_Active return Boolean is (Tube_6502);
   function Speech_Active return Boolean is (Speech_On);

   Parasite_Debug : Boolean := False;    --  debugging the parasite

   procedure Set_Debug_CPU (C : Debug_CPU_Type) is
   begin
      Parasite_Debug := C = Parasite_CPU and then Tube_6502;
   end Set_Debug_CPU;

   function Debug_CPU return Debug_CPU_Type is
     (if Parasite_Debug then Parasite_CPU else Host_CPU);

   type Watch is record
      From, To : Word := 0;
      On_Read, On_Write : Boolean := False;
   end record;
   Max_Watches : constant := 16;
   Watches : array (1 .. Max_Watches) of Watch;
   Watch_Count : Natural := 0;
   Watch_Hit   : Boolean := False;
   Watch_Write_Hit : Boolean := False;
   Watch_Addr  : Word := 0;

   procedure Check_Watch (Addr : Word; Is_Write : Boolean) is
   begin
      for I in 1 .. Watch_Count loop
         if Addr >= Watches (I).From and then Addr <= Watches (I).To
           and then (if Is_Write then Watches (I).On_Write
                     else Watches (I).On_Read)
         then
            if not Watch_Hit then
               Watch_Hit := True;
               Watch_Write_Hit := Is_Write;
               Watch_Addr := Addr;
            end if;
         end if;
      end loop;
   end Check_Watch;

   ---------------------------------------------------------------------
   --  Bus
   ---------------------------------------------------------------------

   function Bus_Read (Addr : Word) return Byte;
   procedure Bus_Write (Addr : Word; Value : Byte);
   function Bus_Read_At (Addr : Word) return Byte;
   procedure Bus_Write_At (Addr : Word; Value : Byte);
   procedure Clock_Devices (N : Natural);

   package CPU is new MOS6502 (Read => Bus_Read, Write => Bus_Write);

   --  Sub-instruction timing: an I/O access first clocks the chips up to
   --  the cycle on which it happens (taken as the last cycle of the
   --  instruction), then adds the 1 MHz bus stretch.
   In_Step      : Boolean := False;
   Instr_Ticked : Natural := 0;    --  cycles already clocked this step
   Instr_Extra  : Natural := 0;    --  stretch cycles added this step

   Instr_Access : Natural := 0;   --  bus accesses so far (= cycle number)

   --  Interrupt timing, matched against the b2 VIA timing tests (recorded
   --  on a real BBC Micro): the VIAs' IRQ output rises one 2 MHz cycle
   --  after their flag is set (and falls at once), and the CPU samples it
   --  at the start of an instruction's penultimate cycle.
   IRQ_Rise_Delay : constant := 1;
   IRQ_Fall_Delay : constant := 0;
   Sample_Offset  : constant := 2;

   --  IRQ sampling: the 6502 polls IRQ at the start of the penultimate
   --  cycle of an instruction.  When that point lies among the
   --  instruction's I/O accesses, Catch_Up takes the sample on the way.
   IRQ_Sampled  : Boolean := False;
   Sample_Taken : Boolean := False;
   Sample_Here  : Boolean := False;
   function IRQ_Now return Boolean;
   procedure Note_VIA_IRQ (At_Time : Long_Long_Integer);

   procedure Catch_Up is
      Target : constant Natural := Instr_Access + Instr_Extra;
      Sample_Point : constant Integer :=
        CPU.Current_Cycles - Sample_Offset + Instr_Extra;
   begin
      if In_Step and then Target > Instr_Ticked then
         if not Sample_Taken and then Sample_Point >= Instr_Ticked
           and then Sample_Point < Target
         then
            if Sample_Point > Instr_Ticked then
               Clock_Devices (Sample_Point - Instr_Ticked);
               Instr_Ticked := Sample_Point;
            end if;
            IRQ_Sampled := IRQ_Now;
            Sample_Taken := True;
         end if;
         if Target > Instr_Ticked then
            Clock_Devices (Target - Instr_Ticked);
            Instr_Ticked := Target;
         end if;
      end if;
      --  The sample falls in this access's cycle: taken during its phi2,
      --  after the wait for a 1 MHz edge and before the access acts
      Sample_Here := In_Step and then not Sample_Taken
        and then Sample_Point = Target;
   end Catch_Up;

   procedure Take_Sample_Here is
   begin
      if Sample_Here then
         IRQ_Sampled := IRQ_Now;
         Sample_Taken := True;
         Sample_Here := False;
      end if;
   end Take_Sample_Here;

   procedure Slow_Access is
      --  1 MHz devices: the CPU waits for the next 1 MHz edge, then the
      --  access takes a whole 1 MHz cycle (two 2 MHz cycles) - one or
      --  two cycles more than a normal access.  The access itself happens
      --  in the second half of that cycle, before the chips' clock edge
      --  that ends it (clocked with the rest of the instruction).
      Align : constant Natural := Natural (Total_Cycles mod 2);
   begin
      if In_Step then
         Clock_Devices (Align + 1);
         Instr_Extra := Instr_Extra + Align + 1;
         Instr_Ticked := Instr_Ticked + Align + 1;
      end if;
   end Slow_Access;

   function Is_Slow (Addr : Word) return Boolean is
     (Addr < 16#FE00#
      or else (case Natural (Shift_Right (Addr, 5) and 7) is
                  when 0 | 2 | 3 | 6 => True,
                  when others => False));

   function IO_Read_Reg (Addr : Word) return Byte;

   function IO_Read (Addr : Word) return Byte is
   begin
      return R : constant Byte := IO_Read_Reg (Addr) do
         Note_VIA_IRQ (Total_Cycles);
      end return;
   end IO_Read;

   function IO_Read_Reg (Addr : Word) return Byte is
      Reg : constant Natural := Natural (Addr and 16#1F#);
   begin
      Catch_Up;
      if Is_Slow (Addr) and then not CPU.Dummy_Access then
         Slow_Access;
      end if;
      Take_Sample_Here;
      if B_Plus then
         case Addr is
            when 16#FE80# .. 16#FE83# => return 16#FE#;
            when 16#FE84# .. 16#FE87# => return WD1770.Read (Reg mod 4);
            when 16#FE88# .. 16#FE9F# => return 16#FE#;
            when others => null;
         end case;
      end if;
      if Master then
         case Addr is
            when 16#FE18# .. 16#FE1F# =>
               case Reg mod 4 is
                  when 0 => return ADC_Status;
                  when 1 => return ADC_High;
                  when 2 => return ADC_Low;
                  when others => return 16#40#;
               end case;
            when 16#FE28# .. 16#FE2F# => return WD1770.Read (Reg mod 4);
            when 16#FE30# .. 16#FE33# =>
               return Byte (ROMSEL) or (if ANDY then 16#80# else 0);
            when 16#FE34# .. 16#FE37# => return ACCCON;
            when 16#FE80# .. 16#FEDF# => return 16#FE#;
            when others => null;
         end case;
      end if;
      case Addr is
         when 16#FC00# .. 16#FDFF# => return 16#FF#;
         when 16#FE00# .. 16#FE07# => return CRTC.CRTC_Read (Reg mod 2);
         when 16#FE08# .. 16#FE0F# => return Tape.ACIA_Read (Reg mod 2);
         when 16#FE40# .. 16#FE5F# =>
            Update_Sys_Port_A_Pins;
            Update_Sys_Port_B_Pins;
            return VIA.Read (Sys_VIA, Reg mod 16);
         when 16#FE60# .. 16#FE7F# =>
            return VIA.Read (User_VIA, Reg mod 16);
         when 16#FE80# .. 16#FE9F# =>
            return FDC8271.Read (Reg mod 8);
         when 16#FEE0# .. 16#FEFF# =>
            return (if Tube.Enabled and then Tube.ROM_Loaded
                    then Tube.Host_Read (Reg mod 8) else 16#FE#);
         when 16#FEC0# .. 16#FEDF# =>
            case Reg mod 4 is
               when 0 => return ADC_Status;
               when 1 => return ADC_High;
               when 2 => return ADC_Low;
               when others => return 16#40#;
            end case;
         when others =>
            return 16#FE#;
      end case;
   end IO_Read_Reg;

   procedure IO_Write_Reg (Addr : Word; Value : Byte);

   procedure IO_Write (Addr : Word; Value : Byte) is
   begin
      IO_Write_Reg (Addr, Value);
      Note_VIA_IRQ (Total_Cycles);
   end IO_Write;

   procedure IO_Write_Reg (Addr : Word; Value : Byte) is
      Reg : constant Natural := Natural (Addr and 16#1F#);
   begin
      Catch_Up;
      if Is_Slow (Addr) then
         Slow_Access;
      end if;
      Take_Sample_Here;
      if B_Plus then
         case Addr is
            when 16#FE30# .. 16#FE33# =>
               ROMSEL := Natural (Value and 15);
               ANDY := (Value and 16#80#) /= 0;    --  12K private RAM
               return;
            when 16#FE34# .. 16#FE37# =>
               ACCCON := Value;
               return;
            when 16#FE80# .. 16#FE83# =>
               WD1770.Write_Control_Acorn (Value);
               return;
            when 16#FE84# .. 16#FE87# =>
               WD1770.Write (Reg mod 4, Value);
               return;
            when 16#FE88# .. 16#FE9F# => return;
            when others => null;
         end case;
      end if;
      if Master then
         case Addr is
            when 16#FE18# .. 16#FE1F# =>
               if Reg mod 4 = 0 then
                  ADC_Status := (Value and 16#0F#) or 16#80#;
                  ADC_Time := (if (Value and 8) /= 0 then 20_000 else 8_000);
                  VIA.Set_CB1 (Sys_VIA, True);
               end if;
               return;
            when 16#FE24# .. 16#FE27# =>
               WD1770.Write_Control (Value);
               return;
            when 16#FE28# .. 16#FE2F# =>
               WD1770.Write (Reg mod 4, Value);
               return;
            when 16#FE30# .. 16#FE33# =>
               ROMSEL := Natural (Value and 15);
               ANDY := (Value and 16#80#) /= 0;
               return;
            when 16#FE34# .. 16#FE37# =>
               ACCCON := Value;
               return;
            when 16#FE80# .. 16#FEDF# => return;
            when others => null;
         end case;
      end if;
      case Addr is
         when 16#FE00# .. 16#FE07# => CRTC.CRTC_Write (Reg mod 2, Value);
         when 16#FE08# .. 16#FE0F# => Tape.ACIA_Write (Reg mod 2, Value);
         when 16#FE10# .. 16#FE1F# => Tape.Serial_ULA_Write (Value);
         when 16#FE20# .. 16#FE2F# => CRTC.ULA_Write (Reg mod 2, Value);
         when 16#FE30# .. 16#FE3F# => ROMSEL := Natural (Value and 15);
         when 16#FE40# .. 16#FE5F# =>
            VIA.Write (Sys_VIA, Reg mod 16, Value);
            case Reg mod 16 is
               when 0 | 2 => Sys_Port_Written;
               when 1 | 3 | 15 => Update_Keyboard_IRQ;
               when others => null;
            end case;
         when 16#FE60# .. 16#FE7F# =>
            VIA.Write (User_VIA, Reg mod 16, Value);
         when 16#FE80# .. 16#FE9F# =>
            FDC8271.Write (Reg mod 8, Value);
         when 16#FEE0# .. 16#FEFF# =>
            if Tube.Enabled and then Tube.ROM_Loaded then
               Tube.Host_Write (Reg mod 8, Value);
            end if;
         when 16#FEC0# .. 16#FEDF# =>
            if Reg mod 4 = 0 then
               ADC_Status := (Value and 16#0F#) or 16#80#;
               ADC_Time := (if (Value and 8) /= 0 then 20_000 else 8_000);
               VIA.Set_CB1 (Sys_VIA, True);
            end if;
         when others => null;
      end case;
   end IO_Write_Reg;

   --  Master: the CPU sees the shadow RAM at &3000-&7FFF when ACCCON X is
   --  set, or (E set) for code running in the VDU driver at &C000-&DFFF
   function Shadow_For_CPU return Boolean is
     (if Instr_PC in 16#C000# .. 16#DFFF# and then (ACCCON and 8) = 0
      then (ACCCON and 2) /= 0
      else (ACCCON and 4) /= 0);

   function Master_Read (Addr : Word; IO : Boolean) return Byte is
   begin
      case Addr is
         when 16#0000# .. 16#2FFF# => return RAM (Natural (Addr));
         when 16#3000# .. 16#7FFF# =>
            return (if Shadow_For_CPU then RAM (16#8000# + Natural (Addr))
                    else RAM (Natural (Addr)));
         when 16#8000# .. 16#8FFF# =>
            return (if ANDY then RAM (Natural (Addr))
                    else Banks (ROMSEL) (Natural (Addr - 16#8000#)));
         when 16#9000# .. 16#BFFF# =>
            return Banks (ROMSEL) (Natural (Addr - 16#8000#));
         when 16#C000# .. 16#DFFF# =>
            return (if (ACCCON and 8) /= 0
                    then RAM (16#9000# + Natural (Addr - 16#C000#))
                    else OS (Natural (Addr - 16#C000#)));
         when 16#FC00# .. 16#FEFF# =>
            if (ACCCON and 16#40#) /= 0 or else not IO then
               return (if IO then OS (Natural (Addr - 16#C000#)) else 16#FF#);
            end if;
            return IO_Read (Addr);
         when others => return OS (Natural (Addr - 16#C000#));
      end case;
   end Master_Read;

   procedure Master_Write (Addr : Word; Value : Byte; IO : Boolean) is
   begin
      case Addr is
         when 16#0000# .. 16#2FFF# => RAM (Natural (Addr)) := Value;
         when 16#3000# .. 16#7FFF# =>
            if Shadow_For_CPU then
               RAM (16#8000# + Natural (Addr)) := Value;
            else
               RAM (Natural (Addr)) := Value;
            end if;
         when 16#8000# .. 16#BFFF# =>
            if ANDY and then Addr < 16#9000# then
               RAM (Natural (Addr)) := Value;
            elsif Bank_Is_RAM (ROMSEL) then
               Banks (ROMSEL) (Natural (Addr - 16#8000#)) := Value;
            end if;
         when 16#C000# .. 16#DFFF# =>
            if (ACCCON and 8) /= 0 then
               RAM (16#9000# + Natural (Addr - 16#C000#)) := Value;
            end if;
         when 16#FC00# .. 16#FEFF# =>
            if IO then
               IO_Write (Addr, Value);
            end if;
         when others => null;
      end case;
   end Master_Write;

   --  B+: 12K private RAM at &8000-&AFFF (ROMSEL bit 7, kept in
   --  RAM (16#8000# .. 16#AFFF#)) and the shadow RAM for the VDU code at
   --  &C000-&DFFF (and private RAM code at &A000-&AFFF) when ACCCON bit 7
   function BPlus_Shadow_For_CPU return Boolean is
     ((ACCCON and 16#80#) /= 0
      and then (Instr_PC in 16#C000# .. 16#DFFF#
                or else (ANDY and then Instr_PC in 16#A000# .. 16#AFFF#)));

   function BPlus_Read (Addr : Word; IO : Boolean) return Byte is
   begin
      case Addr is
         when 16#0000# .. 16#2FFF# => return RAM (Natural (Addr));
         when 16#3000# .. 16#7FFF# =>
            return (if BPlus_Shadow_For_CPU
                    then RAM (16#8000# + Natural (Addr))
                    else RAM (Natural (Addr)));
         when 16#8000# .. 16#AFFF# =>
            return (if ANDY then RAM (Natural (Addr))
                    else Banks (ROMSEL) (Natural (Addr - 16#8000#)));
         when 16#B000# .. 16#BFFF# =>
            return Banks (ROMSEL) (Natural (Addr - 16#8000#));
         when 16#FC00# .. 16#FEFF# =>
            return (if IO then IO_Read (Addr) else 16#FF#);
         when others => return OS (Natural (Addr - 16#C000#));
      end case;
   end BPlus_Read;

   procedure BPlus_Write (Addr : Word; Value : Byte; IO : Boolean) is
   begin
      case Addr is
         when 16#0000# .. 16#2FFF# => RAM (Natural (Addr)) := Value;
         when 16#3000# .. 16#7FFF# =>
            if BPlus_Shadow_For_CPU then
               RAM (16#8000# + Natural (Addr)) := Value;
            else
               RAM (Natural (Addr)) := Value;
            end if;
         when 16#8000# .. 16#BFFF# =>
            if ANDY and then Addr < 16#B000# then
               RAM (Natural (Addr)) := Value;
            elsif Bank_Is_RAM (ROMSEL) then
               Banks (ROMSEL) (Natural (Addr - 16#8000#)) := Value;
            end if;
         when 16#FC00# .. 16#FEFF# =>
            if IO then
               IO_Write (Addr, Value);
            end if;
         when others => null;
      end case;
   end BPlus_Write;

   function Bus_Read (Addr : Word) return Byte is
      Index : constant Natural := Instr_Access;
   begin
      --  an I/O access is timed at cycle Index of the instruction
      return R : constant Byte := Bus_Read_At (Addr) do
         Instr_Access := Index + 1;
      end return;
   end Bus_Read;

   function Bus_Read_At (Addr : Word) return Byte is
   begin
      if Watch_Count > 0 and then not Parasite_Debug then
         Check_Watch (Addr, False);
      end if;
      if Master then
         return Master_Read (Addr, True);
      elsif B_Plus then
         return BPlus_Read (Addr, True);
      end if;
      if Addr < 16#8000# then
         return RAM (Natural (Addr));
      elsif Addr < 16#C000# then
         return Banks (ROMSEL) (Natural (Addr - 16#8000#));
      elsif Addr >= 16#FC00# and then Addr < 16#FF00# then
         return IO_Read (Addr);
      else
         return OS (Natural (Addr - 16#C000#));
      end if;
   end Bus_Read_At;

   procedure Bus_Write (Addr : Word; Value : Byte) is
   begin
      Bus_Write_At (Addr, Value);
      Instr_Access := Instr_Access + 1;
   end Bus_Write;

   procedure Bus_Write_At (Addr : Word; Value : Byte) is
   begin
      if Watch_Count > 0 and then not Parasite_Debug then
         Check_Watch (Addr, True);
      end if;
      if Master then
         Master_Write (Addr, Value, True);
         return;
      elsif B_Plus then
         BPlus_Write (Addr, Value, True);
         return;
      end if;
      if Addr < 16#8000# then
         RAM (Natural (Addr)) := Value;
      elsif Addr < 16#C000# then
         if Bank_Is_RAM (ROMSEL) then
            Banks (ROMSEL) (Natural (Addr - 16#8000#)) := Value;
         end if;
      elsif Addr >= 16#FC00# and then Addr < 16#FF00# then
         IO_Write (Addr, Value);
      end if;
   end Bus_Write_At;

   ---------------------------------------------------------------------
   --  Clocking
   ---------------------------------------------------------------------

   KB_Poll : Natural := 0;

   --  The VIAs' IRQ output follows their flags with a delay (in 2 MHz
   --  cycles), kept as the level before and after the last change.
   VIA_Level, VIA_Prev_Level : Boolean := False;
   VIA_Change_Time : Long_Long_Integer := 0;

   procedure Note_VIA_IRQ (At_Time : Long_Long_Integer) is
      L : constant Boolean := VIA.IRQ (Sys_VIA) or else VIA.IRQ (User_VIA);
   begin
      if L /= VIA_Level then
         VIA_Prev_Level := VIA_Level;
         VIA_Level := L;
         VIA_Change_Time := At_Time;
      end if;
   end Note_VIA_IRQ;

   function VIA_IRQ_Out return Boolean is
      Delay_C : constant Integer :=
        (if VIA_Level then IRQ_Rise_Delay else IRQ_Fall_Delay);
   begin
      return (if Total_Cycles - VIA_Change_Time >= Long_Long_Integer (Delay_C)
              then VIA_Level else VIA_Prev_Level);
   end VIA_IRQ_Out;

   procedure Clock_Devices (N : Natural) is
      Ticks_1MHz : Natural;
   begin
      Total_Cycles := Total_Cycles + Long_Long_Integer (N);
      CRTC.Tick (N);
      Sound.Clock (N);
      if Has_1770 then
         WD1770.Tick (N);
      else
         FDC8271.Tick (N);
      end if;
      Tape.Tick (N);
      if Tube.Enabled then
         Tube.Run (N);
      end if;
      if Speech_On then
         Speech.Clock (N);
      end if;
      Ticks_1MHz := (VIA_Phase + N) / 2;
      VIA_Phase := (VIA_Phase + N) mod 2;
      if Ticks_1MHz > 0 then
         VIA.Tick (Sys_VIA, Ticks_1MHz);
         VIA.Tick (User_VIA, Ticks_1MHz);
         Note_VIA_IRQ (Total_Cycles - Total_Cycles mod 2);
      end if;
      if ADC_Time > 0 then
         ADC_Time := ADC_Time - N;
         if ADC_Time <= 0 then
            ADC_Time := 0;
            ADC_Complete;
         end if;
      end if;
      Note_VIA_IRQ (Total_Cycles);
      KB_Poll := KB_Poll + N;
      if KB_Poll >= 256 then
         KB_Poll := 0;
         Update_Keyboard_IRQ;
      end if;
   end Clock_Devices;

   ---------------------------------------------------------------------
   --  ROM loading and reset
   ---------------------------------------------------------------------

   function Find_File (Dir, Name : String) return String is
      use Ada.Directories;
      Candidates : constant array (1 .. 4) of Unbounded_String :=
        (To_Unbounded_String (Dir & "/" & Name),
         To_Unbounded_String ("roms/" & Name),
         To_Unbounded_String ("../roms/" & Name),
         To_Unbounded_String ("/usr/share/adabeeb/roms/" & Name));
   begin
      for C of Candidates loop
         if Exists (To_String (C)) then
            return To_String (C);
         end if;
      end loop;
      return "";
   end Find_File;

   procedure Read_File (Path : String; Data : out Byte_Array;
                        Got : out Natural) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      Size : Natural;
   begin
      Got := 0;
      Open (F, In_File, Path);
      Size := Natural (Ada.Streams.Stream_IO.Size (F));
      declare
         subtype Buf_T is Byte_Array (0 .. Size - 1);
         Buf : Buf_T;
      begin
         Buf_T'Read (Stream (F), Buf);
         Got := Natural'Min (Size, Data'Length);
         Data (Data'First .. Data'First + Got - 1) := Buf (0 .. Got - 1);
      end;
      Close (F);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Got := 0;
   end Read_File;

   procedure Load_Sideways_ROM (Slot : Natural; Path : String;
                                Ok : out Boolean) is
      Data : Byte_Array (0 .. 16#3FFF#) := (others => 16#FF#);
      Got : Natural;
   begin
      Ok := False;
      if Slot > 15 then
         return;
      end if;
      Read_File (Path, Data, Got);
      if Got = 0 then
         return;
      end if;
      for I in 0 .. 16#3FFF# loop
         Banks (Slot) (I) := (if I < Got then Data (I) else 16#FF#);
      end loop;
      Bank_Used (Slot) := True;
      Ok := True;
   end Load_Sideways_ROM;

   procedure Set_Sideways_RAM (Slot : Natural; On : Boolean) is
   begin
      if Slot <= 15 then
         Bank_Is_RAM (Slot) := On;
         if On and then not Bank_Used (Slot) then
            Banks (Slot) := (others => 0);
         end if;
      end if;
   end Set_Sideways_RAM;

   function ROM_Title (Slot : Natural) return String is
      R : Unbounded_String;
   begin
      if Slot > 15 or else not Bank_Used (Slot) then
         return (if Slot <= 15 and then Bank_Is_RAM (Slot)
                 then "(sideways RAM)" else "");
      end if;
      for I in 9 .. 40 loop
         exit when Banks (Slot) (I) = 0;
         if Banks (Slot) (I) in 32 .. 126 then
            Append (R, Character'Val (Banks (Slot) (I)));
         end if;
      end loop;
      return To_String (R);
   end ROM_Title;

   function Current_ROM_Bank return Natural is (ROMSEL);

   function Slot_Is_RAM (Slot : Natural) return Boolean is
     (Slot <= 15 and then Bank_Is_RAM (Slot));

   procedure Clear_Slot (Slot : Natural) is
   begin
      if Slot <= 15 then
         Banks (Slot) := (others => 16#FF#);
         Bank_Used (Slot) := False;
         Bank_Is_RAM (Slot) := False;
      end if;
   end Clear_Slot;

   procedure Reset is
   begin
      RAM := (others => 0);
      VIA.Reset (Sys_VIA);
      VIA.Reset (User_VIA);
      IC32 := 0;
      CRTC.Reset;
      Sound.Reset;
      ROMSEL := 15;
      ADC_Status := 16#40#;
      ADC_Time := 0;
      FDC8271.Reset;
      WD1770.Reset;
      Tube.Reset;
      ACCCON := 0;
      ANDY := False;
      Tape.Reset;
      Keyboard.Release_All;
      Keyboard.Hold_Shift := False;
      Keyboard.Hold_Key := -1;
      Frames := 0;
      CPU.Reset;
      CPU.Jammed := False;
   end Reset;

   Break_Was_Down : Boolean := False;

   procedure Break_Key (Down : Boolean) is
   begin
      if Down and then not Break_Was_Down then
         null;                 --  held: the CPU stays in reset
      elsif not Down and then Break_Was_Down then
         CPU.Reset;            --  released: the CPU restarts
         Tube.Reset;           --  the Tube's reset follows the host's
         CPU.Jammed := False;
      end if;
      Break_Was_Down := Down;
   end Break_Key;

   function CMOS_Path return String is
      Home : constant String :=
        (if Ada.Environment_Variables.Exists ("HOME")
         then Ada.Environment_Variables.Value ("HOME") else ".");
   begin
      return Home & "/.config/adabeeb/cmos.bin";
   end CMOS_Path;

   procedure Load_CMOS is
      Got : Natural;
      --  user locations 14 .. 30: Econet, DFS + BASIC, all ROMs on,
      --  EDIT, MODE 7 / TV 0,1, shift caps, delay and rate, printer,
      --  baud, no shadow / loud beep
      Defaults : constant Byte_Array (14 .. 30) :=
        (16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#C9#, 16#FF#, 16#FF#,
         16#12#, 16#00#, 16#17#, 16#CA#, 16#1E#, 16#05#, 16#00#, 16#35#,
         16#A6#);
   begin
      CMOS := (others => 0);
      CMOS (10) := 16#20#;
      CMOS (11) := 16#02#;
      CMOS (14 .. 30) := Defaults;
      if Ada.Directories.Exists (CMOS_Path) then
         Read_File (CMOS_Path, CMOS, Got);
      end if;
   end Load_CMOS;

   procedure Save_CMOS is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      if not Ada.Directories.Exists
        (Ada.Directories.Containing_Directory (CMOS_Path))
      then
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (CMOS_Path));
      end if;
      Create (F, Out_File, CMOS_Path);
      Byte_Array'Write (Stream (F), CMOS);
      Close (F);
   exception
      when others => null;
   end Save_CMOS;

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean) is
      Got : Natural;
      Font_Ok : Boolean;
      R_Ok : Boolean;
   begin
      Ok := False;
      Current_Model := M;
      Banks.all := (others => (others => 16#FF#));
      Bank_Used := (others => False);
      Bank_Is_RAM := (others => False);
      CPU.CMOS := M = Master_128;
      CPU.Rockwell := False;
      Keyboard.Master := M = Master_128;
      if M = Master_128 then
         declare
            P : constant String := Find_File (ROM_Dir, "mos320.rom");
            Data : Byte_Array (0 .. 8 * 16#4000# - 1) := (others => 16#FF#);
         begin
            if P = "" then
               Err := To_Unbounded_String ("mos320.rom not found in " &
                                           ROM_Dir);
               return;
            end if;
            Read_File (P, Data, Got);
            if Got /= Data'Length then
               Err := To_Unbounded_String ("cannot read " & P);
               return;
            end if;
            OS := Data (0 .. 16#3FFF#);
            for S in 9 .. 15 loop
               for I in 0 .. 16#3FFF# loop
                  Banks (S) (I) := Data ((S - 8) * 16#4000# + I);
               end loop;
               Bank_Used (S) := True;
            end loop;
            for S in 4 .. 7 loop
               Set_Sideways_RAM (S, True);
            end loop;
            Load_CMOS;
         end;
      else
      declare
         OS_Path : constant String :=
           Find_File (ROM_Dir, (if M = Model_B_Plus then "bpos.rom"
                                else "os12.rom"));
         Basic_Path : constant String := Find_File (ROM_Dir, "basic2.rom");
      begin
         if OS_Path = "" then
            Err := To_Unbounded_String
              ((if M = Model_B_Plus then "bpos.rom" else "os12.rom") &
               " not found in " & ROM_Dir);
            return;
         end if;
         Read_File (OS_Path, OS, Got);
         if Got /= 16#4000# then
            Err := To_Unbounded_String ("cannot read " & OS_Path);
            return;
         end if;
         if Basic_Path /= "" then
            Load_Sideways_ROM (15, Basic_Path, R_Ok);
         end if;
         declare
            DFS : constant String :=
              Find_File (ROM_Dir, (if M = Model_B_Plus then "dfs226.rom"
                                   else "dnfs120.rom"));
         begin
            if DFS /= "" then
               Load_Sideways_ROM (14, DFS, R_Ok);
            end if;
         end;
      end;
      if Model_B_SWRAM then
         for S in 4 .. 7 loop
            Set_Sideways_RAM (S, True);
         end loop;
      end if;
      end if;
      if Tube.Enabled then
         declare
            P : constant String := Find_File (ROM_Dir, Tube.ROM_Name);
            T_Ok : Boolean := False;
         begin
            if P /= "" then
               Tube.Load_ROM (P, T_Ok);
            end if;
            if not T_Ok then
               Err := To_Unbounded_String
                 (Tube.ROM_Name & " not found: second processor disabled");
               Tube.Enabled := False;
            end if;
         end;
      end if;
      Set_Debug_CPU (if Tube_6502 then Parasite_CPU else Host_CPU);
      Speech_On := False;
      Sound.Extra := null;
      if Speech.Enabled and then not Master then
         declare
            P : constant String := Find_File (ROM_Dir, "phroma.rom");
            S_Ok : Boolean := False;
         begin
            if P /= "" then
               Speech.Load_PHROM (15, P, S_Ok);
            end if;
            if S_Ok then
               Speech_On := True;
               Speech.Reset;
               Sound.Extra := Speech.Output'Access;
            else
               Err := To_Unbounded_String
                 ("phroma.rom not found: speech disabled");
            end if;
         end;
      end if;
      declare
         Font : constant String := Find_File (ROM_Dir, "saa5050.fnt");
      begin
         Font_Ok := False;
         if Font /= "" then
            Teletext_Font.Load (Font, Font_Ok);
         end if;
         if not Font_Ok then
            Teletext_Font.Build_Fallback (OS);
         end if;
      end;
      Sound.Set_Clock (2_000_000);
      Reset;
      Ok := True;
   end Power_On;

   function Model return Model_Type is (Current_Model);
   function Error_Message return String is (To_String (Err));
   function Frame_Count return Natural is (Frames);
   function Frame_Rate return Float is (2_000_000.0 / (312.0 * 128.0));
   function Get_PC return Word is (CPU.PC);

   function Program_Peek (Addr : Word) return Byte is
     (if Tube_6502 then Tube.Parasite_Peek (Addr) else Peek (Addr));

   procedure Program_Poke (Addr : Word; Value : Byte) is
   begin
      if Tube_6502 then
         Tube.Parasite_Poke (Addr, Value);
      else
         Poke (Addr, Value);
      end if;
   end Program_Poke;

   function Peek (Addr : Word) return Byte is
   begin
      if Master then
         return Master_Read (Addr, False);
      elsif B_Plus then
         return BPlus_Read (Addr, False);
      end if;
      if Addr < 16#8000# then
         return RAM (Natural (Addr));
      elsif Addr < 16#C000# then
         return Banks (ROMSEL) (Natural (Addr - 16#8000#));
      elsif Addr >= 16#FC00# and then Addr < 16#FF00# then
         return 16#FF#;
      else
         return OS (Natural (Addr - 16#C000#));
      end if;
   end Peek;

   procedure Poke (Addr : Word; Value : Byte) is
   begin
      if Master then
         Master_Write (Addr, Value, False);
         return;
      elsif B_Plus then
         BPlus_Write (Addr, Value, False);
         return;
      end if;
      if Addr < 16#8000# then
         RAM (Natural (Addr)) := Value;
      elsif Addr < 16#C000# and then Bank_Is_RAM (ROMSEL) then
         Banks (ROMSEL) (Natural (Addr - 16#8000#)) := Value;
      end if;
   end Poke;

   function RAM_Peek (Addr : Natural) return Byte is
     (RAM (Addr mod RAM'Length));

   function Screen_Peek (Addr : Word) return Byte is
     (Screen_Read (Natural (Addr)));

   procedure Screen_Poke (Addr : Word; Value : Byte) is
      A : constant Natural := Natural (Addr) mod 16#8000#;
   begin
      if Shadow_Display and then A >= 16#3000# then
         RAM (16#8000# + A) := Value;
      else
         RAM (A) := Value;
      end if;
   end Screen_Poke;

   ---------------------------------------------------------------------
   --  Screen text recognition
   ---------------------------------------------------------------------

   function Screen_Text return String is
      R : Unbounded_String;
   begin
      if CRTC.Teletext_Mode then
         declare
            Start : constant Natural := CRTC.Screen_Start;
            Cols : constant Natural :=
              Natural'Max (1, Natural (CRTC.CRTC_Register (1)));
            Rows : constant Natural := Natural (CRTC.CRTC_Register (6));
            A : Natural;
            C : Byte;
         begin
            for Y in 0 .. Rows - 1 loop
               for X in 0 .. Cols - 1 loop
                  A := Start + Y * Cols + X;
                  if A >= 16#8000# then
                     A := A - 16#400#;
                  end if;
                  C := Screen_Read (A) and 16#7F#;
                  Append (R, (if C >= 32 and then C < 127
                              then Character'Val (C) else ' '));
               end loop;
               Append (R, ASCII.LF);
            end loop;
         end;
      else
         --  Match 8 x 8 cells of a 1 bpp mode against the OS font
         declare
            Ctrl : constant Byte := CRTC.ULA_Control;
            Rate : constant Natural := Natural (Shift_Right (Ctrl, 2) and 3);
            Fast : constant Boolean := (Ctrl and 16#10#) /= 0;
            One_BPP : constant Boolean :=
              (Fast and then Rate = 3) or else (not Fast and then Rate = 2);
            Cols : constant Natural := Natural (CRTC.CRTC_Register (1));
            Rows : constant Natural := Natural (CRTC.CRTC_Register (6));
            Start : constant Natural := CRTC.Screen_Start;
            Len : constant array (0 .. 3) of Natural :=
              (16#4000#, 16#5000#, 16#2000#, 16#2800#);
            Size : constant Natural :=
              Len (Natural (Shift_Right (IC32, 4) and 3));
            A : Natural;
            Found : Character;
         begin
            if not One_BPP then
               return "";
            end if;
            for Y in 0 .. Rows - 1 loop
               for X in 0 .. Cols - 1 loop
                  A := Start + (Y * Cols + X) * 8;
                  if A >= 16#8000# then
                     A := A - Size;
                  end if;
                  Found := '?';
                  for Ch in 32 .. 126 loop
                     declare
                        Match, Inv : Boolean := True;
                        B : Byte;
                     begin
                        for L in 0 .. 7 loop
                           B := Screen_Read ((A + L) mod 16#8000#);
                           if B /= OS ((Ch - 32) * 8 + L) then
                              Match := False;
                           end if;
                           if B /= not OS ((Ch - 32) * 8 + L) then
                              Inv := False;
                           end if;
                        end loop;
                        if Match or else Inv then
                           Found := Character'Val (Ch);
                           exit;
                        end if;
                     end;
                  end loop;
                  Append (R, Found);
               end loop;
               Append (R, ASCII.LF);
            end loop;
         end;
      end if;
      return To_String (R);
   end Screen_Text;

   function Screen_Start return Natural is (CRTC.Screen_Start);
   function Teletext_Mode return Boolean is (CRTC.Teletext_Mode);
   function Screen_Mode return Integer is (Integer (RAM (16#0355#)));
   function ULA_Palette (Index : Natural) return Byte is
     (CRTC.Palette_Entry (Index));

   function Screen_Contains (Text : String) return Boolean is
      S : constant String := Screen_Text;
   begin
      for I in S'First .. S'Last - Text'Length + 1 loop
         if S (I .. I + Text'Length - 1) = Text then
            return True;
         end if;
      end loop;
      return False;
   end Screen_Contains;

   ---------------------------------------------------------------------
   --  Typing and autostart
   ---------------------------------------------------------------------

   procedure Type_Text (S : String) is
   begin
      Keyboard.Type_Keys (S);
   end Type_Text;

   function Typing_Busy return Boolean is (Keyboard.Typing_Busy);

   type Auto_State is (Idle, Wait_Prompt, Inject);
   Shift_Frames : Natural := 0;    --  SHIFT held for the boot

   function Default_Page return Word is
     (if Tube_6502 then 16#0800#
      elsif Current_Model = Master_128 then 16#0E00#
      elsif Bank_Used (14) or else Bank_Used (13) then 16#1900#
      else 16#0E00#);
   Auto : Auto_State := Idle;
   Auto_Frames : Natural := 0;
   Auto_Command : Unbounded_String;
   Auto_Data : Byte_Array_Access := null;
   Auto_Load : Word := 0;

   function At_Prompt return Boolean is
      S : constant String := Screen_Text;
   begin
      --  BASIC's ">" prompt at the start of a line, cursor after it
      for I in S'First + 1 .. S'Last loop
         if S (I) = '>' and then S (I - 1) = ASCII.LF then
            return True;
         end if;
      end loop;
      return S'Length > 0 and then S (S'First) = '>';
   end At_Prompt;

   procedure Autostart_Step is
   begin
      case Auto is
         when Idle => null;
         when Wait_Prompt =>
            Auto_Frames := Auto_Frames + 1;
            if (At_Prompt and then Auto_Frames > 25)
              or else Auto_Frames > 500
            then
               Auto := Inject;
            end if;
         when Inject =>
            if Auto_Data /= null then
               for I in Auto_Data'Range loop
                  Program_Poke (Auto_Load + Word (I - Auto_Data'First),
                                Auto_Data (I));
               end loop;
               if Auto_Load = Word (Program_Peek (16#18#)) * 256 then
                  --  BASIC program at PAGE: set TOP / LOMEM / VARTOP
                  declare
                     Top : constant Word :=
                       Auto_Load + Word (Auto_Data'Length);
                  begin
                     Program_Poke (16#12#, Lo (Top));
                     Program_Poke (16#13#, Hi (Top));
                     Program_Poke (16#00#, Lo (Top));
                     Program_Poke (16#01#, Hi (Top));
                     Program_Poke (16#02#, Lo (Top));
                     Program_Poke (16#03#, Hi (Top));
                  end;
               end if;
            end if;
            if Length (Auto_Command) > 0 then
               Type_Text (To_String (Auto_Command) & ASCII.LF);
            end if;
            Auto := Idle;
      end case;
   end Autostart_Step;

   function Autostart_Busy return Boolean is
     (Auto /= Idle or else Keyboard.Typing_Busy or else Shift_Frames > 0);

   procedure Inject_And_Run (Data : Byte_Array; Load : Word;
                             Command : String; With_Reset : Boolean := True)
   is
   begin
      Auto_Data := new Byte_Array'(Data);
      Auto_Load := Load;
      Auto_Command := To_Unbounded_String (Command);
      if With_Reset then
         Reset;
         Auto := Wait_Prompt;
         Auto_Frames := 0;
      else
         Auto := Inject;
      end if;
   end Inject_And_Run;

   procedure Boot_Disc is
   begin
      Reset;
      Keyboard.Hold_Shift := True;
      if Master and then Disc_Image.Present (0)
        and then Disc_Image.Is_ADFS (0)
      then
         Keyboard.Hold_Key := 16#41#;          --  A: ADFS
      end if;
      Shift_Frames := (if Master then 150 elsif B_Plus then 100 else 60);
      Auto := Idle;
   end Boot_Disc;

   procedure Autostart (Path : String; Ok : out Boolean) is
      Ext : constant String := Ada.Characters.Handling.To_Lower
        (Ada.Directories.Extension (Path));
   begin
      Ok := False;
      if Ext = "adf" or else Ext = "adl" then
         if not Master then
            Err := To_Unbounded_String
              ("ADFS discs need the BBC Master 128 (Machine menu or --master)");
            return;
         end if;
         Attach (Path, Ok);
         if not Ok then
            return;
         end if;
         Reset;
         Keyboard.Hold_Shift := True;            --  SHIFT+A+BREAK:
         Keyboard.Hold_Key := 16#41#;            --  boot from ADFS
         Shift_Frames := 150;
         Auto := Idle;
      elsif Ext = "ssd" or else Ext = "dsd" then
         Attach (Path, Ok);
         if not Ok then
            return;
         end if;
         Reset;
         if Disc_Image.Boot_Option (0) /= 0 then
            Keyboard.Hold_Shift := True;      --  SHIFT+BREAK
            Shift_Frames := (if Master then 150 elsif B_Plus then 100
                             else 60);
            Auto := Idle;
         else
            --  no boot option: run the first file
            declare
               Files : constant Disc_Image.File_List :=
                 Disc_Image.Catalogue (0);
            begin
               Auto_Data := null;
               Auto_Command := Null_Unbounded_String;
               if Files'Length > 0 then
                  declare
                     F : constant Disc_Image.File_Info :=
                       Files (Files'Last);
                     Exec : constant Natural := F.Exec mod 16#10000#;
                     Name : constant String := Disc_Image.File_Name (F);
                  begin
                     if Exec in 16#801F# | 16#8023# | 16#802B# then
                        Auto_Command := To_Unbounded_String
                          ("CHAIN """ & Name & """");
                     else
                        Auto_Command := To_Unbounded_String
                          ("*RUN """ & Name & """");
                     end if;
                  end;
               end if;
               Auto := Wait_Prompt;
               Auto_Frames := 0;
            end;
         end if;
      elsif Ext = "bas" or else Ext = "bbc" then
         Basic.Page := Default_Page;
         Basic.Tokenize_File
           (Path, (if Master then Basic.Basic_IV else Basic.Basic_II));
         if Basic.Error_Count > 0 then
            Err := To_Unbounded_String
              ("line" & Basic.Error_Line (1)'Image & ": " &
               Basic.Error_Text (1));
            return;
         end if;
         declare
            Data : Byte_Array (0 .. Basic.Program_Length - 1);
         begin
            for I in Data'Range loop
               Data (I) := Basic.Program_Byte (I);
            end loop;
            Inject_And_Run (Data, Basic.Program_Load, "RUN");
         end;
         Ok := True;
      elsif Asm.Is_Source (Path) then
         Asm.Assemble (Path);
         if Asm.Has_Errors or else not Asm.Has_Output then
            Err := To_Unbounded_String
              ((if Asm.Error_Count > 0
                then "line" & Asm.Error_Line (1)'Image & ": " &
                     Asm.Error_Text (1)
                else "no code generated"));
            return;
         end if;
         declare
            Low : constant Word := Asm.Low_Address;
            Data : Byte_Array (0 .. Natural (Asm.High_Address - Low));
            Hex : constant String := Disasm.Hex4 (Asm.Start_Address);
         begin
            for I in Data'Range loop
               Data (I) := Asm.Output_Byte (Low + Word (I));
            end loop;
            Inject_And_Run (Data, Low,
                            (if Asm.Has_Basic_Stub and then Low = Default_Page
                             then "RUN" else "CALL &" & Hex));
         end;
         Ok := True;
      elsif Ext = "uef" then
         Attach_Tape (Path, Ok);
         if not Ok then
            return;
         end if;
         Reset;
         Auto_Data := null;
         Auto_Command := To_Unbounded_String
           ("*TAPE" & ASCII.LF &
            (if Tape.First_Block_Is_BASIC then "CHAIN """"" else "*RUN"));
         Auto := Wait_Prompt;
         Auto_Frames := 0;
      else
         Err := To_Unbounded_String ("unknown file type: " & Path);
      end if;
   end Autostart;

   ---------------------------------------------------------------------
   --  Discs
   ---------------------------------------------------------------------

   procedure Attach (Path : String; Ok : out Boolean; Drive : Natural := 0)
   is
   begin
      Disc_Image.Attach (Disc_Image.Drive_Number (Drive mod 2), Path, Ok);
      if not Ok then
         Err := To_Unbounded_String ("cannot read disc image " & Path);
      end if;
   end Attach;

   procedure Detach (Drive : Natural := 0) is
   begin
      Disc_Image.Detach (Disc_Image.Drive_Number (Drive mod 2));
   end Detach;

   function Disc_Name (Drive : Natural := 0) return String is
     (Disc_Image.Name (Disc_Image.Drive_Number (Drive mod 2)));

   function Drive_LED return Boolean is
     (if Has_1770 then WD1770.Motor_On else FDC8271.Motor_On);

   procedure Create_Disc (Path : String; Ok : out Boolean) is
      Base : constant String := Ada.Directories.Base_Name (Path);
   begin
      Disc_Image.Create_Image
        (Path, 80, Base (Base'First .. Base'First +
                         Natural'Min (12, Base'Length) - 1), Ok);
   end Create_Disc;

   ---------------------------------------------------------------------
   --  Tape
   ---------------------------------------------------------------------

   procedure Attach_Tape (Path : String; Ok : out Boolean) is
   begin
      Tape.Attach (Path, Ok);
      if not Ok then
         Err := To_Unbounded_String ("not a UEF tape image: " & Path);
      end if;
   end Attach_Tape;

   function Tape_Name return String is (Tape.Name);

   procedure Tape_Rewind is
   begin
      Tape.Rewind;
   end Tape_Rewind;

   function Tape_Motor return Boolean is (Tape.Motor and then Tape.Present);
   function Tape_Recorded return Natural is (Tape.Recorded_Bytes);

   procedure Save_Tape_Recording (Path : String; Ok : out Boolean) is
   begin
      Tape.Save_Recording (Path, Ok);
   end Save_Tape_Recording;

   ---------------------------------------------------------------------
   --  Snapshots
   ---------------------------------------------------------------------

   Snapshot_Magic : constant String := "ADABEEB3";
   Magic_2 : constant String := "ADABEEB2";         --  Tube is a 6502
   Old_Magic : constant String := "ADABEEB1";       --  no Tube flag

   procedure Save_Snapshot (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
   begin
      Ok := False;
      Create (F, Out_File, Path);
      S := Stream (F);
      String'Write (S, Snapshot_Magic);
      Model_Type'Write (S, Current_Model);
      Boolean'Write (S, Tube_On);
      if Tube_On then
         Tube.Parasite_Type'Write (S, Tube.Kind);
      end if;
      Byte_Array'Write (S, RAM);
      for B in 0 .. 15 loop
         Boolean'Write (S, Bank_Is_RAM (B));
         if Bank_Is_RAM (B) then
            ROM_Bank'Write (S, Banks (B));
         end if;
      end loop;
      Natural'Write (S, ROMSEL);
      Byte'Write (S, CPU.A);
      Byte'Write (S, CPU.X);
      Byte'Write (S, CPU.Y);
      Byte'Write (S, CPU.SP);
      Word'Write (S, CPU.PC);
      Byte'Write (S, CPU.Get_P);
      Boolean'Write (S, CPU.NMI_Pending);
      VIA.Chip'Write (S, Sys_VIA);
      VIA.Chip'Write (S, User_VIA);
      Byte'Write (S, IC32);
      Natural'Write (S, VIA_Phase);
      CRTC.Save_State (S);
      Sound.Save_State (S);
      Byte'Write (S, ADC_Status);
      Byte'Write (S, ADC_High);
      Byte'Write (S, ADC_Low);
      Integer'Write (S, ADC_Time);
      Long_Long_Integer'Write (S, Total_Cycles);
      FDC8271.Save_State (S);
      WD1770.Save_State (S);
      Byte'Write (S, ACCCON);
      Boolean'Write (S, ANDY);
      Byte_Array'Write (S, CMOS);
      Tape.Save_State (S);
      for D in Disc_Image.Drive_Number loop
         declare
            P : constant String := Disc_Image.Path (D);
         begin
            Natural'Write (S, P'Length);
            String'Write (S, P);
         end;
      end loop;
      if Tube_On then
         Tube.Save_State (S);
      end if;
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Err := To_Unbounded_String ("cannot write " & Path);
   end Save_Snapshot;

   procedure Load_Snapshot (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
      Magic : String (1 .. 8);
      M : Model_Type;
      P : Byte;
      With_Tube : Boolean := False;
   begin
      Ok := False;
      Open (F, In_File, Path);
      S := Stream (F);
      String'Read (S, Magic);
      if Magic /= Snapshot_Magic and then Magic /= Magic_2
        and then Magic /= Old_Magic
      then
         Close (F);
         Err := To_Unbounded_String ("not an AdaBeeb snapshot");
         return;
      end if;
      Model_Type'Read (S, M);
      if M /= Current_Model then
         Close (F);
         Err := To_Unbounded_String ("snapshot is for another model");
         return;
      end if;
      if Magic /= Old_Magic then
         Boolean'Read (S, With_Tube);
      end if;
      if With_Tube /= Tube_On then
         Close (F);
         Err := To_Unbounded_String
           (if With_Tube
            then "snapshot needs a Second Processor (Tube)"
            else "snapshot is for a machine without the Second Processor");
         return;
      end if;
      if With_Tube then
         declare
            K : Tube.Parasite_Type := Tube.CPU_6502;   --  ADABEEB2
         begin
            if Magic = Snapshot_Magic then
               Tube.Parasite_Type'Read (S, K);
            end if;
            if K /= Tube.Kind then
               Close (F);
               Err := To_Unbounded_String
                 ("snapshot is for the other kind of Second Processor");
               return;
            end if;
         end;
      end if;
      Byte_Array'Read (S, RAM);
      for B in 0 .. 15 loop
         Boolean'Read (S, Bank_Is_RAM (B));
         if Bank_Is_RAM (B) then
            ROM_Bank'Read (S, Banks (B));
         end if;
      end loop;
      Natural'Read (S, ROMSEL);
      Byte'Read (S, CPU.A);
      Byte'Read (S, CPU.X);
      Byte'Read (S, CPU.Y);
      Byte'Read (S, CPU.SP);
      Word'Read (S, CPU.PC);
      Byte'Read (S, P);
      CPU.Set_P (P);
      Boolean'Read (S, CPU.NMI_Pending);
      VIA.Chip'Read (S, Sys_VIA);
      VIA.Chip'Read (S, User_VIA);
      Byte'Read (S, IC32);
      Natural'Read (S, VIA_Phase);
      CRTC.Load_State (S);
      Sound.Load_State (S);
      Byte'Read (S, ADC_Status);
      Byte'Read (S, ADC_High);
      Byte'Read (S, ADC_Low);
      Integer'Read (S, ADC_Time);
      Long_Long_Integer'Read (S, Total_Cycles);
      FDC8271.Load_State (S);
      WD1770.Load_State (S);
      Byte'Read (S, ACCCON);
      Boolean'Read (S, ANDY);
      Byte_Array'Read (S, CMOS);
      Tape.Load_State (S);
      for D in Disc_Image.Drive_Number loop
         declare
            Len : Natural;
         begin
            Natural'Read (S, Len);
            declare
               P : String (1 .. Len);
               D_Ok : Boolean;
            begin
               String'Read (S, P);
               if Len > 0 and then P /= Disc_Image.Path (D) then
                  Disc_Image.Attach (D, P, D_Ok);
               end if;
            end;
         end;
      end loop;
      if With_Tube then
         Tube.Load_State (S);
      end if;
      Close (F);
      Keyboard.Release_All;
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         Err := To_Unbounded_String ("cannot read snapshot " & Path);
   end Load_Snapshot;

   ---------------------------------------------------------------------
   --  Debugger support
   ---------------------------------------------------------------------

   Max_Breakpoints : constant := 64;
   Breakpoints : array (1 .. Max_Breakpoints) of Word := (others => 0);
   BP_Count    : Natural := 0;
   Break_Flag  : Boolean := False;
   Skip_Break  : Boolean := False;

   procedure Set_Breakpoint (Addr : Word) is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            return;
         end if;
      end loop;
      if BP_Count < Max_Breakpoints then
         BP_Count := BP_Count + 1;
         Breakpoints (BP_Count) := Addr;
      end if;
   end Set_Breakpoint;

   procedure Clear_Breakpoint (Addr : Word) is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            Breakpoints (I) := Breakpoints (BP_Count);
            BP_Count := BP_Count - 1;
            return;
         end if;
      end loop;
   end Clear_Breakpoint;

   procedure Clear_Breakpoints is
   begin
      BP_Count := 0;
   end Clear_Breakpoints;

   function Breakpoint_List return String is
      R : Unbounded_String;
   begin
      for I in 1 .. BP_Count loop
         Append (R, " $" & Disasm.Hex4 (Breakpoints (I)));
      end loop;
      return (if BP_Count = 0 then " (none)" else To_String (R));
   end Breakpoint_List;

   function Break_Hit return Boolean is (Break_Flag);

   Reason      : Stop_Reason := None;
   Pause_Req   : Boolean := False;
   Temp_Addr   : Integer := -1;
   Temp_SP     : Byte := 0;
   Out_Active  : Boolean := False;
   Out_SP      : Byte := 0;

   ---------------------------------------------------------------------
   --  BASIC line breakpoints
   ---------------------------------------------------------------------

   Max_Basic_BP : constant := 64;
   Basic_BPs : array (1 .. Max_Basic_BP) of Natural := (others => 0);
   Basic_BP_Count : Natural := 0;
   Basic_Stepping : Boolean := False;
   Basic_Last_Line : Integer := -1;    --  line the pointer was in
   Basic_Stopped : Integer := -1;

   --  Program lines in memory: start address and line number, sorted
   Max_Lines : constant := 4000;
   Line_Start : array (1 .. Max_Lines + 1) of Natural;
   Line_Num   : array (1 .. Max_Lines) of Natural;
   Line_Count : Natural := 0;

   function PM (A : Natural) return Byte is (Program_Peek (Word (A)));

   procedure Scan_Basic_Lines is
      A : Natural := Natural (PM (16#18#)) * 256;
      Limit : constant Natural := (if Tube_6502 then 16#F800# else 16#8000#);
   begin
      Line_Count := 0;
      if PM (A) /= 16#0D# then
         return;
      end if;
      A := A + 1;
      while A + 3 < Limit and then PM (A) < 16#80#
        and then Line_Count < Max_Lines
      loop
         declare
            Len : constant Natural := Natural (PM (A + 2));
         begin
            exit when Len < 4;
            Line_Count := Line_Count + 1;
            Line_Start (Line_Count) := A;
            Line_Num (Line_Count) :=
              Natural (PM (A)) * 256 + Natural (PM (A + 1));
            A := A + Len;
         end;
      end loop;
      Line_Start (Line_Count + 1) := A;
   end Scan_Basic_Lines;

   function Line_At (Ptr : Natural) return Integer is
      Lo : Natural := 1;
      Hi : Natural := Line_Count;
   begin
      if Line_Count = 0 or else Ptr < Line_Start (1)
        or else Ptr >= Line_Start (Line_Count + 1)
      then
         return -1;
      end if;
      while Lo < Hi loop
         declare
            Mid : constant Natural := (Lo + Hi + 1) / 2;
         begin
            if Line_Start (Mid) <= Ptr then
               Lo := Mid;
            else
               Hi := Mid - 1;
            end if;
         end;
      end loop;
      return Line_Num (Lo);
   end Line_At;

   procedure Clear_Basic_Breakpoints is
   begin
      Basic_BP_Count := 0;
   end Clear_Basic_Breakpoints;

   procedure Add_Basic_Breakpoint (Line_Number : Natural) is
   begin
      if Basic_BP_Count < Max_Basic_BP then
         Basic_BP_Count := Basic_BP_Count + 1;
         Basic_BPs (Basic_BP_Count) := Line_Number;
         Scan_Basic_Lines;
      end if;
   end Add_Basic_Breakpoint;

   function Basic_Stop_Line return Integer is (Basic_Stopped);

   --  True when BASIC just moved into a line it should stop at
   function Basic_Check return Boolean is
      Ptr : constant Natural :=
        Natural (PM (16#0B#)) + 256 * Natural (PM (16#0C#));
      L : constant Integer := Line_At (Ptr);
   begin
      if L = Basic_Last_Line then
         return False;
      end if;
      Basic_Last_Line := L;
      if L < 0 then
         return False;
      end if;
      if Basic_Stepping then
         Basic_Stopped := L;
         return True;
      end if;
      for I in 1 .. Basic_BP_Count loop
         if Basic_BPs (I) = L then
            Basic_Stopped := L;
            return True;
         end if;
      end loop;
      return False;
   end Basic_Check;

   function Debugging return Boolean is
     (BP_Count > 0 or else Watch_Count > 0 or else Temp_Addr >= 0
      or else Out_Active or else Pause_Req or else Basic_BP_Count > 0
      or else Basic_Stepping);

   procedure Stop (R : Stop_Reason) is
   begin
      Break_Flag := True;
      Reason := R;
      Temp_Addr := -1;
      Out_Active := False;
      Pause_Req := False;
      Basic_Stepping := False;
   end Stop;

   ---------------------------------------------------------------------
   --  Debugging the Second Processor: hooks the Tube calls around each
   --  parasite instruction and on its memory accesses
   ---------------------------------------------------------------------

   P_Reason : Stop_Reason := None;
   P_Step   : Boolean := False;       --  stop after one instruction

   function P_Before (PC : Word; SP : Byte) return Boolean is
   begin
      if not Parasite_Debug then
         return False;
      elsif BP_Count > 0 and then Is_Breakpoint (PC) then
         P_Reason := Breakpoint;
         return True;
      elsif Temp_Addr >= 0 and then Integer (PC) = Temp_Addr
        and then SP >= Temp_SP
      then
         P_Reason := Step_Done;
         return True;
      end if;
      return False;
   end P_Before;

   function P_After (Op : Byte) return Boolean is
   begin
      if (Basic_BP_Count > 0 or else Basic_Stepping) and then Basic_Check
      then
         P_Reason := Basic_Line;    --  with the Tube, BASIC runs here
         return True;
      elsif not Parasite_Debug then
         return False;
      elsif Watch_Hit then
         Watch_Hit := False;
         P_Reason := (if Watch_Write_Hit then Watch_Write else Watch_Read);
         return True;
      elsif P_Step then
         P_Reason := Step_Done;
         return True;
      elsif Out_Active and then Op in 16#60# | 16#40#
        and then Tube.Parasite_SP > Out_SP
      then
         P_Reason := Step_Done;
         return True;
      end if;
      return False;
   end P_After;

   procedure P_Access (Addr : Word; Is_Write : Boolean) is
   begin
      if Watch_Count > 0 then
         Check_Watch (Addr, Is_Write);
      end if;
   end P_Access;

   procedure Update_Tube_Hooks is
   begin
      if Tube_6502 and then ((Parasite_Debug and then (Debugging or P_Step))
                           or else Basic_BP_Count > 0 or else Basic_Stepping)
      then
         Tube.Before := P_Before'Access;
         Tube.After := P_After'Access;
         Tube.On_Access :=
           (if Parasite_Debug and then Watch_Count > 0
            then P_Access'Access else null);
      else
         Tube.Before := null;
         Tube.After := null;
         Tube.On_Access := null;
      end if;
   end Update_Tube_Hooks;

   procedure Step_Basic_Line is
   begin
      Scan_Basic_Lines;
      Basic_Stepping := True;
      Resume;
   end Step_Basic_Line;

   procedure Resume is
   begin
      Break_Flag := False;
      Skip_Break := True;
      Watch_Hit := False;
      Tube.Resume;
   end Resume;

   function Last_Stop return Stop_Reason is (Reason);

   function Stop_Text return String is
   begin
      case Reason is
         when None => return "";
         when Breakpoint => return "breakpoint at $" & Disasm.Hex4 (CPU_PC);
         when Watch_Read =>
            return "read of $" & Disasm.Hex4 (Watch_Addr) & " (PC $" &
              Disasm.Hex4 (CPU_PC) & ")";
         when Watch_Write =>
            return "write to $" & Disasm.Hex4 (Watch_Addr) & " (PC $" &
              Disasm.Hex4 (CPU_PC) & ")";
         when Step_Done => return "stopped at $" & Disasm.Hex4 (CPU_PC);
         when Paused => return "paused at $" & Disasm.Hex4 (CPU_PC);
         when Basic_Line =>
            return "BASIC line" & Basic_Stopped'Image;
      end case;
   end Stop_Text;

   procedure Request_Break is
   begin
      if not Break_Flag then
         Pause_Req := True;
      end if;
   end Request_Break;

   procedure Run_To (Addr : Word) is
   begin
      Temp_Addr := Integer (Addr);
      Temp_SP := 0;
      Resume;
   end Run_To;

   procedure Step_Out is
   begin
      Out_Active := True;
      Out_SP := (if Parasite_Debug then Tube.Parasite_SP else CPU.SP);
      Resume;
   end Step_Out;

   procedure Add_Watch (From, To : Word; On_Read, On_Write : Boolean) is
   begin
      for I in 1 .. Watch_Count loop
         if Watches (I).From = From then
            Watches (I) := (From, To, On_Read, On_Write);
            return;
         end if;
      end loop;
      if Watch_Count < Max_Watches then
         Watch_Count := Watch_Count + 1;
         Watches (Watch_Count) := (From, To, On_Read, On_Write);
      end if;
   end Add_Watch;

   procedure Remove_Watch (From : Word) is
   begin
      for I in 1 .. Watch_Count loop
         if Watches (I).From = From then
            Watches (I) := Watches (Watch_Count);
            Watch_Count := Watch_Count - 1;
            return;
         end if;
      end loop;
   end Remove_Watch;

   procedure Clear_Watches is
   begin
      Watch_Count := 0;
      Watch_Hit := False;
   end Clear_Watches;

   function Watch_List return String is
      R : Unbounded_String;
   begin
      for I in 1 .. Watch_Count loop
         Append (R, " $" & Disasm.Hex4 (Watches (I).From) &
                 (if Watches (I).To /= Watches (I).From
                  then "-$" & Disasm.Hex4 (Watches (I).To) else "") &
                 (if Watches (I).On_Read then " r" else "") &
                 (if Watches (I).On_Write then " w" else ""));
      end loop;
      return (if Watch_Count = 0 then " (none)" else To_String (R));
   end Watch_List;

   function Cycle_Count return Long_Long_Integer is (Total_Cycles);

   function Is_Breakpoint (Addr : Word) return Boolean is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = Addr then
            return True;
         end if;
      end loop;
      return False;
   end Is_Breakpoint;

   function Monitor_Peek (Addr : Word) return Byte is
     (if Parasite_Debug then Tube.Parasite_Peek (Addr) else Peek (Addr));

   procedure Monitor_Poke (Addr : Word; Value : Byte) is
   begin
      if Parasite_Debug then
         Tube.Parasite_Poke (Addr, Value);
      else
         Poke (Addr, Value);
      end if;
   end Monitor_Poke;

   function Flags_Text (P : Byte) return String is
      function F (Bit : Byte; C : Character) return Character is
        (if (P and Bit) /= 0 then C else '.');
   begin
      return F (16#80#, 'N') & F (16#40#, 'V') & "-B" &
        F (16#08#, 'D') & F (16#04#, 'I') & F (16#02#, 'Z') &
        F (16#01#, 'C');
   end Flags_Text;

   function Flags_Text return String is (Flags_Text (CPU.Get_P));

   function Host_Register_Text return String;

   function Register_Text return String is
   begin
      if Parasite_Debug then
         return "PC=" & Disasm.Hex4 (Tube.Parasite_PC) &
           " A=" & Disasm.Hex2 (Tube.Parasite_A) &
           " X=" & Disasm.Hex2 (Tube.Parasite_X) &
           " Y=" & Disasm.Hex2 (Tube.Parasite_Y) &
           " SP=" & Disasm.Hex2 (Tube.Parasite_SP) & " " &
           Flags_Text (Tube.Parasite_P) & " (Second Processor)";
      end if;
      return Host_Register_Text;
   end Register_Text;

   function Host_Register_Text return String is
   begin
      return "PC=" & Disasm.Hex4 (CPU.PC) & " A=" & Disasm.Hex2 (CPU.A) &
        " X=" & Disasm.Hex2 (CPU.X) & " Y=" & Disasm.Hex2 (CPU.Y) &
        " SP=" & Disasm.Hex2 (CPU.SP) & " " & Flags_Text &
        " ROM=" & Disasm.Hex2 (Byte (ROMSEL)) &
        (if Has_1770 then " ACCCON=" & Disasm.Hex2 (ACCCON) &
           (if ANDY then " ANDY" else "") else "");
   end Host_Register_Text;

   function CPU_PC return Word is
     (if Parasite_Debug then Tube.Parasite_PC else CPU.PC);

   procedure Monitor_Set_PC (Addr : Word) is
   begin
      if Parasite_Debug then
         Tube.Set_Parasite_PC (Addr);
      else
         CPU.PC := Addr;
      end if;
   end Monitor_Set_PC;

   function Debug_Info return String is
   begin
      return Host_Register_Text & " IC32=" & Disasm.Hex2 (IC32) &
        " SysVIA IFR=" & Disasm.Hex2 (Sys_VIA.IFR) &
        " IER=" & Disasm.Hex2 (Sys_VIA.IER) &
        " PCR=" & Disasm.Hex2 (Sys_VIA.PCR) &
        " ULA=" & Disasm.Hex2 (CRTC.ULA_Control) &
        " R12/13=" & Disasm.Hex2 (CRTC.CRTC_Register (12)) &
        Disasm.Hex2 (CRTC.CRTC_Register (13)) &
        " frames=" & Frames'Image;
   end Debug_Info;

   procedure Shutdown is
   begin
      if Master then
         Save_CMOS;
      end if;
      Disc_Image.Flush (0);
      Disc_Image.Flush (1);
   end Shutdown;

   ---------------------------------------------------------------------
   --  Main loop
   ---------------------------------------------------------------------

   NMI_Prev : Boolean := False;

   function NMI_Line return Boolean is
     (if Has_1770 then WD1770.NMI else FDC8271.INT);

   procedure End_Of_Frame is
   begin
      Keyboard.Tick_Typing;
      Autostart_Step;
      if Shift_Frames > 0 then
         Shift_Frames := Shift_Frames - 1;
         if Shift_Frames = 0 then
            Keyboard.Hold_Shift := False;
            Keyboard.Hold_Key := -1;
         end if;
      end if;
      Frames := Frames + 1;
      if Basic_BP_Count > 0 or else Basic_Stepping then
         Scan_Basic_Lines;        --  the program may have changed
      end if;
   end End_Of_Frame;


   function IRQ_Now return Boolean is
     (VIA_IRQ_Out or else Tape.IRQ or else Tube.Host_IRQ);

   function Step_System return Boolean is
      N : Natural;
      Rest : Natural;
      NMI_Now : Boolean;
   begin
      if Break_Was_Down then
         Clock_Devices (64);           --  CPU held in reset
         return False;
      end if;
      CPU.IRQ_Line := IRQ_Sampled;
      NMI_Now := NMI_Line;
      if NMI_Now and then not NMI_Prev then
         CPU.NMI_Pending := True;
      end if;
      NMI_Prev := NMI_Now;

      Instr_Ticked := 0;
      Instr_Extra := 0;
      Instr_Access := 0;
      Sample_Taken := False;
      Sample_Here := False;
      In_Step := True;
      Instr_PC := CPU.PC;
      CPU.Step (N);
      In_Step := False;
      Rest := N + Instr_Extra;
      Rest := (if Rest > Instr_Ticked then Rest - Instr_Ticked else 0);
      Instr_Ticked := 0;
      Instr_Extra := 0;
      --  The 6502 polls IRQ before the last cycle of an instruction: an
      --  interrupt raised in that cycle waits for the next instruction.
      --  (sampled in phi2 of the penultimate cycle, before its clock edge)
      if Sample_Taken then
         if Rest > 0 then
            Clock_Devices (Rest);
         end if;
      else
         if Rest > Sample_Offset then
            Clock_Devices (Rest - Sample_Offset);
         end if;
         IRQ_Sampled := IRQ_Now;
         if Rest > 0 then
            Clock_Devices (Natural'Min (Rest, Sample_Offset));
         end if;
      end if;
      return True;
   end Step_System;

   function At_Breakpoint return Boolean is
   begin
      for I in 1 .. BP_Count loop
         if Breakpoints (I) = CPU.PC then
            return True;
         end if;
      end loop;
      return False;
   end At_Breakpoint;

   Max_Frame_Cycles : constant := 2_000_000 / 25;   --  no VSYNC at all
   Min_Frame_Cycles : constant := 2_000_000 / 200;

   procedure Run_Frame is
      Executed : Boolean;
      Op : Byte := 0;
      Start : constant Long_Long_Integer := Total_Cycles;
   begin
      if Break_Flag then
         return;
      end if;
      Break_Key (Keyboard.Break_Down);
      Update_Tube_Hooks;
      loop
         if CRTC.Frame_Done then
            --  ignore VSYNCs of an unprogrammed / tiny CRTC frame
            exit when Total_Cycles - Start > Min_Frame_Cycles;
            CRTC.Frame_Done := False;
         end if;
         exit when Total_Cycles - Start > Max_Frame_Cycles;
         if Debugging and then not Break_Was_Down then
            if Pause_Req then
               Stop (Paused);
               return;
            end if;
            if not Skip_Break and then not Parasite_Debug then
               if BP_Count > 0 and then At_Breakpoint then
                  Stop (Breakpoint);
                  return;
               end if;
               if Temp_Addr >= 0 and then Integer (CPU.PC) = Temp_Addr
                 and then CPU.SP >= Temp_SP
               then
                  Stop (Step_Done);
                  return;
               end if;
            end if;
            Skip_Break := False;
            if Out_Active and then not Parasite_Debug then
               Op := Peek (CPU.PC);
            end if;
         end if;
         Executed := Step_System;
         if Tube.Halted then
            Stop (P_Reason);
            return;
         end if;
         if Executed and then (Basic_BP_Count > 0 or else Basic_Stepping)
           and then not Tube_6502 and then Basic_Check
         then
            Stop (Basic_Line);
            return;
         end if;
         if Executed and then not Parasite_Debug
           and then (Watch_Hit or else Out_Active)
         then
            if Watch_Hit then
               Watch_Hit := False;
               Stop (if Watch_Write_Hit then Watch_Write else Watch_Read);
               return;
            end if;
            if Op in 16#60# | 16#40# and then CPU.SP > Out_SP then
               Stop (Step_Done);
               return;
            end if;
         end if;
      end loop;
      CRTC.Frame_Done := False;
      End_Of_Frame;
   end Run_Frame;

   procedure Step_Instruction is
      Dummy : Boolean;
   begin
      if Parasite_Debug then
         --  run the host until the parasite has done one instruction
         P_Step := True;
         Update_Tube_Hooks;
         Tube.Resume;
         for I in 1 .. 1_000_000 loop
            Dummy := Step_System;
            if CRTC.Frame_Done then
               CRTC.Frame_Done := False;
               End_Of_Frame;
            end if;
            exit when Tube.Halted;
         end loop;
         P_Step := False;
         Watch_Hit := False;
         Skip_Break := True;
         Reason := Step_Done;
         return;
      end if;
      Tube.Resume;
      loop
         exit when Step_System;
      end loop;
      Watch_Hit := False;
      if CRTC.Frame_Done then
         CRTC.Frame_Done := False;
         End_Of_Frame;
      end if;
      Skip_Break := True;
      Reason := Step_Done;
   end Step_Instruction;

   procedure Step_Over is
   begin
      if Parasite_Debug then
         if Tube.Parasite_Peek (Tube.Parasite_PC) = 16#20# then
            Temp_Addr := Integer (Tube.Parasite_PC + 3);
            Temp_SP := Tube.Parasite_SP;
            Resume;
         else
            Step_Instruction;
         end if;
         return;
      end if;
      if Peek (CPU.PC) = 16#20# then
         Temp_Addr := Integer (CPU.PC + 3);
         Temp_SP := CPU.SP;
         Resume;
      else
         Step_Instruction;
      end if;
   end Step_Over;

end Machine;
