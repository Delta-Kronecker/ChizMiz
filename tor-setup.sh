cat > /tmp/final-bridge.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }
log() { echo -e "[INFO] $*"; }
[[ "$EUID" -ne 0 ]] && die "Run as root."

read -rp "Domain: " DOMAIN
[[ -z "$DOMAIN" ]] && die "Domain required."
read -rp "Email: " EMAIL
[[ -z "$EMAIL" ]] && die "Email required."
read -rp "Nickname (default TorBridge): " NICKNAME
NICKNAME="${NICKNAME:-TorBridge}"

log "Installing packages..."
apt-get update -qq && apt-get install -y -qq curl git nginx certbot python3-certbot-nginx golang-go ufw >/dev/null 2>&1

log "Firewall..."
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 9001/tcp; ufw allow 4443/tcp
ufw --force enable >/dev/null 2>&1

log "Tor repo..."
wget -qO- https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --dearmor > /usr/share/keyrings/tor-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $(lsb_release -cs) main" > /etc/apt/sources.list.d/tor.list
apt-get update -qq && apt-get install -y -qq tor obfs4proxy >/dev/null 2>&1

log "Building WebTunnel..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git clone -q https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel.git
cd webtunnel/main/server
go build -o webtunnel-server .
cp webtunnel-server /usr/local/bin/
chmod +x /usr/local/bin/webtunnel-server
cd / && rm -rf "$TMPDIR"

log "Nginx + SSL..."
rm -rf /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*
mkdir -p /var/www/tor-camouflage
echo "<html><body><h1>Welcome</h1></body></html>" > /var/www/tor-camouflage/index.html
cat > /etc/nginx/sites-available/bridge <<NGX
server { listen 80; server_name $DOMAIN; }
NGX
ln -sf /etc/nginx/sites-available/bridge /etc/nginx/sites-enabled/bridge
nginx -t && systemctl reload nginx
certbot --non-interactive --agree-tos --email "$EMAIL" --no-eff-email --nginx -d "$DOMAIN" >/dev/null 2>&1

SECRET_PATH=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
log "Secret: $SECRET_PATH"

cat > /etc/nginx/sites-available/bridge <<NGX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    root /var/www/tor-camouflage;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    location = /$SECRET_PATH {
        proxy_pass http://127.0.0.1:15000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        access_log off;
        error_log off;
    }
}
NGX
nginx -t && systemctl reload nginx

PUBLIC_IP=$(curl -4 -s --max-time 5 https://api.ipify.org || curl -4 -s --max-time 5 https://icanhazip.com)
[[ -z "$PUBLIC_IP" ]] && die "No public IP"

log "IP: $PUBLIC_IP"

cat > /etc/tor/torrc <<TORE
SocksPort 0
RunAsDaemon 0
DataDirectory /var/lib/tor
DisableDebuggerAttachment 1
BridgeRelay 1
PublishServerDescriptor 0
ORPort 0.0.0.0:9001
ExtORPort auto
Address $PUBLIC_IP
ContactInfo $EMAIL
Nickname $NICKNAME
ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ServerTransportListenAddr obfs4 0.0.0.0:4443
ServerTransportPlugin webtunnel exec /usr/local/bin/webtunnel-server
ServerTransportListenAddr webtunnel 127.0.0.1:15000
ServerTransportOptions webtunnel url=https://$DOMAIN/$SECRET_PATH
RelayBandwidthRate 31 MBytes
RelayBandwidthBurst 35 MBytes
MaxMemInQueues 4096 MB
TORE

systemctl stop tor@default 2>/dev/null || true
systemctl start tor@default
sleep 20

FINGERPRINT=$(awk '{print $2}' /var/lib/tor/fingerprint)
OFS4=$(grep '^Bridge obfs4' /var/lib/tor/pt_state/obfs4_bridgeline.txt | sed -e "s/<IP ADDRESS>/$PUBLIC_IP/g" -e "s/<PORT>/4443/g" -e "s/<FINGERPRINT>/$FINGERPRINT/g")
WT="webtunnel $PUBLIC_IP:443 $FINGERPRINT url=https://$DOMAIN/$SECRET_PATH"

echo ""
echo "============================================================"
echo "  SETUP COMPLETE"
echo "============================================================"
echo ""
echo "obfs4 bridge:"
echo "$OFS4"
echo ""
echo "WebTunnel bridge:"
echo "$WT"
echo ""
echo "Status: https://metrics.torproject.org/rs.html#details/$FINGERPRINT"
EOF

chmod +x /tmp/final-bridge.sh
sudo bash /tmp/final-bridge.sh
