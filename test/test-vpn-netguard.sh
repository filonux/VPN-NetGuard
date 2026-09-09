#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${VPN_NETGUARD_TEST_SCRIPT:-$SCRIPT_DIR/script/vpn-netguard.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

say_ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
say_fail() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }
run_test() {
    local name="$1"; shift
    local test_id=""
    if [[ "${1:-}" =~ ^T[0-9]+$ ]]; then
        test_id="$1"; shift
    fi
    if [[ -n "${VPN_NETGUARD_TEST_ONLY:-}" && ",${VPN_NETGUARD_TEST_ONLY}," != *",${test_id},"* ]]; then
        return 0
    fi
    if [[ -n "$test_id" && $# -eq 0 ]]; then
        set -- "$test_id"
    fi
    if ( "$@" ); then say_ok "${test_id:+$test_id }$name"; else say_fail "${test_id:+$test_id }$name"; fi
}

new_env() {
    TEST_ROOT="$(mktemp -d "$TMP/env.XXXXXX")"
    export TEST_ROOT
    MOCKBIN="$TEST_ROOT/bin"; mkdir -p "$MOCKBIN"
    STATE_DIR="$TEST_ROOT/state"; mkdir -p "$STATE_DIR"
    STATE_FILE="$STATE_DIR/wanted"
    KILLSWITCH_OVERRIDE_FILE="$STATE_DIR/killswitch-override"
    CONFIG_FILE="$TEST_ROOT/vpn-netguard.conf"
    NM_PRIVACY_CONF="$TEST_ROOT/NetworkManager.conf"
    UNIT_DST="$TEST_ROOT/vpn-netguard.service"
    BOOT_UNIT_DST="$TEST_ROOT/vpn-netguard-boot.service"
    MAC_ROTATE_UNIT_DST="$TEST_ROOT/vpn-netguard-mac-rotate.service"
    MAC_ROTATE_TIMER_DST="$TEST_ROOT/vpn-netguard-mac-rotate.timer"
    DESKTOP_DST="$TEST_ROOT/vpn-netguard.desktop"
    BIN_DST="$TEST_ROOT/bin-installed/vpn-netguard.sh"
    FIREFOX_POLICY_FILE="$TEST_ROOT/firefox/policies.json"
    CHROME_POLICY_DIR="$TEST_ROOT/chrome"
    CHROMIUM_POLICY_DIR="$TEST_ROOT/chromium"
    CHROMIUM_BROWSER_POLICY_DIR="$TEST_ROOT/chromium-browser"
    FIREFOX_POLICY_MARKER="$STATE_DIR/browser-doh-firefox-created"
    CHROME_POLICY_MARKER="$STATE_DIR/browser-doh-chrome-created"
    CHROMIUM_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-created"
    CHROMIUM_BROWSER_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-browser-created"
    LOCK_FILE="$TEST_ROOT/lock"
    NOTIFY_STATE_FILE="$STATE_DIR/notify-state"
    EVENT_HISTORY_FILE="$STATE_DIR/history.csv"
    EVENT_HISTORY_STATE_FILE="$STATE_DIR/history-last-state"
    HEARTBEAT_FILE="$STATE_DIR/heartbeat"
    MAC_ROTATE_TOKEN_FILE="$STATE_DIR/mac-rotate-token"
    KNOWN_ETH=() KNOWN_WIFI=() KNOWN_VPN=() KS_VPN_CANDIDATES=()
    ACTIVE_ETH="" ACTIVE_WIFI="" ACTIVE_VPN="" VPN_IFACE="" VPN_TYPE="" PHYS_IFACE=""
    DNS_MISMATCH_WARNED=0
    PATH="$MOCKBIN:$ORIG_PATH"
    hash -r
    base_config
    load_config >/dev/null 2>&1 || return 1
}

ORIG_PATH="$PATH"
source "$SCRIPT"

base_config() {
    cat > "$CONFIG_FILE" <<'EOF'
LANGUAGE="es"
KILLSWITCH_MODE="auto"
ALLOW_LAN="true"
CHECK_INTERVAL=25
RECONNECT_BACKOFF="5 15 30 60 120"
PING_TARGETS="1.1.1.1 8.8.8.8"
PING_TIMEOUT=3
LOG_LEVEL="info"
DNS_SERVERS="1.1.1.1 9.9.9.9"
DESKTOP_NOTIFICATIONS="false"
ALERT_HOOK=""
PROMETHEUS_TEXTFILE_DIR=""
EVENT_HISTORY_ENABLE="true"
EVENT_HISTORY_MAX_LINES=5000
ANONYMIZE_NETWORK="true"
MAC_MODE="stable"
MAC_OUI_MASK=""
ROTATE_MAC_PER_BOOT="false"
ROTATE_MAC_EVERY_HOURS=0
RANDOMIZE_SCAN_MAC="true"
SPOOF_HOSTNAME="true"
DHCP_HOSTNAME_OVERRIDE=""
HARDEN_DHCP_IDENTIFIERS="true"
IPV6_PRIVACY="true"
DISABLE_IPV6="false"
DISABLE_MDNS_ANNOUNCE="true"
DISABLE_AVAHI_SERVICE="false"
DISABLE_NETBIOS_SERVICE="false"
HARDEN_BROWSER_DOH="false"
EOF
}

mock() {
    local name="$1" body="$2"
    hash -r
    printf '%s\n' '#!/usr/bin/env bash' "$body" > "$MOCKBIN/$name"
    chmod +x "$MOCKBIN/$name"
}

T1() { bash -n "$SCRIPT" && bash -u -n "$SCRIPT"; }
T2() {
    new_env; UI_LANGUAGE=en; ui_init
    [[ "$(ui_t status.header)" == '== vpn-netguard: current status ==' ]]
    UI_LANGUAGE=es; ui_init
    [[ "$(ui_t status.header)" == '== vpn-netguard: estado actual ==' ]]
}
T3() {
    new_env
    base_config
    load_config
    [[ "$CHECK_INTERVAL" == 25 && "$PING_TIMEOUT" == 3 && "$EVENT_HISTORY_MAX_LINES" == 5000 ]]
    printf 'CHECK_INTERVAL="08"\nEVENT_HISTORY_MAX_LINES="0009"\nROTATE_MAC_EVERY_HOURS="07"\n' >> "$CONFIG_FILE"
    load_config
    [[ "$CHECK_INTERVAL" == 8 && "$EVENT_HISTORY_MAX_LINES" == 9 && "$ROTATE_MAC_EVERY_HOURS" == 7 ]]
}
T4() {
    new_env
    mock nmcli 'if [[ "$*" == *"-t -e yes -f NAME,TYPE connection show"* ]]; then cat <<EOF
Office\\:Lab:802-3-ethernet
Wi\\:Fi:802-11-wireless
VPN Main:vpn
EOF
fi'
    ETH_CONNECTION=""; WIFI_CONNECTION=""; VPN_CONNECTION=""
    detect_known_profiles
    [[ "${KNOWN_ETH[0]}" == 'Office:Lab' && "${KNOWN_WIFI[0]}" == 'Wi:Fi' && "${KNOWN_VPN[0]}" == 'VPN Main' ]]
}
T5() {
    new_env
    mock nmcli 'cat <<EOF
GENERAL
remote = [2001:db8::1]:51820:udp
remote = vpn.example.test:1194:udp
EOF'
    mapfile -t ep < <(get_vpn_endpoints test)
    printf '%s\n' "${ep[@]}" | grep -Fqx 'vpn.example.test 1194 udp' && printf '%s\n' "${ep[@]}" | grep -Fqx '2001:db8::1 51820 udp'
}
T6() {
    new_env; base_config
    printf 'PWNED="$(touch %s/hit)"\n' "$TEST_ROOT" > "$TEST_ROOT/malicious.conf"
    cmd_import_config "$TEST_ROOT/malicious.conf" >/dev/null 2>&1 || true
    [[ ! -e "$TEST_ROOT/hit" ]]
    load_config >/dev/null 2>&1 || true
    [[ ! -e "$TEST_ROOT/hit" ]]
}
T9() {
    new_env
    ROTATE_MAC_EVERY_HOURS=1; MAC_MODE=stable
    mock systemctl 'exit 0'
    mock install 'cat >/dev/null; exit 0'
    # Ensure the generated timer syntax can be verified independently.
    write_mac_rotate_timer_unit > "$MAC_ROTATE_TIMER_DST"
    systemd-analyze verify "$MAC_ROTATE_TIMER_DST" >/dev/null 2>&1
}
T10() {
    new_env
    mock systemctl 'case "$1" in list-unit-files) echo "avahi-daemon.service enabled";; is-enabled) echo masked; exit 1;; is-active) exit 1;; mask) printf "%s\n" "$*" >> "$TEST_ROOT/systemctl.log"; exit 0;; unmask|enable|start) printf "%s\n" "$*" >> "$TEST_ROOT/systemctl.log"; exit 0;; esac; exit 0'
    unit_file_exists avahi-daemon.service
    rm -f "$STATE_DIR/marker"
    mask_service_remembering_state avahi-daemon.service '' marker
    [[ -f "$STATE_DIR/marker" ]]
    unmask_service_restoring_state avahi-daemon.service '' marker
    [[ ! -f "$STATE_DIR/marker" ]]
    ! grep -q '^unmask ' "$TEST_ROOT/systemctl.log" 2>/dev/null
}
T11() {
    new_env; base_config
    mock systemctl 'exit 0'
    mock ping 'exit 0'
    mock iptables 'if [[ "$1" == "-C" ]]; then exit 0; fi; exit 0'
    mock ip6tables 'exit 0'
    HAVE_IP6TABLES=1
    KILLSWITCH_MODE=false
    KNOWN_VPN=()
    ACTIVE_VPN=""
    PING_TARGETS='1.1.1.1'
    tunnel_reachable
}
T12() {
    new_env
    mkdir -p "$(dirname "$BIN_DST")"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DST"
    chmod +x "$BIN_DST"
    write_service_unit > "$UNIT_DST"
    write_boot_service_unit > "$BOOT_UNIT_DST"
    systemd-analyze verify "$UNIT_DST" "$BOOT_UNIT_DST" >/dev/null 2>&1
}

T20() {
    new_env
    base_config
    mock nmcli 'exit 0'
    mock iptables 'case "$1" in -w) shift 2;; esac; case "$1" in -C) exit 0;; -D) exit 1;; -F|-X) printf "%s\n" "$*" >> "$TEST_ROOT/iptables.log"; exit 0;; esac; exit 0'
    HAVE_IP6TABLES=0
    printf '%s\n' on > "$KILLSWITCH_OVERRIDE_FILE"
    ( remove_killswitch_if_present ) >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 && -s "$KILLSWITCH_OVERRIDE_FILE" ]] && ! grep -q -- ' -F ' "$TEST_ROOT/iptables.log" 2>/dev/null
}

