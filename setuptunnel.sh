# ---- CHÚ Ý: trước khi chạy, export CF_API_TOKEN và CF_ACCOUNT_ID ----
# export CF_API_TOKEN="eyJ...."
# export CF_ACCOUNT_ID="your-account-id"
# --------------------------------------------------------------------

set -euo pipefail

# Thay domain tại đây
DOMAIN="fatbeo.com"
TUNNEL_NAME="openemr-tunnel"

# Kiểm tra biến môi trường token/account
if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ]; then
  echo "ERROR: Bạn phải export CF_API_TOKEN và CF_ACCOUNT_ID trước khi chạy."
  exit 1
fi

# Ensure tools
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ERROR: cloudflared chưa cài. Cài trước rồi thử lại."
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  sudo apt update
  sudo apt install -y jq
fi

# find cloudflared binary path for systemd ExecStart
CLOUDFLARED_BIN=$(command -v cloudflared || true)
if [ -z "$CLOUDFLARED_BIN" ]; then
  CLOUDFLARED_BIN="/usr/bin/cloudflared"
fi
echo "Using cloudflared binary: $CLOUDFLARED_BIN"

# 1) create tunnel using API token (returns credentials file path)
echo "--- Creating tunnel: $TUNNEL_NAME"
tunnel_output=$(cloudflared tunnel create "$TUNNEL_NAME" --api-token "$CF_API_TOKEN" --account-id "$CF_ACCOUNT_ID" 2>&1) || {
  echo "Tunnel create failed, output:"
  echo "$tunnel_output"
  # If tunnel already exists, try to read from list
}

# Try extract tunnel id from output; if fails, list tunnels via API
TUNNEL_ID=$(echo "$tunnel_output" | grep -oE '[0-9a-f-]{20,}' | head -n1 || true)

if [ -z "$TUNNEL_ID" ]; then
  echo "Falling back to cloudflared tunnel list to find tunnel id..."
  # use cloudflared list (requires token/accounts) and match by name
  list_json=$(cloudflared tunnel list --api-token "$CF_API_TOKEN" --account-id "$CF_ACCOUNT_ID" --format json 2>/dev/null || true)
  TUNNEL_ID=$(echo "$list_json" | jq -r --arg name "$TUNNEL_NAME" 'map(select(.name==$name)) | .[0].id // empty')
fi

if [ -z "$TUNNEL_ID" ]; then
  echo "ERROR: Không tìm được TUNNEL ID. Kiểm tra output ở trên."
  exit 1
fi

echo "TUNNEL_ID=$TUNNEL_ID"

# Move credentials file to /etc/cloudflared if cloudflared put it somewhere else
CRED_SRC="/root/.cloudflared/${TUNNEL_ID}.json"
CRED_DST="/etc/cloudflared/${TUNNEL_ID}.json"
sudo mkdir -p /etc/cloudflared
if [ -f "$CRED_SRC" ] && [ ! -f "$CRED_DST" ]; then
  echo "Moving credentials $CRED_SRC -> $CRED_DST"
  sudo mv "$CRED_SRC" "$CRED_DST"
  sudo chown root:root "$CRED_DST"
  sudo chmod 600 "$CRED_DST"
fi

# If credentials file not found, warn (cloudflared create should have created it)
if [ ! -f "$CRED_DST" ]; then
  # try to discover any credential file that contains tunnel id
  possible=$(sudo find / -path "/etc/cloudflared/${TUNNEL_ID}.json" -o -path "/root/.cloudflared/${TUNNEL_ID}.json" 2>/dev/null || true)
  if [ -n "$possible" ]; then
    echo "Found credentials at: $possible"
    sudo mv "$possible" "$CRED_DST"
    sudo chown root:root "$CRED_DST"
    sudo chmod 600 "$CRED_DST"
  else
    echo "WARNING: credentials file $CRED_DST not found. The tunnel may not run until credential file exists."
  fi
fi

# 2) write config.yml
echo "--- Writing /etc/cloudflared/config.yml"
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_DST

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:80
  - service: http_status:404
EOF
sudo chmod 600 /etc/cloudflared/config.yml

# 3) create or update DNS CNAME for the domain -> <tunnel>.cfargotunnel.com
ZONE_NAME=${DOMAIN#*.}
echo "ZONE_NAME=$ZONE_NAME"
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

if [ -z "$ZONE_ID" ]; then
  echo "ERROR: Không lấy được ZONE_ID cho $ZONE_NAME — kiểm tra token/quyền và tên zone."
  exit 1
fi
echo "ZONE_ID=$ZONE_ID"

# check if record exists
existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0] // empty')

if [ -n "$existing" ]; then
  RECORD_ID=$(echo "$existing" | jq -r '.id')
  echo "Updating existing DNS record $RECORD_ID -> ${TUNNEL_ID}.cfargotunnel.com"
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"$DOMAIN\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" | jq
else
  echo "Creating DNS record for $DOMAIN -> ${TUNNEL_ID}.cfargotunnel.com"
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"$DOMAIN\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" | jq
fi

# 4) create systemd service and start
echo "--- Installing systemd service for cloudflared"
sudo tee /etc/systemd/system/cloudflared.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=${CLOUDFLARED_BIN} --config /etc/cloudflared/config.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sleep 1
sudo systemctl status cloudflared --no-pager -l || true

echo "DONE. Test with: curl -I https://$DOMAIN"
