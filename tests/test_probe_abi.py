"""Compile actual probe pointer declarations against the WebKit SPI types.

Reference reviewed 2026-10-30:
https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/PAL/pal/spi/ios/IOKitSPIIOS.h
No device execution is claimed by this host ABI check.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProbeABI(unittest.TestCase):
    def test_compiled_webkit_signatures(self):
        cc = shutil.which('clang') or shutil.which('gcc')
        if not cc:
            self.skipTest('host C compiler unavailable')
        source = (ROOT/'probe/main.m').read_text(encoding='utf-8')
        names = ['_ATCreateDigitizer', '_ATCreateFinger', '_ATSetInt', '_ATSetFloat']
        declarations = []
        for name in names:
            match = re.search(r'static\s+[^;]*?\(\*' + name + r'\)\([^;]+;', source)
            self.assertIsNotNone(match, name)
            declarations.append(match.group(0))
        c = '''#include <stdint.h>
typedef const void *CFAllocatorRef;
typedef void *ATEventRef;
typedef long CFIndex;
typedef int boolean_t;
typedef unsigned char Boolean;
_Static_assert(sizeof(boolean_t)==4, "Mach boolean_t is 32 bit");
_Static_assert(sizeof(CFIndex)==8, "64-bit target required");
typedef ATEventRef (*Digitizer)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,boolean_t,boolean_t,uint32_t);
typedef ATEventRef (*Finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,boolean_t,boolean_t,uint32_t);
typedef void (*Integer)(ATEventRef,uint32_t,CFIndex);
typedef void (*Float)(ATEventRef,uint32_t,double);
'''+ '\n'.join(declarations)
        for name, expected in zip(names, ['Digitizer', 'Finger', 'Integer', 'Float']):
            c += f'\n_Static_assert(__builtin_types_compatible_p(__typeof__({name}), {expected}), "{name} SPI ABI mismatch");'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'abi.c'
            path.write_text(c, encoding='utf-8')
            result = subprocess.run([cc, '-std=c11', '-fsyntax-only', str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # The same compiler must reject each historical narrow declaration.
            for old, narrow in [('boolean_t, boolean_t', 'Boolean, Boolean'),
                                ('uint32_t, CFIndex);', 'uint32_t, int);')]:
                broken = c.replace(old, narrow)
                self.assertNotEqual(broken, c)
                path.write_text(broken, encoding='utf-8')
                result = subprocess.run([cc, '-std=c11', '-fsyntax-only', str(path)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, 'historical ABI mismatch was accepted')

    def test_active_root_does_not_scan_stale_bootstraps(self):
        paths = (ROOT/'app/Source/ATLPaths.m').read_text(encoding='utf-8')
        self.assertIn('libroot_get_jbroot_prefix', paths)
        self.assertNotIn('contentsOfDirectoryAtPath', paths)
        self.assertIn('[bp hasSuffix:suffix]', paths)