T21() {
    new_env
    base_config
    mock nmcli 'exit 0'
    mock iptables 'exit 0'
    HAVE_IP6TABLES=0
    set_killswitch_override off
    KILLSWITCH_MODE=true
    KNOWN_VPN=()
    ! killswitch_should_be_active
    set_killswitch_override on
    killswitch_should_be_active
    clear_killswitch_override
    killswitch_should_be_active
}

T23() {
    new_env
    base_config
    mock nmcli 'if [[ "$*" == *"connection show --active"* ]]; then printf "VPN\\:Principal:vpn:tun0\n"; elif [[ "$*" == *"connection show"* ]]; then printf "VPN\\:Principal:vpn\nVPN-Backup:vpn\n"; fi'
    detect_known_profiles
    detect_active_state
    [[ "${KNOWN_VPN[0]}" == 'VPN:Principal' && "${ACTIVE_VPN}" == 'VPN:Principal' && "$VPN_IFACE" == tun0 ]]
}

T24() {
    new_env
    base_config; load_config >/dev/null 2>&1
    mock systemctl 'case "$1" in list-unit-files) echo "static.service static";; is-enabled) echo static; exit 0;; is-active) [[ "$*" == *"--quiet"* ]] || echo active; exit 0;; mask|unmask|start) exit 0;; esac; exit 0'
    unit_file_exists static.service
    mask_service_remembering_state static.service '' marker
    [[ "$(sed -n '1p' "$STATE_DIR/marker")" == static-active ]]
    unmask_service_restoring_state static.service '' marker
}

run_test 'failed removal never flushes the chain' T20
run_test 'kill switch override controls policy' T21
run_test 'active profile parsing remains aligned' T23
run_test 'static service state restores safely' T24
run_test 'bash syntax' T1
run_test 'i18n headers' T2
run_test 'config numeric normalization' T3
run_test 'nmcli escaped profile names' T4
run_test 'IPv6 VPN endpoint extraction' T5
run_test 'imported config never executes shell' T6
run_test 'generated systemd timer verifies' T9
run_test 'pre-masked service is not falsely unmasked' T10
run_test 'basic reachability path' T11
run_test 'generated systemd units verify' T12


T13() {
    new_env
    local host port proto
    VPN_ENDPOINT_OVERRIDE='[2001:db8::9]:443:tcp'
    read -r host port proto < <(parse_endpoint_spec "$VPN_ENDPOINT_OVERRIDE" 1194 udp)
    [[ "$host" == '2001:db8::9' && "$port" == 443 && "$proto" == tcp ]]
}

T14() {
    new_env
    base_config
    KILLSWITCH_MODE=true
    HAVE_IP6TABLES=1
    PING_TARGETS='1.1.1.1'
    KNOWN_VPN=(vpn-test)
    touch "$STATE_DIR/wanted"
    mock nmcli 'if [[ "$*" == *"-t -e yes -f NAME,TYPE connection show"* ]]; then printf "vpn-test:vpn\n"; fi'
    mock iptables '[[ "$*" == *" -C "* ]] && exit 0; exit 0'
    mock ip6tables '[[ "$*" == *" -C "* ]] && exit 1; exit 0'
    mock ping 'exit 0'
    local rc=0
    ( cmd_check ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]]
}

T15() {
    new_env
    base_config
    local value='echo $HOME; printf "unsafe"'
    panel_write_config_keys ALERT_HOOK="$value" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    [[ "$ALERT_HOOK" == "$value" ]]
}

T16() {
    new_env
    base_config
    printf 'ALERT_HOOK="$(touch %s/hit)"\n' "$TEST_ROOT" > "$CONFIG_FILE"
    load_config >/dev/null 2>&1 || true
    [[ ! -e "$TEST_ROOT/hit" && "$ALERT_HOOK" == '' ]]
}

T17() {
    new_env
    mock systemctl 'exit 0'
    printf '0\n' > "$TEST_ROOT/jump-count"
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) n=$(cat "$TEST_ROOT/jump-count"); (( n > 0 )); exit $?;; -D) printf "0\n" > "$TEST_ROOT/jump-count"; exit 0;; esac; exit 0'
    mock iptables-restore 'printf "%s\n" "$*" > "$TEST_ROOT/restore-args"; cat >/dev/null; exit 0'
    mock ip6tables 'exit 0'
    HAVE_IP6TABLES=0
    KS_VPN_CANDIDATES=()
    DNS_SERVERS='1.1.1.1'
    PING_TARGETS='1.1.1.1'
    ALLOW_LAN=true
    apply_killswitch_rules ''
    grep -Fq -- '--wait=5 --noflush' "$TEST_ROOT/restore-args"
}
T18() {
    new_env
    write_default_config > "$TEST_ROOT/default.conf"
    ! grep -q '__UI_LANGUAGE__' "$TEST_ROOT/default.conf"
    ! grep -nE '^[[:space:]]*source[[:space:]]' "$TEST_ROOT/default.conf"
}

T19() {
    new_env
    mock systemctl 'case "$1" in list-unit-files) echo "avahi-daemon.service enabled";; is-enabled) echo enabled; exit 0;; is-active) [[ "$*" == *"--quiet"* ]] || echo active; exit 0;; mask|unmask|enable|disable|start) exit 0;; esac; exit 0'
    unit_file_exists avahi-daemon.service
    mask_service_remembering_state avahi-daemon.service '' marker
    [[ "$(sed -n '1p' "$STATE_DIR/marker")" == enabled-active ]]
    unmask_service_restoring_state avahi-daemon.service '' marker
    [[ ! -f "$STATE_DIR/marker" ]]
}

run_test 'IPv6 override parsing' T13
run_test 'IPv6 health is critical' T14
run_test 'panel config roundtrip' T15
run_test 'known-key config injection is blocked' T16
run_test 'iptables restore uses lock wait' T17
run_test 'default config is clean' T18
run_test 'service enabled-active state restores' T19



T25() {
    new_env
    mock iptables-restore 'exit 1'
    mock iptables 'printf "%s\n" "$*" >> "$IPTABLES_LOG"; if [[ "$3" == "-F" ]]; then exit 0; elif [[ "$3" == "-A" && "$6" == "DROP" ]]; then exit 0; elif [[ "$3" == "-I" ]]; then exit 1; fi; exit 0'
    IPTABLES_LOG="$TEST_ROOT/iptables.log"
    export IPTABLES_LOG
    ! ks_restore_apply TEST ipt iptables-restore '-d 1.2.3.4 -j ACCEPT'
    grep -q -- '-A TEST -j DROP' "$IPTABLES_LOG"
}

T26() {
    new_env
    mock iptables-restore 'exit 1'
    mock iptables 'if [[ "$3" == "-N" ]]; then exit 0; elif [[ "$3" == "-C" ]]; then exit 1; elif [[ "$3" == "-I" ]]; then exit 1; fi; exit 0'
    HAVE_IP6TABLES=0
    KNOWN_VPN=()
    KILLSWITCH_MODE=true
    ! apply_killswitch_blocking
}

T27() {
    new_env
    base_config; load_config >/dev/null 2>&1
    mock firefox 'exit 0'
    HARDEN_BROWSER_DOH=true
    apply_browser_doh_policy
    python3 -m json.tool "$FIREFOX_POLICY_FILE" >/dev/null 2>&1
    grep -q '"DNSOverHTTPS"' "$FIREFOX_POLICY_FILE" &&
    ! grep -q '_vpn_netguard_managed' "$FIREFOX_POLICY_FILE" &&
    [[ -f "$FIREFOX_POLICY_MARKER" ]]
}

T28() {
    new_env
    base_config; load_config >/dev/null 2>&1
    mock firefox 'exit 0'
    HARDEN_BROWSER_DOH=true
    mock install 'for a in "$@"; do [[ "$a" == */policies.json ]] && exit 1; done; exec /usr/bin/install "$@"'
    ! apply_browser_doh_policy
    [[ ! -e "$FIREFOX_POLICY_FILE" ]]
}

T29() {
    new_env
    base_config; load_config >/dev/null 2>&1
    ANONYMIZE_NETWORK=true
    DISABLE_AVAHI_SERVICE=false
    DISABLE_NETBIOS_SERVICE=false
    HARDEN_BROWSER_DOH=false
    ROTATE_MAC_EVERY_HOURS=0
    mock systemctl 'case "$1" in list-unit-files) printf "%s\n" "NetworkManager.service enabled"; exit 0;; reload) exit 1;; is-enabled) echo disabled; exit 1;; is-active) exit 0;; *) exit 0;; esac'
    mock nmcli 'case "$*" in *"general reload conf"*) exit 1;; *) exit 0;; esac'
    ! apply_network_privacy
    [[ -f "$NM_PRIVACY_CONF" ]]
}

T30() {
    new_env
    base_config; load_config >/dev/null 2>&1
    MAC_MODE=stable
    ROTATE_MAC_EVERY_HOURS=1
    mock nmcli 'if [[ "$*" == *"connection show --active"* ]]; then printf "Office:802-3-ethernet:eth0\n"; elif [[ "$*" == *"connection show"* ]]; then printf "Office:802-3-ethernet\n"; elif [[ "$*" == *"general reload conf"* ]]; then exit 0; elif [[ "$*" == *"connection down"* ]]; then exit 1; fi; exit 0'
    ! rotate_mac_now
}

T31() {
    new_env
    base_config; load_config >/dev/null 2>&1
    EVENT_HISTORY_MAX_LINES=3
    record_event_if_changed up 'detail "one"'
    record_event_if_changed down 'detail two'
    record_event_if_changed up 'detail three'
    [[ "$(wc -l < "$EVENT_HISTORY_FILE")" -eq 3 ]]
    grep -Fq 'detail ""one""' "$EVENT_HISTORY_FILE"
}

T33() {
    new_env
    base_config; load_config >/dev/null 2>&1
    mock systemctl 'case "$1" in list-unit-files) echo "NetworkManager.service enabled";; *) exit 0;; esac'
    DISABLE_AVAHI_SERVICE=false
    DISABLE_NETBIOS_SERVICE=false
    HARDEN_BROWSER_DOH=false
    ROTATE_MAC_EVERY_HOURS=0
    apply_network_privacy
}

T34() {
    new_env
    base_config; load_config >/dev/null 2>&1
    HEARTBEAT_FILE="$TEST_ROOT/blocked/heartbeat"
    mkdir -p "$(dirname "$HEARTBEAT_FILE")"
    mock mv 'exit 1'
    ! touch_heartbeat
}

T35() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        reconcile_sync() { return 1; }
        ! daemon_main
    )
}

T36() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        detect_known_profiles() { KNOWN_VPN=(vpn); }
        reconcile_sync() { return 1; }
        ! do_activate
    )
}

T37() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        detect_known_profiles() { KNOWN_VPN=(vpn); }
        detect_active_state() { ACTIVE_VPN=vpn; }
        with_killswitch_lock() { return 1; }
        mock nmcli 'printf "%s\n" "$*" >> "$NMCLI_LOG"; exit 0'
        NMCLI_LOG="$TEST_ROOT/nmcli.log"; export NMCLI_LOG
        ! do_deactivate
        [[ ! -s "$NMCLI_LOG" ]]
    )
}

