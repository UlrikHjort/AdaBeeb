-- ***************************************************************************
--                              AdaBeeb - Econet
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

with Ada.Streams; use Ada.Streams;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with GNAT.Sockets; use GNAT.Sockets;
with Interfaces; use Interfaces;
with Econet.File_Server;

package body Econet is

   ---------------------------------------------------------------------
   --  ADLC registers and bits
   ---------------------------------------------------------------------

   CR1, CR2, CR3, CR4 : Byte := 0;
   SR1, SR2 : Byte := 0;
   Prev1, Prev2 : Byte := 0;        --  status at the last update

   CR1_AC  : constant Byte := 16#01#;   --  address control
   CR1_RIE : constant Byte := 16#02#;
   CR1_TIE : constant Byte := 16#04#;
   CR1_Discontinue : constant Byte := 16#20#;
   CR1_Rx_Reset : constant Byte := 16#40#;
   CR1_Tx_Reset : constant Byte := 16#80#;

   CR2_PSE : constant Byte := 16#01#;    --  prioritised status
   CR2_Two_Byte : constant Byte := 16#02#;
   CR2_FC : constant Byte := 16#08#;     --  SR1 b6 = frame complete
   CR2_Tx_Last : constant Byte := 16#10#;
   CR2_Clr_Rx : constant Byte := 16#20#;
   CR2_Clr_Tx : constant Byte := 16#40#;
   CR2_RTS : constant Byte := 16#80#;

   CR4_Abort : constant Byte := 16#20#;
   CR3_FDSE : constant Byte := 16#10#;   --  flag detect status enable

   SR1_RDA  : constant Byte := 16#01#;
   SR1_S2RQ : constant Byte := 16#02#;
   SR1_FD   : constant Byte := 16#08#;
   SR1_CTS  : constant Byte := 16#10#;
   SR1_TXU  : constant Byte := 16#20#;
   SR1_TDRA : constant Byte := 16#40#;
   SR1_IRQ  : constant Byte := 16#80#;

   SR2_AP   : constant Byte := 16#01#;
   SR2_FV   : constant Byte := 16#02#;
   SR2_Idle : constant Byte := 16#04#;
   SR2_Abort : constant Byte := 16#08#;
   SR2_FCS  : constant Byte := 16#10#;
   SR2_DCD  : constant Byte := 16#20#;
   SR2_OVRN : constant Byte := 16#40#;
   SR2_RDA  : constant Byte := 16#80#;

   type FIFO_Entry is record
      V : Byte := 0;
      First, Last : Boolean := False;
   end record;
   type FIFO_Type is array (0 .. 2) of FIFO_Entry;   --  0 = oldest

   Tx_FIFO, Rx_FIFO : FIFO_Type;
   Tx_Count, Rx_Count : Natural := 0;

   Max_Frame : constant := Max_Data + 16;
   Tx_Frame : Byte_Array (0 .. Max_Frame - 1);
   Tx_Len : Natural := 0;
   Rx_Frame : Byte_Array (0 .. Max_Frame - 1);
   Rx_Len, Rx_Pos : Natural := 0;
   Rx_Active : Boolean := False;          --  a frame is being received

   PSE_Level : Natural := 0;
   S2_Cause, IRQ_Cause : Byte := 0;
   NMI_Enabled : Boolean := False;
   NMI_Event : Boolean := False;
   Link_Up : Boolean := False;

   Now : Long_Long_Integer := 0;          --  2 MHz cycles
   Byte_Acc, Poll_Acc : Natural := 0;
   Byte_Time : constant := 128;           --  cycles per byte on the wire
   Poll_Time : constant := 4096;          --  between UDP polls

   ---------------------------------------------------------------------
   --  The four-way handshake, emulated locally
   ---------------------------------------------------------------------

   type HS_State is
     (Idle,
      Tx_Wait_Data,     --  we acked the machine's scout; data comes next
      Tx_Wait_Ack,      --  data sent over UDP; waiting for the AUN ack
      Tx_Wait_Reply,    --  immediate operation sent; waiting for a reply
      Rx_Wait_Ack,      --  we offered a scout; waiting for its ack
      Rx_Wait_Final);   --  we gave the data; waiting for the final ack
   HS : HS_State := Idle;
   HS_Deadline : Long_Long_Integer := 0;
   Next_Try : Long_Long_Integer := 0;

   Scout_Dst, Scout_Net, Scout_Ctrl, Scout_Port : Byte := 0;
   Scout_Extra : Byte_Array (0 .. 7);
   Scout_Extra_Len : Natural := 0;
   Scout_Copy : Byte_Array (0 .. 5) := (others => 0);

   --  A frame the machine should receive next (acks we fake)
   Pending : Byte_Array (0 .. Max_Frame - 1);
   Pending_Len : Natural := 0;

   --  Messages waiting for this machine
   Queue_Size : constant := 48;
   Queue : array (0 .. Queue_Size - 1) of Message;
   Q_Head, Q_Count : Natural := 0;
   Retries : Natural := 0;
   Max_Retries : constant := 60;
   Retry_Gap : constant := 20_000;       --  10 ms
   Ack_Timeout : constant := 40_000;     --  20 ms for the machine to ack
   Remote_Timeout : constant := 1_000_000;   --  0.5 s for another station

   --  Port 0 operations carry extra bytes in the scout
   function Scout_Extra_For (Port, Ctrl : Byte) return Natural is
     (if Port /= 0 then 0
      elsif (Ctrl and 16#7F#) = 16#02# then 8
      elsif (Ctrl and 16#7F#) in 16#03# .. 16#05# then 4
      else 0);

   function Is_Immediate (Port, Ctrl : Byte) return Boolean is
     (Port = 0 and then (Ctrl and 16#7F#) not in 16#02# .. 16#05#);

   ---------------------------------------------------------------------
   --  UDP link
   ---------------------------------------------------------------------

   Sock : Socket_Type;
   Sock_Open : Boolean := False;
   Err : Unbounded_String;
   Seq_Counter : Unsigned_32 := 0;

   AUN_Broadcast : constant Byte := 1;
   AUN_Unicast   : constant Byte := 2;
   AUN_Ack       : constant Byte := 3;
   AUN_Nak       : constant Byte := 4;
   AUN_Immediate : constant Byte := 5;
   AUN_Imm_Reply : constant Byte := 6;

   procedure Send_UDP (To_Stn : Byte; Kind, Port, Ctrl : Byte;
                       Seq : Unsigned_32; Data : Byte_Array) is
      Buf : Stream_Element_Array (1 .. Stream_Element_Offset (8 + Data'Length));
      Last : Stream_Element_Offset;
   begin
      if not Sock_Open or else To_Stn = 0 or else To_Stn = Station then
         return;
      end if;
      Buf (1) := Stream_Element (Kind);
      Buf (2) := Stream_Element (Port);
      Buf (3) := Stream_Element (Ctrl and 16#7F#);
      Buf (4) := 0;
      for I in 0 .. 3 loop
         Buf (Stream_Element_Offset (5 + I)) :=
           Stream_Element (Shift_Right (Seq, 8 * I) and 16#FF#);
      end loop;
      for I in Data'Range loop
         Buf (Stream_Element_Offset (9 + I - Data'First)) :=
           Stream_Element (Data (I));
      end loop;
      Send_Socket (Sock, Buf, Last,
                   To => (Family_Inet, Loopback_Inet_Addr,
                          Port_Type (Base_Port + Natural (To_Stn))));
   exception
      when Socket_Error =>
         null;                          --  nobody there
   end Send_UDP;

   procedure Start (Ok : out Boolean) is
   begin
      Stop;
      Link_Up := True;                  --  the file server is always there
      Ok := False;
      Create_Socket (Sock, Family_Inet, Socket_Datagram);
      begin
         Bind_Socket (Sock, (Family_Inet, Loopback_Inet_Addr,
                             Port_Type (Base_Port + Natural (Station))));
      exception
         when Socket_Error =>
            Close_Socket (Sock);
            Err := To_Unbounded_String
              ("Econet station" & Station'Image & " is in use (UDP port"
               & Natural'Image (Base_Port + Natural (Station)) & ")");
            return;
      end;
      declare
         Req : Request_Type := (Name => Non_Blocking_IO, Enabled => True);
      begin
         Control_Socket (Sock, Req);
      end;
      Sock_Open := True;
      Ok := True;
   exception
      when Socket_Error =>
         Err := To_Unbounded_String ("cannot open the Econet UDP port");
   end Start;

   procedure Stop is
   begin
      if Sock_Open then
         Close_Socket (Sock);
         Sock_Open := False;
      end if;
      Link_Up := False;
   end Stop;

   function Error_Text return String is (To_String (Err));

   ---------------------------------------------------------------------
   --  Status registers and interrupts
   ---------------------------------------------------------------------

   function Bit (Cond : Boolean; B : Byte) return Byte is
     (if Cond then B else 0);

   procedure Update_Status is
      Interrupt_Now : Boolean := False;
      Rx_Reset : constant Boolean := (CR1 and CR1_Rx_Reset) /= 0;
      Tx_Reset : constant Boolean := (CR1 and CR1_Tx_Reset) /= 0;
      Two : constant Boolean := (CR2 and CR2_Two_Byte) /= 0;
      CTS_High : Boolean;
      Cause : Byte;
      Fill : Boolean;
   begin
      --  received data available
      SR1 := SR1 and not SR1_RDA;
      SR2 := SR2 and not SR2_RDA;
      if not Rx_Reset and then Rx_Count > (if Two then 1 else 0) then
         SR1 := SR1 or SR1_RDA;
         SR2 := SR2 or SR2_RDA;
      end if;
      --  Flag fill: during a handshake the other station holds the line
      --  with flags, so it never looks idle between scout and ack
      Fill := HS /= Idle or else Pending_Len > 0 or else Rx_Active;
      SR1 := (SR1 and not SR1_FD) or Bit (Fill, SR1_FD);
      --  CTS is low (clear to send) with a clock and RTS on
      CTS_High := not (Link_Up and then (CR2 and CR2_RTS) /= 0);
      if not CTS_High then
         SR1 := SR1 and not SR1_CTS;
      elsif not Rx_Reset then
         SR1 := SR1 or SR1_CTS;
      end if;
      --  transmit data register available / frame complete
      if not Tx_Reset then
         if (CR2 and CR2_FC) = 0 then
            SR1 := (SR1 and not SR1_TDRA) or
              Bit (Tx_Count < (if Two then 2 else 3)
                   and then (SR1 and SR1_CTS) = 0
                   and then (SR2 and SR2_DCD) = 0, SR1_TDRA);
         else
            SR1 := (SR1 and not SR1_TDRA) or Bit (Tx_Count = 0, SR1_TDRA);
         end if;
      end if;
      if not Rx_Reset then
         SR2 := (SR2 and not SR2_AP)
           or Bit (Rx_Count > 0 and then Rx_FIFO (0).First, SR2_AP);
         if Rx_Count > 0 and then Rx_FIFO (0).Last then
            SR2 := SR2 or SR2_FV;          --  held until cleared
         end if;
         SR2 := (SR2 and not SR2_Idle)
           or Bit (Rx_Count = 0 and then (SR2 and SR2_FV) = 0
                   and then not Fill, SR2_Idle);
      end if;
      SR2 := (SR2 and not SR2_DCD) or Bit (not Link_Up, SR2_DCD);

      --  prioritised status: only the most important receive condition
      --  shows in SR2
      if (CR2 and CR2_PSE) /= 0 then
         if PSE_Level <= 1 and then (SR2 and (SR2_FV or SR2_Abort or SR2_FCS
                                              or SR2_DCD or SR2_OVRN)) /= 0
         then
            PSE_Level := 1;
            SR2 := SR2 and not (SR2_AP or SR2_Idle or SR2_RDA);
         elsif PSE_Level <= 2 and then (SR2 and SR2_Idle) /= 0 then
            PSE_Level := 2;
            SR2 := SR2 and not (SR2_AP or SR2_RDA);
         elsif PSE_Level <= 3 and then (SR2 and SR2_AP) /= 0 then
            PSE_Level := 3;
            SR2 := SR2 and not SR2_RDA;
         elsif (SR2 and SR2_RDA) /= 0 then
            PSE_Level := 4;
            SR2 := SR2 and not SR2_FV;
         else
            PSE_Level := 0;
         end if;
         SR1 := (SR1 and not SR1_RDA) or Bit ((SR2 and SR2_RDA) /= 0, SR1_RDA);
      else
         PSE_Level := 0;
      end if;

      --  interrupts: a status bit going up (and enabled) raises IRQ, which
      --  stays until all the bits that caused it have gone
      if SR1 /= Prev1 or else SR2 /= Prev2 then
         Cause := (SR2 and not Prev2) and not SR2_RDA;
         if (CR1 and CR1_RIE) = 0 then
            Cause := 0;
         end if;
         if Cause /= 0 then
            SR1 := SR1 or SR1_S2RQ;
            S2_Cause := S2_Cause or Cause;
         elsif (SR2 and S2_Cause) = 0 then
            SR1 := SR1 and not SR1_S2RQ;
            S2_Cause := 0;
         end if;
         Cause := (SR1 and not Prev1) and not SR1_IRQ;
         if (CR1 and CR1_RIE) = 0 then
            Cause := Cause and not (SR1_RDA or SR1_S2RQ or SR1_FD);
         end if;
         if (CR3 and CR3_FDSE) = 0 then
            Cause := Cause and not SR1_FD;   --  flags interrupt only if asked
         end if;
         if (CR1 and CR1_TIE) = 0 then
            Cause := Cause and not (SR1_CTS or SR1_TXU or SR1_TDRA);
         end if;
         if Cause /= 0 then
            Interrupt_Now := True;
            IRQ_Cause := IRQ_Cause or Cause;
            SR1 := SR1 or SR1_IRQ;
         end if;
         Cause := (Prev1 and not SR1) and not SR1_IRQ;
         if Cause /= 0 then
            IRQ_Cause := IRQ_Cause and not Cause;
            if IRQ_Cause = 0 then
               SR1 := SR1 and not SR1_IRQ;
            elsif (CR2 and CR2_PSE) /= 0 then
               Interrupt_Now := True;
            end if;
         end if;
      end if;
      Prev1 := SR1;
      Prev2 := SR2;
      if Interrupt_Now and then NMI_Enabled then
         NMI_Event := True;
      end if;
   end Update_Status;

   ---------------------------------------------------------------------
   --  Frames to and from the machine
   ---------------------------------------------------------------------

   procedure Give_Frame (F : Byte_Array) is
   begin
      Pending (0 .. F'Length - 1) := F;
      Pending_Len := F'Length;
   end Give_Frame;

   procedure Start_Pending is
   begin
      if Pending_Len > 0 and then not Rx_Active and then Rx_Count = 0
        and then (CR1 and CR1_Rx_Reset) = 0
        and then (SR2 and SR2_FV) = 0
      then
         Rx_Frame (0 .. Pending_Len - 1) := Pending (0 .. Pending_Len - 1);
         Rx_Len := Pending_Len;
         Rx_Pos := 0;
         Rx_Active := True;
         Pending_Len := 0;
      end if;
   end Start_Pending;

   function Ack_Frame (From_Stn, From_Net : Byte) return Byte_Array is
     ((Station, 0, From_Stn, From_Net));

   procedure Pop_Queue is
   begin
      if Q_Count > 0 then
         Q_Head := (Q_Head + 1) mod Queue_Size;
         Q_Count := Q_Count - 1;
      end if;
      Retries := 0;
   end Pop_Queue;

   procedure Queue_For_Station (M : Message) is
   begin
      if Q_Count < Queue_Size then
         Queue ((Q_Head + Q_Count) mod Queue_Size) := M;
         Q_Count := Q_Count + 1;
      end if;
   end Queue_For_Station;

   --  Offer the next queued message to the machine
   procedure Try_Deliver is
   begin
      if HS /= Idle or else Q_Count = 0 or else Now < Next_Try
        or else Pending_Len > 0 or else Rx_Active or else Rx_Count > 0
        or else (CR1 and CR1_Rx_Reset) /= 0
        or else (SR2 and SR2_FV) /= 0
      then
         return;
      end if;
      declare
         M : Message renames Queue (Q_Head);
         Extra : constant Natural :=
           Natural'Min (Scout_Extra_For (M.Port, M.Ctrl), M.Len);
      begin
         if M.Dst_Stn = 255 then
            --  broadcast: a single frame, no handshake
            Give_Frame (Byte_Array'(255, 255, M.Src_Stn, M.Src_Net,
                                    M.Ctrl or 16#80#, M.Port)
                        & M.Data (0 .. Natural'Min (M.Len, 8) - 1));
            Pop_Queue;
            return;
         end if;
         Give_Frame (Byte_Array'(Station, 0, M.Src_Stn, M.Src_Net,
                                 M.Ctrl or 16#80#, M.Port)
                     & M.Data (0 .. Extra - 1));
         HS := Rx_Wait_Ack;
         HS_Deadline := Now + Ack_Timeout;
      end;
   end Try_Deliver;

   procedure Deliver_Data is
      M : Message renames Queue (Q_Head);
      Extra : constant Natural :=
        Natural'Min (Scout_Extra_For (M.Port, M.Ctrl), M.Len);
   begin
      Give_Frame (Byte_Array'(Station, 0, M.Src_Stn, M.Src_Net)
                  & M.Data (Extra .. M.Len - 1));
      HS := Rx_Wait_Final;
      HS_Deadline := Now + Ack_Timeout * 50;
   end Deliver_Data;

   procedure Message_Received is
      M : constant Message := Queue (Q_Head);
   begin
      if M.Remote then
         Send_UDP (M.Src_Stn, AUN_Ack, M.Port, M.Ctrl, M.Seq,
                   Byte_Array'(1 .. 0 => 0));
      end if;
      Pop_Queue;
      HS := Idle;
   end Message_Received;

   --  A complete frame from the machine
   procedure Frame_Sent (F : Byte_Array) is
   begin
      if F'Length < 4 then
         return;
      end if;
      case HS is
         when Rx_Wait_Ack =>
            if F'Length = 4 then
               Deliver_Data;               --  it accepted our scout
               return;
            end if;
            HS := Idle;                    --  it sent something else
         when Rx_Wait_Final =>
            if F'Length = 4 then
               Message_Received;
               return;
            end if;
            HS := Idle;
         when Tx_Wait_Data =>
            --  the data part of the machine's message (the same scout
            --  again means it is starting over)
            if not (F'Length = 6 + Scout_Extra_Len
                    and then F (F'First .. F'First + 5) = Scout_Copy)
            then
               declare
                  M : Message;
                  Data_Len : constant Natural := F'Length - 4;
               begin
                  M.Src_Stn := Station;
                  M.Src_Net := 0;
                  M.Dst_Stn := Scout_Dst;
                  M.Dst_Net := Scout_Net;
                  M.Ctrl := Scout_Ctrl;
                  M.Port := Scout_Port;
                  M.Len := Natural'Min (Scout_Extra_Len + Data_Len, Max_Data);
                  M.Data (0 .. Scout_Extra_Len - 1) :=
                    Scout_Extra (0 .. Scout_Extra_Len - 1);
                  M.Data (Scout_Extra_Len .. M.Len - 1) :=
                    F (F'First + 4 .. F'First + 4 + M.Len - Scout_Extra_Len - 1);
                  if Scout_Dst = Server_Station then
                     File_Server.Receive (M);
                     Give_Frame (Ack_Frame (Scout_Dst, Scout_Net));
                     HS := Idle;
                  else
                     Seq_Counter := Seq_Counter + 4;
                     Send_UDP (Scout_Dst, AUN_Unicast, Scout_Port, Scout_Ctrl,
                               Seq_Counter, M.Data (0 .. M.Len - 1));
                     HS := Tx_Wait_Ack;
                     HS_Deadline := Now + Remote_Timeout;
                  end if;
               end;
               return;
            end if;
            HS := Idle;
         when others =>
            null;
      end case;

      --  a scout (or broadcast / immediate operation) from the machine
      if F'Length < 6 then
         return;
      end if;
      Scout_Copy := F (F'First .. F'First + 5);
      Scout_Dst := F (F'First);
      Scout_Net := F (F'First + 1);
      Scout_Ctrl := F (F'First + 4);
      Scout_Port := F (F'First + 5);
      Scout_Extra_Len := Natural'Min (F'Length - 6, 8);
      Scout_Extra (0 .. Scout_Extra_Len - 1) :=
        F (F'First + 6 .. F'First + 6 + Scout_Extra_Len - 1);
      if Scout_Dst = 255 then
         for S in Byte range 1 .. 254 loop
            Send_UDP (S, AUN_Broadcast, Scout_Port, Scout_Ctrl, 0,
                      F (F'First + 6 .. F'Last));
         end loop;
         HS := Idle;
      elsif Is_Immediate (Scout_Port, Scout_Ctrl) then
         Seq_Counter := Seq_Counter + 4;
         Send_UDP (Scout_Dst, AUN_Immediate, Scout_Port, Scout_Ctrl,
                   Seq_Counter, F (F'First + 6 .. F'Last));
         HS := Tx_Wait_Reply;
         HS_Deadline := Now + Remote_Timeout;
      else
         Give_Frame (Ack_Frame (Scout_Dst, Scout_Net));
         HS := Tx_Wait_Data;
         HS_Deadline := Now + Remote_Timeout;
      end if;
   end Frame_Sent;

   ---------------------------------------------------------------------
   --  Network input
   ---------------------------------------------------------------------

   procedure Poll_Network is
      Buf : Stream_Element_Array (1 .. Stream_Element_Offset (Max_Data + 8));
      Last : Stream_Element_Offset;
      From : Sock_Addr_Type;
      Src : Integer;
   begin
      if not Sock_Open then
         return;
      end if;
      loop
         begin
            Receive_Socket (Sock, Buf, Last, From);
         exception
            when Socket_Error =>
               return;                      --  nothing waiting
         end;
         exit when Last < 8;
         Src := Integer (From.Port) - Base_Port;
         if Src in 1 .. 254 then
            declare
               Kind : constant Byte := Byte (Buf (1));
               M : Message;
            begin
               M.Src_Stn := Byte (Src);
               M.Port := Byte (Buf (2));
               M.Ctrl := Byte (Buf (3)) or 16#80#;
               M.Seq := 0;
               for I in 0 .. 3 loop
                  M.Seq := M.Seq or Shift_Left
                    (Unsigned_32 (Buf (Stream_Element_Offset (5 + I))), 8 * I);
               end loop;
               M.Len := Natural'Min (Natural (Last) - 8, Max_Data);
               for I in 0 .. M.Len - 1 loop
                  M.Data (I) := Byte (Buf (Stream_Element_Offset (9 + I)));
               end loop;
               case Kind is
                  when AUN_Unicast =>
                     M.Dst_Stn := Station;
                     M.Remote := True;
                     Queue_For_Station (M);
                  when AUN_Broadcast =>
                     M.Dst_Stn := 255;
                     Queue_For_Station (M);
                  when AUN_Ack | AUN_Nak =>
                     if HS = Tx_Wait_Ack and then M.Src_Stn = Scout_Dst then
                        if Kind = AUN_Ack then
                           Give_Frame (Ack_Frame (Scout_Dst, Scout_Net));
                        end if;
                        HS := Idle;
                     end if;
                  when AUN_Imm_Reply =>
                     if HS = Tx_Wait_Reply and then M.Src_Stn = Scout_Dst
                     then
                        Give_Frame (Ack_Frame (Scout_Dst, Scout_Net)
                                    & M.Data (0 .. M.Len - 1));
                        HS := Idle;
                     end if;
                  when others =>
                     null;                  --  immediate operations: not
               end case;                    --  answered
            end;
         end if;
      end loop;
   end Poll_Network;

   ---------------------------------------------------------------------
   --  Timing
   ---------------------------------------------------------------------

   procedure Byte_Tick is
   begin
      --  transmit: the oldest FIFO byte goes onto the wire
      if (CR1 and CR1_Tx_Reset) = 0 and then Tx_Count > 0 then
         declare
            E : constant FIFO_Entry := Tx_FIFO (0);
         begin
            Tx_FIFO (0 .. 1) := Tx_FIFO (1 .. 2);
            Tx_Count := Tx_Count - 1;
            if Tx_Len < Max_Frame then
               Tx_Frame (Tx_Len) := E.V;
               Tx_Len := Tx_Len + 1;
            end if;
            if E.Last then
               declare
                  Len : constant Natural := Tx_Len;
               begin
                  Tx_Len := 0;
                  Frame_Sent (Tx_Frame (0 .. Len - 1));
               end;
            end if;
         end;
      end if;
      --  receive: the next byte of the incoming frame into the FIFO
      if (CR1 and CR1_Rx_Reset) = 0 and then Rx_Active and then Rx_Count < 3
      then
         Rx_FIFO (Rx_Count) := (V => Rx_Frame (Rx_Pos),
                                First => Rx_Pos = 0,
                                Last => Rx_Pos = Rx_Len - 1);
         Rx_Count := Rx_Count + 1;
         Rx_Pos := Rx_Pos + 1;
         if Rx_Pos >= Rx_Len then
            Rx_Active := False;
         end if;
      end if;
      Start_Pending;
      Try_Deliver;
      Start_Pending;
      Update_Status;
   end Byte_Tick;

   procedure Check_Timeouts is
   begin
      if HS /= Idle and then Now > HS_Deadline then
         case HS is
            when Rx_Wait_Ack | Rx_Wait_Final =>
               --  the machine isn't listening on that port (yet): retry
               Retries := Retries + 1;
               if Retries > Max_Retries then
                  Pop_Queue;
               end if;
               Next_Try := Now + Retry_Gap;
            when others =>
               null;            --  no ack: the machine reports an error
         end case;
         HS := Idle;
      end if;
   end Check_Timeouts;

   procedure Clock (Cycles : Natural) is
   begin
      if not Enabled then
         return;
      end if;
      Now := Now + Long_Long_Integer (Cycles);
      Byte_Acc := Byte_Acc + Cycles;
      while Byte_Acc >= Byte_Time loop
         Byte_Acc := Byte_Acc - Byte_Time;
         Byte_Tick;
      end loop;
      Poll_Acc := Poll_Acc + Cycles;
      if Poll_Acc >= Poll_Time then
         Poll_Acc := 0;
         Poll_Network;
         Check_Timeouts;
      end if;
   end Clock;

   ---------------------------------------------------------------------
   --  CPU interface
   ---------------------------------------------------------------------

   procedure Clear_Rx is
   begin
      Rx_Count := 0;
      Rx_Active := False;
   end Clear_Rx;

   procedure Write (Reg : Natural; Value : Byte) is
   begin
      case Reg mod 4 is
         when 0 =>
            --  The IRQ output is a level: conditions already present when
            --  their interrupt is enabled count as new
            if (Value and CR1_TIE) /= 0 and then (CR1 and CR1_TIE) = 0 then
               Prev1 := Prev1 and not (SR1_TDRA or SR1_TXU or SR1_CTS);
            end if;
            if (Value and CR1_RIE) /= 0 and then (CR1 and CR1_RIE) = 0 then
               Prev1 := Prev1 and not (SR1_RDA or SR1_FD);
               Prev2 := 0;
            end if;
            CR1 := Value;
            if (CR1 and CR1_Discontinue) /= 0 then
               Clear_Rx;                   --  drop the frame in progress
               CR1 := CR1 and not CR1_Discontinue;
            end if;
            if (CR1 and CR1_Rx_Reset) /= 0 then
               Clear_Rx;
               SR2 := SR2 and not (SR2_FV or SR2_Abort or SR2_FCS or SR2_OVRN);
               SR1 := SR1 and not (SR1_S2RQ or SR1_FD);
               PSE_Level := 0;
            end if;
            if (CR1 and CR1_Tx_Reset) /= 0 then
               Tx_Count := 0;
               Tx_Len := 0;
               SR1 := SR1 and not (SR1_TXU or SR1_TDRA);
            end if;
         when 1 =>
            if (CR1 and CR1_AC) /= 0 then
               CR3 := Value;
            else
               CR2 := Value;
               if (CR2 and CR2_Tx_Last) /= 0 then
                  --  the byte just written ends the frame
                  if Tx_Count > 0 then
                     Tx_FIFO (Tx_Count - 1).Last := True;
                  elsif Tx_Len > 0 then
                     declare
                        Len : constant Natural := Tx_Len;
                     begin
                        Tx_Len := 0;
                        Frame_Sent (Tx_Frame (0 .. Len - 1));
                     end;
                  end if;
                  CR2 := CR2 and not CR2_Tx_Last;
               end if;
               if (CR2 and CR2_Clr_Rx) /= 0 then
                  SR1 := SR1 and not (SR1_S2RQ or SR1_FD);
                  SR2 := SR2 and not (SR2_FV or SR2_Idle or SR2_Abort
                                      or SR2_FCS or SR2_DCD or SR2_OVRN);
                  if (CR2 and CR2_PSE) /= 0 and then PSE_Level > 0 then
                     PSE_Level := (PSE_Level + 1) mod 5;
                  else
                     PSE_Level := 0;
                  end if;
                  S2_Cause := 0;
                  CR2 := CR2 and not CR2_Clr_Rx;
               end if;
               if (CR2 and CR2_Clr_Tx) /= 0 then
                  SR1 := SR1 and not (SR1_CTS or SR1_TXU or SR1_TDRA);
                  CR2 := CR2 and not CR2_Clr_Tx;
               end if;
            end if;
         when others =>
            if Reg mod 4 = 3 and then (CR1 and CR1_AC) /= 0 then
               CR4 := Value;
               if (CR4 and CR4_Abort) /= 0 then
                  Tx_Count := 0;
                  Tx_Len := 0;
                  HS := Idle;
                  CR4 := CR4 and not CR4_Abort;
               end if;
            elsif (CR1 and CR1_Tx_Reset) = 0 then
               if Tx_Count < 3 then
                  Tx_FIFO (Tx_Count) := (V => Value, First => False,
                                         Last => Reg mod 4 = 3);
                  Tx_Count := Tx_Count + 1;
               else
                  SR1 := SR1 or SR1_TXU;
               end if;
            end if;
      end case;
      Update_Status;
   end Write;

   function Read (Reg : Natural) return Byte is
      V : Byte := 0;
   begin
      case Reg mod 4 is
         when 0 => return SR1;
         when 1 => return SR2;
         when others =>
            if (CR1 and CR1_Rx_Reset) = 0 and then Rx_Count > 0 then
               V := Rx_FIFO (0).V;
               Rx_FIFO (0 .. 1) := Rx_FIFO (1 .. 2);
               Rx_Count := Rx_Count - 1;
               Update_Status;
            end if;
            return V;
      end case;
   end Read;

   function Station_Read return Byte is
   begin
      NMI_Enabled := False;
      return Station;
   end Station_Read;

   procedure INTON is
   begin
      if not NMI_Enabled and then (SR1 and SR1_IRQ) /= 0 then
         NMI_Event := True;            --  a pending IRQ makes a new edge
      end if;
      NMI_Enabled := True;
   end INTON;

   function Take_NMI return Boolean is
   begin
      if NMI_Event then
         NMI_Event := False;
         return True;
      end if;
      return False;
   end Take_NMI;

   procedure Reset is
   begin
      CR1 := CR1_Rx_Reset or CR1_Tx_Reset;
      CR2 := 0;
      CR3 := 0;
      CR4 := 0;
      SR1 := 0;
      SR2 := 0;
      Prev1 := 0;
      Prev2 := 0;
      Tx_Count := 0;
      Tx_Len := 0;
      Clear_Rx;
      Pending_Len := 0;
      PSE_Level := 0;
      S2_Cause := 0;
      IRQ_Cause := 0;
      NMI_Enabled := False;
      NMI_Event := False;
      HS := Idle;
      Update_Status;
   end Reset;

end Econet;
