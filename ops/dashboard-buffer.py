"""Loopback-only buffered HTTP adapter for the AstrBot administration tunnel."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client

class Handler(BaseHTTPRequestHandler):
    def forward(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length > 32 * 1024 * 1024:
            self.send_error(413)
            return
        data = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in {'host', 'connection', 'content-length'}}
        connection = http.client.HTTPConnection('127.0.0.1', 6187, timeout=60)
        try:
            connection.request(self.command, self.path, body=data, headers=headers)
            response = connection.getresponse()
            body = response.read()
            lines = [f'HTTP/1.1 {response.status} {response.reason}\r\n']
            for key, value in response.getheaders():
                if key.lower() not in {'connection', 'transfer-encoding', 'content-length'}:
                    lines.append(f'{key}: {value}\r\n')
            lines.extend([f'Content-Length: {len(body)}\r\n', 'Connection: close\r\n\r\n'])
            self.connection.sendall(''.join(lines).encode('latin-1') + body)
            self.close_connection = True
        except Exception:
            self.send_error(502, 'Backend unavailable')
        finally:
            connection.close()

    do_GET = forward
    do_POST = forward
    do_PUT = forward
    do_DELETE = forward
    do_PATCH = forward
    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', 6185), Handler).serve_forever()
