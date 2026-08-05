cat > /root/tor-setup.sh << 'ENDOFSCRIPT'
#!/usr/bin/env bash
set -uo pipefail

die() { echo -e "\n[ERROR] $*" >&2; exit 1; }
log() { echo -e "[INFO] $*"; }

[[ "$EUID" -ne 0 ]] && die "Please run as root."

cat << "INTRO"

============================================================
   Personal Tor Bridge Setup (obfs4 + WebTunnel)
============================================================
INTRO

read -rp "Domain/subdomain (e.g., bridge.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && die "Domain cannot be empty."
read -rp "Email address: " EMAIL
[[ -z "$EMAIL" ]] && die "Email cannot be empty."
read -rp "Bridge nickname (default: TorBridge): " NICKNAME
NICKNAME="${NICKNAME:-TorBridge}"

log "Updating system and installing packages..."
apt-get update -qq
apt-get install -y -qq curl wget git nginx certbot python3-certbot-nginx golang-go ufw gnupg dnsutils lsb-release >/dev/null 2>&1

log "Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 9001/tcp
ufw allow 4443/tcp
ufw --force enable >/dev/null 2>&1

log "Installing Tor and obfs4proxy..."
wget -qO- https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --dearmor > /usr/share/keyrings/tor-archive-keyring.gpg
CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $CODENAME main" > /etc/apt/sources.list.d/tor.list
apt-get update -qq
apt-get install -y -qq tor obfs4proxy >/dev/null 2>&1

log "Building WebTunnel..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git clone -q https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel.git
cd webtunnel/main/server
go build -o webtunnel-server .
cp webtunnel-server /usr/local/bin/
chmod +x /usr/local/bin/webtunnel-server
cd /
rm -rf "$TMPDIR"

mkdir -p /var/www/tor-camouflage
cat > /var/www/tor-camouflage/index.html <<'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Welcome</title></head><body><h1>Welcome</h1><p>Nothing to see here.</p></body></html>
EOF

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true

cat > /etc/nginx/sites-available/bridge <<EOF
server { listen 80; server_name $DOMAIN; }
EOF
ln -sf /etc/nginx/sites-available/bridge /etc/nginx/sites-enabled/bridge
nginx -t && systemctl reload nginx

certbot --non-interactive --agree-tos --email "$EMAIL" --no-eff-email --nginx -d "$DOMAIN" 2>&1 | tail -5

SECRET_PATH=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
log "Secret path: $SECRET_PATH"

cat > /etc/nginx/sites-available/bridge <<NGINXCONF
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
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
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
NGINXCONF
nginx -t && systemctl reload nginx

PUBLIC_IP=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null || dig +short myip.opendns.com @resolver1.opendns.com)
[[ -z "$PUBLIC_IP" ]] && die "Could not detect public IP."

log "Public IP: $PUBLIC_IP"

cat > /etc/tor/torrc <<EOF
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
EOF

systemctl stop tor@default 2>/dev/null || true
systemctl reset-failed tor@default 2>/dev/null || true
systemctl start tor@default

for i in $(seq 1 30); do [[ -f /var/lib/tor/fingerprint ]] && break; sleep 2; done
[[ ! -f /var/lib/tor/fingerprint ]] && die "Fingerprint not found."

FINGERPRINT=$(awk '{print $2}' /var/lib/tor/fingerprint)

OFS4_FILE="/var/lib/tor/pt_state/obfs4_bridgeline.txt"
if [[ -f "$OFS4_FILE" ]]; then
    OFS4_LINE=$(grep '^Bridge obfs4' "$OFS4_FILE" | sed -e "s/<IP ADDRESS>/$PUBLIC_IP/g" -e "s/<PORT>/4443/g" -e "s/<FINGERPRINT>/$FINGERPRINT/g")
else
    OFS4_LINE="obfs4 bridge file not found"
fi

WT_LINE="webtunnel $PUBLIC_IP:443 $FINGERPRINT url=https://$DOMAIN/$SECRET_PATH"

echo ""
echo "============================================================"
echo "  Setup complete!"
echo "============================================================"
echo ""
echo "obfs4 bridge:"
echo "$OFS4_LINE"
echo ""
echo "WebTunnel bridge:"
echo "$WT_LINE"
echo ""
echo "Status: https://metrics.torproject.org/rs.html#details/$(awk '{print $2}' /var/lib/tor/fingerprint)"
ENDOFSCRIPT

chmod +x /root/tor-setup.sh
