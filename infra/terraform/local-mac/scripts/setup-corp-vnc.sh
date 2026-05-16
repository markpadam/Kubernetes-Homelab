#!/usr/bin/env bash
# Sets up XFCE4 + TigerVNC on the corp-client Multipass VM.
# Usage: setup-corp-vnc.sh <vnc-password>
set -euo pipefail

VNC_PASSWORD="${1:?usage: $0 <vnc-password>}"

echo "[vnc] Installing XFCE4 and TigerVNC..."
multipass exec corp-client -- sudo apt-get install -y -qq \
  xfce4 xfce4-goodies xfce4-terminal thunar \
  tigervnc-standalone-server dbus-x11

echo "[vnc] Setting up VNC directory..."
multipass exec corp-client -- sudo -u ubuntu mkdir -p /home/ubuntu/.vnc
multipass exec corp-client -- sudo -u ubuntu chmod 700 /home/ubuntu/.vnc

echo "[vnc] Setting VNC password..."
printf '%s\n' "${VNC_PASSWORD}" \
  | multipass exec corp-client -- sudo -u ubuntu bash -c 'vncpasswd -f > /home/ubuntu/.vnc/passwd && chmod 600 /home/ubuntu/.vnc/passwd'

echo "[vnc] Writing xstartup..."
cat > /tmp/corp-vnc-xstartup << 'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XEOF
chmod +x /tmp/corp-vnc-xstartup
multipass transfer /tmp/corp-vnc-xstartup corp-client:/tmp/xstartup
multipass exec corp-client -- sudo mv /tmp/xstartup /home/ubuntu/.vnc/xstartup
multipass exec corp-client -- sudo chown ubuntu:ubuntu /home/ubuntu/.vnc/xstartup

echo "[vnc] Installing TigerVNC systemd service..."
cat > /tmp/corp-vnc-vncserver.service << 'SEOF'
[Unit]
Description=TigerVNC server for display %i
After=syslog.target network.target

[Service]
Type=forking
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu
ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver -localhost no -geometry 1280x800 -depth 24 :%i
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure

[Install]
WantedBy=multi-user.target
SEOF
multipass transfer /tmp/corp-vnc-vncserver.service corp-client:/tmp/vncserver.service
multipass exec corp-client -- sudo mv /tmp/vncserver.service /etc/systemd/system/vncserver@.service
multipass exec corp-client -- sudo systemctl daemon-reload
multipass exec corp-client -- sudo systemctl enable vncserver@1
multipass exec corp-client -- sudo systemctl start vncserver@1

CLIENT_IP=$(multipass info corp-client --format json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['ipv4'][0])")

echo "[vnc] Desktop ready"
echo "[vnc] Connect: open vnc://${CLIENT_IP}:5901"
echo "[vnc] Password: ${VNC_PASSWORD}"
