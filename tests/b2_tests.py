#!/usr/bin/env python3
"""Run the b2 text-output tests: each T.<name> is put on its own SSD,
CHAINed, and the O.<name> file it *SPOOLs is compared with the output
recorded on a real BBC Micro.  Usage: b2_tests.py [--master] [dir] [name]"""
import os, subprocess, sys, tempfile

root = os.path.dirname(os.path.abspath(__file__))
exe = os.path.join(root, '..', 'bin', 'adabeeb')
args = sys.argv[1:]
master = '--master' in args
args = [a for a in args if a != '--master']
folder = os.path.join(root, 'b2', args[0] if args else 'via')
only = args[1] if len(args) > 1 else None

def bbc_name(host):
    inf = host + '.inf'
    if os.path.exists(inf):
        return open(inf).read().split()[0]
    return os.path.basename(host).replace('#2e', '.')

passed = failed = 0
for f in sorted(os.listdir(folder)):
    if not f.startswith('T.') or f.endswith('.inf'):
        continue
    name = bbc_name(os.path.join(folder, f))
    if only and only not in name:
        continue
    out_name = 'O.' + name[2:]
    expected = os.path.join(folder, f.replace('T.', 'O.', 1))
    with tempfile.TemporaryDirectory() as tmp:
        ssd = os.path.join(tmp, 't.ssd')
        subprocess.run([exe, '--mkssd', ssd, os.path.join(folder, f)],
                       check=True, stdout=subprocess.DEVNULL)
        cmd = [exe, '--headless', os.environ.get('FRAMES', '5000'), '--attach', ssd,
               '--type', 'CHAIN"%s"\\n' % name, '--screen']
        if master:
            cmd.insert(1, '--master')
        screen = subprocess.run(cmd, capture_output=True, text=True).stdout
        got_path = os.path.join(tmp, 'out')
        r = subprocess.run([exe, '--get', ssd, out_name, got_path],
                           capture_output=True, text=True)
        got = open(got_path, 'rb').read() if r.returncode == 0 else None
    if not os.path.exists(expected):
        print('?    %-14s no reference output' % name)
        continue
    want = open(expected, 'rb').read()
    if got == want:
        passed += 1
        print('ok   %s' % name)
    else:
        failed += 1
        show = lambda b: 'none' if b is None else \
            b.decode('latin1').replace('\r', ' | ').strip()
        print('FAIL %-14s\n     want: %s\n     got:  %s' %
              (name, show(want)[:300], show(got)[:300]))
        if got is None:
            print('     screen:\n' + '\n'.join(
                '       ' + l for l in screen.splitlines()[:25] if l.strip()))
print('%d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