T38() {
    new_env
    base_config; load_config >/dev/null 2>&1
    HEARTBEAT_FILE="$TEST_ROOT/heartbeat"
    printf 'not-a-number\n' > "$HEARTBEAT_FILE"
    WATCHDOG_STALE_AFTER=5
    local out
    out="$(watchdog_ping_if_alive 2>&1)"
    [[ "$out" == *'999999'* ]] && [[ "$out" == *'watchdog'* || "$out" == *'supervisión'* ]]
}

T40() {
    new_env
    mock google-chrome-stable 'exit 0'
    HARDEN_BROWSER_DOH=true
    apply_browser_doh_policy
    python3 -m json.tool "$CHROME_POLICY_DIR/vpn-netguard-doh.json" >/dev/null 2>&1
    grep -q '"DnsOverHttpsMode": "off"' "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
}

T41() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        MAC_MODE=stable
        ROTATE_MAC_EVERY_HOURS=0
        remove_mac_rotate_timer() { return 1; }
        ! rotate_mac_now
    )
}


T42() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        DISABLE_IPV6=true
        HAVE_IP6TABLES=1
        apply_killswitch_rules6
    )
}



T43() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        mock flock 'exit 1'
        local marker="$TEST_ROOT/reconcile-called"
        reconcile_locked() { : > "$marker"; }
        ! reconcile_sync
        [[ ! -e "$marker" ]]
    )
}

T44() {
    new_env
    mock flock 'exit 1'
    ! with_killswitch_lock true
}

T45() {
    new_env
    mock nmcli 'printf "endpoint = 2001:db8::7:51820\n"'
    local -a ep
    mapfile -t ep < <(get_vpn_endpoints wg)
    [[ "${ep[0]}" == '2001:db8::7 51820 udp' ]]
}

T46() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        DISABLE_IPV6=true
        KILLSWITCH_MODE=true
        HAVE_IP6TABLES=1
        detect_known_profiles() { KNOWN_VPN=(vpn); }
        detect_active_state() { ACTIVE_VPN=vpn; VPN_TYPE=openvpn; }
        mock iptables '[[ "$3" == "-C" ]] && exit 0; exit 0'
        mock ip6tables 'printf "%s\n" "$*" >> "$TEST_ROOT/ip6.log"; exit 1'
        tunnel_reachable() { return 0; }
        ( cmd_check ) >/dev/null 2>&1
        [[ $? -eq 0 && ! -e "$TEST_ROOT/ip6.log" ]]
    )
}

T47() {
    new_env
    mkdir -p "$(dirname "$BIN_DST")"
    touch "$BIN_DST"
    mock systemctl 'case "$1" in stop|disable|daemon-reload) exit 0;; is-active) exit 0;; *) exit 0;; esac'
    ! ( cmd_uninstall )
    [[ -f "$BIN_DST" ]]
}

T48() {
    new_env
    mkdir -p "$(dirname "$BIN_DST")"
    touch "$BIN_DST"
    mock systemctl 'case "$1" in stop|disable|daemon-reload) exit 0;; is-active) exit 1;; *) exit 0;; esac'
    mock nmcli 'exit 0'
    mock iptables 'if [[ "$3" == "-C" ]]; then exit 0; elif [[ "$3" == "-D" ]]; then exit 1; fi; exit 0'
    HAVE_IP6TABLES=0
    ! ( cmd_uninstall )
    [[ -f "$BIN_DST" ]]
}

T49() {
    new_env
    mkdir -p "$(dirname "$BIN_DST")"
    touch "$BIN_DST"
    touch "$KILLSWITCH_OVERRIDE_FILE"
    mock systemctl 'case "$1" in stop|disable|daemon-reload) exit 0;; is-active) exit 1;; *) exit 0;; esac'
    mock nmcli 'exit 0'
    mock iptables 'exit 1'
    HAVE_IP6TABLES=0
    ( cmd_uninstall ) >/dev/null 2>&1
    [[ ! -e "$BIN_DST" && ! -e "$KILLSWITCH_OVERRIDE_FILE" ]]
}

T50() {
    new_env
    [[ -z "$(parse_endpoint_spec 'vpn.example:65536:udp' 1194 udp)" ]]
    [[ -z "$(parse_endpoint_spec 'vpn.example:0:udp' 1194 udp)" ]]
}

T51() {
    new_env
    CHAIN_NAME=TEST
    printf '2\n' > "$TEST_ROOT/jump-count"
    mock iptables 'case "$1" in -w) shift 2;; esac; case "$1" in
        -N) exit 1;;
        -C) n=$(cat "$TEST_ROOT/jump-count"); (( n > 0 )); exit $?;;
        -D) n=$(cat "$TEST_ROOT/jump-count"); printf "%s\n" "$((n-1))" > "$TEST_ROOT/jump-count"; exit 0;;
        -I) printf "%s\n" "$*" >> "$TEST_ROOT/insert.log"; printf "1\n" > "$TEST_ROOT/jump-count"; exit 0;;
    esac; exit 0'
    ensure_chain
    [[ "$(cat "$TEST_ROOT/jump-count")" == 1 ]] && grep -Fq -- '-I OUTPUT 1 -j TEST' "$TEST_ROOT/insert.log"
}

T52() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        SELF="$SCRIPT"
        INSTALL_YES=true INSTALL_OPT_AUTOSTART=true INSTALL_OPT_START_NOW=false INSTALL_OPT_PRIVACY=false
        mock nmcli 'exit 0'
        mock iptables 'exit 0'
        mock ping 'exit 0'
        mock getent 'exit 0'
        mock flock 'exit 0'
        mock awk 'exec /usr/bin/awk "$@"'
        mock sed 'exec /usr/bin/sed "$@"'
        mock grep 'exec /usr/bin/grep "$@"'
        mock systemctl 'case "$1" in is-active) exit 0;; enable) exit 1;; daemon-reload) exit 0;; *) exit 0;; esac'
        out="$(cmd_install_text 2>&1)"; rc=$?
        (( rc != 0 ))
    )
}

T53() {
    (
        new_env
        base_config; load_config >/dev/null 2>&1
        SELF="$SCRIPT"
        INSTALL_YES=true INSTALL_OPT_AUTOSTART=false INSTALL_OPT_START_NOW=true INSTALL_OPT_PRIVACY=false
        mock nmcli 'exit 0'
        mock iptables 'exit 0'
        mock ping 'exit 0'
        mock getent 'exit 0'
        mock flock 'exit 0'
        mock awk 'exec /usr/bin/awk "$@"'
        mock sed 'exec /usr/bin/sed "$@"'
        mock grep 'exec /usr/bin/grep "$@"'
        mock systemctl 'case "$1" in is-active) exit 0;; daemon-reload|enable) exit 0;; start) exit 1;; *) exit 0;; esac'
        out="$(cmd_install_text 2>&1)"; rc=$?
        (( rc != 0 ))
    )
}

T54() {
    new_env
    base_config
    cp "$CONFIG_FILE" "$TEST_ROOT/original.conf"
    printf '%s\n' 'KILLSWITCH_MODE="false"' > "$TEST_ROOT/import.conf"
    mock install 'n=$(wc -l < "$TEST_ROOT/install-count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$TEST_ROOT/install-count"; if (( n >= 2 )); then exit 1; fi; exec /usr/bin/install "$@"'
    mock mv 'exit 1'
    ! cmd_import_config "$TEST_ROOT/import.conf" >/dev/null 2>&1
    cmp -s "$TEST_ROOT/original.conf" "$CONFIG_FILE"
}

T55() {
    new_env
    CHAIN_NAME_V6=TEST6
    DISABLE_IPV6=true
    HAVE_IP6TABLES=1
    printf '1\n' > "$TEST_ROOT/ip6-jump-count"
    mock ip6tables 'case "$1" in -w) shift 2;; esac; case "$1" in
        -C) n=$(cat "$TEST_ROOT/ip6-jump-count"); (( n > 0 )); exit $?;;
        -D) n=$(cat "$TEST_ROOT/ip6-jump-count"); printf "%s\n" "$((n-1))" > "$TEST_ROOT/ip6-jump-count"; printf "%s\n" "$*" >> "$TEST_ROOT/ip6-remove.log"; exit 0;;
        -F|-X) printf "%s\n" "$*" >> "$TEST_ROOT/ip6-remove.log"; exit 0;;
        *) exit 0;; esac'
    apply_killswitch_rules6
    grep -Fq -- '-D OUTPUT -j TEST6' "$TEST_ROOT/ip6-remove.log" &&
    grep -Fq -- '-F TEST6' "$TEST_ROOT/ip6-remove.log" &&
    grep -Fq -- '-X TEST6' "$TEST_ROOT/ip6-remove.log"
}


T56() {
    (
        new_env
        mkdir -p "$(dirname "$BIN_DST")"
        touch "$BIN_DST"
        mock systemctl 'case "$1" in stop) exit 0;; is-active) exit 1;; disable) exit 1;; is-enabled) echo enabled; exit 0;; *) exit 0;; esac'
        remove_killswitch_if_present() { :; }
        remove_network_privacy() { :; }
        out="$(cmd_uninstall 2>&1)"; rc=$?
        (( rc != 0 )) && [[ -f "$BIN_DST" ]]
    )
}

T57() {
    new_env
    MAC_MODE=stable
    ROTATE_MAC_EVERY_HOURS=1
    mock date 'exit 1'
    ! write_privacy_conf
    [[ ! -f "$NM_PRIVACY_CONF" ]]
}



T58() {
    new_env
    write_desktop_file > "$DESKTOP_DST"
    grep -Fxq 'Type=Application' "$DESKTOP_DST" &&
    grep -Fxq "Exec=$BIN_DST panel" "$DESKTOP_DST" &&
    grep -Fxq 'Terminal=false' "$DESKTOP_DST" &&
    ! grep -q '__[A-Z_][A-Z_]*__' "$DESKTOP_DST"
}

T59() {
    new_env
    base_config
    mock install 'exec /usr/bin/install "$@"'
    mock mkdir 'exec /usr/bin/mkdir "$@"'
    mock date 'printf "1234567890\\n"'
    mock systemctl 'exit 0'
    mkdir -p "$(dirname "$NM_PRIVACY_CONF")"
    load_config >/dev/null 2>&1
    write_privacy_conf
    grep -Fq 'wifi.scan-rand-mac-address=yes' "$NM_PRIVACY_CONF" &&
    grep -Fq 'wifi.cloned-mac-address=stable' "$NM_PRIVACY_CONF" &&
    grep -Fq 'ethernet.cloned-mac-address=stable' "$NM_PRIVACY_CONF" &&
    grep -Fq 'ipv6.ip6-privacy=2' "$NM_PRIVACY_CONF" &&
    grep -Fq 'ipv6.addr-gen-mode=1' "$NM_PRIVACY_CONF" &&
    ! grep -q '__UI_LANGUAGE__' "$NM_PRIVACY_CONF"
}

