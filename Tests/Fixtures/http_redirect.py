from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_HEAD(self): self.handle_request(False)
 def do_GET(self): self.handle_request(True)
 def handle_request(self,body):
  redirects={'/redirect':'/file','/loop':'/loop','/cross':f'http://localhost:{self.server.server_port}/inspect'}
  if self.path in redirects:
   self.send_response(302);self.send_header('Location',redirects[self.path]);self.send_header('Content-Length','0');self.end_headers();return
  if self.path=='/missing':
   self.send_response(302);self.send_header('Content-Length','0');self.end_headers();return
  data=json.dumps({'cookie':self.headers.get('Cookie'),'authorization':self.headers.get('Authorization')}).encode() if self.path=='/inspect' else b'<html>Login</html>' if self.path.startswith('/html') else b'file-bytes-verified'
  self.send_response(200);self.send_header('Content-Type','text/html' if self.path=='/html' else 'application/octet-stream');self.send_header('Content-Length',str(len(data)));self.end_headers()
  if body:self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
