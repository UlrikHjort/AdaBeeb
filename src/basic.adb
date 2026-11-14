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
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Text_IO;
with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;

package body Basic is

   ---------------------------------------------------------------------
   --  Keyword table (order and flags as in the BASIC II ROM)
   ---------------------------------------------------------------------

   F_Cond  : constant := 16#01#;   --  not before an alphanumeric
   F_Mid   : constant := 16#02#;   --  middle of statement afterwards
   F_Start : constant := 16#04#;   --  start of statement afterwards
   F_FnProc : constant := 16#08#;  --  name follows, not tokenised
   F_LineNo : constant := 16#10#;  --  line numbers follow
   F_Raw   : constant := 16#20#;   --  rest of line not tokenised
   F_Pseudo : constant := 16#40#;  --  +&40 at the start of a statement

   type Keyword is record
      Text  : access constant String;
      Token : Byte;
      Flags : Byte;
   end record;

   function K (S : String; T, F : Byte) return Keyword is
     ((Text => new String'(S), Token => T, Flags => F));

   Table : constant array (Positive range <>) of Keyword :=
     (K ("AND", 16#80#, 16#00#), K ("ABS", 16#94#, 16#00#),
      K ("ACS", 16#95#, 16#00#), K ("ADVAL", 16#96#, 16#00#),
      K ("ASC", 16#97#, 16#00#), K ("ASN", 16#98#, 16#00#),
      K ("ATN", 16#99#, 16#00#), K ("AUTO", 16#C6#, 16#10#),
      K ("BGET", 16#9A#, 16#01#), K ("BPUT", 16#D5#, 16#03#),
      K ("COLOUR", 16#FB#, 16#02#), K ("CALL", 16#D6#, 16#02#),
      K ("CHAIN", 16#D7#, 16#02#), K ("CHR$", 16#BD#, 16#00#),
      K ("CLEAR", 16#D8#, 16#01#), K ("CLOSE", 16#D9#, 16#03#),
      K ("CLG", 16#DA#, 16#01#), K ("CLS", 16#DB#, 16#01#),
      K ("COS", 16#9B#, 16#00#), K ("COUNT", 16#9C#, 16#01#),
      K ("DATA", 16#DC#, 16#20#), K ("DEG", 16#9D#, 16#00#),
      K ("DEF", 16#DD#, 16#00#), K ("DELETE", 16#C7#, 16#10#),
      K ("DIV", 16#81#, 16#00#), K ("DIM", 16#DE#, 16#02#),
      K ("DRAW", 16#DF#, 16#02#), K ("ENDPROC", 16#E1#, 16#01#),
      K ("END", 16#E0#, 16#01#), K ("ENVELOPE", 16#E2#, 16#02#),
      K ("ELSE", 16#8B#, 16#14#), K ("EVAL", 16#A0#, 16#00#),
      K ("ERL", 16#9E#, 16#01#), K ("ERROR", 16#85#, 16#04#),
      K ("EOF", 16#C5#, 16#01#), K ("EOR", 16#82#, 16#00#),
      K ("ERR", 16#9F#, 16#01#), K ("EXP", 16#A1#, 16#00#),
      K ("EXT", 16#A2#, 16#01#), K ("FOR", 16#E3#, 16#02#),
      K ("FALSE", 16#A3#, 16#01#), K ("FN", 16#A4#, 16#08#),
      K ("GOTO", 16#E5#, 16#12#), K ("GET$", 16#BE#, 16#00#),
      K ("GET", 16#A5#, 16#00#), K ("GOSUB", 16#E4#, 16#12#),
      K ("GCOL", 16#E6#, 16#02#), K ("HIMEM", 16#93#, 16#43#),
      K ("INPUT", 16#E8#, 16#02#), K ("IF", 16#E7#, 16#02#),
      K ("INKEY$", 16#BF#, 16#00#), K ("INKEY", 16#A6#, 16#00#),
      K ("INT", 16#A8#, 16#00#), K ("INSTR(", 16#A7#, 16#00#),
      K ("LIST", 16#C9#, 16#10#), K ("LINE", 16#86#, 16#00#),
      K ("LOAD", 16#C8#, 16#02#), K ("LOMEM", 16#92#, 16#43#),
      K ("LOCAL", 16#EA#, 16#02#), K ("LEFT$(", 16#C0#, 16#00#),
      K ("LEN", 16#A9#, 16#00#), K ("LET", 16#E9#, 16#04#),
      K ("LOG", 16#AB#, 16#00#), K ("LN", 16#AA#, 16#00#),
      K ("MID$(", 16#C1#, 16#00#), K ("MODE", 16#EB#, 16#02#),
      K ("MOD", 16#83#, 16#00#), K ("MOVE", 16#EC#, 16#02#),
      K ("NEXT", 16#ED#, 16#02#), K ("NEW", 16#CA#, 16#01#),
      K ("NOT", 16#AC#, 16#00#), K ("OLD", 16#CB#, 16#01#),
      K ("ON", 16#EE#, 16#02#), K ("OFF", 16#87#, 16#00#),
      K ("OR", 16#84#, 16#00#), K ("OPENIN", 16#8E#, 16#00#),
      K ("OPENOUT", 16#AE#, 16#00#), K ("OPENUP", 16#AD#, 16#00#),
      K ("OSCLI", 16#FF#, 16#02#), K ("PRINT", 16#F1#, 16#02#),
      K ("PAGE", 16#90#, 16#43#), K ("PTR", 16#8F#, 16#43#),
      K ("PI", 16#AF#, 16#01#), K ("PLOT", 16#F0#, 16#02#),
      K ("POINT(", 16#B0#, 16#00#), K ("PROC", 16#F2#, 16#0A#),
      K ("POS", 16#B1#, 16#01#), K ("RETURN", 16#F8#, 16#01#),
      K ("REPEAT", 16#F5#, 16#00#), K ("REPORT", 16#F6#, 16#01#),
      K ("READ", 16#F3#, 16#02#), K ("REM", 16#F4#, 16#20#),
      K ("RUN", 16#F9#, 16#01#), K ("RAD", 16#B2#, 16#00#),
      K ("RESTORE", 16#F7#, 16#12#), K ("RIGHT$(", 16#C2#, 16#00#),
      K ("RND", 16#B3#, 16#01#), K ("RENUMBER", 16#CC#, 16#10#),
      K ("STEP", 16#88#, 16#00#), K ("SAVE", 16#CD#, 16#02#),
      K ("SGN", 16#B4#, 16#00#), K ("SIN", 16#B5#, 16#00#),
      K ("SQR", 16#B6#, 16#00#), K ("SPC", 16#89#, 16#00#),
      K ("STR$", 16#C3#, 16#00#), K ("STRING$(", 16#C4#, 16#00#),
      K ("SOUND", 16#D4#, 16#02#), K ("STOP", 16#FA#, 16#01#),
      K ("TAN", 16#B7#, 16#00#), K ("THEN", 16#8C#, 16#14#),
      K ("TO", 16#B8#, 16#00#), K ("TAB(", 16#8A#, 16#00#),
      K ("TRACE", 16#FC#, 16#12#), K ("TIME", 16#91#, 16#43#),
      K ("TRUE", 16#B9#, 16#01#), K ("UNTIL", 16#FD#, 16#02#),
      K ("USR", 16#BA#, 16#00#), K ("VDU", 16#EF#, 16#02#),
      K ("VAL", 16#BB#, 16#00#), K ("VPOS", 16#BC#, 16#01#),
      K ("WIDTH", 16#FE#, 16#02#),
      --  statement forms of the pseudo-variables (for listing)
      K ("PAGE", 16#D0#, 16#00#), K ("PTR", 16#CF#, 16#00#),
      K ("TIME", 16#D1#, 16#00#), K ("LOMEM", 16#D2#, 16#00#),
      K ("HIMEM", 16#D3#, 16#00#),
      --  BASIC IV (Master) only
      K ("EDIT", 16#CE#, 16#10#), K ("COLOR", 16#FB#, 16#02#));

   Tokenising_Entries : constant := 121;   --  then listing-only entries
   First_IV_Entry : constant := 127;         --  BASIC IV additions
   Current_Dialect : Dialect := Basic_II;

   function Is_Alnum (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '`');

   ---------------------------------------------------------------------
   --  Tokenising one line
   ---------------------------------------------------------------------

   function Tokenize_Line (Text : String) return Byte_Array is
      Out_B : Byte_Array (0 .. 2 * Text'Length + 8);
      N : Natural := 0;
      I : Positive := Text'First;
      Start_Of_Stmt : Boolean := True;
      Line_Mode : Boolean := False;

      procedure Emit (B : Byte) is
      begin
         if N <= Out_B'Last then
            Out_B (N) := B;
            N := N + 1;
         end if;
      end Emit;

      procedure Emit_C (C : Character) is
      begin
         Emit (Character'Pos (C));
      end Emit_C;

      procedure Copy_Rest is
      begin
         while I <= Text'Last loop
            Emit_C (Text (I));
            I := I + 1;
         end loop;
      end Copy_Rest;

      procedure Emit_Line_Number (V : Natural) is
         Lo : constant Byte := Byte (V mod 256);
         Hi : constant Byte := Byte ((V / 256) mod 256);
      begin
         Emit (16#8D#);
         Emit (((Shift_Right (Lo and 16#C0#, 2)) or
                (Shift_Right (Hi and 16#C0#, 4))) xor 16#54#);
         Emit ((Lo and 16#3F#) or 16#40#);
         Emit ((Hi and 16#3F#) or 16#40#);
      end Emit_Line_Number;

      function Match (E : Keyword; Len : out Natural) return Boolean is
         W : constant String := E.Text.all;
         J : Natural := 0;
      begin
         Len := 0;
         loop
            if J = W'Length then
               Len := J;
               return True;
            end if;
            exit when I + J > Text'Last;
            if Text (I + J) = '.' and then J > 0 then
               Len := J + 1;          --  abbreviation
               return True;
            end if;
            exit when Text (I + J) /= W (W'First + J);
            J := J + 1;
         end loop;
         return False;
      end Match;

   begin
      while I <= Text'Last loop
         declare
            C : constant Character := Text (I);
         begin
            if C = '"' then
               Emit_C (C);
               I := I + 1;
               while I <= Text'Last and then Text (I) /= '"' loop
                  Emit_C (Text (I));
                  I := I + 1;
               end loop;
               if I <= Text'Last then
                  Emit_C ('"');
                  I := I + 1;
               end if;
               Start_Of_Stmt := False;
               Line_Mode := False;
            elsif C = ':' then
               Emit_C (C);
               I := I + 1;
               Start_Of_Stmt := True;
               Line_Mode := False;
            elsif C = '*' and then Start_Of_Stmt then
               Copy_Rest;
            elsif C = '&' then
               Emit_C (C);
               I := I + 1;
               while I <= Text'Last
                 and then Text (I) in '0' .. '9' | 'A' .. 'F'
               loop
                  Emit_C (Text (I));
                  I := I + 1;
               end loop;
               Start_Of_Stmt := False;
               Line_Mode := False;
            elsif C in '0' .. '9' | '.' then
               if Line_Mode and then C /= '.' then
                  declare
                     V : Natural := 0;
                  begin
                     while I <= Text'Last and then Text (I) in '0' .. '9'
                     loop
                        V := (V * 10 + Character'Pos (Text (I)) - 48)
                          mod 65536;
                        I := I + 1;
                     end loop;
                     Emit_Line_Number (V);
                  end;
               else
                  while I <= Text'Last
                    and then Text (I) in '0' .. '9' | '.'
                  loop
                     Emit_C (Text (I));
                     I := I + 1;
                  end loop;
                  Line_Mode := False;
               end if;
               Start_Of_Stmt := False;
            elsif C in 'A' .. 'Z' then
               declare
                  Found : Natural := 0;
                  Len : Natural := 0;
               begin
                  for E in 1 .. Tokenising_Entries loop
                     if Match (Table (E), Len) then
                        Found := E;
                        exit;
                     end if;
                  end loop;
                  if Found = 0 and then Current_Dialect = Basic_IV then
                     for E in First_IV_Entry .. Table'Last loop
                        if Match (Table (E), Len) then
                           Found := E;
                           exit;
                        end if;
                     end loop;
                  end if;
                  if Found > 0
                    and then (Table (Found).Flags and F_Cond) /= 0
                    and then I + Len <= Text'Last
                    and then Is_Alnum (Text (I + Len))
                    and then Text (I + Len - 1) /= '.'
                  then
                     Found := 0;          --  part of a variable name
                  end if;
                  if Found = 0 then
                     while I <= Text'Last and then Is_Alnum (Text (I)) loop
                        Emit_C (Text (I));
                        I := I + 1;
                     end loop;
                     Start_Of_Stmt := False;
                     Line_Mode := False;
                  else
                     declare
                        E : constant Keyword := Table (Found);
                        T : Byte := E.Token;
                     begin
                        if (E.Flags and F_Pseudo) /= 0 and then Start_Of_Stmt
                        then
                           T := T + 16#40#;
                        end if;
                        Emit (T);
                        I := I + Len;
                        if (E.Flags and F_Mid) /= 0 then
                           Start_Of_Stmt := False;
                        end if;
                        if (E.Flags and F_Start) /= 0 then
                           Start_Of_Stmt := True;
                        end if;
                        if (E.Flags and (F_Mid or F_Start)) = 0 then
                           Start_Of_Stmt := False;
                        end if;
                        Line_Mode := (E.Flags and F_LineNo) /= 0;
                        if (E.Flags and F_FnProc) /= 0 then
                           while I <= Text'Last and then Is_Alnum (Text (I))
                           loop
                              Emit_C (Text (I));
                              I := I + 1;
                           end loop;
                        end if;
                        if (E.Flags and F_Raw) /= 0 then
                           Copy_Rest;
                        end if;
                     end;
                  end if;
               end;
            elsif C in 'a' .. 'z' | '_' | '`' then
               while I <= Text'Last and then Is_Alnum (Text (I)) loop
                  Emit_C (Text (I));
                  I := I + 1;
               end loop;
               Start_Of_Stmt := False;
               Line_Mode := False;
            else
               Emit_C (C);
               I := I + 1;
               if C /= ' ' and then C /= ',' then
                  Line_Mode := False;
                  Start_Of_Stmt := False;
               end if;
            end if;
         end;
      end loop;
      return Out_B (0 .. N - 1);
   end Tokenize_Line;

   ---------------------------------------------------------------------
   --  Programs
   ---------------------------------------------------------------------

   Max_Program : constant := 32 * 1024;
   Prog : Byte_Array (0 .. Max_Program - 1);
   Prog_Len : Natural := 0;
   Load : Word := 16#1900#;

   type Error_Rec is record
      Line : Natural := 0;
      Text : Unbounded_String;
   end record;
   Errors : array (1 .. 100) of Error_Rec;
   Err_Count : Natural := 0;

   Line_Map_Max : constant := 4000;
   Line_Nums : array (1 .. Line_Map_Max) of Natural;
   Line_Src  : array (1 .. Line_Map_Max) of Natural;
   Map_Count : Natural := 0;

   procedure Add_Error (L : Natural; T : String) is
   begin
      if Err_Count < Errors'Last then
         Err_Count := Err_Count + 1;
         Errors (Err_Count) := (L, To_Unbounded_String (T));
      end if;
   end Add_Error;

   procedure Tokenize_Text (Text : String; D : Dialect) is
      Pos : Natural := Text'First;
      Src_Line : Natural := 0;
      Last_Num : Integer := -1;
      procedure Put (B : Byte) is
      begin
         if Prog_Len < Max_Program then
            Prog (Prog_Len) := B;
            Prog_Len := Prog_Len + 1;
         end if;
      end Put;
   begin
      Current_Dialect := D;
      Err_Count := 0;
      Map_Count := 0;
      Prog_Len := 0;
      Load := Page;
      Put (16#0D#);
      while Pos <= Text'Last loop
         declare
            E : Natural := Index (Text (Pos .. Text'Last), (1 => ASCII.LF));
            L_Last : Natural;
         begin
            if E = 0 then
               E := Text'Last + 1;
            end if;
            L_Last := E - 1;
            if L_Last >= Pos and then Text (L_Last) = ASCII.CR then
               L_Last := L_Last - 1;
            end if;
            Src_Line := Src_Line + 1;
            declare
               Line : constant String := Text (Pos .. L_Last);
               J : Natural := Line'First;
               Num : Integer := -1;
            begin
               while J <= Line'Last and then Line (J) = ' ' loop
                  J := J + 1;
               end loop;
               if J <= Line'Last then
                  if Line (J) in '0' .. '9' then
                     Num := 0;
                     while J <= Line'Last and then Line (J) in '0' .. '9' loop
                        Num := Num * 10 + Character'Pos (Line (J)) - 48;
                        J := J + 1;
                        exit when Num > 32767;
                     end loop;
                  else
                     Num := (if Last_Num < 0 then 10 else Last_Num + 10);
                  end if;
                  if Num > 32767 then
                     Add_Error (Src_Line, "line number too large");
                  elsif Num <= Last_Num then
                     Add_Error (Src_Line, "line number" & Num'Image &
                                " not after" & Last_Num'Image);
                  else
                     declare
                        T : constant Byte_Array :=
                          Tokenize_Line (Line (J .. Line'Last));
                     begin
                        if T'Length > 251 then
                           Add_Error (Src_Line, "line too long");
                        else
                           Put (Byte (Num / 256));
                           Put (Byte (Num mod 256));
                           Put (Byte (T'Length + 4));
                           for B of T loop
                              Put (B);
                           end loop;
                           Put (16#0D#);
                           if Map_Count < Line_Map_Max then
                              Map_Count := Map_Count + 1;
                              Line_Nums (Map_Count) := Num;
                              Line_Src (Map_Count) := Src_Line;
                           end if;
                        end if;
                     end;
                     Last_Num := Num;
                  end if;
               end if;
            end;
            Pos := E + 1;
         end;
      end loop;
      Put (16#FF#);
      if Prog_Len >= Max_Program then
         Add_Error (Src_Line, "program too large");
      end if;
   end Tokenize_Text;

   function Read_Text_File (Path : String) return String is
      use Ada.Text_IO;
      F : File_Type;
      R : Unbounded_String;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         Append (R, Get_Line (F));
         Append (R, ASCII.LF);
      end loop;
      Close (F);
      return To_String (R);
   end Read_Text_File;

   procedure Tokenize_File (Path : String; D : Dialect) is
   begin
      Tokenize_Text (Read_Text_File (Path), D);
   exception
      when others =>
         Err_Count := 0;
         Prog_Len := 0;
         Add_Error (0, "cannot read " & Path);
   end Tokenize_File;

   function Is_Source (Path : String) return Boolean is
      L : constant String := To_Lower (Path);
      function Ends (E : String) return Boolean is
        (L'Length > E'Length and then L (L'Last - E'Length + 1 .. L'Last) = E);
   begin
      return Ends (".bas") or else Ends (".bbc");
   end Is_Source;

   function Error_Count return Natural is (Err_Count);
   function Error_Line (I : Positive) return Natural is (Errors (I).Line);
   function Error_Text (I : Positive) return String is
     (To_String (Errors (I).Text));
   function Program_Length return Natural is (Prog_Len);
   function Program_Byte (I : Natural) return Byte is (Prog (I));
   function Program_Load return Word is (Load);

   function Source_Line_Of (Basic_Line : Natural) return Natural is
   begin
      for I in 1 .. Map_Count loop
         if Line_Nums (I) = Basic_Line then
            return Line_Src (I);
         end if;
      end loop;
      return 0;
   end Source_Line_Of;

   function Strip_Ext (P : String) return String is
      Dot : constant Natural := Index (P, ".", Ada.Strings.Backward);
      Sl  : constant Natural := Index (P, "/", Ada.Strings.Backward);
   begin
      return (if Dot > Sl then P (P'First .. Dot - 1) else P);
   end Strip_Ext;

   function Hex6 (V : Natural) return String is
      H : constant String := "0123456789ABCDEF";
      R : String (1 .. 6);
      X : Natural := V;
   begin
      for I in reverse R'Range loop
         R (I) := H (X mod 16 + 1);
         X := X / 16;
      end loop;
      return R;
   end Hex6;

   procedure Build (Source : String; D : Dialect;
                    PRG : out Unbounded_String; Ok : out Boolean) is
      Out_Path : constant String := Strip_Ext (Source);
   begin
      Tokenize_File (Source, D);
      for I in 1 .. Err_Count loop
         if Report /= null then
            Report.all (Source & ":" & Trim (Errors (I).Line'Image,
                                             Ada.Strings.Left) &
                        ": error: " & To_String (Errors (I).Text));
         end if;
      end loop;
      PRG := To_Unbounded_String (Out_Path);
      Ok := Err_Count = 0;
      if not Ok then
         return;
      end if;
      declare
         use Ada.Streams.Stream_IO;
         F : File_Type;
      begin
         Create (F, Out_File, Out_Path);
         for I in 0 .. Prog_Len - 1 loop
            Byte'Write (Stream (F), Prog (I));
         end loop;
         Close (F);
         declare
            package TIO renames Ada.Text_IO;
            T : TIO.File_Type;
            Name : constant String :=
              Out_Path (Index (Out_Path, "/", Ada.Strings.Backward) + 1
                        .. Out_Path'Last);
         begin
            TIO.Create (T, TIO.Out_File, Out_Path & ".inf");
            TIO.Put_Line (T, "$." & To_Upper (Name) & " " &
                        Hex6 (16#FF0000# + Natural (Load)) & " " &
                        Hex6 (16#FF8023#) & " " & Hex6 (Prog_Len));
            TIO.Close (T);
         end;
         if Report /= null then
            Report.all ("wrote " & Out_Path & " (" &
                        Trim (Prog_Len'Image, Ada.Strings.Left) &
                        " bytes, PAGE = &" & Hex6 (Natural (Load)) (3 .. 6) &
                        ")");
         end if;
      exception
         when others =>
            Ok := False;
            if Report /= null then
               Report.all ("cannot write " & Out_Path);
            end if;
      end;
   end Build;

   ---------------------------------------------------------------------
   --  Listing
   ---------------------------------------------------------------------

   function Token_Text (T : Byte) return String is
   begin
      for E of Table loop
         if E.Token = T then
            return E.Text.all;
         end if;
      end loop;
      return "";
   end Token_Text;

   function List_Line (Content : Byte_Array) return String is
      R : Unbounded_String;
      I : Natural := Content'First;
      In_Quote : Boolean := False;
      Raw : Boolean := False;
   begin
      while I <= Content'Last loop
         declare
            B : constant Byte := Content (I);
         begin
            if Raw or else In_Quote or else B < 16#80# then
               if B = 34 then
                  In_Quote := not In_Quote;
               end if;
               Append (R, (if B >= 32 and then B < 127 then Character'Val (B)
                           else '?'));
               I := I + 1;
            elsif B = 16#8D# and then I + 3 <= Content'Last then
               declare
                  B1 : constant Byte := Content (I + 1) xor 16#54#;
                  Lo : constant Natural :=
                    Natural ((Content (I + 2) and 16#3F#) or
                             Shift_Left (B1 and 16#30#, 2));
                  Hi : constant Natural :=
                    Natural ((Content (I + 3) and 16#3F#) or
                             Shift_Left (B1 and 16#0C#, 4));
               begin
                  Append (R, Trim (Natural'Image (Hi * 256 + Lo),
                                   Ada.Strings.Left));
               end;
               I := I + 4;
            else
               Append (R, Token_Text (B));
               if B in 16#F4# | 16#DC# then        --  REM, DATA
                  Raw := True;
               end if;
               I := I + 1;
            end if;
         end;
      end loop;
      return To_String (R);
   end List_Line;

   function Detokenize (Read : not null Reader; Load : Word; D : Dialect)
                        return String is
      pragma Unreferenced (D);
      R : Unbounded_String;
      A : Word := Load + 1;          --  skip the initial &0D
      Lines : Natural := 0;
   begin
      if Read (Load) /= 16#0D# then
         return "";
      end if;
      loop
         declare
            Hi : constant Byte := Read (A);
         begin
            exit when Hi >= 16#80#;          --  &FF end marker
            declare
               Num : constant Natural :=
                 Natural (Hi) * 256 + Natural (Read (A + 1));
               Len : constant Natural := Natural (Read (A + 2));
               Content : Byte_Array (0 .. Integer'Max (Len - 5, -1));
            begin
               exit when Len < 4;
               for I in Content'Range loop
                  Content (I) := Read (A + 3 + Word (I));
               end loop;
               Append (R, Trim (Num'Image, Ada.Strings.Left) &
                       List_Line (Content) & ASCII.LF);
               A := A + Word (Len);
               Lines := Lines + 1;
               exit when Lines > 8000;
            end;
         end;
      end loop;
      return To_String (R);
   end Detokenize;

   Data_Buf : Byte_Array_Access := null;

   function Read_Data (A : Word) return Byte is
     (if Data_Buf /= null and then Natural (A) <= Data_Buf'Last
      then Data_Buf (Natural (A)) else 16#FF#);

   function Detokenize_Data (Data : Byte_Array) return String is
   begin
      Data_Buf := new Byte_Array (0 .. Data'Length - 1);
      Data_Buf.all := Data;
      return Detokenize (Read_Data'Access, 0, Basic_II);
   end Detokenize_Data;

   function List_PRG (Path : String; Ok : out Boolean) return String is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Ok := False;
      Open (F, In_File, Path);
      declare
         Size : constant Natural := Natural (Ada.Streams.Stream_IO.Size (F));
         subtype Buf_T is Byte_Array (0 .. Size - 1);
         Buf : Buf_T;
      begin
         Buf_T'Read (Stream (F), Buf);
         Close (F);
         Ok := Size > 0 and then Buf (0) = 16#0D#;
         return (if Ok then Detokenize_Data (Buf) else "");
      end;
   exception
      when others =>
         return "";
   end List_PRG;

   function Current_Line (Read : not null Reader; Load : Word)
     return Integer is
      Ptr : constant Word :=
        Word (Read (16#0B#)) + 256 * Word (Read (16#0C#));
      A : Word := Load + 1;
      Lines : Natural := 0;
   begin
      if Ptr < Load then
         return -1;
      end if;
      loop
         declare
            Hi : constant Byte := Read (A);
            Len : constant Natural := Natural (Read (A + 2));
         begin
            exit when Hi >= 16#80# or else Len < 4;
            if Ptr >= A and then Ptr < A + Word (Len) then
               return Natural (Hi) * 256 + Natural (Read (A + 1));
            end if;
            A := A + Word (Len);
            Lines := Lines + 1;
            exit when Lines > 8000;
         end;
      end loop;
      return -1;
   end Current_Line;

end Basic;
