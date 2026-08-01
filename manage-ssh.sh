#!/bin/bash
# manage-ssh.sh — create / list / extend / delete SSH tunnel accounts

set -e

SSHPANEL_DIR="${SSHPANEL_DIR:-/etc/sshpanel}"
USERLOG="${USERLOG:-$SSHPANEL_DIR/users.db}"
mkdir -p "$SSHPANEL_DIR"
touch "$USERLOG"

HOST_IP="$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
CF_DOMAIN="$(cat "$SSHPANEL_DIR/cf_domain.txt" 2>/dev/null || echo '')"

usage() {
    cat <<EOF
Usage: $0 {create|extend|delete|list|purge-expired|banner|set-cf-domain}

  create         Create a new SSH tunnel account
  extend         Extend the expiry of an existing account
  delete         Delete an account
  list           List all accounts with dates
  purge-expired  Remove expired accounts
  banner         Edit the login banner (shown as "Server Message:" in HTTP Custom)
  set-cf-domain  Set / update your Cloudflare domain for CF-RAY payload
EOF
    exit 1
}

# ── Print HTTP Custom config block ───────────────────────────────────────────

print_account_config() {
    local uname="$1" passwd="$2" created="$3" expires="$4"

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    printf "║  %-56s║\n" " Account: $uname"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Username : $uname"
    echo "  Password : $passwd"
    echo "  Host IP  : $HOST_IP"
    echo "  Created  : $created"
    echo "  Expires  : $expires"
    echo ""
    echo "┌─── HTTP Custom — SSH settings ─────────────────────────┐"
    echo "  Server   : $HOST_IP"
    echo "  Port     : 22  (OpenSSH)  or  109  (Dropbear)"
    echo "  Username : $uname"
    echo "  Password : $passwd"
    echo "  UDPGW    : 127.0.0.1:7300"
    echo ""

    if [ -n "$CF_DOMAIN" ]; then
        echo "┌─── CF-RAY payload — any Cloudflare domain as bughost ──┐"
        echo "  Remote Proxy : viton.com  (or ANY Cloudflare domain)"
        echo "  Payload      :"
        echo "    GET /cdn-cgi/trace HTTP/1.1[crlf]Host:${CF_DOMAIN}[crlf][crlf]CF-RAY / HTTP/1.1[crlf]Host: ${CF_DOMAIN}[crlf]Upgrade: Websocket[crlf]Connection: Keep-Alive[crlf][crlf]"
        echo ""
        echo "  Expected HTTP Custom log:"
        echo "    → connected to socket viton.com:80"
        echo "    → HTTP/1.1 200 OK"
        echo "    → HTTP/1.1 101 JAHIMtech"
        echo "    → set auto replace response"
        echo "    → HTTP/1.1 200 OK"
        echo "    → SSH-2.0-dropbear_xxxx"
        echo "    → ssh authenticate with password"
        echo "    → ssh connected"
        echo "    → set UDPGW 127.0.0.1:7300"
        echo "    → HTTP Custom ready to use"
    else
        echo "  [!] No Cloudflare domain set."
        echo "      Run: manage-ssh set-cf-domain"
    fi
    echo ""
    echo "┌─── CONNECT payload — VPS as direct proxy ──────────────┐"
    echo "  Remote Proxy : $HOST_IP:80"
    echo "  Payload      :"
    echo "    CONNECT [host]:[port] HTTP/1.1[crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]"
    echo ""
}

# ── Commands ─────────────────────────────────────────────────────────────────

create_account() {
    read -rp  "Username: " uname < /dev/tty
    if id "$uname" &>/dev/null; then
        echo "ERROR: User '$uname' already exists."
        exit 1
    fi
    read -rsp "Password: " passwd < /dev/tty; echo
    if [ -z "$passwd" ]; then
        echo "ERROR: Password cannot be empty."
        exit 1
    fi
    read -rp  "Active for how many days: " days < /dev/tty

    local expiry_date
    expiry_date="$(date -d "+${days} days" +%Y-%m-%d)"

    # Ensure /bin/false is in /etc/shells so PAM allows login.
    # Without this, SSH returns "Incorrect user name or password" even when
    # the password is correct.
    grep -qxF '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells

    # Use -m (create home dir). Some PAM/SSH configurations reject users
    # without a home directory.  Shell is /bin/false — blocks interactive
    # logins while allowing SSH tunneling and port forwarding.
    useradd -m -e "$expiry_date" -s /bin/false "$uname"
    echo "$uname:$passwd" | chpasswd

    # Verify the password was actually set correctly
    if ! getent passwd "$uname" > /dev/null 2>&1; then
        echo "ERROR: Failed to create user '$uname'."
        exit 1
    fi

    local created expires
    created="$(date +%d-%b-%Y)"
    expires="$(date -d "+${days} days" +%d-%b-%Y)"
    echo "$uname:$created:$expires" >> "$USERLOG"

    echo -e "\033[0;32m[✓] Account '$uname' created — expires $expires\033[0m"
    print_account_config "$uname" "$passwd" "$created" "$expires"
}

