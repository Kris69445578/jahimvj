#!/bin/bash
# install.sh — FastSSH-compatible SSH tunnel server on Ubuntu 22.04
# Run as root: sudo bash install.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
CYN='\033[1;36m'; MAG='\033[1;35m'; NC='\033[0m'

# ──────────────────────────────────────────────────────────────────────────────
# BRAND CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
BRAND_BANNER='<center><font color="#00FFFF">✔JAHIMtech</font></center>'
BRAND_SAFE='JAHIMtech'

print_header() {
    echo -e "${CYN}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       FastSSH-Compatible Tunnel Setup        ║"
    echo "  ║              ${MAG}✔JAHIMtech${CYN}                     ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}
print_header

echo "== updating packages =="
apt update -y
# vnstat + iptables back the bandwidth counters shown in the menu.
apt install -y dropbear openssh-server python3 stunnel4 curl cron git \
               build-essential certbot cmake ufw vnstat iptables

INSTALL_DIR="/opt/sshpanel"
mkdir -p "$INSTALL_DIR"
mkdir -p /etc/sshpanel /etc/sshpanel/usage /etc/sshpanel/quota

echo "$BRAND_BANNER" > /etc/sshpanel/brand.txt
echo "$BRAND_SAFE"   > /etc/sshpanel/brand_safe.txt

# ──────────────────────────────────────────────────────────────────────────────
# FIX 1: Free port 80
# ──────────────────────────────────────────────────────────────────────────────
echo "== freeing port 80 =="
systemctl stop  apache2 2>/dev/null && systemctl disable apache2 2>/dev/null || true
systemctl stop  nginx   2>/dev/null && systemctl disable nginx   2>/dev/null || true
fuser -k 80/tcp 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# FIX 2: Open firewall ports
# ──────────────────────────────────────────────────────────────────────────────
echo "== configuring firewall =="
ufw allow 22/tcp   comment 'OpenSSH'
ufw allow 109/tcp  comment 'Dropbear SSH'
ufw allow 80/tcp   comment 'wsproxy HTTP/WS'
ufw allow 443/tcp  comment 'stunnel4 TLS'
ufw --force enable
echo -e "${GRN}[✓] Firewall: ports 22, 80, 109, 443 open${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# FIX 3: Register /bin/false in /etc/shells
# PAM rejects logins when the user's shell is not in /etc/shells — this causes
# "Incorrect user name or password" even when the password is correct.
# ──────────────────────────────────────────────────────────────────────────────
echo "== registering /bin/false in /etc/shells =="
grep -qxF '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells
echo -e "${GRN}[✓] /bin/false added to /etc/shells${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# Cloudflare domain prompt
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YEL}  CLOUDFLARE SETUP (enables 'any CF bughost' feature)${NC}"
echo -e "${YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}  Step 1:${NC} Add your domain to Cloudflare (free plan OK)"
echo -e "${GRN}  Step 2:${NC} DNS A record → this VPS IP, orange cloud ON (Proxied)"
echo -e "${GRN}  Step 3:${NC} Cloudflare dashboard → Network → WebSockets → ON"
echo ""
read -rp "Enter your Cloudflare domain (e.g. konami.chickenkiller.com) or blank to skip: " CF_DOMAIN < /dev/tty

if [ -n "$CF_DOMAIN" ]; then
    echo "$CF_DOMAIN" > /etc/sshpanel/cf_domain.txt
    echo -e "${GRN}[✓] Cloudflare domain saved: $CF_DOMAIN${NC}"
    LE_EMAIL="wamitiantony297@gmail.com"
    SSL_DOMAIN="$CF_DOMAIN"
else
    echo -e "${YEL}[!] Skipped. Set it later: manage-ssh set-cf-domain${NC}"
    SSL_DOMAIN=""
    LE_EMAIL=""
fi
echo -e "${YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

[ -z "$LE_EMAIL" ] && SSL_DOMAIN=""

# ──────────────────────────────────────────────────────────────────────────────
# FIX 4: OpenSSH hardening for tunnel accounts
# ──────────────────────────────────────────────────────────────────────────────
echo "== configuring OpenSSH for tunnel accounts =="
SSHD_CONF="/etc/ssh/sshd_config"
sed -i 's/^#*\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' "$SSHD_CONF"
grep -q "^PasswordAuthentication" "$SSHD_CONF" || echo "PasswordAuthentication yes" >> "$SSHD_CONF"
sed -i 's/^#*\s*AllowTcpForwarding\s.*/AllowTcpForwarding yes/' "$SSHD_CONF"
grep -q "^AllowTcpForwarding" "$SSHD_CONF" || echo "AllowTcpForwarding yes" >> "$SSHD_CONF"
sed -i 's/^#*\s*PermitEmptyPasswords\s.*/PermitEmptyPasswords no/' "$SSHD_CONF"
sed -i 's/^#*\s*UsePAM\s.*/UsePAM yes/' "$SSHD_CONF"
grep -q "^UsePAM" "$SSHD_CONF" || echo "UsePAM yes" >> "$SSHD_CONF"
echo -e "${GRN}[✓] OpenSSH: PasswordAuthentication yes, AllowTcpForwarding yes${NC}"
systemctl enable ssh
systemctl restart ssh