T60() {
    local v1 v2 help
    v1="$(bash "$SCRIPT" version)" || return 1
    v2="$(bash "$SCRIPT" --version)" || return 1
    help="$(bash "$SCRIPT" --help)" || return 1
    [[ "$v1" == "$v2" ]] && [[ "$v1" == 'VPN NetGuard 1.0.0' ]] &&
    grep -Fq 'Uso:' <<<"$help" && grep -Fq 'install' <<<"$help" && grep -Fq 'doctor' <<<"$help"
}

T61() {
    new_env
    PROMETHEUS_TEXTFILE_DIR="$TEST_ROOT/prom"
    mkdir -p "$PROMETHEUS_TEXTFILE_DIR"
    write_prometheus_metrics 0 1 0 1
    [[ -s "$PROMETHEUS_TEXTFILE_DIR/vpn_netguard.prom" ]] &&
    grep -Fxq 'vpn_netguard_killswitch_active 1' "$PROMETHEUS_TEXTFILE_DIR/vpn_netguard.prom" &&
    grep -Fxq 'vpn_netguard_vpn_connected 0' "$PROMETHEUS_TEXTFILE_DIR/vpn_netguard.prom" &&
    ! find "$PROMETHEUS_TEXTFILE_DIR" -maxdepth 1 -type f -name '.vpn_netguard.prom.*' -print -quit | grep -q .
}

T62() {
    python3 - "$SCRIPT" <<'PYCODE'
import re, sys
text=open(sys.argv[1], encoding='utf-8').read()
refs=set(re.findall(r'ui_t[ \t]+([A-Za-z_][A-Za-z0-9_.-]+)', text))
es=set(re.findall(r'es:([A-Za-z0-9_.-]+)\)', text))
en=set(re.findall(r'en:([A-Za-z0-9_.-]+)\)', text))
refs -= {'es', 'en'}
missing_es=sorted(refs-es-{''})
missing_en=sorted(refs-en-{''})
if missing_es or missing_en:
    print('missing es:', missing_es)
    print('missing en:', missing_en)
    raise SystemExit(1)
PYCODE
}

T63() {
    new_env
    base_config
    out="$TEST_ROOT/export.conf"
    cmd_export_config "$out" >/dev/null 2>&1 &&
    grep -Fq 'KILLSWITCH_MODE="auto"' "$out" &&
    printf '%s\n' 'KILLSWITCH_MODE="false"' >> "$CONFIG_FILE" &&
    cmd_import_config "$out" >/dev/null 2>&1 &&
    ! grep -q 'KILLSWITCH_MODE="false"' "$CONFIG_FILE" &&
    grep -Fq 'KILLSWITCH_MODE="auto"' "$CONFIG_FILE"
}

T64() {
    new_env
    RECONNECT_BACKOFF='05 15 30'
    VPN_BACKOFF_STEP=0
    [[ "$(vpn_backoff_seconds)" == 5 ]]
    vpn_backoff_register_failure
    [[ $VPN_BACKOFF_STEP -eq 1 ]] && [[ "$(vpn_backoff_seconds)" == 5 ]]
    vpn_backoff_register_failure
    [[ $VPN_BACKOFF_STEP -eq 2 ]] && [[ "$(vpn_backoff_seconds)" == 15 ]]
    vpn_backoff_reset
    [[ $VPN_BACKOFF_STEP -eq 0 && $VPN_BACKOFF_LAST_ATTEMPT -eq 0 ]]
    printf '%s
' 'RECONNECT_BACKOFF="00 05"' > "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    [[ "$RECONNECT_BACKOFF" == '5 15 30 60 120' ]]
}

T65() {
    new_env
    VPN_TYPE=wireguard
    VPN_IFACE=wg0
    mock wg 'if [[ "$1" == "show" && "$2" == "wg0" && "$3" == "latest-handshakes" ]]; then printf "peer 1999\n"; exit 0; fi; exit 0'
    mock date 'printf "2005\n"'
    [[ "$(wg_tunnel_alive wg0 >/dev/null 2>&1; echo $?)" == 0 ]] || return 1
    mock date 'printf "2200\n"'
    [[ "$(wg_tunnel_alive wg0 >/dev/null 2>&1; echo $?)" == 1 ]]
}

run_test 'iptables fallback stays fail-closed' T25
run_test 'blocking propagates firewall failure' T26
run_test 'Firefox DoH policy is valid and complete' T27
run_test 'browser policy write failure is propagated' T28
run_test 'privacy apply reports reload failure' T29
run_test 'MAC rotation reports reconnect failure' T30
run_test 'event history deduplicates and escapes CSV' T31
run_test 'privacy treats missing optional services as no-op' T33
run_test 'heartbeat write failures are visible' T34
run_test 'daemon startup propagates reconcile failure' T35
run_test 'activate propagates reconcile failure' T36
run_test 'deactivate never disconnects if firewall cleanup fails' T37
run_test 'corrupt heartbeat cannot create arithmetic failure' T38
run_test 'Chrome DoH policy is valid' T40
run_test 'disabled MAC rotation reports cleanup failure' T41
run_test 'disabled IPv6 does not require a v6 chain' T42
run_test 'sync reconcile aborts when lock cannot be acquired' T43
run_test 'privileged action aborts when lock cannot be acquired' T44
run_test 'WireGuard endpoint parser accepts unbracketed IPv6' T45
run_test 'disabled IPv6 health ignores missing v6 chain' T46
run_test 'uninstall keeps installation if service stays active' T47
run_test 'uninstall keeps installation if firewall teardown fails' T48
run_test 'successful uninstall clears runtime override' T49
run_test 'endpoint ports outside 1-65535 are rejected' T50
run_test 'kill-switch jump is repaired to position 1' T51
run_test 'install fails when autostart enable fails' T52
run_test 'install fails when immediate start fails' T53
run_test 'import failure leaves the original config intact' T54
run_test 'disabling IPv6 removes a stale IPv6 kill-switch chain' T55
run_test 'uninstall aborts if autostart remains enabled' T56
run_test 'privacy configuration fails when its rotation token cannot be created' T57

T66() {
    (
        new_env
        KILLSWITCH_MODE=true
    detect_known_profiles() { :; }
    detect_active_state() {
        (( ++detect_calls == 1 )) && ACTIVE_VPN="" || ACTIVE_VPN="VPN"
    }
    apply_killswitch_blocking() { :; }
    try_reconnect_vpn() { :; }
    apply_killswitch_allowing() { return 1; }
    ACTIVE_VPN=""
    detect_calls=0
        ! reconcile_locked
    )
}

T91() {
    (
        new_env
    KILLSWITCH_MODE=false
    PHYS_IFACE=eth0
    ACTIVE_VPN=VPN
    VPN_TYPE=openvpn
    detect_known_profiles() { :; }
    detect_active_state() { :; }
    killswitch_should_be_active() { return 1; }
    tunnel_reachable() { return 1; }
    try_reconnect_physical() { (( ++physical_attempts )); return 0; }
    try_reconnect_vpn() { :; }
    physical_attempts=0
    touch_heartbeat() { :; }
    reconcile_locked
        [[ $physical_attempts -eq 0 ]]
    )
}

T67() {
    new_env
    touch "$UNIT_DST"
    mock systemctl '[[ "$1" == "daemon-reload" ]] && exit 1; exit 0'
    ! sync_localized_installed_files
}

T68() {
    new_env
    mock firefox 'exit 0'
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    cat > "$FIREFOX_POLICY_FILE" <<'EOF'
{
  "policies": {
    "_vpn_netguard_managed": true,
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "DisableTelemetry": true
  }
}
EOF
    HARDEN_BROWSER_DOH=true
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    grep -Fq 'DisableTelemetry' "$FIREFOX_POLICY_FILE"
    ! remove_browser_doh_policy >/dev/null 2>&1 &&
    grep -Fq 'DisableTelemetry' "$FIREFOX_POLICY_FILE"
}

T69() {
    new_env
    mock google-chrome 'exit 0'
    mkdir -p "$CHROME_POLICY_DIR"
    cat > "$CHROME_POLICY_DIR/vpn-netguard-doh.json" <<'EOF'
{
  "DnsOverHttpsMode": "off",
  "SomeOtherPolicy": true
}
EOF
    printf '%s\n' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" > "$CHROME_POLICY_MARKER"
    HARDEN_BROWSER_DOH=true
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    grep -Fq 'SomeOtherPolicy' "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
}

T70() {
    new_env
    mock google-chrome 'exit 0'
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" > "$CHROME_POLICY_MARKER"
    remove_browser_doh_policy >/dev/null 2>&1 &&
    [[ ! -f "$CHROME_POLICY_MARKER" ]]
}

T71() {
    new_env
    mock google-chrome 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROME_POLICY_DIR"
    # The marker must only be consumed with a genuinely owned policy file.
    printf '%s\n' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" > "$CHROME_POLICY_MARKER"
    printf '%s\n' '{"DnsOverHttpsMode":"off"}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    apply_browser_doh_policy >/dev/null 2>&1 &&
    chromium_policy_is_managed "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
}

T72() {
    new_env
    mock chromium 'exit 0'
    HARDEN_BROWSER_DOH=true
    apply_browser_doh_policy >/dev/null 2>&1 &&
    chromium_policy_is_managed "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" &&
    chromium_policy_is_managed "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" &&
    [[ -f "$CHROMIUM_POLICY_MARKER" && -f "$CHROMIUM_BROWSER_POLICY_MARKER" ]]
}

T73() {
    new_env
    mock chromium 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROMIUM_POLICY_DIR" "$CHROMIUM_BROWSER_POLICY_DIR"
    printf '%s\n' '{"DnsOverHttpsMode":"off"}' > "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json"
    # One existing file is modified externally: neither file should be overwritten.
    cat > "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" <<'EOF'
{"DnsOverHttpsMode":"off","External":true}
EOF
    printf '%s\n' "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" > "$CHROMIUM_POLICY_MARKER"
    printf '%s\n' "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" > "$CHROMIUM_BROWSER_POLICY_MARKER"
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    grep -Fq 'External' "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json"
}

T75() {
    new_env
    NMCLI_UP_TIMEOUT=2
    mock nmcli '[[ "$1" == "connection" && "$2" == "up" && "$3" == "Office" ]] && exit 0; exit 1'
    nmcli_up 'Office'
}

T76() {
    new_env
    NMCLI_UP_TIMEOUT=1
    mock nmcli 'sleep 5'
    start=$SECONDS
    ! nmcli_up 'Slow'
    elapsed=$((SECONDS-start))
    (( elapsed <= 3 ))
}

T77() {
    new_env
    mock google-chrome 'exit 0'
    mock mv 'exit 1'
    HARDEN_BROWSER_DOH=true
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    [[ ! -e "$CHROME_POLICY_DIR/vpn-netguard-doh.json" ]] &&
    [[ ! -e "$CHROME_POLICY_MARKER" ]]
}

T78() {
    new_env
    printf '%s\n' 'LANGUAGE="es"' > "$TEST_ROOT/config"
    unset i
    config_file_is_safe "$TEST_ROOT/config"
    [[ -z "${i+x}" ]]
}

T79() {
    new_env
    [[ "$(nmcli_unescape "$(nmcli_protect_escapes 'Office\\Lab')")" == 'Office\Lab' ]]
}

