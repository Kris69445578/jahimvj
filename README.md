# SSH Tunnel Panel — FastSSH-Compatible (v4)

A self-hosted SSH tunnel server that behaves identically to FastSSH from HTTP Custom's perspective.

---

## Root Cause — Why it worked with a data bundle but not without

| Scenario | Carrier proxy behaviour | Result |
|---|---|---|
| **With data bundle** | Lenient — passes any 101 response | ✅ Connected |
| **Without data bundle** | Strict RFC 6455 — validates `Sec-WebSocket-Accept` | ❌ Connection timeout |

FastSSH passes the strict check because it computes and returns a valid `Sec-WebSocket-Accept` header derived from the client's `Sec-WebSocket-Key`.  The old wsproxy did not — so the carrier's proxy rejected the handshake and the connection timed out.

**Before fix (your VPS):**
```
HTTP/1.1 101 Switching Protocols
Connection: Upgrade
Upgrade: websocket
X-Powered-By: Switching Protocols
```

**After fix (matches FastSSH exactly):**
```
HTTP/1.1 101 Switching Protocols
Connection: upgrade
Upgrade: websocket
Sec-WebSocket-Accept: bATZaIDm+vu6uZLDz6WoQQ==   ← different every request (derived from client nonce)
```

The `Sec-WebSocket-Accept` value changes every request because it is computed from the random `Sec-WebSocket-Key` the client sends — this is correct RFC 6455 behaviour, not a bug.

**Algorithm (RFC 6455 §4.2.2):**
```
Sec-WebSocket-Accept = base64( sha1( Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )
```

---

## All Fixes

| # | Fix | Why it matters |
|---|---|---|
| 1 | **UFW firewall rules** | Ubuntu 22.04 default-deny blocks port 80 → Cloudflare 530 |
| 2 | **Brand = "Switching Protocols"** | HTTP Custom shows `HTTP/1.1 101 Switching Protocols` — identical to FastSSH |
| 3 | **`Sec-WebSocket-Accept` computed per RFC 6455** | **Fixes "no connect without data bundle"** — strict carrier proxies reject the WS handshake without it |
| 4 | **101 for ALL requests** (including plain GET) | HTTP Custom probes the proxy before tunneling; FastSSH returns 101, so must we |
| 5 | **PasswordAuthentication yes** in sshd_config | Ubuntu 22.04 ships with it OFF |
| 6 | **AllowTcpForwarding yes** in sshd_config | Required for HTTP Custom tunneling |
| 7 | **useradd -m** (home dir created) | Prevents PAM rejecting accounts |
| 8 | **/bin/false added to /etc/shells** | Fixes "Incorrect user name or password" — PAM checks /etc/shells |
| 9 | **stunnel4 → wsproxy:80 → Dropbear:109** | Fixes SSL mode with payload |
| 10 | **`Connection: upgrade`** (lowercase) | Matches FastSSH header exactly |

---

## Quick-Fix existing server

```bash
curl -sL https://raw.githubusercontent.com/Kris69445578/jahimvj/main/quickfix.sh | sudo bash
```

The script ends with a live probe that confirms `Sec-WebSocket-Accept` is present in the response.

---

## Fresh install

```bash
# Option A — curl
curl -sL https://raw.githubusercontent.com/Kris69445578/jahimvj/main/bootstrap.sh | sudo bash

# Option B — wget
apt update -y && apt upgrade -y && \
wget -q https://raw.githubusercontent.com/Kris69445578/jahimvj/main/setup.sh && \
chmod +x setup.sh && sudo ./setup.sh
```

---

## HTTP Custom Configuration

### CONNECT payload (HTTP — port 80)

| Setting | Value |
|---|---|
| Remote Proxy | `YOUR-VPS-IP:80` |
| Payload | `CONNECT [host]:[port] HTTP/1.1[crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]` |
| SSH Port | `22` or `109` |

### CONNECT payload (SSL — port 443)

| Setting | Value |
|---|---|
| SSL checkbox | ✓ ON |
| Remote Proxy | `YOUR-VPS-IP:443` |
| Payload | `CONNECT [host]:[port] HTTP/1.1[crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]` |
| SSH Port | `22` or `109` |

### Zero-rated bughost payload (works without data bundle)