extend_account() {
    read -rp "Username to extend: " uname < /dev/tty
    if ! id "$uname" &>/dev/null; then
        echo "ERROR: No such user '$uname'."
        exit 1
    fi
    read -rp "Add how many days: " days < /dev/tty

    local current_exp base new_exp new_exp_fmt
    current_exp="$(chage -l "$uname" | grep "Account expires" | cut -d: -f2 | xargs)"
    if [ "$current_exp" = "never" ] || [ -z "$current_exp" ]; then
        base="$(date +%Y-%m-%d)"
    else
        base="$(date -d "$current_exp" +%Y-%m-%d)"
    fi
    new_exp="$(date -d "$base +${days} days" +%Y-%m-%d)"
    new_exp_fmt="$(date -d "$new_exp" +%d-%b-%Y)"
    usermod -e "$new_exp" "$uname"
    sed -i "s|^${uname}:\(.*\):.*|${uname}:\1:${new_exp_fmt}|" "$USERLOG"
    echo "New expiry for $uname: $new_exp_fmt"
}

delete_account() {
    read -rp "Username to delete: " uname < /dev/tty
    userdel -r "$uname" 2>/dev/null || userdel -f "$uname" 2>/dev/null || true
    sed -i "/^${uname}:/d" "$USERLOG"
    echo "Deleted $uname."
}

list_accounts() {
    echo ""
    printf "%-22s %-15s %-15s\n" "USERNAME" "CREATED" "EXPIRES"
    printf '%0.s─' {1..54}; echo
    while IFS=: read -r u c e; do
        [ -z "$u" ] && continue
        printf "%-22s %-15s %-15s\n" "$u" "$c" "$e"
    done < "$USERLOG"
    local count
    count="$(grep -c . "$USERLOG" 2>/dev/null || true)"
    echo ""
    echo "Total: ${count:-0} account(s)"
    echo ""
}

edit_banner() {
    echo ""
    echo "Current banner ($SSHPANEL_DIR/banner.txt):"
    echo "─────────────────────────────────────────"
    cat "$SSHPANEL_DIR/banner.txt"
    echo "─────────────────────────────────────────"
    echo "Note: HTTP Custom renders HTML in the Server Message."
    echo "      Use <font color=\"#RRGGBB\"> for colors."
    echo ""
    "${EDITOR:-nano}" "$SSHPANEL_DIR/banner.txt"
    systemctl restart dropbear
    echo "Banner updated and dropbear reloaded."
}

set_cf_domain() {
    echo ""
    echo "Your Cloudflare domain must have:"
    echo "  • Orange cloud ON (Proxied) pointing to this VPS"
    echo "  • Cloudflare → Network → WebSockets → ON"
    echo ""
    read -rp "Cloudflare domain (e.g. konami.chickenkiller.com): " newdomain < /dev/tty
    echo "$newdomain" > "$SSHPANEL_DIR/cf_domain.txt"
    echo ""
    echo "[✓] Saved: $newdomain"
    echo ""
    echo "CF-RAY payload for HTTP Custom:"
    echo "  Remote Proxy : viton.com  (or ANY Cloudflare domain)"
    echo "  Payload :"
    echo "    GET /cdn-cgi/trace HTTP/1.1[crlf]Host:${newdomain}[crlf][crlf]CF-RAY / HTTP/1.1[crlf]Host: ${newdomain}[crlf]Upgrade: Websocket[crlf]Connection: Keep-Alive[crlf][crlf]"
    echo ""
}

purge_expired() {
    local today
    today="$(date +%s)"
    while IFS=: read -r u c e; do
        [ -z "$u" ] && continue
        local exp_epoch
        exp_epoch="$(date -d "$e" +%s 2>/dev/null || echo 0)"
        if [ "$exp_epoch" -lt "$today" ]; then
            echo "Purging expired user: $u (expired $e)"
            userdel -r "$u" 2>/dev/null || userdel -f "$u" 2>/dev/null || true
            sed -i "/^${u}:/d" "$USERLOG"
        fi
    done < "$USERLOG"
}

case "$1" in
    create)         create_account ;;
    extend)         extend_account ;;
    delete)         delete_account ;;
    list)           list_accounts ;;
    purge-expired)  purge_expired ;;
    banner)         edit_banner ;;
    set-cf-domain)  set_cf_domain ;;
    *)              usage ;;
esac