T80() {
    new_env
    KNOWN_VPN=('VPN Principal' 'VPN Respaldo' 'VPN')
    VPN_PRIORITY='VPN Respaldo VPN Principal'
    mapfile -t ordered < <(ordered_known_vpn)
    [[ "${ordered[0]}" == 'VPN Respaldo' ]] &&
    [[ "${ordered[1]}" == 'VPN Principal' ]] &&
    [[ "${ordered[2]}" == 'VPN' ]] &&
    [[ ${#ordered[@]} -eq 3 ]]
}

T81() {
    new_env
    local hook="$TEST_ROOT/hooks/hook *"
    mkdir -p "$(dirname "$hook")"
    cat > "$hook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" "$2" > "$TEST_ROOT/hook.out"
EOF
    chmod +x "$hook"
    ALERT_HOOK="$hook"
    run_alert_hook normal 'hello *'
    for _ in {1..20}; do [[ -f "$TEST_ROOT/hook.out" ]] && break; sleep 0.05; done
    [[ -f "$TEST_ROOT/hook.out" ]] &&
    sed -n '1p' "$TEST_ROOT/hook.out" | grep -Fxq normal &&
    sed -n '2p' "$TEST_ROOT/hook.out" | grep -Fxq 'hello *'
}

T82() {
    new_env
    local d="$TEST_ROOT/bin-installed/desktop file.desktop"
    local log="$TEST_ROOT/gio.log"
    mkdir -p "$(dirname "$d")"
    mock gio 'printf "%s\n" "$*" > "$TEST_ROOT/gio.log"; exit 0'
    mock runuser '[[ "$1" == "-u" ]] && [[ "$2" == "alice" ]] && [[ "$3" == "--" ]] && exec "$4" "${@:5}"; exit 1'
    mark_desktop_trusted alice "$d"
    grep -Fxq "set $d metadata::trusted true" "$log"
}

T83() {
    new_env
    mock firefox 'exit 0'
    HARDEN_BROWSER_DOH=true
    apply_browser_doh_policy >/dev/null 2>&1
    python3 -m json.tool "$FIREFOX_POLICY_FILE" >/dev/null 2>&1
    ! grep -q '_vpn_netguard_managed' "$FIREFOX_POLICY_FILE"
    [[ -f "$FIREFOX_POLICY_MARKER" ]]
    remove_browser_doh_policy >/dev/null 2>&1
    [[ ! -e "$FIREFOX_POLICY_FILE" && ! -e "$FIREFOX_POLICY_MARKER" ]]
}

T84() {
    new_env
    mock firefox 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    cat > "$FIREFOX_POLICY_FILE" <<'EOF'
{"policies":{"_vpn_netguard_managed":true,"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}
EOF
    apply_browser_doh_policy >/dev/null 2>&1
    ! grep -q '_vpn_netguard_managed' "$FIREFOX_POLICY_FILE" && [[ -f "$FIREFOX_POLICY_MARKER" ]]
}

T85() {
    new_env
    mock firefox 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    cat > "$FIREFOX_POLICY_FILE" <<'EOF'
{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}
EOF
    printf '%s\n' "$FIREFOX_POLICY_FILE" > "$FIREFOX_POLICY_MARKER"
    printf '%s\n' '{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true},"DisableTelemetry":true}}' > "$FIREFOX_POLICY_FILE"
    ! apply_browser_doh_policy >/dev/null 2>&1
    grep -q 'DisableTelemetry' "$FIREFOX_POLICY_FILE"
    ! remove_browser_doh_policy >/dev/null 2>&1
    grep -q 'DisableTelemetry' "$FIREFOX_POLICY_FILE"
}

T86() {
    new_env
    MAC_MODE=stable
    ROTATE_MAC_EVERY_HOURS=1
    mock systemctl '[[ "$1" == "daemon-reload" ]] && exit 0; [[ "$1" == "enable" ]] && exit 1; exit 0'
    ! sync_mac_rotate_timer
    [[ ! -e "$MAC_ROTATE_UNIT_DST" && ! -e "$MAC_ROTATE_TIMER_DST" ]]
}

T87() {
    new_env
    mock nmcli 'exit 0'; mock iptables 'exit 0'; mock ping 'exit 0'; mock getent 'exit 0'; mock flock 'exit 0'; mock awk 'exit 0'; mock sed 'exit 0'; mock grep 'exit 0'; mock systemctl 'exit 0'; mock ip6tables 'exit 0'
    HAVE_IP6TABLES=1
    check_dependencies
    [[ $HAVE_IP6TABLES -eq 1 ]]
    rm -f "$MOCKBIN/ip6tables"
    check_dependencies
    [[ $HAVE_IP6TABLES -eq 0 ]]
}

T88() {
    new_env
    python3 - "$SCRIPT" <<'PY'
import re, sys
text=open(sys.argv[1], encoding='utf-8').read()
entries={'es':{}, 'en':{}}
rx=re.compile(r"\s*(es|en):([A-Za-z0-9_.-]+)\) text=('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")")
for lang,key,raw in rx.findall(text):
    entries[lang][key]=raw[1:-1]
assert set(entries['es']) == set(entries['en'])
ph=lambda v: re.findall(r'%(?:[0-9]+\$)?[-+#0 ]?(?:\*|[0-9]+)?(?:\.[0-9]+)?[diouxXeEfFgGcs]', v)
for key in entries['es']:
    assert ph(entries['es'][key]) == ph(entries['en'][key]), key
PY
}

T89() {
    new_env
    unset _ipv6_parts 2>/dev/null || true
    valid_ipv6_literal '2001:db8::1234'
    [[ -z "${_ipv6_parts+x}" ]]
    [[ "$(resolve_ipv6 '2001:db8::1234')" == '2001:db8::1234' ]]
    ! valid_ipv6_literal '2001:db8:::1234'
    [[ -z "$(resolve_ipv6 '2001:db8:::1234')" ]]
}

T90() {
    new_env
    mock firefox 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    cat > "$FIREFOX_POLICY_FILE" <<'EOF'
{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}
EOF
    ! apply_browser_doh_policy >/dev/null 2>&1
    [[ ! -f "$FIREFOX_POLICY_MARKER" ]]
    [[ -f "$FIREFOX_POLICY_FILE" ]]
    ! remove_browser_doh_policy >/dev/null 2>&1
    [[ -f "$FIREFOX_POLICY_FILE" ]]
}

T92() {
    new_env
    printf 'PING_TARGETS="safe" touch "%s/pwned"\n' "$TEST_ROOT" > "$CONFIG_FILE"
    ! config_file_is_safe "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    [[ ! -e "$TEST_ROOT/pwned" ]]
}

T93() {
    new_env
    base_config
    printf 'PING_TARGETS="1.1.1.1 8.8.8.8" # comentario\n' >> "$CONFIG_FILE"
    config_file_is_safe "$CONFIG_FILE"
}

T94() {
    new_env
    ! parse_endpoint_spec 'vpn.example:-1:udp' 1194 udp >/dev/null
    ! parse_endpoint_spec 'vpn.example:abc:udp' 1194 udp >/dev/null
    ! parse_endpoint_spec 'vpn.example:443:udp:extra' 1194 udp >/dev/null
}

T95() {
    new_env
    CHAIN_NAME=TEST
    printf '2\n' > "$TEST_ROOT/jump-count"
    mock iptables 'case "$1" in -w) shift 2;; esac; case "$1" in
        -C) n=$(cat "$TEST_ROOT/jump-count"); (( n > 0 )); exit $?;;
        -D) n=$(cat "$TEST_ROOT/jump-count"); printf "%s\n" "$((n-1))" > "$TEST_ROOT/jump-count"; exit 0;;
        -F) printf "%s\n" flush >> "$TEST_ROOT/actions"; exit 0;;
        -X) printf "%s\n" delete >> "$TEST_ROOT/actions"; exit 0;;
    esac; exit 0'
    remove_killswitch_if_present
    [[ "$(cat "$TEST_ROOT/jump-count")" == 0 ]] &&
    grep -Fxq flush "$TEST_ROOT/actions" && grep -Fxq delete "$TEST_ROOT/actions"
}

T96() {
    new_env
    HAVE_IP6TABLES=1
    CHAIN_NAME_V6=TEST6
    printf '2\n' > "$TEST_ROOT/jump-count6"
    mock ip6tables 'case "$1" in -w) shift 2;; esac; case "$1" in
        -C) n=$(cat "$TEST_ROOT/jump-count6"); (( n > 0 )); exit $?;;
        -D) n=$(cat "$TEST_ROOT/jump-count6"); printf "%s\n" "$((n-1))" > "$TEST_ROOT/jump-count6"; exit 0;;
        -F) printf "%s\n" flush >> "$TEST_ROOT/actions6"; exit 0;;
        -X) printf "%s\n" delete >> "$TEST_ROOT/actions6"; exit 0;;
    esac; exit 0'
    remove_killswitch6_if_present
    [[ "$(cat "$TEST_ROOT/jump-count6")" == 0 ]] &&
    grep -Fxq flush "$TEST_ROOT/actions6" && grep -Fxq delete "$TEST_ROOT/actions6"
}

T97() {
    new_env
    printf 'CHECK_INTERVAL=999999999999999999999999999999999999\nEVENT_HISTORY_MAX_LINES=999999999999999999999999999999999999\nROTATE_MAC_EVERY_HOURS=999999999999999999999999999999999999\n' > "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    [[ "$CHECK_INTERVAL" == 25 ]] &&
    [[ "$EVENT_HISTORY_MAX_LINES" == 5000 ]] &&
    [[ "$ROTATE_MAC_EVERY_HOURS" == 0 ]]
}



T102() {
    new_env
    printf 'ALERT_HOOK="$(touch "%s/pwned")"\n' "$TEST_ROOT" > "$CONFIG_FILE"
    ! config_file_is_safe "$CONFIG_FILE"
    ! load_config >/dev/null 2>&1
    [[ ! -e "$TEST_ROOT/pwned" ]]
}



T104() {
    new_env
    WATCHDOG_PING_INTERVAL=0
    WATCHDOG_STALE_AFTER=0
    WATCHDOG_USEC=999999999999999999999999999999999999
    configure_watchdog
    [[ $WATCHDOG_PING_INTERVAL -eq 0 && $WATCHDOG_STALE_AFTER -eq 0 ]]
    WATCHDOG_USEC=5000000
    CHECK_INTERVAL=25
    configure_watchdog
    [[ $WATCHDOG_PING_INTERVAL -eq 2 && $WATCHDOG_STALE_AFTER -eq 3 ]]
}

T103() {
    (
        new_env
        UI_LANGUAGE='es"; touch "$TEST_ROOT/pwned'
        write_default_config > "$TEST_ROOT/default.conf"
        grep -Fxq 'LANGUAGE="es"   # es | en' "$TEST_ROOT/default.conf" &&
        [[ ! -e "$TEST_ROOT/pwned" ]]
    )
}

