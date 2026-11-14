-- ***************************************************************************
--                               AdaBeeb - Tape
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
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings;
with System;

package body Tape is

   ---------------------------------------------------------------------
   --  zlib (gzread also reads uncompressed files)
   ---------------------------------------------------------------------

   function gzopen (Path, Mode : Interfaces.C.Strings.chars_ptr)
     return System.Address;
   pragma Import (C, gzopen, "gzopen");
   function gzread (F : System.Address; Buf : System.Address;
                    Len : unsigned) return int;
   pragma Import (C, gzread, "gzread");
   function gzclose (F : System.Address) return int;
   pragma Import (C, gzclose, "gzclose");

   ---------------------------------------------------------------------
   --  Tape contents as events, each one byte time long
   ---------------------------------------------------------------------

   type Event_Kind is (Tone, Data, Gap);
   type Event is record
      Kind : Event_Kind := Gap;
      Value : Byte := 0;
   end record;
   type Event_Array is array (Natural range <>) of Event;
   type Event_Access is access Event_Array;

   Events : Event_Access := null;
   Count  : Natural := 0;
   Pos    : Natural := 0;
   Tape_Name : Unbounded_String;

   procedure Add (K : Event_Kind; V : Byte := 0) is
   begin
      if Events = null then
         Events := new Event_Array (0 .. 65_535);
      elsif Count > Events'Last then
         declare
            Bigger : constant Event_Access :=
              new Event_Array (0 .. Events'Length * 2 - 1);
         begin
            Bigger (0 .. Count - 1) := Events (0 .. Count - 1);
            Events := Bigger;
         end;
      end if;
      Events (Count) := (K, V);
      Count := Count + 1;
   end Add;

   Byte_Cycles : constant := 2_000_000 * 10 / 1200;   --  16_666

   procedure Attach (Path : String; Ok : out Boolean) is
      use Interfaces.C.Strings;
      P : chars_ptr := New_String (Path);
      M : chars_ptr := New_String ("rb");
      F : constant System.Address := gzopen (P, M);
      Buf : constant Byte_Array_Access :=
        new Byte_Array (0 .. 4 * 1024 * 1024 - 1);
      Got : int;
      Size : Natural := 0;
      R : int;
      pragma Unreferenced (R);
      use type System.Address;
   begin
      Free (P);
      Free (M);
      Ok := False;
      if F = System.Null_Address then
         return;
      end if;
      loop
         Got := gzread (F, Buf.all (Size)'Address,
                        unsigned (Buf'Length - Size));
         exit when Got <= 0;
         Size := Size + Natural (Got);
         exit when Size >= Buf'Length;
      end loop;
      R := gzclose (F);
      if Size < 12 or else Buf (0 .. 8) /=
        (16#55#, 16#45#, 16#46#, 16#20#, 16#46#, 16#69#, 16#6C#, 16#65#,
         16#21#)                                        --  "UEF File!"
      then
         return;
      end if;
      Count := 0;
      declare
         I : Natural := 12;
         Baud : Natural := 1200;
         function W16 (A : Natural) return Natural is
           (Natural (Buf (A)) + Natural (Buf (A + 1)) * 256);
         function W32 (A : Natural) return Natural is
           (W16 (A) + W16 (A + 2) * 65536);
         procedure Tones (Cycles : Natural) is
         begin
            --  20 cycles of 2400 Hz per byte time
            for K in 1 .. Natural'Max (1, Cycles / 20) loop
               Add (Tone);
            end loop;
         end Tones;
      begin
         while I + 6 <= Size loop
            declare
               Id  : constant Natural := W16 (I);
               Len : constant Natural := W32 (I + 2);
               D   : constant Natural := I + 6;
            begin
               exit when D + Len > Size;
               case Id is
                  when 16#0100# =>
                     for K in 0 .. Len - 1 loop
                        Add (Data, Buf (D + K));
                     end loop;
                  when 16#0104# =>
                     for K in 3 .. Len - 1 loop
                        Add (Data, (if Buf (D) = 7 then Buf (D + K) and 16#7F#
                                    else Buf (D + K)));
                     end loop;
                  when 16#0110# =>
                     Tones (W16 (D));
                  when 16#0111# =>
                     Tones (W16 (D));
                     Add (Data, 16#AA#);
                     Tones (W16 (D + 2));
                  when 16#0112# =>
                     for K in 1 .. Natural'Max (1, W16 (D) / 20) loop
                        Add (Gap);
                     end loop;
                  when 16#0116# =>
                     --  floating point gap in seconds (IEEE single)
                     declare
                        Bits : constant Unsigned_32 :=
                          Unsigned_32 (W16 (D)) or
                          Shift_Left (Unsigned_32 (W16 (D + 2)), 16);
                        Exp : constant Integer :=
                          Integer (Shift_Right (Bits, 23) and 16#FF#) - 127;
                        Mant : constant Float :=
                          1.0 + Float (Bits and 16#7F_FFFF#) / 8388608.0;
                        Secs : constant Float :=
                          (if Exp < -20 then 0.0 else Mant * 2.0 ** Exp);
                     begin
                        for K in 1 .. Natural'Max
                          (1, Natural (Float'Min (Secs, 60.0) * 120.0))
                        loop
                           Add (Gap);
                        end loop;
                     end;
                  when 16#0113# | 16#0114# | 16#0115# | 16#0117# =>
                     if Id = 16#0117# then
                        Baud := W16 (D);
                     end if;
                  when others => null;
               end case;
               I := D + Len;
            end;
         end loop;
         pragma Unreferenced (Baud);
      end;
      Pos := 0;
      Tape_Name := To_Unbounded_String (Ada.Directories.Simple_Name (Path));
      Ok := Count > 0;
   exception
      when others =>
         Ok := False;
   end Attach;

   procedure Detach is
   begin
      Count := 0;
      Pos := 0;
      Tape_Name := Null_Unbounded_String;
   end Detach;

   function Present return Boolean is (Count > 0);
   function Name return String is (To_String (Tape_Name));

   procedure Rewind is
   begin
      Pos := 0;
   end Rewind;

   function Position_Percent return Natural is
     (if Count = 0 then 0 else Pos * 100 / Count);

   ---------------------------------------------------------------------
   --  ACIA and serial ULA
   ---------------------------------------------------------------------

   S_RDRF : constant Byte := 16#01#;
   S_TDRE : constant Byte := 16#02#;
   S_DCD  : constant Byte := 16#04#;
   S_CTS  : constant Byte := 16#08#;
   S_OVRN : constant Byte := 16#20#;
   S_IRQ  : constant Byte := 16#80#;

   Status   : Byte := S_TDRE;
   Control  : Byte := 0;
   RX_Data  : Byte := 0;
   TX_Data  : Byte := 0;
   ULA      : Byte := 0;
   DCD_Int  : Boolean := False;
   In_Tone  : Boolean := False;
   Timer    : Integer := Byte_Cycles;
   TX_Timer : Integer := 0;

   --  Recording: bytes, with Tone_Mark entries for the carrier tone the
   --  serial ULA sends while the computer writes nothing
   Recording : Event_Access := null;
   Rec_Count : Natural := 0;
   Idle_Cycles : Natural := 0;
   Idle_Tones : Natural := 0;

   procedure Reset is
   begin
      Status := S_TDRE;
      Control := 0;
      ULA := 0;
      DCD_Int := False;
      In_Tone := False;
      Timer := Byte_Cycles;
      TX_Timer := 0;
   end Reset;

   function Motor return Boolean is ((ULA and 16#80#) /= 0);
   function Cassette return Boolean is ((ULA and 16#40#) = 0);

   procedure Serial_ULA_Write (Value : Byte) is
   begin
      ULA := Value;
      if Cassette then
         Status := Status and not S_CTS;
      else
         Status := Status and not (S_DCD or S_CTS);
      end if;
   end Serial_ULA_Write;

   function RX_Int_Enabled return Boolean is ((Control and 16#80#) /= 0);
   function TX_Int_Enabled return Boolean is
     ((Control and 16#60#) = 16#20#);

   function IRQ return Boolean is
     ((RX_Int_Enabled and then ((Status and S_RDRF) /= 0 or else DCD_Int))
      or else (TX_Int_Enabled and then (Status and S_TDRE) /= 0));

   function ACIA_Read (Reg : Natural) return Byte is
   begin
      if Reg mod 2 = 0 then
         return (Status and not S_IRQ) or (if IRQ then S_IRQ else 0);
      else
         Status := Status and not (S_RDRF or S_OVRN);
         DCD_Int := False;
         return RX_Data;
      end if;
   end ACIA_Read;

   procedure ACIA_Write (Reg : Natural; Value : Byte) is
   begin
      if Reg mod 2 = 0 then
         Control := Value;
         if (Value and 3) = 3 then             --  master reset
            Status := (Status and (S_CTS or S_DCD)) or S_TDRE;
            DCD_Int := False;
         end if;
      else
         TX_Data := Value;
         Status := Status and not S_TDRE;
         TX_Timer := Byte_Cycles;
      end if;
   end ACIA_Write;

   procedure Receive (B : Byte) is
   begin
      if (Status and S_RDRF) /= 0 then
         Status := Status or S_OVRN;
      end if;
      RX_Data := B;
      Status := Status or S_RDRF;
   end Receive;

   procedure Store (E : Event) is
   begin
      if Recording = null then
         Recording := new Event_Array (0 .. 2 * 1024 * 1024 - 1);
      end if;
      if Rec_Count <= Recording'Last then
         Recording (Rec_Count) := E;
         Rec_Count := Rec_Count + 1;
      end if;
   end Store;

   procedure Record_Byte (B : Byte) is
   begin
      for I in 1 .. Idle_Tones loop
         Store ((Tone, 0));
      end loop;
      Idle_Tones := 0;
      Idle_Cycles := 0;
      Store ((Data, B));
   end Record_Byte;

   procedure Step is
      E : Event;
   begin
      if Pos >= Count then
         return;
      end if;
      E := Events (Pos);
      Pos := Pos + 1;
      case E.Kind is
         when Tone =>
            if not In_Tone then
               In_Tone := True;
               if (Status and S_DCD) = 0 then
                  Status := Status or S_DCD;
                  DCD_Int := True;
               end if;
            end if;
         when Data =>
            In_Tone := False;
            Status := Status and not S_DCD;
            Receive (E.Value);
         when Gap =>
            In_Tone := False;
      end case;
   end Step;

   procedure Tick (Cycles : Natural) is
   begin
      if TX_Timer > 0 then
         TX_Timer := TX_Timer - Cycles;
         if TX_Timer <= 0 then
            Status := Status or S_TDRE;
            if Motor and then Cassette then
               Record_Byte (TX_Data);
            end if;
         end if;
      end if;
      if Motor and then Cassette and then TX_Timer <= 0 then
         --  carrier tone while nothing is being written
         Idle_Cycles := Idle_Cycles + Cycles;
         while Idle_Cycles >= Byte_Cycles loop
            Idle_Cycles := Idle_Cycles - Byte_Cycles;
            Idle_Tones := Natural'Min (Idle_Tones + 1, 600);
         end loop;
      end if;
      if not Motor or else not Cassette or else Count = 0 then
         return;
      end if;
      Timer := Timer - Cycles;
      while Timer <= 0 loop
         Timer := Timer + Byte_Cycles;
         Step;
      end loop;
   end Tick;

   function First_Block_Is_BASIC return Boolean is
   begin
      for I in 0 .. Count - 20 loop
         if Events (I).Kind = Data and then Events (I).Value = 16#2A# then
            --  sync byte, then the name up to a zero, then load and exec
            declare
               J : Natural := I + 1;
            begin
               while J < Count and then J < I + 12
                 and then Events (J).Value /= 0
               loop
                  J := J + 1;
               end loop;
               J := J + 5;      --  skip zero and the load address
               if J + 1 < Count then
                  declare
                     Exec : constant Natural :=
                       Natural (Events (J).Value) +
                       Natural (Events (J + 1).Value) * 256;
                  begin
                     return Exec in 16#8000# .. 16#80FF#;
                  end;
               end if;
               return False;
            end;
         end if;
      end loop;
      return False;
   end First_Block_Is_BASIC;

   function Recorded_Bytes return Natural is
      N : Natural := 0;
   begin
      for I in 0 .. Rec_Count - 1 loop
         if Recording (I).Kind = Data then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Recorded_Bytes;

   procedure Save_Recording (Path : String; Ok : out Boolean) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      S : Stream_Access;
      procedure W8 (B : Natural) is
      begin
         Byte'Write (S, Byte (B mod 256));
      end W8;
      procedure W16 (V : Natural) is
      begin
         W8 (V mod 256);
         W8 (V / 256);
      end W16;
      procedure W32 (V : Natural) is
      begin
         W16 (V mod 65536);
         W16 (V / 65536);
      end W32;
   begin
      Ok := False;
      Create (F, Out_File, Path);
      S := Stream (F);
      String'Write (S, "UEF File!");
      W8 (0);
      W8 (10);
      W8 (0);
      declare
         I : Natural := 0;
      begin
         while I < Rec_Count loop
            declare
               J : Natural := I;
            begin
               while J < Rec_Count
                 and then Recording (J).Kind = Recording (I).Kind
               loop
                  J := J + 1;
               end loop;
               if Recording (I).Kind = Tone then
                  W16 (16#0110#);
                  W32 (2);
                  W16 (Natural'Min (65535, (J - I) * 20));
               else
                  W16 (16#0100#);
                  W32 (J - I);
                  for K in I .. J - 1 loop
                     W8 (Natural (Recording (K).Value));
                  end loop;
               end if;
               I := J;
            end;
         end loop;
      end;
      W16 (16#0110#);
      W32 (2);
      W16 (1000);
      Close (F);
      Ok := True;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Save_Recording;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Natural'Write (S, Pos);
      Byte'Write (S, Status);
      Byte'Write (S, Control);
      Byte'Write (S, RX_Data);
      Byte'Write (S, ULA);
      Boolean'Write (S, DCD_Int);
      Boolean'Write (S, In_Tone);
      Integer'Write (S, Timer);
      Integer'Write (S, TX_Timer);
   end Save_State;

   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class) is
   begin
      Natural'Read (S, Pos);
      if Pos > Count then
         Pos := 0;
      end if;
      Byte'Read (S, Status);
      Byte'Read (S, Control);
      Byte'Read (S, RX_Data);
      Byte'Read (S, ULA);
      Boolean'Read (S, DCD_Int);
      Boolean'Read (S, In_Tone);
      Integer'Read (S, Timer);
      Integer'Read (S, TX_Timer);
   end Load_State;

end Tape;
