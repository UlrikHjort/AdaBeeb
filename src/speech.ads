-- ***************************************************************************
--                              AdaBeeb - Speech
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
--  The Acorn speech system: a TMS5220 voice synthesis processor with
--  TMS6100 speech PHROMs (the word ROM "PHROM A" answers as PHROM 15).
--
--  The CPU talks to the chip over the system VIA's slow data bus: the
--  addressable latch's bit 1 is its read select and bit 2 its write
--  select (both active low), PB7 is READY (low = ready; high with no chip
--  fitted, which is how the OS finds out) and PB6 the interrupt line.
--
--  Commands (bits 6-4 of a written byte): 1 read byte, 3 read and branch,
--  4 load address (bits 3-0, five nibbles, low first), 5 speak (from the
--  PHROM), 6 speak external (data bytes follow into a 16-byte FIFO),
--  7 reset.  Reads return the status (bit 7 talking, 6 buffer low,
--  5 buffer empty) or, after a read byte command, the PHROM byte.
--
--  Speech is LPC: every 25 ms a frame gives energy, pitch and up to ten
--  reflection coefficients, interpolated eight times a frame and fed to
--  a ten-stage lattice filter excited by a chirp (voiced) or noise
--  (unvoiced), at 8 kHz.

with Types; use Types;

package Speech is

   Enabled : Boolean := False;
   --  The speech upgrade is fitted (Model B / B+; takes effect at power-on).

   subtype PHROM_Number is Natural range 0 .. 15;
   procedure Load_PHROM (N : PHROM_Number; Path : String; Ok : out Boolean);
   function Present return Boolean;    --  enabled and PHROM A loaded

   procedure Reset;

   procedure Write (Value : Byte);     --  write select strobe
   function Read return Byte;          --  read select strobe
   function Ready return Boolean;
   function Interrupt return Boolean;

   procedure Clock (Cycles : Natural);
   --  Advance by Cycles of the 2 MHz clock.

   function Output return Float;
   --  The current output sample, about -32767.0 .. 32767.0.

   function Talking return Boolean;

end Speech;
