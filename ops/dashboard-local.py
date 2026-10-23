"""Serve official static dashboard files locally; API stays on the SSH tunnel."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import http.client

ROOT = Path(__file__).resolve().parent / 'dashboard-static' / 'dist'

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def proxy(self):
        size = int(self.headers.get('Content-Length', '0'))
        data = self.rfile.read(size) if size else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in {'host', 'connection', 'accept-encoding', 'content-length'}}
        connection = http.client.HTTPConnection('127.0.0.1', 6185, timeout=60)
        try:
            connection.request(self.command, self.path, body=data, headers=headers)
            response = connection.getresponse()
            body = response.read()
            response_headers = response.getheaders()
            status = response.status
            self.send_response(status)
            for key, value in response_headers:
                if key.lower() not in {'connection', 'transfer-encoding', 'content-length'}:
                    self.send_header(key, value)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:
            print('API connection failed:', type(exc).__name__, flush=True)
            try:
                self.send_error(502, 'Dashboard tunnel unavailable')
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
        finally:
            connection.close()

    def do_GET(self):
        if self.path.startswith('/api/'):
            self.proxy()
        else:
            super().do_GET()

    def do_POST(self):
        self.proxy()

    def do_PUT(self):
        self.proxy()

    def do_DELETE(self):
        self.proxy()

    def log_message(self, format, *args):
        pass  # Avoid recording account or configuration requests.

print('Local dashboard ready: http://127.0.0.1:6186', flush=True)
ThreadingHTTPServer(('127.0.0.1', 6186), Handler).serve_forever()