T99() {
    new_env
    mock google-chrome 'exit 0'
    mock chromium 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' '{"DnsOverHttpsMode":"off"}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    printf '%s\n' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" > "$CHROME_POLICY_MARKER"
    mock install 'case "$*" in *chromium-browser*) exit 1;; *) /usr/bin/install "$@";; esac'
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    grep -Fxq '{"DnsOverHttpsMode":"off"}' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" &&
    [[ -f "$CHROME_POLICY_MARKER" ]] &&
    [[ ! -e "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" ]] &&
    [[ ! -e "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" ]]
}

T100() {
    new_env
    mock systemctl 'if [[ "$1" == "list-unit-files" ]]; then printf "vpn.service-extra enabled\n"; else exit 1; fi'
    ! unit_file_exists vpn.service
}

T101() {
    new_env
    write_default_config > "$TEST_ROOT/default.conf"
    python3 - "$TEST_ROOT/default.conf" <<'PY'
from pathlib import Path
data = Path(__import__('sys').argv[1]).read_bytes()
assert b'\x00' not in data
assert b'\r' not in data
for line in data.splitlines():
    assert line == line.rstrip(b' \t')
PY
}

T98() {
    new_env
    valid_ipv4_literal '000000000000000000000000000192.0.2.1'
    ! valid_ipv4_literal '999999999999999999999999.0.0.1'
    ! parse_endpoint_spec 'host:999999999999999999999999:udp' 1194 udp >/dev/null
}


T105() {
    new_env
    mock firefox 'exit 0'
    mock google-chrome 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")" "$CHROME_POLICY_DIR"
    printf '%s\n' '{"managed":true}' > "$FIREFOX_POLICY_FILE"
    printf '%s\n' '{"preexisting":true}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    grep -Fxq '{"managed":true}' "$FIREFOX_POLICY_FILE" &&
    grep -Fxq '{"preexisting":true}' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" &&
    [[ ! -f "$CHROME_POLICY_MARKER" ]]
}

T106() {
    new_env
    mock firefox 'exit 0'
    mock google-chrome 'exit 0'
    mock install 'case "$*" in *"'$CHROME_POLICY_DIR'/vpn-netguard-doh.json"*) exit 1;; *) /usr/bin/install "$@";; esac'
    HARDEN_BROWSER_DOH=true
    ! apply_browser_doh_policy >/dev/null 2>&1 &&
    [[ -f "$FIREFOX_POLICY_FILE" ]] &&
    [[ -f "$FIREFOX_POLICY_MARKER" ]] &&
    [[ ! -e "$CHROME_POLICY_DIR/vpn-netguard-doh.json" ]] &&
    [[ ! -e "$CHROME_POLICY_MARKER" ]]
}
T107() {
    new_env
    fake="$MOCKBIN/shellcheck"
    cat > "$fake" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo 'ShellCheck - shell script analysis tool'
    echo 'version: 0.11.0'
    exit 0
fi
printf '%s\n' "$@" > "$TEST_ROOT/shellcheck.args"
exit 0
EOF
    chmod +x "$fake"
    PATH="$MOCKBIN:$ORIG_PATH" "$SCRIPT_DIR/test/run-shellcheck.sh" >/dev/null 2>&1 || return 1
    ! grep -Fxq -- '-x' "$TEST_ROOT/shellcheck.args" &&
    grep -Fxq -- '-e' "$TEST_ROOT/shellcheck.args" &&
    grep -Fxq -- 'SC2317,SC2034' "$TEST_ROOT/shellcheck.args" &&
    grep -Fxq -- "$SCRIPT" "$TEST_ROOT/shellcheck.args"
}

T108() {
    new_env
    UI_LANGUAGE=es; ui_init
    local es_header es_desktop es_service
    es_header=$(write_privacy_conf 2>/dev/null)
    [[ -f "$NM_PRIVACY_CONF" ]] || return 1
    es_header=$(head -n 4 "$NM_PRIVACY_CONF")
    es_desktop=$(write_desktop_file)
    es_service=$(write_service_unit)
    grep -Fq 'Generado automáticamente por vpn-netguard.sh' <<<"$es_header" &&
    grep -Fq 'Configura, activa o desactiva' <<<"$es_desktop" &&
    grep -Fq 'vigilancia de red' <<<"$es_service"
    UI_LANGUAGE=en; ui_init
    write_privacy_conf >/dev/null
    es_header=$(head -n 4 "$NM_PRIVACY_CONF")
    es_desktop=$(write_desktop_file)
    es_service=$(write_service_unit)
    grep -Fq 'Automatically generated by vpn-netguard.sh' <<<"$es_header" &&
    grep -Fq 'Configure, enable or disable' <<<"$es_desktop" &&
    grep -Fq 'network monitoring' <<<"$es_service" &&
    ! grep -Fq 'Generado automáticamente' <<<"$es_header"
}

T109() {
    new_env
    UI_LANGUAGE=es; ui_init
    grep -Fq 'Endurecer identificadores DHCP' <<<"$(ui_field_label HARDEN_DHCP_IDENTIFIERS)" &&
    grep -Fq 'Política de dirección MAC' <<<"$(ui_field_label MAC_MODE)"
    UI_LANGUAGE=en; ui_init
    [[ "$(ui_field_label HARDEN_DHCP_IDENTIFIERS)" == 'Harden DHCP identifiers' ]] &&
    [[ "$(ui_field_label MAC_MODE)" == 'MAC address policy' ]]
}

T110() {
    new_env
    fake="$MOCKBIN/shellcheck"
    cat > "$fake" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo 'ShellCheck - shell script analysis tool'
    echo 'version: 0.10.0'
    exit 0
fi
exit 0
EOF
    chmod +x "$fake"
    ! PATH="$MOCKBIN:$ORIG_PATH" "$SCRIPT_DIR/test/run-shellcheck.sh" >/dev/null 2>&1
}

run_test 'desktop entry is structurally clean' T58
run_test 'privacy snippet contains intended NetworkManager policy' T59
run_test 'CLI version and help smoke tests' T60
run_test 'Prometheus textfile output is valid and atomic' T61
run_test 'translations cover every ui_t key' T62
run_test 'configuration export/import round-trip succeeds' T63
run_test 'VPN backoff progresses and resets predictably' T64
run_test 'WireGuard handshake age is computable' T65
run_test 'reconcile propagates failure after VPN reconnect' T66
run_test 'localization sync reports daemon-reload failure' T67
run_test 'zombie VPN does not bounce an already-active physical link' T91
run_test 'modified Firefox managed policy is preserved' T68
run_test 'modified Chrome managed policy is preserved' T69
run_test 'stale Chrome ownership marker is cleaned' T70
run_test 'owned Chrome policy remains reusable' T71
run_test 'Chromium policies and ownership markers are created' T72
run_test 'modified Chromium policy is preserved' T73
run_test 'nmcli_up works through the real timeout executable' T75
run_test 'nmcli_up timeout aborts a hung NetworkManager call' T76
run_test 'Chrome policy creation rolls back on marker failure' T77
run_test 'configuration parser keeps loop variables local' T78
run_test 'nmcli unescapes literal backslashes correctly' T79
run_test 'VPN priority supports profile names with spaces' T80
run_test 'alert hooks preserve literal paths and wildcard characters' T81
run_test 'desktop trust marking does not build a shell command' T82
run_test 'Firefox policy uses an external ownership marker' T83
run_test 'legacy Firefox policy migrates cleanly' T84
run_test 'modified Firefox policy remains preserved' T85
run_test 'MAC rotation reports systemd activation failure' T86
run_test 'IPv6 dependency state resets between checks' T87
run_test 'translation placeholders remain aligned' T88
run_test 'exact unowned Firefox policy is never adopted' T90
run_test 'IPv6 literal validation is local and DNS-independent' T89
T111() { source "$SCRIPT"; valid_ipv6_literal "::ffff:192.0.2.128" && ! valid_ipv6_literal "192.0.2.128::ffff" && ! valid_ipv6_literal "::192.0.2.128:1"; }
run_test 'IPv6 embedded IPv4 must be the final component' T111
T112() { source "$SCRIPT"; [[ "$(parse_endpoint_spec "[2001:db8::1]" 1194 udp)" == "2001:db8::1 1194 udp" ]]; }
run_test 'Bracketed IPv6 without explicit port uses the default' T112
run_test 'config assignments cannot execute trailing commands' T92
run_test 'quoted configuration whitespace and comments remain valid' T93
run_test 'malformed endpoint syntax is rejected' T94
run_test 'IPv4 kill-switch teardown removes every jump' T95
run_test 'IPv6 kill-switch teardown removes every jump' T96
T113() { source "$SCRIPT"; [[ "$(parse_endpoint_spec "2001:db8::1" 1194 udp)" == "2001:db8::1 1194 udp" ]]; }
run_test 'Bare IPv6 endpoint is not mistaken for a port' T113
run_test 'decimal overflow is rejected without wrapping' T97
run_test 'IPv4 and endpoint numeric fields resist huge values' T98
run_test 'quoted command substitutions are rejected without execution' T102
run_test 'default config language cannot inject shell/sed syntax' T103
run_test 'watchdog environment values cannot overflow arithmetic' T104
run_test 'browser rollback preserves pre-existing managed Chrome policy' T99
run_test 'unit discovery requires an exact unit name' T100
run_test 'generated default config is visually clean' T101
run_test 'browser preflight prevents cross-browser partial state' T105
run_test 'browser write failure rolls back newly created Firefox policy' T106
run_test 'ShellCheck helper passes the correct exclude option' T107
run_test 'Spanish and English generated artifacts stay localized' T108
run_test 'refined bilingual field labels stay exact' T109
T124() {
    new_env; base_config
    KILLSWITCH_MODE=true
    VPN_ENDPOINT_OVERRIDE='vpn.example:70000:udp'
    KS_VPN_CANDIDATES=(vpn-good)
    mock nmcli 'printf "%s\n" "remote = 198.51.100.20:1194:udp"'
    mock iptables-restore 'cat > "$TEST_ROOT/restore-input"; exit 0'
    printf '0\n' > "$TEST_ROOT/jump-count"
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) n=$(cat "$TEST_ROOT/jump-count"); (( n > 0 )); exit $?;; -D) printf "0\n" > "$TEST_ROOT/jump-count"; exit 0;; esac; exit 0'
    log_t() { [[ "$2" == log.endpoint_unresolved ]] && printf '%s\n' "$*" > "$TEST_ROOT/endpoint-warning"; }
    apply_killswitch_rules '' >/dev/null
    ! grep -Fq '70000' "$TEST_ROOT/restore-input" || return 1
    [[ "$(grep -Fc '198.51.100.20' "$TEST_ROOT/restore-input")" == 1 ]] && grep -Fq 'vpn.example:70000:udp' "$TEST_ROOT/endpoint-warning"
}

