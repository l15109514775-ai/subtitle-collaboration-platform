from pathlib import Path
import select
import socketserver
import sys
import threading

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'runtime'))
import paramiko

client = paramiko.SSHClient()
client.load_host_keys(str(ROOT / 'access' / 'known_hosts'))
client.set_missing_host_key_policy(paramiko.RejectPolicy())
connect_lock = threading.Lock()

def connected_transport():
    with connect_lock:
        transport = client.get_transport()
        if transport is None or not transport.is_active() or not transport.is_authenticated():
            client.close()
            client.connect('SERVER_IP', username='ubuntu',
                           key_filename=str(ROOT / 'access' / 'dashboard_tunnel'),
                           look_for_keys=False, allow_agent=False, compress=True,
                           timeout=20, banner_timeout=20, auth_timeout=20)
            transport = client.get_transport()
            transport.set_keepalive(15)
        return transport

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            transport = connected_transport()
            channel = transport.open_channel('direct-tcpip', ('127.0.0.1', 6185), self.client_address, timeout=20)
        except Exception as exc:
            print('Tunnel connection failed:', type(exc).__name__, flush=True)
            return
        if channel is None:
            return
        try:
            while True:
                ready, _, _ = select.select([self.request, channel], [], [], 30)
                if self.request in ready:
                    data = self.request.recv(65536)
                    if not data:
                        break
                    channel.sendall(data)
                if channel in ready:
                    data = channel.recv(65536)
                    if not data:
                        break
                    self.request.sendall(data)
                if not transport.is_active():
                    break
        except (OSError, paramiko.SSHException):
            pass
        finally:
            channel.close()

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

try:
    with Server(('127.0.0.1', 6185), Handler) as server:
        print('Encrypted dashboard tunnel ready: http://127.0.0.1:6185', flush=True)
        server.serve_forever()
finally:
    client.close()
