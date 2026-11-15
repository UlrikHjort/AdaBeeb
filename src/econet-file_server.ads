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
--  The Econet file server built into AdaBeeb (station 254): the Acorn
--  file server protocol as the BBC's NFS uses it (command line, LOAD /
--  SAVE, catalogue, files opened for random access, object information)
--  on a folder of the host.  Load and execution addresses are kept in
--  "<name>.inf" files beside the data ("NAME LLLLLLLL EEEEEEEE").
--  Every user name is accepted without a password and gets the folder's
--  root as its user root; a "Library" directory there is the library.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package Econet.File_Server is

   Root : Unbounded_String;
   --  The folder served (created if missing).

   procedure Receive (M : Message);
   --  A message for station 254.

   procedure Reset;
   --  Forget logins and open files (after writing them back).

end Econet.File_Server;
