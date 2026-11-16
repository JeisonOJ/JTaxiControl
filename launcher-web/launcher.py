"""Local-only compiled web launcher. No database calls or third-party packages."""
import argparse
import functools
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = Path(__file__).resolve().parent
WEB = HERE / 'web'
STATE = HERE / 'server-state.json'
HOST, PORT = '127.0.0.1', 8765
URL = f'http://{HOST}:{PORT}/'
APP = 'JTaxiControl-local-build4-v1'

def request(method='GET', path='/_jtaxi/status', token=None):
    c = http.client.HTTPConnection(HOST, PORT, timeout=3)
    try:
        c.request(method, path, headers={'X-JTaxi-Stop': token} if token else {})
        r = c.getresponse()
        body = r.read()
        if r.status != 200:
            raise RuntimeError(f'Respuesta HTTP {r.status}')
        return json.loads(body)
    finally:
        c.close()

def probe():
    try:
        data = request()
        return data if data.get('app') == APP else None
    except Exception:
        return None

def validate():
    expected = json.loads((HERE / 'web-files.json').read_text(encoding='utf-8'))
    for name, digest in expected.items():
        p = WEB / name
        if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Faltan archivos de la web o fueron cambiados. Restaura la carpeta launcher-web/web del build 4.')

def edge():
    for base in (os.environ.get('PROGRAMFILES(X86)', ''), os.environ.get('PROGRAMFILES', '')):
        p = Path(base) / 'Microsoft/Edge/Application/msedge.exe'
        if p.is_file():
            subprocess.Popen([str(p), URL], creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            return
    raise RuntimeError('No se encontró Microsoft Edge. Instálalo o abre manualmente ' + URL)

def stop():
    if not STATE.is_file():
        raise RuntimeError('No hay un servidor de JTaxiControl registrado para cerrar.')
    state = json.loads(STATE.read_text(encoding='utf-8'))
    live = probe()
    if not live or live.get('instance') != state.get('instance'):
        raise RuntimeError('El puerto no corresponde al servidor registrado. No se detuvo ningún otro programa.')
    request('POST', '/_jtaxi/stop', state['token'])

class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def list_directory(self, _):
        self.send_error(404)

    def json_response(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

    def do_GET(self):
        if self.path == '/_jtaxi/status':
            self.json_response({'app': APP, 'instance': self.server.instance})
        else:
            super().do_GET()

    def do_POST(self):
        if self.path != '/_jtaxi/stop' or not secrets.compare_digest(self.headers.get('X-JTaxi-Stop', ''), self.server.token):
            self.send_error(403)
            return
        self.json_response({'stopping': True})
        self.server.done.set()

class LocalServer(ThreadingHTTPServer):
    allow_reuse_address = False
    def server_bind(self):
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

def run(args):
    if args.stop:
        stop()
        return
    validate()
    if probe():
        if not args.no_browser:
            edge()
        return
    try:
        server = LocalServer((HOST, PORT), functools.partial(Handler, directory=str(WEB)))
    except OSError as exc:
        # Another launch may have bound the port while this process was starting.
        for _ in range(10):
            if probe():
                if not args.no_browser:
                    edge()
                return
            time.sleep(.1)
        raise RuntimeError('El puerto 8765 está ocupado por otro programa. Ciérralo o pide ayuda; no se inició otro servidor.') from exc
    server.daemon_threads = True
    server.instance, server.token = secrets.token_hex(16), secrets.token_hex(32)
    server.done = threading.Event()
    window = None
    try:
        STATE.write_text(json.dumps({'instance': server.instance, 'token': server.token}), encoding='utf-8')
        server.timeout = .25
        def serve():
            while not server.done.is_set():
                server.handle_request()
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        if not args.headless:
            import tkinter as tk
            window = tk.Tk()
            window.title('JTaxiControl Web')
            window.geometry('420x200')
            window.resizable(False, False)
            tk.Label(window, text='JTaxiControl Web está abierto', font=('Segoe UI', 13)).pack(pady=12)
            tk.Label(window, text=URL + '\nDeja esta ventana abierta mientras usas la aplicación.\nAl terminar, confirma los pagos pendientes antes de cerrar.').pack()
            tk.Button(window, text='Cerrar servidor', command=server.done.set, width=24).pack(pady=12)
            window.protocol('WM_DELETE_WINDOW', server.done.set)
            def check():
                if server.done.is_set():
                    window.quit()
                else:
                    window.after(250, check)
            window.after(250, check)
        if not args.no_browser:
            edge()
        if window:
            window.mainloop()
        else:
            server.done.wait()
    finally:
        server.done.set()
        if 'thread' in locals():
            thread.join(timeout=3)
        server.server_close()
        if window:
            window.destroy()
        if STATE.is_file():
            try:
                if json.loads(STATE.read_text()).get('instance') == server.instance:
                    STATE.unlink()
            except (OSError, ValueError):
                pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--headless', action='store_true')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()
    try:
        run(args)
    except Exception as exc:
        message = str(exc)
        if args.headless:
            print(message, file=sys.stderr)
        else:
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, message, 'JTaxiControl Web', 16)
        if sys.stderr:
            sys.stderr.flush()
        os._exit(1)
    # All sockets, UI and state were closed in run(). Avoid native interpreter
    # finalization hanging in this Windows Python runtime after worker threads.
    if sys.stdout:
        sys.stdout.flush()
    os._exit(0)
