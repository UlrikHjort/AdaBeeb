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
--  Texas Instruments SN76489 sound generator (BBC Micro).
--
--  Three square-wave tone channels and one noise channel, clocked at
--  4 MHz / 16 = 250 kHz.  The CPU writes bytes through the system VIA's
--  slow data bus; Machine calls Write when the sound write-enable line
--  of the addressable latch goes low.  Samples are generated in step with
--  the 2 MHz CPU clock and handed to Sink.

with Ada.Streams;
with Types; use Types;

package Sound is

   Sample_Rate : constant := 44_100;

   type Sample is range -32768 .. 32767;
   for Sample'Size use 16;

   type Sink_Proc is access procedure (S : Sample);
   Sink : Sink_Proc := null;

   type Extra_Source is access function return Float;
   Extra : Extra_Source := null;
   --  Another sound source mixed into the output (the speech chip).

   procedure Reset;
   procedure Write (Value : Byte);

   procedure Clock (Cycles : Natural);
   --  Advance by Cycles of the 2 MHz CPU clock.

   procedure Set_Clock (Hz : Natural);
   --  CPU clock rate used for sample timing (default 2_000_000).

   type Channel_Index is range 0 .. 3;
   function Period (C : Channel_Index) return Natural;
   function Attenuation (C : Channel_Index) return Natural;   --  15 = off
   function Noise_Control return Natural;

   procedure Save_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);
   procedure Load_State
     (S : not null access Ada.Streams.Root_Stream_Type'Class);

end Sound;
