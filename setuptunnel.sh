#!/bin/bash

curl -X POST "https://api.cloudflare.com/client/v4/accounts/aed6351b715621d8592005d2b96b2022/tunnels" \
     -H "Authorization: Bearer KDjypxaUbaHr93iSI3dWJzKF2YO2qxp4sYK52Ufy" \
     -H "Content-Type: application/json" \
     --data "{\"name\":\"openemr-tunnel\"}"
