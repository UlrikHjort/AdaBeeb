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
with Interfaces; use Interfaces;

package body Keyboard is

   type Shift_Mode is (Natural_Shift, Force_Shift, Force_No_Shift);

   type Key_Pos is record
      Col : Column := 0;
      R   : Row := 0;
   end record;

   type Mapping is record
      Valid : Boolean := False;
      Key   : Key_Pos;
      Shift : Shift_Mode := Natural_Shift;
      Ctrl  : Boolean := False;     --  also hold CTRL
      Joy   : Byte := 0;            --  joystick bits instead of a key
      Brk   : Boolean := False;     --  BREAK
   end record;

   No_Map : constant Mapping := (others => <>);

   Active : array (0 .. 1023) of Mapping := (others => No_Map);

   function K (Code : Natural) return Key_Pos is
     ((Col => Code mod 16, R => Code / 16));

   --  Internal key numbers
   K_SHIFT  : constant Key_Pos := K (16#00#);
   K_CTRL   : constant Key_Pos := K (16#01#);
   K_Q      : constant Key_Pos := K (16#10#);
   K_3      : constant Key_Pos := K (16#11#);
   K_4      : constant Key_Pos := K (16#12#);
   K_5      : constant Key_Pos := K (16#13#);
   K_F4     : constant Key_Pos := K (16#14#);
   K_8      : constant Key_Pos := K (16#15#);
   K_F7     : constant Key_Pos := K (16#16#);
   K_MINUS  : constant Key_Pos := K (16#17#);
   K_CARET  : constant Key_Pos := K (16#18#);
   K_LEFT   : constant Key_Pos := K (16#19#);
   K_F0     : constant Key_Pos := K (16#20#);
   K_W      : constant Key_Pos := K (16#21#);
   K_E      : constant Key_Pos := K (16#22#);
   K_T      : constant Key_Pos := K (16#23#);
   K_7      : constant Key_Pos := K (16#24#);
   K_I      : constant Key_Pos := K (16#25#);
   K_9      : constant Key_Pos := K (16#26#);
   K_0      : constant Key_Pos := K (16#27#);
   K_UNDER  : constant Key_Pos := K (16#28#);
   K_DOWN   : constant Key_Pos := K (16#29#);
   K_1      : constant Key_Pos := K (16#30#);
   K_2      : constant Key_Pos := K (16#31#);
   K_D      : constant Key_Pos := K (16#32#);
   K_R      : constant Key_Pos := K (16#33#);
   K_6      : constant Key_Pos := K (16#34#);
   K_U      : constant Key_Pos := K (16#35#);
   K_O      : constant Key_Pos := K (16#36#);
   K_P      : constant Key_Pos := K (16#37#);
   K_LBRACK : constant Key_Pos := K (16#38#);
   K_UP     : constant Key_Pos := K (16#39#);
   K_CAPS   : constant Key_Pos := K (16#40#);
   K_A      : constant Key_Pos := K (16#41#);
   K_X      : constant Key_Pos := K (16#42#);
   K_F      : constant Key_Pos := K (16#43#);
   K_Y      : constant Key_Pos := K (16#44#);
   K_J      : constant Key_Pos := K (16#45#);
   K_K      : constant Key_Pos := K (16#46#);
   K_AT     : constant Key_Pos := K (16#47#);
   K_COLON  : constant Key_Pos := K (16#48#);
   K_RETURN : constant Key_Pos := K (16#49#);
   K_SHLOCK : constant Key_Pos := K (16#50#);
   K_S      : constant Key_Pos := K (16#51#);
   K_C      : constant Key_Pos := K (16#52#);
   K_G      : constant Key_Pos := K (16#53#);
   K_H      : constant Key_Pos := K (16#54#);
   K_N      : constant Key_Pos := K (16#55#);
   K_L      : constant Key_Pos := K (16#56#);
   K_SEMI   : constant Key_Pos := K (16#57#);
   K_RBRACK : constant Key_Pos := K (16#58#);
   K_DELETE : constant Key_Pos := K (16#59#);
   K_TAB    : constant Key_Pos := K (16#60#);
   K_Z      : constant Key_Pos := K (16#61#);
   K_SPACE  : constant Key_Pos := K (16#62#);
   K_V      : constant Key_Pos := K (16#63#);
   K_B      : constant Key_Pos := K (16#64#);
   K_M      : constant Key_Pos := K (16#65#);
   K_COMMA  : constant Key_Pos := K (16#66#);
   K_DOT    : constant Key_Pos := K (16#67#);
   K_SLASH  : constant Key_Pos := K (16#68#);
   K_COPY   : constant Key_Pos := K (16#69#);
   K_ESCAPE : constant Key_Pos := K (16#70#);
   K_F1     : constant Key_Pos := K (16#71#);
   K_F2     : constant Key_Pos := K (16#72#);
   K_F3     : constant Key_Pos := K (16#73#);
   K_F5     : constant Key_Pos := K (16#74#);
   K_F6     : constant Key_Pos := K (16#75#);
   K_F8     : constant Key_Pos := K (16#76#);
   K_F9     : constant Key_Pos := K (16#77#);
   K_BSLASH : constant Key_Pos := K (16#78#);
   K_RIGHT  : constant Key_Pos := K (16#79#);

   type Pos_Array is array (Character range <>) of Key_Pos;

   Letters : constant Pos_Array ('A' .. 'Z') :=
     (K_A, K_B, K_C, K_D, K_E, K_F, K_G, K_H, K_I, K_J, K_K, K_L, K_M,
      K_N, K_O, K_P, K_Q, K_R, K_S, K_T, K_U, K_V, K_W, K_X, K_Y, K_Z);

   Digit_Keys : constant Pos_Array ('0' .. '9') :=
     (K_0, K_1, K_2, K_3, K_4, K_5, K_6, K_7, K_8, K_9);

   Function_Keys : constant array (0 .. 9) of Key_Pos :=
     (K_F0, K_F1, K_F2, K_F3, K_F4, K_F5, K_F6, K_F7, K_F8, K_F9);

   function Key (P : Key_Pos; S : Shift_Mode := Natural_Shift)
     return Mapping is
     ((Valid => True, Key => P, Shift => S, Ctrl => False, Joy => 0,
       Brk => False));

   function Joy (Bits : Byte) return Mapping is
     ((Valid => True, Key => (0, 0), Shift => Natural_Shift, Ctrl => False,
       Joy => Bits, Brk => False));

   --  GDK key values
   GDK_BackSpace : constant := 16#FF08#;
   GDK_Tab       : constant := 16#FF09#;
   GDK_Return    : constant := 16#FF0D#;
   GDK_Pause     : constant := 16#FF13#;
   GDK_Escape    : constant := 16#FF1B#;
   GDK_Home      : constant := 16#FF50#;
   GDK_Left      : constant := 16#FF51#;
   GDK_Up        : constant := 16#FF52#;
   GDK_Right     : constant := 16#FF53#;
   GDK_Down      : constant := 16#FF54#;
   GDK_Page_Up   : constant := 16#FF55#;
   GDK_End       : constant := 16#FF57#;
   GDK_Insert    : constant := 16#FF63#;
   GDK_Delete    : constant := 16#FFFF#;
   GDK_KP_Enter  : constant := 16#FF8D#;
   GDK_KP_Home   : constant := 16#FF95#;
   GDK_KP_Left   : constant := 16#FF96#;
   GDK_KP_Up     : constant := 16#FF97#;
   GDK_KP_Right  : constant := 16#FF98#;
   GDK_KP_Down   : constant := 16#FF99#;
   GDK_KP_Page_Up : constant := 16#FF9A#;
   GDK_KP_Page_Down : constant := 16#FF9B#;
   GDK_KP_End    : constant := 16#FF9C#;
   GDK_KP_Begin  : constant := 16#FF9D#;
   GDK_KP_Insert : constant := 16#FF9E#;
   GDK_KP_0      : constant := 16#FFB0#;
   GDK_KP_Multiply : constant := 16#FFAA#;
   GDK_KP_Add    : constant := 16#FFAB#;
   GDK_KP_Subtract : constant := 16#FFAD#;
   GDK_KP_Decimal : constant := 16#FFAE#;
   GDK_KP_Divide : constant := 16#FFAF#;
   GDK_F1        : constant := 16#FFBE#;
   GDK_F10       : constant := 16#FFC7#;
   GDK_F12       : constant := 16#FFC9#;
   GDK_Shift_L   : constant := 16#FFE1#;
   GDK_Shift_R   : constant := 16#FFE2#;
   GDK_Control_L : constant := 16#FFE3#;
   GDK_Control_R : constant := 16#FFE4#;
   GDK_Caps_Lock : constant := 16#FFE5#;
   GDK_Alt_R     : constant := 16#FFEA#;
   GDK_Sterling  : constant := 16#00A3#;
   GDK_Dead_Circumflex : constant := 16#FE52#;

   J_Up    : constant Byte := 1;
   J_Down  : constant Byte := 2;
   J_Left  : constant Byte := 4;
   J_Right : constant Byte := 8;
   J_Fire  : constant Byte := 16;

   function Joystick_Mapping (KV : Unsigned_32) return Mapping is
   begin
      if Joystick_Port = 0 then
         return No_Map;
      end if;
      case Joystick_Keys is
         when Keypad =>
            case KV is
               when GDK_KP_0 + 8 | GDK_KP_Up => return Joy (J_Up);
               when GDK_KP_0 + 2 | GDK_KP_Down => return Joy (J_Down);
               when GDK_KP_0 + 4 | GDK_KP_Left => return Joy (J_Left);
               when GDK_KP_0 + 6 | GDK_KP_Right => return Joy (J_Right);
               when GDK_KP_0 + 7 | GDK_KP_Home => return Joy (J_Up or J_Left);
               when GDK_KP_0 + 9 | GDK_KP_Page_Up =>
                  return Joy (J_Up or J_Right);
               when GDK_KP_0 + 1 | GDK_KP_End => return Joy (J_Down or J_Left);
               when GDK_KP_0 + 3 | GDK_KP_Page_Down =>
                  return Joy (J_Down or J_Right);
               when GDK_KP_0 | GDK_KP_Insert | GDK_KP_0 + 5 | GDK_KP_Begin
                  | GDK_KP_Enter =>
                  return Joy (J_Fire);
               when others => return No_Map;
            end case;
         when Cursor_Keys =>
            case KV is
               when GDK_Up => return Joy (J_Up);
               when GDK_Down => return Joy (J_Down);
               when GDK_Left => return Joy (J_Left);
               when GDK_Right => return Joy (J_Right);
               when GDK_Alt_R => return Joy (J_Fire);
               when others => return No_Map;
            end case;
      end case;
   end Joystick_Mapping;

   function Letter_Map (Upper : Character; Lower_Case : Boolean)
     return Mapping is
      --  With CAPS LOCK off, SHIFT gives capitals; with it on, letters are
      --  always capitals (typed text switches CAPS LOCK off first)
   begin
      if Caps_LED then
         return Key (Letters (Upper), Natural_Shift);
      end if;
      return Key (Letters (Upper),
                  (if Lower_Case then Force_No_Shift else Force_Shift));
   end Letter_Map;

   function Char_Map (C : Character) return Mapping is
   begin
      case C is
         when 'a' .. 'z' =>
            return Letter_Map (Character'Val (Character'Pos (C) - 32), True);
         when 'A' .. 'Z' => return Letter_Map (C, False);
         when '0' .. '9' => return Key (Digit_Keys (C), Force_No_Shift);
         when ' ' => return Key (K_SPACE);
         when '!' => return Key (K_1, Force_Shift);
         when '"' => return Key (K_2, Force_Shift);
         when '#' => return Key (K_3, Force_Shift);
         when '$' => return Key (K_4, Force_Shift);
         when '%' => return Key (K_5, Force_Shift);
         when '&' => return Key (K_6, Force_Shift);
         when ''' => return Key (K_7, Force_Shift);
         when '(' => return Key (K_8, Force_Shift);
         when ')' => return Key (K_9, Force_Shift);
         when '-' => return Key (K_MINUS, Force_No_Shift);
         when '=' => return Key (K_MINUS, Force_Shift);
         when '^' => return Key (K_CARET, Force_No_Shift);
         when '~' => return Key (K_CARET, Force_Shift);
         when '\' => return Key (K_BSLASH, Force_No_Shift);
         when '|' => return Key (K_BSLASH, Force_Shift);
         when '@' => return Key (K_AT, Force_No_Shift);
         when '[' => return Key (K_LBRACK, Force_No_Shift);
         when '{' => return Key (K_LBRACK, Force_Shift);
         when '_' => return Key (K_UNDER, Force_No_Shift);
         when '`' => return Key (K_UNDER, Force_Shift);    --  pound sign
         when ';' => return Key (K_SEMI, Force_No_Shift);
         when '+' => return Key (K_SEMI, Force_Shift);
         when ':' => return Key (K_COLON, Force_No_Shift);
         when '*' => return Key (K_COLON, Force_Shift);
         when ']' => return Key (K_RBRACK, Force_No_Shift);
         when '}' => return Key (K_RBRACK, Force_Shift);
         when ',' => return Key (K_COMMA, Force_No_Shift);
         when '<' => return Key (K_COMMA, Force_Shift);
         when '.' => return Key (K_DOT, Force_No_Shift);
         when '>' => return Key (K_DOT, Force_Shift);
         when '/' => return Key (K_SLASH, Force_No_Shift);
         when '?' => return Key (K_SLASH, Force_Shift);
         when others => return No_Map;
      end case;
   end Char_Map;

   function Map_Key (KV : Unsigned_32) return Mapping is
      J : constant Mapping := Joystick_Mapping (KV);
   begin
      if J.Valid then
         return J;
      end if;
      if Master then
         --  numeric keypad (columns 10 .. 12)
         case KV is
            when GDK_KP_0 => return Key (K (16#6A#));
            when GDK_KP_0 + 1 => return Key (K (16#6B#));
            when GDK_KP_0 + 2 => return Key (K (16#7C#));
            when GDK_KP_0 + 3 => return Key (K (16#6C#));
            when GDK_KP_0 + 4 => return Key (K (16#7A#));
            when GDK_KP_0 + 5 => return Key (K (16#7B#));
            when GDK_KP_0 + 6 => return Key (K (16#1A#));
            when GDK_KP_0 + 7 => return Key (K (16#1B#));
            when GDK_KP_0 + 8 => return Key (K (16#2A#));
            when GDK_KP_0 + 9 => return Key (K (16#2B#));
            when GDK_KP_Divide => return Key (K (16#4A#));
            when GDK_KP_Multiply => return Key (K (16#5B#));
            when GDK_KP_Subtract => return Key (K (16#3B#));
            when GDK_KP_Add => return Key (K (16#3A#));
            when GDK_KP_Enter => return Key (K (16#3C#));
            when GDK_KP_Decimal => return Key (K (16#4C#));
            when others => null;
         end case;
      end if;
      if KV in 16#20# .. 16#7E# then
         declare
            C : constant Character := Character'Val (KV);
         begin
            case C is
               when 'a' .. 'z' =>
                  return Key (Letters (Character'Val (KV - 32)));
               when 'A' .. 'Z' => return Key (Letters (C));
               when others => return Char_Map (C);
            end case;
         end;
      end if;
      case KV is
         when GDK_Return | GDK_KP_Enter => return Key (K_RETURN);
         when GDK_BackSpace | GDK_Delete => return Key (K_DELETE);
         when GDK_End | GDK_Insert => return Key (K_COPY);
         when GDK_Left => return Key (K_LEFT);
         when GDK_Right => return Key (K_RIGHT);
         when GDK_Up => return Key (K_UP);
         when GDK_Down => return Key (K_DOWN);
         when GDK_F1 .. GDK_F1 + 8 =>
            return Key (Function_Keys (Natural (KV - GDK_F1) + 1));
         when GDK_F10 => return Key (Function_Keys (0));
         when GDK_F12 | GDK_Pause =>
            return (Valid => True, Key => (0, 0), Shift => Natural_Shift,
                    Ctrl => False, Joy => 0, Brk => True);
         when GDK_Shift_L | GDK_Shift_R => return Key (K_SHIFT);
         when GDK_Control_L | GDK_Control_R => return Key (K_CTRL);
         when GDK_Caps_Lock => return Key (K_CAPS);
         when GDK_Page_Up => return Key (K_SHLOCK);
         when GDK_Escape => return Key (K_ESCAPE);
         when GDK_Tab => return Key (K_TAB);
         when GDK_Home => return Key (K_COPY);
         when GDK_Sterling => return Key (K_UNDER, Force_Shift);
         when GDK_Dead_Circumflex => return Key (K_CARET, Force_No_Shift);
         when others => return No_Map;
      end case;
   end Map_Key;

   --  Positional mapping by X11 hardware keycode (evdev code + 8)
   function Positional_Map (Code : Natural) return Mapping is
      function P (Pos : Key_Pos) return Mapping is (Key (Pos));
   begin
      case Code is
         when 9 => return P (K_ESCAPE);
         when 49 => return P (K_UNDER);
         when 10 => return P (K_1);
         when 11 => return P (K_2);
         when 12 => return P (K_3);
         when 13 => return P (K_4);
         when 14 => return P (K_5);
         when 15 => return P (K_6);
         when 16 => return P (K_7);
         when 17 => return P (K_8);
         when 18 => return P (K_9);
         when 19 => return P (K_0);
         when 20 => return P (K_MINUS);
         when 21 => return P (K_CARET);
         when 22 => return P (K_DELETE);
         when 23 => return P (K_TAB);
         when 24 => return P (K_Q);
         when 25 => return P (K_W);
         when 26 => return P (K_E);
         when 27 => return P (K_R);
         when 28 => return P (K_T);
         when 29 => return P (K_Y);
         when 30 => return P (K_U);
         when 31 => return P (K_I);
         when 32 => return P (K_O);
         when 33 => return P (K_P);
         when 34 => return P (K_AT);
         when 35 => return P (K_LBRACK);
         when 36 => return P (K_RETURN);
         when 37 => return P (K_CTRL);
         when 66 => return P (K_CAPS);
         when 38 => return P (K_A);
         when 39 => return P (K_S);
         when 40 => return P (K_D);
         when 41 => return P (K_F);
         when 42 => return P (K_G);
         when 43 => return P (K_H);
         when 44 => return P (K_J);
         when 45 => return P (K_K);
         when 46 => return P (K_L);
         when 47 => return P (K_SEMI);
         when 48 => return P (K_COLON);
         when 51 => return P (K_RBRACK);
         when 94 => return P (K_BSLASH);
         when 50 | 62 => return P (K_SHIFT);
         when 52 => return P (K_Z);
         when 53 => return P (K_X);
         when 54 => return P (K_C);
         when 55 => return P (K_V);
         when 56 => return P (K_B);
         when 57 => return P (K_N);
         when 58 => return P (K_M);
         when 59 => return P (K_COMMA);
         when 60 => return P (K_DOT);
         when 61 => return P (K_SLASH);
         when 65 => return P (K_SPACE);
         when others => return No_Map;
      end case;
   end Positional_Map;

   Host_Bits : Byte := 0;

   procedure Set_Bit (P : Key_Pos; Down : Boolean) is
   begin
      if Down then
         Matrix (P.Col) := Matrix (P.Col) or Shift_Left (1, P.R);
      else
         Matrix (P.Col) := Matrix (P.Col) and not Shift_Left (1, P.R);
      end if;
   end Set_Bit;

   procedure Rebuild is
      Force_S, Force_NS, Force_C : Boolean := False;
      J : Byte := Host_Bits;
   begin
      Matrix := (others => 0);
      Break_Down := False;
      for M of Active loop
         if M.Valid then
            if M.Joy /= 0 then
               J := J or M.Joy;
            elsif M.Brk then
               Break_Down := True;
            else
               Set_Bit (M.Key, True);
               case M.Shift is
                  when Force_Shift => Force_S := True;
                  when Force_No_Shift => Force_NS := True;
                  when Natural_Shift => null;
               end case;
               Force_C := Force_C or else M.Ctrl;
            end if;
         end if;
      end loop;
      if Force_S then
         Set_Bit (K_SHIFT, True);
      elsif Force_NS then
         Set_Bit (K_SHIFT, False);
      end if;
      if Force_C then
         Set_Bit (K_CTRL, True);
      end if;
      Joy1 := 0;
      Joy2 := 0;
      case Joystick_Port is
         when 1 => Joy1 := J;
         when 2 => Joy2 := J;
         when 0 => null;
      end case;
   end Rebuild;

   procedure Set_Host_Joystick (Bits : Byte) is
   begin
      if Bits /= Host_Bits then
         Host_Bits := Bits;
         Rebuild;
      end if;
   end Set_Host_Joystick;

   function Host_Joystick_Bits return Byte is (Host_Bits);

   procedure Key_Event
     (Keyval  : Unsigned_32;
      Keycode : Natural;
      Pressed : Boolean)
   is
      Code : constant Natural := Keycode mod Active'Length;
   begin
      if Pressed then
         declare
            J : constant Mapping := Joystick_Mapping (Keyval);
            PM : constant Mapping :=
              (if Positional and then not J.Valid
               then Positional_Map (Keycode) else No_Map);
            M : constant Mapping :=
              (if PM.Valid then PM else Map_Key (Keyval));
         begin
            if M.Valid then
               Active (Code) := M;
            end if;
         end;
      else
         Active (Code) := No_Map;
      end if;
      Rebuild;
   end Key_Event;

   procedure Release_All is
   begin
      Active := (others => No_Map);
      Rebuild;
   end Release_All;

   procedure Press (Col : Column; R : Row; Down : Boolean) is
   begin
      Set_Bit ((Col, R), Down);
   end Press;

   function Key_Down (Col : Column; R : Row) return Boolean is
   begin
      if R = 0 and then Col in 2 .. 9 and then not Master then
         return (Links and Shift_Left (1, 9 - Col)) /= 0;
      end if;
      if R = 0 and then Col = 0 and then Hold_Shift then
         return True;
      end if;
      return (Matrix (Col) and Shift_Left (1, R)) /= 0;
   end Key_Down;

   function Column_Active (Col : Column) return Boolean is
     ((Matrix (Col) and 16#FE#) /= 0);

   function Any_Key return Boolean is
   begin
      for C in 0 .. (if Master then 12 else 9) loop
         if (Matrix (C) and 16#FE#) /= 0 then
            return True;
         end if;
      end loop;
      return False;
   end Any_Key;

   Typing : String (1 .. 8192);
   Typing_Len, Typing_Pos : Natural := 0;
   Typing_Phase : Natural := 0;
   Typing_Retry : Boolean := False;
   Typing_Code : constant Natural := 1000;   --  pseudo hardware keycode

   procedure Type_Keys (S : String) is
   begin
      for C of S loop
         if Typing_Len < Typing'Last then
            Typing_Len := Typing_Len + 1;
            Typing (Typing_Len) := C;
         end if;
      end loop;
   end Type_Keys;

   function Typing_Busy return Boolean is (Typing_Pos < Typing_Len);

   procedure Tick_Typing is
   begin
      if Typing_Pos >= Typing_Len then
         Typing_Pos := 0;
         Typing_Len := 0;
         return;
      end if;
      Typing_Phase := Typing_Phase + 1;
      if Typing_Phase = 1 then
         declare
            C : constant Character := Typing (Typing_Pos + 1);
         begin
            if C in 'a' .. 'z' and then Caps_LED then
               --  switch CAPS LOCK off, then type the letter
               Active (Typing_Code) := Key (K_CAPS);
               Typing_Retry := True;
            elsif C = ASCII.LF or else C = ASCII.CR then
               Active (Typing_Code) := Key (K_RETURN);
            elsif C = ASCII.ESC then
               Active (Typing_Code) := Key (K_ESCAPE);
            else
               Active (Typing_Code) := Char_Map (C);
            end if;
            Rebuild;
         end;
      elsif Typing_Phase = 3 then
         Active (Typing_Code) := No_Map;
         Rebuild;
      elsif Typing_Phase >= 5 then
         Typing_Phase := 0;
         if Typing_Retry then
            Typing_Retry := False;
         else
            Typing_Pos := Typing_Pos + 1;
         end if;
      end if;
   end Tick_Typing;

   function Keys_Help return String is
     ("Keyboard mapping is symbolic: type the character you mean." &
      ASCII.LF &
      "F1-F9 = f1-f9, F10 = f0, F12 / Pause = BREAK, End / Insert / Home " &
      "= COPY," & ASCII.LF &
      "Caps Lock = CAPS LOCK, Page Up = SHIFT LOCK, Backspace / Delete = " &
      "DELETE," & ASCII.LF &
      "` = pound sign.  Shift+F12 = SHIFT+BREAK (boot a disc), " &
      "Ctrl+F12 = CTRL+BREAK." & ASCII.LF &
      "Joystick: keypad 8/2/4/6 (diagonals 7/9/1/3), fire = keypad 0/5/Enter.");

end Keyboard;
