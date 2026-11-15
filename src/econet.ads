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
--  Econet on the Model B: the MC6854 ADLC at &FEA0-&FEA3, the station
--  number at &FE18 (reading it also masks the network NMI: INTOFF) and
--  INTON on reads of &FE20; the ADLC's IRQ reaches the CPU as an NMI.
--
--  The network is emulated a message at a time, as Acorn Universal
--  Networking (AUN) does: the emulator answers the Econet four-way
--  handshake (scout, ack, data, ack) itself and moves whole messages.
--  Other AdaBeeb instances are reached over UDP on this computer: station
--  N listens on 127.0.0.1 port Base_Port + N, with AUN's 8-byte header.
--  Station 254 is a file server inside the emulator (Econet.File_Server)
--  that serves a folder on the host.

with Types; use Types;
with Interfaces;

package Econet is

   Enabled : Boolean := False;
   --  The Econet interface is fitted (Model B; takes effect at power-on).

   Station : Byte := 1;               --  this machine's station number
   Server_Station : constant Byte := 254;
   Base_Port : constant := 32768;

   procedure Start (Ok : out Boolean);
   --  Bring the network up (open this station's UDP port).  Ok is False
   --  if the port is in use (another instance with the same number); the
   --  file server still works then.
   procedure Stop;
   function Error_Text return String;

   procedure Reset;
   --  A machine reset: the ADLC's reset line.

   function Read (Reg : Natural) return Byte;
   procedure Write (Reg : Natural; Value : Byte);
   function Station_Read return Byte;     --  &FE18 (INTOFF)
   procedure INTON;                        --  read of &FE20
   function Take_NMI return Boolean;
   --  True once for each network NMI (an edge on the CPU's NMI line).

   procedure Clock (Cycles : Natural);
   --  Advance by Cycles of the 2 MHz clock.

   --  Messages, as the file server sees them
   Max_Data : constant := 2048;
   type Message is record
      Src_Stn, Src_Net : Byte := 0;
      Dst_Stn, Dst_Net : Byte := 0;
      Ctrl, Port : Byte := 0;            --  Ctrl with bit 7 set
      Len : Natural := 0;
      Data : Byte_Array (0 .. Max_Data - 1) := (others => 0);
      Remote : Boolean := False;         --  came over UDP (needs an ack)
      Seq : Interfaces.Unsigned_32 := 0;
   end record;

   procedure Queue_For_Station (M : Message);
   --  A message for this machine (from the file server).

end Econet;
