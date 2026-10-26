"""Email job Objective-C source contracts; not an iOS execution test."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class EmailJobContract(unittest.TestCase):
    def test_shared_state_and_lock_contract(self):
        s=(ROOT/'shared/ATLEmailJob.m').read_text(encoding='utf-8')
        for marker in ['LOCK_EX | LOCK_NB','email-job.json','pending','processing','done','error','cancelled','NSDataWritingAtomic','409','ATLEmailClaimJob','ATLEmailFinishJob','ATLEmailCancelJob']:
            self.assertIn(marker,s)
        self.assertNotIn('LOCK_EX)',s)
        self.assertIn('ATLEmailMaxJSON',s)
        self.assertIn('controlCharacterSet',s)
        self.assertIn('100',s)
        self.assertIn('2048',s)
    def test_routes_contract(self):
        s=(ROOT/'app/Source/ATLWebServer.m').read_text(encoding='utf-8')
        for marker in ['@"/api/job"','@"/api/result"','ATLEmailCreateJob','ATLEmailReadJob','ATLEmailCancelJob','q[@"jobId"]','202']:
            self.assertIn(marker,s)
    def test_exception_safe_descriptors_contract(self):
        s=(ROOT/'shared/ATLEmailJob.m').read_text(encoding='utf-8')
        # One finally for each public acquired lock and one for the read fd.
        self.assertEqual(s.count('@finally { ATLEmailUnlock(fd); }'), 5)
        self.assertIn('@finally { close(fd); }',s)
        self.assertNotIn('ATLEmailUnlock(fd); return',s)
if __name__=='__main__': unittest.main()
