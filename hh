import json
import os
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERS_FILE = os.environ.get("USERS_FILE", "users.json")
LOG_FILE = os.environ.get("LOG_FILE", "requests.jsonl")

with open(USERS_FILE) as f:
    USERS = json.load(f)

log_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path.split("?")[0] != "/user":
            return self.unknown()
        username = None
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 4096:
                raise ValueError
            username = json.loads(self.rfile.read(length))["username"]
            if not isinstance(username, str):
                raise ValueError
        except (ValueError, KeyError, TypeError):
            return self.reply("user_lookup", 400, None)
        if username not in USERS:
            return self.reply("user_lookup", 404, username)
        self.reply("user_lookup", 200, username, USERS[username])

    def unknown(self):
        self.reply("unknown_url", 404, None)

    # Toute autre méthode (GET, PUT, DELETE, ...) = URL inconnue
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.unknown
        raise AttributeError(name)

    def reply(self, event, status, username, data=None):
        body = json.dumps(data).encode() if data is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "ip": self.headers.get("X-Real-IP", self.client_address[0]),
            "method": self.command,
            "path": self.path.split("?")[0],
            "username": username,
            "status": status,
        }
        with log_lock, open(LOG_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def log_message(self, *args):  # pas de log texte sur stderr
        pass


ThreadingHTTPServer(("127.0.0.1", 8000), Handler).serve_forever()























[Unit]
Description=user-api (Python stdlib)
After=network.target

[Service]
Type=exec
User=user-api
Group=user-api
WorkingDirectory=/opt/user-api
Environment=USERS_FILE=/opt/user-api/users.json
Environment=LOG_FILE=/var/log/user-api/requests.jsonl
ExecStart=/usr/bin/python3 -I -B /opt/user-api/app.py
Restart=on-failure
RestartSec=2

# Seul endroit inscriptible : /var/log/user-api (créé par systemd)
LogsDirectory=user-api
LogsDirectoryMode=0750
UMask=0077

# Système de fichiers
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectProc=invisible
ProcSubset=pid
NoExecPaths=/
ExecPaths=/usr

# Noyau / système
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
PrivateIPC=yes
PrivateUsers=yes

# Privilèges
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RemoveIPC=yes

# Réseau : écoute uniquement 127.0.0.1:8000, ne parle qu'à localhost
RestrictAddressFamilies=AF_INET AF_UNIX
IPAddressDeny=any
IPAddressAllow=localhost
SocketBindDeny=any
SocketBindAllow=tcp:8000

# Appels système
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM

# Ressources
MemoryMax=256M
TasksMax=32
LimitNOFILE=1024

[Install]
WantedBy=multi-user.target







server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