T125() {
    new_env; base_config
    HAVE_IP6TABLES=1
    VPN_ENDPOINT_OVERRIDE='[2001:db8::10]:70000:udp'
    KS_VPN_CANDIDATES=(vpn-good)
    mock nmcli 'printf "%s\n" "endpoint = [2001:db8::20]:51820:udp"'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6-input"; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; -N|-I) exit 0;; esac; exit 0'
    log_t() { [[ "$2" == log.endpoint_unresolved ]] && printf '%s\n' "$*" > "$TEST_ROOT/endpoint-warning6"; }
    apply_killswitch_rules6 '' >/dev/null
    ! grep -Fq '70000' "$TEST_ROOT/restore6-input" || return 1
    [[ "$(grep -Fc '2001:db8::20' "$TEST_ROOT/restore6-input")" == 1 ]] && grep -Fq '[2001:db8::10]:70000:udp' "$TEST_ROOT/endpoint-warning6"
}

T126() {
    new_env
    HAVE_IP6TABLES=1
    printf '1\n' > "$TEST_ROOT/jump-count6"
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 0;; -D) exit 1;; -F|-X) exit 0;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) n=$(cat "$TEST_ROOT/jump-count6"); (( n > 0 )); exit $?;; -D) printf "0\n" > "$TEST_ROOT/jump-count6"; exit 0;; -F|-X) exit 0;; esac; exit 0'
    log_t() { [[ "$2" == log.ks6_removed ]] && printf '%s\n' ks6_removed > "$TEST_ROOT/ks6-log"; }
    notify_event() { :; }
    local rc=0
    remove_killswitch_if_present || rc=$?
    [[ $rc -eq 1 ]] && [[ -s "$TEST_ROOT/ks6-log" ]]
}

T127() {
    new_env
    mock firefox 'exit 0'
    mock google-chrome 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    printf '%s\n' '{"managed":true}' > "$FIREFOX_POLICY_FILE"
    ! apply_browser_doh_policy >/dev/null 2>&1
    [[ -f "$FIREFOX_POLICY_FILE" ]] && [[ -f "$CHROME_POLICY_DIR/vpn-netguard-doh.json" ]] && [[ -f "$CHROME_POLICY_MARKER" ]]
}

T128() {
    new_env
    mock firefox 'exit 0'
    mock google-chrome 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' '{"managed":true}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    ! apply_browser_doh_policy >/dev/null 2>&1
    [[ -f "$FIREFOX_POLICY_FILE" ]] && [[ -f "$FIREFOX_POLICY_MARKER" ]] &&
    grep -Fxq '{"managed":true}' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" && [[ ! -f "$CHROME_POLICY_MARKER" ]]
}

T129() {
    new_env
    mock firefox 'exit 0'
    mock chromium 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    printf '%s\n' '{"managed":true}' > "$FIREFOX_POLICY_FILE"
    ! apply_browser_doh_policy >/dev/null 2>&1
    [[ -f "$FIREFOX_POLICY_FILE" ]] && [[ -f "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" ]] && [[ -f "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" ]]
}

T130() {
    new_env
    mock google-chrome 'exit 0'
    mock chromium 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' '{"managed":true}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    ! apply_browser_doh_policy >/dev/null 2>&1
    [[ -f "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" ]] && [[ -f "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" ]]
}

T135() {
    new_env
    mock iptables-restore 'cat > "$TEST_ROOT/restore"; exit 0'
    mock iptables 'exit 0'
    ks_restore_apply TEST ipt iptables-restore '-o tun0 -j ACCEPT'
    [[ -f "$TEST_ROOT/restore" ]] || return 1
    awk 'BEGIN{ok=0; last=""} {if ($0 == "-A TEST -j DROP") ok=1; if ($0 ~ /^-A TEST /) last=$0} END{exit !(ok && last == "-A TEST -j DROP")}' "$TEST_ROOT/restore"
}

T132() {
    python3 "$SCRIPT_DIR/test/validate_i18n.py" "$SCRIPT"
}

T136() {
    python3 "$SCRIPT_DIR/test/validate_test_harness.py" "$SCRIPT_DIR/test/test-vpn-netguard.sh"
}

T138() {
    new_env
    local lang help max=0 width
    for lang in es en; do
        help="$(VPN_NETGUARD_LANGUAGE="$lang" bash "$SCRIPT" --help)" || return 1
        while IFS= read -r line; do
            width=${#line}
            (( width > max )) && max=$width
        done <<<"$help"
    done
    (( max <= 140 ))
}

T137() {
    new_env
    local help
    help="$(VPN_NETGUARD_LANGUAGE=en bash "$SCRIPT" --help)" || return 1
    grep -Fq 'Usage:' <<<"$help" && grep -Fq '  install ' <<<"$help" && ! grep -Fq 'Uso:' <<<"$help"
}

run_test 'ShellCheck helper rejects an unpinned version' T110
run_test 'malformed IPv4 endpoint override never reuses a stale endpoint' T124
run_test 'malformed IPv6 endpoint override never reuses a stale endpoint' T125
run_test 'IPv4 removal failure does not hide IPv6 removal' T126
run_test 'Firefox conflict does not block Chrome hardening' T127
run_test 'Chrome conflict does not block Firefox hardening' T128
run_test 'Firefox conflict does not block Chromium hardening' T129
run_test 'Chrome conflict does not block Chromium hardening' T130
run_test 'all literal UI and log references have translations' T132
run_test 'atomic firewall restore places DROP last' T135
run_test 'test harness is registered exactly once and T17 mock is finite' T136
run_test 'English CLI help is actually localized' T137
run_test 'CLI help stays visually readable in both languages' T138


T134() {
    new_env
    export EXPECTED_SHELLCHECK_SCRIPT="$SCRIPT"
    fake="$MOCKBIN/docker"
    cat > "$fake" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == run && "$2" == --rm && "$3" == --network=none && "$4" == -v && "$5" == *:/src:ro ]] || exit 1
[[ "$6" == koalaman/shellcheck:v0.11.0 ]] || exit 1
[[ "$7" == -e && "$8" == SC2317,SC2034 && "$9" == -S && "${10}" == warning && "${11}" == /src/script/vpn-netguard.sh ]]
printf '%s\n' docker-ok > "$TEST_ROOT/docker.ok"
EOF
    chmod +x "$fake"
    VPN_NETGUARD_DISABLE_SHELLCHECK_DOWNLOAD=1 VPN_NETGUARD_DISABLE_SHELLCHECK_NPM=1 VPN_NETGUARD_DISABLE_SHELLCHECK_GO=1 \
        PATH="$MOCKBIN:$ORIG_PATH" "$SCRIPT_DIR/test/run-shellcheck.sh" >/dev/null 2>&1 &&
    [[ -f "$TEST_ROOT/docker.ok" ]]
}

T133() {
    new_env
    export EXPECTED_SHELLCHECK_SCRIPT="$SCRIPT"
    fake="$MOCKBIN/go"
    cat > "$fake" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run && "$2" == github.com/wasilibs/go-shellcheck/cmd/shellcheck@v0.11.0 ]]; then
    if [[ "$3" == --version ]]; then
        printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.11.0'
        exit 0
    fi
    [[ "$3" == -e && "$4" == 'SC2317,SC2034' && "$5" == -S && "$6" == warning && "$7" == "$EXPECTED_SHELLCHECK_SCRIPT" ]]
    exit $?
fi
exit 1
EOF
    chmod +x "$fake"
    PATH="$MOCKBIN:$ORIG_PATH" VPN_NETGUARD_DISABLE_SHELLCHECK_DOWNLOAD=1 VPN_NETGUARD_DISABLE_SHELLCHECK_NPM=1 VPN_NETGUARD_DISABLE_SHELLCHECK_DOCKER=1 VPN_NETGUARD_DISABLE_SHELLCHECK_PODMAN=1 "$SCRIPT_DIR/test/run-shellcheck.sh" >/dev/null 2>&1
}

run_test 'Go ShellCheck fallback is pinned and passes exact arguments' T133
run_test 'Docker ShellCheck fallback targets the repository script' T134

T161() {
    new_env
    fake="$MOCKBIN/go"
    cat > "$fake" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run && "$2" == github.com/wasilibs/go-shellcheck/cmd/shellcheck@v0.11.0 && "$3" == --version ]]; then
    printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.11.0'
    exit 0
fi
if [[ "$1" == run && "$2" == github.com/wasilibs/go-shellcheck/cmd/shellcheck@v0.11.0 ]]; then
    exit 7
fi
exit 1
EOF
    chmod +x "$fake"
    set +e
    PATH="$MOCKBIN:$ORIG_PATH" VPN_NETGUARD_DISABLE_SHELLCHECK_DOCKER=1 VPN_NETGUARD_DISABLE_SHELLCHECK_PODMAN=1 VPN_NETGUARD_DISABLE_SHELLCHECK_DOWNLOAD=1 VPN_NETGUARD_DISABLE_SHELLCHECK_NPM=1 "$SCRIPT_DIR/test/run-shellcheck.sh" >/dev/null 2>&1
    rc=$?
    set -e
    [[ $rc -eq 7 ]]
}

run_test 'Go ShellCheck fallback propagates lint failure status' T161

T139() {
    new_env
    rm -f "$STATE_FILE"
    ! want_vpn_active
    mark_vpn_wanted
    want_vpn_active
    unmark_vpn_wanted
    ! want_vpn_active
}

T140() {
    new_env
    KNOWN_VPN=(vpn-a)
    rm -f "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE"
    KILLSWITCH_MODE=auto; ! killswitch_should_be_active
    touch "$STATE_FILE"; killswitch_should_be_active
    KILLSWITCH_MODE=false; ! killswitch_should_be_active
    KILLSWITCH_MODE=true; killswitch_should_be_active
    printf '%s\n' off > "$KILLSWITCH_OVERRIDE_FILE"; ! killswitch_should_be_active
    printf '%s\n' on > "$KILLSWITCH_OVERRIDE_FILE"; killswitch_should_be_active
}

T141() {
    new_env
    KNOWN_VPN=(vpn-a)
    KILLSWITCH_MODE=false; vpn_reconnect_wanted
    KILLSWITCH_MODE=true; vpn_reconnect_wanted
    touch "$STATE_FILE"
    KILLSWITCH_MODE=auto; vpn_reconnect_wanted
    rm -f "$STATE_FILE"; ! vpn_reconnect_wanted
    KILLSWITCH_MODE=invalid; ! vpn_reconnect_wanted
}

T142() {
    new_env
    KNOWN_ETH=(eth-b eth-a); KNOWN_WIFI=(wifi-a)
    nmcli_up() { printf '%s\n' "$1" >> "$TEST_ROOT/reconnect.log"; [[ "$1" == eth-a ]]; }
    try_reconnect_physical
    [[ "$(cat "$TEST_ROOT/reconnect.log")" == $'eth-b\neth-a' ]]
}

T143() {
    new_env
    KNOWN_VPN=('Office Main' 'Office Backup' other)
    VPN_PRIORITY='Office Backup Office Main missing'
    mapfile -t got < <(ordered_known_vpn)
    [[ "${got[*]}" == 'Office Backup Office Main other' ]]
}

