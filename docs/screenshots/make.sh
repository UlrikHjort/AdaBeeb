#!/bin/sh
# Regenerates the emulated-screen screenshots for the README (the GUI and
# Forge window shots are taken by hand).  Needs the ROMs in roms/.
cd "$(dirname "$0")/../.." || exit 1
D=docs/screenshots
B=bin/adabeeb
$B --b --headless 300 $D/src/teletext.bas --png $D/teletext.png
$B --b --headless 5000 $D/src/sunburst.bas --png $D/mode2.png
$B --b --headless 14000 $D/src/hat.bas --png $D/mode1.png
$B --master --headless 400 --type 'CLS:PRINT "BBC Master 128 - sideways ROMs:"\n*HELP\n' --png $D/master.png
$B --b --tube --headless 700 --type 'PRINT "PAGE ";PAGE;", HIMEM ";HIMEM\nPRINT HIMEM-PAGE;" bytes free"\n' --png $D/tube.png
$B --b --z80 --headless 400 --png $D/z80.png
fs=$(mktemp -d)
mkdir "$fs/Library"
$B --b --econet 5 --econet-dir "$fs" --headless 2500 --type '*NET\n*I AM GUEST\n10 PRINT "HELLO"\nSAVE "HELLO"\nSAVE "GAME"\n*CDIR DEMOS\nSAVE "DEMOS.SPIRAL"\n*CAT\n*INFO HELLO\n' --png $D/econet.png
rm -rf "$fs"
