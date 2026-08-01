#!/bin/bash
# menu — interactive SSH panel dashboard
#
# Sourcing this file defines its functions without starting the menu loop,
# which is what tests/menu.bats does.

SSHPANEL_DIR="${SSHPANEL_DIR:-/etc/sshpanel}"
USERLOG="${USERLOG:-$SSHPANEL_DIR/users.db}"
USAGE_DIR="${USAGE_DIR:-$SSHPANEL_DIR/usage}"
QUOTA_DIR="${QUOTA_DIR:-$SSHPANEL_DIR/quota}"
BRAND_FILE="${BRAND_FILE:-$SSHPANEL_DIR/brand.txt}"
AUTH_LOG="${AUTH_LOG:-/var/log/auth.log}"
IPT_CHAIN="SSHPANEL"
BOX_W=64

BRAND="$(cat "$BRAND_FILE" 2>/dev/null || echo "SSH PANEL")"

# ── Colors ───────────────────────────────────────────────────────────────────
# Disabled automatically when stdout is not a terminal or NO_COLOR is set.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GRN=$'\033[32m';   C_YEL=$'\033[33m'
    C_BLU=$'\033[34m';   C_MAG=$'\033[35m';   C_CYN=$'\033[36m'
    C_WHT=$'\033[37m'
else
    C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_MAG=; C_CYN=; C_WHT=
fi
C_BOX="$C_CYN"

strip_ansi() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

# repeat <count> <char>
repeat() {
    local n="${1:-0}" ch="$2" out="" i
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    for ((i = 0; i < n; i++)); do out+="$ch"; done
    printf '%s' "$out"
}

