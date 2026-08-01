NETWORK ENGINEER NOTES
======================

Your phone log:
  connected to socket 43.157.45.177:80
  HTTP/1.1 200 OK
  Connection lost: The connect timeout expired

That pattern means the TCP session reached *something* on :80 that answered
with a plain HTTP 200 and then sent nothing else. FastSSH free accounts answer:

  HTTP/1.1 200 OK
  HTTP/1.1 101 Switching Protocols
  SSH-2.0-dropbear_...

So either:
  A) nginx/apache/caddy still owns :80 (plain website 200)  ← most common
  B) old wsproxy without dual 101 + banner flush
  C) Dropbear down → handshake incomplete
  D) carrier middlebox drops the second HTTP message when it is a separate TCP segment

What this package does:
  1. Stops nginx/apache/caddy (they hurt, they do not help)
  2. Ensures Dropbear on 109 and prints its banner
  3. Installs wsproxy v7:
       - dual 200 + 101 (FastSSH shape)
       - TCP_CORK so 200+101+SSH banner leave as ONE segment
       - TCP_NODELAY + keepalive
  4. Local probe that MUST show 200 + 101 + SSH-2.0 before you test the phone

Run on VPS:
  sudo bash diagnose-and-fix.sh

Then watch while connecting from the phone:
  journalctl -u wsproxy -f

If local probe is green but phone still only sees 200:
  try Remote Proxy VPS-IP:443 with SSL ON (stunnel path, less middlebox interference)
