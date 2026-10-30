"""Execute real Foundation/HTTP implementation on macOS; no model copies."""
import http.client
import json
import pathlib
import selectors
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def compile_native(destination, *sources):
    command = ['clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'CoreFoundation',
               *[str(ROOT / source) for source in sources], '-o', str(destination)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS Foundation and clang')
class NativeAppFixtures(unittest.TestCase):
    def test_status_and_file_delivery(self):
        with tempfile.TemporaryDirectory() as folder:
            for source in ['tests/app_status_native.m', 'tests/app_io_native.m']:
                binary = pathlib.Path(folder) / pathlib.Path(source).stem
                compile_native(binary, source)
                result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS Foundation and clang')
class NativeHTTPIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.binary = pathlib.Path(cls.build.name) / 'http-native'
        compile_native(cls.binary, 'tests/http_native.m', 'app/Source/ATLWebServer.m', 'shared/ATLEmailJob.m')

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.folder.name)
        (self.root / 'Scripts').mkdir()
        (self.root / 'Images').mkdir()
        self.process = subprocess.Popen([str(self.binary), str(self.root)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.addCleanup(self.cleanup_server)
        self.port = self.read_line()['port']

    def read_line(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(15), 'native process response timed out')
        line = self.process.stdout.readline()
        self.assertTrue(line, 'native process exited without response')
        return json.loads(line)

    def cleanup_server(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.process.stdout.close()
        self.process.stderr.close()
        self.folder.cleanup()

    def control(self, **command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()
        return self.read_line()

    def request(self, method, path, body=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=15)
        try:
            if isinstance(body, dict):
                body = json.dumps(body).encode()
            connection.request(method, path, body=body)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def create(self, email='first@example.com'):
        status, data = self.request('PUT', '/api/job', {'email': email})
        self.assertEqual(status, 202, data)
        return json.loads(data)

    def test_email_roundtrip_and_stale_result(self):
        job = self.create()
        self.assertEqual(job['status'], 'pending')
        self.assertEqual(self.request('PUT', '/api/job', {'email': 'second@example.com'})[0], 409)
        claimed = self.control(action='claim')
        self.assertEqual(claimed['jobId'], job['jobId'])
        self.assertEqual(claimed['status'], 'processing')
        self.assertEqual(self.control(action='claim')['error'], 409)
        self.assertEqual(self.control(action='finish', jobId=job['jobId'], email=job['email'],
                                      username='alice', ocrLines=['Username: alice']), {'ok': True})
        status, data = self.request('GET', '/api/result?jobId=' + job['jobId'])
        self.assertEqual(status, 200)
        result = json.loads(data)
        self.assertEqual((result['status'], result['email'], result['username']), ('done',job['email'],'alice'))
        next_job = self.create('second@example.com')
        self.assertNotEqual(next_job['jobId'], job['jobId'])
        self.assertEqual(self.request('GET', '/api/result?jobId=' + job['jobId'])[0], 404)
        self.assertEqual(self.control(action='claim')['status'], 'processing')
        self.assertEqual(self.request('DELETE', '/api/job?jobId=' + next_job['jobId'])[0], 200)
        self.assertEqual(self.control(action='finish', jobId=next_job['jobId'], email=next_job['email'],
                                      username='late', ocrLines=[])['error'], 409)
        status, data = self.request('GET', '/api/result?jobId=' + next_job['jobId'])
        self.assertEqual((status,json.loads(data)['status']), (200,'cancelled'))

    def test_files_and_errors(self):
        self.assertEqual(self.request('PUT', '/api/put?name=sample.at', b'hello')[0], 200)
        self.assertEqual(self.request('GET', '/api/get?name=sample.at'), (200,b'hello'))
        self.assertEqual(self.request('DELETE', '/api/del?name=sample.at')[0], 200)
        self.assertFalse((self.root/'Scripts/sample.at').exists())
        self.assertEqual(self.request('DELETE', '/api/del?name=sample.at')[0], 404)
        # Turn Scripts into a file; removal under it must report an error, not OK.
        (self.root/'Scripts').rmdir()
        (self.root/'Scripts').write_text('not a directory')
        self.assertIn(self.request('DELETE', '/api/del?name=sample.at')[0], [404,500])
        for name in ['../outside.at','%2e%2e%2foutside.at','bad.txt','bad%00.at']:
            self.assertEqual(self.request('PUT', '/api/put?name='+name,b'x')[0],400,name)
        self.assertEqual(self.request('PUT','/api/job',{'email':'bad'})[0],400)

    def test_duplicate_length_rejected_on_real_socket(self):
        with socket.create_connection(('127.0.0.1',self.port),timeout=15) as stream:
            stream.sendall(b'PUT /api/put?name=bad.at HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx')
            response = stream.recv(4096)
        self.assertTrue(response.startswith(b'HTTP/1.1 400 '),response)
        self.assertFalse((self.root/'Scripts/bad.at').exists())


if __name__ == '__main__':
    unittest.main()
