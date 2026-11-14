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
--  The complete BBC Micro: memory map, sideways ROM paging, I/O dispatch
--  (SHEILA), CPU, chips, and the per-frame run loop.

with Types; use Types;

package Machine is

   type Model_Type is (Model_B, Model_B_Plus, Master_128);

   procedure Power_On (M : Model_Type; ROM_Dir : String; Ok : out Boolean);
   --  Load the ROM set for the model and perform a power-on reset.

   function Model return Model_Type;
   function Error_Message return String;

   procedure Reset;
   --  Power-on reset (memory cleared, all chips reset).

   procedure Break_Key (Down : Boolean);
   --  The BREAK key (resets only the CPU, as on the real machine; the OS
   --  then tells BREAK, SHIFT+BREAK and CTRL+BREAK apart).

   procedure Run_Frame;
   --  Emulate until the next vertical sync (one 50 Hz field).

   function Frame_Rate return Float;     --  50.08 (312 lines of 64 us)

   procedure Type_Text (S : String);
   --  Type text through the keyboard (LF = RETURN).
   function Typing_Busy return Boolean;

   function Default_Page return Word;
   --  BASIC's PAGE after a reset: &1900 with a disc system ROM, else &E00.

   procedure Autostart (Path : String; Ok : out Boolean);
   --  Attach the image/file, reset, and boot / run it.
   function Autostart_Busy return Boolean;

   procedure Boot_Disc;
   --  Reset with SHIFT held (SHIFT+BREAK; SHIFT+A+BREAK for an ADFS disc
   --  on the Master): boots the disc in drive 0 by its boot option.

   function Frame_Count return Natural;
   function Peek (Addr : Word) return Byte;     --  CPU view, no side effects
   procedure Poke (Addr : Word; Value : Byte);  --  main RAM
   function RAM_Peek (Addr : Natural) return Byte;
   function Screen_Peek (Addr : Word) return Byte;
   procedure Screen_Poke (Addr : Word; Value : Byte);
   --  Screen memory as the display sees it (the Master's shadow RAM
   --  when the display uses it).
   function Get_PC return Word;
   function Screen_Contains (Text : String) return Boolean;
   --  True when Text is visible (mode 7 screen memory, or the OS font
   --  recognised in a one bit per pixel mode).
   function Screen_Text return String;
   function At_Prompt return Boolean;   --  BASIC's ">" prompt is showing
   function Screen_Start return Natural;   --  address of the first byte
   function Teletext_Mode return Boolean;  --  the video ULA shows mode 7
   function Screen_Mode return Integer;    --  OS MODE (0 .. 7), from &0355
   function ULA_Palette (Index : Natural) return Byte;
   --  Physical colour (0 .. 15) of video ULA palette entry Index
   --  The screen as text lines (same recognition), for tests.

   --  Sideways ROMs
   procedure Load_Sideways_ROM (Slot : Natural; Path : String;
                                Ok : out Boolean);
   procedure Set_Sideways_RAM (Slot : Natural; On : Boolean);

   Model_B_SWRAM : Boolean := True;
   --  Give the Model B sideways RAM in slots 4-7 at power-on (as most
   --  expanded machines had; the Master always has it).
   function ROM_Title (Slot : Natural) return String;   --  "" = empty
   function Slot_Is_RAM (Slot : Natural) return Boolean;
   procedure Clear_Slot (Slot : Natural);
   --  Empty a sideways slot (no ROM, no RAM)
   function Current_ROM_Bank return Natural;

   --  Discs (drive 0 / 1)
   procedure Attach (Path : String; Ok : out Boolean; Drive : Natural := 0);
   procedure Detach (Drive : Natural := 0);
   function Disc_Name (Drive : Natural := 0) return String;
   function Drive_LED return Boolean;
   procedure Create_Disc (Path : String; Ok : out Boolean);
   --  A blank, formatted 80-track single-sided image.

   --  Tape
   procedure Attach_Tape (Path : String; Ok : out Boolean);
   function Tape_Name return String;
   procedure Tape_Rewind;
   function Tape_Motor return Boolean;
   function Tape_Recorded return Natural;          --  bytes saved to tape
   procedure Save_Tape_Recording (Path : String; Ok : out Boolean);
   Fast_Tape : Boolean := True;
   --  Warp while the cassette motor runs.

   --  Analogue joystick inputs (ADC channels 0 .. 3), -1.0 .. 1.0
   type Axis_Index is range 0 .. 3;
   procedure Set_Axis (A : Axis_Index; Value : Float);

   procedure Save_Snapshot (Path : String; Ok : out Boolean);
   procedure Load_Snapshot (Path : String; Ok : out Boolean);

   function Program_Peek (Addr : Word) return Byte;
   procedure Program_Poke (Addr : Word; Value : Byte);
   --  The memory BASIC and started programs run in: the Second
   --  Processor's when the Tube is on, else the host's (as Peek / Poke).

   --  Debugger
   type Debug_CPU_Type is (Host_CPU, Parasite_CPU);
   procedure Set_Debug_CPU (C : Debug_CPU_Type);
   function Debug_CPU return Debug_CPU_Type;
   --  Which processor the debugger works on (breakpoints, watches,
   --  stepping, registers, monitor memory).  Parasite_CPU only takes
   --  effect while the 6502 Second Processor is on; it is chosen
   --  automatically when the machine starts with the Tube.
   function Tube_Active return Boolean;
   function Speech_Active return Boolean;
   --  The speech upgrade is fitted and its PHROM loaded (Model B / B+).

   procedure Step_Instruction;
   procedure Step_Over;
   procedure Step_Out;
   procedure Run_To (Addr : Word);
   procedure Request_Break;

   type Stop_Reason is (None, Breakpoint, Watch_Read, Watch_Write,
                        Step_Done, Paused, Basic_Line);

   --  BASIC debugging: stop when BASIC's text pointer enters a program
   --  line with a breakpoint, or (Step_Basic_Line) any other line
   procedure Clear_Basic_Breakpoints;
   procedure Add_Basic_Breakpoint (Line_Number : Natural);
   procedure Step_Basic_Line;
   function Basic_Stop_Line return Integer;   --  -1 = none
   function Last_Stop return Stop_Reason;
   function Stop_Text return String;

   procedure Add_Watch (From, To : Word; On_Read, On_Write : Boolean);
   procedure Remove_Watch (From : Word);
   procedure Clear_Watches;
   function Watch_List return String;

   function Is_Breakpoint (Addr : Word) return Boolean;
   function Cycle_Count return Long_Long_Integer;   --  2 MHz cycles

   procedure Inject_And_Run (Data : Byte_Array; Load : Word;
                             Command : String; With_Reset : Boolean := True);
   --  Reset (optional), wait for the BASIC prompt, copy Data into RAM at
   --  Load (for a BASIC program at PAGE the BASIC pointers are set too)
   --  and type Command (e.g. "RUN").

   procedure Set_Breakpoint (Addr : Word);
   procedure Clear_Breakpoint (Addr : Word);
   procedure Clear_Breakpoints;
   function Breakpoint_List return String;
   function Break_Hit return Boolean;
   procedure Resume;
   function Register_Text return String;
   function Monitor_Peek (Addr : Word) return Byte;
   procedure Monitor_Poke (Addr : Word; Value : Byte);
   function CPU_PC return Word;
   procedure Monitor_Set_PC (Addr : Word);
   function Debug_Info return String;

   procedure Shutdown;
   --  Write back modified disc images.

end Machine;
