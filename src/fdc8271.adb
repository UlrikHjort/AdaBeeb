-- ***************************************************************************
--                             AdaBeeb - FDC8271
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

package body FDC8271 is

   --  Status register bits
   S_Busy      : constant Byte := 16#80#;
   S_Cmd_Full  : constant Byte := 16#40#;
   S_Res_Full  : constant Byte := 16#10#;
   S_Int       : constant Byte := 16#08#;
   S_Data_Req  : constant Byte := 16#04#;

   --  Result codes
   R_OK          : constant Byte := 16#00#;
   R_Not_Ready   : constant Byte := 16#10#;
   R_Write_Prot  : constant Byte := 16#12#;
   R_Not_Found   : constant Byte := 16#18#;
   R_Track0      : constant Byte := 16#14#;
   pragma Unreferenced (R_Track0);

   Byte_Time : constant := 128;    --  64 us per FM byte at 2 MHz

   Status  : Byte := 0;
   Result  : Byte := 0;
   Data    : Byte := 0;
   Command : Byte := 0;
   Params  : array (0 .. 7) of Byte := (others => 0);
   Param_Count, Params_Needed : Natural := 0;
   Special : array (Byte) of Byte := (others => 0);
   Track_Of : array (0 .. 1) of Natural := (others => 0);
   Step_Rate : Natural := 12;      --  ms, from Specify
   Settle    : Natural := 10;
   Head_Load_Time : Natural := 16;

   type Phase_Type is (Idle, Seeking, Transfer_Read, Transfer_Write,
                       Read_IDs, Format_IDs, Finishing);
   Phase : Phase_Type := Idle;
   Timer : Integer := 0;           --  cycles until the next event

   Drive : Natural := 0;           --  0 / 1
   Side  : Natural := 0;
   Cur_Track, Cur_Sector : Natural := 0;
   Sectors_Left : Natural := 0;
   Sector_Bytes : Natural := 256;
   Byte_Pos     : Natural := 0;
   Pending_Result : Byte := 0;
   Motor_Count  : Integer := 0;    --  cycles until the head unloads
   Op : Byte := 0;                 --  command without the drive bits

   procedure Reset is
   begin
      Status := 0;
      Result := 0;
      Data := 0;
      Command := 0;
      Param_Count := 0;
      Params_Needed := 0;
      Phase := Idle;
      Timer := 0;
      Motor_Count := 0;
   end Reset;

   function INT return Boolean is ((Status and S_Int) /= 0);
   function Motor_On return Boolean is (Motor_Count > 0);
   function Current_Track (Drive : Natural) return Natural is
     (Track_Of (Drive mod 2));

   function Param_Total (Cmd : Byte) return Natural is
   begin
      case Cmd and 16#3F# is
         when 16#0A# | 16#0E# | 16#12# | 16#16# | 16#1E# => return 2;
         when 16#0B# | 16#0F# | 16#13# | 16#17# | 16#1B# | 16#1F# =>
            return 3;
         when 16#23# => return 5;
         when 16#29# => return 1;
         when 16#2C# => return 0;
         when 16#35# => return 4;
         when 16#3A# => return 2;
         when 16#3D# => return 1;
         when others => return 0;
      end case;
   end Param_Total;

   procedure Finish (Code : Byte) is
   begin
      Result := Code;
      Status := (Status and not (S_Busy or S_Data_Req)) or S_Res_Full or S_Int;
      Phase := Idle;
   end Finish;

   function Drive_Num return Drive_Number is (Drive_Number (Drive mod 2));

   function Ready return Boolean is (Present (Drive_Num));

   procedure Load_Head is
   begin
      Motor_Count := 2_000_000 * 2;     --  2 s after the last command
   end Load_Head;

   function Seek_Cycles (To : Natural) return Natural is
      Steps : constant Natural :=
        (if To > Track_Of (Drive) then To - Track_Of (Drive)
         else Track_Of (Drive) - To);
   begin
      if Fast_Seek then
         return 400 + Steps * 1000;
      end if;
      return 2000 + Steps * Step_Rate * 2000 +
        (if Steps > 0 then Settle * 2000 else 0);
   end Seek_Cycles;

   procedure Start_Sector_Transfer is
   begin
      Byte_Pos := 0;
      if not Has_Sector (Drive_Num, Side, Cur_Track, Cur_Sector) then
         Finish (R_Not_Found);
         return;
      end if;
      Timer := Byte_Time * 4;
   end Start_Sector_Transfer;

   procedure Execute is
      Count_Size : constant Byte := Params (2);
   begin
      Op := Command and 16#3F#;
      --  Drive select bits 7-6 of the command (01 = drive 0, 10 = drive 1)
      if (Command and 16#C0#) = 16#80# then
         Drive := 1;
      elsif (Command and 16#C0#) = 16#40# then
         Drive := 0;
      end if;
      Special (16#23#) := (Special (16#23#) and 16#3F#) or
        (Command and 16#C0#);
      Side := (if (Special (16#23#) and 16#20#) /= 0 then 1 else 0);
      Status := (Status or S_Busy) and not S_Cmd_Full;

      case Op is
         when 16#0A# | 16#0B# | 16#0E# | 16#0F# |    --  write
              16#12# | 16#13# | 16#16# | 16#17# |    --  read
              16#1E# | 16#1F# =>                     --  verify
            if not Ready then
               Finish (R_Not_Ready);
               return;
            end if;
            Cur_Track := Natural (Params (0));
            Cur_Sector := Natural (Params (1));
            if Op in 16#0A# | 16#0E# | 16#12# | 16#16# | 16#1E# then
               Sectors_Left := 1;
               Sector_Bytes := 128;
            else
               Sectors_Left := Natural (Count_Size and 16#1F#);
               Sector_Bytes := 128 * 2 ** Natural
                 (Shift_Right (Count_Size, 5) and 7);
               if Sectors_Left = 0 then
                  Finish (R_OK);
                  return;
               end if;
            end if;
            if Op in 16#0A# | 16#0B# | 16#0E# | 16#0F#
              and then Read_Only (Drive_Num)
            then
               Finish (R_Write_Prot);
               return;
            end if;
            Load_Head;
            Timer := Seek_Cycles (Cur_Track);
            Track_Of (Drive) := Cur_Track;
            Phase := Seeking;
         when 16#1B# =>                                --  read ID
            if not Ready then
               Finish (R_Not_Ready);
               return;
            end if;
            Cur_Track := Natural (Params (0));
            Sectors_Left := Natural (Params (2));
            Cur_Sector := 0;
            Byte_Pos := 0;
            Load_Head;
            Timer := Seek_Cycles (Cur_Track);
            Track_Of (Drive) := Cur_Track;
            Phase := Seeking;
         when 16#23# =>                                --  format
            if not Ready then
               Finish (R_Not_Ready);
               return;
            end if;
            if Read_Only (Drive_Num) then
               Finish (R_Write_Prot);
               return;
            end if;
            Cur_Track := Natural (Params (0));
            Sectors_Left := Natural (Params (2) and 16#1F#);
            Cur_Sector := 0;
            Byte_Pos := 0;
            Load_Head;
            Timer := Seek_Cycles (Cur_Track);
            Track_Of (Drive) := Cur_Track;
            Phase := Seeking;
         when 16#29# =>                                --  seek
            Load_Head;
            Timer := Seek_Cycles (Natural (Params (0)));
            Track_Of (Drive) := Natural (Params (0));
            Pending_Result := R_OK;
            Phase := Finishing;
         when 16#2C# =>                                --  drive status
            declare
               R : Byte := 16#80#;
            begin
               if Present (0) then
                  R := R or 16#04#;               --  RDY0
               end if;
               if Present (1) then
                  R := R or 16#40#;               --  RDY1
               end if;
               if Track_Of (Drive) = 0 then
                  R := R or 16#02#;               --  TRK0
               end if;
               if Ready and then Read_Only (Drive_Num) then
                  R := R or 16#08#;               --  WR PROT
               end if;
               Result := R;
               Status := (Status and not S_Busy) or S_Res_Full;
            end;
         when 16#35# =>                                --  specify
            if Params (0) = 16#0D# then
               Step_Rate := Natural (Params (1));
               Settle := Natural (Params (2));
               Head_Load_Time := Natural (Params (3) and 16#0F#);
            end if;
            Status := Status and not S_Busy;
         when 16#3A# =>                                --  write special
            Special (Params (0)) := Params (1);
            case Params (0) is
               when 16#12# => Track_Of (0) := Natural (Params (1));
               when 16#1A# => Track_Of (1) := Natural (Params (1));
               when 16#23# =>
                  Side := (if (Params (1) and 16#20#) /= 0 then 1 else 0);
               when others => null;
            end case;
            Status := Status and not S_Busy;
         when 16#3D# =>                                --  read special
            case Params (0) is
               when 16#12# => Result := Byte (Track_Of (0) mod 256);
               when 16#1A# => Result := Byte (Track_Of (1) mod 256);
               when others => Result := Special (Params (0));
            end case;
            Status := (Status and not S_Busy) or S_Res_Full;
         when others =>
            Finish (16#0E#);   --  invalid command: report a CRC-type error
      end case;
   end Execute;

   function Read (Reg : Natural) return Byte is
   begin
      case Reg mod 8 is
         when 0 => return Status;
         when 1 =>
            Status := Status and not (S_Res_Full or S_Int);
            return Result;
         when 4 .. 7 =>
            Status := Status and not (S_Data_Req or S_Int);
            return Data;
         when others => return 16#FF#;
      end case;
   end Read;

   procedure Write (Reg : Natural; Value : Byte) is
   begin
      case Reg mod 8 is
         when 0 =>
            if (Status and S_Busy) /= 0 and then Phase /= Idle then
               return;
            end if;
            Command := Value;
            Param_Count := 0;
            Params_Needed := Param_Total (Value);
            Status := (Status or S_Busy or S_Cmd_Full)
              and not (S_Res_Full or S_Int);
            if Params_Needed = 0 then
               Execute;
            end if;
         when 1 =>
            if Param_Count < Params'Length then
               Params (Param_Count) := Value;
            end if;
            Param_Count := Param_Count + 1;
            if Param_Count = Params_Needed then
               Execute;
            end if;
         when 2 =>
            if (Value and 1) /= 0 then
               Reset;
            end if;
         when 4 .. 7 =>
            Data := Value;
            Status := Status and not (S_Data_Req or S_Int);
         when others => null;
      end case;
   end Write;

   procedure Request_Data is
   begin
      Status := Status or S_Data_Req or S_Int;
   end Request_Data;

   procedure Event is
      Is_Write : constant Boolean := Op in 16#0A# | 16#0B# | 16#0E# | 16#0F#;
      Is_Verify : constant Boolean := Op in 16#1E# | 16#1F#;
   begin
      case Phase is
         when Idle => null;
         when Finishing =>
            Finish (Pending_Result);
         when Seeking =>
            if Op = 16#1B# then
               Phase := Read_IDs;
               Timer := Byte_Time * 8;
            elsif Op = 16#23# then
               Phase := Format_IDs;
               Request_Data;
               Timer := Byte_Time;
            elsif Is_Verify then
               if Has_Sector (Drive_Num, Side, Cur_Track,
                              Cur_Sector + Sectors_Left - 1)
               then
                  Pending_Result := R_OK;
               else
                  Pending_Result := R_Not_Found;
               end if;
               Phase := Finishing;
               Timer := Byte_Time * 256 * Sectors_Left;
            else
               Phase := (if Is_Write then Transfer_Write else Transfer_Read);
               Start_Sector_Transfer;
               if Phase /= Idle and then Is_Write then
                  Request_Data;    --  ask for the first byte
               end if;
            end if;
         when Transfer_Read =>
            if Byte_Pos < Sector_Bytes then
               Data := Get (Drive_Num, Side, Cur_Track, Cur_Sector,
                            Byte_Pos);
               Request_Data;
               Byte_Pos := Byte_Pos + 1;
               Timer := Byte_Time;
            else
               Sectors_Left := Sectors_Left - 1;
               if Sectors_Left = 0 then
                  Finish (R_OK);
               else
                  Cur_Sector := Cur_Sector + 1;
                  Start_Sector_Transfer;
               end if;
            end if;
         when Transfer_Write =>
            if Byte_Pos < Sector_Bytes then
               Put (Drive_Num, Side, Cur_Track, Cur_Sector, Byte_Pos, Data);
               Byte_Pos := Byte_Pos + 1;
               if Byte_Pos < Sector_Bytes then
                  Request_Data;
               end if;
               Timer := Byte_Time;
            else
               Sectors_Left := Sectors_Left - 1;
               if Sectors_Left = 0 then
                  Flush (Drive_Num);
                  Finish (R_OK);
               else
                  Cur_Sector := Cur_Sector + 1;
                  Start_Sector_Transfer;
                  if Phase /= Idle then
                     Request_Data;
                  end if;
               end if;
            end if;
         when Read_IDs =>
            if Sectors_Left = 0 then
               Finish (R_OK);
            else
               case Byte_Pos is
                  when 0 => Data := Byte (Cur_Track mod 256);
                  when 1 => Data := 0;
                  when 2 => Data := Byte (Cur_Sector mod 256);
                  when others => Data := 1;     --  256-byte sectors
               end case;
               Request_Data;
               Byte_Pos := Byte_Pos + 1;
               Timer := Byte_Time;
               if Byte_Pos = 4 then
                  Byte_Pos := 0;
                  Cur_Sector := (Cur_Sector + 1) mod Sectors_Per_Track;
                  Sectors_Left := Sectors_Left - 1;
                  Timer := Byte_Time * 32;
               end if;
            end if;
         when Format_IDs =>
            --  four ID bytes per sector come from the CPU
            Byte_Pos := Byte_Pos + 1;
            if Byte_Pos = 4 then
               Byte_Pos := 0;
               Sectors_Left := Sectors_Left - 1;
            end if;
            if Sectors_Left = 0 then
               Format_Track (Drive_Num, Side, Cur_Track);
               Flush (Drive_Num);
               Finish (R_OK);
            else
               Request_Data;
               Timer := Byte_Time;
            end if;
      end case;
   end Event;

   procedure Tick (Cycles : Natural) is
   begin
      if Motor_Count > 0 then
         Motor_Count := Motor_Count - Cycles;
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
         exit when Phase = Idle;
      end loop;
      if Phase /= Idle then
         Load_Head;
      end if;
   end Tick;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte'Write (S, Status);
      Byte'Write (S, Result);
      Byte'Write (S, Data);
      Byte'Write (S, Command);
      for P of Params loop
         Byte'Write (S, P);
      end loop;
      Natural'Write (S, Param_Count);
      Natural'Write (S, Params_Needed);
      for B in Byte loop
         Byte'Write (S, Special (B));
      end loop;
      Natural'Write (S, Track_Of (0));
      Natural'Write (S, Track_Of (1));
      Phase_Type'Write (S, Phase);
      Integer'Write (S, Timer);
      Natural'Write (S, Drive);
      Natural'Write (S, Side);
      Natural'Write (S, Cur_Track);
      Natural'Write (S, Cur_Sector);
      Natural'Write (S, Sectors_Left);
      Natural'Write (S, Sector_Bytes);
      Natural'Write (S, Byte_Pos);
      Byte'Write (S, Pending_Result);
      Byte'Write (S, Op);
   end Save_State;

   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Byte'Read (S, Status);
      Byte'Read (S, Result);
      Byte'Read (S, Data);
      Byte'Read (S, Command);
      for P of Params loop
         Byte'Read (S, P);
      end loop;
      Natural'Read (S, Param_Count);
      Natural'Read (S, Params_Needed);
      for B in Byte loop
         Byte'Read (S, Special (B));
      end loop;
      Natural'Read (S, Track_Of (0));
      Natural'Read (S, Track_Of (1));
      Phase_Type'Read (S, Phase);
      Integer'Read (S, Timer);
      Natural'Read (S, Drive);
      Natural'Read (S, Side);
      Natural'Read (S, Cur_Track);
      Natural'Read (S, Cur_Sector);
      Natural'Read (S, Sectors_Left);
      Natural'Read (S, Sector_Bytes);
      Natural'Read (S, Byte_Pos);
      Byte'Read (S, Pending_Result);
      Byte'Read (S, Op);
   end Load_State;

end FDC8271;
