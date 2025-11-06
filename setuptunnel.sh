#!/bin/bash

CF_API_TOKEN="KDjypxaUbaHr93iSI3dWJzK52Ufy"
CF_ACCOUNT_ID="aed6351b715621d8592005d2b96b202"
TUNNEL_ID="6ae8a17d-9e51-4c2a-8850-22f30be2502f"
DOMAIN="fatbeo.com"
ZONE_NAME=${DOMAIN#*.}

ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
  --data "{\"type\":\"CNAME\",\"name\":\"${DOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" | jq
