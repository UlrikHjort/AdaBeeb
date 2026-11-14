-- ***************************************************************************
--                             AdaBeeb - Keyboard
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
--  BBC Micro keyboard matrix (10 columns x 8 rows), the start-up option
--  links read through row 0, BREAK, and mapping of host (GDK) keys.
--
--  Internal key number = row * 16 + column (as in INKEY(-1 - n)).

with Interfaces;
with Types; use Types;

package Keyboard is

   subtype Column is Natural range 0 .. 15;
   subtype Row is Natural range 0 .. 7;

   type Matrix_Type is array (Column) of Byte;   --  bit set = key down
   Matrix : Matrix_Type := (others => 0);

   Links : Byte := 0;
   --  Keyboard links (start-up options, *FX255): bit n = link at column
   --  9 - n... stored as the byte the OS reads: bits 0-2 screen mode,
   --  bit 3 = SHIFT+BREAK action inverted, bits 4-5 disc timings.

   Break_Down : Boolean := False;

   Master : Boolean := False;
   --  BBC Master keyboard: 13 columns (numeric keypad in 10 .. 12), no
   --  start-up links (the Master keeps its options in CMOS RAM).

   Hold_Shift : Boolean := False;
   Hold_Key   : Integer := -1;
   --  Another key held by the emulator (internal key number), e.g. A for
   --  the Master's SHIFT+A+BREAK ADFS boot.
   --  SHIFT held down by the emulator (autostart: SHIFT+BREAK boot).

   Caps_LED : Boolean := True;    --  set by Machine from the latch
   --  Used to pick the shift state for typed letters.

   --  Joystick (switched joystick from the keypad): bits 0 up, 1 down,
   --  2 left, 3 right, 4 fire
   Joy1, Joy2 : Byte := 0;
   type Joy_Keyset is (Keypad, Cursor_Keys);
   type Joy_Port is range 0 .. 2;    --  0 = no joystick emulation
   Joystick_Port : Joy_Port := 1;
   Joystick_Keys : Joy_Keyset := Keypad;

   Positional : Boolean := False;
   --  False: symbolic mapping (type the character you mean).
   --  True:  PC key positions = BBC key positions.

   procedure Key_Event
     (Keyval  : Interfaces.Unsigned_32;
      Keycode : Natural;
      Pressed : Boolean);

   procedure Release_All;

   function Key_Down (Col : Column; R : Row) return Boolean;
   --  Includes the links on row 0, columns 2 .. 9.

   function Column_Active (Col : Column) return Boolean;
   --  A key in rows 1 .. 7 of the column is down.

   function Any_Key return Boolean;
   --  A key in rows 1 .. 7 of any column (auto-scan interrupt).

   procedure Press (Col : Column; R : Row; Down : Boolean);

   procedure Set_Host_Joystick (Bits : Byte);
   function Host_Joystick_Bits return Byte;

   procedure Type_Keys (S : String);
   --  Queue text to be typed through the matrix; LF = RETURN.
   --  Upper and lower case follow Caps_LED.
   function Typing_Busy return Boolean;

   procedure Tick_Typing;
   --  Advance matrix typing; call once per frame.

   function Keys_Help return String;

end Keyboard;