| Setting | Value |
|---|---|
| Remote Proxy | `YOUR-VPS-IP:80` |
| Payload | `CONNECT https://wifipay.co.ke:UC19O866GH HTTP/1.1[crlf]Host: https://netpap.co.ke:UC19O866GH[crlf]Connection: keep-alive[crlf]X-Online-Host: m.netpap.co.ke:UC19O866GH[crlf]X-Forward-Host: m.netpap.co.ke:UC19O866GH[crlf][crlf]` |
| SSH Port | `22` or `109` |

---

## Expected HTTP Custom Log

```
[xx:xx:xx] HTTP/1.1 101 Switching Protocols   ← brand
[xx:xx:xx] set auto replace response
[xx:xx:xx] HTTP/1.1 200 OK
[xx:xx:xx] SSH-2.0-dropbear_xxxx
[xx:xx:xx] ssh authenticate with password
[xx:xx:xx] ssh connected
[xx:xx:xx] set UDPGW 127.0.0.1:7300
[xx:xx:xx] HTTP Custom ready to use
```

---

## Services

| Service | Port | Purpose |
|---|---|---|
| wsproxy | 80 | HTTP/WS front door — parses CONNECT + WebSocket payloads, computes Sec-WebSocket-Accept |
| stunnel4 | 443 | TLS front door → wsproxy:80 → Dropbear:109 |
| dropbear | 109 | SSH backend |
| openssh | 22 | SSH backend (alternative) |
| badvpn-udpgw | 127.0.0.1:7300 | UDP over SSH |

---

## Management Commands

```bash
menu                        # Interactive management menu
manage-ssh create           # Create an SSH account
manage-ssh list             # List all accounts
manage-ssh extend           # Extend account expiry
manage-ssh delete           # Delete an account
manage-ssh purge-expired    # Remove expired accounts
manage-ssh banner           # Edit the login banner
manage-ssh set-cf-domain    # Set/update your Cloudflare domain
```

---

## Verify the fix manually

```bash
curl -i \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://YOUR-VPS-IP:80/
```

Expected response:
```
HTTP/1.1 101 Switching Protocols
Connection: upgrade
Upgrade: websocket
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
X-Powered-By: Switching Protocols
```

The `Sec-WebSocket-Accept` value for the fixed test key `dGhlIHNhbXBsZSBub25jZQ==` is always `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=` — this is defined by RFC 6455 and can be used to confirm the implementation is correct.

---

## v5 — Zero-rated pure CONNECT fix

**Problem:** With Enhanced OFF and a pure CONNECT payload (e.g. wifipay/netpap zero-rated), the server was sending:

```
HTTP/1.1 200 OK

HTTP/1.1 101 Switching Protocols
...
```

HTTP Custom (Enhanced OFF) treats everything after the first `200` as the SSH stream, so it read `HTTP/1.1 101...` as the SSH banner → timeout. FastSSH free accounts work because they reply with a **single** `200 Connection Established` for pure CONNECT.

**Fix:**  
- Pure CONNECT (no `Upgrade` / no `Sec-WebSocket-Key`) → only `HTTP/1.1 200 Connection Established`  
- CONNECT that also has WebSocket headers, or plain WS / CF-RAY → dual `200` + `101` + `Sec-WebSocket-Accept` (unchanged)

### Apply on existing VPS

```bash
# Upload the zip, or:
sudo bash quickfix.sh
```

### HTTP Custom — zero-rated (no data bundle)

| Setting | Value |
|---|---|
| Remote Proxy | `YOUR-VPS-IP:80` |
| Enhanced payload | **OFF** |
| Payload | `CONNECT https://wifipay.co.ke:UC19O866GH HTTP/1.1[crlf]Host: https://netpap.co.ke:UC19O866GH[crlf]Connection: keep-alive[crlf]X-Online-Host: m.netpap.co.ke:UC19O866GH[crlf]X-Forward-Host: m.netpap.co.ke:UC19O866GH[crlf][crlf]` |
| SSH Port | `109` (or `22`) |
| UDPGW | `127.0.0.1:7300` |

Expected log:

```
connected to socket YOUR-IP:80
HTTP/1.1 200 Connection Established
SSH-2.0-dropbear_xxxx
ssh authenticate with password
ssh connected
set UDPGW 127.0.0.1:7300
HTTP Custom ready to use
```
