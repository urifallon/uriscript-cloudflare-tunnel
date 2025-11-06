# --- Thay 3 biến này bằng giá trị của bạn ---
export CF_API_TOKEN="KDjypxaUbaHr93iSI3dWJzKF2YO2qxp4sYK52Ufy"
export CF_ACCOUNT_ID="aed6351b715621d8592005d2b96b2022"
export DOMAIN="fatbeo.com"   # domain bạn quản lý trên Cloudflare
# ------------------------------------------------

# 1) tạo tunnel (không cần cert.pem)
TUNNEL_NAME="openemr-tunnel"
tunnel_json=$(cloudflared tunnel create "$TUNNEL_NAME" --api-token "$CF_API_TOKEN" --account-id "$CF_ACCOUNT_ID" 2>&1) || { echo "tunnel create failed"; echo "$tunnel_json"; exit 1; }

# lấy tunnel id từ output
TUNNEL_ID=$(echo "$tunnel_json" | sed -n 's/.*Created tunnel .* with id \([0-9a-f-]\+\).*/\1/p' | head -n1)
if [ -z "$TUNNEL_ID" ]; then
  # fallback: list tunnels
  TUNNEL_ID=$(cloudflared tunnel list --api-token "$CF_API_TOKEN" --account-id "$CF_ACCOUNT_ID" --format json 2>/dev/null | jq -r '.[0].id')
fi
echo "TUNNEL_ID=$TUNNEL_ID"

# 2) viết config.yml
sudo mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:80
  - service: http_status:404
EOF
sudo chmod 600 /etc/cloudflared/config.yml

# 3) tạo DNS CNAME record trỏ domain → tunnel (phải có ZONE_ID)
# Lấy zone id cho zone gốc:
ZONE_NAME=${DOMAIN#*.}   # openemr.example.com -> example.com
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')
echo "ZONE_ID=$ZONE_ID"

# tạo record CNAME
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"CNAME\",\"name\":\"$DOMAIN\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" \
  | jq

# 4) start tunnel service
sudo tee /etc/systemd/system/cloudflared.service >/dev/null <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared --no-pager -l
