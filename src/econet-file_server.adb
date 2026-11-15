-- ***************************************************************************
--                           AdaBeeb - File_Server
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

with Ada.Calendar;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces; use Interfaces;

package body Econet.File_Server is

   package Dirs renames Ada.Directories;

   Data_Port  : constant Byte := 16#97#;   --  where clients send data
   Block_Size : constant := 1280;

   --  Error numbers
   E_Not_Found : constant Byte := 16#D6#;
   E_Bad_Cmd   : constant Byte := 16#FE#;
   E_Channel   : constant Byte := 16#DE#;
   E_Is_Dir    : constant Byte := 16#B5#;
   E_Not_Dir   : constant Byte := 16#BE#;
   E_Bad_Name  : constant Byte := 16#CC#;
   E_Dir_Not_Empty : constant Byte := 16#B4#;
   E_Many_Open : constant Byte := 16#C0#;

   ---------------------------------------------------------------------
   --  Handles: directories (user root, current, library) and open files
   ---------------------------------------------------------------------

   type Handle_Rec is record
      Used, Is_Dir, Dirty : Boolean := False;
      Path : Unbounded_String;
      Content : Unbounded_String;          --  file data, one byte a char
      Ptr : Natural := 0;
   end record;
   Max_Handles : constant := 64;
   Handles : array (1 .. Max_Handles) of Handle_Rec;

   function Root_Path return String is (To_String (Root));

   ---------------------------------------------------------------------
   --  Host files
   ---------------------------------------------------------------------

   function Read_File (Path : String) return Unbounded_String is
      use Ada.Streams.Stream_IO;
      F : File_Type;
      R : Unbounded_String;
   begin
      Open (F, In_File, Path);
      declare
         S : String (1 .. Natural (Size (F)));
      begin
         String'Read (Stream (F), S);
         R := To_Unbounded_String (S);
      end;
      Close (F);
      return R;
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
         return Null_Unbounded_String;
   end Read_File;

   procedure Write_File (Path : String; Content : Unbounded_String) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Path);
      String'Write (Stream (F), To_String (Content));
      Close (F);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Write_File;

   function Is_Dir (Path : String) return Boolean is
     (Dirs.Exists (Path) and then Dirs."=" (Dirs.Kind (Path), Dirs.Directory));

   function Leaf (Path : String) return String is
     (if Path = Root_Path then "$" else Dirs.Simple_Name (Path));

   function Parent (Path : String) return String is
     (if Path = Root_Path then Path else Dirs.Containing_Directory (Path));

   --  The objects in a directory, sorted, without .inf files
   package Name_Lists is new Ada.Containers.Indefinite_Vectors
     (Positive, String);
   package Sorting is new Name_Lists.Generic_Sorting;

   function List (Dir : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      S : Dirs.Search_Type;
      E : Dirs.Directory_Entry_Type;
   begin
      Dirs.Start_Search (S, Dir, "");
      while Dirs.More_Entries (S) loop
         Dirs.Get_Next_Entry (S, E);
         declare
            N : constant String := Dirs.Simple_Name (E);
         begin
            if N'Length > 0 and then N (N'First) /= '.'
              and then not (N'Length > 4 and then To_Upper
                            (N (N'Last - 3 .. N'Last)) = ".INF")
            then
               Result.Append (N);
            end if;
         end;
      end loop;
      Dirs.End_Search (S);
      Sorting.Sort (Result);
      return Result;
   exception
      when others =>
         return Result;
   end List;

   --  Acorn wildcards: # one character, * any number
   function Matches (Pattern, Name : String) return Boolean is
      P : constant String := To_Upper (Pattern);
      N : constant String := To_Upper (Name);
      function M (I, J : Natural) return Boolean is
      begin
         if I > P'Last then
            return J > N'Last;
         elsif P (I) = '*' then
            for K in J .. N'Last + 1 loop
               if M (I + 1, K) then
                  return True;
               end if;
            end loop;
            return False;
         elsif J > N'Last then
            return False;
         elsif P (I) = '#' or else P (I) = N (J) then
            return M (I + 1, J + 1);
         end if;
         return False;
      end M;
   begin
      return M (P'First, N'First);
   end Matches;

   function Find (Dir, Pattern : String) return String is
   begin
      for N of List (Dir) loop
         if Matches (Pattern, N) then
            return N;
         end if;
      end loop;
      return "";
   end Find;

   --  Load and execution addresses from NAME.inf
   procedure Get_Meta (Path : String; Load, Exec : out Unsigned_32) is
      F : Ada.Text_IO.File_Type;
   begin
      Load := 16#FFFF1900#;
      Exec := 16#FFFF8023#;
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path & ".inf");
      declare
         Line : constant String := Ada.Text_IO.Get_Line (F);
         Fields : array (1 .. 3) of Unbounded_String;
         N : Natural := 0;
         I : Natural := Line'First;
      begin
         while I <= Line'Last and then N < 3 loop
            while I <= Line'Last and then Line (I) = ' ' loop
               I := I + 1;
            end loop;
            exit when I > Line'Last;
            N := N + 1;
            while I <= Line'Last and then Line (I) /= ' ' loop
               Append (Fields (N), Line (I));
               I := I + 1;
            end loop;
         end loop;
         if N >= 3 then
            Load := Unsigned_32'Value ("16#" & To_String (Fields (2)) & "#");
            Exec := Unsigned_32'Value ("16#" & To_String (Fields (3)) & "#");
         end if;
      end;
      Ada.Text_IO.Close (F);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (F) then
            Ada.Text_IO.Close (F);
         end if;
   end Get_Meta;

   function Hex8 (V : Unsigned_32) return String is
      Digits_Hex : constant String := "0123456789ABCDEF";
      R : String (1 .. 8);
   begin
      for I in R'Range loop
         R (I) := Digits_Hex
           (Natural (Shift_Right (V, 4 * (8 - I)) and 15) + 1);
      end loop;
      return R;
   end Hex8;

   procedure Set_Meta (Path : String; Load, Exec : Unsigned_32) is
      F : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Path & ".inf");
      Ada.Text_IO.Put_Line (F, Leaf (Path) & " " & Hex8 (Load) & " "
                            & Hex8 (Exec));
      Ada.Text_IO.Close (F);
   exception
      when others =>
         null;
   end Set_Meta;

   function File_Size (Path : String) return Natural is
     (if Dirs.Exists (Path) and then not Is_Dir (Path)
      then Natural (Dirs.Size (Path)) else 0);

   --  Acorn date: day, then (year - 1981) * 16 + month
   function Date_Of (Path : String) return Byte_Array is
      use Ada.Calendar;
      T : Time;
      Y : Year_Number;
      Mo : Month_Number;
      D : Day_Number;
      S : Day_Duration;
   begin
      T := (if Dirs.Exists (Path) then Dirs.Modification_Time (Path)
            else Clock);
      Split (T, Y, Mo, D, S);
      return (Byte (D), Byte (((Y - 1981) mod 16) * 16 + Mo));
   exception
      when others =>
         return (1, 1);
   end Date_Of;

   function Year_Of (Path : String) return Natural is
   begin
      return Ada.Calendar.Year (Dirs.Modification_Time (Path));
   exception
      when others =>
         return Ada.Calendar.Year (Ada.Calendar.Clock);
   end Year_Of;

   function Access_Byte (Path : String) return Byte is
     (if Is_Dir (Path) then 16#20# else 16#0D#);   --  D / WR/r

   function Access_Text (Path : String) return String is
     (if Is_Dir (Path) then "D/" else "WR/r");

   function LE (V : Unsigned_32; N : Positive) return Byte_Array is
      R : Byte_Array (0 .. N - 1);
   begin
      for I in R'Range loop
         R (I) := Byte (Shift_Right (V, 8 * I) and 16#FF#);
      end loop;
      return R;
   end LE;

   function Padded (S : String; N : Natural) return Byte_Array is
      R : Byte_Array (0 .. N - 1) := (others => Character'Pos (' '));
   begin
      for I in 0 .. Natural'Min (N, S'Length) - 1 loop
         R (I) := Character'Pos (S (S'First + I));
      end loop;
      return R;
   end Padded;

   function Text (S : String) return Byte_Array is
      R : Byte_Array (0 .. S'Length - 1);
   begin
      for I in R'Range loop
         R (I) := Character'Pos (S (S'First + I));
      end loop;
      return R;
   end Text;

   ---------------------------------------------------------------------
   --  Replies
   ---------------------------------------------------------------------

   Req : Message;                       --  the request being handled

   procedure Send (Port : Byte; Data : Byte_Array) is
      M : Message;
   begin
      M.Src_Stn := Server_Station;
      M.Src_Net := 0;
      M.Dst_Stn := Req.Src_Stn;
      M.Dst_Net := Req.Src_Net;
      M.Ctrl := Req.Ctrl;
      M.Port := Port;
      M.Len := Data'Length;
      M.Data (0 .. Data'Length - 1) := Data;
      Queue_For_Station (M);
   end Send;

   Reply_Port : Byte := 0;

   procedure Reply (Data : Byte_Array) is
   begin
      Send (Reply_Port, Data);
   end Reply;

   procedure OK is
   begin
      Reply ((0, 0));
   end OK;

   procedure Error (Code : Byte; Msg : String) is
   begin
      Reply (Byte_Array'(0, Code) & Text (Msg) & Byte_Array'(0 => 13));
   end Error;

   ---------------------------------------------------------------------
   --  Request fields
   ---------------------------------------------------------------------

   function D (I : Natural) return Byte is
     (if I < Req.Len then Req.Data (I) else 0);

   function Num (I, N : Natural) return Unsigned_32 is
      V : Unsigned_32 := 0;
   begin
      for K in reverse 0 .. N - 1 loop
         V := Shift_Left (V, 8) or Unsigned_32 (D (I + K));
      end loop;
      return V;
   end Num;

   function Str (From : Natural) return String is
      R : Unbounded_String;
      I : Natural := From;
   begin
      while I < Req.Len and then Req.Data (I) /= 13 loop
         Append (R, Character'Val (Req.Data (I)));
         I := I + 1;
      end loop;
      return Ada.Strings.Fixed.Trim (To_String (R), Ada.Strings.Both);
   end Str;

   function Dir_Handle_Path (H : Byte) return String is
     (if H in 1 .. Max_Handles and then Handles (Natural (H)).Used
         and then Handles (Natural (H)).Is_Dir
      then To_String (Handles (Natural (H)).Path) else Root_Path);

   CSD_H, LIB_H : Byte := 0;

   function Library_Path return String is
      L : constant String := Find (Root_Path, "LIBRARY");
   begin
      return (if L /= "" then Dirs.Compose (Root_Path, L) else Root_Path);
   end Library_Path;

   --  Acorn path to host path.  Found is False when the last name does
   --  not exist (the result is then where it would be created); Valid
   --  is False when the directories leading to it do not exist.
   procedure Resolve (Spec : String; Path : out Unbounded_String;
                      Found, Valid : out Boolean) is
      S : constant String := Ada.Strings.Fixed.Trim (Spec, Ada.Strings.Both);
      Cur : Unbounded_String := To_Unbounded_String
        (Dir_Handle_Path (CSD_H));
      I : Natural := S'First;
      First : Boolean := True;
   begin
      Found := True;
      Valid := True;
      if S'Length > 0 and then S (S'First) = ':' then     --  disc name
         while I <= S'Last and then S (I) /= '.' loop
            I := I + 1;
         end loop;
         I := I + 1;
         Cur := Root;
      end if;
      while I <= S'Last loop
         declare
            J : Natural := I;
         begin
            while J <= S'Last and then S (J) /= '.' loop
               J := J + 1;
            end loop;
            declare
               C : constant String := S (I .. J - 1);
               Last : constant Boolean := J > S'Last;
            begin
               if First and then C = "$" then
                  Cur := Root;
               elsif First and then C = "&" then
                  Cur := Root;
               elsif First and then C = "@" then
                  null;
               elsif First and then C = "%" then
                  Cur := To_Unbounded_String (Dir_Handle_Path (LIB_H));
               elsif C = "^" then
                  Cur := To_Unbounded_String (Parent (To_String (Cur)));
               elsif C = "" then
                  null;
               else
                  declare
                     N : constant String := Find (To_String (Cur), C);
                  begin
                     if N = "" then
                        if Last and then (for all Ch of C =>
                                            Ch not in '*' | '#')
                        then
                           Path := To_Unbounded_String
                             (Dirs.Compose (To_String (Cur), C));
                           Found := False;
                        else
                           Found := False;
                           Valid := False;
                        end if;
                        return;
                     end if;
                     Cur := To_Unbounded_String
                       (Dirs.Compose (To_String (Cur), N));
                     if not Last and then not Is_Dir (To_String (Cur)) then
                        Found := False;
                        Valid := False;
                        return;
                     end if;
                  end;
               end if;
            end;
            First := False;
            I := J + 1;
         end;
      end loop;
      Path := Cur;
   exception
      when others =>
         Found := False;
         Valid := False;
   end Resolve;

   function Existing (Spec : String; P : out Unbounded_String)
                      return Boolean is
      Found, Valid : Boolean;
   begin
      Resolve (Spec, P, Found, Valid);
      if not Found then
         Error (E_Not_Found, "Not found");
      end if;
      return Found;
   end Existing;

   function New_Handle (Path : String; Dir : Boolean) return Byte is
   begin
      for H in Handles'Range loop
         if not Handles (H).Used then
            Handles (H) := (Used => True, Is_Dir => Dir, Dirty => False,
                            Path => To_Unbounded_String (Path),
                            Content => (if Dir then Null_Unbounded_String
                                        else Read_File (Path)),
                            Ptr => 0);
            return Byte (H);
         end if;
      end loop;
      return 0;
   end New_Handle;

   procedure Close_Handle (H : Natural) is
   begin
      if H in Handles'Range and then Handles (H).Used then
         if Handles (H).Dirty then
            Write_File (To_String (Handles (H).Path), Handles (H).Content);
         end if;
         Handles (H).Used := False;
      end if;
   end Close_Handle;

   function File_Handle (H : Byte) return Natural is
     (if H in 1 .. Max_Handles and then Handles (Natural (H)).Used
         and then not Handles (Natural (H)).Is_Dir
      then Natural (H) else 0);

   ---------------------------------------------------------------------
   --  Data transfers
   ---------------------------------------------------------------------

   --  Data from the client (SAVE, PUTBYTES): collected as it arrives
   type Recv_Kind is (None, Saving, Putting);
   Recv : Recv_Kind := None;
   Recv_Stn, Recv_Ack_Port, Recv_Reply_Port, Recv_Ctrl : Byte := 0;
   Recv_Left : Natural := 0;
   Recv_Data : Unbounded_String;
   Recv_Path : Unbounded_String;
   Recv_Load, Recv_Exec : Unsigned_32 := 0;
   Recv_Handle, Recv_Total : Natural := 0;

   --  Send Data to the client's port in blocks
   procedure Send_Data (Port : Byte; Data : String) is
      I : Natural := Data'First;
   begin
      while I <= Data'Last loop
         declare
            Last : constant Natural := Natural'Min (I + Block_Size - 1,
                                                    Data'Last);
         begin
            Send (Port, Text (Data (I .. Last)));
            I := Last + 1;
         end;
      end loop;
   end Send_Data;

   procedure Finish_Receive is
   begin
      Reply_Port := Recv_Reply_Port;
      Req.Ctrl := Recv_Ctrl;
      case Recv is
         when Saving =>
            declare
               P : constant String := To_String (Recv_Path);
            begin
               Write_File (P, Recv_Data);
               Set_Meta (P, Recv_Load, Recv_Exec);
               Reply (Byte_Array'(0, 0, Access_Byte (P)) & Date_Of (P));
            end;
         when Putting =>
            declare
               H : Handle_Rec renames Handles (Recv_Handle);
               Ptr : constant Natural := H.Ptr;
               New_Len : constant Natural :=
                 Natural'Max (Length (H.Content), Ptr + Length (Recv_Data));
            begin
               if Length (H.Content) < New_Len then
                  Append (H.Content, (New_Len - Length (H.Content)) * ASCII.NUL);
               end if;
               Replace_Slice (H.Content, Ptr + 1, Ptr + Length (Recv_Data),
                              To_String (Recv_Data));
               H.Ptr := Ptr + Length (Recv_Data);
               H.Dirty := True;
               Reply (Byte_Array'(0, 0, 0) & LE (Unsigned_32 (Recv_Total), 3));
            end;
         when None =>
            null;
      end case;
      Recv := None;
   end Finish_Receive;

   procedure Start_Receive (Kind : Recv_Kind; Size : Natural) is
   begin
      Recv := Kind;
      Recv_Stn := Req.Src_Stn;
      Recv_Ack_Port := D (2);
      Recv_Reply_Port := Reply_Port;
      Recv_Ctrl := Req.Ctrl;
      Recv_Left := Size;
      Recv_Total := Size;
      Recv_Data := Null_Unbounded_String;
      Reply (Byte_Array'(0, 0, Data_Port) & LE (Block_Size, 2));
      if Size = 0 then
         Finish_Receive;
      end if;
   end Start_Receive;

   procedure Data_Arrived (M : Message) is
   begin
      if Recv = None or else M.Src_Stn /= Recv_Stn then
         return;
      end if;
      for I in 0 .. M.Len - 1 loop
         Append (Recv_Data, Character'Val (M.Data (I)));
      end loop;
      Recv_Left := (if M.Len >= Recv_Left then 0 else Recv_Left - M.Len);
      Req := M;
      if Recv_Left > 0 then
         Req.Ctrl := Recv_Ctrl;
         Send (Recv_Ack_Port, (0 => 0));      --  ready for the next block
      else
         Finish_Receive;
      end if;
   end Data_Arrived;

   ---------------------------------------------------------------------
   --  Functions
   ---------------------------------------------------------------------

   procedure Do_Load (As_Command : Boolean) is
      Name : constant String := Str (5);
      Spec : constant String :=
        (if As_Command then Name (Name'First ..
           Ada.Strings.Fixed.Index (Name & " ", " ") - 1) else Name);
      P : Unbounded_String;
      Found, Valid : Boolean;
   begin
      Resolve (Spec, P, Found, Valid);
      if not Found and then As_Command then
         declare
            Saved : constant Byte := CSD_H;
         begin
            CSD_H := LIB_H;                    --  then the library
            Resolve (Spec, P, Found, Valid);
            CSD_H := Saved;
         end;
      end if;
      if not Found then
         if As_Command then
            Error (E_Bad_Cmd, "Bad command");
         else
            Error (E_Not_Found, "Not found");
         end if;
         return;
      end if;
      declare
         Path : constant String := To_String (P);
         Load, Exec : Unsigned_32;
         Content : Unbounded_String;
      begin
         if Is_Dir (Path) then
            Error (E_Is_Dir, "Is a directory");
            return;
         end if;
         Get_Meta (Path, Load, Exec);
         Content := Read_File (Path);
         Reply (Byte_Array'(0, 0) & LE (Load, 4) & LE (Exec, 4)
                & LE (Unsigned_32 (Length (Content)), 3)
                & Access_Byte (Path) & Date_Of (Path));
         Send_Data (D (2), To_String (Content));
         OK;
      end;
   end Do_Load;

   procedure Do_Save is
      P : Unbounded_String;
      Found, Valid : Boolean;
   begin
      Resolve (Str (16), P, Found, Valid);
      if not Valid then
         Error (E_Not_Found, "Not found");
         return;
      elsif Found and then Is_Dir (To_String (P)) then
         Error (E_Is_Dir, "Is a directory");
         return;
      end if;
      Recv_Path := P;
      Recv_Load := Num (5, 4);
      Recv_Exec := Num (9, 4);
      Start_Receive (Saving, Natural (Num (13, 3)));
   end Do_Save;

   --  One line of *INFO / *EX
   function Info_Line (Path : String) return String is
      Load, Exec : Unsigned_32;
      Dt : constant Byte_Array := Date_Of (Path);
      function Two (N : Natural) return String is
        (Character'Val (48 + N / 10 mod 10) & Character'Val (48 + N mod 10));
      Name : String (1 .. 10) := (others => ' ');
      L : constant String := Leaf (Path);
   begin
      Get_Meta (Path, Load, Exec);
      Name (1 .. Natural'Min (10, L'Length)) :=
        L (L'First .. L'First + Natural'Min (10, L'Length) - 1);
      if Is_Dir (Path) then
         return Name & " Dir        " & Access_Text (Path);
      end if;
      return Name & " " & Hex8 (Load) & " " & Hex8 (Exec) & " "
        & Hex8 (Unsigned_32 (File_Size (Path))) (3 .. 8) & " "
        & Access_Text (Path) & "  " & Two (Natural (Dt (0))) & ":"
        & Two (Natural (Dt (1) mod 16)) & ":" & Two (Year_Of (Path) mod 100);
   end Info_Line;

   procedure Do_Examine is
      Arg : constant Byte := D (5);
      Start : constant Natural := Natural (D (6));
      Count : constant Natural := Natural (D (7));
      P : Unbounded_String;
      Out_Data : Byte_Array (0 .. Max_Data - 1);
      N : Natural := 4;
      Got : Natural := 0;
   begin
      if not Existing (Str (8), P) then
         return;
      end if;
      declare
         Dir : constant String := To_String (P);
         Names : constant Name_Lists.Vector := List (Dir);
      begin
         for I in Start + 1 .. Names.Last_Index loop
            exit when Got >= Count;
            declare
               E : constant String := Dirs.Compose (Dir, Names (I));
               Item : Unbounded_String;
               Load, Exec : Unsigned_32;
               B : Byte_Array (0 .. 79);
               BL : Natural := 0;
            begin
               case Arg is
                  when 0 =>                            --  machine readable
                     Get_Meta (E, Load, Exec);
                     declare
                        R : constant Byte_Array :=
                          Padded (Names (I), 10) & LE (Load, 4) & LE (Exec, 4)
                          & Access_Byte (E) & Date_Of (E) & LE (0, 3)
                          & LE (Unsigned_32 (File_Size (E)), 3);
                     begin
                        B (0 .. R'Length - 1) := R;
                        BL := R'Length;
                     end;
                  when 1 =>                            --  long text
                     Item := To_Unbounded_String (Info_Line (E));
                     B (0 .. Length (Item)) :=
                       Text (To_String (Item)) & Byte_Array'(0 => 0);
                     BL := Length (Item) + 1;
                  when 2 =>                            --  name only
                     B (0 .. 10) := Byte_Array'(0 => 10) & Padded (Names (I), 10);
                     BL := 11;
                  when others =>                       --  name and access
                     declare
                        R : constant Byte_Array :=
                          Padded (Names (I), 10) & Padded ("", 1)
                          & Padded (Access_Text (E), 7) & Byte_Array'(0 => 0);
                     begin
                        B (0 .. R'Length - 1) := R;
                        BL := R'Length;
                     end;
               end case;
               exit when N + BL + 1 > Block_Size;
               Out_Data (N .. N + BL - 1) := B (0 .. BL - 1);
               N := N + BL;
               Got := Got + 1;
            end;
         end loop;
      end;
      Out_Data (0 .. 3) := (0, 0, Byte (Got), 0);
      if Arg in 1 | 3 then
         Out_Data (N) := 16#80#;
         N := N + 1;
      end if;
      Reply (Out_Data (0 .. N - 1));
   end Do_Examine;

   procedure Do_Info is
      Arg : constant Byte := D (5);
      Spec : constant String := Str (6);
      P : Unbounded_String;
      Found, Valid : Boolean;
   begin
      Resolve ((if Spec = "" then "@" else Spec), P, Found, Valid);
      declare
         Path : constant String := To_String (P);
         Kind : constant Byte :=
           (if not Found then 0 elsif Is_Dir (Path) then 2 else 1);
         Load, Exec : Unsigned_32 := 0;
      begin
         if Found then
            Get_Meta (Path, Load, Exec);
         end if;
         case Arg is
            when 1 => Reply (Byte_Array'(0, 0, Kind) & Date_Of (Path));
            when 2 => Reply (Byte_Array'(0, 0, Kind) & LE (Load, 4)
                             & LE (Exec, 4));
            when 3 => Reply (Byte_Array'(0, 0, Kind)
                             & LE (Unsigned_32 (File_Size (Path)), 3));
            when 4 => Reply (Byte_Array'(0, 0, Kind, Access_Byte (Path)));
            when 5 => Reply (Byte_Array'(0, 0, Kind) & LE (Load, 4)
                             & LE (Exec, 4)
                             & LE (Unsigned_32 (File_Size (Path)), 3)
                             & Access_Byte (Path) & Date_Of (Path));
            when 6 =>
               if not Found or else not Is_Dir (Path) then
                  Error (E_Not_Dir, "Not a directory");
               else
                  Reply (Byte_Array'(0, 0, 0, 0, 10) & Padded (Leaf (Path), 10)
                         & Byte_Array'(0, 0));
               end if;
            when others => Error (16#8E#, "Bad INFO argument");
         end case;
      end;
   end Do_Info;

   procedure Do_Open is
      Must_Exist : constant Boolean := D (5) /= 0;
      Read_Only : constant Boolean := D (6) /= 0;
      P : Unbounded_String;
      Found, Valid : Boolean;
      H : Byte;
   begin
      Resolve (Str (7), P, Found, Valid);
      if not Found and then (Must_Exist or else not Valid) then
         Error (E_Not_Found, "Not found");
         return;
      end if;
      declare
         Path : constant String := To_String (P);
      begin
         if not Found or else (not Must_Exist and then not Read_Only
                               and then not Is_Dir (Path))
         then
            Write_File (Path, Null_Unbounded_String);   --  OPENOUT: new
         end if;
         H := New_Handle (Path, Is_Dir (Path));
         if H = 0 then
            Error (E_Many_Open, "Too many open files");
         else
            Reply ((0, 0, H));
         end if;
      end;
   end Do_Open;

   procedure Do_Get_Bytes is
      H : constant Natural := File_Handle (D (5));
      N : constant Natural := Natural (Num (7, 3));
   begin
      if H = 0 then
         Error (E_Channel, "Channel");
         return;
      end if;
      declare
         F : Handle_Rec renames Handles (H);
         Ptr : constant Natural :=
           (if D (6) = 0 then Natural (Num (10, 3)) else F.Ptr);
         Avail : constant Natural :=
           (if Ptr >= Length (F.Content) then 0
            else Natural'Min (N, Length (F.Content) - Ptr));
         Data : String (1 .. N) := (others => ASCII.NUL);
      begin
         if Avail > 0 then
            Data (1 .. Avail) := Slice (F.Content, Ptr + 1, Ptr + Avail);
         end if;
         F.Ptr := Ptr + Avail;
         OK;
         Send_Data (D (2), Data);
         Reply (Byte_Array'(0, 0,
                (if Avail < N or else F.Ptr >= Length (F.Content)
                 then 16#80# else 0))
                & LE (Unsigned_32 (Avail), 3));
      end;
   end Do_Get_Bytes;

   procedure Do_Put_Bytes is
      H : constant Natural := File_Handle (D (5));
   begin
      if H = 0 then
         Error (E_Channel, "Channel");
         return;
      end if;
      if D (6) = 0 then
         Handles (H).Ptr := Natural (Num (10, 3));
      end if;
      Recv_Handle := H;
      Start_Receive (Putting, Natural (Num (7, 3)));
   end Do_Put_Bytes;

   procedure Do_Delete is
      P : Unbounded_String;
   begin
      if not Existing (Str (5), P) then
         return;
      end if;
      declare
         Path : constant String := To_String (P);
         Load, Exec : Unsigned_32;
         Size : constant Natural := File_Size (Path);
      begin
         Get_Meta (Path, Load, Exec);
         if Is_Dir (Path) then
            if not List (Path).Is_Empty then
               Error (E_Dir_Not_Empty, "Dir. not empty");
               return;
            end if;
            Dirs.Delete_Directory (Path);
         else
            Dirs.Delete_File (Path);
            if Dirs.Exists (Path & ".inf") then
               Dirs.Delete_File (Path & ".inf");
            end if;
         end if;
         Reply (Byte_Array'(0, 0) & LE (Load, 4) & LE (Exec, 4)
                & LE (Unsigned_32 (Size), 3));
      end;
   end Do_Delete;

   --  The command line (function 0)
   procedure Do_Command is
      Line : constant String := Str (5);
      L : Natural := Line'First;
      function Arg return String is
         S : Natural;
      begin
         while L <= Line'Last and then Line (L) = ' ' loop
            L := L + 1;
         end loop;
         S := L;
         while L <= Line'Last and then Line (L) /= ' ' loop
            L := L + 1;
         end loop;
         return Line (S .. L - 1);
      end Arg;
      --  Command names with their minimum abbreviation
      function Is_Cmd (Name : String; Min : Positive) return Boolean is
         U : constant String := To_Upper (Line);
         I : Natural := U'First;
      begin
         for K in Name'Range loop
            if I > U'Last then
               return False;
            elsif U (I) = '.' and then K - Name'First >= Min then
               L := I + 1;
               return True;
            elsif U (I) /= Name (K) then
               return False;
            end if;
            I := I + 1;
         end loop;
         if I > U'Last or else U (I) in ' ' | '.' | '$' | '&' | '^' | '@'
           | '%' | ':' | '0' .. '9'
         then
            L := I;
            return True;
         end if;
         return False;
      end Is_Cmd;
      P : Unbounded_String;
   begin
      if Line = "" then
         OK;
      elsif Is_Cmd ("I AM", 2) or else Is_Cmd ("IAM", 3) then
         declare
            Who : constant String := Arg;
            pragma Unreferenced (Who);
            Lib : constant String := Library_Path;
            U, C, Li : Byte;
         begin
            U := New_Handle (Root_Path, True);
            C := New_Handle (Root_Path, True);
            Li := New_Handle (Lib, True);
            Reply ((0 => 5, 1 => 0, 2 => U, 3 => C, 4 => Li, 5 => 0));
         end;
      elsif Is_Cmd ("DIR", 3) or else Is_Cmd ("LIB", 3) then
         declare
            Is_Lib : constant Boolean :=
              To_Upper (Line (Line'First .. Line'First + 2)) = "LIB";
            A : constant String := Arg;
            Found, Valid : Boolean;
         begin
            Resolve ((if A = "" then "&" else A), P, Found, Valid);
            if not Found then
               Error (E_Not_Found, "Not found");
            elsif not Is_Dir (To_String (P)) then
               Error (E_Not_Dir, "Not a directory");
            else
               declare
                  H : constant Byte := New_Handle (To_String (P), True);
               begin
                  Close_Handle (Natural (if Is_Lib then LIB_H else CSD_H));
                  Reply ((0 => (if Is_Lib then 9 else 7), 1 => 0, 2 => H));
               end;
            end if;
         end;
      elsif Is_Cmd ("CAT", 1) then
         Reply (Byte_Array'(3, 0) & Text (Arg) & Byte_Array'(0 => 13));
      elsif Is_Cmd ("LOAD", 1) then
         declare
            Name : constant String := Arg;
            Addr : constant String := Arg;
            A : Unsigned_32 := 0;
         begin
            if Addr /= "" then
               A := Unsigned_32'Value ("16#" & Addr & "#");
            end if;
            Reply (Byte_Array'(2, 0) & LE (A, 4)
                   & Byte_Array'(0 => (if Addr = "" then 0 else 16#FF#))
                   & Text (Name) & Byte_Array'(0 => 13));
         end;
      elsif Is_Cmd ("SAVE", 1) then
         declare
            Name : constant String := Arg;
            S : constant Unsigned_32 := Unsigned_32'Value ("16#" & Arg & "#");
            E2 : constant String := Arg;
            E : constant Unsigned_32 :=
              (if E2'Length > 0 and then E2 (E2'First) = '+'
               then S + Unsigned_32'Value
                 ("16#" & E2 (E2'First + 1 .. E2'Last) & "#")
               else Unsigned_32'Value ("16#" & E2 & "#"));
            X : constant String := Arg;
            Ex : constant Unsigned_32 :=
              (if X = "" then S else Unsigned_32'Value ("16#" & X & "#"));
         begin
            Reply (Byte_Array'(1, 0) & LE (S, 4) & LE (Ex, 4)
                   & LE (E - S, 3) & Text (Name) & Byte_Array'(0 => 13));
         end;
      elsif Is_Cmd ("INFO", 1) or else Is_Cmd ("EX", 2) then
         if Existing (Arg, P) then
            Reply (Byte_Array'(4, 0) & Text (Info_Line (To_String (P)))
                   & Byte_Array'(13, 16#80#));       --  NFS prints to &80
         end if;
      elsif Is_Cmd ("DELETE", 3) then
         declare
            A : constant String := Arg;
         begin
            Req.Len := 5;
            for Ch of A loop
               Req.Data (Req.Len) := Character'Pos (Ch);
               Req.Len := Req.Len + 1;
            end loop;
            Req.Data (Req.Len) := 13;
            Req.Len := Req.Len + 1;
            Do_Delete;
         end;
      elsif Is_Cmd ("CDIR", 2) then
         declare
            Found, Valid : Boolean;
         begin
            Resolve (Arg, P, Found, Valid);
            if Found then
               Error (16#C4#, "Already exists");
            elsif not Valid then
               Error (E_Bad_Name, "Bad name");
            else
               Dirs.Create_Directory (To_String (P));
               OK;
            end if;
         end;
      elsif Is_Cmd ("RENAME", 1) then
         declare
            From : constant String := Arg;
            To : constant String := Arg;
            Q : Unbounded_String;
            Found, Valid : Boolean;
         begin
            if Existing (From, P) then
               Resolve (To, Q, Found, Valid);
               if Found or else not Valid then
                  Error (E_Bad_Name, "Bad rename");
               else
                  Dirs.Rename (To_String (P), To_String (Q));
                  if Dirs.Exists (To_String (P) & ".inf") then
                     Dirs.Rename (To_String (P) & ".inf",
                                  To_String (Q) & ".inf");
                  end if;
                  OK;
               end if;
            end if;
         end;
      elsif Is_Cmd ("ACCESS", 2) or else Is_Cmd ("PASS", 1)
        or else Is_Cmd ("BYE", 1) or else Is_Cmd ("SDISC", 3)
      then
         OK;
      else
         Reply (Byte_Array'(8, 0) & Text (Line) & Byte_Array'(0 => 13));
      end if;
   exception
      when Constraint_Error =>
         Error (16#FF#, "Syntax");
   end Do_Command;

   procedure Request is
      Func : constant Byte := D (1);
   begin
      Reply_Port := D (0);
      if Func not in 8 | 9 then
         CSD_H := D (3);
         LIB_H := D (4);
      end if;
      case Func is
         when 0 => Do_Command;
         when 1 => Do_Save;
         when 2 => Do_Load (False);
         when 3 => Do_Examine;
         when 4 =>
            declare
               P : Unbounded_String;
               Found, Valid : Boolean;
               S : constant String := Str (5);
            begin
               Resolve ((if S = "" then "@" else S), P, Found, Valid);
               Reply (Byte_Array'(0, 0) & Padded (Leaf (To_String (P)), 10)
                      & Padded (" O   ", 5) & Padded ("AdaBeeb", 12)
                      & Byte_Array'(13, 16#80#));
            end;
         when 5 => Do_Load (True);
         when 6 => Do_Open;
         when 7 =>
            if D (5) = 0 then
               for H in Handles'Range loop
                  if Handles (H).Used and then not Handles (H).Is_Dir then
                     Close_Handle (H);
                  end if;
               end loop;
            else
               Close_Handle (Natural (D (5)));
            end if;
            OK;
         when 8 =>
            declare
               H : constant Natural := File_Handle (D (2));
            begin
               if H = 0 then
                  Error (E_Channel, "Channel");
               elsif Handles (H).Ptr >= Length (Handles (H).Content) then
                  Reply ((0, 0, 16#FE#, 16#C0#));          --  end of file
               else
                  Handles (H).Ptr := Handles (H).Ptr + 1;
                  Reply ((0, 0,
                          Character'Pos (Element (Handles (H).Content,
                                                  Handles (H).Ptr)),
                          (if Handles (H).Ptr = Length (Handles (H).Content)
                           then 16#80# else 0)));
               end if;
            end;
         when 9 =>
            declare
               H : constant Natural := File_Handle (D (2));
            begin
               if H = 0 then
                  Error (E_Channel, "Channel");
               else
                  declare
                     F : Handle_Rec renames Handles (H);
                  begin
                     if F.Ptr >= Length (F.Content) then
                        Append (F.Content,
                                (F.Ptr - Length (F.Content) + 1) * ASCII.NUL);
                     end if;
                     Replace_Element (F.Content, F.Ptr + 1,
                                      Character'Val (D (3)));
                     F.Ptr := F.Ptr + 1;
                     F.Dirty := True;
                     OK;
                  end;
               end if;
            end;
         when 10 => Do_Get_Bytes;
         when 11 => Do_Put_Bytes;
         when 12 | 13 | 17 =>
            declare
               H : constant Natural := File_Handle (D (5));
            begin
               if H = 0 then
                  Error (E_Channel, "Channel");
               elsif Func = 17 then
                  Reply ((0, 0, (if Handles (H).Ptr >=
                          Length (Handles (H).Content) then 16#FF# else 0)));
               elsif Func = 12 then
                  Reply (Byte_Array'(0, 0) & LE (Unsigned_32
                         (if D (6) = 0 then Handles (H).Ptr
                          else Length (Handles (H).Content)), 3));
               else
                  declare
                     F : Handle_Rec renames Handles (H);
                     V : constant Natural := Natural (Num (7, 3));
                  begin
                     if D (6) = 0 then
                        F.Ptr := V;
                     elsif V < Length (F.Content) then
                        Delete (F.Content, V + 1, Length (F.Content));
                        F.Dirty := True;
                     else
                        Append (F.Content, (V - Length (F.Content)) * ASCII.NUL);
                        F.Dirty := True;
                     end if;
                     OK;
                  end;
               end if;
            end;
         when 14 =>
            Reply (Byte_Array'(0, 0, 1, 0) & Padded ("AdaBeeb", 16));
         when 15 =>
            Reply ((0, 0, 0));
         when 16 =>
            declare
               use Ada.Calendar;
               T : constant Time := Clock;
               Y : Year_Number;
               Mo : Month_Number;
               Dy : Day_Number;
               S : Day_Duration;
               Secs : Natural;
            begin
               Split (T, Y, Mo, Dy, S);
               Secs := Natural (S - 0.5);
               Reply ((0, 0, Byte (Dy), Byte (((Y - 1981) mod 16) * 16 + Mo),
                       Byte (Secs / 3600), Byte (Secs / 60 mod 60),
                       Byte (Secs mod 60)));
            end;
         when 18 => Do_Info;
         when 19 =>
            declare
               Arg : constant Byte := D (5);
               P : Unbounded_String;
               Load, Exec : Unsigned_32;
            begin
               if Existing (Str (if Arg = 1 then 15 elsif Arg = 4 then 7
                                 else 10), P)
               then
                  Get_Meta (To_String (P), Load, Exec);
                  case Arg is
                     when 1 => Load := Num (6, 4); Exec := Num (10, 4);
                     when 2 => Load := Num (6, 4);
                     when 3 => Exec := Num (6, 4);
                     when others => null;
                  end case;
                  Set_Meta (To_String (P), Load, Exec);
                  OK;
               end if;
            end;
         when 20 => Do_Delete;
         when 21 =>
            Reply (Byte_Array'(0, 0, 16) & Padded ("AdaBeeb", 16)
                   & Padded (Leaf (Dir_Handle_Path (CSD_H)), 10)
                   & Padded (Leaf (Dir_Handle_Path (LIB_H)), 10));
         when 22 | 23 => OK;
         when 24 => Reply ((0, 0, 0, Req.Src_Stn, 0));
         when 25 => Reply (Byte_Array'(0, 0) & Text ("AdaBeeb FS 1.00")
                           & Byte_Array'(0 => 13));
         when 26 => Reply (Byte_Array'(0, 0) & LE (16#7FFF#, 3)
                           & LE (16#7FFF#, 3));
         when others => Error (E_Bad_Cmd, "Bad command");
      end case;
   exception
      when others =>
         Error (16#FF#, "Server error");
   end Request;

   procedure Receive (M : Message) is
   begin
      if not Dirs.Exists (Root_Path) then
         Dirs.Create_Path (Root_Path);
      end if;
      if M.Port = Data_Port then
         Data_Arrived (M);
      elsif M.Port = 16#99# and then M.Len >= 2 then
         Req := M;
         Request;
      end if;
   exception
      when others =>
         null;
   end Receive;

   procedure Reset is
   begin
      for H in Handles'Range loop
         Close_Handle (H);
      end loop;
      Recv := None;
   end Reset;

end Econet.File_Server;
