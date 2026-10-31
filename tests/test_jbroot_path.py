import pathlib, shutil, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

class JBRootPath(unittest.TestCase):
    def test_canonical_injection_path_is_supported(self):
        source = (ROOT/'tweak/Tweak.xm').read_text(encoding='utf-8')
        self.assertIn('ATLRootPrefixLengthForTweakPath', source,
                      'root resolver must recognize canonical TweakInject path seen on iPhone')

    def test_production_path_parser(self):
        header=ROOT/'shared/ATLJBRootPath.h'
        self.assertTrue(header.exists(), 'missing production canonical-path parser')
        cc=shutil.which('cc')
        if not cc: self.skipTest('C compiler required')
        code=r'''#include <assert.h>
#include <string.h>
#include "ATLJBRootPath.h"
int main(void) {
 const char *root="/private/var/containers/Bundle/Application/.jbroot-8B2BCDE2B21B1630";
 char path[512];
 const char *suffixes[]={"/usr/lib/TweakInject/ATLiteTweak.dylib", "/Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib"};
 for(int i=0;i<2;i++) { strcpy(path,root); strcat(path,suffixes[i]); assert(ATLRootPrefixLengthForTweakPath(path)==strlen(root)); }
 assert(!ATLRootPrefixLengthForTweakPath(NULL));
 assert(!ATLRootPrefixLengthForTweakPath("/usr/lib/TweakInject/ATLiteTweak.dylib"));
 assert(!ATLRootPrefixLengthForTweakPath("/x/usr/lib/TweakInject/Other.dylib"));
 assert(!ATLRootPrefixLengthForTweakPath("/x/usr/lib/TweakInject/ATLiteTweak.dylib.bak"));
 return 0;
}'''
        with tempfile.TemporaryDirectory() as d:
            src=pathlib.Path(d)/'root.c'; src.write_text(code)
            binary=pathlib.Path(d)/'root'
            subprocess.run([cc,'-Wall','-Wextra','-Werror','-I',str(ROOT/'shared'),str(src),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)
