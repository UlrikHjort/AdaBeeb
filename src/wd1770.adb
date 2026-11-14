-- ***************************************************************************
--                              AdaBeeb - WD1770
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
with Disc_Image; use Disc_Image;

package body WD1770 is

   --  Status bits
   S_Busy  : constant Byte := 16#01#;
   S_DRQ   : constant Byte := 16#02#;   --  type I: index pulse
   S_Track0 : constant Byte := 16#04#;  --  type II/III: lost data
   S_RNF   : constant Byte := 16#10#;
   S_Spin  : constant Byte := 16#20#;   --  type I: spin-up complete
   S_WP    : constant Byte := 16#40#;
   S_Motor : constant Byte := 16#80#;

   Byte_Time : constant := 128;          --  FM: 64 us per byte

   Status, Track_Reg, Sector_Reg, Data_Reg, Command : Byte := 0;
   Control : Byte := 0;
   Head_Track : array (0 .. 1) of Natural := (others => 0);
   Step_Dir : Integer := 1;
   INTRQ, DRQ : Boolean := False;
   Motor_Count : Integer := 0;
   Type_I : Boolean := True;

   type Phase_Type is (Idle, Stepping, Reading, Writing, Read_Addr,
                       Write_Track, Finishing);
   Phase : Phase_Type := Idle;
   Timer : Integer := 0;
   Pos : Natural := 0;
   Multi : Boolean := False;
   Index_Count : Natural := 0;

   function Drive return Natural is
     (if (Control and 2) /= 0 and then (Control and 1) = 0 then 1 else 0);
   function Side return Natural is
     (if (Control and 16#10#) /= 0 then 1 else 0);
   function Selected return Boolean is ((Control and 3) /= 0);
   function D return Drive_Number is (Drive_Number (Drive));
   function Ready return Boolean is (Selected and then Present (D));

   procedure Reset is
   begin
      Status := 0;
      Track_Reg := 0;
      Sector_Reg := 1;
      Data_Reg := 0;
      Command := 0;
      INTRQ := False;
      DRQ := False;
      Phase := Idle;
      Timer := 0;
      Type_I := True;
   end Reset;

   function NMI return Boolean is (INTRQ or else DRQ);
   function Motor_On return Boolean is (Motor_Count > 0);

   procedure Write_Control (Value : Byte) is
   begin
      Control := Value;
      if (Value and 4) = 0 then
         Reset;                 --  reset line (active low)
      end if;
   end Write_Control;

   procedure Finish (Extra : Byte := 0) is
   begin
      Status := ((Status and not (S_Busy or S_DRQ)) or Extra) or S_Motor;
      DRQ := False;
      INTRQ := True;
      Phase := Idle;
   end Finish;

   procedure Spin is
   begin
      Motor_Count := 2_000_000 * 2;
   end Spin;

   procedure Start_Command (Value : Byte) is
      Kind : constant Byte := Shift_Right (Value, 4);
   begin
      if (Value and 16#F0#) = 16#D0# then        --  force interrupt
         Phase := Idle;
         DRQ := False;
         Status := Status and not S_Busy;
         if (Value and 16#08#) /= 0 then
            --  "immediate" interrupt: INTRQ follows after the 1770 has
            --  decoded the command (a few microseconds)
            Phase := Finishing;
            Timer := 40;
            Status := Status or S_Busy;
         end if;
         return;
      end if;
      if (Status and S_Busy) /= 0 then
         return;
      end if;
      Command := Value;
      INTRQ := False;
      DRQ := False;
      Spin;
      Status := S_Busy or S_Motor;
      Pos := 0;
      if Kind <= 7 then                           --  type I
         Type_I := True;
         declare
            Target : Integer := Integer (Head_Track (Drive));
         begin
            case Kind is
               when 0 =>
                  Target := 0;
                  Track_Reg := 0;
               when 1 =>
                  Step_Dir := (if Data_Reg > Track_Reg then 1 else -1);
                  Target := Integer (Head_Track (Drive)) +
                    Integer (Data_Reg) - Integer (Track_Reg);
                  Track_Reg := Data_Reg;
               when 2 | 3 =>
                  Target := Target + Step_Dir;
               when 4 | 5 =>
                  Step_Dir := 1;
                  Target := Target + 1;
               when others =>
                  Step_Dir := -1;
                  Target := Target - 1;
            end case;
            if Kind in 3 | 5 | 7 then             --  update the track reg
               Track_Reg := Byte ((Integer (Track_Reg) + Step_Dir) mod 256);
            end if;
            Target := Integer'Max (0, Integer'Min (81, Target));
            Timer := 400 + 1000 * abs (Target - Integer (Head_Track (Drive)));
            Head_Track (Drive) := Target;
            Phase := Stepping;
         end;
      else
         Type_I := False;
         case Kind is
            when 8 | 9 =>
               Multi := Kind = 9;
               Phase := Reading;
               Timer := Byte_Time * 8;
            when 10 | 11 =>
               Multi := Kind = 11;
               if Ready and then Read_Only (D) then
                  Finish (S_WP);
                  return;
               end if;
               Phase := Writing;
               DRQ := True;
               Status := Status or S_DRQ;
               Timer := Byte_Time * 8;
            when 12 =>
               Phase := Read_Addr;
               Timer := Byte_Time * 8;
            when 15 =>
               if Ready and then Read_Only (D) then
                  Finish (S_WP);
                  return;
               end if;
               Phase := Write_Track;
               DRQ := True;
               Status := Status or S_DRQ;
               Timer := Byte_Time * 3000;   --  one revolution
            when others =>                 --  read track: not supported
               Finish (S_RNF);
         end case;
         if not Ready and then Phase /= Idle then
            Finish (S_RNF);
         end if;
      end if;
   end Start_Command;

   function Read (Reg : Natural) return Byte is
   begin
      case Reg mod 4 is
         when 0 =>
            INTRQ := False;
            if Type_I and then (Status and S_Busy) = 0 then
               declare
                  S : Byte := Status and not (S_DRQ or S_Track0 or S_WP);
               begin
                  if Head_Track (Drive) = 0 then
                     S := S or S_Track0;
                  end if;
                  if Ready and then Read_Only (D) then
                     S := S or S_WP;
                  end if;
                  Index_Count := Index_Count + 1;
                  if Index_Count mod 16 = 0 then
                     S := S or S_DRQ;          --  index pulse
                  end if;
                  return S or S_Spin;
               end;
            end if;
            return Status;
         when 1 => return Track_Reg;
         when 2 => return Sector_Reg;
         when others =>
            DRQ := False;
            Status := Status and not S_DRQ;
            return Data_Reg;
      end case;
   end Read;

   procedure Write (Reg : Natural; Value : Byte) is
   begin
      case Reg mod 4 is
         when 0 => Start_Command (Value);
         when 1 => Track_Reg := Value;
         when 2 => Sector_Reg := Value;
         when others =>
            Data_Reg := Value;
            DRQ := False;
            Status := Status and not S_DRQ;
      end case;
   end Write;

   procedure Request is
   begin
      DRQ := True;
      Status := Status or S_DRQ;
   end Request;

   function Sector_Ok return Boolean is
     (Ready and then Natural (Track_Reg) = Head_Track (Drive)
      and then Has_Sector (D, Side, Head_Track (Drive),
                           Natural (Sector_Reg)));

   procedure Event is
   begin
      case Phase is
         when Idle => null;
         when Finishing => Finish;
         when Stepping =>
            if (Command and 16#04#) /= 0 and then Ready
              and then Natural (Track_Reg) /= Head_Track (Drive)
            then
               Finish (S_RNF);           --  verify failed
            else
               Finish;
            end if;
         when Reading =>
            if Pos = 0 and then not Sector_Ok then
               Finish (S_RNF);
               return;
            end if;
            if Pos < 256 then
               Data_Reg := Get (D, Side, Head_Track (Drive),
                                Natural (Sector_Reg), Pos);
               Request;
               Pos := Pos + 1;
               Timer := Byte_Time;
            elsif Multi then
               Sector_Reg := Sector_Reg + 1;
               Pos := 0;
               if not Sector_Ok then
                  Finish;                 --  end of track
               else
                  Timer := Byte_Time * 8;
               end if;
            else
               Finish;
            end if;
         when Writing =>
            if Pos = 0 and then not Sector_Ok then
               Finish (S_RNF);
               return;
            end if;
            if Pos < 256 then
               Put (D, Side, Head_Track (Drive), Natural (Sector_Reg), Pos,
                    Data_Reg);
               Pos := Pos + 1;
               if Pos < 256 then
                  Request;
               end if;
               Timer := Byte_Time;
            elsif Multi then
               Sector_Reg := Sector_Reg + 1;
               Pos := 0;
               if not Sector_Ok then
                  Flush (D);
                  Finish;
               else
                  Request;
                  Timer := Byte_Time * 8;
               end if;
            else
               Flush (D);
               Finish;
            end if;
         when Read_Addr =>
            if not Ready then
               Finish (S_RNF);
               return;
            end if;
            if Pos < 6 then
               case Pos is
                  when 0 => Data_Reg := Byte (Head_Track (Drive) mod 256);
                  when 1 => Data_Reg := Byte (Side);
                  when 2 => Data_Reg := Byte (Index_Count mod 10);
                  when 3 => Data_Reg := 1;
                  when others => Data_Reg := 0;
               end case;
               if Pos = 0 then
                  Sector_Reg := Data_Reg;  --  the 1770 copies the track
               end if;
               Request;
               Pos := Pos + 1;
               Timer := Byte_Time;
            else
               Finish;
            end if;
         when Write_Track =>
            Format_Track (D, Side, Head_Track (Drive));
            Flush (D);
            Finish;
      end case;
   end Event;

   procedure Tick (Cycles : Natural) is
   begin
      if Motor_Count > 0 then
         Motor_Count := Motor_Count - Cycles;
         if Motor_Count <= 0 then
            Status := Status and not S_Motor;
         end if;
      end if;
      if Phase = Idle then
         return;
      end if;
      Timer := Timer - Cycles;
      while Phase /= Idle and then Timer <= 0 loop
         declare
            Before : constant Integer := Timer;
         begin
            Event;
            if Phase /= Idle then
               Timer := Timer + Before;
            end if;
         end;
      end loop;
      if Phase = Write_Track and then DRQ then
         DRQ := False;                  --  format data is just accepted
         Status := Status and not S_DRQ;
         Request;
      end if;
   end Tick;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte'Write (S, Status);
      Byte'Write (S, Track_Reg);
      Byte'Write (S, Sector_Reg);
      Byte'Write (S, Data_Reg);
      Byte'Write (S, Command);
      Byte'Write (S, Control);
      Natural'Write (S, Head_Track (0));
      Natural'Write (S, Head_Track (1));
      Integer'Write (S, Step_Dir);
      Boolean'Write (S, INTRQ);
      Boolean'Write (S, DRQ);
      Boolean'Write (S, Type_I);
      Phase_Type'Write (S, Phase);
      Integer'Write (S, Timer);
      Natural'Write (S, Pos);
      Boolean'Write (S, Multi);
   end Save_State;

   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte'Read (S, Status);
      Byte'Read (S, Track_Reg);
      Byte'Read (S, Sector_Reg);
      Byte'Read (S, Data_Reg);
      Byte'Read (S, Command);
      Byte'Read (S, Control);
      Natural'Read (S, Head_Track (0));
      Natural'Read (S, Head_Track (1));
      Integer'Read (S, Step_Dir);
      Boolean'Read (S, INTRQ);
      Boolean'Read (S, DRQ);
      Boolean'Read (S, Type_I);
      Phase_Type'Read (S, Phase);
      Integer'Read (S, Timer);
      Natural'Read (S, Pos);
      Boolean'Read (S, Multi);
   end Load_State;

end WD1770;
