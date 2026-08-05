#!/usr/bin/env bash
#=============================================================================
# personal-tor-bridge.sh — Automated private Tor bridge setup (obfs4 + WebTunnel)
#=============================================================================
# Prerequisites:
# 1. Ubuntu 24.04 server with root access
# 2. A domain/subdomain with an A record pointing to this server's public IP
# 3. Ports 80, 443, 9001, 4443 open in the cloud firewall (external)
#-----------------------------------------------------------------------------

set -euo pipefail

die() { echo -e "\n[ERROR] $*" >&2; exit 1; }
log() { echo -e "[INFO] $*"; }

# Check root
[[ "$EUID" -ne 0 ]] && die "Please run this script as root (sudo)."

# --- Gather user input ---
cat << "INTRO"

============================================================
   Personal Tor Bridge Setup (obfs4 + WebTunnel)
============================================================
INTRO

read -rp "Domain/subdomain (e.g., bridge.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && die "Domain cannot be empty."

read -rp "Email address (for Let's Encrypt notifications): " EMAIL
[[ -z "$EMAIL" ]] && die "Email cannot be empty."

read -rp "Bridge nickname (default: TorBridge): " NICKNAME
NICKNAME="${NICKNAME:-TorBridge}"

# --- 1. Install essential packages ---
log "Updating system and installing essential packages..."
apt-get update -qq
apt-get install -y -qq curl wget git nginx certbot python3-certbot-nginx \
    golang-go ufw gnupg dnsutils lsb-release >/dev/null 2>&1

# --- 2. Configure internal firewall (ufw) ---
log "Configuring firewall (ufw)..."
ufw allow 22/tcp          # keep SSH alive
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 9001/tcp
ufw allow 4443/tcp
ufw --force enable >/dev/null 2>&1

# --- 3. Add official Tor repo and install Tor + obfs4proxy ---
log "Adding official Tor repository and installing Tor and obfs4proxy..."
wget -qO- https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | \
    gpg --dearmor > /usr/share/keyrings/tor-archive-keyring.gpg
CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $CODENAME main" \
    > /etc/apt/sources.list.d/tor.list
apt-get update -qq
apt-get install -y -qq tor obfs4proxy >/dev/null 2>&1 || die "Tor/obfs4proxy installation failed."

# --- 4. Build WebTunnel from source ---
log "Building WebTunnel pluggable transport (this may take a few minutes)..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git clone -q https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel.git
cd webtunnel/main/server
go build -o webtunnel-server . || die "WebTunnel compilation failed."
cp webtunnel-server /usr/local/bin/
chmod +x /usr/local/bin/webtunnel-server
cd /
rm -rf "$TMPDIR"

# --- 5. Camouflage website for Nginx ---
log "Creating camouflage website..."
mkdir -p /var/www/tor-camouflage
cat > /var/www/tor-camouflage/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Welcome</title></head>
<body><h1>Welcome</h1><p>Nothing to see here.</p></body>
</html>
EOF

# --- 6. Obtain SSL certificate via Certbot ---
log "Obtaining SSL certificate for $DOMAIN..."
cat > /etc/nginx/sites-available/"$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
}
EOF
ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

certbot --non-interactive --agree-tos --email "$EMAIL" --no-eff-email \
    --nginx -d "$DOMAIN" 2>&1 | grep -v "warning" || die "SSL certificate issuance failed."

# --- 7. Generate secret path for WebTunnel ---
SECRET_PATH=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
log "Secret WebTunnel path: $SECRET_PATH"

# --- 8. Final Nginx configuration (with WebTunnel proxy) ---
log "Applying final Nginx configuration..."
# Using <<'NGINXEOF' to avoid shell expansion of $uri, $host, etc.
cat > /etc/nginx/sites-available/"$DOMAIN" <<'NGINXEOF'
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    root /var/www/tor-camouflage;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location = /SECRET_PLACEHOLDER {
        proxy_pass http://127.0.0.1:15000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
        access_log off;
        error_log off;
    }
}
NGINXEOF

# Replace placeholders with actual values
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/"$DOMAIN"
sed -i "s/SECRET_PLACEHOLDER/$SECRET_PATH/g" /etc/nginx/sites-available/"$DOMAIN"

nginx -t && systemctl reload nginx || die "Nginx configuration test failed."

# --- 9. Detect public IP ---
log "Detecting public IP address..."
PUBLIC_IP=""
for srv in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me" "https://checkip.amazonaws.com"; do
    PUBLIC_IP=$(curl -4 -s --max-time 5 "$srv" 2>/dev/null || true)
    [[ -n "$PUBLIC_IP" ]] && break
done
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)
fi
[[ -z "$PUBLIC_IP" ]] && die "Could not detect public IP. Please set it manually."

log "Public IP: $PUBLIC_IP"

# --- 10. Write Tor configuration ---
log "Writing /etc/tor/torrc..."
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

# --- 11. Start Tor service ---
log "Starting Tor service..."
systemctl stop tor@default 2>/dev/null || true
systemctl reset-failed tor@default 2>/dev/null || true
systemctl start tor@default

# --- 12. Wait for fingerprint file ---
FINGERPRINT_FILE="/var/lib/tor/fingerprint"
log "Waiting for Tor to generate fingerprint..."
for i in $(seq 1 30); do
    if [[ -f "$FINGERPRINT_FILE" ]]; then
        break
    fi
    sleep 2
done

if [[ ! -f "$FINGERPRINT_FILE" ]]; then
    die "Fingerprint file not created. Check logs with: journalctl -u tor@default -n 50"
fi

FINGERPRINT=$(awk '{print $2}' "$FINGERPRINT_FILE")
log "Bridge fingerprint: $FINGERPRINT"

# --- 13. Generate bridge lines ---
OFS4_FILE="/var/lib/tor/pt_state/obfs4_bridgeline.txt"
if [[ -f "$OFS4_FILE" ]]; then
    OFS4_LINE=$(grep '^Bridge obfs4' "$OFS4_FILE" | \
        sed -e "s/<IP ADDRESS>/$PUBLIC_IP/g" -e "s/<PORT>/4443/g" -e "s/<FINGERPRINT>/$FINGERPRINT/g")
else
    OFS4_LINE="⚠️  obfs4 bridge line file not found. Something may be wrong."
fi

WT_LINE="webtunnel $PUBLIC_IP:443 $FINGERPRINT url=https://$DOMAIN/$SECRET_PATH"

# --- 14. Final output ---
cat << "RESULT"

============================================================
  ✅ Setup completed successfully!
============================================================
RESULT

echo -e "📍 obfs4 bridge line:\n$OFS4_LINE\n"
echo -e "📍 WebTunnel bridge line:\n$WT_LINE\n"
echo "🔗 Status: https://metrics.torproject.org/rs.html#details/$(awk '{print $2}' /var/lib/tor/fingerprint)"
echo ""
echo "Note: Ensure ports 80, 443, 9001, 4443 are open in your external (cloud) firewall."

exit 0
