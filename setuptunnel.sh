#!/bin/bash
set -euo pipefail

# === 1) Sửa 3 giá trị ở đây trước khi chạy ===
CF_API_TOKEN="KDjypxaUbaHr93iSI3dWJzKF2YO2qxp4sYK52Ufy"
CF_ACCOUNT_ID="aed6351b715621d8592005d2b96b2022"
DOMAIN="fatbeo.com"        # ví dụ openemr.example.com
TUNNEL_NAME="openemr-tunnel"        # tên tunnel muốn tạo
# ============================================

# safety check
if [[ "$CF_API_TOKEN" == "PUT_YOUR_CF_API_TOKEN_HERE" || "$CF_ACCOUNT_ID" == "PUT_YOUR_CF_ACCOUNT_ID_HERE" || "$DOMAIN" == "put.your.domain.here" ]]; then
  echo "ERROR: bạn phải chỉnh CF_API_TOKEN, CF_ACCOUNT_ID và DOMAIN trong file trước khi chạy."
  exit 2
fi

# ensure dependencies
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ERROR: cloudflared chưa cài. Hãy cài trước rồi chạy lại."
  echo "Gợi ý: tải .deb từ https://github.com/cloudflare/cloudflared/releases và dpkg -i"
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Đang cài jq..."
  sudo apt update
  sudo apt install -y jq
fi

CLOUDFLARED_BIN=$(command -v cloudflared || echo /usr/bin/cloudflared)
echo "Using cloudflared: $CLOUDFLARED_BIN"

# create tunnel (using API token & account id)
echo "=> Tạo tunnel tên: $TUNNEL_NAME"
tunnel_output=$(cloudflared tunnel create "$TUNNEL_NAME" --api-token "$CF_API_TOKEN" --account-id "$CF_ACCOUNT_ID" 2>&1) || {
  echo "Warning: cloudflared tunnel create failed or returned warnings; output below:"
  echo "$tunnel_output"
  # continue to try to find tunnel id from list
}

# try to parse TUNNEL_ID
TUNNEL_ID=$(echo "$tunnel_output" | grep -oE '[0-9a-f]{8,}-[0-9a-f-]+' | head -n1 || true)
if [ -z "$TUNNEL_ID" ]; then
  echo "Không tìm Tunnel ID từ output, liệt kê tunnel hiện có..."
  list_json=$(cloudflared tunnel list --api-token "$CF_API_TOKEN" --account-id "$CF_ACCOUNT_ID" --format json 2>/dev/null || true)
  TUNNEL_ID=$(echo "$list_json" | jq -r --arg name "$TUNNEL_NAME" 'map(select(.name==$name)) | .[0].id // empty')
fi

if [ -z "$TUNNEL_ID" ]; then
  echo "ERROR: Không lấy được TUNNEL_ID. Kiểm tra token/permission hoặc tạo tunnel thủ công."
  exit 4
fi
echo "TUNNEL_ID=${TUNNEL_ID}"

# prepare credentials file destination
sudo mkdir -p /etc/cloudflared
CRED_DST="/etc/cloudflared/${TUNNEL_ID}.json"

# move credentials if created under root's .cloudflared
if [ -f "/root/.cloudflared/${TUNNEL_ID}.json" ] && [ ! -f "${CRED_DST}" ]; then
  echo "Moving credentials from /root/.cloudflared -> ${CRED_DST}"
  sudo mv "/root/.cloudflared/${TUNNEL_ID}.json" "${CRED_DST}"
  sudo chown root:root "${CRED_DST}"
  sudo chmod 600 "${CRED_DST}"
fi

# if not found, try to find anywhere
if [ ! -f "${CRED_DST}" ]; then
  found=$(sudo find / -type f -name "*${TUNNEL_ID}*.json" 2>/dev/null | head -n1 || true)
  if [ -n "$found" ]; then
    echo "Found credentials at $found, moving to ${CRED_DST}"
    sudo mv "$found" "${CRED_DST}"
    sudo chown root:root "${CRED_DST}"
    sudo chmod 600 "${CRED_DST}"
  else
    echo "WARNING: credentials JSON not found. cloudflared may have placed it elsewhere or create failed."
  fi
fi

# write config.yml
echo "-> Tạo /etc/cloudflared/config.yml"
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_DST}

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:80
  - service: http_status:404
EOF
sudo chmod 600 /etc/cloudflared/config.yml

# create/update DNS CNAME via Cloudflare API
ZONE_NAME=${DOMAIN#*.}
echo "-> Lấy ZONE_ID cho $ZONE_NAME"
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

if [ -z "$ZONE_ID" ]; then
  echo "ERROR: Không lấy được ZONE_ID. Kiểm tra CF_API_TOKEN/Account và tên zone ($ZONE_NAME)."
  exit 5
fi
echo "ZONE_ID=${ZONE_ID}"

# create or update record
echo "-> Tạo hoặc cập nhật DNS CNAME: ${DOMAIN} -> ${TUNNEL_ID}.cfargotunnel.com"
existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0] // empty')

if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  RECORD_ID=$(echo "$existing" | jq -r '.id')
  echo "Updating DNS record ${RECORD_ID}"
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${DOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" | jq
else
  echo "Creating DNS record"
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${DOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" | jq
fi

# install systemd service
echo "-> Cài systemd service và start cloudflared"
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

echo "Hoàn tất. Test: curl -I https://${DOMAIN}"
