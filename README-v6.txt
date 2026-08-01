v6 fix — match FastSSH CONNECT exactly
======================================

Your FastSSH success log proves the server MUST send:

  HTTP/1.1 200 OK
  HTTP/1.1 101 Switching Protocols
  SSH-2.0-dropbear_...

NOT a lone "200 Connection Established".

What was wrong before:
  After dual 200+101 the SSH banner sometimes arrived too late (or not at
  all), so HTTP Custom reported "Premature connection close".

What v6 does:
  1. Always dual 200 + 101 for CONNECT (same as FastSSH)
  2. Connect to Dropbear first, peek the SSH banner, send handshake + banner
     in one write so the client never sees an empty tunnel
  3. Sec-WebSocket-Accept when the client sends a key
  4. Brand reason phrase = "Switching Protocols"

Apply:
  unzip jahimvj-v5-zero-rated-fix.zip
  cd jahimvj-v5
  sudo bash quickfix.sh

HTTP Custom settings (identical to working FastSSH free account):
  Remote Proxy : VPS-IP:80
  Payload      : CONNECT https://wifipay.co.ke:UC19O866GH HTTP/1.1[crlf]Host: https://netpap.co.ke:UC19O866GH[crlf]Connection: keep-alive[crlf]X-Online-Host: m.netpap.co.ke:UC19O866GH[crlf]X-Forward-Host: m.netpap.co.ke:UC19O866GH[crlf][crlf]
  SSH port     : 109
  UDPGW        : 127.0.0.1:7300
