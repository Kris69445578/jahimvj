#!/bin/bash
# diagnose-and-fix.sh — network-engineer grade recovery for zero-rated CONNECT
# Run as root on the VPS:  sudo bash diagnose-and-fix.sh
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "  ${GRN}[✓]${NC} $1"; }
warn() { echo -e "  ${YEL}[!]${NC} $1"; }
bad()  { echo -e "  ${RED}[✗]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo bash diagnose-and-fix.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYN}  Network engineer diagnosis + fix (v8)${NC}"
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
echo ""

# ── 1. Who owns port 80 / 109 / 443? ─────────────────────────────────────────
echo -e "${YEL}[1] Port ownership (what answers the phone?)${NC}"
for port in 80 109 443 22; do
    line="$(ss -tlnp 2>/dev/null | grep -E ":${port}\\s" || true)"
    if [ -n "$line" ]; then
        echo "  :$port  $line"
    else
        bad "port $port not listening"
    fi
done
echo ""

# ── 2. Kill anything that is NOT wsproxy on 80 ───────────────────────────────
echo -e "${YEL}[2] Free port 80 — nginx/apache/caddy MUST NOT own it${NC}"
echo "    (they answer with a plain 200 HTML page → client sees only 200 OK → timeout)"
for svc in apache2 nginx caddy lighttpd httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        warn "stopping $svc (it was holding a web port)"
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    fi
done
# Kill whatever still holds 80
fuser -k 80/tcp 2>/dev/null || true
sleep 1
ok "port 80 cleared"
echo ""

# ── 3. Dropbear must answer on 109 ───────────────────────────────────────────
echo -e "${YEL}[3] Dropbear (SSH backend on 109)${NC}"
if ! command -v dropbear >/dev/null 2>&1; then
    bad "dropbear not installed — apt install -y dropbear"
    apt-get install -y dropbear 2>/dev/null || true
fi
# Ensure config
sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear 2>/dev/null || true
if grep -q "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null; then
    sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=109/" /etc/default/dropbear
else
    echo "DROPBEAR_PORT=109" >> /etc/default/dropbear
fi
systemctl enable dropbear 2>/dev/null || true
systemctl restart dropbear
sleep 1
if ss -tlnp | grep -q ':109 '; then
    ok "dropbear listening on 109"
    # Live banner check
    BANNER="$(timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/109; head -c 64 <&3' 2>/dev/null || true)"
    if echo "$BANNER" | grep -q 'SSH-2.0'; then
        ok "banner: $(echo "$BANNER" | tr -d '\r')"
    else
        bad "no SSH banner from :109 — dropbear broken"
    fi
else
    bad "dropbear NOT on 109 — journalctl -u dropbear -n 30"
fi
echo ""

# ── 4. Firewall ──────────────────────────────────────────────────────────────
echo -e "${YEL}[4] Firewall${NC}"
apt-get install -y ufw -qq 2>/dev/null || true
ufw allow 22/tcp  comment 'OpenSSH'  2>/dev/null || true
ufw allow 80/tcp  comment 'wsproxy'  2>/dev/null || true
ufw allow 109/tcp comment 'Dropbear' 2>/dev/null || true
ufw allow 443/tcp comment 'stunnel4' 2>/dev/null || true
ufw --force enable 2>/dev/null || true
ok "ufw: 22,80,109,443 open"
echo ""

# ── 5. /bin/false + OpenSSH ──────────────────────────────────────────────────
echo -e "${YEL}[5] Login plumbing${NC}"
grep -qxF '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells
ok "/bin/false in /etc/shells"
SSHD_CONF=/etc/ssh/sshd_config
sed -i 's/^#*\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' "$SSHD_CONF"
grep -q "^PasswordAuthentication" "$SSHD_CONF" || echo "PasswordAuthentication yes" >> "$SSHD_CONF"
sed -i 's/^#*\s*AllowTcpForwarding\s.*/AllowTcpForwarding yes/' "$SSHD_CONF"
grep -q "^AllowTcpForwarding" "$SSHD_CONF" || echo "AllowTcpForwarding yes" >> "$SSHD_CONF"
systemctl restart ssh 2>/dev/null || true
ok "sshd PasswordAuthentication + AllowTcpForwarding"
echo ""

# ── 6. Deploy wsproxy v8 ─────────────────────────────────────────────────────
echo -e "${YEL}[6] Deploy wsproxy v8 (atomic dual 200+101 + SSH banner)${NC}"
mkdir -p /opt/sshpanel
if [ -f "$SCRIPT_DIR/wsproxy.py" ]; then
    cp "$SCRIPT_DIR/wsproxy.py" /opt/sshpanel/wsproxy.py
else
    bad "wsproxy.py missing next to this script"
    exit 1
fi
chmod +x /opt/sshpanel/wsproxy.py

cat > /etc/systemd/system/wsproxy.service << 'SVCEOF'
[Unit]
Description=wsproxy v8 FastSSH-compatible front door
After=network.target dropbear.service
Wants=dropbear.service

[Service]
ExecStart=/usr/bin/python3 /opt/sshpanel/wsproxy.py --listen-port 80 --ssh-port 109 --brand "Switching Protocols"
Restart=always
RestartSec=2
User=root
StandardOutput=journal
StandardError=journal
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

# stunnel → wsproxy
mkdir -p /etc/systemd/system/stunnel4.service.d /etc/stunnel
cat > /etc/systemd/system/stunnel4.service.d/override.conf << 'D'
[Service]
User=root
Group=root
ExecStart=
ExecStart=/usr/bin/stunnel4 /etc/stunnel/sshpanel.conf
D
if [ ! -f /etc/stunnel/sshpanel.pem ]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /etc/stunnel/sshpanel.pem -out /etc/stunnel/sshpanel.pem \
        -days 3650 -subj "/CN=$(hostname -I | awk '{print $1}')" 2>/dev/null || true
fi
cat > /etc/stunnel/sshpanel.conf << 'S'
foreground = no
output = /var/log/stunnel4.log
cert = /etc/stunnel/sshpanel.pem
key  = /etc/stunnel/sshpanel.pem
[ssh-tls]
accept  = 443
connect = 127.0.0.1:80
S
[ -f /etc/default/stunnel4 ] && sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 || echo ENABLED=1 > /etc/default/stunnel4

systemctl daemon-reload
systemctl enable wsproxy dropbear 2>/dev/null || true
systemctl restart dropbear
systemctl restart wsproxy
systemctl restart stunnel4 2>/dev/null || true
sleep 2
ok "wsproxy v8 deployed"
echo ""

# ── 7. Local probes (ground truth) ───────────────────────────────────────────
echo -e "${YEL}[7] Local probes (what the VPS actually sends)${NC}"

echo -e "  ${CYN}— Pure CONNECT (zero-rated payload) —${NC}"
PROBE=$(printf 'CONNECT https://wifipay.co.ke:UC19O866GH HTTP/1.1\r\nHost: https://netpap.co.ke:UC19O866GH\r\nConnection: keep-alive\r\nX-Online-Host: m.netpap.co.ke:UC19O866GH\r\n\r\n' \
    | timeout 3 nc -q 1 127.0.0.1 80 2>/dev/null | head -c 500 | tr -d '\0' || true)
echo "$PROBE" | head -25 | sed 's/^/    /'
HAS200=0; HAS101=0; HASSSH=0
echo "$PROBE" | grep -q "200 OK" && HAS200=1
echo "$PROBE" | grep -q "101" && HAS101=1
echo "$PROBE" | grep -qi "SSH-2.0" && HASSSH=1
[ "$HAS200" = 1 ] && ok "200 OK present" || bad "no 200 OK"
[ "$HAS101" = 1 ] && ok "101 Switching Protocols present (matches FastSSH)" || bad "no 101 — client will timeout"
[ "$HASSSH" = 1 ] && ok "SSH banner present in same response (prevents premature close)" || bad "no SSH banner — dropbear issue or race"

echo ""
echo -e "  ${CYN}— Who is listening on 80 now? —${NC}"
ss -tlnp | grep ':80 ' | sed 's/^/    /' || bad "nothing on 80"
echo ""

# ── 8. Public IP + remote test hint ──────────────────────────────────────────
IP="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo -e "${YEL}[8] Remote path check${NC}"
echo "  VPS public IP: $IP"
echo ""
echo "  From ANY machine with internet (or your phone via termux):"
echo -e "  ${CYN}printf 'CONNECT test HTTP/1.1\\r\\nHost: test\\r\\n\\r\\n' | nc -v $IP 80 | head -c 300${NC}"
echo ""
echo "  You MUST see both:"
echo "    HTTP/1.1 200 OK"
echo "    HTTP/1.1 101 Switching Protocols"
echo "    SSH-2.0-dropbear_..."
echo ""
echo "  If local probe is OK but remote only shows 200:"
echo "    → cloud firewall / security group is not the issue (you got 200)"
echo "    → carrier middlebox is stripping the 101, OR an upstream proxy sits on the path"
echo "    → try Remote Proxy = $IP:443 with SSL checkbox ON (stunnel path)"
echo ""

# ── 9. Why nginx/apache do NOT help ──────────────────────────────────────────
echo -e "${YEL}[9] About nginx / apache${NC}"
echo "  They do NOT help this tunnel. They steal :80 and answer with a normal"
echo "  website 200 OK (HTML). That is exactly the failure mode in your log:"
echo "    connected → HTTP/1.1 200 OK → timeout"
echo "  FastSSH works because ITS process on :80 speaks CONNECT/WS, not HTTP pages."
echo "  We keep nginx/apache stopped/disabled on purpose."
echo ""

# ── 10. HTTP Custom recipe ───────────────────────────────────────────────────
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYN}  HTTP Custom (same as working FastSSH free account)${NC}"
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
echo "  Remote Proxy : $IP:80"
echo "  Payload      :"
echo "    CONNECT https://wifipay.co.ke:UC19O866GH HTTP/1.1[crlf]Host: https://netpap.co.ke:UC19O866GH[crlf]Connection: keep-alive[crlf]X-Online-Host: m.netpap.co.ke:UC19O866GH[crlf]X-Forward-Host: m.netpap.co.ke:UC19O866GH[crlf][crlf]"
echo "  SSH host     : $IP   (or leave as is)"
echo "  SSH port     : 109"
echo "  Username/Pass: create with  manage-ssh create"
echo "  UDPGW        : 127.0.0.1:7300"
echo "  Enhanced     : try OFF first, then ON"
echo ""
echo "  Expected log:"
echo "    connected to socket $IP:80"
echo "    HTTP/1.1 200 OK"
echo "    HTTP/1.1 101 Switching Protocols"
echo "    set auto replace response"
echo "    HTTP/1.1 200 OK"
echo "    SSH-2.0-dropbear_xxxx"
echo "    ssh connected"
echo ""
echo "  Live logs on VPS while you connect:"
echo -e "  ${CYN}journalctl -u wsproxy -f${NC}"
echo ""
