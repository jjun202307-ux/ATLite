"""Exercise real Mach-O parser with synthetic load commands/signatures."""
import importlib.util, pathlib, plistlib, struct, unittest
root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('artifact',root/'tools/verify_artifact.py')
mod=importlib.util.module_from_spec(spec)
import sys
sys.path.insert(0,str(root/'tools'))
spec.loader.exec_module(mod)

class ArtifactMachO(unittest.TestCase):
    def test_signature_is_parsed_not_string_searched(self):
        self.assertTrue(hasattr(mod,'macho_slices'),'real Mach-O parser missing')
        xml=plistlib.dumps({'platform-application':True})
        ent=struct.pack('>II',0xfade7171,len(xml)+8)+xml
        signature=struct.pack('>IIIII',0xfade0cc0,20+len(ent),1,5,20)+ent
        header=struct.pack('<8I',0xfeedfacf,0x100000c,2,2,1,16,0,0)
        command=struct.pack('<4I',0x1d,16,48,len(signature))
        parsed=mod.macho_slices(header+command+signature)
        self.assertEqual(parsed[0]['subtype'],2)
        self.assertIs(parsed[0]['entitlements']['platform-application'],True)
        no_sig=struct.pack('<8I',0xfeedfacf,0x100000c,0,2,0,0,0,0)+xml
        self.assertEqual(mod.macho_slices(no_sig)[0]['entitlements'],{})

    def test_truncation_is_rejected(self):
        self.assertTrue(hasattr(mod,'macho_slices'),'real Mach-O parser missing')
        with self.assertRaises(ValueError): mod.macho_slices(b'\xcf\xfa\xed\xfe')

if __name__=='__main__': unittest.main()
