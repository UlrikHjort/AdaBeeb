10 MODE 7:VDU 23,1,0;0;0;0;
20 FOR I%=1 TO 2:PRINT CHR$141;CHR$132;CHR$157;CHR$131;"       AdaBeeb            ";CHR$156:NEXT
30 PRINT CHR$134;"  A BBC Micro emulator written in Ada"
40 PRINT
50 FOR C%=1 TO 7:PRINT CHR$(144+C%);CHR$153;STRING$(37,CHR$255):NEXT
60 PRINT
70 PRINT CHR$130;"Model B, B+ and Master 128"
80 PRINT CHR$131;"6502 and Z80 Second Processors"
90 PRINT CHR$133;"Speech, Econet and a file server"
100 PRINT CHR$134;"Forge: assembler, BASIC, debugger"
110 PRINT CHR$135;"Teletext, character and bitmap editors"
120 PRINT
130 PRINT CHR$129;"         MODE 7 teletext"
140 GOTO 140
