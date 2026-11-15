-- ***************************************************************************
--                                AdaBeeb - Z80
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

with Interfaces; use Interfaces;

package body Z80 is

   FS : constant Byte := 16#80#;
   FZ : constant Byte := 16#40#;
   FY : constant Byte := 16#20#;
   FH : constant Byte := 16#10#;
   FX : constant Byte := 16#08#;
   FP : constant Byte := 16#04#;
   FN : constant Byte := 16#02#;
   FC : constant Byte := 16#01#;
   FXY : constant Byte := FX or FY;

   type Flag_Table is array (Byte) of Byte;

   function Make_SZ return Flag_Table is
      T : Flag_Table;
   begin
      for V in Byte loop
         T (V) := (V and (FS or FXY)) or (if V = 0 then FZ else 0);
      end loop;
      return T;
   end Make_SZ;

   function Make_SZP return Flag_Table is
      T : Flag_Table := Make_SZ;
      N : Natural;
   begin
      for V in Byte loop
         N := 0;
         for Bit in 0 .. 7 loop
            if (Shift_Right (V, Bit) and 1) /= 0 then
               N := N + 1;
            end if;
         end loop;
         if N mod 2 = 0 then
            T (V) := T (V) or FP;
         end if;
      end loop;
      return T;
   end Make_SZP;

   SZ  : constant Flag_Table := Make_SZ;
   SZP : constant Flag_Table := Make_SZP;

   --  State of the instruction being executed
   Idx : Natural range 0 .. 2 := 0;     --  0 HL, 1 IX, 2 IY
   Addr_Valid : Boolean := False;
   Addr_Cache : Word := 0;
   EI_Delay : Boolean := False;
   T : Natural := 0;
   Extra : Natural := 0;               --  prefix and (IX+d) T-states

   function W (Hi_B, Lo_B : Byte) return Word is
     (Shift_Left (Word (Hi_B), 8) or Word (Lo_B));

   procedure Inc_R is
   begin
      R := (R and 16#80#) or ((R + 1) and 16#7F#);
   end Inc_R;

   function Fetch return Byte is
      V : constant Byte := Read (PC);
   begin
      PC := PC + 1;
      return V;
   end Fetch;

   function Fetch_Op return Byte is
   begin
      Fetch_Hook (PC);
      Inc_R;
      return Fetch;
   end Fetch_Op;

   function Fetch_Word return Word is
      L8 : constant Byte := Fetch;
      H8 : constant Byte := Fetch;
   begin
      return W (H8, L8);
   end Fetch_Word;

   function Read16 (Addr : Word) return Word is
     (W (Read (Addr + 1), Read (Addr)));

   procedure Write16 (Addr : Word; V : Word) is
   begin
      Write (Addr, Lo (V));
      Write (Addr + 1, Hi (V));
   end Write16;

   procedure Push (V : Word) is
   begin
      SP := SP - 1;
      Write (SP, Hi (V));
      SP := SP - 1;
      Write (SP, Lo (V));
   end Push;

   function Pop return Word is
      L8, H8 : Byte;
   begin
      L8 := Read (SP);
      SP := SP + 1;
      H8 := Read (SP);
      SP := SP + 1;
      return W (H8, L8);
   end Pop;

   function BC return Word is (W (B, C));
   function DE return Word is (W (D, E));
   function HL return Word is (W (H, L));
   procedure Set_BC (V : Word) is begin B := Hi (V); C := Lo (V); end Set_BC;
   procedure Set_DE (V : Word) is begin D := Hi (V); E := Lo (V); end Set_DE;
   procedure Set_HL (V : Word) is begin H := Hi (V); L := Lo (V); end Set_HL;

   --  HL, IX or IY according to the prefix
   function HLx return Word is
     (case Idx is when 0 => HL, when 1 => IX, when 2 => IY);

   procedure Set_HLx (V : Word) is
   begin
      case Idx is
         when 0 => Set_HL (V);
         when 1 => IX := V;
         when 2 => IY := V;
      end case;
   end Set_HLx;

   --  (HL) or (IX+d): the displacement is fetched on first use
   function Mem_Addr return Word is
   begin
      if not Addr_Valid then
         if Idx = 0 then
            Addr_Cache := HL;
         else
            declare
               Dis : constant Byte := Fetch;
               Off : constant Integer :=
                 (if Dis >= 128 then Integer (Dis) - 256 else Integer (Dis));
            begin
               Addr_Cache := Word ((Integer (HLx) + Off) mod 65536);
               Extra := Extra + 8;
            end;
         end if;
         Addr_Valid := True;
      end if;
      return Addr_Cache;
   end Mem_Addr;

   --  r[n]: B C D E H L (HL) A; with a prefix H / L are IXH / IXL (or
   --  IYH / IYL) unless Plain (instructions that also use (IX+d))
   function Get_R (N : Natural; Plain : Boolean := False) return Byte is
   begin
      case N is
         when 0 => return B;
         when 1 => return C;
         when 2 => return D;
         when 3 => return E;
         when 4 => return (if Idx = 0 or else Plain then H else Hi (HLx));
         when 5 => return (if Idx = 0 or else Plain then L else Lo (HLx));
         when 6 => return Read (Mem_Addr);
         when others => return A;
      end case;
   end Get_R;

   procedure Set_R (N : Natural; V : Byte; Plain : Boolean := False) is
   begin
      case N is
         when 0 => B := V;
         when 1 => C := V;
         when 2 => D := V;
         when 3 => E := V;
         when 4 =>
            if Idx = 0 or else Plain then
               H := V;
            else
               Set_HLx (W (V, Lo (HLx)));
            end if;
         when 5 =>
            if Idx = 0 or else Plain then
               L := V;
            else
               Set_HLx (W (Hi (HLx), V));
            end if;
         when 6 => Write (Mem_Addr, V);
         when others => A := V;
      end case;
   end Set_R;

   function Get_RP (P : Natural) return Word is
     (case P is when 0 => BC, when 1 => DE, when 2 => HLx, when others => SP);

   procedure Set_RP (P : Natural; V : Word) is
   begin
      case P is
         when 0 => Set_BC (V);
         when 1 => Set_DE (V);
         when 2 => Set_HLx (V);
         when others => SP := V;
      end case;
   end Set_RP;

   function Cond (Y : Natural) return Boolean is
     (case Y is
         when 0 => (F and FZ) = 0,
         when 1 => (F and FZ) /= 0,
         when 2 => (F and FC) = 0,
         when 3 => (F and FC) /= 0,
         when 4 => (F and FP) = 0,
         when 5 => (F and FP) /= 0,
         when 6 => (F and FS) = 0,
         when others => (F and FS) /= 0);

   ---------------------------------------------------------------------
   --  Arithmetic
   ---------------------------------------------------------------------

   procedure Add8 (V : Byte; Cy : Byte) is
      Res : constant Natural := Natural (A) + Natural (V) + Natural (Cy);
      R8  : constant Byte := Byte (Res mod 256);
   begin
      F := SZ (R8) or ((A xor V xor R8) and FH)
        or (if Res > 255 then FC else 0)
        or (if ((A xor V) and 16#80#) = 0 and then ((A xor R8) and 16#80#) /= 0
            then FP else 0);
      A := R8;
   end Add8;

   procedure Sub8 (V : Byte; Cy : Byte; Store : Boolean) is
      Res : constant Integer := Integer (A) - Integer (V) - Integer (Cy);
      R8  : constant Byte := Byte (Res mod 256);
   begin
      F := (SZ (R8) and not FXY) or ((if Store then R8 else V) and FXY)
        or FN or ((A xor V xor R8) and FH)
        or (if Res < 0 then FC else 0)
        or (if ((A xor V) and (A xor R8) and 16#80#) /= 0 then FP else 0);
      if Store then
         A := R8;
      end if;
   end Sub8;

   procedure ALU (Op : Natural; V : Byte) is
   begin
      case Op is
         when 0 => Add8 (V, 0);
         when 1 => Add8 (V, F and FC);
         when 2 => Sub8 (V, 0, True);
         when 3 => Sub8 (V, F and FC, True);
         when 4 => A := A and V; F := SZP (A) or FH;
         when 5 => A := A xor V; F := SZP (A);
         when 6 => A := A or V; F := SZP (A);
         when others => Sub8 (V, 0, False);
      end case;
   end ALU;

   function Inc8 (V : Byte) return Byte is
      R8 : constant Byte := V + 1;
   begin
      F := (F and FC) or SZ (R8) or (if (R8 and 16#0F#) = 0 then FH else 0)
        or (if R8 = 16#80# then FP else 0);
      return R8;
   end Inc8;

   function Dec8 (V : Byte) return Byte is
      R8 : constant Byte := V - 1;
   begin
      F := (F and FC) or SZ (R8) or FN
        or (if (R8 and 16#0F#) = 16#0F# then FH else 0)
        or (if R8 = 16#7F# then FP else 0);
      return R8;
   end Dec8;

   function Add16 (X, Y : Word) return Word is
      Res : constant Natural := Natural (X) + Natural (Y);
      R16 : constant Word := Word (Res mod 65536);
   begin
      F := (F and (FS or FZ or FP)) or (Hi (R16) and FXY)
        or (if ((X xor Y xor R16) and 16#1000#) /= 0 then FH else 0)
        or (if Res > 16#FFFF# then FC else 0);
      return R16;
   end Add16;

   procedure Adc16 (V : Word) is
      X   : constant Word := HLx;
      Res : constant Natural :=
        Natural (X) + Natural (V) + Natural (F and FC);
      R16 : constant Word := Word (Res mod 65536);
   begin
      F := (Hi (R16) and (FS or FXY)) or (if R16 = 0 then FZ else 0)
        or (if ((X xor V xor R16) and 16#1000#) /= 0 then FH else 0)
        or (if ((X xor V) and 16#8000#) = 0
              and then ((X xor R16) and 16#8000#) /= 0 then FP else 0)
        or (if Res > 16#FFFF# then FC else 0);
      Set_HLx (R16);
   end Adc16;

   procedure Sbc16 (V : Word) is
      X   : constant Word := HLx;
      Res : constant Integer :=
        Integer (X) - Integer (V) - Integer (F and FC);
      R16 : constant Word := Word (Res mod 65536);
   begin
      F := (Hi (R16) and (FS or FXY)) or (if R16 = 0 then FZ else 0) or FN
        or (if ((X xor V xor R16) and 16#1000#) /= 0 then FH else 0)
        or (if ((X xor V) and (X xor R16) and 16#8000#) /= 0 then FP else 0)
        or (if Res < 0 then FC else 0);
      Set_HLx (R16);
   end Sbc16;

   function Rot (Op : Natural; V : Byte) return Byte is
      Cy  : constant Byte := F and FC;
      R8  : Byte;
      Out_C : Byte;
   begin
      case Op is
         when 0 => Out_C := Shift_Right (V, 7); R8 := Shift_Left (V, 1) or Out_C;
         when 1 => Out_C := V and 1; R8 := Shift_Right (V, 1) or Shift_Left (Out_C, 7);
         when 2 => Out_C := Shift_Right (V, 7); R8 := Shift_Left (V, 1) or Cy;
         when 3 => Out_C := V and 1; R8 := Shift_Right (V, 1) or Shift_Left (Cy, 7);
         when 4 => Out_C := Shift_Right (V, 7); R8 := Shift_Left (V, 1);
         when 5 => Out_C := V and 1; R8 := Shift_Right (V, 1) or (V and 16#80#);
         when 6 => Out_C := Shift_Right (V, 7); R8 := Shift_Left (V, 1) or 1;
         when others => Out_C := V and 1; R8 := Shift_Right (V, 1);
      end case;
      F := SZP (R8) or Out_C;
      return R8;
   end Rot;

   procedure Bit_Test (N : Natural; V : Byte; XY_From : Byte) is
      Set : constant Boolean := (Shift_Right (V, N) and 1) /= 0;
   begin
      F := (F and FC) or FH or (XY_From and FXY)
        or (if Set then 0 else FZ or FP)
        or (if N = 7 and then Set then FS else 0);
   end Bit_Test;

   procedure DAA is
      Corr : Byte := 0;
      Cy   : Boolean := (F and FC) /= 0;
      R8   : Byte;
   begin
      if (F and FH) /= 0 or else (A and 16#0F#) > 9 then
         Corr := 6;
      end if;
      if Cy or else A > 16#99# then
         Corr := Corr or 16#60#;
         Cy := True;
      end if;
      R8 := (if (F and FN) /= 0 then A - Corr else A + Corr);
      F := SZP (R8) or (F and FN) or ((A xor R8) and FH)
        or (if Cy then FC else 0);
      A := R8;
   end DAA;

   ---------------------------------------------------------------------
   --  Block instructions
   ---------------------------------------------------------------------

   procedure Block (Y, Z : Natural) is
      Dir : constant Word := (if Y mod 2 = 0 then 1 else 16#FFFF#);
      Rep : constant Boolean := Y >= 6;
      V   : Byte;
      Again : Boolean := False;
   begin
      case Z is
         when 0 =>                                    --  LDI LDD LDIR LDDR
            V := Read (HL);
            Write (DE, V);
            Set_HL (HL + Dir);
            Set_DE (DE + Dir);
            Set_BC (BC - 1);
            declare
               N : constant Byte := V + A;
            begin
               F := (F and (FS or FZ or FC)) or (N and FX)
                 or (if (N and 2) /= 0 then FY else 0)
                 or (if BC /= 0 then FP else 0);
            end;
            Again := Rep and then BC /= 0;
         when 1 =>                                    --  CPI CPD CPIR CPDR
            V := Read (HL);
            declare
               Res : constant Byte := A - V;
               Half : constant Boolean := ((A xor V xor Res) and FH) /= 0;
               N : constant Byte := Res - (if Half then 1 else 0);
            begin
               Set_HL (HL + Dir);
               Set_BC (BC - 1);
               F := (F and FC) or (SZ (Res) and (FS or FZ)) or FN
                 or (if Half then FH else 0) or (N and FX)
                 or (if (N and 2) /= 0 then FY else 0)
                 or (if BC /= 0 then FP else 0);
               Again := Rep and then BC /= 0 and then Res /= 0;
            end;
         when 2 =>                                    --  INI IND INIR INDR
            V := In_Port (BC);
            Write (HL, V);
            Set_HL (HL + Dir);
            B := B - 1;
            F := SZ (B) or (if (V and 16#80#) /= 0 then FN else 0)
              or (F and FC);
            Again := Rep and then B /= 0;
         when others =>                               --  OUTI OUTD OTIR OTDR
            V := Read (HL);
            B := B - 1;
            Out_Port (BC, V);
            Set_HL (HL + Dir);
            F := SZ (B) or (if (V and 16#80#) /= 0 then FN else 0)
              or (F and FC);
            Again := Rep and then B /= 0;
      end case;
      if Again then
         PC := PC - 2;
         T := 21;
      else
         T := 16;
      end if;
   end Block;

   ---------------------------------------------------------------------
   --  Prefixed groups
   ---------------------------------------------------------------------

   procedure Exec_CB is
      --  CB xx, or DD CB d xx / FD CB d xx (operating on (IX+d), with the
      --  result also copied to r[z] when z /= 6, undocumented)
      Addr : Word := 0;
      Op   : Byte;
      X, Y, Z : Natural;
      V, Res : Byte;
   begin
      if Idx /= 0 then
         Addr := Mem_Addr;                  --  the displacement comes first
         Op := Fetch;                       --  not an M1 cycle
         T := 11;                           --  + 4 prefix + 8 (d) = 23
      else
         Op := Fetch_Op;
         T := 8;
      end if;
      X := Natural (Shift_Right (Op, 6));
      Y := Natural (Shift_Right (Op, 3) and 7);
      Z := Natural (Op and 7);
      if Idx /= 0 then
         V := Read (Addr);
      else
         V := Get_R (Z);
         if Z = 6 then
            Addr := Mem_Addr;
            T := (if X = 1 then 12 else 15);
         end if;
      end if;
      case X is
         when 0 => Res := Rot (Y, V);
         when 1 =>
            Bit_Test (Y, V, (if Idx /= 0 or else Z = 6 then Hi (Addr) else V));
            if Idx /= 0 then
               T := 8;                      --  BIT n,(IX+d): 20
            end if;
            return;
         when 2 => Res := V and not Shift_Left (1, Y);
         when others => Res := V or Shift_Left (1, Y);
      end case;
      if Idx /= 0 then
         Write (Addr, Res);
         if Z /= 6 then
            Set_R (Z, Res, Plain => True);
         end if;
      else
         Set_R (Z, Res);
      end if;
   end Exec_CB;

   procedure Exec_ED is
      Op : constant Byte := Fetch_Op;
      X : constant Natural := Natural (Shift_Right (Op, 6));
      Y : constant Natural := Natural (Shift_Right (Op, 3) and 7);
      Z : constant Natural := Natural (Op and 7);
      P : constant Natural := Y / 2;
      Q : constant Natural := Y mod 2;
      V : Byte;
   begin
      Idx := 0;                       --  ED ignores DD / FD
      T := 8;
      if X = 1 then
         case Z is
            when 0 =>
               V := In_Port (BC);
               F := (F and FC) or SZP (V);
               if Y /= 6 then
                  Set_R (Y, V);
               end if;
               T := 12;
            when 1 =>
               Out_Port (BC, (if Y = 6 then 0 else Get_R (Y)));
               T := 12;
            when 2 =>
               if Q = 0 then
                  Sbc16 (Get_RP (P));
               else
                  Adc16 (Get_RP (P));
               end if;
               T := 15;
            when 3 =>
               declare
                  Addr : constant Word := Fetch_Word;
               begin
                  if Q = 0 then
                     Write16 (Addr, Get_RP (P));
                  else
                     Set_RP (P, Read16 (Addr));
                  end if;
               end;
               T := 20;
            when 4 =>
               V := A;
               A := 0;
               Sub8 (V, 0, True);
            when 5 =>
               PC := Pop;
               IFF1 := IFF2;             --  RETN (RETI as well)
               T := 14;
            when 6 =>
               IM := (case Y mod 4 is when 0 | 1 => 0, when 2 => 1,
                      when others => 2);
            when others =>
               case Y is
                  when 0 => I := A; T := 9;
                  when 1 => R := A; T := 9;
                  when 2 | 3 =>
                     A := (if Y = 2 then I else R);
                     F := (F and FC) or SZ (A) or (if IFF2 then FP else 0);
                     T := 9;
                  when 4 | 5 =>
                     V := Read (HL);
                     if Y = 4 then                         --  RRD
                        Write (HL, Shift_Left (A, 4) or Shift_Right (V, 4));
                        A := (A and 16#F0#) or (V and 16#0F#);
                     else                                  --  RLD
                        Write (HL, Shift_Left (V, 4) or (A and 16#0F#));
                        A := (A and 16#F0#) or Shift_Right (V, 4);
                     end if;
                     F := (F and FC) or SZP (A);
                     T := 18;
                  when others => null;
               end case;
         end case;
      elsif X = 2 and then Z <= 3 and then Y >= 4 then
         Block (Y, Z);
      end if;
   end Exec_ED;

   ---------------------------------------------------------------------
   --  Main decoder
   ---------------------------------------------------------------------

   procedure Execute (Op : Byte) is
      X : constant Natural := Natural (Shift_Right (Op, 6));
      Y : constant Natural := Natural (Shift_Right (Op, 3) and 7);
      Z : constant Natural := Natural (Op and 7);
      P : constant Natural := Y / 2;
      Q : constant Natural := Y mod 2;
      V : Byte;
      Nn : Word;
   begin
      case X is
         when 0 =>
            case Z is
               when 0 =>
                  case Y is
                     when 0 => T := 4;
                     when 1 =>
                        declare
                           TA : constant Byte := A;
                           TF : constant Byte := F;
                        begin
                           A := A2; F := F2; A2 := TA; F2 := TF;
                        end;
                        T := 4;
                     when 2 =>
                        V := Fetch;
                        B := B - 1;
                        if B /= 0 then
                           PC := Word ((Integer (PC) + (if V >= 128
                             then Integer (V) - 256 else Integer (V))) mod 65536);
                           T := 13;
                        else
                           T := 8;
                        end if;
                     when others =>
                        V := Fetch;
                        if Y = 3 or else Cond (Y - 4) then
                           PC := Word ((Integer (PC) + (if V >= 128
                             then Integer (V) - 256 else Integer (V))) mod 65536);
                           T := 12;
                        else
                           T := 7;
                        end if;
                  end case;
               when 1 =>
                  if Q = 0 then
                     Set_RP (P, Fetch_Word);
                     T := 10;
                  else
                     Set_HLx (Add16 (HLx, Get_RP (P)));
                     T := 11;
                  end if;
               when 2 =>
                  case P is
                     when 0 | 1 =>
                        Nn := (if P = 0 then BC else DE);
                        if Q = 0 then
                           Write (Nn, A);
                        else
                           A := Read (Nn);
                        end if;
                        T := 7;
                     when 2 =>
                        Nn := Fetch_Word;
                        if Q = 0 then
                           Write16 (Nn, HLx);
                        else
                           Set_HLx (Read16 (Nn));
                        end if;
                        T := 16;
                     when others =>
                        Nn := Fetch_Word;
                        if Q = 0 then
                           Write (Nn, A);
                        else
                           A := Read (Nn);
                        end if;
                        T := 13;
                  end case;
               when 3 =>
                  Set_RP (P, (if Q = 0 then Get_RP (P) + 1 else Get_RP (P) - 1));
                  T := 6;
               when 4 =>
                  T := (if Y = 6 then 11 else 4);
                  if Y = 6 then
                     Nn := Mem_Addr;
                     Write (Nn, Inc8 (Read (Nn)));
                  else
                     Set_R (Y, Inc8 (Get_R (Y)));
                  end if;
               when 5 =>
                  T := (if Y = 6 then 11 else 4);
                  if Y = 6 then
                     Nn := Mem_Addr;
                     Write (Nn, Dec8 (Read (Nn)));
                  else
                     Set_R (Y, Dec8 (Get_R (Y)));
                  end if;
               when 6 =>
                  if Y = 6 then
                     Nn := Mem_Addr;            --  d before n
                     Write (Nn, Fetch);
                     T := (if Idx = 0 then 10 else 7);   --  19 with DD / FD
                  else
                     Set_R (Y, Fetch);
                     T := 7;
                  end if;
               when others =>
                  T := 4;
                  case Y is
                     when 0 =>
                        F := (F and (FS or FZ or FP)) or Shift_Right (A, 7);
                        A := Shift_Left (A, 1) or (F and FC);
                        F := F or (A and FXY);
                     when 1 =>
                        F := (F and (FS or FZ or FP)) or (A and 1);
                        A := Shift_Right (A, 1) or Shift_Left (F and FC, 7);
                        F := F or (A and FXY);
                     when 2 =>
                        V := F and FC;
                        F := (F and (FS or FZ or FP)) or Shift_Right (A, 7);
                        A := Shift_Left (A, 1) or V;
                        F := F or (A and FXY);
                     when 3 =>
                        V := F and FC;
                        F := (F and (FS or FZ or FP)) or (A and 1);
                        A := Shift_Right (A, 1) or Shift_Left (V, 7);
                        F := F or (A and FXY);
                     when 4 => DAA;
                     when 5 =>
                        A := not A;
                        F := (F and (FS or FZ or FP or FC)) or FH or FN
                          or (A and FXY);
                     when 6 =>
                        F := (F and (FS or FZ or FP)) or FC or (A and FXY);
                     when others =>
                        F := (F and (FS or FZ or FP)) or (A and FXY)
                          or (if (F and FC) /= 0 then FH else FC);
                  end case;
            end case;

         when 1 =>
            if Y = 6 and then Z = 6 then
               Halted := True;
               T := 4;
            else
               declare
                  Plain : constant Boolean := Y = 6 or else Z = 6;
               begin
                  Set_R (Y, Get_R (Z, Plain), Plain);
                  T := (if Plain then 7 else 4);
               end;
            end if;

         when 2 =>
            ALU (Y, Get_R (Z));
            T := (if Z = 6 then 7 else 4);

         when others =>
            case Z is
               when 0 =>
                  if Cond (Y) then
                     PC := Pop;
                     T := 11;
                  else
                     T := 5;
                  end if;
               when 1 =>
                  if Q = 0 then
                     Nn := Pop;
                     if P = 3 then
                        A := Hi (Nn);
                        F := Lo (Nn);
                     else
                        Set_RP (P, Nn);
                     end if;
                     T := 10;
                  else
                     case P is
                        when 0 => PC := Pop; T := 10;
                        when 1 =>
                           declare
                              T1 : constant Word := BC;
                              T2 : constant Word := DE;
                              T3 : constant Word := HL;
                           begin
                              Set_BC (W (B2, C2));
                              Set_DE (W (D2, E2));
                              Set_HL (W (H2, L2));
                              B2 := Hi (T1); C2 := Lo (T1);
                              D2 := Hi (T2); E2 := Lo (T2);
                              H2 := Hi (T3); L2 := Lo (T3);
                           end;
                           T := 4;
                        when 2 => PC := HLx; T := 4;
                        when others => SP := HLx; T := 6;
                     end case;
                  end if;
               when 2 =>
                  Nn := Fetch_Word;
                  if Cond (Y) then
                     PC := Nn;
                  end if;
                  T := 10;
               when 3 =>
                  case Y is
                     when 0 => PC := Fetch_Word; T := 10;
                     when 1 => Exec_CB;
                     when 2 =>
                        V := Fetch;
                        Out_Port (W (A, V), A);
                        T := 11;
                     when 3 =>
                        V := Fetch;
                        A := In_Port (W (A, V));
                        T := 11;
                     when 4 =>
                        Nn := Read16 (SP);
                        Write16 (SP, HLx);
                        Set_HLx (Nn);
                        T := 19;
                     when 5 =>
                        Nn := DE;
                        Set_DE (HL);
                        Set_HL (Nn);
                        T := 4;
                     when 6 =>
                        IFF1 := False;
                        IFF2 := False;
                        T := 4;
                     when others =>
                        IFF1 := True;
                        IFF2 := True;
                        EI_Delay := True;
                        T := 4;
                  end case;
               when 4 =>
                  Nn := Fetch_Word;
                  if Cond (Y) then
                     Push (PC);
                     PC := Nn;
                     T := 17;
                  else
                     T := 10;
                  end if;
               when 5 =>
                  if Q = 0 then
                     Push (if P = 3 then W (A, F) else Get_RP (P));
                     T := 11;
                  else
                     case P is
                        when 0 =>
                           Nn := Fetch_Word;
                           Push (PC);
                           PC := Nn;
                           T := 17;
                        when 2 => Exec_ED;
                        when others =>
                           --  DD / FD: prefix the next opcode
                           Idx := (if P = 1 then 1 else 2);
                           Extra := Extra + 4;
                           Execute (Fetch_Op);
                     end case;
                  end if;
               when 6 =>
                  ALU (Y, Fetch);
                  T := 7;
               when others =>
                  Push (PC);
                  PC := Word (Y * 8);
                  T := 11;
            end case;
      end case;
   end Execute;

   procedure Reset is
   begin
      PC := 0;
      I := 0;
      R := 0;
      IFF1 := False;
      IFF2 := False;
      IM := 0;
      Halted := False;
      EI_Delay := False;
      NMI_Pending := False;
      SP := 16#FFFF#;
      A := 16#FF#;
      F := 16#FF#;
   end Reset;

   procedure Step (T_States : out Natural) is
   begin
      if NMI_Pending then
         NMI_Pending := False;
         Halted := False;
         IFF1 := False;
         Inc_R;
         Push (PC);
         PC := 16#0066#;
         T_States := 11;
         return;
      end if;
      if INT_Line and then IFF1 and then not EI_Delay then
         Halted := False;
         IFF1 := False;
         IFF2 := False;
         Inc_R;
         Push (PC);
         if IM = 2 then
            PC := Read16 (W (I, Ack_Byte));
            T_States := 19;
         else
            PC := 16#0038#;
            T_States := 13;
         end if;
         return;
      end if;
      EI_Delay := False;
      if Halted then
         Inc_R;
         T_States := 4;
         return;
      end if;
      Idx := 0;
      Addr_Valid := False;
      T := 0;
      Extra := 0;
      Execute (Fetch_Op);
      T_States := T + Extra;
   end Step;

end Z80;