# ──────────────────────────────────────────────────────────────────────────────
# Dropbear — SSH-2.0-dropbear backend on port 109
# ──────────────────────────────────────────────────────────────────────────────
DROPBEAR_PORT=109
sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear 2>/dev/null || true
if grep -q "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null; then
    sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$DROPBEAR_PORT/" /etc/default/dropbear
else
    echo "DROPBEAR_PORT=$DROPBEAR_PORT" >> /etc/default/dropbear
fi

cat > /etc/sshpanel/banner.txt << 'BANNEREOF'
<center><font color="#00FFFF">✔JAHIMtech</font></center>
<center><font color="#FFFF00">Premium Private SSH Tunnel</font></center>
<center>──────────────────────────────</center>
<center><font color="#00FF00">Connection established. Enjoy!</font></center>
BANNEREOF

if grep -q "^DROPBEAR_EXTRA_ARGS" /etc/default/dropbear 2>/dev/null; then
    sed -i 's|^DROPBEAR_EXTRA_ARGS=.*|DROPBEAR_EXTRA_ARGS="-b /etc/sshpanel/banner.txt"|' /etc/default/dropbear
else
    echo 'DROPBEAR_EXTRA_ARGS="-b /etc/sshpanel/banner.txt"' >> /etc/default/dropbear
fi
systemctl enable dropbear
systemctl restart dropbear
echo -e "${GRN}[✓] Dropbear running on port $DROPBEAR_PORT${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# wsproxy — FastSSH-compatible HTTP/WS front door on port 80
# ──────────────────────────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/wsproxy.py" "$INSTALL_DIR/"

cat > /etc/systemd/system/wsproxy.service << SVCEOF
[Unit]
Description=WS/CONNECT proxy -> local SSH (FastSSH-compatible) - ${BRAND_SAFE}
After=network.target dropbear.service
Wants=dropbear.service

[Service]
ExecStart=/usr/bin/python3 /opt/sshpanel/wsproxy.py --listen-port 80 --ssh-port ${DROPBEAR_PORT} --brand "Switching Protocols"
Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable wsproxy
systemctl restart wsproxy

sleep 2
if ss -tlnp | grep -q ':80 '; then
    echo -e "${GRN}[✓] wsproxy listening on port 80${NC}"
else
    echo -e "${RED}[!] wsproxy NOT on port 80 — check: journalctl -u wsproxy -n 50${NC}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# TLS cert for stunnel
# ──────────────────────────────────────────────────────────────────────────────
if [ -n "$SSL_DOMAIN" ]; then
    echo "== requesting Let's Encrypt cert for $SSL_DOMAIN =="
    systemctl stop wsproxy 2>/dev/null || true
    certbot certonly --standalone --preferred-challenges http \
        -d "$SSL_DOMAIN" --agree-tos --non-interactive -m "$LE_EMAIL" || true
    systemctl start wsproxy 2>/dev/null || true
    CERT_FILE="/etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem"
    KEY_FILE="/etc/letsencrypt/live/$SSL_DOMAIN/privkey.pem"
else
    mkdir -p /etc/stunnel
    if [ ! -f /etc/stunnel/sshpanel.pem ]; then
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout /etc/stunnel/sshpanel.pem \
            -out    /etc/stunnel/sshpanel.pem \
            -days 3650 \
            -subj "/CN=$(hostname -I | awk '{print $1}')"
    fi
    CERT_FILE="/etc/stunnel/sshpanel.pem"
    KEY_FILE="/etc/stunnel/sshpanel.pem"
fi

# ──────────────────────────────────────────────────────────────────────────────
# stunnel4 — TLS wrapper on port 443
#
# FIX: stunnel4 must forward to wsproxy:80 (NOT directly to Dropbear:109).
# When the SSL checkbox is enabled in HTTP Custom, the app sends its full
# payload (CONNECT or WebSocket upgrade) over TLS.  That payload is HTTP —
# Dropbear cannot understand it.  wsproxy must sit in the middle so it can
# parse the HTTP payload and then connect to Dropbear.
#
# Correct flow:
#   HTTP Custom --TLS--> stunnel4:443 --> wsproxy:80 --> Dropbear:109
#
# Wrong flow (old):
#   HTTP Custom --TLS--> stunnel4:443 --> Dropbear:109   ← Dropbear sees HTTP garbage
# ──────────────────────────────────────────────────────────────────────────────
mkdir -p /etc/stunnel
mkdir -p /etc/systemd/system/stunnel4.service.d

cat > /etc/systemd/system/stunnel4.service.d/override.conf << 'DROPINEOF'
[Service]
User=root
Group=root
ExecStart=
ExecStart=/usr/bin/stunnel4 /etc/stunnel/sshpanel.conf
DROPINEOF