box_top() {
    local title="$1" plain pad
    plain="$(strip_ansi "$title")"
    pad=$(( BOX_W - 6 - ${#plain} ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s╔══ %s%s%s %s╗%s\n' \
        "$C_BOX" "$C_BOLD$C_WHT" "$plain" "$C_RESET$C_BOX" "$(repeat "$pad" '═')" "$C_RESET"
}

box_line() {
    local text="$1" plain pad
    plain="$(strip_ansi "$text")"
    pad=$(( BOX_W - 3 - ${#plain} ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s║%s %s%*s%s║%s\n' "$C_BOX" "$C_RESET" "$text" "$pad" "" "$C_BOX" "$C_RESET"
}

box_sep() {
    printf '%s╟%s╢%s\n' "$C_BOX" "$(repeat $((BOX_W - 2)) '─')" "$C_RESET"
}

box_bottom() {
    printf '%s╚%s╝%s\n' "$C_BOX" "$(repeat $((BOX_W - 2)) '═')" "$C_RESET"
}

banner() {
    printf '%s' "$C_CYN$C_BOLD"
    cat <<'ART'
  ███████╗███████╗██╗  ██╗    ██████╗  █████╗ ███╗   ██╗███████╗██╗
  ██╔════╝██╔════╝██║  ██║    ██╔══██╗██╔══██╗████╗  ██║██╔════╝██║
  ███████╗███████╗███████║    ██████╔╝███████║██╔██╗ ██║█████╗  ██║
  ╚════██║╚════██║██╔══██║    ██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║
  ███████║███████║██║  ██║    ██║     ██║  ██║██║ ╚████║███████╗███████╗
  ╚══════╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
ART
    printf '%s' "$C_RESET"
    printf '%s   %s — SSH Tunnel Manager%s\n\n' "$C_MAG$C_BOLD" "$BRAND" "$C_RESET"
}

ok_mark()   { printf '%s✔%s' "$C_GRN" "$C_RESET"; }
bad_mark()  { printf '%s✘%s' "$C_RED" "$C_RESET"; }

# ── Formatting helpers ───────────────────────────────────────────────────────

human_bytes() {
    local b="${1:-0}"
    if ! [[ "$b" =~ ^[0-9]+$ ]]; then echo "0 B"; return; fi
    if   [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.2f GB", b/1073741824}'
    elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.2f MB", b/1048576}'
    elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.2f KB", b/1024}'
    else echo "$b B"
    fi
}

fmt_duration() {
    local s="${1:-0}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    printf '%dd %02dh %02dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60))
}

# progress_bar <used> <total> [width] — coloured bar, green/yellow/red by fill.
progress_bar() {
    local used="${1:-0}" total="${2:-0}" width="${3:-20}" pct filled color
    if ! [[ "$total" =~ ^[0-9]+$ ]] || [ "$total" -le 0 ]; then
        printf '%s%s unlimited%s' "$C_DIM" "$(repeat "$width" '─')" "$C_RESET"
        return
    fi
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    pct=$(( used * 100 / total ))
    [ "$pct" -gt 100 ] && pct=100
    filled=$(( pct * width / 100 ))
    if   [ "$pct" -ge 90 ]; then color="$C_RED"
    elif [ "$pct" -ge 70 ]; then color="$C_YEL"
    else color="$C_GRN"
    fi
    printf '%s%s%s%s%s %3d%%' \
        "$color" "$(repeat "$filled" '█')" \
        "$C_DIM" "$(repeat $((width - filled)) '░')" "$C_RESET" "$pct"
}

# days_until <DD-Mon-YYYY> — days from today (negative once expired).
days_until() {
    local target now
    target="$(date -d "$1" +%s 2>/dev/null)" || return 1
    [ -n "$target" ] || { echo 0; return 1; }
    now="$(date +%s)"
    echo $(( (target - now) / 86400 ))
}

# expiry_state <days-left> — expired | warning (<= 3 days) | active
expiry_state() {
    local d="${1:-0}"
    if   [ "$d" -lt 0 ]; then echo expired
    elif [ "$d" -le 3 ]; then echo warning
    else echo active
    fi
}

state_color() {
    case "$1" in
        expired) printf '%s' "$C_RED" ;;
        warning) printf '%s' "$C_YEL" ;;
        *)       printf '%s' "$C_GRN" ;;
    esac
}

# ── Accounts ─────────────────────────────────────────────────────────────────

accounts() { [ -f "$USERLOG" ] && grep -v '^[[:space:]]*$' "$USERLOG" || true; }

# account_stats — "<total> <active> <warning> <expired>"
account_stats() {
    local total=0 active=0 warning=0 expired=0 u c e days
    while IFS=: read -r u c e; do
        [ -z "$u" ] && continue
        total=$((total + 1))
        days="$(days_until "$e" 2>/dev/null || echo 0)"
        case "$(expiry_state "$days")" in
            expired) expired=$((expired + 1)) ;;
            warning) warning=$((warning + 1)) ;;
            *)       active=$((active + 1)) ;;
        esac
    done < <(accounts)
    echo "$total $active $warning $expired"
}

# ── Online sessions ──────────────────────────────────────────────────────────

# parse_auth_sessions — reads an auth log on stdin, emits "<pid> <user> <ip>"
# for every successful OpenSSH or Dropbear password authentication.
parse_auth_sessions() {
    awk '
        match($0, /sshd\[[0-9]+\]: Accepted (password|publickey) for [^ ]+ from [0-9a-fA-F.:]+/) {
            s = substr($0, RSTART, RLENGTH)
            split(s, f, " ")
            pid = s; sub(/.*sshd\[/, "", pid); sub(/\].*/, "", pid)
            print pid, f[5], f[7]
            next
        }
        match($0, /dropbear\[[0-9]+\]: Password auth succeeded for .[^'"'"']+. from [0-9a-fA-F.:]+/) {
            s = substr($0, RSTART, RLENGTH)
            pid = s; sub(/.*dropbear\[/, "", pid); sub(/\].*/, "", pid)
            user = s; sub(/.*succeeded for .?/, "", user); sub(/.? from .*/, "", user)
            ip = s; sub(/.* from /, "", ip); sub(/:[0-9]+$/, "", ip)
            print pid, user, ip
        }
    '
}

auth_log_stream() {
    if [ -r "$AUTH_LOG" ]; then
        cat "$AUTH_LOG"
    else
        journalctl -t sshd -t dropbear --since "-7 days" --no-pager 2>/dev/null || true
    fi
}

session_uptime() { ps -o etimes= -p "$1" 2>/dev/null | tr -d ' '; }

# online_sessions — "<user> <ip> <pid> <seconds>" for sessions whose PID is alive.
online_sessions() {
    local pid user ip secs
    while read -r pid user ip; do
        [ -z "$pid" ] && continue
        [ -d "/proc/$pid" ] || continue
        secs="$(session_uptime "$pid")"
        [ -n "$secs" ] || continue
        echo "$user $ip $pid $secs"
    done < <(auth_log_stream | parse_auth_sessions | tac | awk '!seen[$1]++')
}

show_online() {
    local rows count
    rows="$(online_sessions)"
    count="$(printf '%s' "$rows" | grep -c . || true)"
    echo ""
    box_top "ONLINE USERS  ($count connected)"
    box_line "$(printf '%s%-16s %-17s %-8s %s%s' "$C_BOLD" USER IP PID DURATION "$C_RESET")"
    box_sep
    if [ -z "$rows" ]; then
        box_line "$(printf '%sno active sessions%s' "$C_DIM" "$C_RESET")"
    else
        while read -r user ip pid secs; do
            [ -z "$user" ] && continue
            box_line "$(printf '%s%-16s%s %-17s %-8s %s' \
                "$C_GRN" "$user" "$C_RESET" "$ip" "$pid" "$(fmt_duration "$secs")")"
        done <<< "$rows"
    fi
    box_bottom
    printf '%s  refreshed %s%s\n' "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"
}

watch_online() {
    local n=0
    while [ "$n" -lt 20 ]; do
        clear; banner; show_online
        printf '%s  auto-refresh every 5s — press Ctrl+C to stop%s\n' "$C_DIM" "$C_RESET"
        sleep 5 || break
        n=$((n + 1))
    done
}

# ── Bandwidth accounting ─────────────────────────────────────────────────────
#
# Per-user counters come from iptables `owner` match rules in the SSHPANEL
# chain (one counter-only rule per account).  Counters reset when the firewall
# is reloaded, so usage_sync folds them into cumulative totals under
# $USAGE_DIR/<user> ("<total-bytes> <last-counter>").

bw_ensure_rules() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -n -L "$IPT_CHAIN" >/dev/null 2>&1 || iptables -N "$IPT_CHAIN" >/dev/null 2>&1 || return 1
    iptables -C OUTPUT -j "$IPT_CHAIN" >/dev/null 2>&1 || iptables -A OUTPUT -j "$IPT_CHAIN" >/dev/null 2>&1
    local u c e uid
    while IFS=: read -r u c e; do
        [ -z "$u" ] && continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        iptables -C "$IPT_CHAIN" -m owner --uid-owner "$uid" \
            -m comment --comment "sshpanel:$u" >/dev/null 2>&1 && continue
        iptables -A "$IPT_CHAIN" -m owner --uid-owner "$uid" \
            -m comment --comment "sshpanel:$u" >/dev/null 2>&1
    done < <(accounts)
}

# parse_iptables_counters — reads `iptables -n -v -x -L SSHPANEL` on stdin,
# emits "<user> <bytes>" for each sshpanel counter rule.
parse_iptables_counters() {
    awk '
        match($0, /sshpanel:[^ *]+/) {
            user = substr($0, RSTART + 9, RLENGTH - 9)
            print user, $2
        }
    '
}

# usage_apply_delta <total> <last> <counter> — "<new-total> <new-last>",
# treating a counter that went backwards as a firewall reset.
usage_apply_delta() {
    local total="${1:-0}" last="${2:-0}" counter="${3:-0}" delta
    if [ "$counter" -ge "$last" ]; then delta=$((counter - last)); else delta="$counter"; fi
    echo "$((total + delta)) $counter"
}

usage_sync() {
    mkdir -p "$USAGE_DIR" 2>/dev/null || return 1
    bw_ensure_rules
    command -v iptables >/dev/null 2>&1 || return 1
    local user counter total last
    while read -r user counter; do
        [ -z "$user" ] && continue
        read -r total last < <(cat "$USAGE_DIR/$user" 2>/dev/null || echo "0 0")
        usage_apply_delta "${total:-0}" "${last:-0}" "$counter" > "$USAGE_DIR/$user"
    done < <(iptables -n -v -x -L "$IPT_CHAIN" 2>/dev/null | parse_iptables_counters)
}

usage_bytes() {
    local total
    [ -r "$USAGE_DIR/$1" ] && read -r total _ < "$USAGE_DIR/$1"
    [[ "$total" =~ ^[0-9]+$ ]] && echo "$total" || echo 0
}
quota_bytes() {
    local gb
    gb="$(cat "$QUOTA_DIR/$1" 2>/dev/null || echo 0)"
    [[ "$gb" =~ ^[0-9]+$ ]] || gb=0
    echo $(( gb * 1073741824 ))
}

# server_bytes — total interface traffic, from vnstat when available.
server_bytes() {
    local total
    if command -v vnstat >/dev/null 2>&1; then
        total="$(vnstat --oneline b 2>/dev/null | awk -F';' '{printf "%.0f", $11}')"
        [ -n "$total" ] && [ "$total" != "0" ] && { echo "$total"; return; }
    fi
    awk 'NR>2 && $1 !~ /^lo:/ {gsub(":"," "); rx+=$2; tx+=$10} END{printf "%.0f", rx+tx}' /proc/net/dev 2>/dev/null || echo 0
}

show_bandwidth() {
    usage_sync
    local u c e used quota total=0
    echo ""
    box_top "BANDWIDTH USAGE"
    box_line "$(printf '%s%-16s %-12s %s%s' "$C_BOLD" USER USED QUOTA "$C_RESET")"
    box_sep
    while IFS=: read -r u c e; do
        [ -z "$u" ] && continue
        used="$(usage_bytes "$u")"; quota="$(quota_bytes "$u")"
        total=$((total + used))
        box_line "$(printf '%-16s %-12s %s' "$u" "$(human_bytes "$used")" "$(progress_bar "$used" "$quota" 16)")"
    done < <(accounts)
    box_sep
    box_line "$(printf '%sAccounts total : %s%s' "$C_BOLD" "$(human_bytes "$total")" "$C_RESET")"
    box_line "$(printf 'Server total   : %s' "$(human_bytes "$(server_bytes)")")"
    box_bottom
    if ! command -v iptables >/dev/null 2>&1; then
        printf '%s  [!] iptables missing — per-user counters unavailable%s\n' "$C_YEL" "$C_RESET"
    fi
}

set_quota() {
    local user gb
    read -rp "Username: " user < /dev/tty
    read -rp "Quota in GB (0 = unlimited): " gb < /dev/tty
    [[ "$gb" =~ ^[0-9]+$ ]] || { printf '%s[!] quota must be a whole number of GB%s\n' "$C_RED" "$C_RESET"; return 1; }
    mkdir -p "$QUOTA_DIR"
    echo "$gb" > "$QUOTA_DIR/$user"
    printf '%s[✓] quota for %s set to %s GB%s\n' "$C_GRN" "$user" "$gb" "$C_RESET"
}

reset_usage() {
    local user
    read -rp "Username (blank = all): " user < /dev/tty
    mkdir -p "$USAGE_DIR"
    if [ -z "$user" ]; then
        rm -f "$USAGE_DIR"/* 2>/dev/null
        printf '%s[✓] usage counters cleared for all accounts%s\n' "$C_GRN" "$C_RESET"
    else
        rm -f "$USAGE_DIR/$user"
        printf '%s[✓] usage counters cleared for %s%s\n' "$C_GRN" "$user" "$C_RESET"
    fi
}

# ── System / service status ──────────────────────────────────────────────────

cpu_load()  { awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0; }
cpu_cores() { nproc 2>/dev/null || echo 1; }
mem_line()  { free -m 2>/dev/null | awk '/^Mem:/{printf "%d %d", $3, $2}'; }
disk_line() { df -Pk / 2>/dev/null | awk 'NR==2{printf "%.0f %.0f", $3*1024, $2*1024}'; }
uptime_str(){ uptime -p 2>/dev/null || echo "unknown"; }

get_cf_domain() { cat "$SSHPANEL_DIR/cf_domain.txt" 2>/dev/null || echo '<not set>'; }
get_host_ip()   { curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }

show_system() {
    local used tot load cores
    echo ""
    box_top "SYSTEM RESOURCES"
    load="$(cpu_load)"; cores="$(cpu_cores)"
    box_line "$(printf 'CPU load  : %s%s%s  (%s cores)' "$C_CYN" "$load" "$C_RESET" "$cores")"
    read -r used tot < <(mem_line)
    if [ -n "$tot" ] && [ "${tot:-0}" -gt 0 ]; then
        box_line "$(printf 'Memory    : %s / %s MB  %s' "$used" "$tot" "$(progress_bar "$used" "$tot" 16)")"
    fi
    read -r used tot < <(disk_line)
    if [ -n "$tot" ] && [ "${tot:-0}" -gt 0 ]; then
        box_line "$(printf 'Disk /    : %s / %s  %s' "$(human_bytes "$used")" "$(human_bytes "$tot")" "$(progress_bar "$used" "$tot" 16)")"
    fi
    box_line "$(printf 'Uptime    : %s' "$(uptime_str)")"
    box_line "$(printf 'Time      : %s' "$(date '+%Y-%m-%d %H:%M:%S %Z')")"
    box_bottom
}

show_status() {
    echo ""
    box_top "SERVICE STATUS"
    local svc status port
    for svc in dropbear wsproxy stunnel4 udpgw; do
        status="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
        if [ "$status" = "active" ]; then
            box_line "$(printf '%s %-12s %srunning%s' "$(ok_mark)" "$svc" "$C_GRN" "$C_RESET")"
        else
            box_line "$(printf '%s %-12s %s%s%s' "$(bad_mark)" "$svc" "$C_RED" "$status" "$C_RESET")"
        fi
    done
    box_sep
    for port in 22 80 109 443; do
        if ss -tln 2>/dev/null | grep -q ":${port} "; then
            box_line "$(printf '%s port %-6s %slistening%s' "$(ok_mark)" "$port" "$C_GRN" "$C_RESET")"
        else
            box_line "$(printf '%s port %-6s %snot listening%s' "$(bad_mark)" "$port" "$C_RED" "$C_RESET")"
        fi
    done
    box_sep
    if grep -qxF '/bin/false' /etc/shells 2>/dev/null; then
        box_line "$(printf '%s /bin/false in /etc/shells — logins allowed' "$(ok_mark)")"
    else
        box_line "$(printf '%s /bin/false MISSING from /etc/shells — logins fail' "$(bad_mark)")"
        box_line "$(printf '%s  fix: echo /bin/false >> /etc/shells%s' "$C_DIM" "$C_RESET")"
    fi
    box_line "$(printf 'CF domain : %s' "$(get_cf_domain)")"
    box_line "$(printf 'VPS IP    : %s' "$(get_host_ip)")"
    box_bottom
    show_system
}

show_accounts_overview() {
    local total active warning expired u c e days state
    read -r total active warning expired < <(account_stats)
    echo ""
    box_top "ACCOUNTS  ($total total)"
    box_line "$(printf '%sactive %s%s  %swarning %s%s  %sexpired %s%s' \
        "$C_GRN" "$active" "$C_RESET" "$C_YEL" "$warning" "$C_RESET" "$C_RED" "$expired" "$C_RESET")"
    box_sep
    box_line "$(printf '%s%-16s %-12s %-12s %s%s' "$C_BOLD" USER EXPIRES LEFT USED "$C_RESET")"
    while IFS=: read -r u c e; do
        [ -z "$u" ] && continue
        days="$(days_until "$e" 2>/dev/null || echo 0)"
        state="$(expiry_state "$days")"
        box_line "$(printf '%s%-16s%s %-12s %-12s %s' \
            "$(state_color "$state")" "$u" "$C_RESET" "$e" \
            "$([ "$days" -lt 0 ] && echo "EXPIRED" || echo "${days}d")" \
            "$(human_bytes "$(usage_bytes "$u")")")"
    done < <(accounts)
    box_bottom
}

show_payloads() {
    local host_ip cf_domain
    host_ip="$(get_host_ip)"; cf_domain="$(get_cf_domain)"
    echo ""
    box_top "HTTP CUSTOM PAYLOADS"
    box_line "$(printf '%s► CONNECT (direct VPS proxy)%s' "$C_CYN" "$C_RESET")"
    box_line "  Remote Proxy : ${host_ip}:80"
    box_line "$(printf '%s  CONNECT [host]:[port] HTTP/1.1[crlf]Host: [host][crlf]%s' "$C_DIM" "$C_RESET")"
    box_line "$(printf '%s  Connection: Keep-Alive[crlf][crlf]%s' "$C_DIM" "$C_RESET")"
    box_sep
    box_line "$(printf '%s► Zero-rated bughost (works with no data bundle)%s' "$C_CYN" "$C_RESET")"
    box_line "  Remote Proxy : ${host_ip}:80"
    box_line "$(printf '%s  CONNECT https://wifipay.co.ke:UC19O866GH HTTP/1.1[crlf]%s' "$C_DIM" "$C_RESET")"
    box_line "$(printf '%s  Host: https://netpap.co.ke:UC19O866GH[crlf]%s' "$C_DIM" "$C_RESET")"
    box_line "$(printf '%s  Connection: keep-alive[crlf]X-Online-Host: ...[crlf][crlf]%s' "$C_DIM" "$C_RESET")"
    box_sep
    box_line "$(printf '%s► CF-RAY (any Cloudflare domain as bughost)%s' "$C_CYN" "$C_RESET")"
    if [ "$cf_domain" != "<not set>" ]; then
        box_line "$(printf '%s  GET /cdn-cgi/trace HTTP/1.1[crlf]Host:%s[crlf][crlf]%s' "$C_DIM" "$cf_domain" "$C_RESET")"
        box_line "$(printf '%s  CF-RAY / HTTP/1.1[crlf]Host: %s[crlf]%s' "$C_DIM" "$cf_domain" "$C_RESET")"
        box_line "$(printf '%s  Upgrade: Websocket[crlf]Connection: Keep-Alive[crlf][crlf]%s' "$C_DIM" "$C_RESET")"
    else
        box_line "$(printf '%s  [!] no CF domain set — use option 10%s' "$C_YEL" "$C_RESET")"
    fi
    box_sep
    box_line "  SSH ports : 22 (OpenSSH) / 109 (Dropbear)   UDPGW : 7300"
    box_bottom
}

# ── Dashboard + menu ─────────────────────────────────────────────────────────

dashboard() {
    local total active warning expired online load
    read -r total active warning expired < <(account_stats)
    online="$(online_sessions | grep -c . || true)"
    load="$(cpu_load)"
    box_top "DASHBOARD  $(date '+%Y-%m-%d %H:%M:%S')"
    box_line "$(printf 'Accounts  : %s total   %s%s active%s   %s%s expiring%s   %s%s expired%s' \
        "$total" "$C_GRN" "$active" "$C_RESET" "$C_YEL" "$warning" "$C_RESET" "$C_RED" "$expired" "$C_RESET")"
    box_line "$(printf 'Online    : %s%s user(s)%s   CF domain : %s' "$C_CYN" "$online" "$C_RESET" "$(get_cf_domain)")"
    box_line "$(printf 'Load      : %s   Uptime : %s' "$load" "$(uptime_str)")"
    box_bottom
    if [ "${expired:-0}" -gt 0 ]; then
        printf '%s  ⚠ %s expired account(s) — run option 5 to purge%s\n' "$C_RED" "$expired" "$C_RESET"
    fi
    if [ "${warning:-0}" -gt 0 ]; then
        printf '%s  ⚠ %s account(s) expire within 3 days%s\n' "$C_YEL" "$warning" "$C_RESET"
    fi
}

menu_item() { printf '  %s►%s %s%2s%s) %s\n' "$C_CYN" "$C_RESET" "$C_BOLD" "$1" "$C_RESET" "$2"; }

menu_options() {
        printf '%s  ── Accounts ─────────────────────────────────────────%s\n' "$C_MAG" "$C_RESET"
        menu_item 1 "Create account"
        menu_item 2 "List accounts"
        menu_item 3 "Extend account"
        menu_item 4 "Delete account"
        menu_item 5 "Purge expired accounts"
        menu_item 6 "Accounts overview (expiry + usage)"
        printf '%s  ── Monitoring ───────────────────────────────────────%s\n' "$C_MAG" "$C_RESET"
        menu_item 7 "Online users"
        menu_item 8 "Online users (live refresh)"
        menu_item 9 "Bandwidth usage"
        menu_item 10 "Service status + system resources"
        printf '%s  ── Server ───────────────────────────────────────────%s\n' "$C_MAG" "$C_RESET"
        menu_item 11 "Set user quota"
        menu_item 12 "Reset usage counters"
        menu_item 13 "Edit login banner"
        menu_item 14 "Restart all services"
        menu_item 15 "HTTP Custom payload examples"
        menu_item 16 "Set / update Cloudflare domain"
        menu_item 0 "Exit"
}

main_menu() {
    while true; do
        clear
        banner
        dashboard
        echo ""
        menu_options
        echo ""
        read -rp "$(printf '%sChoose an option:%s ' "$C_BOLD" "$C_RESET")" choice

        case "$choice" in
            1)  manage-ssh create ;;
            2)  manage-ssh list ;;
            3)  manage-ssh extend ;;
            4)  manage-ssh delete ;;
            5)  manage-ssh purge-expired ;;
            6)  show_accounts_overview ;;
            7)  show_online ;;
            8)  watch_online ;;
            9)  show_bandwidth ;;
            10) show_status ;;
            11) set_quota ;;
            12) reset_usage ;;
            13) manage-ssh banner ;;
            14)
                printf '%sRestarting dropbear, wsproxy, stunnel4, udpgw ...%s\n' "$C_YEL" "$C_RESET"
                systemctl restart dropbear wsproxy stunnel4 udpgw
                printf '%s[✓] done%s\n' "$C_GRN" "$C_RESET"
                ;;
            15) show_payloads ;;
            16) manage-ssh set-cf-domain ;;
            0)  exit 0 ;;
            *)  printf '%s[!] invalid option%s\n' "$C_RED" "$C_RESET" ;;
        esac

        echo ""
        read -rp "Press Enter to return to menu..." _
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main_menu
fi
