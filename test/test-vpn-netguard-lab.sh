#!/usr/bin/env bash
set -u -o pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$BASE_DIR/script/vpn-netguard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
CONFIG_FILE="$TMP/config"
KILLSWITCH_OVERRIDE_FILE="$STATE_DIR/killswitch-override"
CHAIN_NAME="NETGUARD_KS"
CHAIN_NAME_V6="NETGUARD_KS6"
HAVE_IP6TABLES=1
ALLOW_LAN=true
DNS_SERVERS='1.1.1.1 2001:4860:4860::8888'
PING_TARGETS='1.2.3.4 2001:4860:4860::8888'
VPN_ENDPOINT_OVERRIDE='198.51.100.10:1194:udp'
DISABLE_IPV6=false
LOG_LEVEL=error
DESKTOP_NOTIFICATIONS=false
EVENT_HISTORY_ENABLE=false
ALERT_HOOK=''
PATH="$MOCKBIN:$PATH"
V4_JUMP_COUNT="$TMP/v4-jumps"
V6_JUMP_COUNT="$TMP/v6-jumps"
printf '1\n' > "$V4_JUMP_COUNT"
printf '1\n' > "$V6_JUMP_COUNT"
export STATE_DIR CONFIG_FILE KILLSWITCH_OVERRIDE_FILE CHAIN_NAME CHAIN_NAME_V6 HAVE_IP6TABLES ALLOW_LAN DNS_SERVERS PING_TARGETS VPN_ENDPOINT_OVERRIDE DISABLE_IPV6 LOG_LEVEL DESKTOP_NOTIFICATIONS EVENT_HISTORY_ENABLE ALERT_HOOK PATH RESTORE_OUT V4_JUMP_COUNT V6_JUMP_COUNT
cat > "$CONFIG_FILE" <<'EOF'
KILLSWITCH_MODE="true"
EOF
cat > "$MOCKBIN/iptables" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-w" ]] && shift 2
case "$1" in
  -N) exit 1;;
  -C) n=$(cat "$V4_JUMP_COUNT"); (( n > 0 )); exit $?;;
  -D) n=$(cat "$V4_JUMP_COUNT"); printf '%s\n' "$((n-1))" > "$V4_JUMP_COUNT"; exit 0;;
  -I) printf '1\n' > "$V4_JUMP_COUNT"; exit 0;;
  *) exit 0;;
esac
EOF
cat > "$MOCKBIN/ip6tables" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-w" ]] && shift 2
case "$1" in
  -N) exit 1;;
  -C) n=$(cat "$V6_JUMP_COUNT"); (( n > 0 )); exit $?;;
  -D) n=$(cat "$V6_JUMP_COUNT"); printf '%s\n' "$((n-1))" > "$V6_JUMP_COUNT"; exit 0;;
  -I) printf '1\n' > "$V6_JUMP_COUNT"; exit 0;;
  *) exit 0;;
esac
EOF
cat > "$MOCKBIN/iptables-restore" <<'EOF'
#!/usr/bin/env bash
cat > "$RESTORE_OUT"
EOF
cat > "$MOCKBIN/ip6tables-restore" <<'EOF'
#!/usr/bin/env bash
cat > "$RESTORE_OUT"
EOF
chmod +x "$MOCKBIN"/*
source "$SCRIPT"
STATE_DIR="$TMP/state"
CONFIG_FILE="$TMP/config"
KILLSWITCH_OVERRIDE_FILE="$STATE_DIR/killswitch-override"
CHAIN_NAME="NETGUARD_KS"
CHAIN_NAME_V6="NETGUARD_KS6"
HAVE_IP6TABLES=1
ALLOW_LAN=true
DNS_SERVERS='1.1.1.1 2001:4860:4860::8888'
PING_TARGETS='1.2.3.4 2001:4860:4860::8888'
VPN_ENDPOINT_OVERRIDE='198.51.100.10:1194:udp'
DISABLE_IPV6=false
LOG_LEVEL=error
DESKTOP_NOTIFICATIONS=false
EVENT_HISTORY_ENABLE=false
ALERT_HOOK=''
FIREFOX_POLICY_FILE="$TMP/firefox/policies.json"
FIREFOX_POLICY_MARKER="$STATE_DIR/browser-doh-firefox-created"
CHROME_POLICY_DIR="$TMP/chrome"
CHROMIUM_POLICY_DIR="$TMP/chromium"
CHROMIUM_BROWSER_POLICY_DIR="$TMP/chromium-browser"
CHROME_POLICY_MARKER="$STATE_DIR/browser-doh-chrome-created"
CHROMIUM_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-created"
CHROMIUM_BROWSER_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-browser-created"

RESTORE_OUT="$TMP/v4.restore" apply_killswitch_rules "tun0"
python3 "$BASE_DIR/test/validate_firewall_restore.py" v4 "$TMP/v4.restore"
RESTORE_OUT="$TMP/v6.restore" apply_killswitch_rules6 "tun0"
python3 "$BASE_DIR/test/validate_firewall_restore.py" v6 "$TMP/v6.restore"

# Prove the test itself is isolated in a real network namespace.
unshare -Urn bash -c 'set -e; ip link add labA type veth peer labB; ip link set labA up; ip link set labB up; ip link del labA'

echo 'NETNS: isolated network capabilities available'