T144() {
    new_env
    EVENT_HISTORY_ENABLE=true
    EVENT_HISTORY_MAX_LINES=10
    DESKTOP_NOTIFICATIONS=false
    ALERT_HOOK=''
    notify_event vpn_up normal 'one "quoted"'
    notify_event vpn_up normal 'duplicate ignored'
    notify_event vpn_down critical 'two'
    [[ "$(wc -l < "$EVENT_HISTORY_FILE")" -eq 3 ]] || return 1
    grep -Fq '"one ""quoted"""' "$EVENT_HISTORY_FILE" && grep -Fqx 'vpn_down' "$EVENT_HISTORY_STATE_FILE"
}

T145() {
    new_env
    rm -f "$NOTIFY_STATE_FILE"
    DESKTOP_NOTIFICATIONS=true
    notify_send() { printf '%s\n' "$*" >> "$TEST_ROOT/notify.log"; }
    run_alert_hook() { :; }
    notify_event up normal first
    notify_event up normal second
    notify_event down normal third
    [[ "$(wc -l < "$TEST_ROOT/notify.log")" -eq 2 ]]
}

T146() {
    new_env
    PING_TARGETS='bad good'
    PING_TIMEOUT=1
    mock ping '[[ "$3" == good ]] && exit 0; exit 1'
    check_internet_reachable
}

T147() {
    new_env
    ACTIVE_VPN=VPN; VPN_TYPE=wireguard; VPN_IFACE=tun0
    PING_TARGETS='1.1.1.1'
    mock ping 'exit 0'
    mock wg 'printf "1 10\n"'
    ! tunnel_reachable
}

T148() {
    new_env
    PHYS_IFACE=eth0
    rm -f "$MOCKBIN/resolvectl"
    mock nmcli 'if [[ "$*" == *"IP4.DNS"* ]]; then printf "1.1.1.1|9.9.9.9\n"; elif [[ "$*" == *"IP6.DNS"* ]]; then printf "2001:4860:4860::8888\n"; fi'
    mapfile -t dns < <(PATH="$MOCKBIN:$ORIG_PATH" system_dns_servers)
    [[ "${dns[*]}" == '1.1.1.1 9.9.9.9 2001:4860:4860::8888' ]]
}

T149() {
    new_env
    DNS_SERVERS='1.1.1.1'
    PHYS_IFACE=eth0
    system_dns_servers() { printf '%s\n' '9.9.9.9'; }
    DNS_MISMATCH_WARNED=0
    log_t() { [[ "$2" == log.dns_mismatch ]] && printf '%s\n' mismatch >> "$TEST_ROOT/dns.log"; }
    warn_if_dns_mismatch
    warn_if_dns_mismatch
    [[ "$(wc -l < "$TEST_ROOT/dns.log")" -eq 1 ]] || return 1
    system_dns_servers() { printf '%s\n' '1.1.1.1'; }
    warn_if_dns_mismatch
    system_dns_servers() { printf '%s\n' '9.9.9.9'; }
    warn_if_dns_mismatch
    [[ "$(wc -l < "$TEST_ROOT/dns.log")" -eq 2 ]]
}

T150() {
    new_env
    MAC_MODE=stable; ROTATE_MAC_PER_BOOT=true; ROTATE_MAC_EVERY_HOURS=4
    RANDOMIZE_SCAN_MAC=true; MAC_OUI_MASK='ff:ff:ff:00:00:00'
    HARDEN_DHCP_IDENTIFIERS=true; IPV6_PRIVACY=true; DISABLE_IPV6=false
    SPOOF_HOSTNAME=true; DHCP_HOSTNAME_OVERRIDE='host-test'; DISABLE_MDNS_ANNOUNCE=true
    write_privacy_conf
    grep -Fxq 'wifi.cloned-mac-address=stable' "$NM_PRIVACY_CONF" || return 1
    token="$(cat "$MAC_ROTATE_TOKEN_FILE")"
    grep -Fxq "connection.stable-id=\${CONNECTION}/\${BOOT}/$token" "$NM_PRIVACY_CONF" || return 1
    grep -Fxq 'ipv4.dhcp-hostname=host-test' "$NM_PRIVACY_CONF" || return 1
    grep -Fxq 'connection.mdns=0' "$NM_PRIVACY_CONF" || return 1
    DISABLE_IPV6=true
    write_privacy_conf
    grep -Fxq 'ipv6.method=disabled' "$NM_PRIVACY_CONF" && ! grep -Fxq 'ipv6.ip6-privacy=2' "$NM_PRIVACY_CONF"
}

T151() {
    new_env
    ANONYMIZE_NETWORK=false
    touch "$NM_PRIVACY_CONF"
    restore_avahi_daemon() { :; }
    restore_netbios_service() { :; }
    remove_browser_doh_policy() { :; }
    remove_mac_rotate_timer() { :; }
    reload_networkmanager_conf() { :; }
    apply_network_privacy
    [[ ! -e "$NM_PRIVACY_CONF" ]]
}

T152() {
    new_env
    printf '%s\n' "$FIREFOX_POLICY_FILE" > "$FIREFOX_POLICY_MARKER"
    mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")"
    printf '%s\n' '{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}' > "$FIREFOX_POLICY_FILE"
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' 'x' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    printf '%s\n' "$CHROME_POLICY_DIR/vpn-netguard-doh.json" > "$CHROME_POLICY_MARKER"
    ! remove_browser_doh_policy
    [[ ! -e "$FIREFOX_POLICY_FILE" && ! -e "$FIREFOX_POLICY_MARKER" ]] || return 1
    [[ -e "$CHROME_POLICY_DIR/vpn-netguard-doh.json" && -e "$CHROME_POLICY_MARKER" ]]
}

T153() {
    new_env
    mock systemctl 'case "$*" in *"is-active --quiet"*) exit 1;; *"is-enabled"*) echo enabled; exit 0;; esac; exit 0'
    [[ "$(unit_saved_state foo.service)" == enabled-inactive ]]
    mock systemctl 'case "$*" in *"is-active --quiet"*) exit 0;; *"is-enabled"*) echo disabled; exit 0;; esac; exit 0'
    [[ "$(unit_saved_state foo.service)" == disabled-active ]]
}

T154() {
    new_env
    touch_heartbeat
    [[ -s "$HEARTBEAT_FILE" ]] || return 1
    [[ "$(cat "$HEARTBEAT_FILE")" =~ ^[0-9]+$ ]]
}

T155() {
    new_env
    WATCHDOG_STALE_AFTER=60
    NOTIFY_SOCKET=1
    log_t() { [[ "$2" == log.watchdog_stale ]] && printf '%s\n' stale >> "$TEST_ROOT/watchdog.log"; }
    mock systemd-notify 'printf "%s\n" "$*" >> "$TEST_ROOT/notify"'
    touch_heartbeat
    watchdog_ping_if_alive
    grep -Fqx 'WATCHDOG=1' "$TEST_ROOT/notify" || return 1
    printf '1\n' > "$HEARTBEAT_FILE"
    watchdog_ping_if_alive
    [[ "$(wc -l < "$TEST_ROOT/notify")" -eq 1 && "$(wc -l < "$TEST_ROOT/watchdog.log")" -eq 1 ]]
}

T156() {
    new_env
    local output="$TEST_ROOT/menu.out"
    printf '0\n' | bash "$SCRIPT" >"$output" 2>&1
    grep -Fq '17)' "$output" && grep -Fq '0)' "$output"
}

T157() {
    new_env
    config_key_allowed LANGUAGE && config_key_allowed HARDEN_BROWSER_DOH && ! config_key_allowed BASH_ENV && ! config_key_allowed MALICIOUS
}

T158() {
    new_env
    [[ "$(decimal_normalize_max 00025 25)" == 25 ]] || return 1
    [[ "$(decimal_normalize_max 9223372036854775807 9223372036854775807)" == 9223372036854775807 ]] || return 1
    ! decimal_normalize_max 9223372036854775808 9223372036854775807
    ! decimal_normalize_max abc 25
    [[ "$(decimal_normalize_max 000 25)" == 0 ]]
}

T159() {
    new_env
    [[ "$(dep_apt_package nmcli)" == network-manager ]] &&
    [[ "$(dep_apt_package systemctl)" == systemd ]] &&
    [[ "$(dep_apt_package unknown-pkg)" == unknown-pkg ]]
}

T160() {
    new_env
    local old_ifs="$IFS"
    mock nmcli 'printf "%s\n" "One:802-3-ethernet" "Two:802-11-wireless" "VPN:vpn"'
    detect_known_profiles
    [[ "${KNOWN_ETH[*]}" == One && "${KNOWN_WIFI[*]}" == Two && "${KNOWN_VPN[*]}" == VPN && "$IFS" == "$old_ifs" ]]
}

# cmd_menu construye las etiquetas del menú principal como "menu.action$i"
# (i=1..17), una clave por número compuesta en tiempo de ejecución: el
# validador estático de i18n no puede verla (no hay ningún "menu.action7"
# literal en el código para que la encuentre) y una desalineación con el
# case de cmd_menu no da ningún error, solo un menú con un hueco o con el
# nombre crudo de la clave. T162 cubre justo ese punto ciego.
T162() {
    new_env
    local i t
    for i in $(seq 1 18); do
        t="$(ui_t "menu.action$i")"
        [[ "$t" != "menu.action$i" && -n "$t" ]] || return 1
    done
    [[ "$(ui_t "menu.action19")" == "menu.action19" ]]
}

T163() {
    new_env
    local f; f="$(mktemp)"
    printf 'KILLSWITCH_MODE=auto\r\n' > "$f"
    printf 'CHECK_INTERVAL=25\n' >> "$f"
    ! config_file_is_safe "$f"
}

run_test 'wanted VPN state is created and cleared predictably' T139
run_test 'kill-switch policy honors override and mode matrix' T140
run_test 'VPN reconnection policy follows mode and desired state' T141
run_test 'physical reconnection tries Ethernet then Wi-Fi in order' T142
run_test 'VPN priority preserves names containing spaces' T143
run_test 'event history deduplicates independently of notifications' T144
run_test 'notification state suppresses duplicate transitions' T145
run_test 'reachability tries all configured targets' T146
run_test 'WireGuard stale handshake makes tunnel unreachable' T147
run_test 'system DNS fallback parses IPv4 and IPv6 output' T148
run_test 'DNS mismatch warning deduplicates and resets' T149
run_test 'privacy snippet tracks MAC rotation and IPv6 mode' T150
run_test 'privacy disable path removes generated configuration' T151
run_test 'browser removal preserves modified owned files' T152
run_test 'saved unit state distinguishes enabled-inactive and disabled-active' T153
run_test 'heartbeat is written as numeric epoch atomically' T154
run_test 'watchdog pings only with a fresh heartbeat' T155
run_test 'interactive menu has a deterministic exit path' T156
run_test 'configuration whitelist rejects unknown keys' T157
run_test 'decimal normalization covers zero, max and overflow' T158
run_test 'dependency package mapping is stable' T159
run_test 'profile detection does not leak shell IFS state' T160
run_test 'main menu action labels exist for exactly items 1-18' T162
run_test 'config_file_is_safe rejects CRLF line endings' T163

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
