-- ***************************************************************************
--                              AdaBeeb - Basic
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
--  BBC BASIC tokenizer / detokenizer (BASIC II on the Model B, BASIC IV
--  on the Master), following the ROM's own tokenising rules: keywords in
--  upper case only, abbreviations with '.', conditional tokens (PI, END,
--  TIME ...), pseudo-variables in statement position, line numbers after
--  GOTO / GOSUB / THEN / ELSE / RESTORE encoded as &8D b1 b2 b3, the rest
--  of REM / DATA / * lines untouched.
--
--  Text form: one line per text line, "10 PRINT ..."; lines without a
--  number are numbered automatically (previous + 10).
--  Memory form: &0D, then per line: number high, low, length, text, &0D;
--  &FF after the last line's &0D.

with Types; use Types;
with Ada.Strings.Unbounded;

package Basic is

   type Dialect is (Basic_II, Basic_IV);

   Page : Word := 16#1900#;
   --  Where programs are built and loaded (BASIC's PAGE).

   function Is_Source (Path : String) return Boolean;   --  .bas .bbc .txt
   function Load_Address (D : Dialect) return Word is (Page);

   procedure Tokenize_File (Path : String; D : Dialect);
   procedure Tokenize_Text (Text : String; D : Dialect);
   function Tokenize_Line (Text : String) return Byte_Array;
   --  The tokenised text of one line (no number, length or CR).

   function Error_Count return Natural;
   function Error_Line (I : Positive) return Natural;
   function Error_Text (I : Positive) return String;
   function Program_Length return Natural;
   function Program_Byte (I : Natural) return Byte;
   function Program_Load return Word;
   function Source_Line_Of (Basic_Line : Natural) return Natural;
   function Basic_Line_Of (Source_Line : Positive) return Integer;
   --  BASIC line number of a text line (1-based) of the last
   --  tokenized source, -1 when it has none (blank / error)

   procedure Build (Source : String; D : Dialect;
                    PRG : out Ada.Strings.Unbounded.Unbounded_String;
                    Ok : out Boolean);
   --  Tokenize Source and write the program file (Source with no
   --  extension, plus a .inf file with load and exec address).
   type Report_Proc is access procedure (Line : String);
   Report : Report_Proc := null;

   type Reader is access function (Addr : Word) return Byte;
   function Detokenize (Read : not null Reader; Load : Word; D : Dialect)
                        return String;
   --  List the program at Load (memory read through Read).

   function Detokenize_Data (Data : Byte_Array) return String;
   function List_PRG (Path : String; Ok : out Boolean) return String;
   --  List a tokenised BASIC file.

   function Current_Line (Read : not null Reader; Load : Word)
     return Integer;
   --  The line BASIC is executing (from its text pointer), -1 in
   --  direct mode.

end Basic;