cat > /etc/stunnel/sshpanel.conf << STUNNELEOF
; JAHIMtech stunnel4 — TLS wrapper on port 443
; Forwards decrypted traffic to wsproxy:80 which handles the HTTP payload
; and tunnels to Dropbear:109.  Do NOT connect directly to Dropbear here.
foreground = no
output     = /var/log/stunnel4.log

cert = $CERT_FILE
key  = $KEY_FILE

[ssh-tls]
accept  = 443
connect = 127.0.0.1:80
STUNNELEOF

if [ -f /etc/default/stunnel4 ]; then
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
else
    echo "ENABLED=1" > /etc/default/stunnel4
fi

systemctl daemon-reload
systemctl enable stunnel4
if systemctl restart stunnel4 2>/dev/null; then
    echo -e "${GRN}[✓] stunnel4 running on port 443 → wsproxy:80 → Dropbear:109${NC}"
else
    echo -e "${YEL}[!] stunnel4 failed — SSL (port 443) unavailable (HTTP on port 80 still works).${NC}"
    echo -e "${YEL}    Diagnose: journalctl -u stunnel4 -n 30  or  cat /var/log/stunnel4.log${NC}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# badvpn-udpgw on 127.0.0.1:7300
# ──────────────────────────────────────────────────────────────────────────────
if ! command -v badvpn-udpgw &>/dev/null; then
    echo "== building badvpn-udpgw =="
    (
        cd /tmp
        rm -rf badvpn
        git clone --depth 1 https://github.com/ambrop72/badvpn.git
        mkdir -p badvpn/badvpn-build && cd badvpn/badvpn-build
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
        make
        cp udpgw/badvpn-udpgw /usr/local/bin/
    )
fi

cat > /etc/systemd/system/udpgw.service << 'UDPEOF'
[Unit]
Description=badvpn-udpgw
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UDPEOF

systemctl daemon-reload
systemctl enable udpgw
systemctl restart udpgw

# ──────────────────────────────────────────────────────────────────────────────
# Management tools
# ──────────────────────────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/manage-ssh.sh" /usr/local/bin/manage-ssh
chmod +x /usr/local/bin/manage-ssh
cp "$SCRIPT_DIR/menu.sh" /usr/local/bin/menu
chmod +x /usr/local/bin/menu

(
    crontab -l 2>/dev/null | grep -v manage-ssh
    echo "0 * * * * /usr/local/bin/manage-ssh purge-expired >> /var/log/sshpanel-purge.log 2>&1"
) | crontab -

# ──────────────────────────────────────────────────────────────────────────────
# Final summary
# ──────────────────────────────────────────────────────────────────────────────
HOST_IP="$(hostname -I | awk '{print $1}')"
CF_DOMAIN_VAL="$(cat /etc/sshpanel/cf_domain.txt 2>/dev/null || echo '<not set — run: manage-ssh set-cf-domain>')"

echo ""
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYN}  ✔JAHIMtech — Installation Complete${NC}"
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GRN}VPS IP  :${NC} $HOST_IP"
echo ""
echo -e "${YEL}── Service status ───────────────────────────────────────${NC}"
for svc in dropbear wsproxy stunnel4 udpgw; do
    STATUS="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    [ "$STATUS" = "active" ] \
        && echo -e "  ${GRN}[✓]${NC} $svc" \
        || echo -e "  ${RED}[✗]${NC} $svc ($STATUS) — journalctl -u $svc -n 30"
done
echo ""
echo -e "${YEL}── Traffic flow ─────────────────────────────────────────${NC}"
echo -e "  HTTP  :  client → wsproxy:80 → Dropbear:109"
echo -e "  HTTPS :  client → stunnel4:443 → wsproxy:80 → Dropbear:109"
echo ""
echo -e "${YEL}── CF-RAY payload ───────────────────────────────────────${NC}"
echo -e "${GRN}CF Domain    :${NC} $CF_DOMAIN_VAL"
echo "  GET /cdn-cgi/trace HTTP/1.1[crlf]Host:${CF_DOMAIN_VAL}[crlf][crlf]CF-RAY / HTTP/1.1[crlf]Host: ${CF_DOMAIN_VAL}[crlf]Upgrade: Websocket[crlf]Connection: Keep-Alive[crlf][crlf]"
echo ""
echo -e "${YEL}── CONNECT payload ──────────────────────────────────────${NC}"
echo -e "${GRN}Remote Proxy :${NC} $HOST_IP:80  (HTTP)  or  $HOST_IP:443  (SSL)"
echo "  CONNECT [host]:[port] HTTP/1.1[crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]"
echo ""
echo -e "${CYN}  Create first account :  manage-ssh create${NC}"
echo -e "${CYN}  Management menu      :  menu${NC}"
echo -e "${CYN}════════════════════════════════════════════════════════${NC}"
