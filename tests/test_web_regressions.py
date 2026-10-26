"""Portable JS regression plus source contracts; does not compile/execute iOS code."""
import json, os, pathlib, re, shutil, subprocess, unittest
SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'app/Source/ATLWebServer.m'
NODE = os.environ.get('NODE_BINARY') or shutil.which('node') or r'C:\Users\jjun\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
class WebRegression(unittest.TestCase):
    def test_public_running_atomicity_matches_extension(self):
        header=SOURCE.with_suffix('.h').read_text(encoding='utf-8')
        self.assertIn('@property (atomic, readonly, assign, getter=isRunning)',header)
    def setUp(self): self.s = SOURCE.read_text(encoding='utf-8')
    def test_filename_dom_behavior(self):
        block = self.s.split('NSString *html =',1)[1].split('return [html',1)[0]
        html = ''.join(json.loads('"'+x+'"') for x in re.findall(r'@"((?:\\.|[^"\\])*)"', block))
        js = html.split('<script>')[1].split('</script>')[0]
        harness = """const assert=require('assert');const nodes={};function elem(tag){return {tag,children:[],appendChild(x){this.children.push(x)},set innerHTML(v){assert.equal(v,'');this.children=[]}}}global.document={getElementById(id){return nodes[id]||(nodes[id]=elem(id))},createElement:elem};const evil='<img src=x onerror=alert(1)>.at';global.fetch=async()=>({json:async()=>[evil]});"""
        harness += js + "\nsetTimeout(()=>{const a=nodes.list.children[0].children[0];assert.equal(a.tag,'a');assert.equal(a.textContent,evil);assert(a.href.includes(encodeURIComponent(evil)))},0);"
        result = subprocess.run([NODE,'-e',harness],capture_output=True,text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_decode_and_controls_contract(self):
        self.assertNotIn('[q[@"name"] stringByRemovingPercentEncoding]',self.s)
        self.assertIn('controlCharacterSet',self.s)
    def test_body_framing_contract(self):
        self.assertIn('duplicate content-length',self.s)
        self.assertIn('transfer-encoding',self.s)
        self.assertIn('short body',self.s)
        self.assertNotIn('.longLongValue',self.s)
    def test_deadline_and_capacity_contract(self):
        for marker in ['dispatch_semaphore_create(6)','ATLRequestSeconds = 10','poll(', 'SO_RCVTIMEO','SO_SNDTIMEO','SO_NOSIGPIPE','MSG_DONTWAIT','CLOCK_MONOTONIC']:
            self.assertIn(marker,self.s)
    def test_ownership_and_thread_failure_contract(self):
        self.assertNotIn('__unsafe_unretained',self.s)
        self.assertIn('__bridge_retained',self.s)
        self.assertIn('__bridge_transfer',self.s)
        self.assertRegex(self.s,r'if \(pthread_create\(')
        self.assertIn('dispatch_semaphore_signal',self.s)
    def test_atomic_running_accessor_contract(self):
        """The public isRunning selector must use the atomic synthesized getter."""
        self.assertIn('@property (atomic, assign, getter=isRunning) BOOL running;', self.s)
        self.assertNotRegex(self.s, r'-\s*\(BOOL\)isRunning\s*\{')
    def test_listener_readiness_contract(self):
        """Source contract: stale poll readiness cannot cause blocking accept."""
        start = self.s.split('- (BOOL)start {', 1)[1]
        listener = self.s.split('static void *ATLServerThread', 1)[1].split('- (BOOL)start', 1)[0]
        self.assertIn('fcntl(fd, F_GETFL, 0)', start)
        self.assertIn('fcntl(fd, F_SETFL, flags | O_NONBLOCK)', start)
        self.assertLess(start.index('F_SETFL'), start.index('listen(fd,'))
        self.assertIn('if (!(p.revents & POLLIN))', listener)
        self.assertLess(listener.index('if (!(p.revents & POLLIN))'), listener.index('accept(listener,'))
        self.assertIn('errno == EAGAIN || errno == EWOULDBLOCK', listener)
if __name__=='__main__': unittest.main()
