#!/usr/bin/env bash
set -Eeuo pipefail
echo "== edge-boot.service (this boot) =="
journalctl -u edge-boot.service -b --no-pager | tail -n 120 || true
echo
echo "== env: MODBUS_IP / PORT =="
grep -E '^(MODBUS_IP|MODBUS_PORT)=' /opt/edge-boot/env.edge || echo "No MODBUS_* found"
echo
echo "== Docker =="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | sed '1,1p'
echo
ip -4 addr show dev eth0 | sed 's/^/eth0: /'
ip -4 addr show dev wlan0 | sed 's/^/wlan0: /'
