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
    COEXIST_YIELD_FILE="$STATE_DIR/coexist-yield"
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/killswitch-autodisabled"
    KS_BOOT_RACE_PENDING_FILE="$STATE_DIR/killswitch-boot-race-pending"
    CONFIG_FILE="$TEST_ROOT/vpn-netguard.conf"
    CONF_DIR="$TEST_ROOT/etc"          # cmd_uninstall (T49) lo borra con rm -rf
    ICON_DST="$TEST_ROOT/share/icon.svg"   # ídem, y su carpeta con rmdir
    ROOT_HOME_DIR="$TEST_ROOT/root-home"   # cmd_uninstall (T49, T266) retira de aquí y de USERS_HOME_DIR/* los lanzadores del Escritorio
    USERS_HOME_DIR="$TEST_ROOT/homes"
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
    KNOWN_ETH=() KNOWN_WIFI=() KNOWN_VPN=() IGNORED_VPN=() KS_VPN_CANDIDATES=()
    FOREIGN_TUNNELS=() FOREIGN_MARKS=() FOREIGN_KS=()
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

# fw_model_install: modelo con estado de la cadena OUTPUT para iptables/ip6tables
# y sus *-restore. Cada familia guarda sus reglas (texto tras "-A OUTPUT ") en
# $TEST_ROOT/fw4.rules o fw6.rules y anota cada escritura en fw4.log o fw6.log
# junto con los saltos a $FW_CHAIN que quedan (jumps=N). Fallos inyectables
# creando ficheros: fwN.deny-S (OUTPUT ilegible), fwN.deny-restore (transacción
# revertida), fwN.race-after-I (otro cortafuegos inserta una regla justo
# después del primer -I; una sola vez).
fw_model_install() {
    cat > "$TEST_ROOT/fwmodel.sh" <<'EOF'
fw_load() { FW_RULES=(); [[ -f "$1.rules" ]] && mapfile -t FW_RULES < "$1.rules"; return 0; }
fw_save() { local r; : > "$1.rules"; for r in "${FW_RULES[@]}"; do printf '%s\n' "$r" >> "$1.rules"; done; }
fw_jumps() { local r n=0; for r in "${FW_RULES[@]}"; do [[ "$r" == "-j ${FW_CHAIN:-}" ]] && n=$((n + 1)); done; echo "$n"; }
fw_log() { printf '%s jumps=%s\n' "$2" "$(fw_jumps)" >> "$1.log"; }
fw_insert() { local pos="$1" spec="$2"; FW_RULES=("${FW_RULES[@]:0:pos-1}" "$spec" "${FW_RULES[@]:pos-1}"); }
fw_delete_at() { local pos="$1"; [[ -n "${FW_RULES[pos-1]+x}" ]] || return 1; FW_RULES=("${FW_RULES[@]:0:pos-1}" "${FW_RULES[@]:pos}"); }
fw_delete_spec() {
    local i
    for i in "${!FW_RULES[@]}"; do
        [[ "${FW_RULES[i]}" == "$1" ]] && { fw_delete_at $((i + 1)); return; }
    done
    return 1
}
fw_ipt() {
    local f="$1" op r n; shift
    [[ "${1:-}" == -w ]] && shift 2
    op="${1:-}"; shift
    [[ "$op" == -N ]] && return 1
    [[ "${1:-}" == OUTPUT ]] || return 0
    shift
    fw_load "$f"
    case "$op" in
        -S)
            [[ -f "$f.deny-S" ]] && return 1
            if [[ -n "${1:-}" ]]; then
                [[ -n "${FW_RULES[$1-1]+x}" ]] || return 1
                echo "-A OUTPUT ${FW_RULES[$1-1]}"
                return 0
            fi
            echo '-P OUTPUT ACCEPT'
            for r in "${FW_RULES[@]}"; do echo "-A OUTPUT $r"; done ;;
        -C)
            for r in "${FW_RULES[@]}"; do [[ "$r" == "$*" ]] && return 0; done
            return 1 ;;
        -I)
            n=1
            if [[ "${1:-}" =~ ^[0-9]+$ ]]; then n="$1"; shift; fi
            fw_insert "$n" "$*"
            if [[ -f "$f.race-after-I" ]]; then
                rm -f "$f.race-after-I"; fw_insert 1 '-s 203.0.113.9 -j DROP'
            fi
            fw_save "$f"; fw_log "$f" "I $n $*" ;;
        -D)
            if [[ "${1:-}" =~ ^[0-9]+$ ]]; then fw_delete_at "$1" || return 1; else fw_delete_spec "$*" || return 1; fi
            fw_save "$f"; fw_log "$f" "D $*" ;;
        *) return 0 ;;
    esac
}
fw_restore() {
    local f="$1" line rest pos; shift
    cat > "$f.restore-in"
    fw_load "$f"
    if [[ -f "$f.deny-restore" ]]; then fw_log "$f" 'R denied'; return 1; fi
    while IFS= read -r line; do
        case "$line" in
            '*filter'|COMMIT|'') ;;
            '-D OUTPUT '*) fw_delete_spec "${line#-D OUTPUT }" || return 1 ;;
            '-I OUTPUT '*)
                rest="${line#-I OUTPUT }"; pos=1
                if [[ "$rest" =~ ^([0-9]+)\ (.*)$ ]]; then pos="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fi
                fw_insert "$pos" "$rest" ;;
            *) return 1 ;;
        esac
    done < "$f.restore-in"
    fw_save "$f"; fw_log "$f" R
}
EOF
    local fam
    for fam in 4:iptables 6:ip6tables; do
        mock "${fam#*:}" "source \"\$TEST_ROOT/fwmodel.sh\"; fw_ipt \"\$TEST_ROOT/fw${fam%%:*}\" \"\$@\"; exit \$?"
        mock "${fam#*:}-restore" "source \"\$TEST_ROOT/fwmodel.sh\"; fw_restore \"\$TEST_ROOT/fw${fam%%:*}\" \"\$@\"; exit \$?"
    done
    source "$TEST_ROOT/fwmodel.sh"
}
# fw_set <4|6> [regla...]: fija OUTPUT (borra el registro). fw_dump <4|6>: "a|b|c".
fw_set() { local fam="$1"; shift; rm -f "$TEST_ROOT/fw$fam".{log,deny-S,deny-restore,race-after-I}; FW_RULES=("$@"); fw_save "$TEST_ROOT/fw$fam"; }
fw_dump() { fw_load "$TEST_ROOT/fw$1"; local IFS='|'; printf '%s' "${FW_RULES[*]}"; }
fw_writes() { local f="$TEST_ROOT/fw$1.log"; [[ -f "$f" ]] && cat "$f"; return 0; }

T1() { bash -n "$SCRIPT" && bash -u -n "$SCRIPT"; }
T2() {
    new_env; UI_LANGUAGE=en; ui_init
    [[ "$(ui_t status.title)" == 'Current status' ]] || return 1
    UI_LANGUAGE=es; ui_init
    [[ "$(ui_t status.title)" == 'Estado actual' ]]
}
T3() {
    new_env
    base_config
    load_config
    [[ "$CHECK_INTERVAL" == 25 && "$PING_TIMEOUT" == 3 && "$EVENT_HISTORY_MAX_LINES" == 5000 ]] || return 1
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
    [[ ! -e "$TEST_ROOT/hit" ]] || return 1
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
    unit_file_exists avahi-daemon.service || return 1
    rm -f "$STATE_DIR/marker"
    mask_service_remembering_state avahi-daemon.service '' marker
    [[ -f "$STATE_DIR/marker" ]] || return 1
    unmask_service_restoring_state avahi-daemon.service '' marker
    [[ ! -f "$STATE_DIR/marker" ]] || return 1
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
    ! killswitch_should_be_active || return 1
    set_killswitch_override on
    killswitch_should_be_active || return 1
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
    unit_file_exists static.service || return 1
    mask_service_remembering_state static.service '' marker
    [[ "$(sed -n '1p' "$STATE_DIR/marker")" == static-active ]] || return 1
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
    ! grep -q '__UI_LANGUAGE__' "$TEST_ROOT/default.conf" || return 1
    ! grep -nE '^[[:space:]]*source[[:space:]]' "$TEST_ROOT/default.conf"
}

T19() {
    new_env
    mock systemctl 'case "$1" in list-unit-files) echo "avahi-daemon.service enabled";; is-enabled) echo enabled; exit 0;; is-active) [[ "$*" == *"--quiet"* ]] || echo active; exit 0;; mask|unmask|enable|disable|start) exit 0;; esac; exit 0'
    unit_file_exists avahi-daemon.service || return 1
    mask_service_remembering_state avahi-daemon.service '' marker
    [[ "$(sed -n '1p' "$STATE_DIR/marker")" == enabled-active ]] || return 1
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
    mock iptables 'printf "%s\n" "$*" >> "$IPTABLES_LOG"; exit 0'
    IPTABLES_LOG="$TEST_ROOT/iptables.log"
    export IPTABLES_LOG
    # Con *-restore fallando el respaldo vacía la cadena, añade la excepción y cierra con el DROP: devuelve 0.
    ks_restore_apply TEST ipt iptables-restore '-d 1.2.3.4 -j RETURN' >/dev/null 2>&1 ||
        { echo "el respaldo devuelve error aunque todas las reglas se aplicaron" >&2; return 1; }
    local want=$'-w 5 -F TEST\n-w 5 -A TEST -d 1.2.3.4 -j RETURN\n-w 5 -A TEST -j DROP'
    [[ "$(<"$IPTABLES_LOG")" == "$want" ]] ||
        { echo "reglas del respaldo distintas de las esperadas (-F, excepción, DROP final):" >&2; cat "$IPTABLES_LOG" >&2; return 1; }
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
    python3 -m json.tool "$FIREFOX_POLICY_FILE" >/dev/null 2>&1 || return 1
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
    ! apply_browser_doh_policy || return 1
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
    ! apply_network_privacy || return 1
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
    record_event_if_changed up 'detail repeated'   # mismo estado que el anterior: no se registra
    # Cabecera + 3 eventos (3 es el límite y no recorta); el repetido no suma línea.
    [[ "$(wc -l < "$EVENT_HISTORY_FILE")" -eq 4 ]] || { echo "$(wc -l < "$EVENT_HISTORY_FILE") líneas (se esperaban 4: cabecera y 3 eventos)" >&2; return 1; }
    ! grep -Fq 'detail repeated' "$EVENT_HISTORY_FILE" || { echo "el estado repetido se registró" >&2; return 1; }
    grep -Fq 'detail ""one""' "$EVENT_HISTORY_FILE"   # las comillas del detalle se duplican (CSV)
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
        ! do_deactivate || return 1
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
    python3 -m json.tool "$CHROME_POLICY_DIR/vpn-netguard-doh.json" >/dev/null 2>&1 || return 1
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
        ! reconcile_sync || return 1
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
    ! ( cmd_uninstall ) || return 1
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
    ! ( cmd_uninstall ) || return 1
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
    [[ -z "$(parse_endpoint_spec 'vpn.example:65536:udp' 1194 udp)" ]] || return 1
    [[ -z "$(parse_endpoint_spec 'vpn.example:0:udp' 1194 udp)" ]]
}

T51() {
    new_env; fw_model_install
    CHAIN_NAME=TEST; export FW_CHAIN=TEST
    # Repetido y desplazado: una sola transacción *-restore; el orden ajeno se conserva.
    fw_set 4 '-o eth9 -j DROP' '-j TEST' '-p tcp --dport 9 -j DROP' '-j TEST'
    ensure_chain || return 1
    [[ "$(fw_dump 4)" == '-j TEST|-o eth9 -j DROP|-p tcp --dport 9 -j DROP' ]] &&
    [[ "$(fw_writes 4)" == 'R jumps=1' ]]
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
    ! cmd_import_config "$TEST_ROOT/import.conf" >/dev/null 2>&1 || return 1
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
    ! write_privacy_conf || return 1
    [[ ! -f "$NM_PRIVACY_CONF" ]]
}



T58() {
    new_env
    write_desktop_file > "$DESKTOP_DST"
    grep -Fxq 'Type=Application' "$DESKTOP_DST" &&
    grep -Fxq "Exec=$BIN_DST launch" "$DESKTOP_DST" &&
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
    [[ "$v1" == "$v2" ]] && [[ "$v1" == 'VPN NetGuard 2.6.0' ]] &&
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
    # Por el camino real: load_config normaliza los pasos («05» -> «5») y de ahí salen los retardos.
    printf '%s\n' 'RECONNECT_BACKOFF="05 15 30"' > "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    [[ "$RECONNECT_BACKOFF" == '5 15 30' ]] || { echo "pasos tras load_config: «$RECONNECT_BACKOFF»" >&2; return 1; }
    VPN_BACKOFF_STEP=0
    [[ "$(vpn_backoff_seconds)" == 5 ]] || { echo "sin fallos: $(vpn_backoff_seconds) s (se esperaban 5)" >&2; return 1; }
    vpn_backoff_register_failure
    [[ $VPN_BACKOFF_STEP -eq 1 && $VPN_BACKOFF_LAST_ATTEMPT -gt 0 && "$(vpn_backoff_seconds)" == 5 ]] ||
        { echo "1.er fallo: paso $VPN_BACKOFF_STEP, intento $VPN_BACKOFF_LAST_ATTEMPT, $(vpn_backoff_seconds) s (se esperaba paso 1, hora del intento > 0 y 5 s)" >&2; return 1; }
    vpn_backoff_register_failure
    [[ $VPN_BACKOFF_STEP -eq 2 && "$(vpn_backoff_seconds)" == 15 ]] ||
        { echo "2.º fallo: paso $VPN_BACKOFF_STEP, $(vpn_backoff_seconds) s (se esperaba 2 y 15)" >&2; return 1; }
    # Con el último paso alcanzado no sigue subiendo.
    vpn_backoff_register_failure
    vpn_backoff_register_failure
    [[ $VPN_BACKOFF_STEP -eq 3 && "$(vpn_backoff_seconds)" == 30 ]] ||
        { echo "4.º fallo: paso $VPN_BACKOFF_STEP, $(vpn_backoff_seconds) s (se esperaba 3 y 30)" >&2; return 1; }
    vpn_backoff_reset
    [[ $VPN_BACKOFF_STEP -eq 0 && $VPN_BACKOFF_LAST_ATTEMPT -eq 0 ]] ||
        { echo "tras reiniciar: paso $VPN_BACKOFF_STEP, intento $VPN_BACKOFF_LAST_ATTEMPT (se esperaba 0 y 0)" >&2; return 1; }
    printf '%s\n' 'RECONNECT_BACKOFF="00 05"' > "$CONFIG_FILE"
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
    grep -Fq 'DisableTelemetry' "$FIREFOX_POLICY_FILE" || return 1
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
    ! nmcli_up 'Slow' || return 1
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
    config_file_is_safe "$TEST_ROOT/config" || return 1
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
    for _ in {1..100}; do [[ -f "$TEST_ROOT/hook.out" ]] && break; sleep 0.05; done
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
    python3 -m json.tool "$FIREFOX_POLICY_FILE" >/dev/null 2>&1 || return 1
    ! grep -q '_vpn_netguard_managed' "$FIREFOX_POLICY_FILE" || return 1
    [[ -f "$FIREFOX_POLICY_MARKER" ]] || return 1
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
    ! apply_browser_doh_policy >/dev/null 2>&1 || return 1
    grep -q 'DisableTelemetry' "$FIREFOX_POLICY_FILE" || return 1
    ! remove_browser_doh_policy >/dev/null 2>&1 || return 1
    grep -q 'DisableTelemetry' "$FIREFOX_POLICY_FILE"
}

T86() {
    new_env
    MAC_MODE=stable
    ROTATE_MAC_EVERY_HOURS=1
    mock systemctl '[[ "$1" == "daemon-reload" ]] && exit 0; [[ "$1" == "enable" ]] && exit 1; exit 0'
    ! sync_mac_rotate_timer || return 1
    [[ ! -e "$MAC_ROTATE_UNIT_DST" && ! -e "$MAC_ROTATE_TIMER_DST" ]]
}

T87() {
    new_env
    mock nmcli 'exit 0'; mock iptables 'exit 0'; mock ping 'exit 0'; mock getent 'exit 0'; mock flock 'exit 0'; mock awk 'exit 0'; mock sed 'exit 0'; mock grep 'exit 0'; mock systemctl 'exit 0'; mock ip6tables 'exit 0'
    HAVE_IP6TABLES=0
    # PATH solo con los simulacros: un ip6tables real (p. ej. en /usr/sbin) no cuenta.
    PATH="$MOCKBIN" check_dependencies || { echo "con ip6tables, check_dependencies devuelve error" >&2; return 1; }
    [[ $HAVE_IP6TABLES -eq 1 ]] || { echo "con ip6tables, HAVE_IP6TABLES no pasa a 1" >&2; return 1; }
    rm -f "$MOCKBIN/ip6tables"
    # D14: ip6tables es opcional; sin él check_dependencies devuelve 0 (cmd_doctor lee su código).
    PATH="$MOCKBIN" check_dependencies || { echo "sin ip6tables, check_dependencies devuelve error (D14)" >&2; return 1; }
    [[ $HAVE_IP6TABLES -eq 0 ]] || { echo "sin ip6tables, HAVE_IP6TABLES no vuelve a 0" >&2; return 1; }
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
    valid_ipv6_literal '2001:db8::1234' || return 1
    [[ -z "${_ipv6_parts+x}" ]] || return 1
    [[ "$(resolve_ipv6 '2001:db8::1234')" == '2001:db8::1234' ]] || return 1
    ! valid_ipv6_literal '2001:db8:::1234' || return 1
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
    local before
    before="$(<"$FIREFOX_POLICY_FILE")"
    # Aunque el contenido sea idéntico al de NetGuard, sin marcador el fichero es ajeno: no se adopta...
    ! apply_browser_doh_policy >/dev/null 2>&1 || { echo "apply_browser_doh_policy adopta un fichero ajeno" >&2; return 1; }
    [[ ! -f "$FIREFOX_POLICY_MARKER" ]] || { echo "se creó el marcador de un fichero ajeno" >&2; return 1; }
    [[ "$(<"$FIREFOX_POLICY_FILE")" == "$before" ]] || { echo "apply_browser_doh_policy cambió el fichero ajeno" >&2; return 1; }
    # ...y quitar no es un fallo (no hay nada propio) ni lo borra.
    remove_browser_doh_policy >/dev/null 2>&1 || { echo "remove_browser_doh_policy falla sin nada propio que quitar" >&2; return 1; }
    [[ "$(<"$FIREFOX_POLICY_FILE")" == "$before" ]] || { echo "remove_browser_doh_policy tocó el fichero ajeno" >&2; return 1; }
}

T92() {
    new_env
    printf 'PING_TARGETS="safe" touch "%s/pwned"\n' "$TEST_ROOT" > "$CONFIG_FILE"
    ! config_file_is_safe "$CONFIG_FILE" || return 1
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
    ! parse_endpoint_spec 'vpn.example:-1:udp' 1194 udp >/dev/null || return 1
    ! parse_endpoint_spec 'vpn.example:abc:udp' 1194 udp >/dev/null || return 1
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
    remove_killswitch_if_present || { echo "T95: quitar el kill switch con iptables bien debe devolver 0" >&2; return 1; }
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
    remove_killswitch6_if_present || { echo "T96: quitar el kill switch IPv6 con ip6tables bien debe devolver 0" >&2; return 1; }
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
    # Una clave inofensiva (la que debilitaría el kill switch) antes de la línea rechazada: el fichero se ignora ENTERO.
    printf 'KILLSWITCH_MODE="false"\nALERT_HOOK="$(touch "%s/pwned")"\n' "$TEST_ROOT" > "$CONFIG_FILE"
    ! config_file_is_safe "$CONFIG_FILE" || { echo "se acepta una sustitución de comandos entre comillas" >&2; return 1; }
    local want
    printf -v want -- "$(ui_t log.config_unsafe_file)" "$CONFIG_FILE"
    # Rechazar el fichero no es un fallo de load_config: avisa por stderr y sigue con los valores por defecto.
    load_config >/dev/null 2>"$TEST_ROOT/load.err" || { echo "load_config devuelve error con un fichero rechazado" >&2; return 1; }
    grep -Fq -- "$want" "$TEST_ROOT/load.err" || { echo "falta el aviso de fichero rechazado" >&2; return 1; }
    [[ "$KILLSWITCH_MODE" == auto && -z "$ALERT_HOOK" ]] || { echo "se aplicó algo del fichero rechazado" >&2; return 1; }
    [[ ! -e "$TEST_ROOT/pwned" ]] || { echo "se ejecutó la sustitución de comandos" >&2; return 1; }
}



T104() {
    new_env
    WATCHDOG_PING_INTERVAL=0
    WATCHDOG_STALE_AFTER=0
    WATCHDOG_USEC=999999999999999999999999999999999999
    configure_watchdog
    [[ $WATCHDOG_PING_INTERVAL -eq 0 && $WATCHDOG_STALE_AFTER -eq 0 ]] || return 1
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
    valid_ipv4_literal '000000000000000000000000000192.0.2.1' || return 1
    ! valid_ipv4_literal '999999999999999999999999.0.0.1' || return 1
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
    grep -Fq 'vigilancia de red' <<<"$es_service" || return 1
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
    grep -Fq 'Política de dirección MAC' <<<"$(ui_field_label MAC_MODE)" || return 1
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
    ! apply_browser_doh_policy >/dev/null 2>&1 || return 1
    [[ -f "$FIREFOX_POLICY_FILE" ]] && [[ -f "$CHROME_POLICY_DIR/vpn-netguard-doh.json" ]] && [[ -f "$CHROME_POLICY_MARKER" ]]
}

T128() {
    new_env
    mock firefox 'exit 0'
    mock google-chrome 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' '{"managed":true}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    ! apply_browser_doh_policy >/dev/null 2>&1 || return 1
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
    ! apply_browser_doh_policy >/dev/null 2>&1 || return 1
    [[ -f "$FIREFOX_POLICY_FILE" ]] && [[ -f "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" ]] && [[ -f "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" ]]
}

T130() {
    new_env
    mock google-chrome 'exit 0'
    mock chromium 'exit 0'
    HARDEN_BROWSER_DOH=true
    mkdir -p "$CHROME_POLICY_DIR"
    printf '%s\n' '{"managed":true}' > "$CHROME_POLICY_DIR/vpn-netguard-doh.json"
    ! apply_browser_doh_policy >/dev/null 2>&1 || return 1
    [[ -f "$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json" ]] && [[ -f "$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json" ]]
}

T135() {
    new_env
    mock iptables-restore 'cat > "$TEST_ROOT/restore"; exit 0'
    mock iptables 'exit 0'
    ks_restore_apply TEST ipt iptables-restore '-o tun0 -j RETURN'
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
run_test 'all literal UI and log references have translations and no translation key is unused' T132
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
    ! want_vpn_active || return 1
    mark_vpn_wanted
    want_vpn_active || return 1
    unmark_vpn_wanted
    ! want_vpn_active
}

T140() {
    new_env
    KNOWN_VPN=(vpn-a)
    rm -f "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE"
    KILLSWITCH_MODE=auto; ! killswitch_should_be_active || return 1
    touch "$STATE_FILE"; killswitch_should_be_active || return 1
    KILLSWITCH_MODE=false; ! killswitch_should_be_active || return 1
    KILLSWITCH_MODE=true; killswitch_should_be_active || return 1
    printf '%s\n' off > "$KILLSWITCH_OVERRIDE_FILE"; ! killswitch_should_be_active || return 1
    printf '%s\n' on > "$KILLSWITCH_OVERRIDE_FILE"; killswitch_should_be_active
}

T141() {
    new_env
    KNOWN_VPN=(vpn-a)
    KILLSWITCH_MODE=false; vpn_reconnect_wanted || return 1
    KILLSWITCH_MODE=true; vpn_reconnect_wanted || return 1
    touch "$STATE_FILE"
    KILLSWITCH_MODE=auto; vpn_reconnect_wanted || return 1
    rm -f "$STATE_FILE"; ! vpn_reconnect_wanted || return 1
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
    ! remove_browser_doh_policy || return 1
    [[ ! -e "$FIREFOX_POLICY_FILE" && ! -e "$FIREFOX_POLICY_MARKER" ]] || return 1
    [[ -e "$CHROME_POLICY_DIR/vpn-netguard-doh.json" && -e "$CHROME_POLICY_MARKER" ]]
}

T153() {
    new_env
    mock systemctl 'case "$*" in *"is-active --quiet"*) exit 1;; *"is-enabled"*) echo enabled; exit 0;; esac; exit 0'
    [[ "$(unit_saved_state foo.service)" == enabled-inactive ]] || return 1
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
    local output="$TEST_ROOT/menu.out" kind num icon id last=0
    UI_LANGUAGE=en
    # Sin argumentos manda la interfaz fijada por el usuario (~/.config): un XDG_CONFIG_HOME propio y
    # vacío deja el arranque en la terminal aunque quien lance la suite tenga el panel fijado.
    mkdir -p "$TEST_ROOT/xdg"
    printf '0\n' | XDG_CONFIG_HOME="$TEST_ROOT/xdg" VPN_NETGUARD_LANGUAGE=en bash "$SCRIPT" >"$output" 2>&1
    # Cada fila del modelo sale tal cual en el menú de texto: categorías, número,
    # icono y etiqueta, y nada más allá de la última entrada.
    while IFS='|' read -r kind num icon id; do
        if [[ "$kind" == H ]]; then
            grep -Fxq -- "$(ui_t "$id")" "$output" || return 1
        else
            grep -Fxq -- "$(printf '%2d) %s %s' "$num" "$icon" "$(menu_label "$id" text)")" "$output" || return 1
            last="$num"
        fi
    done < <(menu_rows text)
    grep -Fxq -- " 0) $(ui_t menu.exit0)" "$output" &&
    ! grep -Fq -- "$((last + 1)))" "$output" &&
    ! grep -Fq 'Force the kill switch now' "$output" &&
    ! grep -Fq 'Disable VPN protection' "$output" &&
    ! grep -Fq 'Apply network privacy now' "$output" &&
    ! grep -Fq 'View network privacy status' "$output"
}

T157() {
    new_env
    config_key_allowed LANGUAGE && config_key_allowed HARDEN_BROWSER_DOH && ! config_key_allowed BASH_ENV && ! config_key_allowed MALICIOUS
}

T158() {
    new_env
    [[ "$(decimal_normalize_max 00025 25)" == 25 ]] || return 1
    [[ "$(decimal_normalize_max 9223372036854775807 9223372036854775807)" == 9223372036854775807 ]] || return 1
    ! decimal_normalize_max 9223372036854775808 9223372036854775807 || return 1
    ! decimal_normalize_max abc 25 || return 1
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

# Las etiquetas de los menús se piden con "ui_t menu.xxx", "ui_t killswitch.xxx"
# etc. sin comillas, y validate_i18n.py solo ve las referencias entre comillas.
# T162 cubre ese punto ciego: toda clave literal debe existir en es y en en.
T162() {
    new_env
    local lang key t n=0
    for lang in es en; do
        UI_LANGUAGE="$lang"
        n=0
        while IFS= read -r key; do
            t="$(ui_t "$key")"
            [[ -n "$t" && "$t" != "$key" ]] || { echo "sin traducción ($lang): $key" >&2; return 1; }
            n=$((n + 1))
        done < <(grep -oE '(ui_t |\bkey=)[a-z][a-z0-9_]*\.[A-Za-z0-9_]+' "$SCRIPT" | sed -E 's/^(ui_t |key=)//' | sort -u)
        (( n > 20 )) || return 1
    done
}

T163() {
    new_env
    local f; f="$(mktemp)"
    printf 'KILLSWITCH_MODE=auto\r\n' > "$f"
    printf 'CHECK_INTERVAL=25\n' >> "$f"
    ! config_file_is_safe "$f"
}

# --- Kill switch en una única función (killswitch on|off|auto|status) -------
# Stubs comunes: aíslan el firewall real y la comprobación de root. Cada
# llamada queda anotada en $TEST_ROOT/calls (block | allow | remove).
ks_stub_env() {
    new_env || return 1
    require_root() { :; }
    detect_known_profiles() { KNOWN_VPN=(vpn-a); }
    detect_active_state() { ACTIVE_VPN=""; VPN_IFACE=""; }
    apply_killswitch_blocking() { echo block >> "$TEST_ROOT/calls"; }
    apply_killswitch_allowing() { echo allow >> "$TEST_ROOT/calls"; }
    remove_killswitch_if_present() { echo remove >> "$TEST_ROOT/calls"; }
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    : > "$TEST_ROOT/calls"
}

T164() {
    ks_stub_env
    local err="$TEST_ROOT/err"
    ! cmd_killswitch bogus 2>"$err" || return 1
    ! cmd_killswitch '' 2>>"$err" || return 1
    grep -Fq 'killswitch on|off|auto|status' "$err" &&
    [[ ! -s "$TEST_ROOT/calls" && ! -e "$KILLSWITCH_OVERRIDE_FILE" ]]
}

T165() {
    ks_stub_env
    cmd_killswitch on >/dev/null || return 1
    [[ "$(killswitch_override_value)" == on && "$(tail -n1 "$TEST_ROOT/calls")" == block ]] || return 1
    detect_active_state() { ACTIVE_VPN=vpn-a; VPN_IFACE=tun0; }
    cmd_killswitch on >/dev/null || return 1
    [[ "$(tail -n1 "$TEST_ROOT/calls")" == allow ]]
}

T166() {
    ks_stub_env
    KILLSWITCH_MODE=true
    cmd_killswitch off >/dev/null || return 1
    [[ "$(killswitch_override_value)" == off && "$(tail -n1 "$TEST_ROOT/calls")" == remove ]] || return 1
    ! killswitch_should_be_active || return 1
    cmd_killswitch auto >/dev/null || return 1
    [[ "$(killswitch_override_value)" == auto && ! -e "$KILLSWITCH_OVERRIDE_FILE" ]] || return 1
    killswitch_should_be_active && [[ "$(tail -n1 "$TEST_ROOT/calls")" == block ]]
}

T167() {
    ks_stub_env
    set_killswitch_override off
    date > "$KS_BOOT_RACE_MARKER_FILE"
    KILLSWITCH_MODE=auto
    rm -f "$STATE_FILE"
    cmd_killswitch auto >/dev/null || return 1
    [[ "$(tail -n1 "$TEST_ROOT/calls")" == remove && ! -e "$KS_BOOT_RACE_MARKER_FILE" ]] || return 1
    mark_vpn_wanted
    cmd_killswitch auto >/dev/null || return 1
    [[ "$(tail -n1 "$TEST_ROOT/calls")" == block ]] || return 1
    KILLSWITCH_MODE=false
    cmd_killswitch auto >/dev/null || return 1
    [[ "$(tail -n1 "$TEST_ROOT/calls")" == remove ]]
}

T168() {
    ks_stub_env
    remove_killswitch_if_present() { return 1; }
    ! cmd_killswitch off >/dev/null 2>&1 || return 1
    [[ ! -e "$KILLSWITCH_OVERRIDE_FILE" ]] || return 1
    apply_killswitch_blocking() { return 1; }
    ! cmd_killswitch on >/dev/null 2>&1 || return 1
    [[ "$(killswitch_override_value)" == on ]]
}

T169() {
    new_env
    mock nmcli 'exit 0'
    mock iptables 'exit 0'
    mock ping 'exit 0'
    mock systemctl 'exit 0'
    local out="$TEST_ROOT/out" rc
    PATH="$MOCKBIN:$ORIG_PATH" bash "$SCRIPT" killswitch bogus >"$out" 2>&1; rc=$?
    [[ $rc -eq 1 ]] && grep -Fq 'killswitch on|off|auto|status' "$out" || return 1
    PATH="$MOCKBIN:$ORIG_PATH" bash "$SCRIPT" --help >"$out" 2>&1
    grep -Fq 'killswitch on|off|auto|status' "$out" &&
    grep -Fq 'alias' "$out"
}

T170() {
    new_env
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    HAVE_IP6TABLES=0
    KNOWN_VPN=()
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    UI_LANGUAGE=en; ui_init
    local out
    set_killswitch_override on
    out="$(print_killswitch_status)"
    grep -Fq 'ON (always blocks)' <<< "$out" && grep -Fq 'do not match' <<< "$out" || return 1
    set_killswitch_override off
    out="$(print_killswitch_status)"
    grep -Fq 'OFF (never blocks)' <<< "$out" && ! grep -Fq 'do not match' <<< "$out" || return 1
    clear_killswitch_override
    out="$(print_killswitch_status)"
    grep -Fq 'the configured mode applies' <<< "$out" && grep -Fq 'no blocking' <<< "$out"
}

T171() {
    new_env
    mock nmcli 'exit 0'
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock ping 'exit 1'
    HAVE_IP6TABLES=0
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    UI_LANGUAGE=en; ui_init
    set_killswitch_override off
    local out
    out="$(print_status 2>&1)"
    grep -Fq 'OFF (never blocks)' <<< "$out" &&
    grep -Fq 'Effective policy' <<< "$out" &&
    [[ "$(grep -c 'Configured mode' <<< "$out")" -eq 1 ]]
}

T172() {
    new_env
    menu_clear() { :; }
    sleep() { :; }
    menu_action() { echo "$*" >> "$TEST_ROOT/calls"; }
    menu_confirm() { return 0; }
    printf '%s\n' 1 2 3 4 9 0 | menu_killswitch_submenu >"$TEST_ROOT/out" 2>&1
    [[ "$(paste -sd, "$TEST_ROOT/calls")" == 'killswitch on,killswitch off,killswitch auto,killswitch status' ]] || return 1
    : > "$TEST_ROOT/calls"
    menu_confirm() { return 1; }
    printf '%s\n' 1 2 0 | menu_killswitch_submenu >"$TEST_ROOT/out" 2>&1
    [[ ! -s "$TEST_ROOT/calls" ]]
}

T173() {
    new_env
    local seq="$TEST_ROOT/seq"
    printf '%s\n' 1 2 3 4 0 > "$seq"
    zenity_ui() {
        if [[ "$*" == *--text-info* ]]; then cat >/dev/null; return 0; fi
        local c; c="$(head -n1 "$seq")"; sed -i 1d "$seq"
        [[ -n "$c" ]] || return 1
        printf '%s\n' "$c"
    }
    panel_confirm_box() { return 0; }
    panel_info_box() { :; }
    panel_run_privileged() { [[ "$1" == -- ]] && shift; echo "${*:2}" >> "$TEST_ROOT/calls"; }
    pkexec() { echo "pkexec ${*:2}" >> "$TEST_ROOT/calls"; echo out; }
    panel_killswitch_submenu
    [[ "$(paste -sd, "$TEST_ROOT/calls")" == 'killswitch on,killswitch off,killswitch auto,pkexec killswitch status' ]]
}

T174() {
    new_env
    # Solo la ayuda (usage.*) puede nombrar los alias; el resto de textos
    # recomienda "killswitch ..." y la config por defecto explica el control.
    ! grep -E '^[[:space:]]+(es|en):[A-Za-z0-9_.-]+\)' "$SCRIPT" | grep -v 'usage\.' | grep -Eq 'enable-killswitch|disable-killswitch' &&
    write_default_config | grep -Fq "vpn-netguard.sh killswitch auto"
}

T175() {
    new_env
    detect_known_profiles() { KNOWN_VPN=(vpn-a); }
    reconcile_sync() { return 0; }
    set_killswitch_override on
    do_activate >/dev/null || return 1
    [[ "$(killswitch_override_value)" == on ]] && want_vpn_active || return 1
    set_killswitch_override off
    do_activate >/dev/null || return 1
    [[ "$(killswitch_override_value)" == auto ]] && want_vpn_active
}

T176() {
    new_env
    menu_clear() { :; }
    sleep() { :; }
    menu_action() { echo "$*" >> "$TEST_ROOT/calls"; }
    menu_confirm() { return 0; }
    printf '%s\n' 1 2 9 0 | menu_protection_submenu >"$TEST_ROOT/out" 2>&1
    [[ "$(paste -sd, "$TEST_ROOT/calls")" == 'activate,deactivate' ]] || return 1
    : > "$TEST_ROOT/calls"
    menu_confirm() { return 1; }
    printf '%s\n' 1 2 0 | menu_protection_submenu >"$TEST_ROOT/out" 2>&1
    [[ ! -s "$TEST_ROOT/calls" ]]
}

T177() {
    new_env
    local seq="$TEST_ROOT/seq"
    printf '%s\n' 1 2 0 > "$seq"
    zenity_ui() {
        local c; c="$(head -n1 "$seq")"; sed -i 1d "$seq"
        [[ -n "$c" ]] || return 1
        printf '%s\n' "$c"
    }
    panel_confirm_box() { return 0; }
    panel_info_box() { :; }
    panel_run_privileged() { [[ "$1" == -- ]] && shift; echo "${*:2}" >> "$TEST_ROOT/calls"; }
    panel_protection_submenu
    [[ "$(paste -sd, "$TEST_ROOT/calls")" == 'activate,deactivate' ]]
}

T178() {
    new_env
    local lang key
    for lang in es en; do
        UI_LANGUAGE="$lang"
        # Las etiquetas de la protección VPN no nombran el kill switch...
        for key in menu.protection protection.title protection.menu_on protection.menu_off panel.activate; do
            ! ui_t "$key" | grep -qi 'kill switch' || return 1
        done
        # ...salvo para explicar su efecto al desactivar.
        ui_t menu.confirm_deactivate | grep -qi 'kill switch' || return 1
        ui_t panel.deactivate | grep -qi 'kill switch' || return 1
    done
}

# --- Ajustes de anonimato de red en una única entrada --------------------
T179() {
    new_env
    menu_clear() { :; }
    sleep() { :; }
    menu_configure_privacy() { echo configure >> "$TEST_ROOT/calls"; }
    menu_action() { echo "$*" >> "$TEST_ROOT/calls"; }
    confirm_apply_privacy_text() { return 0; }
    printf '%s\n' 1 2 3 9 0 | menu_privacy_submenu >"$TEST_ROOT/out" 2>&1
    [[ "$(paste -sd, "$TEST_ROOT/calls")" == 'configure,apply-privacy,privacy-status' ]] || return 1
    # Sin confirmación (p. ej. aviso de SSH rechazado) no se aplica nada.
    : > "$TEST_ROOT/calls"
    confirm_apply_privacy_text() { return 1; }
    printf '%s\n' 2 0 | menu_privacy_submenu >"$TEST_ROOT/out" 2>&1
    [[ ! -s "$TEST_ROOT/calls" ]]
}

T180() {
    new_env
    # «Ajustes de anonimato de red» abre Configurar sin submenú. Con zenity 4.0.1 (medido): Cancelar
    # sale con 1 y sin salida; el botón extra, con 1 y solo su etiqueta. El extra muestra el estado y
    # reabre el formulario; Cancelar sale. Nada se guarda ni se aplica.
    local lang label seq="$TEST_ROOT/seq" presses want opened
    zenity_ui() {
        local flat="$*"; printf '%s\n' "${flat//$'\n'/ }" >> "$TEST_ROOT/zargs"   # una apertura, una línea
        # Más de 5 aperturas es un bucle sin fin (p. ej. Cancelar tomado por «Ver estado»): falla, no se cuelga.
        (( $(wc -l < "$TEST_ROOT/zargs") > 5 )) && return 2
        local c; c="$(head -n1 "$seq")"; sed -i 1d "$seq"
        [[ -n "$c" ]] && printf '%s\n' "$c"
        return 1
    }
    panel_action_privacy_status() { echo status >> "$TEST_ROOT/calls"; }
    panel_write_config_keys() { echo write >> "$TEST_ROOT/calls"; }
    panel_run_privileged() { echo apply >> "$TEST_ROOT/calls"; }
    for lang in es en; do
        UI_LANGUAGE="$lang"; ui_init
        label="$(ui_t privacy.menu_status)"
        for presses in 0 1 2; do
            : > "$TEST_ROOT/calls"; : > "$TEST_ROOT/zargs"
            : > "$seq"; opened=$(( presses + 1 )); want=""
            local n; for (( n = 0; n < presses; n++ )); do printf '%s\n' "$label" >> "$seq"; want+="${want:+,}status"; done
            printf '\n' >> "$seq"        # y al final, Cancelar
            panel_action_configure_privacy
            [[ "$(paste -sd, "$TEST_ROOT/calls")" == "$want" ]] || return 1
            # El formulario se abre una vez más que los «Ver estado», siempre con el botón extra traducido.
            [[ "$(grep -c -- '--forms' "$TEST_ROOT/zargs")" == "$opened" ]] || return 1
            [[ "$(grep -c -- "--extra-button=$label" "$TEST_ROOT/zargs")" == "$opened" ]] || return 1
        done
    done
}

T181() {
    new_env
    local ssh empty want
    # Aplicar conserva la confirmación (reforzada si hay SSH) en terminal y panel, y sin ella no se
    # ejecuta apply-privacy. En el panel, Aceptar sin cambios llega directo a la confirmación.
    base_config
    printf -v empty '%14s' ''; empty="${empty// /|}"      # los 15 campos vacíos: nada cambia
    zenity_ui() { [[ " $* " == *" --forms "* ]] && printf '%s\n' "$empty"; return 0; }
    menu_confirm() { printf '%s\n' "$1" >> "$TEST_ROOT/asked"; return 1; }
    panel_confirm_box() { printf '%s\n' "$1" >> "$TEST_ROOT/asked"; return 1; }
    panel_run_privileged() { echo "$*" >> "$TEST_ROOT/ran"; }
    local fn
    for ssh in 0 1; do
        if (( ssh )); then is_ssh_session() { return 0; }; else is_ssh_session() { return 1; }; fi
        for fn in confirm_apply_privacy_text panel_action_configure_privacy; do
            : > "$TEST_ROOT/asked"
            "$fn" >/dev/null 2>&1
            [[ ! -e "$TEST_ROOT/ran" ]] || return 1
            if (( ssh )); then
                # Terminal: el aviso de SSH y «aplicar de todos modos»; panel: el aviso de SSH reforzado.
                if [[ "$fn" == panel_action_configure_privacy ]]; then want="$(ui_t install.ssh_warning)"; else want="$(ui_t warning.apply_anyway)"; fi
                [[ "$(<"$TEST_ROOT/asked")" == "$want" ]] && grep -Fq 'SSH' <<< "$(ui_t install.ssh_warning)" || return 1
            else
                [[ "$(<"$TEST_ROOT/asked")" == "$(ui_t menu.confirm_privacy)" ]] || return 1
            fi
        done
    done
}

# --- D4: el demonio relee la configuración cuando cambia el fichero -----
# Las llamadas van al shell actual (no en $(...)): la firma que guarda
# config_reload_if_changed no sobreviviría a una subshell.
reload_out() { config_reload_if_changed "$@" >"$TEST_ROOT/reload.out" 2>&1; }

T182() {
    new_env
    printf 'KILLSWITCH_MODE="true"\nCHECK_INTERVAL=40\n' > "$CONFIG_FILE"
    [[ "$KILLSWITCH_MODE" == auto ]] || return 1          # aún sin releer
    reload_out
    [[ "$KILLSWITCH_MODE" == true && "$CHECK_INTERVAL" == 40 ]] || return 1
    # Fichero sin cambios: no se relee (un valor tocado a mano sobrevive).
    KILLSWITCH_MODE=false
    reload_out
    [[ "$KILLSWITCH_MODE" == false ]] || return 1
    # Mismo tamaño, mismo inodo y solo otro mtime: también cuenta como cambio.
    printf 'KILLSWITCH_MODE="auto"\nCHECK_INTERVAL=40\n' > "$CONFIG_FILE"
    touch -d '2001-02-03 04:05:06' "$CONFIG_FILE"
    reload_out
    [[ "$KILLSWITCH_MODE" == auto ]] || return 1
    # La firma se toma antes de leer: una carga normal deja la firma al día.
    load_config >/dev/null 2>&1
    [[ "$CONFIG_SIG" == "$(config_signature)" ]] || return 1
    rm -f "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    [[ "$CONFIG_SIG" == missing ]]
}

T183() {
    new_env
    printf 'LANGUAGE="en"\nKILLSWITCH_MODE="true"\nALLOW_LAN="false"\n' > "$CONFIG_FILE"
    reload_out announce
    grep -Fq 'Configuration reloaded from' "$TEST_ROOT/reload.out" || return 1
    [[ "$KILLSWITCH_MODE" == true && "$ALLOW_LAN" == false ]] || return 1
    # Contenido rechazado: se mantiene la configuración en uso (no se cae a
    # los valores por defecto), se avisa una sola vez y no se ejecuta nada.
    printf 'LANGUAGE="en"\nKILLSWITCH_MODE="false"\nALERT_HOOK="$(touch %s/pwned)"\n' "$TEST_ROOT" > "$CONFIG_FILE"
    reload_out announce
    [[ "$KILLSWITCH_MODE" == true && "$ALLOW_LAN" == false ]] || return 1
    grep -Fq 'keeping the previous one' "$TEST_ROOT/reload.out" || return 1
    [[ ! -e "$TEST_ROOT/pwned" ]] || return 1
    reload_out announce
    [[ ! -s "$TEST_ROOT/reload.out" ]] || return 1
    # Fichero ausente: igual.
    rm -f "$CONFIG_FILE"
    reload_out announce
    [[ "$KILLSWITCH_MODE" == true ]] && grep -Fq 'keeping the previous one' "$TEST_ROOT/reload.out" || return 1
    # Sin "announce" (bucle de eventos) nunca se escribe nada en el log.
    printf 'KILLSWITCH_MODE="auto"\nesto no es una clave\n' > "$CONFIG_FILE"
    reload_out
    [[ ! -s "$TEST_ROOT/reload.out" && "$KILLSWITCH_MODE" == true ]] || return 1
    # Al corregir el fichero vuelve a cargarse.
    printf 'LANGUAGE="en"\nKILLSWITCH_MODE="false"\n' > "$CONFIG_FILE"
    reload_out announce
    [[ "$KILLSWITCH_MODE" == false ]] && grep -Fq 'Configuration reloaded from' "$TEST_ROOT/reload.out"
}

T184() {
    new_env
    : > "$TEST_ROOT/calls"
    (
        n=0
        reconcile_async() { echo "reconcile:$KILLSWITCH_MODE:$CHECK_INTERVAL" >> "$TEST_ROOT/calls"; }
        sleep() {
            echo "sleep:$1" >> "$TEST_ROOT/calls"
            n=$((n + 1))
            (( n == 1 )) && printf 'KILLSWITCH_MODE="true"\nCHECK_INTERVAL=7\n' > "$CONFIG_FILE"
            (( n == 3 )) && exit 0
            return 0
        }
        periodic_loop
    ) >"$TEST_ROOT/out" 2>&1
    # El cambio se aplica antes de la reconciliación y el nuevo intervalo
    # rige desde la espera siguiente.
    [[ "$(paste -sd, "$TEST_ROOT/calls")" == 'sleep:25,reconcile:true:7,sleep:7,reconcile:true:7,sleep:7' ]] || return 1
    # Solo este bucle deja constancia en el log, y una sola vez.
    [[ "$(grep -c 'Configuración recargada' "$TEST_ROOT/out")" == 1 ]]
}

T185() {
    new_env
    KS_BOOT_RACE_PENDING_FILE="$STATE_DIR/ks-pending"
    require_root() { :; }
    periodic_loop() { :; }
    reconcile_sync() { printf 'KILLSWITCH_MODE="true"\nALLOW_LAN="false"\n' > "$CONFIG_FILE"; }
    # El monitor simulado espera a que se procese el evento antes de cerrar
    # (si terminara antes, bash descartaría NMCLI_MON y "set -u" abortaría).
    nmcli_c() {
        local i
        echo evento
        for i in {1..100}; do [[ -e "$TEST_ROOT/seen" ]] && break; sleep 0.05; done
        sleep 0.2
    }
    reconcile_async() { echo "$KILLSWITCH_MODE:$ALLOW_LAN" > "$TEST_ROOT/seen"; }
    ( daemon_main ) >"$TEST_ROOT/out" 2>&1
    # Un evento de NetworkManager reconcilia ya con la configuración nueva,
    # y recargar en este bucle no escribe nada en el log.
    [[ "$(cat "$TEST_ROOT/seen" 2>/dev/null)" == 'true:false' ]] || return 1
    ! grep -Eq 'recargada|reloaded' "$TEST_ROOT/out"
}

# --- 1.5: guardar o importar configuración ya no pide reiniciar el servicio ---
T186() {
    new_env
    mkdir -p "${BIN_DST%/*}"; printf '#!/bin/sh\n' > "$BIN_DST"; chmod +x "$BIN_DST"
    menu_elevate() { echo "$*" >> "$TEST_ROOT/elev"; }
    menu_confirm() { echo ask >> "$TEST_ROOT/asked"; return 0; }
    pause_enter() { :; }
    boot_killswitch_would_block() { return 1; }
    panel_write_config_keys() { return 0; }
    local -A ch=([CHECK_INTERVAL]=30)
    menu_save_config_changes ch >"$TEST_ROOT/out" 2>&1 || return 1
    # Sin subcomando de aplicación: aviso informativo, ni pregunta ni reinicio.
    grep -Fq "$(ui_t menu.saved_auto)" "$TEST_ROOT/out" || return 1
    [[ ! -e "$TEST_ROOT/asked" && ! -e "$TEST_ROOT/elev" ]] || return 1
    # Importar desde el menú de texto: pregunta solo por la importación.
    : > "$TEST_ROOT/in.conf"
    menu_import_config <<< "$TEST_ROOT/in.conf" >"$TEST_ROOT/out" 2>&1 || return 1
    grep -Fq "$(ui_t menu.saved_auto)" "$TEST_ROOT/out" || return 1
    [[ "$(wc -l < "$TEST_ROOT/asked")" == 1 ]] || return 1
    [[ "$(cat "$TEST_ROOT/elev")" == *import-config* && "$(cat "$TEST_ROOT/elev")" != *restart* ]]
}

T187() {
    new_env
    : > "$TEST_ROOT/in.conf"
    zenity_ui() { echo "$TEST_ROOT/in.conf"; }
    panel_confirm_box() { echo ask >> "$TEST_ROOT/asked"; return 0; }
    panel_info_box() { printf '%s\n' "$1" >> "$TEST_ROOT/info"; }
    panel_run_privileged() { echo "$*" >> "$TEST_ROOT/ran"; }
    panel_action_restart_service() { echo restart >> "$TEST_ROOT/ran"; }
    panel_action_import_config
    # Importar solo confirma la importación y avisa; no reinicia el servicio.
    [[ "$(wc -l < "$TEST_ROOT/asked")" == 1 ]] || return 1
    grep -Fq "$(ui_t panel.imported_auto)" "$TEST_ROOT/info" || return 1
    [[ "$(cat "$TEST_ROOT/ran")" == *import-config* && "$(cat "$TEST_ROOT/ran")" != *restart* ]] || return 1
    # Ningún texto de interfaz ofrece ya reiniciar para aplicar la configuración.
    ! grep -Eq 'config_restart|saved_restart|imported_restart' "$SCRIPT"
}

# --- 4.1: un único modelo de menú para terminal y panel ---
T188() {
    new_env
    local kind num icon id lang iface label n=0 prev=0
    local -a text_ids=() panel_ids=() seen=()
    while IFS='|' read -r kind num icon id; do
        [[ "$kind" == E ]] || continue
        (( num == ++prev )) || return 1                    # numeración secuencial
        [[ " ${text_ids[*]} " != *" $id "* ]] || return 1  # ids únicos
        text_ids+=("$id")
    done < <(menu_rows text)
    while IFS='|' read -r kind num icon id; do
        [[ "$kind" == E ]] && panel_ids+=("$id")
    done < <(menu_rows panel)
    (( ${#text_ids[@]} == 15 && ${#panel_ids[@]} == 14 )) || return 1
    # Los números del panel son un prefijo exacto de los del terminal.
    for n in "${!panel_ids[@]}"; do [[ "${panel_ids[n]}" == "${text_ids[n]}" ]] || return 1; done
    # «interface» (9.6 b) lleva el 14 en ambas interfaces; Instalar, el 15 y solo en la terminal.
    [[ "$(menu_id_of_number panel 13)" == uninstall && "$(menu_id_of_number text 13)" == uninstall ]] || return 1
    [[ "$(menu_id_of_number panel 14)" == interface && "$(menu_id_of_number text 14)" == interface ]] || return 1
    [[ "$(menu_id_of_number text 15)" == install ]] || return 1
    ! menu_id_of_number panel 15 >/dev/null && ! menu_id_of_number text 16 >/dev/null || return 1
    # Todas las etiquetas y categorías están traducidas en es y en.
    for lang in es en; do
        UI_LANGUAGE="$lang"
        for iface in text panel; do
            while IFS='|' read -r kind num icon id; do
                if [[ "$kind" == H ]]; then
                    [[ "$(ui_t "$id")" != "$id" ]] || return 1
                else
                    label="$(menu_label "$id" "$iface")"
                    [[ -n "$label" && ! "$label" =~ ^[a-z_]+\.[A-Za-z0-9_]+$ ]] || return 1
                fi
            done < <(menu_rows "$iface")
        done
    done
}

T189() {
    new_env
    local fn id kind num icon
    local -A want_text=([status]='menu_action status' [one_click]=menu_action_one_click
        [protection]=menu_protection_submenu [killswitch]=menu_killswitch_submenu
        [language]=menu_configure_language [config]=menu_configure_general
        [privacy]=menu_privacy_submenu [monitoring]=menu_configure_monitoring
        [service]=menu_service_submenu [backup]=menu_backup_submenu [logs]=menu_logs
        [doctor]='menu_action doctor' [uninstall]=menu_do_uninstall
        [interface]=menu_open_gui_panel [install]=menu_do_install)
    local -A want_panel=([status]=panel_action_status [one_click]=panel_action_one_click
        [protection]=panel_protection_submenu [killswitch]=panel_killswitch_submenu
        [language]=panel_action_change_language [config]=panel_action_configure
        [privacy]=panel_action_configure_privacy [monitoring]=panel_action_configure_monitoring
        [service]=panel_service_submenu [backup]=panel_backup_submenu
        [logs]=panel_action_logs [doctor]=panel_action_doctor [uninstall]=uninstall
        [interface]=panel_back_to_terminal)
    for id in "${!want_text[@]}"; do
        fn="${want_text[$id]%% *}"; eval "$fn() { echo \"$fn\${*:+ \$*}\" >> \"\$TEST_ROOT/calls\"; }"
    done
    for id in "${!want_panel[@]}"; do
        fn="${want_panel[$id]}"; [[ "$id" == uninstall ]] && continue
        eval "$fn() { echo \"$fn\${*:+ \$*}\" >> \"\$TEST_ROOT/calls\"; }"
    done
    panel_confirm_box() { return 0; }
    panel_info_box() { :; }
    panel_run_privileged() { echo "uninstall" >> "$TEST_ROOT/calls"; }
    # Cada id del modelo llega a su manejador (y solo a ese) en su interfaz.
    while IFS='|' read -r kind num icon id; do
        [[ "$kind" == E ]] || continue
        : > "$TEST_ROOT/calls"; menu_run_text "$id"
        [[ "$(cat "$TEST_ROOT/calls")" == "${want_text[$id]:-?}" ]] || return 1
    done < <(menu_rows text)
    while IFS='|' read -r kind num icon id; do
        [[ "$kind" == E ]] || continue
        : > "$TEST_ROOT/calls"; menu_run_panel "$id"
        [[ "$(cat "$TEST_ROOT/calls")" == "${want_panel[$id]:-?}" ]] || return 1
    done < <(menu_rows panel)
    # Menú de texto: el número elegido despacha su entrada; lo demás es inválido.
    menu_clear() { :; }; sleep() { :; }; menu_show_header() { :; }
    menu_run_text() { echo "$1" >> "$TEST_ROOT/picked"; }
    printf '%s\n' 13 14 15 99 x 0 | cmd_menu >"$TEST_ROOT/out" 2>&1
    [[ "$(paste -sd, "$TEST_ROOT/picked")" == 'uninstall,interface,install' ]] || return 1
    # Panel: la cabecera "H" no hace nada, el número elegido despacha y Cancelar (sin salida) sale.
    local seq="$TEST_ROOT/seq"; printf '%s\n' H 13 14 > "$seq"
    zenity_ui() {
        printf '%s\n' "$*" > "$TEST_ROOT/zargs"
        local c; c="$(head -n1 "$seq")"; sed -i 1d "$seq"
        [[ -n "$c" ]] || return 1
        printf '%s\n' "$c"
    }
    menu_run_panel() { echo "$1" >> "$TEST_ROOT/ppicked"; }
    panel_main_menu
    [[ "$(paste -sd, "$TEST_ROOT/ppicked")" == 'uninstall,interface' ]] || return 1
    grep -Fq -- " 14 " "$TEST_ROOT/zargs" && ! grep -Fq -- " 15 " "$TEST_ROOT/zargs" || return 1
    # D2: el aviso "no instalado" cita el número real de Instalar.
    BIN_DST="$TEST_ROOT/no-such/vpn-netguard.sh"
    unset -f menu_show_header; source <(sed -n '/^menu_show_header() {/,/^}/p' "$SCRIPT")
    local header; header="$(menu_show_header 2>&1)"
    [[ "$header" == *"$(menu_number_of install)"* ]]
}

# --- 4.2: panel con columnas, cabecera de estado y botones Abrir/Salir ---
T190() {
    new_env
    local -a items
    cat > "$MOCKBIN/nmcli" <<'EOF'
#!/usr/bin/env bash
cat "$TEST_ROOT/nm.out"
EOF
    chmod +x "$MOCKBIN/nmcli"; hash -r
    printf '%s\n' 'Casa:802-3-ethernet:eth0' 'Pro\:ton & <x>:vpn:tun0' > "$TEST_ROOT/nm.out"
    # Todo en marcha: servicio activo, protección deseada, VPN activa, kill switch en auto.
    mock systemctl 'exit 0'
    printf 'on\n' > "$STATE_FILE"; KILLSWITCH_MODE=auto
    mapfile -t items < <(menu_status_items)
    [[ "${items[0]}" == "ok|$(ui_t menu.st_service)|$(ui_t menu.st_active)" &&
       "${items[1]}" == "ok|$(ui_t menu.st_protection)|$(ui_t menu.st_enabled)" &&
       "${items[2]}" == "ok|$(ui_t menu.st_vpn)|Pro:ton & <x>" &&
       "${items[3]}" == "ok|$(ui_t menu.st_killswitch)|$(printf -- "$(ui_t menu.st_ks_auto)" auto)" ]] || return 1
    # Servicio parado y sin VPN: con protección deseada avisa; sin ella queda en gris.
    mock systemctl 'exit 3'
    printf '%s\n' 'Casa:802-3-ethernet:eth0' > "$TEST_ROOT/nm.out"
    mapfile -t items < <(menu_status_items)
    [[ "${items[0]}" == "warn|$(ui_t menu.st_service)|$(ui_t menu.st_inactive)" &&
       "${items[2]}" == "warn|$(ui_t menu.st_vpn)|$(ui_t menu.st_vpn_waiting)" ]] || return 1
    printf 'off\n' > "$STATE_FILE"
    mapfile -t items < <(menu_status_items)
    [[ "${items[1]}" == "off|$(ui_t menu.st_protection)|$(ui_t menu.st_disabled)" &&
       "${items[2]}" == "off|$(ui_t menu.st_vpn)|$(ui_t menu.st_vpn_none)" ]] || return 1
    # Kill switch: el forzado manda sobre el modo; "false" en auto también avisa.
    printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    [[ "$(menu_status_items | tail -n1)" == "ok|$(ui_t menu.st_killswitch)|$(ui_t menu.st_ks_on)" ]] || return 1
    printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"
    [[ "$(menu_status_items | tail -n1)" == "warn|$(ui_t menu.st_killswitch)|$(ui_t menu.st_ks_off)" ]] || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; KILLSWITCH_MODE=false
    [[ "$(menu_status_items | tail -n1)" == warn\|* ]]
}

T191() {
    new_env
    local id kind num icon label
    mock systemctl 'exit 0'
    cat > "$MOCKBIN/nmcli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Pro\:ton & <x>:vpn:tun0'
EOF
    chmod +x "$MOCKBIN/nmcli"; hash -r
    printf 'on\n' > "$STATE_FILE"
    zenity_ui() { printf '%s\n' "$@" > "$TEST_ROOT/zargs"; return 1; }   # cancelar = Salir
    panel_main_menu
    local z="$TEST_ROOT/zargs"
    # Botones, cabeceras de columna y tamaño; sin fila "0" ni cabecera oculta.
    grep -Fxq -- "--ok-label=$(ui_t panel.btn_open)" "$z" &&
    grep -Fxq -- "--cancel-label=$(ui_t menu.exit0)" "$z" &&
    grep -Fxq -- "--column=$(ui_t panel.col_num)" "$z" &&
    grep -Fxq -- "--column=$(ui_t panel.col_action)" "$z" &&
    grep -Fxq -- "--column=$(ui_t panel.col_desc)" "$z" &&
    ! grep -Fxq -- '--hide-header' "$z" && ! grep -Fxq 0 "$z" || return 1
    local h; h="$(sed -n 's/^--height=//p' "$z")"
    [[ "$h" =~ ^[0-9]+$ ]] && (( h >= 400 && h <= 700 )) || return 1
    # Cabecera Pango: negrita y datos dinámicos escapados (nunca &, < ni > crudos).
    local t; t="$(sed -n '/^--text=/,/^--ok-label=/p' "$z")"
    [[ "$t" == *'<b>'* && "$t" == *'Pro:ton &amp; &lt;x&gt;'* && "$t" != *'& <x>'* ]] || return 1
    # Cada entrada del panel: fila Nº | Nº | Acción | Descripción; las categorías, con ID "H".
    while IFS='|' read -r kind num icon id; do
        if [[ "$kind" == H ]]; then
            grep -Fxq "$(ui_t "$id")" "$z" || return 1
        else
            label="$icon $(menu_label "$id" panel)"
            grep -Fxq "$label" "$z" && grep -Fxq "$(menu_desc "$id")" "$z" || return 1
        fi
    done < <(menu_rows panel)
    [[ "$(grep -cFx H "$z")" == 3 ]]
}

T192() {
    new_env
    local lang id key
    # También con patsub_replacement activo (bash 5.2+), y sin dejarlo cambiado.
    local before after
    shopt -s patsub_replacement 2>/dev/null; shopt -q patsub_replacement 2>/dev/null; before=$?
    [[ "$(pango_escape 'a&b<c>d')" == 'a&amp;b&lt;c&gt;d' ]] || return 1
    pango_escape x >/dev/null; shopt -q patsub_replacement 2>/dev/null; after=$?
    [[ "$before" == "$after" ]] || return 1
    ! menu_desc install >/dev/null || return 1
    for lang in es en; do
        UI_LANGUAGE="$lang"
        while IFS='|' read -r kind num icon id; do
            [[ "$kind" == E ]] || continue
            [[ "$id" == install ]] && continue
            [[ -n "$(menu_desc "$id")" && "$(menu_desc "$id")" != menu.desc_* ]] || return 1
        done < <(menu_rows text)
        for key in panel.col_num panel.col_action panel.col_desc panel.btn_open menu.st_service \
                   menu.st_protection menu.st_vpn menu.st_killswitch menu.st_active menu.st_inactive \
                   menu.st_enabled menu.st_disabled menu.st_vpn_none menu.st_vpn_waiting menu.st_ks_on \
                   menu.st_ks_off menu.st_ks_auto; do
            [[ -n "$(ui_t "$key")" && "$(ui_t "$key")" != "$key" ]] || return 1
        done
    done
}

# --- Revisión de 4.2: el panel (sin root) debe poder leer el estado que muestra ---
T193() {
    new_env
    local f
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    umask 0077   # como el demonio (UMask=0027) o un usuario con umask estricta
    mark_vpn_wanted; unmark_vpn_wanted; set_killswitch_override off
    for f in "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE"; do
        [[ "$(stat -c %a "$f")" == 644 ]] || return 1
    done
    # Ficheros ya creados en 0640 por una versión anterior: se corrigen sin reescribirlos.
    chmod 0640 "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE"
    state_files_make_readable
    for f in "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE"; do
        [[ "$(stat -c %a "$f")" == 644 ]] || return 1
    done
    # Un fichero ausente no se crea (ausente significa "auto").
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; state_files_make_readable
    [[ ! -e "$KILLSWITCH_OVERRIDE_FILE" ]] || return 1
    # El demonio lo aplica al arrancar, antes de su primer mensaje de registro.
    sed -n '/^daemon_main() {/,/^}/p' "$SCRIPT" |
        awk '/state_files_make_readable/ {a = NR} /log_t info log.daemon_start/ {b = NR} END {exit !(a && b && a < b)}'
}

# --- 4.3: el terminal usa la misma línea de estado que el panel ---
T194() {
    new_env
    local lang loc header line glyph prefix item level label value
    local -a items
    mkdir -p "${BIN_DST%/*}"; printf '#!/bin/sh\n' > "$BIN_DST"; chmod +x "$BIN_DST"
    mock systemctl 'exit 0'
    cat > "$MOCKBIN/nmcli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Pro\:ton:vpn:tun0'
EOF
    chmod +x "$MOCKBIN/nmcli"; hash -r
    printf 'on\n' > "$STATE_FILE"; KILLSWITCH_MODE=auto
    menu_color_enabled() { return 1; }
    # Sin color y en locale de bytes (C) o UTF-8: cada dato de menu_status_items sale
    # con su símbolo, sin secuencias ANSI y con todos los ":" en la misma columna.
    for loc in C C.UTF-8; do
        LC_ALL="$loc"
        [[ "$(ui_text_len 'Protección VPN')" == 14 && "$(ui_text_len abc)" == 3 ]] || return 1
        for lang in es en; do
            UI_LANGUAGE="$lang"
            header="$(menu_show_header)"
            [[ "$header" != *$'\e'* ]] || return 1
            mapfile -t items < <(menu_status_items)
            (( ${#items[@]} == 4 )) || return 1
            for item in "${items[@]}"; do
                IFS='|' read -r level label value <<< "$item"
                case "$level" in ok) glyph='●' ;; warn) glyph='▲' ;; *) glyph='○' ;; esac
                line="$(grep -F -- " $glyph $label" <<< "$header")" || return 1
                [[ "$line" == *": $value" ]] || return 1
            done
            [[ "$(sed -n '4,9p' <<< "$header" | wc -l)" == 6 ]] || return 1
            while IFS= read -r line; do
                prefix="${line%%:*}"
                [[ "$(ui_text_len "$prefix")" == 20 ]] || return 1
            done < <(sed -n '4,9p' <<< "$header")
        done
    done
    # Con color: verde ● ok, ámbar ▲ aviso, gris ○ apagado, y se restablece.
    menu_color_enabled() { return 0; }
    header="$(menu_show_header)"
    [[ "$header" == *$'\e[32m●'* && "$header" == *$'\e[0m'* ]] || return 1
    mock systemctl 'exit 3'; printf 'off\n' > "$STATE_FILE"
    header="$(menu_show_header)"
    [[ "$header" == *$'\e[33m▲'* && "$header" == *$'\e[90m○'* ]] || return 1
    # Solo hay color en un terminal y sin NO_COLOR.
    unset -f menu_color_enabled; source <(sed -n '/^menu_color_enabled() {/,/^}/p' "$SCRIPT")
    menu_stdout_is_tty() { return 0; }
    NO_COLOR=1; ! menu_color_enabled || return 1
    unset NO_COLOR; menu_color_enabled || return 1
    menu_stdout_is_tty() { return 1; }; ! menu_color_enabled || return 1
    # Sin instalar no hay estado que mostrar, solo el aviso con el número de Instalar.
    rm -f "$BIN_DST"
    header="$(menu_show_header)"
    [[ "$header" != *●* && "$header" != *▲* && "$header" != *○* && "$header" == *"$(menu_number_of install)"* ]]
}

# --- 5.1: las excepciones del kill switch salen con RETURN, nunca con ACCEPT ---
T196() {
    new_env
    local f chain
    HAVE_IP6TABLES=1; KS_VPN_CANDIDATES=(); ALLOW_LAN=true
    DNS_SERVERS='1.1.1.1 2001:4860:4860::8888'
    PING_TARGETS='1.2.3.4 2001:4860:4860::8888'
    VPN_ENDPOINT_OVERRIDE='198.51.100.10:1194:udp'
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock iptables-restore 'cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6"; exit 0'
    apply_killswitch_rules tun0 >/dev/null && apply_killswitch_rules6 tun0 >/dev/null || return 1
    for f in restore4:NETGUARD_KS restore6:NETGUARD_KS6; do
        chain="${f#*:}"; f="$TEST_ROOT/${f%%:*}"
        # Sin ACCEPT en ninguna línea; todas las reglas salvo la última son RETURN y
        # la última es el DROP final (fail-closed).
        ! grep -q ACCEPT "$f" || return 1
        [[ "$(grep -c "^-A $chain " "$f")" -gt 5 ]] || return 1
        [[ "$(grep "^-A $chain " "$f" | tail -n1)" == "-A $chain -j DROP" ]] || return 1
        [[ -z "$(grep "^-A $chain " "$f" | sed '$d' | grep -v -- ' -j RETURN$')" ]] || return 1
        # Las excepciones que importan siguen ahí: loopback, conexiones establecidas y túnel.
        grep -Fxq -- "-A $chain -o lo -j RETURN" "$f" &&
        grep -Fxq -- "-A $chain -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" "$f" &&
        grep -Fxq -- "-A $chain -o tun0 -j RETURN" "$f" || return 1
    done
    # Cada familia lleva su LAN y su endpoint con el mismo criterio.
    grep -Fxq -- '-A NETGUARD_KS -d 192.168.0.0/16 -j RETURN' "$TEST_ROOT/restore4" &&
    grep -Fxq -- '-A NETGUARD_KS -d 198.51.100.10 -p udp --dport 1194 -j RETURN' "$TEST_ROOT/restore4" &&
    grep -Fxq -- '-A NETGUARD_KS6 -d fc00::/7 -j RETURN' "$TEST_ROOT/restore6"
}

T197() {
    new_env; fw_model_install
    CHAIN_NAME=TEST; export FW_CHAIN=TEST
    # Ya primero y único: ensure_chain no escribe nada, ni repetido.
    fw_set 4 '-j TEST' '-o eth9 -j DROP'
    ensure_chain && ensure_chain || return 1
    [[ "$(fw_dump 4)" == '-j TEST|-o eth9 -j DROP' && -z "$(fw_writes 4)" ]] || return 1
    fw_set 4 '-j TEST'
    ensure_chain || return 1
    [[ "$(fw_dump 4)" == '-j TEST' && -z "$(fw_writes 4)" ]]
}

T198() {
    new_env; fw_model_install
    CHAIN_NAME=TEST; export FW_CHAIN=TEST
    # Ausente: un único -I en la posición 1; las reglas ajenas conservan su orden.
    fw_set 4 '-o eth9 -j DROP' '-p tcp --dport 9 -j DROP'
    ensure_chain || return 1
    [[ "$(fw_dump 4)" == '-j TEST|-o eth9 -j DROP|-p tcp --dport 9 -j DROP' ]] &&
    [[ "$(fw_writes 4)" == 'I 1 -j TEST jumps=1' ]] || return 1
    fw_set 4
    ensure_chain || return 1
    [[ "$(fw_dump 4)" == '-j TEST' && "$(fw_writes 4)" == 'I 1 -j TEST jumps=1' ]]
}

T199() {
    new_env; fw_model_install
    CHAIN_NAME=TEST; export FW_CHAIN=TEST
    local log
    # Sin transacción (revertida): inserta primero, borra después; nunca 0 saltos.
    fw_set 4 '-o eth9 -j DROP' '-j TEST' '-p tcp --dport 9 -j DROP' '-j TEST'
    : > "$TEST_ROOT/fw4.deny-restore"
    ensure_chain || return 1
    log="$(fw_writes 4)"
    [[ "$(fw_dump 4)" == '-j TEST|-o eth9 -j DROP|-p tcp --dport 9 -j DROP' ]] || return 1
    [[ "$(sed -n 2p <<< "$log")" == 'I 1 -j TEST jumps=3' ]] || return 1
    [[ "$log" != *'jumps=0'* && "$log" != *$'\nD -j '* ]] || return 1
    # Primero y repetido más abajo: no se inserta, solo se borra el repetido.
    fw_set 4 '-j TEST' '-o eth9 -j DROP' '-j TEST'
    : > "$TEST_ROOT/fw4.deny-restore"
    ensure_chain || return 1
    [[ "$(fw_dump 4)" == '-j TEST|-o eth9 -j DROP' && "$(fw_writes 4)" != *$'\nI '* ]] || return 1
    # Otro cortafuegos inserta justo después del primer -I: las posiciones se
    # desplazan y NO se borra ninguna regla ajena (el salto repetido queda para la
    # siguiente reconciliación).
    fw_set 4 '-o eth9 -j DROP' '-j TEST' '-p tcp --dport 9 -j DROP' '-j TEST'
    : > "$TEST_ROOT/fw4.deny-restore"; : > "$TEST_ROOT/fw4.race-after-I"
    ensure_chain || return 1
    [[ "$(fw_dump 4)" == *'-o eth9 -j DROP'* && "$(fw_dump 4)" == *'-p tcp --dport 9 -j DROP'* &&
       "$(fw_dump 4)" == *'-s 203.0.113.9 -j DROP'* && "$(fw_dump 4)" == *'-j TEST'* ]]
}

T200() {
    new_env; fw_model_install
    CHAIN_NAME_V6=TEST6; export FW_CHAIN=TEST6
    # Sin ip6tables no se toca nada.
    HAVE_IP6TABLES=0
    ensure_chain6 && [[ ! -e "$TEST_ROOT/fw6.rules" ]] || return 1
    # IPv6 usa ip6tables(-restore), nunca los de IPv4.
    HAVE_IP6TABLES=1
    fw_set 4 '-o eth9 -j DROP'; fw_set 6 '-o eth9 -j DROP' '-j TEST6' '-j TEST6'
    ensure_chain6 || return 1
    [[ "$(fw_dump 6)" == '-j TEST6|-o eth9 -j DROP' && "$(fw_writes 6)" == 'R jumps=1' ]] || return 1
    [[ "$(fw_dump 4)" == '-o eth9 -j DROP' && -z "$(fw_writes 4)" ]] || return 1
    # OUTPUT ilegible: con el salto presente no se escribe; ausente se inserta.
    fw_set 6 '-o eth9 -j DROP' '-j TEST6'
    : > "$TEST_ROOT/fw6.deny-S"
    ensure_chain6 || return 1
    [[ "$(fw_dump 6)" == '-o eth9 -j DROP|-j TEST6' && -z "$(fw_writes 6)" ]] || return 1
    fw_set 6 '-o eth9 -j DROP'
    : > "$TEST_ROOT/fw6.deny-S"
    ensure_chain6 || return 1
    [[ "$(fw_dump 6)" == '-j TEST6|-o eth9 -j DROP' && "$(fw_writes 6)" == 'I 1 -j TEST6 jumps=1' ]]
}

T201() {
    new_env
    local d="$TEST_ROOT/sysnet" i
    for i in eth0:up lo:unknown nordlynx:unknown proton0:unknown tap1:down tun0:unknown tun7:unknown wg0:unknown ppp0:lowerlayerdown utun:unknown; do
        mkdir -p "$d/${i%%:*}"; printf '%s\n' "${i#*:}" > "$d/${i%%:*}/operstate"
    done
    SYS_NET_DIR="$d"; VPN_IFACE=tun7
    foreign_vpn_scan
    # Solo túneles activos y no gestionados por NM; nordlynx implica la marca de NordVPN.
    [[ "${FOREIGN_TUNNELS[*]}" == 'nordlynx proton0 tun0 wg0' && "${FOREIGN_MARKS[*]}" == 0xe1f1 &&
       ${#FOREIGN_KS[@]} -eq 0 ]] || return 1
    # Cada llamada parte de cero y, sin VPN de NM, tun7 también cuenta.
    VPN_IFACE=""; rm -rf "$d/nordlynx"
    foreign_vpn_scan
    [[ "${FOREIGN_TUNNELS[*]}" == 'proton0 tun0 tun7 wg0' && ${#FOREIGN_MARKS[@]} -eq 0 ]] || return 1
    SYS_NET_DIR="$TEST_ROOT/nada"
    foreign_vpn_scan 2>&1
    [[ ${#FOREIGN_TUNNELS[@]} -eq 0 ]]
}

T202() {
    new_env; fw_model_install
    SYS_NET_DIR="$TEST_ROOT/nada"; HAVE_IP6TABLES=0
    # Kill switch de NordVPN: reglas con su comentario y un DROP.
    fw_set 4 '-o lo -m comment --comment nordvpn -j ACCEPT' \
        '-m mark --mark 0xe1f1 -m comment --comment nordvpn -j ACCEPT' \
        '-o eth0 -m comment --comment nordvpn -j DROP'
    foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == nordvpn && "${FOREIGN_MARKS[*]}" == 0xe1f1 ]] || return 1
    fw_set 4 '-o eth0 -m comment --comment "nordvpn" -j REJECT --reject-with icmp-port-unreachable'
    foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == nordvpn ]] || return 1
    # Reglas de NordVPN sin DROP: hay cliente (marca) pero no kill switch.
    fw_set 4 '-o lo -m comment --comment nordvpn -j ACCEPT'
    foreign_vpn_scan
    [[ ${#FOREIGN_KS[@]} -eq 0 && "${FOREIGN_MARKS[*]}" == 0xe1f1 ]] || return 1
    # Ni NetGuard, ni ufw, ni un comentario parecido cuentan.
    fw_set 4 '-j NETGUARD_KS' '-j ufw-before-output' '-o eth0 -m comment --comment nordvpn-fake -j DROP' '-o eth9 -j DROP'
    foreign_vpn_scan
    [[ ${#FOREIGN_KS[@]} -eq 0 && ${#FOREIGN_MARKS[@]} -eq 0 ]] || return 1
    # El comando nordvpn instalado basta para dejar pasar su marca.
    mock nordvpn 'exit 0'
    foreign_vpn_scan
    [[ ${#FOREIGN_KS[@]} -eq 0 && "${FOREIGN_MARKS[*]}" == 0xe1f1 ]] || return 1
    rm -f "$MOCKBIN/nordvpn"; hash -r
    # Solo en IPv6, y solo si hay ip6tables.
    fw_set 4; fw_set 6 '-o eth0 -m comment --comment nordvpn -j DROP'
    HAVE_IP6TABLES=1; foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == nordvpn ]] || return 1
    HAVE_IP6TABLES=0; foreign_vpn_scan
    [[ ${#FOREIGN_KS[@]} -eq 0 ]] || return 1
    # OUTPUT ilegible (sin root): sin resultado y sin ruido.
    : > "$TEST_ROOT/fw4.deny-S"
    [[ -z "$(foreign_vpn_scan 2>&1)" ]]
}

T203() {
    new_env; fw_model_install
    local d="$TEST_ROOT/sysnet"; mkdir -p "$d/eth0"
    SYS_NET_DIR="$d"; HAVE_IP6TABLES=0
    mock nmcli 'case "$*" in *"connection show --active"*) printf "Wired connection 1\n";; esac; exit 0'
    foreign_vpn_scan
    [[ ${#FOREIGN_KS[@]} -eq 0 ]] || return 1
    mock nmcli 'case "$*" in *"connection show --active"*) printf "Wired connection 1\npvpn-killswitch\n";; esac; exit 0'
    foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == protonvpn ]] || return 1
    mock nmcli 'case "$*" in *"connection show --active"*) printf "pvpn-ipv6leak-protection\n";; esac; exit 0'
    foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == protonvpn ]] || return 1
    # Sin NM, la interfaz dummy basta y no es un túnel.
    mock nmcli 'exit 1'; mkdir -p "$d/pvpnksintrf0"
    foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == protonvpn && ${#FOREIGN_TUNNELS[@]} -eq 0 ]] || return 1
    # Ambos a la vez: orden fijo y sin duplicados aunque NM y la interfaz coincidan.
    mock nmcli 'case "$*" in *"connection show --active"*) printf "pvpn-killswitch\n";; esac; exit 0'
    fw_set 4 '-o eth0 -m comment --comment nordvpn -j DROP'
    foreign_vpn_scan
    [[ "${FOREIGN_KS[*]}" == 'nordvpn protonvpn' ]]
}

T204() {
    new_env
    local d="$TEST_ROOT/sysnet"; mkdir -p "$d/tun0"; echo unknown > "$d/tun0/operstate"
    SYS_NET_DIR="$d"; HAVE_IP6TABLES=1
    mock iptables 'printf "iptables %s\n" "$*" >> "$TEST_ROOT/calls"; exit 0'
    mock ip6tables 'printf "ip6tables %s\n" "$*" >> "$TEST_ROOT/calls"; exit 0'
    mock nmcli 'printf "nmcli %s\n" "$*" >> "$TEST_ROOT/calls"; exit 0'
    foreign_vpn_scan
    # Solo lectura: listar OUTPUT en las dos familias y las conexiones activas.
    [[ "$(wc -l < "$TEST_ROOT/calls")" -eq 3 ]] &&
    [[ -z "$(grep -v -e '^iptables -w 5 -S OUTPUT$' -e '^ip6tables -w 5 -S OUTPUT$' \
        -e '^nmcli -t -f NAME connection show --active$' "$TEST_ROOT/calls")" ]]
}

T205() {
    new_env
    local err="$TEST_ROOT/err" v ui
    # Por defecto auto; la clave está permitida y documentada en la config por defecto.
    [[ "$COEXIST_MODE" == auto ]] && config_key_allowed COEXIST_MODE &&
    [[ "$(write_default_config | grep -c '^COEXIST_MODE="auto"$')" -eq 1 ]] || return 1
    # Valores válidos: se conservan y no avisan.
    for v in strict auto; do
        printf 'COEXIST_MODE="%s"\n' "$v" >> "$CONFIG_FILE"
        load_config 2>"$err" || return 1
        [[ "$COEXIST_MODE" == "$v" && ! -s "$err" ]] || return 1
    done
    # Valor inválido: avisa nombrando la clave, en los dos idiomas, y vuelve a auto.
    for ui in es en; do
        printf 'LANGUAGE="%s"\nCOEXIST_MODE="paranoid"\n' "$ui" >> "$CONFIG_FILE"
        load_config 2>"$err" || return 1
        [[ "$COEXIST_MODE" == auto ]] && grep -q 'COEXIST_MODE.*paranoid' "$err" || return 1
    done
    # Los dos menús de configuración la ofrecen con las dos opciones y etiqueta en es y en.
    [[ "$(menu_field_spec COEXIST_MODE)" == enum:auto,strict ]] || return 1
    for ui in es en; do
        UI_LANGUAGE="$ui"
        [[ -n "$(ui_field_label COEXIST_MODE)" ]] || return 1
    done
    # Menú de terminal: menu_configure_general entrega la clave a menu_configure_keys.
    menu_configure_keys() { printf '%s\n' "$@" > "$TEST_ROOT/keys"; }
    menu_configure_general || return 1
    grep -Fxq COEXIST_MODE "$TEST_ROOT/keys" || return 1
    # Panel gráfico (sin zenity aquí): la clave está en su lista y su combo ofrece auto y strict.
    grep -Eq 'local -a keys=\(.* COEXIST_MODE ' "$SCRIPT" &&
    grep -Eq '^ +COEXIST_MODE\) forms\+=\(.*panel_order_combo "\$val" auto strict' "$SCRIPT"
}

# --- 5.4 (b): túneles y marcas ajenos pasan con RETURN solo en COEXIST_MODE=auto ---
T206() {
    new_env
    local f chain out
    HAVE_IP6TABLES=1; KS_VPN_CANDIDATES=(); ALLOW_LAN=true; DNS_SERVERS=''
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock iptables-restore 'cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6"; exit 0'
    # Entradas inválidas (inyección en el texto de *-restore, nombres largos, marcas mal
    # formadas) se descartan; las válidas salen en orden, túneles primero.
    FOREIGN_TUNNELS=('eth0 -j ACCEPT' 'a;b' '' '-j' 'abcdefghijklmnop' '$(x)' 'nordlynx' 'ok-1.x' 'tun0')
    FOREIGN_MARKS=('0x' '0xzz' '1234' '0xe1f1 -j ACCEPT' '0x123456789' '0xe1f1' '0xAbC')
    out="$(coexist_pass_rules)"
    [[ "$out" == "$(printf '%s\n' '-o nordlynx -j RETURN' '-o ok-1.x -j RETURN' '-o tun0 -j RETURN' \
        '-m mark --mark 0xe1f1 -j RETURN' '-m mark --mark 0xAbC -j RETURN')" ]] || return 1
    # Auto: las dos familias las llevan junto a la del túnel propio, sin ACCEPT y con el DROP último.
    FOREIGN_TUNNELS=(nordlynx); FOREIGN_MARKS=(0xe1f1)
    apply_killswitch_rules tun9 >/dev/null && apply_killswitch_rules6 tun9 >/dev/null || return 1
    for f in restore4:NETGUARD_KS restore6:NETGUARD_KS6; do
        chain="${f#*:}"; f="$TEST_ROOT/${f%%:*}"
        ! grep -q ACCEPT "$f" || return 1
        [[ "$(grep "^-A $chain " "$f" | tail -n1)" == "-A $chain -j DROP" ]] || return 1
        [[ -z "$(grep "^-A $chain " "$f" | sed '$d' | grep -v -- ' -j RETURN$')" ]] || return 1
        grep -Fxq -- "-A $chain -o nordlynx -j RETURN" "$f" &&
        grep -Fxq -- "-A $chain -m mark --mark 0xe1f1 -j RETURN" "$f" &&
        grep -Fxq -- "-A $chain -o tun9 -j RETURN" "$f" || return 1
    done
    # Strict: aunque FOREIGN_* tenga datos, no se exceptúa nada ajeno; el resto de reglas sigue.
    COEXIST_MODE=strict
    [[ -z "$(coexist_pass_rules)" ]] || return 1
    rm -f "$TEST_ROOT"/restore4 "$TEST_ROOT"/restore6
    apply_killswitch_rules tun9 >/dev/null && apply_killswitch_rules6 tun9 >/dev/null || return 1
    for f in restore4:NETGUARD_KS restore6:NETGUARD_KS6; do
        chain="${f#*:}"; f="$TEST_ROOT/${f%%:*}"
        ! grep -q -e nordlynx -e 'mark' "$f" || return 1
        grep -Fxq -- "-A $chain -o tun9 -j RETURN" "$f" &&
        [[ "$(grep "^-A $chain " "$f" | tail -n1)" == "-A $chain -j DROP" ]] || return 1
    done
    # Sin túneles ni marcas no hay reglas ajenas y no falla con arrays vacíos.
    COEXIST_MODE=auto; FOREIGN_TUNNELS=(); FOREIGN_MARKS=()
    [[ -z "$(coexist_pass_rules)" ]]
}

# --- 5.4 (b): el escaneo ocurre antes de decidir y de aplicar reglas ---
T207() {
    new_env
    local log="$TEST_ROOT/order" scans phys=0
    detect_known_profiles() { :; }
    detect_active_state() { echo detect >> "$log"; ACTIVE_VPN=""; PHYS_IFACE=eth0; ((phys++ == 0 && ${NO_PHYS:-0})) && PHYS_IFACE=""; return 0; }
    try_reconnect_physical() { echo physical >> "$log"; }
    foreign_vpn_scan() { echo scan >> "$log"; FOREIGN_TUNNELS=(nordlynx); FOREIGN_MARKS=(0xe1f1); FOREIGN_KS=(nordvpn); }
    killswitch_should_be_active() { echo "decide:${FOREIGN_TUNNELS[*]:-}" >> "$log"; return 0; }
    apply_killswitch_blocking() { echo "block:${FOREIGN_TUNNELS[*]:-}" >> "$log"; }
    apply_killswitch_allowing() { echo "allow:${FOREIGN_TUNNELS[*]:-}" >> "$log"; }
    remove_killswitch_if_present() { echo remove >> "$log"; }
    try_reconnect_vpn() { echo reconnect >> "$log"; }
    vpn_reconnect_wanted() { return 0; }
    warn_ks_boot_race_if_stuck() { :; }
    touch_heartbeat() { :; }
    tunnel_reachable() { return 0; }
    # Aplicar la política al instante: detectar, escanear, decidir y aplicar, en ese orden.
    killswitch_apply_policy_now >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|decide:nordlynx|block:nordlynx' ]] || return 1
    # Reconciliación normal.
    : > "$log"; phys=0
    reconcile_locked >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|decide:nordlynx|block:nordlynx|reconnect|detect' ]] || return 1
    # Sin interfaz física: el escaneo va tras el último detect y antes de decidir.
    : > "$log"; phys=0; NO_PHYS=1
    reconcile_locked >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|physical|detect|scan|decide:nordlynx|block:nordlynx|reconnect|detect' ]] || return 1
    # Túnel zombie: tras recuperarlo se vuelve a escanear antes de la segunda decisión.
    : > "$log"; phys=0; NO_PHYS=0
    local n=0
    tunnel_reachable() { ((n++ == 0)) && return 1; return 0; }
    reconcile_locked >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|decide:nordlynx|block:nordlynx|reconnect|detect|reconnect|detect|scan|decide:nordlynx|block:nordlynx' ]] || return 1
    # Strict: no se ejecuta ningún escaneo y las decisiones no ven nada ajeno.
    COEXIST_MODE=strict; FOREIGN_TUNNELS=(stale); FOREIGN_MARKS=(0x1); FOREIGN_KS=(nordvpn)
    : > "$log"; phys=0; n=1
    killswitch_apply_policy_now >/dev/null 2>&1
    reconcile_locked >/dev/null 2>&1
    scans="$(grep -c '^scan$' "$log")"
    [[ "$scans" -eq 0 && "$(paste -sd'|' "$log")" == 'detect|decide:|block:|detect|decide:|block:|reconnect|detect' ]] &&
    [[ ${#FOREIGN_TUNNELS[@]} -eq 0 && ${#FOREIGN_MARKS[@]} -eq 0 && ${#FOREIGN_KS[@]} -eq 0 ]]
}

# --- 5.4 (c): la cesión solo existe en la rama auto de la política ---
T208() {
    new_env
    local ov mode wanted known coexist base cede y
    for ov in none on off; do
        for mode in true false auto; do
            for wanted in 1 0; do
                for known in 1 0; do
                    for coexist in auto strict; do
                        rm -f "$KILLSWITCH_OVERRIDE_FILE" "$STATE_FILE"
                        [[ "$ov" == none ]] || printf '%s\n' "$ov" > "$KILLSWITCH_OVERRIDE_FILE"
                        (( wanted )) && printf 'on\n' > "$STATE_FILE"
                        KILLSWITCH_MODE="$mode"; COEXIST_MODE="$coexist"
                        KNOWN_VPN=(); (( known )) && KNOWN_VPN=(vpn)
                        FOREIGN_KS=()
                        if killswitch_should_be_active; then base=1; else base=0; fi
                        FOREIGN_KS=(nordvpn)
                        if killswitch_should_be_active; then cede=1; else cede=0; fi
                        # Un kill switch ajeno solo apaga el bloqueo en auto, sin forzado y con COEXIST_MODE=auto.
                        if [[ "$ov" == none && "$mode" == auto && "$coexist" == auto ]]; then
                            (( cede == 0 )) || return 1
                        else
                            (( cede == base )) || return 1
                        fi
                        # killswitch_is_yielding = "bloquearía sin el ajeno y ya no bloquea".
                        if killswitch_is_yielding; then y=1; else y=0; fi
                        (( y == (base == 1 && cede == 0) )) || return 1
                    done
                done
            done
        done
    done
    # Casos concretos, sin depender del modelo de arriba.
    KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"; KILLSWITCH_MODE=auto; COEXIST_MODE=auto
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; FOREIGN_KS=()
    killswitch_should_be_active || return 1
    FOREIGN_KS=(nordvpn)
    ! killswitch_should_be_active && killswitch_is_yielding || return 1
    printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    killswitch_should_be_active && ! killswitch_is_yielding || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; KILLSWITCH_MODE=true
    killswitch_should_be_active && ! killswitch_is_yielding || return 1
    KILLSWITCH_MODE=auto; COEXIST_MODE=strict
    killswitch_should_be_active && ! killswitch_is_yielding
}

# --- 5.4 (c): COEXIST_YIELD_FILE solo cambia, y se avisa, al entrar, cambiar o salir de la cesión ---
T209() {
    new_env
    local log="$TEST_ROOT/events" out mode
    notify_event() { echo "notify:$1" >> "$log"; }
    UI_LANGUAGE=en; ui_init
    KILLSWITCH_MODE=auto; COEXIST_MODE=auto; KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"
    # Entra en cesión: fichero con el cliente, un log, un aviso y legible con UMask=0027.
    FOREIGN_KS=(nordvpn)
    ( umask 0027; coexist_sync_yield > "$TEST_ROOT/out" 2>&1 )
    [[ "$(<"$COEXIST_YIELD_FILE")" == nordvpn && "$(stat -c %a "$COEXIST_YIELD_FILE")" == 644 ]] || return 1
    grep -Fq 'another kill switch is active (nordvpn)' "$TEST_ROOT/out" || return 1
    [[ "$(<"$log")" == notify:yield ]] || return 1
    # Sin cambios: ni log ni aviso ni reescritura.
    touch -d @978307200 "$COEXIST_YIELD_FILE"
    out="$(coexist_sync_yield 2>&1)"
    [[ -z "$out" && "$(<"$log")" == notify:yield && "$(stat -c %Y "$COEXIST_YIELD_FILE")" == 978307200 ]] || return 1
    # Cambia el cliente: se reescribe y se anota.
    FOREIGN_KS=(nordvpn protonvpn)
    out="$(coexist_sync_yield 2>&1)"
    [[ "$(<"$COEXIST_YIELD_FILE")" == 'nordvpn protonvpn' ]] && grep -Fq '(nordvpn protonvpn)' <<< "$out" || return 1
    # Sale: se borra, se anota y no hay aviso nuevo (el de bloqueo/permiso lo da quien aplica).
    : > "$log"; FOREIGN_KS=()
    out="$(coexist_sync_yield 2>&1)"
    [[ ! -e "$COEXIST_YIELD_FILE" && ! -s "$log" ]] && grep -Fq 'stops yielding' <<< "$out" || return 1
    # Cada razón para no ceder deja todo en silencio y sin fichero.
    local why
    for why in forced_on forced_off mode_true strict unwanted no_profile; do
        KILLSWITCH_MODE=auto; COEXIST_MODE=auto; KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"
        rm -f "$KILLSWITCH_OVERRIDE_FILE"; FOREIGN_KS=(nordvpn)
        case "$why" in
            forced_on) printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE" ;;
            forced_off) printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE" ;;
            mode_true) KILLSWITCH_MODE=true ;;
            strict) COEXIST_MODE=strict ;;
            unwanted) printf 'off\n' > "$STATE_FILE" ;;
            no_profile) KNOWN_VPN=() ;;
        esac
        out="$(coexist_sync_yield 2>&1)"
        [[ -z "$out" && ! -e "$COEXIST_YIELD_FILE" && ! -s "$log" ]] || return 1
    done
    # Un fichero que ya no corresponde (forzado nuevo) se retira.
    KILLSWITCH_MODE=auto; COEXIST_MODE=auto; KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"
    printf 'nordvpn\n' > "$COEXIST_YIELD_FILE"; printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    out="$(coexist_sync_yield 2>&1)"
    [[ ! -e "$COEXIST_YIELD_FILE" ]] && grep -Fq 'stops yielding' <<< "$out" || return 1
    # Si no se puede escribir: error con la ruta, ni log de cesión ni aviso, sin romper el ciclo.
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; FOREIGN_KS=(nordvpn)
    : > "$TEST_ROOT/afile"; STATE_DIR="$TEST_ROOT/afile"; COEXIST_YIELD_FILE="$TEST_ROOT/afile/coexist-yield"
    out="$(coexist_sync_yield 2>&1)"; local rc=$?
    [[ $rc -eq 0 && ! -s "$log" ]] && grep -Fq "$COEXIST_YIELD_FILE" <<< "$out" && ! grep -Fq 'yields blocking' <<< "$out"
}

# --- 5.4 (c): las tres decisiones sincronizan la cesión y ceder retira el bloqueo propio ---
T210() {
    new_env
    local log="$TEST_ROOT/order" scans=0 phys=0 n=0
    detect_known_profiles() { KNOWN_VPN=(vpn); }
    detect_active_state() { echo detect >> "$log"; ACTIVE_VPN=""; PHYS_IFACE=eth0; }
    foreign_vpn_scan() {
        echo scan >> "$log"; FOREIGN_TUNNELS=(); FOREIGN_MARKS=(); FOREIGN_KS=()
        if (( scans++ < ${SCAN_YIELDS:-1} )); then FOREIGN_TUNNELS=(nordlynx); FOREIGN_MARKS=(0xe1f1); FOREIGN_KS=(nordvpn); fi
    }
    apply_killswitch_blocking() { echo block >> "$log"; }
    apply_killswitch_allowing() { echo allow >> "$log"; }
    remove_killswitch_if_present() { echo remove >> "$log"; }
    try_reconnect_vpn() { echo reconnect >> "$log"; }
    vpn_reconnect_wanted() { return 1; }
    warn_ks_boot_race_if_stuck() { :; }
    touch_heartbeat() { :; }
    tunnel_reachable() { return 0; }
    notify_event() { :; }
    printf 'on\n' > "$STATE_FILE"; KILLSWITCH_MODE=auto; COEXIST_MODE=auto
    # Aplicar la política ya: cede (sin bloquear ni permitir) y deja el fichero.
    killswitch_apply_policy_now >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|remove' && "$(<"$COEXIST_YIELD_FILE")" == nordvpn ]] || return 1
    # Reconciliación normal: igual, y sin ceder de nuevo no cambia nada.
    : > "$log"; scans=0
    reconcile_locked >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|remove' && "$(<"$COEXIST_YIELD_FILE")" == nordvpn ]] || return 1
    # Desaparece el kill switch ajeno: se borra el fichero y NetGuard vuelve a bloquear.
    : > "$log"; SCAN_YIELDS=0; scans=0
    reconcile_locked >"$TEST_ROOT/out" 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|block|reconnect|detect' && ! -e "$COEXIST_YIELD_FILE" ]] || return 1
    # Túnel zombie: el segundo escaneo cede y el tercer decide con lo recién leído.
    : > "$log"; SCAN_YIELDS=1; scans=0
    tunnel_reachable() { ((n++ == 0)) && return 1; return 0; }
    reconcile_locked >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|remove|detect|scan|block' && ! -e "$COEXIST_YIELD_FILE" ]] || return 1
    # Estricto o forzado: no hay cesión aunque el escaneo viera algo.
    : > "$log"; scans=0; COEXIST_MODE=strict
    killswitch_apply_policy_now >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|block' && ! -e "$COEXIST_YIELD_FILE" ]] || return 1
    : > "$log"; scans=0; COEXIST_MODE=auto; printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    killswitch_apply_policy_now >/dev/null 2>&1
    [[ "$(paste -sd'|' "$log")" == 'detect|scan|block' && ! -e "$COEXIST_YIELD_FILE" ]]
}

# --- 5.4 (c): al ceder no sale el aviso "kill switch desactivado" ---
T211() {
    new_env
    local log="$TEST_ROOT/events"
    notify_event() { echo "notify:$1" >> "$log"; }
    HAVE_IP6TABLES=0
    # La cadena existe hasta que se borra el salto: -C acierta una vez y luego falla.
    mock iptables 'if [[ "$*" == *" -C "* ]]; then n=$(cat "$TEST_ROOT/chain" 2>/dev/null || echo 1); echo 0 > "$TEST_ROOT/chain"; ((n == 1)) && exit 0; exit 1; fi; exit 0'
    KILLSWITCH_MODE=auto; COEXIST_MODE=auto; KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"
    FOREIGN_KS=(nordvpn)
    coexist_sync_yield >/dev/null 2>&1
    remove_killswitch_if_present >/dev/null 2>&1 || return 1
    [[ "$(<"$log")" == notify:yield ]] || return 1
    # Sin cesión (forzado OFF) el aviso de siempre se mantiene.
    : > "$log"; rm -f "$TEST_ROOT/chain"; FOREIGN_KS=(); printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"
    remove_killswitch_if_present >/dev/null 2>&1 || return 1
    [[ "$(<"$log")" == notify:off ]]
}

# --- 5.4 (c): status, check y menús leen la cesión sin escanear ---
T212() {
    new_env
    local out rc items
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock nmcli 'exit 0'
    HAVE_IP6TABLES=0
    UI_LANGUAGE=en; ui_init
    KILLSWITCH_MODE=auto; COEXIST_MODE=auto; KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"
    # El lector solo acepta nombres de cliente bien formados y solo en auto.
    printf 'nordvpn  protonvpn;x $(y) UPPER ok-1\n' > "$COEXIST_YIELD_FILE"
    coexist_yield_load
    [[ "${FOREIGN_KS[*]}" == 'nordvpn ok-1' ]] || return 1
    COEXIST_MODE=strict; coexist_yield_load; [[ ${#FOREIGN_KS[@]} -eq 0 ]] || return 1
    COEXIST_MODE=auto; rm -f "$COEXIST_YIELD_FILE"; coexist_yield_load; [[ ${#FOREIGN_KS[@]} -eq 0 ]] || return 1
    # status: con la cesión no hay "reglas no coinciden"; sin ella, con la cadena ausente, sí.
    printf 'nordvpn\n' > "$COEXIST_YIELD_FILE"
    out="$(print_killswitch_status 2>&1)"
    grep -Fq 'Yielding' <<< "$out" && grep -Fq 'to nordvpn' <<< "$out" &&
        grep -Fq 'no blocking' <<< "$out" && ! grep -Fq 'do not match' <<< "$out" || return 1
    rm -f "$COEXIST_YIELD_FILE"
    out="$(print_killswitch_status 2>&1)"
    ! grep -Fq 'Yielding' <<< "$out" && grep -Fq 'do not match' <<< "$out" || return 1
    # Un fichero que ya no corresponde (forzado, strict, protección apagada) se ignora.
    printf 'nordvpn\n' > "$COEXIST_YIELD_FILE"
    printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    ! print_killswitch_status 2>&1 | grep -Fq 'Yielding' || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; COEXIST_MODE=strict
    ! print_killswitch_status 2>&1 | grep -Fq 'Yielding' || return 1
    COEXIST_MODE=auto
    # Panel y menú de texto: el kill switch aparece como cedido, con aviso.
    mapfile -t items < <(menu_status_items)
    [[ "${items[3]}" == "warn|$(ui_t menu.st_killswitch)|$(printf -- "$(ui_t menu.st_ks_yield)" nordvpn)" ]] || return 1
    printf 'off\n' > "$STATE_FILE"
    [[ "$(menu_status_items | tail -n1)" == "ok|$(ui_t menu.st_killswitch)|$(printf -- "$(ui_t menu.st_ks_auto)" auto)" ]] || return 1
    printf 'on\n' > "$STATE_FILE"; KILLSWITCH_MODE=true
    [[ "$(menu_status_items | tail -n1)" == ok\|* ]] || return 1
    KILLSWITCH_MODE=auto; printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"
    [[ "$(menu_status_items | tail -n1)" == "warn|$(ui_t menu.st_killswitch)|$(ui_t menu.st_ks_off)" ]] || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"
    # check: cediendo y con Internet es OK; sin Internet avisa; sin la cesión sería crítico.
    detect_known_profiles() { KNOWN_VPN=(vpn); }
    detect_active_state() { ACTIVE_VPN=""; }
    tunnel_reachable() { return 0; }
    rc=0; ( cmd_check ) >"$TEST_ROOT/check" 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && grep -Fq 'NetGuard yields blocking' "$TEST_ROOT/check" || return 1
    tunnel_reachable() { return 1; }
    rc=0; ( cmd_check ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 1 ]] || return 1
    rm -f "$COEXIST_YIELD_FILE"; tunnel_reachable() { return 0; }
    rc=0; ( cmd_check ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]]
}

# --- 5.5: la sección "Convivencia" de status lee en vivo, recomienda y no ensucia FOREIGN_* ---
T213() {
    new_env
    local rc out none
    mock nmcli 'exit 0'
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock ping 'exit 1'
    HAVE_IP6TABLES=0
    UI_LANGUAGE=en; ui_init; none="$(ui_t none)"
    KNOWN_VPN=(vpn); printf 'on\n' > "$STATE_FILE"; KILLSWITCH_MODE=auto; COEXIST_MODE=auto
    have_root() { return 0; }
    local -a st=() sm=() sk=()
    foreign_vpn_scan() { FOREIGN_TUNNELS=("${st[@]}"); FOREIGN_MARKS=("${sm[@]}"); FOREIGN_KS=("${sk[@]}"); }
    cx() { rc=0; print_coexist_status >"$TEST_ROOT/out" 2>&1 || rc=$?; out="$(<"$TEST_ROOT/out")"; flat="$(tr '\n' ' ' <<< "$out" | tr -s ' ')"; }
    row() { printf '  %s%*s%s' "$1" $(( 22 - ${#1} )) '' "$2"; }
    # Nada ajeno: sin recomendación y con los tres datos en "ninguno".
    cx
    [[ $rc -eq 0 ]] && grep -Fq 'No other VPN client' <<< "$out" &&
        grep -Fxq "$(row 'Coexistence mode' auto)" <<< "$out" &&
        grep -Fxq "$(row 'Other tunnels' "$none")" <<< "$out" &&
        grep -Fxq "$(row 'Other fwmarks' "$none")" <<< "$out" &&
        grep -Fxq "$(row 'Other kill switch' "$none")" <<< "$out" || return 1
    # Auto y sin forzado: NetGuard cede; es información, no un aviso.
    st=(nordlynx); sm=(0xe1f1); sk=(nordvpn)
    cx
    [[ $rc -eq 0 ]] && grep -Fxq '  ✓ NetGuard yields blocking to nordvpn while it stays active.' <<< "$out" &&
        grep -Fxq "$(row 'Other tunnels' nordlynx)" <<< "$out" &&
        grep -Fxq "$(row 'Other fwmarks' 0xe1f1)" <<< "$out" &&
        grep -Fxq "$(row 'Other kill switch' nordvpn)" <<< "$out" || return 1
    # Strict bloqueando con un cliente ajeno activo: avisa y recomienda auto, nombrándolo.
    COEXIST_MODE=strict
    cx
    [[ $rc -eq 1 ]] && grep -Fq 'Recommended: COEXIST_MODE="auto"' <<< "$flat" &&
        grep -Fq 'traffic of nordvpn, nordlynx' <<< "$flat" || return 1
    sk=(); sm=(); st=(tun7)
    cx
    [[ $rc -eq 1 ]] && grep -Fq 'traffic of tun7' <<< "$flat" || return 1
    # Strict que no bloquea (forzado off) o sin nada activo (solo una marca): sin recomendación.
    sk=(nordvpn); printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"
    cx; [[ $rc -eq 0 ]] && ! grep -Fq Recommended <<< "$out" || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; sk=(); st=(); sm=(0xe1f1)
    cx; [[ $rc -eq 0 ]] && ! grep -Fq Recommended <<< "$out" || return 1
    # Auto con bloqueo forzado y kill switch ajeno: recomienda la salida que corresponde a cada causa.
    COEXIST_MODE=auto; sk=(nordvpn); sm=(); st=()
    printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    cx
    [[ $rc -eq 1 ]] && grep -Fq 'Recommended: killswitch auto.' <<< "$flat" &&
        grep -Fq 'even though nordvpn is active' <<< "$flat" || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; KILLSWITCH_MODE=true
    cx
    [[ $rc -eq 1 ]] && grep -Fq 'Recommended: KILLSWITCH_MODE="auto".' <<< "$flat" || return 1
    # Auto con bloqueo forzado pero solo un túnel ajeno (sin su kill switch): se deja pasar, sin aviso.
    sk=(); st=(nordlynx)
    cx; [[ $rc -eq 0 ]] && ! grep -Fq Recommended <<< "$out" || return 1
    KILLSWITCH_MODE=auto
    # ProtonVPN: kill switch activo sin túnel (ni de NetGuard ni ajeno) = posible bloqueo huérfano.
    sk=(protonvpn); st=(); ACTIVE_VPN=""
    cx
    [[ $rc -eq 1 ]] && grep -Fq 'nmcli connection down pvpn-killswitch' <<< "$flat" || return 1
    st=(proton0)
    cx; [[ $rc -eq 0 ]] && ! grep -Fq 'pvpn-killswitch' <<< "$out" || return 1
    st=(); ACTIVE_VPN=vpn
    cx; [[ $rc -eq 0 ]] && ! grep -Fq 'pvpn-killswitch' <<< "$out" || return 1
    ACTIVE_VPN=""
    # Sin root se avisa de que el cortafuegos de NordVPN no se lee; con root, no.
    sk=(); cx; ! grep -Fq 'Without root' <<< "$out" || return 1
    have_root() { return 1; }
    cx; grep -Fq 'Without root' <<< "$out" || return 1
    have_root() { return 0; }
    # Las FOREIGN_* del llamador (p. ej. las que llenó coexist_yield_load) quedan intactas.
    FOREIGN_TUNNELS=(keep-t); FOREIGN_MARKS=(0x1); FOREIGN_KS=(keep-k); sk=(nordvpn); st=(tun7); sm=(0xe1f1)
    print_coexist_status >/dev/null 2>&1
    [[ "${FOREIGN_TUNNELS[*]}|${FOREIGN_MARKS[*]}|${FOREIGN_KS[*]}" == 'keep-t|0x1|keep-k' ]] || return 1
    # Español.
    UI_LANGUAGE=es; ui_init
    cx
    grep -Fxq '  Modo de convivencia   auto' <<< "$out" && grep -Fxq '  Túneles ajenos        tun7' <<< "$out" || return 1
    UI_LANGUAGE=en; ui_init
    # status: la sección sale tras la de kill switch y antes de la de conectividad, con el modo de convivencia.
    detect_known_profiles() { KNOWN_VPN=(vpn); }
    detect_active_state() { :; }
    check_internet_reachable() { return 1; }
    out="$(print_status 2>&1)"
    local k c v
    k="$(grep -nE -- '^── Kill switch (─)+$' <<< "$out" | cut -d: -f1)"
    c="$(grep -nE -- '^── Coexistence with other VPNs (─)+$' <<< "$out" | cut -d: -f1)"
    v="$(grep -nE -- '^── Connectivity (─)+$' <<< "$out" | cut -d: -f1)"
    [[ -n "$k" && -n "$c" && -n "$v" ]] && (( k < c && c < v )) && grep -Fxq "$(row 'Other kill switch' nordvpn)" <<< "$out"
}

# --- 5.5: doctor incluye la sección de convivencia y sus recomendaciones suben el resultado a AVISO ---
T214() {
    new_env
    local rc out h k c m
    UI_LANGUAGE=en; ui_init
    mock nmcli 'exit 0'
    have_root() { return 0; }
    check_dependencies() { return 0; }
    warn_if_networkmanager_inactive() { return 0; }
    warn_if_ufw_active() { return 0; }
    boot_killswitch_would_block() { return 1; }
    cmd_check() { exit "${CHECK_RC:-0}"; }
    detect_known_profiles() { KNOWN_VPN=(vpn); }
    detect_active_state() { ACTIVE_VPN=""; }
    printf 'on\n' > "$STATE_FILE"
    printf 'LANGUAGE="en"\n' >> "$CONFIG_FILE"   # doctor recarga la configuración
    local -a st=() sk=()
    foreign_vpn_scan() { echo scan >> "$TEST_ROOT/scans"; FOREIGN_TUNNELS=("${st[@]}"); FOREIGN_MARKS=(); FOREIGN_KS=("${sk[@]}"); }
    doc() { rc=0; ( cmd_doctor ) >"$TEST_ROOT/out" 2>&1 || rc=$?; out="$(<"$TEST_ROOT/out")"; }
    # Limpio: la sección va tras la de kill switch y antes del resumen; resultado OK.
    doc
    h="$(grep -n -- '^-- Kill switch / VPN --$' <<< "$out" | cut -d: -f1)"
    c="$(grep -n -- '^-- Coexistence with other VPNs --$' <<< "$out" | cut -d: -f1)"
    m="$(grep -n -- 'Summary:' <<< "$out" | cut -d: -f1)"
    [[ $rc -eq 0 && -n "$h" && -n "$c" && -n "$m" ]] && (( h < c && c < m )) &&
        grep -Fq 'No other VPN client' <<< "$out" && grep -Fq 'Summary: everything is OK.' <<< "$out" || return 1
    # Strict bloqueando con un kill switch ajeno: la recomendación sube el resultado a AVISO (1).
    printf 'COEXIST_MODE="strict"\n' >> "$CONFIG_FILE"; sk=(nordvpn)
    doc
    [[ $rc -eq 1 ]] && grep -Fq 'Recommended: COEXIST_MODE="auto"' <<< "$out" &&
        grep -Fq 'Summary: review the warnings above.' <<< "$out" || return 1
    # Un resultado CRÍTICO de check no baja por una recomendación.
    CHECK_RC=2; doc
    [[ $rc -eq 2 ]] || return 1
    CHECK_RC=0
    # Sin root la sección se omite sin escanear, y el resultado es AVISO.
    have_root() { return 1; }
    rm -f "$TEST_ROOT/scans"; doc
    [[ $rc -eq 1 && ! -e "$TEST_ROOT/scans" ]] && grep -Fq 'Skipped' <<< "$out" &&
        [[ "$(grep -c '^⚠ Skipped' <<< "$out")" -eq 3 ]] || return 1
    have_root() { return 0; }
    # Sin configuración instalada la detección sigue funcionando (con el modo por defecto, auto: cede).
    rm -f "$CONFIG_FILE"; COEXIST_MODE=auto; doc
    [[ $rc -eq 1 ]] && grep -Fq 'not installed yet' <<< "$out" &&
        grep -Fq 'NetGuard yields blocking to nordvpn' <<< "$out"
}

# --- 5.6 (a): VPN_IGNORE, clave de configuración sin efecto aún sobre el comportamiento ---
T215() {
    new_env
    local err="$TEST_ROOT/err" v ui def long
    # Permitida, vacía por defecto y documentada (línea real y ejemplo comentado).
    def="$(write_default_config)"
    config_key_allowed VPN_IGNORE && [[ -z "$VPN_IGNORE" ]] &&
    [[ "$(grep -c '^VPN_IGNORE=""$' <<< "$def")" -eq 1 ]] &&
    grep -Fq '#   VPN_IGNORE="pvpn-* ProtonVPN*"' <<< "$def" || return 1
    # Patrones con coma, espacios y * ? [ ]: escritos a mano y como los guarda el menú (%q).
    for v in 'pvpn-*' 'a, b ,c' 'pvpn-* Proton?VPN [Pp]roton'; do
        printf 'VPN_IGNORE="%s"\n' "$v" > "$CONFIG_FILE"
        load_config 2>"$err" || return 1
        [[ "$VPN_IGNORE" == "$v" && ! -s "$err" ]] || return 1
        printf 'VPN_IGNORE=%q\n' "$v" > "$CONFIG_FILE"
        load_config 2>"$err" || return 1
        [[ "$VPN_IGNORE" == "$v" && ! -s "$err" ]] || return 1
    done
    # Límite de línea: 1024 caracteres (comillas incluidas) pasan; 1025 rechazan el fichero entero.
    long="$(printf 'a%.0s' $(seq 1 1022))"
    printf 'VPN_IGNORE="%s"\n' "$long" > "$CONFIG_FILE"
    config_file_is_safe "$CONFIG_FILE" || return 1
    printf 'VPN_IGNORE="%s"\n' "${long}a" > "$CONFIG_FILE"
    ! config_file_is_safe "$CONFIG_FILE" || return 1
    printf 'KILLSWITCH_MODE="true"\nVPN_IGNORE="%s"\n' "${long}a" > "$CONFIG_FILE"
    load_config 2>"$err" || return 1
    [[ -z "$VPN_IGNORE" && "$KILLSWITCH_MODE" == auto && -s "$err" ]] || return 1
    # Etiqueta en es y en.
    for ui in es en; do
        UI_LANGUAGE="$ui"
        [[ -n "$(ui_field_label VPN_IGNORE)" && "$(ui_field_label VPN_IGNORE)" != VPN_IGNORE ]] || return 1
    done
    UI_LANGUAGE=es; v="$(ui_field_label VPN_IGNORE)"
    UI_LANGUAGE=en
    [[ "$v" != "$(ui_field_label VPN_IGNORE)" ]]
}

# Guardado real de VPN_IGNORE desde los dos menús (el escritor es el mismo: panel_write_config_keys).
T216() {
    new_env
    menu_clear() { :; }; pause_enter() { :; }; sleep() { :; }
    menu_elevate() { if [[ "$1" == install ]]; then cp -- "${@: -2:1}" "${@: -1}"; else "$@"; fi; }
    panel_info_box() { echo info >> "$TEST_ROOT/box"; }
    panel_error_box() { echo error >> "$TEST_ROOT/box"; }
    local keys idx want
    # Número de VPN_IGNORE en el menú de terminal, sacado de las claves que entrega.
    keys="$(menu_configure_keys() { shift 2; printf '%s\n' "$@"; }; menu_configure_general)"
    idx="$(grep -nFx VPN_IGNORE <<< "$keys" | cut -d: -f1)"
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1

    # Terminal: en blanco conserva (y el fichero se reescribe: pasa de comillas a %q).
    printf 'KILLSWITCH_MODE="auto"\nVPN_IGNORE="old-*"\n' > "$CONFIG_FILE"
    printf '%s\n' "$idx" '' g | menu_configure_general >/dev/null 2>&1 || return 1
    grep -Fxq 'VPN_IGNORE=old-\*' "$CONFIG_FILE" && [[ "$(panel_get_val VPN_IGNORE)" == 'old-*' ]] || return 1
    # Terminal: valor escrito, con coma, espacio y comodines.
    printf '%s\n' "$idx" 'pvpn-*, Proton VPN?' g | menu_configure_general >/dev/null 2>&1 || return 1
    [[ "$(panel_get_val VPN_IGNORE)" == 'pvpn-*, Proton VPN?' ]] && config_file_is_safe "$CONFIG_FILE" &&
    grep -Fxq 'KILLSWITCH_MODE="auto"' "$CONFIG_FILE" || return 1
    # Terminal: "-" vacía el campo.
    printf '%s\n' "$idx" - g | menu_configure_general >/dev/null 2>&1 || return 1
    [[ -z "$(panel_get_val VPN_IGNORE)" ]] || return 1

    # Panel: zenity simulado; cada campo vuelve en blanco salvo VPN_IGNORE, hallado por su etiqueta.
    zenity_ui() {
        local a out="" sep="" lbl val
        lbl="$(ui_field_label VPN_IGNORE)"
        for a in "$@"; do
            case "$a" in
                --add-entry=*|--add-combo=*)
                    val=""
                    [[ "$a" == "--add-entry=$lbl ("* ]] && val="$PANEL_WANT"
                    out+="$sep$val"; sep='|' ;;
            esac
        done
        printf '%s\n' "$out"
    }
    printf 'KILLSWITCH_MODE="auto"\nVPN_IGNORE="old-*"\n' > "$CONFIG_FILE"
    PANEL_WANT=''
    panel_action_configure >/dev/null 2>&1
    grep -Fxq 'VPN_IGNORE=old-\*' "$CONFIG_FILE" && [[ "$(panel_get_val VPN_IGNORE)" == 'old-*' ]] || return 1
    PANEL_WANT='pvpn-*, Proton VPN?'
    : > "$TEST_ROOT/box"
    panel_action_configure >/dev/null 2>&1
    [[ "$(panel_get_val VPN_IGNORE)" == 'pvpn-*, Proton VPN?' ]] && ! grep -q error "$TEST_ROOT/box" || return 1
    PANEL_WANT=-
    panel_action_configure >/dev/null 2>&1
    [[ -z "$(panel_get_val VPN_IGNORE)" ]]
}

# --- 5.6 (b): VPN_IGNORE aparta perfiles de KNOWN_VPN (detect_known_profiles) ---
T217() {
    new_env
    local old_ifs="$IFS"
    mock nmcli 'printf "%s\n" "Home:802-3-ethernet" "pvpn-es:vpn" "pvpn-wg:wireguard" "Proton VPN:vpn" "Work VPN:vpn" "Work-WG:wireguard" "other-vpn:vpn"'
    # Sin VPN_IGNORE no se aparta nada.
    VPN_IGNORE=""
    detect_known_profiles
    [[ "${#KNOWN_VPN[@]}" -eq 6 && "${#IGNORED_VPN[@]}" -eq 0 ]] || return 1
    # Patrones con coma, espacios dobles, ? y [ ]: los ignorados salen de KNOWN_VPN y quedan en IGNORED_VPN.
    VPN_IGNORE='pvpn-*, Proton?VPN  [Ww]ork-*'
    detect_known_profiles
    [[ "$(printf '%s|' "${KNOWN_VPN[@]}")" == 'Work VPN|other-vpn|' &&
       "$(printf '%s|' "${IGNORED_VPN[@]}")" == 'pvpn-es|pvpn-wg|Proton VPN|Work-WG|' &&
       "$IFS" == "$old_ifs" ]] || return 1
    # Lo explícito gana: VPN_CONNECTION no se ignora, ni siquiera por patrón.
    VPN_CONNECTION="pvpn-es"
    detect_known_profiles
    [[ "${KNOWN_VPN[*]}" == pvpn-es && "$(printf '%s|' "${IGNORED_VPN[@]}")" == 'pvpn-wg|Proton VPN|Work-WG|' ]] || return 1
    vpn_is_ignored pvpn-es && return 1
    VPN_CONNECTION=""
    vpn_is_ignored pvpn-es || return 1
    # Cada detección parte de cero: sin patrones no queda nada de la anterior.
    VPN_IGNORE=""
    detect_known_profiles
    [[ "${#IGNORED_VPN[@]}" -eq 0 && "${#KNOWN_VPN[@]}" -eq 6 ]] || return 1
    # El helper mira solo los patrones, no IGNORED_VPN ni si detect_known_profiles corrió.
    IGNORED_VPN=(pvpn-es)
    vpn_is_ignored pvpn-es && return 1
    IGNORED_VPN=()
    # Sin expansión de rutas: un fichero llamado como el patrón no lo altera.
    mkdir "$TEST_ROOT/cwd" && : > "$TEST_ROOT/cwd/pvpn-zzz" && cd "$TEST_ROOT/cwd" || return 1
    VPN_IGNORE='pvpn-*'
    vpn_is_ignored pvpn-es || return 1
    # Nombre completo y con mayúsculas exactas; separadores vacíos no ignoran nada.
    VPN_IGNORE='Work'
    vpn_is_ignored 'Work VPN' && return 1
    VPN_IGNORE='proton*'
    vpn_is_ignored 'Proton VPN' && return 1
    VPN_IGNORE=',, ,'
    vpn_is_ignored anything && return 1
    VPN_IGNORE='*'
    vpn_is_ignored anything
}

# --- 5.6 (c): VPN_IGNORE en bloqueo, túnel zombie, desactivar, activar y status ---
T218() {
    new_env
    local f="$TEST_ROOT/cand"
    apply_killswitch_rules() { printf 'v4:%s|' "${KS_VPN_CANDIDATES[@]}" >> "$f"; }
    apply_killswitch_rules6() { printf 'v6:%s|' "${KS_VPN_CANDIDATES[@]}" >> "$f"; }
    notify_event() { :; }; warn_if_dns_mismatch() { :; }
    # El bloqueo exceptúa los endpoints de los perfiles propios y de los ignorados (su cliente debe poder conectar).
    KNOWN_VPN=(own); IGNORED_VPN=(pvpn-es 'Proton VPN')
    apply_killswitch_blocking >/dev/null 2>&1 || return 1
    [[ "$(<"$f")" == 'v4:own|v4:pvpn-es|v4:Proton VPN|v6:own|v6:pvpn-es|v6:Proton VPN|' ]] || return 1
    # Solo ignorados (todo ignorado con el bloqueo forzado): siguen siendo candidatos.
    : > "$f"; KNOWN_VPN=()
    apply_killswitch_blocking >/dev/null 2>&1 || return 1
    [[ "$(<"$f")" == 'v4:pvpn-es|v4:Proton VPN|v6:pvpn-es|v6:Proton VPN|' ]]
}

T219() {
    new_env
    local log="$TEST_ROOT/calls"
    detect_known_profiles() { KNOWN_VPN=(own); IGNORED_VPN=(pvpn-es); }
    detect_active_state() { ACTIVE_VPN="$ACTIVE_NOW"; PHYS_IFACE=eth0; }
    foreign_vpn_scan() { FOREIGN_TUNNELS=(); FOREIGN_MARKS=(); FOREIGN_KS=(); }
    nmcli_c() { echo "nmcli $*" >> "$log"; }
    try_reconnect_vpn() { echo reconnect >> "$log"; }
    apply_killswitch_allowing() { echo allow >> "$log"; }
    apply_killswitch_blocking() { echo block >> "$log"; }
    remove_killswitch_if_present() { :; }
    warn_ks_boot_race_if_stuck() { :; }
    touch_heartbeat() { :; }
    notify_event() { :; }
    tunnel_reachable() { return 1; }
    KILLSWITCH_MODE=true; VPN_IGNORE='pvpn-*'
    # Túnel sin Internet con una VPN ignorada activa: se avisa, pero ni se baja ni se reconecta.
    ACTIVE_NOW=pvpn-es
    reconcile_locked > "$TEST_ROOT/out" 2>&1 || return 1
    [[ "$(paste -sd, "$log")" == allow,allow ]] && grep -q 'Sin respuesta real de Internet' "$TEST_ROOT/out" || return 1
    # Propia: se baja y se reconecta como siempre.
    : > "$log"; ACTIVE_NOW=own
    reconcile_locked >/dev/null 2>&1 || return 1
    grep -Fxq 'nmcli connection down own' "$log" && grep -Fxq reconnect "$log" || return 1
    # Lo explícito gana: con VPN_CONNECTION el perfil ya no se ignora.
    : > "$log"; ACTIVE_NOW=pvpn-es; VPN_CONNECTION=pvpn-es
    reconcile_locked >/dev/null 2>&1 || return 1
    grep -Fxq 'nmcli connection down pvpn-es' "$log" && grep -Fxq reconnect "$log"
}

T220() {
    new_env
    local log="$TEST_ROOT/calls" out ui
    detect_known_profiles() { KNOWN_VPN=("${T_KNOWN[@]}"); IGNORED_VPN=("${T_IGNORED[@]}"); }
    detect_active_state() { ACTIVE_VPN="$ACTIVE_NOW"; }
    with_killswitch_lock() { "$@"; }
    disable_killswitch_locked() { :; }
    reconcile_sync() { return 0; }
    nmcli_c() { echo "nmcli $*" >> "$log"; }
    VPN_IGNORE='pvpn-*'; T_KNOWN=(own); T_IGNORED=(pvpn-es)
    for ui in es en; do
        UI_LANGUAGE="$ui"; ui_init
        # Desactivar con una VPN ignorada activa: no se baja y queda constancia en el log.
        : > "$log"; ACTIVE_NOW=pvpn-es
        out="$(do_deactivate 2>&1)" || return 1
        [[ ! -s "$log" && "$out" == *"'pvpn-es'"*VPN_IGNORE* ]] || return 1
        # Con una propia activa: se baja y se registra como siempre.
        ACTIVE_NOW=own
        out="$(do_deactivate 2>&1)" || return 1
        [[ "$(<"$log")" == 'nmcli connection down own' && "$out" != *VPN_IGNORE* ]] || return 1
        # Con VPN_CONNECTION el perfil nombrado no se ignora.
        : > "$log"; ACTIVE_NOW=pvpn-es; VPN_CONNECTION=pvpn-es
        do_deactivate >/dev/null 2>&1 || return 1
        [[ "$(<"$log")" == 'nmcli connection down pvpn-es' ]] || return 1
        VPN_CONNECTION=""
        # Activar con todos los perfiles ignorados: mensaje propio con los nombres y la clave; nunca el de "añade una VPN".
        T_KNOWN=(); T_IGNORED=(pvpn-es 'Proton VPN')
        out="$(do_activate 2>&1)" || return 1
        [[ "$out" == *'pvpn-es, Proton VPN'* && "$out" == *VPN_IGNORE* && "$out" != *VPN_CONNECTION* ]] || return 1
        # Sin ningún perfil: el mensaje de siempre; con alguno propio: ninguno de los dos.
        T_IGNORED=()
        out="$(do_activate 2>&1)" || return 1
        [[ "$out" == *VPN_CONNECTION* && "$out" != *VPN_IGNORE* ]] || return 1
        T_KNOWN=(own); T_IGNORED=(pvpn-es)
        out="$(do_activate 2>&1)" || return 1
        [[ "$out" != *VPN_CONNECTION* && "$out" != *VPN_IGNORE* ]] || return 1
        T_KNOWN=(own)
    done
}

T221() {
    new_env
    mock nmcli 'case "$*" in *--active*) ;; *) printf "%s\n" "own:vpn" "pvpn-es:vpn" "Proton VPN:vpn" ;; esac; exit 0'
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock ping 'exit 1'
    HAVE_IP6TABLES=0
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    local out ui
    for ui in es en; do
        UI_LANGUAGE="$ui"; ui_init
        # Con VPN_IGNORE, status lista aparte los perfiles ignorados y deja los propios en su línea.
        VPN_IGNORE='pvpn-*, Proton?VPN'
        out="$(print_status 2>&1)"
        grep -Eq '^  (Perfiles VPN|VPN profiles) {10}own$' <<< "$out" &&
        grep -Eq '^  (VPN ignoradas {9}|Ignored VPN profiles {2})pvpn-es Proton VPN$' <<< "$out" || return 1
        # Sin VPN_IGNORE no hay línea de ignorados.
        VPN_IGNORE=''
        out="$(print_status 2>&1)"
        grep -Eq '^  (Perfiles VPN|VPN profiles) {10}own pvpn-es Proton VPN$' <<< "$out" &&
        ! grep -Eq 'VPN ignoradas|Ignored VPN profiles' <<< "$out" || return 1
    done
}

# --- 5.7: el bloqueo de arranque deja pasar lo ajeno visible sin NetworkManager ---
T222() {
    new_env
    local f chain order="$TEST_ROOT/order"
    HAVE_IP6TABLES=1
    check_dependencies() { :; }
    require_root() { :; }
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock iptables-restore 'cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6"; exit 0'
    mock nmcli 'echo "$*" >> "$TEST_ROOT/nmcli.calls"; exit 1'
    mock nordvpn 'exit 0'
    SYS_NET_DIR="$TEST_ROOT/sys"; mkdir -p "$SYS_NET_DIR/nordlynx"
    echo unknown > "$SYS_NET_DIR/nordlynx/operstate"
    printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"
    # Auto, con el escaneo real: túnel y marca ajenos pasan en las dos familias, el DROP
    # sigue último y no se consulta NetworkManager (aún no corre).
    ( boot_killswitch_main ) >/dev/null 2>&1
    for f in restore4:NETGUARD_KS restore6:NETGUARD_KS6; do
        chain="${f#*:}"; f="$TEST_ROOT/${f%%:*}"
        grep -Fxq -- "-A $chain -o nordlynx -j RETURN" "$f" &&
        grep -Fxq -- "-A $chain -m mark --mark 0xe1f1 -j RETURN" "$f" &&
        ! grep -q ACCEPT "$f" &&
        [[ "$(grep "^-A $chain " "$f" | tail -n1)" == "-A $chain -j DROP" ]] || return 1
    done
    [[ ! -e "$TEST_ROOT/nmcli.calls" ]] || return 1
    # Strict: se bloquea igual y no pasa nada ajeno.
    base_config; echo 'COEXIST_MODE="strict"' >> "$CONFIG_FILE"
    rm -f "$TEST_ROOT/restore4" "$TEST_ROOT/restore6"
    ( boot_killswitch_main ) >/dev/null 2>&1
    for f in restore4:NETGUARD_KS restore6:NETGUARD_KS6; do
        chain="${f#*:}"; f="$TEST_ROOT/${f%%:*}"
        [[ -s "$f" ]] && ! grep -q -e nordlynx -e mark "$f" &&
        [[ "$(grep "^-A $chain " "$f" | tail -n1)" == "-A $chain -j DROP" ]] || return 1
    done
    [[ ! -e "$TEST_ROOT/nmcli.calls" ]] || return 1
    # Contrato del escaneo: una sola vez, con "boot" y antes de escribir las reglas; ni en
    # strict ni sin bloqueo se escanea.
    foreign_vpn_scan() { echo "scan:${1:-}" >> "$order"; }
    mock iptables-restore 'echo restore4 >> "$TEST_ROOT/order"; cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'echo restore6 >> "$TEST_ROOT/order"; cat > "$TEST_ROOT/restore6"; exit 0'
    base_config
    ( boot_killswitch_main ) >/dev/null 2>&1
    [[ "$(paste -sd'|' "$order")" == 'scan:boot|restore4|restore6' ]] || return 1
    : > "$order"; echo 'COEXIST_MODE="strict"' >> "$CONFIG_FILE"
    ( boot_killswitch_main ) >/dev/null 2>&1
    [[ "$(paste -sd'|' "$order")" == 'restore4|restore6' ]] || return 1
    : > "$order"; base_config; printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"
    ( boot_killswitch_main ) >/dev/null 2>&1
    [[ ! -s "$order" ]]
}

# --- 5.8: el bloqueo de arranque no cede, así que no hereda la cesión de la sesión anterior ---
# coexist-yield vive en /var/lib y sobrevive al reinicio; si el arranque bloquea pero el fichero
# sigue ahí, status y los menús (sin root, sin escanear) dirían "cedido" con las reglas puestas.
T223() {
    new_env
    local out
    HAVE_IP6TABLES=1
    check_dependencies() { :; }
    require_root() { :; }
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock iptables-restore 'cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6"; exit 0'
    mock nmcli 'exit 1'
    SYS_NET_DIR="$TEST_ROOT/sys"; mkdir -p "$SYS_NET_DIR"
    KNOWN_VPN=(vpn)
    # Auto y deseada: el arranque bloquea y la cesión heredada se retira.
    printf 'nordvpn\n' > "$COEXIST_YIELD_FILE"; printf 'on\n' > "$STATE_FILE"
    ( boot_killswitch_main ) >/dev/null 2>&1
    [[ -s "$TEST_ROOT/restore4" && ! -e "$COEXIST_YIELD_FILE" ]] || return 1
    # Lo que leen status y menús sin escanear: ya no hay cesión que mostrar.
    coexist_yield_load
    [[ ${#FOREIGN_KS[@]} -eq 0 ]] || return 1
    # También en strict y con el bloqueo forzado; sin bloqueo (forzado OFF) tampoco queda rastro.
    rm -f "$TEST_ROOT/restore4"
    printf 'nordvpn\n' > "$COEXIST_YIELD_FILE"; echo 'COEXIST_MODE="strict"' >> "$CONFIG_FILE"
    ( boot_killswitch_main ) >/dev/null 2>&1
    [[ -s "$TEST_ROOT/restore4" && ! -e "$COEXIST_YIELD_FILE" ]] || return 1
    base_config; rm -f "$TEST_ROOT/restore4"
    printf 'nordvpn\n' > "$COEXIST_YIELD_FILE"; printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"
    ( boot_killswitch_main ) >/dev/null 2>&1
    [[ ! -e "$TEST_ROOT/restore4" && ! -e "$COEXIST_YIELD_FILE" ]] || return 1
    # Tras el arranque, el demonio vuelve a decidir: si el ajeno sigue activo, cede y lo avisa.
    rm -f "$KILLSWITCH_OVERRIDE_FILE"; printf 'on\n' > "$STATE_FILE"
    notify_event() { echo "notify:$1" >> "$TEST_ROOT/events"; }
    FOREIGN_KS=(nordvpn)
    out="$(coexist_sync_yield 2>&1)"
    [[ "$(<"$COEXIST_YIELD_FILE")" == nordvpn && "$(<"$TEST_ROOT/events")" == notify:yield ]]
}

# --- 6.2: el perfil de 1-click es el "equilibrado y compatible" del PLAN (sección 8) ---
T224() {
    new_env
    menu_elevate() { if [[ "$1" == install ]]; then cp -- "${@: -2:1}" "${@: -1}"; else "$@"; fi; }
    local -a keys; local -A want=(
        [KILLSWITCH_MODE]=auto [COEXIST_MODE]=auto [KILLSWITCH_BOOT_RACE_AUTO_DISABLE]=true [ALLOW_LAN]=true
        [DESKTOP_NOTIFICATIONS]=true [ANONYMIZE_NETWORK]=true [MAC_MODE]=stable [ROTATE_MAC_PER_BOOT]=true
        [RANDOMIZE_SCAN_MAC]=true [SPOOF_HOSTNAME]=true [HARDEN_DHCP_IDENTIFIERS]=true [IPV6_PRIVACY]=true
        [DISABLE_MDNS_ANNOUNCE]=true [DISABLE_AVAHI_SERVICE]=false [DISABLE_NETBIOS_SERVICE]=false
        [HARDEN_BROWSER_DOH]=false )
    local kv k out
    mapfile -t keys < <(one_click_config_keys)
    # Exactamente las 16 claves de la tabla, sin repetir, todas de la lista blanca y con el valor previsto.
    [[ ${#keys[@]} -eq ${#want[@]} ]] || return 1
    declare -A seen=()
    for kv in "${keys[@]}"; do
        k="${kv%%=*}"
        [[ -z "${seen[$k]:-}" && "${want[$k]:-}" == "${kv#*=}" ]] && config_key_allowed "$k" || return 1
        seen[$k]=1
    done
    # Partiendo de la configuración más estricta, el perfil la deja en el perfil y es válida y silenciosa.
    base_config
    sed -i -e 's/^KILLSWITCH_MODE=.*/KILLSWITCH_MODE="true"/' -e 's/^MAC_MODE=.*/MAC_MODE="random"/' \
        -e 's/^DISABLE_AVAHI_SERVICE=.*/DISABLE_AVAHI_SERVICE="true"/' -e 's/^DISABLE_NETBIOS_SERVICE=.*/DISABLE_NETBIOS_SERVICE="true"/' \
        -e 's/^HARDEN_BROWSER_DOH=.*/HARDEN_BROWSER_DOH="true"/' "$CONFIG_FILE"
    echo 'COEXIST_MODE="strict"' >> "$CONFIG_FILE"
    panel_write_config_keys "${keys[@]}" || return 1
    config_file_is_safe "$CONFIG_FILE" || return 1
    load_config > "$TEST_ROOT/load.out" 2>&1 || return 1
    [[ ! -s "$TEST_ROOT/load.out" ]] || return 1
    for k in "${!want[@]}"; do [[ "${!k}" == "${want[$k]}" ]] || return 1; done
    [[ "$(grep -c '^COEXIST_MODE=' "$CONFIG_FILE")" -eq 1 ]] || return 1
    # Los textos describen ese perfil: sin MAC aleatoria ni Avahi/NetBIOS/DoH "desactivados o endurecidos".
    local lang
    for lang in es en; do
        UI_LANGUAGE="$lang"; ui_init
        out="$(ui_t panel.one_click_confirm) $(ui_t panel.one_click_done)"
        ! grep -qiE 'aleatoria|random|endurecid|hardened|full network|completo' <<< "$out" || return 1
    done
}

# --- 6.1 (a): la copia de seguridad de la configuración, compartida por import-config y 1-click ---
T225() {
    new_env
    local bak
    # Éxito: junto a la configuración, con su contenido y 0644.
    bak="$(config_backup_make)" || return 1
    [[ "$bak" == "$CONFIG_FILE".bak-* && -f "$bak" && "$(stat -c %a "$bak")" == 644 ]] && cmp -s "$CONFIG_FILE" "$bak" || return 1
    rm -f "$bak"
    # Falla install o mktemp: devuelve 1, no imprime ruta y no deja ningún .bak (antes quedaba uno vacío).
    mock install 'exit 1'
    bak="$(config_backup_make)" && return 1
    [[ -z "$bak" ]] && ! compgen -G "$CONFIG_FILE.bak-*" >/dev/null || return 1
    rm -f "$MOCKBIN/install"; mock mktemp 'exit 1'
    bak="$(config_backup_make)" && return 1
    [[ -z "$bak" ]] || return 1
    rm -f "$MOCKBIN/mktemp"; mock install 'exit 1'
    # Importar sin copia previa se cancela con su aviso y la configuración queda intacta.
    cp "$CONFIG_FILE" "$TEST_ROOT/before.conf"; printf '%s\n' 'KILLSWITCH_MODE="false"' > "$TEST_ROOT/import.conf"
    cmd_import_config "$TEST_ROOT/import.conf" > "$TEST_ROOT/imp.out" 2>&1 && return 1
    grep -Fq "$(ui_t config.backup_fail)" "$TEST_ROOT/imp.out" && cmp -s "$TEST_ROOT/before.conf" "$CONFIG_FILE"
}

# --- 6.1 (b): el subcomando one-click ---
# oc_env: entorno de 1-click con los pasos lentos sustituidos por registros en $TEST_ROOT/calls.
# Controles: PRIV_RC, ACT_RC, SVC_RC (códigos de salida de cada paso), ACT_VPN (perfil que
# "encuentra" do_activate; vacío = ninguno), EN_RC (systemctl is-enabled), OC_TUN y OC_KS
# (túneles y kill switch ajenos que ve el escaneo; el escaneo en sí es la parte simulada).
oc_env() {
    new_env
    sed -i 's/^LANGUAGE=.*/LANGUAGE="en"/' "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    menu_elevate() { if [[ "$1" == install ]]; then cp -- "${@: -2:1}" "${@: -1}"; else "$@"; fi; }
    apply_network_privacy() { echo "privacy rot=$ROTATE_MAC_PER_BOOT" >> "$TEST_ROOT/calls"; echo privacy-log; return "${PRIV_RC:-0}"; }
    do_activate() {
        echo "activate rot=$ROTATE_MAC_PER_BOOT" >> "$TEST_ROOT/calls"; echo activate-log
        if [[ -n "${ACT_VPN-office}" ]]; then KNOWN_VPN=("${ACT_VPN-office}"); else KNOWN_VPN=(); fi
        return "${ACT_RC:-0}"
    }
    mock systemctl '[[ "$1" == is-enabled ]] && exit "${EN_RC:-0}"; echo "systemctl $*" >> "$TEST_ROOT/calls"; echo systemctl-log; exit "${SVC_RC:-0}"'
    OC_TUN=() OC_KS=()
    detect_known_profiles() { :; }
    detect_active_state() { :; }
    foreign_vpn_scan() { FOREIGN_TUNNELS=("${OC_TUN[@]}"); FOREIGN_MARKS=(); FOREIGN_KS=("${OC_KS[@]}"); }
    : > "$UNIT_DST"
    : > "$TEST_ROOT/calls"
    cp "$CONFIG_FILE" "$TEST_ROOT/before.conf"
}

T226() {
    oc_env
    local out rc n prev=0 pat bak
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] || return 1
    # Resumen: los cinco pasos con ✓ y en orden.
    for pat in '✓ Configuration backup: ' '✓ Recommended profile saved to ' '✓ Network privacy applied' \
               '✓ VPN protection enabled' '✓ Service vpn-netguard.service restarted'; do
        n="$(grep -nF -- "$pat" <<< "$out" | head -1 | cut -d: -f1)"
        [[ -n "$n" ]] && (( n > prev )) || return 1
        prev=$n
    done
    # Pasos en orden y con el perfil ya cargado: ROTATE_MAC_PER_BOOT era false en la configuración anterior.
    [[ "$(<"$TEST_ROOT/calls")" == $'privacy rot=true\nactivate rot=true\nsystemctl restart vpn-netguard.service' ]] || return 1
    # El registro de los pasos que van bien no ensucia el resumen.
    ! grep -qE 'privacy-log|activate-log|systemctl-log' <<< "$out" || return 1
    # Copia idéntica a la configuración anterior, perfil escrito una vez por clave y configuración válida.
    bak="$(compgen -G "$CONFIG_FILE.bak-*")" && [[ "$(wc -l <<< "$bak")" -eq 1 ]] && cmp -s "$bak" "$TEST_ROOT/before.conf" || return 1
    [[ "$(grep -c '^ROTATE_MAC_PER_BOOT=' "$CONFIG_FILE")" -eq 1 ]] && grep -q '^ROTATE_MAC_PER_BOOT=true$' "$CONFIG_FILE" || return 1
    config_file_is_safe "$CONFIG_FILE" || return 1
    # Cierre: perfil aplicado y pista de reconexión; sin pista de DoH mientras no cambie.
    grep -Fq "$(ui_t panel.one_click_done)" <<< "$out" && grep -Fq "$(ui_t panel.privacy_reconnect_hint)" <<< "$out" || return 1
    ! grep -Fq "$(ui_t panel.doh_restart_browser)" <<< "$out" && ! grep -Fq "$(ui_t oneclick.partial)" <<< "$out" || return 1
    # DoH endurecido antes (true) y false en el perfil: sale la pista de reabrir el navegador.
    cp "$TEST_ROOT/before.conf" "$CONFIG_FILE"; rm -f "$CONFIG_FILE".bak-*
    sed -i 's/^HARDEN_BROWSER_DOH=.*/HARDEN_BROWSER_DOH="true"/' "$CONFIG_FILE"
    load_config >/dev/null 2>&1
    out="$(cmd_one_click 2>&1)" || return 1
    grep -Fq "$(ui_t panel.doh_restart_browser)" <<< "$out"
}

T227() {
    oc_env
    local out rc real_install
    # check <texto>: sale con 1, lo dice, no ejecuta ningún paso, no deja copias y la configuración queda como estaba.
    check() {
        out="$(cmd_one_click 2>&1)"; rc=$?
        [[ $rc -eq 1 ]] && grep -Fq -- "$1" <<< "$out" && [[ ! -s "$TEST_ROOT/calls" ]] &&
            ! compgen -G "$CONFIG_FILE.bak-*" >/dev/null && { [[ ! -f "$CONFIG_FILE" ]] || cmp -s "$TEST_ROOT/before.conf" "$CONFIG_FILE"; }
    }
    rm -f "$CONFIG_FILE"
    check 'Cannot find' || return 1
    # Configuración rechazada por config_file_is_safe: el perfil no tendría efecto.
    cp "$TEST_ROOT/before.conf" "$CONFIG_FILE"; echo 'EVIL=1' >> "$CONFIG_FILE"; cp "$CONFIG_FILE" "$TEST_ROOT/before.conf"
    check 'ignores the whole file' || return 1
    # Aborta antes de la copia de seguridad. Sin esto, panel_write_config_keys (que también rechaza
    # una configuración rechazada) dejaría el mismo estado final tras hacer y deshacer la copia.
    ! grep -Fq 'Configuration backup:' <<< "$out" || return 1
    cp "$TEST_ROOT/before.conf" "$CONFIG_FILE"; sed -i '/^EVIL=/d' "$CONFIG_FILE"; cp "$CONFIG_FILE" "$TEST_ROOT/before.conf"
    # Sin copia de seguridad no se toca nada.
    mock install 'exit 1'
    check 'Could not save the configuration backup' || return 1
    rm -f "$MOCKBIN/install"; hash -r
    # Perfil sin poder guardarse: la configuración sigue igual y no queda copia.
    panel_write_config_keys() { return 1; }
    check 'Could not save the profile' || return 1
    # Escritura a medias (configuración vaciada): se restaura desde la copia y la copia se borra.
    panel_write_config_keys() { : > "$CONFIG_FILE"; return 1; }
    check 'Could not save the profile' || return 1
    # Si tampoco se puede restaurar, se avisa y la copia se conserva.
    real_install="$(command -v install)"
    mock install "n=\$(cat \"\$TEST_ROOT/n\" 2>/dev/null || echo 0); echo \$((n + 1)) > \"\$TEST_ROOT/n\"; (( n == 0 )) || exit 1; exec $real_install \"\$@\""
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 1 && ! -s "$CONFIG_FILE" && ! -s "$TEST_ROOT/calls" ]] && grep -Fq 'left damaged' <<< "$out" &&
        cmp -s "$(compgen -G "$CONFIG_FILE.bak-*")" "$TEST_ROOT/before.conf"
}

T228() {
    local step out rc msg
    for step in privacy activate service; do
        oc_env
        PRIV_RC=0 ACT_RC=0; export SVC_RC=0
        case "$step" in
            privacy)  PRIV_RC=1; msg='✗ Network privacy was not fully applied' ;;
            activate) ACT_RC=1;  msg='✗ Could not enable VPN protection' ;;
            service)  export SVC_RC=1; msg='✗ Could not restart the service vpn-netguard.service' ;;
        esac
        out="$(cmd_one_click 2>&1)"; rc=$?
        [[ $rc -eq 2 ]] && grep -Fq -- "$msg" <<< "$out" || return 1
        # Los tres pasos corren aunque uno falle; solo el que falla muestra su salida, sangrada.
        [[ "$(wc -l < "$TEST_ROOT/calls")" -eq 3 && "$(grep -c -- '^    [a-z]*-log$' <<< "$out")" -eq 1 ]] || return 1
        grep -Fq "$(ui_t oneclick.partial)" <<< "$out" && ! grep -Fq "$(ui_t panel.one_click_done)" <<< "$out" || return 1
        grep -q '^ROTATE_MAC_PER_BOOT=true$' "$CONFIG_FILE" || return 1   # el perfil sí quedó guardado
    done
    # Sin la unidad del servicio no hay nada que reiniciar: aviso, sin llamar a systemctl, y no cuenta como fallo.
    oc_env; export SVC_RC=0; rm -f "$UNIT_DST"
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && grep -Fq '⚠ The service vpn-netguard.service is not installed: not restarted' <<< "$out" &&
        ! grep -q systemctl "$TEST_ROOT/calls" && grep -Fq "$(ui_t panel.one_click_done)" <<< "$out"
}

T229() {
    new_env
    local blk out lang a b
    # El despacho exige root antes de llamar a cmd_one_click (no se ejecuta de verdad: con root tocaría /etc).
    blk="$(awk '/^    one-click\)$/ {f=1; next} f && /^        ;;$/ {exit} f' "$SCRIPT")"
    a="$(grep -n 'require_root' <<< "$blk" | head -1 | cut -d: -f1)"
    b="$(grep -n 'cmd_one_click' <<< "$blk" | head -1 | cut -d: -f1)"
    [[ -n "$a" && -n "$b" ]] && (( a < b )) && grep -q 'check_dependencies' <<< "$blk" && grep -q 'load_config' <<< "$blk" || return 1
    # La ayuda y la cabecera del script lo documentan, en los dos idiomas.
    for lang in es en; do
        out="$(VPN_NETGUARD_LANGUAGE=$lang PATH="$MOCKBIN:$ORIG_PATH" bash "$SCRIPT" --help 2>&1)"
        grep -Fq "$(UI_LANGUAGE=$lang; ui_t usage.one_click)" <<< "$out" || return 1
    done
    grep -Fq 'vpn-netguard.sh one-click' "$SCRIPT"
}

# --- 6.3: avisos previos de solo lectura (T230-T231) y D7: sin perfil VPN (T232) ---
T230() {
    oc_env
    local out snap
    foreign_vpn_scan() { echo s >> "$TEST_ROOT/seq"; FOREIGN_TUNNELS=("${OC_TUN[@]}"); FOREIGN_MARKS=(); FOREIGN_KS=("${OC_KS[@]}"); }
    detect_known_profiles() { echo k >> "$TEST_ROOT/seq"; }
    detect_active_state() { echo a >> "$TEST_ROOT/seq"; }
    pf() { out="$(one_click_preflight 2>&1)"; }
    local yield='NetGuard yields blocking to nordvpn while it stays active.'
    # Nada que decir: sin salida y sin código de error.
    pf && [[ -z "$out" ]] || return 1
    # Kill switch ajeno y sin forzado: NetGuard cede (una línea; con túnel ajeno también, el aviso es el del kill switch).
    OC_KS=(nordvpn); pf; [[ "$out" == "$yield" ]] || return 1
    OC_TUN=(nordlynx); pf; [[ "$out" == "$yield" ]] || return 1
    # Forzado OFF: do_activate lo retira, así que también cede. Si el perfil cambia a auto, strict actual da igual.
    printf 'off\n' > "$KILLSWITCH_OVERRIDE_FILE"; COEXIST_MODE=strict
    pf; [[ "$out" == "$yield" ]] || return 1
    COEXIST_MODE=auto
    # Forzado ON: no cede y recomienda la salida, nombrando al cliente.
    printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"; pf
    [[ "$(wc -l <<< "$out")" -eq 1 ]] && grep -Fq 'Recommended: killswitch auto.' <<< "$out" &&
        grep -Fq 'even though nordvpn is active' <<< "$out" || return 1
    rm -f "$KILLSWITCH_OVERRIDE_FILE"
    # Solo túneles ajenos, sin kill switch: se dejan pasar.
    OC_KS=(); OC_TUN=(tun7 wg0); pf
    [[ "$out" == 'Another VPN tunnel is active (tun7 wg0) without a kill switch: NetGuard lets it through.' ]] || return 1
    # Arranque automático: avisa solo con la unidad instalada y sin habilitar.
    OC_TUN=(); export EN_RC=1; pf
    [[ "$out" == 'The service vpn-netguard.service is installed but does not start on its own: run "systemctl enable vpn-netguard.service".' ]] || return 1
    EN_RC=0; pf; [[ -z "$out" ]] || return 1
    EN_RC=1; rm -f "$UNIT_DST"; pf; [[ -z "$out" ]] || return 1
    : > "$UNIT_DST"
    # Varios avisos: uno por línea, el de convivencia primero.
    OC_KS=(nordvpn); pf
    [[ "$(wc -l <<< "$out")" -eq 2 && "$(head -1 <<< "$out")" == "$yield" ]] && tail -1 <<< "$out" | grep -Fq 'systemctl enable' || return 1
    # Solo lectura: ni escribe ficheros ni ejecuta ningún paso, y detecta antes de escanear.
    snap="$(find "$TEST_ROOT" -type f ! -name seq -printf '%p %s %T@\n' | sort)"
    rm -f "$TEST_ROOT/seq"; pf
    [[ "$(find "$TEST_ROOT" -type f ! -name seq -printf '%p %s %T@\n' | sort)" == "$snap" && ! -s "$TEST_ROOT/calls" ]] || return 1
    [[ "$(tr -d '\n' < "$TEST_ROOT/seq")" == kas ]]
}

T231() {
    local out rc n_title n_a n_b n_bak
    # Sin nada que avisar no hay sección.
    oc_env
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && ! grep -Fq 'Pre-checks' <<< "$out" || return 1
    # Con avisos: sección con cada línea tras su título y antes de la copia de seguridad; los pasos y la salida no cambian.
    oc_env; OC_KS=(nordvpn); export EN_RC=1
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] || return 1
    n_title="$(grep -nF -- 'Pre-checks' <<< "$out" | head -1 | cut -d: -f1)"
    n_a="$(grep -nF -- '⚠ NetGuard yields blocking to nordvpn' <<< "$out" | head -1 | cut -d: -f1)"
    n_b="$(grep -nF -- '⚠ The service vpn-netguard.service is installed' <<< "$out" | head -1 | cut -d: -f1)"
    n_bak="$(grep -nF -- '✓ Configuration backup: ' <<< "$out" | head -1 | cut -d: -f1)"
    [[ -n "$n_title" && -n "$n_a" && -n "$n_b" && -n "$n_bak" ]] && (( n_title < n_a && n_a < n_b && n_b < n_bak )) || return 1
    [[ "$(<"$TEST_ROOT/calls")" == $'privacy rot=true\nactivate rot=true\nsystemctl restart vpn-netguard.service' ]] || return 1
    ! grep -Fq "$(ui_t oneclick.partial)" <<< "$out" && grep -Fq "$(ui_t panel.one_click_done)" <<< "$out" || return 1
    # Los avisos salen después de las comprobaciones que abortan: sin configuración o con una rechazada, no hay sección.
    oc_env; OC_KS=(nordvpn); export EN_RC=1; rm -f "$CONFIG_FILE"
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 1 ]] && ! grep -Fq 'Pre-checks' <<< "$out" || return 1
    cp "$TEST_ROOT/before.conf" "$CONFIG_FILE"; echo 'EVIL=1' >> "$CONFIG_FILE"
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 1 ]] && ! grep -Fq 'Pre-checks' <<< "$out" || return 1
    # Y antes de la copia: si la copia falla, los avisos ya se mostraron.
    oc_env; OC_KS=(nordvpn); mock install 'exit 1'
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 1 ]] && grep -Fq 'Pre-checks' <<< "$out" && grep -Fq 'Could not save the configuration backup' <<< "$out"
}

T232() {
    local out rc
    # La do_activate REAL devuelve 0 sin perfil VPN (solo marca la protección como deseada): 1-click lo trata como fallo y da la razón.
    new_env
    UI_LANGUAGE=en; ui_init
    reconcile_sync() { echo reconcile >> "$TEST_ROOT/calls"; return "${REC_RC:-0}"; }
    local -a prof=() ign=()
    detect_known_profiles() { KNOWN_VPN=("${prof[@]}"); IGNORED_VPN=("${ign[@]}"); }
    out="$(do_activate 2>&1)" || return 1   # el comportamiento que motiva D7
    out="$(one_click_activate 2>&1)"; rc=$?
    [[ $rc -eq 1 ]] && grep -Fq 'First add a VPN connection' <<< "$out" || return 1
    ign=(other-vpn)
    out="$(one_click_activate 2>&1)"; rc=$?
    [[ $rc -eq 1 ]] && grep -Fq 'VPN_IGNORE' <<< "$out" || return 1
    ign=(); prof=(office)
    out="$(one_click_activate 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] || return 1
    REC_RC=1
    out="$(one_click_activate 2>&1)"; rc=$?
    [[ $rc -eq 1 ]] || return 1
    # En el flujo: ✗ con la razón sangrada, sin «activada», salida 2, y el reinicio del servicio se ejecuta igual.
    oc_env; ACT_VPN=""
    out="$(cmd_one_click 2>&1)"; rc=$?
    [[ $rc -eq 2 ]] && grep -Fq '✗ Could not enable VPN protection' <<< "$out" && grep -Fq '    activate-log' <<< "$out" &&
        ! grep -Fq '✓ VPN protection enabled' <<< "$out" || return 1
    grep -Fq "$(ui_t oneclick.partial)" <<< "$out" && ! grep -Fq "$(ui_t panel.one_click_done)" <<< "$out" || return 1
    grep -q '^systemctl restart' "$TEST_ROOT/calls" && grep -q '^ROTATE_MAC_PER_BOOT=true$' "$CONFIG_FILE"
}

# --- 6.4: menú de texto y panel llaman al subcomando one-click (una sola elevación) ---
T233() {
    new_env
    UI_LANGUAGE=en; ui_init
    unset SSH_CONNECTION SSH_TTY
    local ans=y out exp
    pause_enter() { :; }
    menu_confirm() { printf '%s' "$1" > "$TEST_ROOT/asked"; [[ "$ans" == y ]]; }
    menu_elevate() { echo "elevate $*" >> "$TEST_ROOT/calls"; return "${EL_RC:-0}"; }
    panel_write_config_keys() { echo write-config >> "$TEST_ROOT/calls"; }
    : > "$TEST_ROOT/calls"
    # Confirma con el texto normal y delega: una sola elevación del subcomando, sin escribir la
    # configuración ni llamar a los pasos por separado (antes eran cuatro contraseñas).
    out="$(menu_action_one_click 2>&1)" || return 1
    [[ "$(<"$TEST_ROOT/calls")" == "elevate bash $SELF one-click" && "$(<"$TEST_ROOT/asked")" == "$(ui_t panel.one_click_confirm)" ]] || return 1
    grep -Fq "$(ui_t action_ok)" <<< "$out" || return 1
    # Salida 2 (perfil guardado, un paso falló): sigue siendo una sola elevación y se informa del código.
    EL_RC=2; : > "$TEST_ROOT/calls"
    out="$(menu_action_one_click 2>&1)"
    printf -v exp -- "$(ui_t action_failed)" 2
    [[ "$(wc -l < "$TEST_ROOT/calls")" -eq 1 ]] && grep -Fq "$exp" <<< "$out" || return 1
    EL_RC=0
    # Sin confirmar no se ejecuta nada.
    ans=n; : > "$TEST_ROOT/calls"
    menu_action_one_click >/dev/null 2>&1; [[ ! -s "$TEST_ROOT/calls" ]] || return 1
    # Por SSH la confirmación es la reforzada.
    ans=y; SSH_CONNECTION="1 2 3 4"
    menu_action_one_click >/dev/null 2>&1
    [[ "$(<"$TEST_ROOT/asked")" == "$(ui_t panel.one_click_confirm_ssh)" ]] || return 1
    unset SSH_CONNECTION
    # Sin configuración: avisa antes de preguntar y no eleva (así no pide contraseña para nada).
    rm -f "$CONFIG_FILE" "$TEST_ROOT/asked"; : > "$TEST_ROOT/calls"
    out="$(menu_action_one_click 2>&1)"
    printf -v exp -- "$(ui_t config.install_first)" "$CONFIG_FILE"
    [[ ! -s "$TEST_ROOT/calls" && ! -e "$TEST_ROOT/asked" ]] && grep -Fq "$exp" <<< "$out"
}

T234() {
    new_env
    UI_LANGUAGE=en; ui_init
    unset SSH_CONNECTION SSH_TTY
    export PK_RC=0 ZQ=y CONFIG_FILE   # el mock de pkexec es un proceso aparte: necesita la ruta
    local before msg
    mkdir -p "${BIN_DST%/*}"; : > "$BIN_DST"
    : > "$TEST_ROOT/calls"; : > "$TEST_ROOT/zlog"
    mock pkexec 'echo "pkexec $*" >> "$TEST_ROOT/calls"; sed -i "s/^MAC_MODE=.*/MAC_MODE=\"random\"/" "$CONFIG_FILE"; echo one-click-output; exit "$PK_RC"'
    zenity_ui() {
        local kind="" a
        for a in "$@"; do
            case "$a" in
                --question|--text-info|--error|--info) kind="$a" ;;
                --text=*) printf '%s' "${a#--text=}" > "$TEST_ROOT/ztext" ;;   # texto completo (puede llevar saltos de línea)
            esac
        done
        echo "$kind" >> "$TEST_ROOT/zlog"
        case "$kind" in
            --text-info) cat > "$TEST_ROOT/zin" ;;
            --question)  [[ "$ZQ" == y ]]; return ;;
        esac
        return 0
    }
    reset() { : > "$TEST_ROOT/calls"; : > "$TEST_ROOT/zlog"; rm -f "$TEST_ROOT/zin" "$TEST_ROOT/ztext"; base_config; load_config >/dev/null 2>&1; }
    # Confirma y hace UNA llamada a pkexec con el subcomando; muestra el resumen y recarga la configuración
    # que root acaba de guardar. El panel no escribe nada por su cuenta.
    reset; panel_action_one_click
    [[ "$(<"$TEST_ROOT/calls")" == "pkexec $BIN_DST one-click" && "$(tr '\n' ' ' < "$TEST_ROOT/zlog")" == "--question --text-info " ]] || return 1
    grep -Fxq one-click-output "$TEST_ROOT/zin" && [[ "$MAC_MODE" == random ]] || return 1
    [[ "$(<"$TEST_ROOT/ztext")" == "$(ui_t panel.one_click_confirm)" ]] || return 1
    # Salidas 1 y 2 (nada guardado / paso fallido) también son resumen, no caja de error.
    for PK_RC in 1 2; do
        export PK_RC; reset; panel_action_one_click
        [[ "$(tr '\n' ' ' < "$TEST_ROOT/zlog")" == "--question --text-info " ]] && grep -Fxq one-click-output "$TEST_ROOT/zin" || return 1
    done
    # 126 y 127 (pkexec cancelado o sin autorización): caja de error con la orden y la salida; sin resumen.
    for PK_RC in 126 127; do
        export PK_RC; reset; panel_action_one_click
        [[ "$(tr '\n' ' ' < "$TEST_ROOT/zlog")" == "--question --error " ]] || return 1
        printf -v msg -- "$(ui_t panel.fail)" "$BIN_DST one-click" "one-click-output"
        [[ "$(<"$TEST_ROOT/ztext")" == "$msg" ]] || return 1
    done
    export PK_RC=0
    # Sin confirmar no se llama a pkexec.
    export ZQ=n; reset; before="$(<"$CONFIG_FILE")"
    panel_action_one_click
    [[ ! -s "$TEST_ROOT/calls" && "$(<"$CONFIG_FILE")" == "$before" && "$(tr '\n' ' ' < "$TEST_ROOT/zlog")" == "--question " ]] || return 1
    # Por SSH la confirmación es la reforzada.
    export ZQ=y; reset; SSH_CONNECTION="1 2 3 4"
    panel_action_one_click
    [[ "$(<"$TEST_ROOT/ztext")" == "$(ui_t panel.one_click_confirm_ssh)" ]] || return 1
    unset SSH_CONNECTION
    # Sin configuración: caja de error y ni pregunta ni pkexec.
    reset; rm -f "$CONFIG_FILE"
    panel_action_one_click
    [[ ! -s "$TEST_ROOT/calls" && "$(tr '\n' ' ' < "$TEST_ROOT/zlog")" == "--error " ]]
}

# 7.2: la configuración por defecto ya no manda reiniciar el servicio (el demonio
# relee el fichero desde 1.5) y dice cómo aplicar el anonimato de red.
T235() {
    new_env
    local def
    def="$(write_default_config)"
    ! grep -Eiq 'reinicia el servicio|systemctl restart' <<< "$def" &&
    grep -Fq 'no hace falta reiniciarlo' <<< "$def" &&
    grep -Fq 'vpn-netguard.sh apply-privacy' <<< "$def"
}

# El despacho, la ayuda (es y en) y la cabecera del script listan los mismos subcomandos.
T237() {
    new_env
    local name lang out
    local -a cmds
    mapfile -t cmds < <(awk '/^case "\$CMD" in$/ {f=1; next} f && /^esac$/ {exit}
        f && match($0, /^    [a-z][-a-z]*[|)]/) {print substr($0, RSTART + 4, RLENGTH - 5)}' "$SCRIPT")
    (( ${#cmds[@]} >= 22 )) || return 1
    for lang in es en; do
        out="$(VPN_NETGUARD_LANGUAGE=$lang PATH="$MOCKBIN:$ORIG_PATH" bash "$SCRIPT" --help 2>&1)"
        for name in "${cmds[@]}"; do
            grep -Eq "^ +$name( |$)" <<< "$out" || { echo "ayuda ($lang) sin $name" >&2; return 1; }
        done
    done
    for name in "${cmds[@]}"; do
        grep -Eq "^#   vpn-netguard\.sh +$name( |$)" "$SCRIPT" || { echo "cabecera sin $name" >&2; return 1; }
    done
}

# doctor revisa también la convivencia con otros VPN: su ayuda, su descripción en el
# panel y la cabecera del script la nombran. La palabra sale del título de la sección
# en cada idioma; la cabecera está en inglés.
T243() {
    new_env
    local lang title word word_en=""
    for lang in es en; do
        UI_LANGUAGE="$lang"; ui_init
        title="$(ui_t doctor.coexist)"
        word="${title#-- }"; word="${word%% *}"
        [[ "$lang" == en ]] && word_en="$word"
        grep -Fiq -- "$word" <<< "$(ui_t usage.doctor)" || { echo "usage.doctor ($lang) sin «$word»" >&2; return 1; }
        grep -Fiq -- "$word" <<< "$(ui_t menu.desc_doctor)" || { echo "menu.desc_doctor ($lang) sin «$word»" >&2; return 1; }
    done
    [[ -n "$word_en" ]] || return 1
    grep -Eiq -- "^#   vpn-netguard\.sh +doctor .*$word_en" "$SCRIPT" || { echo "cabecera: doctor sin «$word_en»" >&2; return 1; }
}

# 8.1-8.2 (D9): un guardado rechazado dice por qué. panel_write_config_keys deja el motivo en
# CONFIG_WRITE_ERROR y en stderr, sin tocar el fichero ni elevar; un guardado correcto o un fallo
# de la elevación (sin motivo propio) no arrastran el anterior.
T244() {
    new_env
    UI_LANGUAGE=en; ui_init
    menu_elevate() { echo "elevate $*" >> "$TEST_ROOT/calls"; cp -- "${@: -2:1}" "${@: -1}"; }
    : > "$TEST_ROOT/calls"
    local before exp long rc lang
    # Configuración actual rechazada (clave ajena): el motivo nombra el fichero.
    printf 'NOT_A_KEY=1\n' >> "$CONFIG_FILE"
    before="$(cksum < "$CONFIG_FILE")"
    panel_write_config_keys LANGUAGE=en 2> "$TEST_ROOT/err"; rc=$?
    printf -v exp -- "$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
    [[ $rc -eq 1 && "$CONFIG_WRITE_ERROR" == "$exp" && "$(<"$TEST_ROOT/err")" == "$exp" && "$exp" == *"$CONFIG_FILE"* ]] || return 1
    [[ "$(cksum < "$CONFIG_FILE")" == "$before" && ! -s "$TEST_ROOT/calls" ]] || return 1

    # Valor demasiado largo: 600 '*' ocupan 1200 con las barras de %q. Nombra la clave que lo causa (la
    # segunda, no la primera) y la cifra real.
    base_config
    printf -v long '%600s' ''; long="${long// /*}"
    before="$(cksum < "$CONFIG_FILE")"
    panel_write_config_keys LANGUAGE=en VPN_IGNORE="$long" 2> "$TEST_ROOT/err"; rc=$?
    printf -v exp -- "$(ui_t config.write_too_long)" VPN_IGNORE 1200 1024
    [[ $rc -eq 1 && "$CONFIG_WRITE_ERROR" == "$exp" && "$(<"$TEST_ROOT/err")" == "$exp" ]] || return 1
    [[ "$exp" == *VPN_IGNORE*1200*1024* && "$(cksum < "$CONFIG_FILE")" == "$before" && ! -s "$TEST_ROOT/calls" ]] || return 1
    for lang in es en; do   # el motivo sale en ambos idiomas, con las mismas cifras
        UI_LANGUAGE=$lang; ui_init
        panel_write_config_keys VPN_IGNORE="$long" 2>/dev/null
        [[ "$CONFIG_WRITE_ERROR" == *VPN_IGNORE*1200*1024* ]] || return 1
        [[ "$lang" == es ]] && exp="$CONFIG_WRITE_ERROR"
    done
    [[ "$CONFIG_WRITE_ERROR" != "$exp" ]] || return 1
    # Límite exacto: 512 '*' son 1024 y se guardan; 513 son 1026 y no.
    printf -v long '%513s' ''; long="${long// /*}"
    ! panel_write_config_keys VPN_IGNORE="$long" 2>/dev/null && [[ "$CONFIG_WRITE_ERROR" == *1026* ]] || return 1
    printf -v long '%512s' ''; long="${long// /*}"
    panel_write_config_keys VPN_IGNORE="$long" 2>/dev/null &&
        [[ -z "$CONFIG_WRITE_ERROR" && "$(panel_get_val VPN_IGNORE)" == "$long" ]] || return 1

    # Contenido no admitido (clave fuera de la lista blanca): rechazo general.
    before="$(cksum < "$CONFIG_FILE")"
    panel_write_config_keys NOT_A_KEY=1 2> "$TEST_ROOT/err"; rc=$?
    [[ $rc -eq 1 && "$CONFIG_WRITE_ERROR" == "$(ui_t config.write_rejected)" && "$(<"$TEST_ROOT/err")" == "$CONFIG_WRITE_ERROR" ]] || return 1
    [[ "$(cksum < "$CONFIG_FILE")" == "$before" ]] || return 1

    # Un guardado correcto borra el motivo anterior; si falla la elevación no hay motivo propio y tampoco queda el viejo.
    panel_write_config_keys LANGUAGE=en 2>/dev/null && [[ -z "$CONFIG_WRITE_ERROR" ]] || return 1
    CONFIG_WRITE_ERROR="old reason"
    menu_elevate() { return 1; }
    ! panel_write_config_keys LANGUAGE=es 2>/dev/null && [[ -z "$CONFIG_WRITE_ERROR" ]]
}

# 8.3: los cuatro diálogos del panel que guardan configuración ponen el motivo del rechazo bajo el
# texto general, escapado para Pango (la ruta del fichero lleva & < >); sin motivo, solo el texto
# general. El menú de texto lo muestra por stderr.
T245() {
    new_env
    CONFIG_FILE="$TEST_ROOT/a&b<c>.conf"
    UI_LANGUAGE=en; ui_init
    PANEL_LABEL=""; PANEL_WANT=""
    zenity_ui() {
        local a kind="" out="" sep="" lbl
        for a in "$@"; do
            case "$a" in --forms|--error|--info|--question) kind="$a" ;; esac
        done
        echo "$kind" >> "$TEST_ROOT/zlog"
        [[ "$kind" == --error ]] && for a in "$@"; do
            [[ "$a" == --text=* ]] && printf '%s' "${a#--text=}" > "$TEST_ROOT/ztext"
        done
        [[ "$kind" == --forms ]] || return 0
        for a in "$@"; do
            case "$a" in
                --add-entry=*|--add-combo=*)
                    lbl="${a#*=}"; lbl="${lbl%%$'\n'*}"
                    [[ "$lbl" == "$PANEL_LABEL" || "$lbl" == "$PANEL_LABEL ("* ]] && out+="$sep$PANEL_WANT" || out+="$sep"
                    sep='|' ;;
            esac
        done
        printf '%s\n' "$out"
    }
    panel_info_box() { echo info >> "$TEST_ROOT/zlog"; }
    local pair fn key reason exp txt long
    reset() { : > "$TEST_ROOT/zlog"; rm -f "$TEST_ROOT/ztext"; base_config; }

    # Configuración actual rechazada: cada diálogo muestra su texto general y debajo el motivo escapado.
    # El de idioma y el de anonimato solo guardan si algo cambia: reciben un valor distinto del actual.
    for pair in panel_action_change_language:panel.config_save_fail panel_action_configure:panel.config_save_fail \
                panel_action_configure_privacy:panel.privacy_save_fail panel_action_configure_monitoring:panel.monitor_save_fail; do
        fn="${pair%%:*}"; key="${pair#*:}"
        PANEL_LABEL="$(ui_field_label LANGUAGE)"; PANEL_WANT=en
        [[ "$fn" == panel_action_configure_privacy ]] && { PANEL_LABEL="$(ui_field_label DHCP_HOSTNAME_OVERRIDE)"; PANEL_WANT=equipo; }
        reset; printf 'NOT_A_KEY=1\n' >> "$CONFIG_FILE"
        "$fn" >/dev/null 2>&1
        [[ "$(tr '\n' ' ' < "$TEST_ROOT/zlog")" == "--forms --error " ]] || { echo "$fn: no acaba en una caja de error" >&2; return 1; }
        txt="$(<"$TEST_ROOT/ztext")"
        printf -v reason -- "$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
        exp="$(ui_t "$key")\n\n$(pango_escape "$reason")"
        [[ "$txt" == "$exp" && "$txt" == *'a&amp;b&lt;c&gt;.conf'* && "$txt" != *'b<c>'* ]] || { echo "$fn: texto inesperado: $txt" >&2; return 1; }
    done

    # Valor demasiado largo desde el formulario general y desde el de anonimato: clave y cifra reales.
    printf -v long '%600s' ''; long="${long// /*}"
    for pair in "panel_action_configure:VPN_IGNORE:panel.config_save_fail" "panel_action_configure_privacy:DHCP_HOSTNAME_OVERRIDE:panel.privacy_save_fail"; do
        IFS=: read -r fn key exp <<< "$pair"
        reset; PANEL_LABEL="$(ui_field_label "$key")"; PANEL_WANT="$long"
        "$fn" >/dev/null 2>&1
        printf -v reason -- "$(ui_t config.write_too_long)" "$key" 1200 1024
        [[ "$(<"$TEST_ROOT/ztext")" == "$(ui_t "$exp")\n\n$(pango_escape "$reason")" ]] || { echo "$fn: motivo de longitud inesperado" >&2; return 1; }
    done

    # Sin motivo propio (falla la elevación): solo el texto general, sin saltos de línea sobrantes.
    reset; menu_elevate() { return 1; }
    PANEL_LABEL="$(ui_field_label LANGUAGE)"; PANEL_WANT=es
    panel_action_change_language >/dev/null 2>&1
    [[ "$(<"$TEST_ROOT/ztext")" == "$(ui_t panel.config_save_fail)" ]] || return 1

    # Menú de texto: el motivo sale por stderr junto al aviso de que se conservan los cambios.
    unset -f menu_elevate
    pause_enter() { :; }
    reset; printf 'NOT_A_KEY=1\n' >> "$CONFIG_FILE"
    local -A chg=([LANGUAGE]=en)
    local out rc=0
    out="$(menu_save_config_changes chg 2>&1 >/dev/null)" || rc=$?
    printf -v reason -- "$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
    [[ $rc -eq 1 ]] && grep -Fq -- "$reason" <<< "$out" && grep -Fq -- "$(ui_t menu.save_failed)" <<< "$out"
}

# --- Fase 9.1: nmcli en UTF-8 (nombres con tilde) ---
# El mock se comporta como el nmcli real (1.46, comprobado): si el locale de quien
# lo llama no es UTF-8 cambia por '?' cada carácter no ASCII, y un nombre así ya no
# existe como perfil.
nmcli_utf8_mock() {
    cat > "$MOCKBIN/nmcli" <<'EOF'
#!/usr/bin/env bash
caller="${LC_ALL:-}"
printf '%s|%s\n' "$caller" "${LANGUAGE:-}" >> "$TEST_ROOT/nmcli.env"
LC_ALL=C.UTF-8
out() { case "$caller" in *UTF-8*|*utf8*) printf '%s\n' "$1" ;; *) printf '%s\n' "${1//[!A-Za-z0-9 :._-]/?}" ;; esac; }
exists() { [[ "$1" == "Conexión cableada 1" || "$1" == "Oficina Málaga" ]] || { echo "Error: $1 - no such connection profile." >&2; exit 10; }; }
case "$*" in
    "-t -e yes -f NAME,TYPE connection show") out "Conexión cableada 1:802-3-ethernet"; out "Oficina Málaga:vpn" ;;
    "-t -e yes -f NAME,TYPE,DEVICE connection show --active") out "Conexión cableada 1:802-3-ethernet:enp0s3"; out "Oficina Málaga:vpn:tun0" ;;
    "-t -e yes -f NAME,TYPE connection show --active") out "Conexión cableada 1:802-3-ethernet"; out "Oficina Málaga:vpn" ;;
    "-g ethernet.cloned-mac-address connection show "*) exists "${*:5}"; echo stable ;;
    "-g ipv6.ip6-privacy connection show "*) exists "${*:5}"; echo 2 ;;
    "-g ipv4.dhcp-send-hostname connection show "*) exists "${*:5}"; echo no ;;
    "connection up "*) exists "${*:3}" ;;
esac
exit 0
EOF
    chmod +x "$MOCKBIN/nmcli"; hash -r
}

T246() {
    new_env
    nmcli_utf8_mock
    UI_LANGUAGE=es; ui_init
    export LANGUAGE=es   # un LANGUAGE del entorno no debe traducir los mensajes de nmcli
    local out
    # El mock es fiel: con LC_ALL=C hace justo lo que se veía en pantalla.
    [[ "$(LC_ALL=C nmcli -t -e yes -f NAME,TYPE connection show | head -1)" == 'Conexi?n cableada 1:802-3-ethernet' ]] || return 1
    rm -f "$TEST_ROOT/nmcli.env"
    detect_known_profiles; detect_active_state
    [[ "${KNOWN_ETH[*]}" == 'Conexión cableada 1' && "${KNOWN_VPN[*]}" == 'Oficina Málaga' &&
       "$ACTIVE_ETH" == 'Conexión cableada 1' && "$ACTIVE_VPN" == 'Oficina Málaga' && "$PHYS_IFACE" == enp0s3 ]] || return 1
    # «Ver estado del anonimato»: el nombre sale entero y se pudo volver a consultar el perfil.
    out="$(print_privacy_status)"
    grep -Fxq '  Red activa            Conexión cableada 1 (enp0s3)' <<< "$out" && [[ "$out" != *'?'* ]] || return 1
    grep -Fxq '  MAC del perfil        stable' <<< "$out" || return 1
    # Reconectar y la cabecera del menú usan el mismo nombre, también con tilde.
    nmcli_up 'Oficina Málaga' && [[ "$(menu_active_vpn_name)" == 'Oficina Málaga' ]] || return 1
    # Ninguna llamada a nmcli salió con otro entorno que no sea C.UTF-8 + LANGUAGE=C.
    [[ -s "$TEST_ROOT/nmcli.env" && "$(sort -u "$TEST_ROOT/nmcli.env" | tr '\n' ' ')" == 'C.UTF-8|C ' ]]
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
run_test 'every literal ui_t key and menu label key has es and en text' T162
run_test 'config_file_is_safe rejects CRLF line endings' T163
run_test 'killswitch rejects unknown actions without touching the firewall' T164
run_test 'killswitch on forces blocking or allows the tunnel' T165
run_test 'killswitch off removes rules and auto restores the configured mode' T166
run_test 'killswitch auto clears override and boot-race marker and follows mode' T167
run_test 'killswitch keeps override consistent when firewall changes fail' T168
run_test 'killswitch subcommand and aliases are exposed by the CLI' T169
run_test 'killswitch status shows forced state and rule/policy mismatch' T170
run_test 'general status reuses the kill switch section with forced state' T171
run_test 'text kill switch submenu maps each choice to one killswitch action' T172
run_test 'graphical kill switch submenu maps each choice to one killswitch action' T173
run_test 'user-facing texts recommend killswitch, not the legacy aliases' T174
run_test 'activate keeps a forced kill switch on and clears a forced off' T175
run_test 'text VPN protection submenu maps each choice to activate or deactivate' T176
run_test 'graphical VPN protection submenu maps each choice to activate or deactivate' T177
run_test 'VPN protection labels do not name the kill switch except to explain effects' T178
run_test 'text network privacy submenu maps each choice and keeps the apply confirmation' T179
run_test 'graphical network privacy settings open Configure directly; the extra button shows the status and reopens' T180
run_test 'applying network privacy asks for confirmation, reinforced under SSH' T181
run_test 'config reload tracks the file signature and ignores unchanged files' T182
run_test 'config reload keeps the running config on missing or unsafe files' T183
run_test 'periodic loop reloads the config before reconciling and honors a new interval' T184
run_test 'network event loop reloads the config silently before reconciling' T185
run_test 'saving or importing config tells the service reloads it, with no restart prompt' T186
run_test 'graphical config import confirms once and does not restart the service' T187
run_test 'menu model gives terminal and panel the same sequential numbers and translated labels' T188
run_test 'every menu entry dispatches to one handler and numbers pick the right entry' T189
run_test 'status summary reports service, protection, VPN and kill switch without root' T190
run_test 'panel list has number, action and description columns, a status header and Open/Exit buttons' T191
run_test 'menu descriptions and status labels exist in es and en, and Pango data is escaped' T192
run_test 'state files the panel header reads stay world-readable under a strict umask' T193
run_test 'terminal header shows the shared status lines, aligned, with color only on a tty' T194
run_test 'kill-switch exceptions are RETURN, never ACCEPT, and the final DROP stays last' T196
run_test 'ensure_chain does not write when the jump is already first and unique' T197
run_test 'ensure_chain inserts an absent jump first and keeps foreign rule order' T198
run_test 'jump repair without a transaction inserts before deleting and spares foreign rules' T199
run_test 'IPv6 jump repair uses ip6tables and survives an unreadable OUTPUT' T200
run_test 'foreign scan lists active tunnels NetworkManager does not manage' T201
run_test 'foreign scan detects the NordVPN kill switch from its tagged DROP rules' T202
run_test 'foreign scan detects the ProtonVPN kill switch from its dummy connections' T203
run_test 'foreign scan only reads: no firewall or connection writes' T204
run_test 'COEXIST_MODE is a documented, validated key offered by both config menus' T205
run_test 'foreign tunnels and marks pass with RETURN only in auto, invalid entries are dropped' T206
run_test 'the foreign scan runs before every policy decision and not at all in strict' T207
run_test 'a foreign kill switch turns blocking off only in the automatic policy' T208
run_test 'the yield state file changes and notifies only on entering, changing or leaving' T209
run_test 'every policy decision syncs the yield and yielding removes the own blocking' T210
run_test 'yielding does not send the kill switch disabled notice' T211
run_test 'status, check and menus read the yield without scanning' T212
run_test 'status coexistence section reads live, recommends and leaves FOREIGN_* untouched' T213
run_test 'doctor includes the coexistence section and its recommendations raise the result' T214
run_test 'VPN_IGNORE is a documented, limited key with labels and free-text patterns' T215
run_test 'both config menus save VPN_IGNORE: keep, write with globs and commas, clear' T216
run_test 'VPN_IGNORE moves matching NetworkManager profiles out of KNOWN_VPN, and VPN_CONNECTION wins' T217
run_test 'blocking exempts the endpoints of own and ignored VPN profiles' T218
run_test 'a zombie tunnel on an ignored VPN is neither brought down nor reconnected' T219
run_test 'deactivate keeps an ignored VPN and activate explains when all profiles are ignored' T220
run_test 'status lists ignored VPN profiles apart from the managed ones' T221
run_test 'early boot blocking lets visible foreign clients through without asking NetworkManager' T222
run_test 'boot blocking drops the yield inherited from the previous session' T223
run_test 'the 1-click profile is the balanced and compatible one and its texts describe it' T224
run_test 'the config backup leaves no empty file when it fails and import-config cancels without it' T225
run_test 'one-click backs up, saves the profile, applies each step in order and keeps the summary clean' T226
run_test 'one-click changes nothing without a usable configuration, a backup or a saved profile' T227
run_test 'one-click runs every step, shows the failed one and exits 2; a missing service unit is only skipped' T228
run_test 'one-click is a root subcommand listed in the help and the script header' T229
run_test 'one-click pre-checks are read-only and give one line per warning (yield, forced ON, tunnel, autostart)' T230
run_test 'one-click shows the pre-checks after the aborting checks and before the backup, without changing steps or exit code' T231
run_test 'one-click treats a missing VPN profile as a failed step with its reason and exit 2 (D7)' T232
run_test 'text menu 1-click confirms once and delegates to the one-click subcommand with a single elevation' T233
run_test 'panel 1-click confirms, runs one pkexec one-click and shows its summary; only an elevation failure is an error box' T234
run_test 'the default config says the service applies changes by itself and names apply-privacy for the privacy settings' T235
run_test 'the dispatcher, the help (es and en) and the script header list the same subcommands' T237
run_test 'doctor help, panel description and script header name its coexistence section' T243
run_test 'a rejected config save says why (current file, value too long, disallowed content) and leaves nothing stale (D9)' T244
run_test 'the four panel save dialogs show the escaped reason under their message; the text menu shows it on stderr' T245
# --- Fase 9 (punto 8 de la revisión de uso): carpeta de métricas con el selector de zenity ---
# El diálogo de monitorización ya no pide la ruta escrita: un combo (mantener / elegir / quitar) y,
# solo al elegir, un selector de carpetas. Cancelar el selector no guarda nada.
T247() {
    new_env
    UI_LANGUAGE=en; ui_init
    menu_elevate() { if [[ "$1" == install ]]; then cp -- "${@: -2:1}" "${@: -1}"; else "$@"; fi; }
    panel_info_box() { echo info >> "$TEST_ROOT/box"; }
    panel_error_box() { echo error >> "$TEST_ROOT/box"; }
    PANEL_FORM=""; PANEL_PICK=""
    zenity_ui() {
        local a kind=""
        for a in "$@"; do case "$a" in --forms|--file-selection) kind="$a" ;; esac; done
        printf '%s\n' "$*" >> "$TEST_ROOT/zargs"
        case "$kind" in
            --forms) printf '%s\n' "$PANEL_FORM" ;;
            --file-selection) printf '%s' "$PANEL_PICK" ; [[ -n "$PANEL_PICK" ]] && echo || return 1 ;;
        esac
    }
    reset() {
        : > "$TEST_ROOT/zargs"; : > "$TEST_ROOT/box"
        printf 'LANGUAGE="en"\nEVENT_HISTORY_ENABLE="true"\nEVENT_HISTORY_MAX_LINES=5000\nPROMETHEUS_TEXTFILE_DIR=%q\n' "$1" > "$CONFIG_FILE"
    }
    local keep_old='Keep (/srv/old)' choose='Choose folder...' clear='Remove (no metrics)' args

    # Mantener: no se abre el selector, el resto del formulario sí se guarda.
    reset /srv/old; PANEL_FORM="false|$keep_old|7000"
    panel_action_configure_monitoring >/dev/null 2>&1
    [[ "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" == /srv/old && "$(panel_get_val EVENT_HISTORY_ENABLE)" == false &&
       "$(panel_get_val EVENT_HISTORY_MAX_LINES)" == 7000 ]] || { echo "mantener: valores inesperados" >&2; return 1; }
    ! grep -q -- '--file-selection' "$TEST_ROOT/zargs" && grep -qx info "$TEST_ROOT/box" || { echo "mantener: no debía abrir el selector" >&2; return 1; }

    # Elegir: selector de carpetas (--directory) que parte de la carpeta actual; se guarda sin la barra final.
    reset /srv/old; PANEL_FORM="true|$choose|"; PANEL_PICK=/srv/new/
    panel_action_configure_monitoring >/dev/null 2>&1
    [[ "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" == /srv/new ]] || { echo "elegir: no guardó la carpeta" >&2; return 1; }
    args="$(grep -- '--file-selection' "$TEST_ROOT/zargs")"
    [[ "$(grep -c -- '--file-selection' "$TEST_ROOT/zargs")" -eq 1 && "$args" == *' --directory '* && "$args" == *'--filename=/srv/old/'* &&
       "$args" != *' --save'* ]] || { echo "elegir: argumentos del selector: $args" >&2; return 1; }
    # Una carpeta con espacios y símbolos llega intacta y el fichero sigue siendo aceptado.
    reset ""; PANEL_FORM="true|$choose|"; PANEL_PICK='/home/ana/My Metrics & Co'
    panel_action_configure_monitoring >/dev/null 2>&1
    [[ "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" == '/home/ana/My Metrics & Co' ]] && config_file_is_safe "$CONFIG_FILE" || return 1
    # Sin carpeta actual el selector parte de la carpeta personal.
    [[ "$(grep -- '--file-selection' "$TEST_ROOT/zargs")" == *"--filename=$HOME/"* ]] || return 1
    # La raíz no se queda vacía al quitar la barra final.
    reset /srv/old; PANEL_FORM="true|$choose|"; PANEL_PICK=/
    panel_action_configure_monitoring >/dev/null 2>&1
    [[ "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" == / ]] || return 1

    # Selector cancelado: no se guarda nada, ni lo demás del formulario, y no hay aviso de éxito.
    reset /srv/old; PANEL_FORM="false|$choose|9"; PANEL_PICK=""
    panel_action_configure_monitoring >/dev/null 2>&1
    [[ "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" == /srv/old && "$(panel_get_val EVENT_HISTORY_ENABLE)" == true &&
       "$(panel_get_val EVENT_HISTORY_MAX_LINES)" == 5000 && ! -s "$TEST_ROOT/box" ]] || { echo "cancelar: se guardó algo" >&2; return 1; }

    # Quitar: vacía la carpeta, sin abrir el selector.
    reset /srv/old; PANEL_FORM="true|$clear|"
    panel_action_configure_monitoring >/dev/null 2>&1
    [[ -z "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" ]] && ! grep -q -- '--file-selection' "$TEST_ROOT/zargs" || return 1

    # Las opciones del combo: con carpeta, las tres; sin carpeta, "quitar" no se ofrece.
    reset /srv/old; PANEL_FORM="true|$keep_old|"
    panel_action_configure_monitoring >/dev/null 2>&1
    grep -Fq -- "--combo-values=$keep_old|$choose|$clear" "$TEST_ROOT/zargs" || { echo "combo con carpeta" >&2; return 1; }
    reset ""; PANEL_FORM="true|Keep (none)|"
    panel_action_configure_monitoring >/dev/null 2>&1
    grep -Fq -- '--combo-values=Keep (none)|Choose folder... ' "$TEST_ROOT/zargs" && ! grep -Fq "$clear" "$TEST_ROOT/zargs" || { echo "combo sin carpeta" >&2; return 1; }
    # Una carpeta actual con "|" (separador de los valores del combo) se muestra con "¦" y se conserva.
    reset '/srv/a|b'; PANEL_FORM="true|Keep (/srv/a¦b)|"
    panel_action_configure_monitoring >/dev/null 2>&1
    grep -Fq -- '--combo-values=Keep (/srv/a¦b)|Choose folder...|' "$TEST_ROOT/zargs" &&
    [[ "$(panel_get_val PROMETHEUS_TEXTFILE_DIR)" == '/srv/a|b' ]] || { echo "carpeta con barra vertical" >&2; return 1; }
    # Ya no hay campo de texto para la ruta: solo queda el del máximo de líneas.
    [[ "$(grep -o -- '--add-entry=' "$TEST_ROOT/zargs" | wc -l)" -eq 1 ]]
}

# --- Fase 9.2 (punto 5 de la revisión de uso): presentación de «Ver estado actual» ---
# Cabecera «VPN NetGuard · …», seis secciones (9.3 añadió la del anonimato), etiquetas en columna fija y 64 columnas, igual en
# locale C (pkexec arranca sin LANG) que en UTF-8, con acentos en etiquetas y valores.
T248() {
    new_env
    nmcli_utf8_mock
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock ping 'exit 1'
    HAVE_IP6TABLES=0
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    EVENT_HISTORY_FILE=/var/lib/vpn-netguard/history.csv   # ruta corta: la de TMP no debe decidir el ancho
    require_root() { :; }
    local ui loc out out_c rule line title ks_title sections eth phys prof warn n
    printf -v rule '%64s' ''; rule="${rule// /═}"
    for ui in es en; do
        UI_LANGUAGE="$ui"; ui_init
        if [[ "$ui" == es ]]; then
            title='  VPN NetGuard · Estado actual'; ks_title='  VPN NetGuard · Estado del kill switch'
            sections='── Red|── Kill switch|── Convivencia con otros VPN|── Anonimato de red|── Conectividad|── Alertas y monitorización|'
            eth='  Ethernet activa       Conexión cableada 1'; phys='  Interfaz física       enp0s3'
            prof='  Perfiles Ethernet     Conexión cableada 1'; warn='  Reglas IPv4           ⚠ inactivas'
        else
            title='  VPN NetGuard · Current status'; ks_title='  VPN NetGuard · Kill switch status'
            sections='── Network|── Kill switch|── Coexistence with other VPNs|── Network privacy|── Connectivity|── Alerts and monitoring|'
            eth='  Active Ethernet       Conexión cableada 1'; phys='  Physical interface    enp0s3'
            prof='  Ethernet profiles     Conexión cableada 1'; warn='  IPv4 rules            ⚠ inactive'
        fi
        out_c=""
        for loc in C C.UTF-8; do
            out="$( (LC_ALL="$loc"; export LC_ALL; print_status) 2>&1)"
            # Cabecera: nombre del programa en su grafía, entre dos líneas dobles de 64 columnas.
            [[ "$(sed -n 1p <<< "$out")" == "$rule" && "$(sed -n 2p <<< "$out")" == "$title" &&
               "$(sed -n 3p <<< "$out")" == "$rule" && "$out" != *'== vpn-netguard'* ]] || { echo "$ui/$loc: cabecera" >&2; return 1; }
            # Sin «?» ni códigos de color; los acentos salen enteros.
            [[ "$out" != *'?'* && "$out" != *$'\033'* && "$out" == *'Conexión cableada 1'* ]] || { echo "$ui/$loc: '?' o color" >&2; return 1; }
            # Exactamente seis secciones, en orden, de 64 columnas cada una.
            [[ "$(grep -E '^── ' <<< "$out" | LC_ALL=C.UTF-8 sed -E 's/ ─+$//' | tr '\n' '|')" == "$sections" ]] || { echo "$ui/$loc: secciones" >&2; return 1; }
            while IFS= read -r line; do
                n="$(printf '%s\n' "$line" | LC_ALL=C.UTF-8 wc -m)"
                (( n == 65 )) || { echo "$ui/$loc: sección de $((n - 1)) columnas: $line" >&2; return 1; }
            done < <(grep -E '^── ' <<< "$out")
            # Ninguna línea pasa de 64 columnas (las reglas miden justo 64).
            [[ "$(LC_ALL=C.UTF-8 wc -L <<< "$out")" -eq 64 ]] || { echo "$ui/$loc: ancho" >&2; return 1; }
            # Etiqueta en 22 columnas y valor alineado, con acento en la etiqueta y símbolo de nivel.
            grep -Fxq "$eth" <<< "$out" && grep -Fxq "$phys" <<< "$out" && grep -Fxq "$prof" <<< "$out" &&
                grep -Fxq "$warn" <<< "$out" || { echo "$ui/$loc: alineación" >&2; return 1; }
            # El locale no cambia ni un byte de la salida.
            [[ -z "$out_c" ]] && out_c="$out"
            [[ "$out" == "$out_c" ]] || { echo "$ui: C y UTF-8 difieren" >&2; return 1; }
        done
        # «Ver estado del kill switch»: pantalla propia, con su cabecera y sin las secciones de estado.
        for loc in C C.UTF-8; do
            out="$( (LC_ALL="$loc"; export LC_ALL; cmd_killswitch status) 2>&1)"
            [[ "$(sed -n 1p <<< "$out")" == "$rule" && "$(sed -n 2p <<< "$out")" == "$ks_title" &&
               "$(sed -n 3p <<< "$out")" == "$rule" && "$out" != *'Estado actual'* && "$out" != *'Current status'* ]] || { echo "$ui/$loc: cabecera del kill switch" >&2; return 1; }
            ! grep -qE '^── ' <<< "$out" && [[ "$(LC_ALL=C.UTF-8 wc -L <<< "$out")" -eq 64 ]] || { echo "$ui/$loc: kill switch ancho o secciones" >&2; return 1; }
            grep -Fxq "$warn" <<< "$out" || { echo "$ui/$loc: kill switch alineación" >&2; return 1; }
        done
    done
}

# --- Fase 9.3 (punto 6 de la revisión de uso): el anonimato de red dentro de «Ver estado actual» ---
# «status» tiene una sección propia con las mismas filas que la pantalla «privacy-status», que
# además muestra la red activa (en «status» ya sale en la sección Red).
T249() {
    new_env
    nmcli_utf8_mock
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock ping 'exit 1'
    HAVE_IP6TABLES=0
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    EVENT_HISTORY_FILE=/var/lib/vpn-netguard/history.csv
    require_root() { :; }
    local ui loc out out_c st own rows rule
    printf -v rule '%64s' ''; rule="${rule// /═}"
    ANONYMIZE_NETWORK=true; MAC_MODE=stable; ROTATE_MAC_PER_BOOT=true; ROTATE_MAC_EVERY_HOURS=0
    RANDOMIZE_SCAN_MAC=true; SPOOF_HOSTNAME=false; IPV6_PRIVACY=true; DISABLE_IPV6=false
    DISABLE_MDNS_ANNOUNCE=true; HARDEN_BROWSER_DOH=false
    : > "$NM_PRIVACY_CONF"
    for ui in es en; do
        UI_LANGUAGE="$ui"; ui_init
        local title sect yes no mod
        if [[ "$ui" == es ]]; then
            title='  VPN NetGuard · Anonimato de red'; sect='── Anonimato de red'; yes='sí'; no='no'
            mod='  Módulo de anonimato   ✓ activado (política de MAC: stable)'
        else
            title='  VPN NetGuard · Network privacy'; sect='── Network privacy'; yes='yes'; no='no'
            mod='  Privacy module        ✓ enabled (MAC policy: stable)'
        fi
        out_c=""
        for loc in C C.UTF-8; do
            own="$( (LC_ALL="$loc"; export LC_ALL; print_privacy_status) 2>&1)"
            [[ "$(sed -n 1p <<< "$own")" == "$rule" && "$(sed -n 2p <<< "$own")" == "$title" && "$(sed -n 3p <<< "$own")" == "$rule" &&
               "$own" != *'== vpn-netguard'* && "$own" != *'?'* && "$own" != *$'\033'* ]] || { echo "$ui/$loc: cabecera" >&2; return 1; }
            [[ "$(LC_ALL=C.UTF-8 wc -L <<< "$own")" -eq 64 ]] && ! grep -qE '^── ' <<< "$own" || { echo "$ui/$loc: ancho o secciones" >&2; return 1; }
            [[ -z "$out_c" ]] && out_c="$own"
            [[ "$own" == "$out_c" ]] || { echo "$ui: C y UTF-8 difieren" >&2; return 1; }
        done
        # Valores sí/no localizados y filas alineadas (etiqueta con acento incluida) en la pantalla propia.
        grep -Fxq "$mod" <<< "$own" || { echo "$ui: módulo" >&2; return 1; }
        if [[ "$ui" == es ]]; then
            grep -Fxq "  Rotar MAC al inicio   $yes" <<< "$own" && grep -Fxq "  Ocultar nombre DHCP   $no" <<< "$own" &&
                grep -Fxq '  Rotación periódica    desactivada' <<< "$own" &&
                grep -Fxq '  Red activa            Conexión cableada 1 (enp0s3)' <<< "$own" || { echo "es: filas" >&2; return 1; }
        else
            grep -Fxq "  Rotate MAC at boot    $yes" <<< "$own" && grep -Fxq "  Hide name from DHCP   $no" <<< "$own" &&
                grep -Fxq '  Periodic rotation     disabled' <<< "$own" &&
                grep -Fxq '  Active network        Conexión cableada 1 (enp0s3)' <<< "$own" || { echo "en: filas" >&2; return 1; }
        fi
        # «status»: sección entre Convivencia y Conectividad, sin repetir la red activa, y con las
        # mismas filas que la pantalla propia (una sola fuente).
        st="$( (LC_ALL=C; export LC_ALL; print_status) 2>&1)"
        rows="$(awk -v s="$sect" 'index($0, s)==1 {on=1; next} on && /^── / {exit} on && NF' <<< "$st")"
        [[ -n "$rows" && "$st" == *"$sect"* ]] || { echo "$ui: sin sección" >&2; return 1; }
        [[ "$(grep -nE -- '^── ' <<< "$st" | sed -n 4p | cut -d: -f2- | cut -c1-30)" == "$sect"* ]] || { echo "$ui: la sección no es la cuarta" >&2; return 1; }
        [[ "$rows" == "$(tail -n +5 <<< "$own" | grep -vE '^  (Red activa|Active network) ')" ]] || { echo "$ui: filas distintas en status y privacy-status" >&2; return 1; }
        ! grep -qE '^  (Red activa|Active network) ' <<< "$rows" || { echo "$ui: la red activa se repite" >&2; return 1; }
    done
    # Niveles: sin snippet con el módulo activado avisa; con el módulo apagado no hay símbolo ni aviso.
    UI_LANGUAGE=es; ui_init
    rm -f "$NM_PRIVACY_CONF"
    out="$(print_privacy_status 2>&1)"
    grep -Fxq '  Aplicado al sistema   ⚠ NO (se crea al aplicar los ajustes)' <<< "$out" || { echo "snippet ausente sin aviso" >&2; return 1; }
    ANONYMIZE_NETWORK=false
    out="$(print_privacy_status 2>&1)"
    grep -Fxq '  Módulo de anonimato   desactivado' <<< "$out" && grep -Fxq '  Aplicado al sistema   no' <<< "$out" || { echo "módulo apagado" >&2; return 1; }
    : > "$NM_PRIVACY_CONF"
    out="$(print_privacy_status 2>&1)"
    [[ "$out" != *'✓ sí'* ]] || { echo "snippet con el módulo apagado marcado como correcto" >&2; return 1; }
    ANONYMIZE_NETWORK=true
    # Temporizador: avisa si no corre y es correcto si corre.
    ROTATE_MAC_EVERY_HOURS=6
    out="$(print_privacy_status 2>&1)"
    grep -Fxq '  Rotación periódica    ⚠ cada 6 h (inactivo)' <<< "$out" || { echo "temporizador parado" >&2; return 1; }
    mock systemctl 'exit 0'
    out="$(print_privacy_status 2>&1)"
    grep -Fxq '  Rotación periódica    ✓ cada 6 h (activo)' <<< "$out" || { echo "temporizador activo" >&2; return 1; }
    # Sin red activa: la pantalla propia lo dice; «status» no añade filas de perfil ni la red.
    nmcli_utf8_mock; mock nmcli 'exit 0'
    out="$(print_privacy_status 2>&1)"
    grep -Fxq '  Red activa            ninguna' <<< "$out" && ! grep -q 'MAC en uso' <<< "$out" || { echo "sin red activa" >&2; return 1; }
    out="$(print_status 2>&1)"
    ! grep -qE '^  (MAC en uso|Red activa) ' <<< "$out" || { echo "status sin red: filas de red" >&2; return 1; }
}

# --- Fase 9.4 (punto 7 de la revisión de uso): pantallas de estado con un solo botón ---
# Un texto corto va en --info (solo Aceptar); uno largo, en --text-info, que en zenity 4 lleva
# siempre Cancelar. --info ignora --height, así que el tope se mide en saltos de línea.

# zenity simulado: guarda los argumentos de la última llamada (separados por NUL) en zargs0 y,
# solo con --text-info, el texto de stdin en zstdin; --info no lee nada, como el real.
zenity_capture_mock() {
    zenity_ui() {
        local a
        printf '%s\0' "$@" > "$TEST_ROOT/zargs0"; : > "$TEST_ROOT/zstdin"
        for a in "$@"; do [[ "$a" == --text-info ]] && cat > "$TEST_ROOT/zstdin"; done
        return 0
    }
}

# zarg --width -> valor de --width=... en la última llamada (código 1 si no estaba).
zarg() {
    local a
    while IFS= read -r -d '' a; do [[ "$a" == "$1="* ]] && { printf '%s' "${a#"$1="}"; return 0; }; done < "$TEST_ROOT/zargs0"
    return 1
}

# zarg_has --info -> la última llamada llevó ese argumento tal cual.
zarg_has() {
    local a
    while IFS= read -r -d '' a; do [[ "$a" == "$1" ]] && return 0; done < "$TEST_ROOT/zargs0"
    return 1
}

# Texto de prueba con exactamente N saltos de línea (N + 1 filas), sin salto final.
nl_text() { local n="$1" i t="fila 0"; for ((i = 1; i <= n; i++)); do t+=$'\nfila '"$i"; done; printf '%s' "$t"; }

T250() {
    new_env
    nmcli_utf8_mock
    mock systemctl 'exit 1'
    mock iptables 'exit 1'
    mock ping 'exit 1'
    HAVE_IP6TABLES=0
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    EVENT_HISTORY_FILE=/var/lib/vpn-netguard/history.csv
    require_root() { :; }
    zenity_capture_mock
    local ui screen out fn title kind w text
    # Pantallas reales (es y en): estado actual en --text-info; kill switch y anonimato, en --info,
    # con el título de su pantalla, el texto intacto y un ancho que admite 64 columnas (~620 px).
    for ui in es en; do
        UI_LANGUAGE="$ui"; ui_init
        for screen in status killswitch privacy; do
            case "$screen" in
                status) out="$(print_status 2>&1)"; fn=panel_action_status; title="$TITLE - $(ui_t panel.status)"; kind=--text-info ;;
                killswitch) out="$(cmd_killswitch status 2>&1)"; fn=panel_action_killswitch_status; title="$TITLE - $(ui_t killswitch.title)"; kind=--info ;;
                privacy) out="$(print_privacy_status 2>&1)"; fn=panel_action_privacy_status; title="$TITLE - $(ui_t panel.privacy)"; kind=--info ;;
            esac
            printf '%s\n' "$out" > "$TEST_ROOT/pk.out"
            mock pkexec "cat \"$TEST_ROOT/pk.out\""
            "$fn" >/dev/null 2>&1
            if [[ "$kind" == --info ]]; then
                zarg_has --info && ! zarg_has --text-info && [[ "$(zarg --text)" == "<tt>$(pango_escape "$out")</tt>" ]] ||
                    { echo "$ui/$screen: debía ir en --info con su texto" >&2; return 1; }
            else
                zarg_has --text-info && ! zarg_has --info && [[ "$(< "$TEST_ROOT/zstdin")" == "$out" ]] ||
                    { echo "$ui/$screen: debía ir en --text-info con su texto" >&2; return 1; }
            fi
            w="$(zarg --width)"
            [[ "$(zarg --title)" == "$title" && "$w" =~ ^[0-9]+$ ]] && (( w >= 620 && w <= 800 )) ||
                { echo "$ui/$screen: título '$(zarg --title)' o ancho '$w'" >&2; return 1; }
        done
    done
    # Frontera: un salto por debajo del tope, --info; en el tope, --text-info.
    text="$(nl_text $((PANEL_INFO_MAX_LINES - 1)))"
    panel_status_screen T 300 "$text"
    zarg_has --info && ! zarg_has --text-info || { echo "bajo el tope: debía ir en --info" >&2; return 1; }
    text="$(nl_text "$PANEL_INFO_MAX_LINES")"
    panel_status_screen T 300 "$text"
    zarg_has --text-info && ! zarg_has --info || { echo "en el tope: debía ir en --text-info" >&2; return 1; }
    # --info: título dado, ancho de las pantallas de estado, sin ajuste de línea y texto en <tt>
    # con &, < y > escapados (el texto lleva acentos y símbolos que Pango deja pasar).
    text=$'═══ a & b <c> ✓\n  Ethernet   Conexión cableada 1'
    panel_status_screen 'Título ñ' 300 "$text"
    [[ "$(zarg --title)" == 'Título ñ' && "$(zarg --width)" == "$PANEL_STATUS_W" ]] && zarg_has --no-wrap &&
        [[ "$(zarg --text)" == $'<tt>═══ a &amp; b &lt;c&gt; ✓\n  Ethernet   Conexión cableada 1</tt>' ]] ||
        { echo "--info: título, ancho, --no-wrap o escape" >&2; return 1; }
    # --text-info: título dado, ancho, alto pedido y Monospace; el texto entra por stdin.
    text="$(nl_text "$PANEL_INFO_MAX_LINES")"
    panel_status_screen 'Título ñ' 345 "$text"
    [[ "$(zarg --title)" == 'Título ñ' && "$(zarg --width)" == "$PANEL_STATUS_W" && "$(zarg --height)" == 345 &&
       "$(zarg --font)" == Monospace && "$(< "$TEST_ROOT/zstdin")" == "$text" ]] ||
        { echo "--text-info: título, ancho, alto, fuente o texto" >&2; return 1; }
}

# --- Fase 9.4 (c): Aceptar en «Ajustes de anonimato de red» ---
# Aceptar guarda solo si algún valor cambió (sin cambios no escribe), pide confirmación y aplica.
# «Guardada» solo sale si hubo cambios y no se aplicó (confirmación rechazada o aplicar falló).
T251() {
    new_env
    local ev="$TEST_ROOT/ev" confirm=0 apply_rc=0 lang
    local -A WANT=()
    is_ssh_session() { return 1; }
    lab() { ui_field_label "$1"; }
    fresh() { base_config; sed -i "s/^LANGUAGE=.*/LANGUAGE=\"${1:-en}\"/" "$CONFIG_FILE"; UI_LANGUAGE="${1:-en}"; ui_init; WANT=(); }
    # zenity simulado: el formulario devuelve el valor de WANT para cada campo (por etiqueta; vacío si no está).
    zenity_ui() {
        local a kind="" text="" out="" sep="" lbl k
        for a in "$@"; do
            case "$a" in --forms|--error|--info|--question) kind="$a" ;; --text=*) text="${a#--text=}" ;; esac
        done
        case "$kind" in
            --forms)
                echo forms >> "$ev"; printf '%s' "$text" > "$TEST_ROOT/ftext"
                for a in "$@"; do
                    case "$a" in --add-entry=*|--add-combo=*)
                        lbl="${a#*=}"; lbl="${lbl%%$'\n'*}"; out+="$sep"; sep='|'
                        for k in "${!WANT[@]}"; do
                            [[ "$lbl" == "$k" || "$lbl" == "$k ("* ]] && out+="${WANT[$k]}"
                        done ;;
                    esac
                done
                printf '%s\n' "$out" ;;
            --question) echo question >> "$ev"; return "$confirm" ;;
            --error) echo error >> "$ev" ;;
            --info)
                if [[ "$text" == "$(ui_t panel.privacy_saved)" ]]; then echo saved >> "$ev"
                elif [[ "$text" == "$(ui_t panel.privacy_applied)"* ]]; then
                    if [[ "$text" == *"$(ui_t panel.doh_restart_browser)"* ]]; then echo applied+doh >> "$ev"; else echo applied >> "$ev"; fi
                else echo 'info?' >> "$ev"; fi ;;
        esac
        return 0
    }
    eval "real_$(declare -f panel_write_config_keys)"
    panel_write_config_keys() { echo write >> "$ev"; real_panel_write_config_keys "$@"; }
    panel_run_privileged() {
        [[ "$1" == -- ]] && shift
        echo "apply:${*:2}" >> "$ev"
        (( apply_rc )) && panel_error_box x
        return "$apply_rc"
    }
    run_case() {   # <eventos esperados> <confirmar: 0 sí, 1 no> <código de aplicar>
        : > "$ev"; confirm="$2"; apply_rc="$3"
        panel_action_configure_privacy >/dev/null 2>&1
        local got; got="$(paste -sd, "$ev")"
        [[ "$got" == "$1" ]] || { echo "esperado '$1', salió '$got'" >&2; return 1; }
    }

    # Sin cambios (combo con el valor actual, '-' en un campo vacío y solo espacios): no escribe, confirma y aplica.
    fresh; cp "$CONFIG_FILE" "$TEST_ROOT/orig"
    WANT["$(lab MAC_MODE)"]=stable; WANT["$(lab MAC_OUI_MASK)"]=-; WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]='   '
    run_case 'forms,question,apply:apply-privacy,applied' 0 0 || return 1
    cmp -s "$CONFIG_FILE" "$TEST_ROOT/orig" || return 1
    # Sin cambios y sin confirmar: no pasa nada (ni escribe, ni aplica, ni avisa de «guardada»).
    run_case 'forms,question' 1 0 || return 1
    cmp -s "$CONFIG_FILE" "$TEST_ROOT/orig" || return 1

    # Con un cambio: guarda antes de confirmar y aplica; el resto de claves queda igual.
    fresh; WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]=equipo
    run_case 'forms,write,question,apply:apply-privacy,applied' 0 0 || return 1
    [[ "$(panel_get_val DHCP_HOSTNAME_OVERRIDE)" == equipo && "$(panel_get_val MAC_MODE)" == stable ]] || return 1
    # Con un cambio y sin confirmar: queda guardado, no se aplica y sale el aviso de «guardada».
    fresh; WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]=equipo
    run_case 'forms,write,question,saved' 1 0 || return 1
    [[ "$(panel_get_val DHCP_HOSTNAME_OVERRIDE)" == equipo ]] || return 1
    # Con un cambio y aplicar falla (p. ej. pkexec cancelado): error de aplicar y, después, «guardada».
    fresh; WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]=equipo
    run_case 'forms,write,question,apply:apply-privacy,error,saved' 0 1 || return 1
    [[ "$(panel_get_val DHCP_HOSTNAME_OVERRIDE)" == equipo ]] || return 1

    # '-' vacía un campo opcional que tenía valor: es un cambio.
    fresh; sed -i 's/^DHCP_HOSTNAME_OVERRIDE=.*/DHCP_HOSTNAME_OVERRIDE="viejo"/' "$CONFIG_FILE"
    WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]=-
    run_case 'forms,write,question,apply:apply-privacy,applied' 0 0 || return 1
    [[ -z "$(panel_get_val DHCP_HOSTNAME_OVERRIDE)" ]] || return 1

    # El aviso de reabrir el navegador solo sale si cambió HARDEN_BROWSER_DOH.
    fresh; WANT["$(lab HARDEN_BROWSER_DOH)"]=true
    run_case 'forms,write,question,apply:apply-privacy,applied+doh' 0 0 || return 1
    fresh; WANT["$(lab HARDEN_BROWSER_DOH)"]=false; WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]=equipo
    run_case 'forms,write,question,apply:apply-privacy,applied' 0 0 || return 1

    # Guardado rechazado (configuración actual no admitida): caja de error, sin confirmar ni aplicar, fichero intacto.
    fresh; printf 'NOT_A_KEY=1\n' >> "$CONFIG_FILE"; cp "$CONFIG_FILE" "$TEST_ROOT/orig"
    WANT["$(lab DHCP_HOSTNAME_OVERRIDE)"]=equipo
    run_case 'forms,write,error' 0 0 || return 1
    cmp -s "$CONFIG_FILE" "$TEST_ROOT/orig" || return 1

    # La ayuda nombra el botón de estado (traducido) y dice qué hacen Aceptar y ese botón.
    for lang in es en; do
        fresh "$lang"; run_case 'forms,question' 1 0 || return 1
        grep -Fq "'$(ui_t privacy.menu_status)'" "$TEST_ROOT/ftext" && ! grep -Fq '%' "$TEST_ROOT/ftext" || { echo "ayuda ($lang): $(<"$TEST_ROOT/ftext")" >&2; return 1; }
    done
}

# --- 9.5: explicación breve de cada opción de configuración (ui_field_help) ---
T252() {
    new_env
    local -a allowed=() kg=() kp=() km=()
    local -A LAB=() HLP=()
    local lang key es en txt cur out line joined idx block max_line=90
    read -ra allowed <<< "$(declare -f config_key_allowed | grep -oE '\b[A-Z][A-Z0-9_]+\b' | tr '\n' ' ')"
    [[ " ${allowed[*]} " == *' LANGUAGE '* && " ${allowed[*]} " == *' HARDEN_BROWSER_DOH '* ]] || { echo "no se leyeron las claves de config_key_allowed" >&2; return 1; }

    # Una explicación por clave permitida y por idioma: una línea de hasta 90 caracteres, distinta en cada
    # idioma, sin espacios sobrantes ni caracteres que zenity, Pango o printf interpretarían (_ < > & % | \ ' " $).
    for key in "${allowed[@]}"; do
        es="$(UI_LANGUAGE=es ui_field_help "$key")"; en="$(UI_LANGUAGE=en ui_field_help "$key")"
        [[ -n "$es" && -n "$en" && "$es" != "$en" ]] || { echo "$key: sin texto o igual en es y en" >&2; return 1; }
        for txt in "$es" "$en"; do
            [[ "$txt" != *$'\n'* && "$txt" != ' '* && "$txt" != *' ' && "$txt" != *'  '* ]] || { echo "$key: salto de línea o espacios sobrantes" >&2; return 1; }
            (( $(ui_text_len "$txt") <= max_line )) || { echo "$key: más de $max_line caracteres: $txt" >&2; return 1; }
            case "$txt" in *[_\<\>\&%\|\\\'\"\$]*) echo "$key: carácter prohibido en: $txt" >&2; return 1 ;; esac
        done
    done
    [[ -z "$(ui_field_help NOT_A_KEY)" && -z "$(ui_field_help '')" ]] || { echo "una clave desconocida debe quedar sin explicación" >&2; return 1; }
    # El plazo que cita la explicación es la constante real: si cambia, hay que actualizar el texto.
    for lang in es en; do
        [[ "$(UI_LANGUAGE=$lang ui_field_help KILLSWITCH_BOOT_RACE_AUTO_DISABLE)" == *"$KS_BOOT_RACE_GRACE_SECONDS s"* ]] || { echo "$lang: plazo de arranque distinto de ${KS_BOOT_RACE_GRACE_SECONDS} s" >&2; return 1; }
    done

    # Claves de cada formulario (las mismas que el menú de texto) y cobertura total entre los tres.
    mapfile -t kg < <(menu_configure_keys() { shift 2; printf '%s\n' "$@"; }; menu_configure_general)
    mapfile -t kp < <(menu_configure_keys() { shift 2; printf '%s\n' "$@"; }; menu_configure_privacy)
    mapfile -t km < <(menu_configure_keys() { shift 2; printf '%s\n' "$@"; }; menu_configure_monitoring)
    [[ "$(printf '%s\n' "${kg[@]}" "${kp[@]}" "${km[@]}" | sort)" == "$(printf '%s\n' "${allowed[@]}" | sort)" ]] || { echo "los tres formularios no cubren exactamente las claves permitidas" >&2; return 1; }

    # zenity simulado: anota la etiqueta de cada campo (separadas por NUL: llevan saltos de línea) y no devuelve nada.
    zenity_ui() {
        local a
        for a in "$@"; do
            case "$a" in
                --add-entry=*|--add-combo=*) printf '%s\0' "${a#*=}" >> "$TEST_ROOT/fields" ;;
                --text=*) printf '%s' "${a#*=}" > "$TEST_ROOT/text" ;;
            esac
        done
        return 0
    }
    # Cada etiqueta calculada llama una vez a ui_field_help: se anota (las etiquetas se calculan en
    # subshells) para comprobar que un formulario no calcula etiquetas que luego descarta.
    eval "real_$(declare -f ui_field_help)"
    ui_field_help() { echo >> "$TEST_ROOT/helps"; real_ui_field_help "$@"; }
    form_text_ok() {   # --text que recibió zenity en la última ejecución del formulario: ninguna línea pasa de max_line caracteres
        local fn="$1" txt line n=0
        txt="$(<"$TEST_ROOT/text")"
        [[ -n "$txt" ]] || { echo "$fn: sin --text" >&2; return 1; }
        txt="${txt//\\n/$'\n'}"   # zenity convierte el \n literal del --text; el de anonimato ya trae saltos reales (printf)
        while IFS= read -r line; do
            ((++n)); (( $(ui_text_len "$line") <= max_line )) || { echo "$fn: la línea $n del --text tiene $(ui_text_len "$line") caracteres (máx. $max_line): $line" >&2; return 1; }
        done <<< "$txt"
    }
    form_fields() {   # <formulario> <claves...>: un campo por clave, de dos líneas (nombre [+ valor] y su explicación)
        local fn="$1"; shift
        local -a f=(); local lbl l1 l2 k n seen=' '
        : > "$TEST_ROOT/fields"; : > "$TEST_ROOT/text"; : > "$TEST_ROOT/helps"; "$fn" >/dev/null 2>&1
        mapfile -d '' -t f < "$TEST_ROOT/fields"
        (( ${#f[@]} == $# )) || { echo "$fn: ${#f[@]} campos, esperados $#" >&2; return 1; }
        n="$(wc -l < "$TEST_ROOT/helps")"
        (( n == $# )) || { echo "$fn: $n explicaciones calculadas para $# campos (una etiqueta se calcula y se descarta)" >&2; return 1; }
        for lbl in "${f[@]}"; do
            [[ "$lbl" == *$'\n'* ]] || { echo "$fn: campo sin explicación: $lbl" >&2; return 1; }
            l1="${lbl%%$'\n'*}"; l2="${lbl#*$'\n'}"
            for k in "$@"; do
                [[ ( "$l1" == "${LAB[$k]}" || "$l1" == "${LAB[$k]} ("* ) && "$l2" == "${HLP[$k]}" ]] && seen+="$k "
            done
        done
        for k in "$@"; do [[ "$seen" == *" $k "* ]] || { echo "$fn: $k sin su explicación" >&2; return 1; }; done
        form_text_ok "$fn"
    }

    for lang in es en; do
        UI_LANGUAGE=$lang; ui_init
        for key in "${allowed[@]}"; do LAB[$key]="$(ui_field_label "$key")"; HLP[$key]="$(ui_field_help "$key")"; done
        # Etiqueta del panel: nombre y explicación en dos líneas; los campos de texto añaden el valor actual.
        [[ "$(panel_field_label LOG_LEVEL)" == "${LAB[LOG_LEVEL]}"$'\n'"${HLP[LOG_LEVEL]}" ]] || { echo "$lang: etiqueta de un combo" >&2; return 1; }
        printf -v cur -- "$(ui_t ui.current)" 'a%sb'
        [[ "$(panel_field_label PING_TARGETS 'a%sb')" == "${LAB[PING_TARGETS]} ($cur)"$'\n'"${HLP[PING_TARGETS]}" ]] || { echo "$lang: etiqueta de un campo de texto" >&2; return 1; }
        [[ "$(panel_field_label NOT_A_KEY)" == NOT_A_KEY ]] || { echo "$lang: una clave sin explicación debe dar una sola línea" >&2; return 1; }
        form_fields panel_action_configure "${kg[@]}" || return 1
        form_fields panel_action_configure_privacy "${kp[@]}" || return 1
        form_fields panel_action_configure_monitoring "${km[@]}" || return 1
        # Menú de texto: línea en blanco y la explicación con sangría, ajustada a UI_WIDTH, sin perder palabras.
        for key in "${allowed[@]}"; do
            out="$(menu_print_field_help "$key")"
            [[ "$out" == $'\n  '* ]] || { echo "$lang $key: formato de la explicación en el menú" >&2; return 1; }
            joined=''
            while IFS= read -r line; do
                [[ "$line" == '  '* ]] && (( $(ui_text_len "$line") <= UI_WIDTH )) || { echo "$lang $key: línea mal ajustada: $line" >&2; return 1; }
                joined+="${line#  } "
            done <<< "${out#$'\n'}"
            [[ "${joined% }" == "${HLP[$key]}" ]] || { echo "$lang $key: el texto ajustado no coincide" >&2; return 1; }
        done
        [[ -z "$(menu_print_field_help NOT_A_KEY)" ]] || { echo "$lang: el menú no debe imprimir nada para una clave sin explicación" >&2; return 1; }
    done

    # Menú de texto real: al elegir una opción sale su explicación y solo la suya.
    menu_clear() { :; }; pause_enter() { :; }; sleep() { :; }
    menu_elevate() { if [[ "$1" == install ]]; then cp -- "${@: -2:1}" "${@: -1}"; else "$@"; fi; }
    idx=0; for key in "${kg[@]}"; do ((++idx)); [[ "$key" == PING_TARGETS ]] && break; done
    out="$(printf '%s\n' "$idx" '' g | menu_configure_general 2>&1)"
    block="$(menu_print_field_help PING_TARGETS)"
    [[ "$out" == *"$block"* && "$out" != *"$(ui_field_help LOG_LEVEL)"* ]] || { echo "el menú de texto no muestra solo la explicación de la opción elegida" >&2; return 1; }
}

# --- 9.5 (hallazgo de 9.2): la fila «DNS del kill switch» con DNS_SERVERS vacío ---
# Con la lista vacía las reglas abren el DNS (puerto 53) a cualquier destino en IPv4 y no abren
# ninguno en IPv6, y la fila decía «ninguno». El test ata el texto a las reglas generadas: si estas
# cambian, el texto deja de ser cierto y falla.
T253() {
    new_env
    nmcli_utf8_mock
    mock systemctl 'exit 1'
    mock ping 'exit 1'
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    EVENT_HISTORY_FILE=/var/lib/vpn-netguard/history.csv   # ruta corta: la de TMP no debe decidir el ancho
    require_root() { :; }
    local ui out any lst
    # Reglas reales con la lista vacía: DNS sin destino en IPv4 y ninguna regla de DNS en IPv6.
    HAVE_IP6TABLES=1; KS_VPN_CANDIDATES=(); DNS_SERVERS=''
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock iptables-restore 'cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6"; exit 0'
    apply_killswitch_rules tun0 >/dev/null && apply_killswitch_rules6 tun0 >/dev/null || return 1
    grep -Fxq -- '-A NETGUARD_KS -p udp --dport 53 -j RETURN' "$TEST_ROOT/restore4" &&
        grep -Fxq -- '-A NETGUARD_KS -p tcp --dport 53 -j RETURN' "$TEST_ROOT/restore4" || { echo "IPv4: con la lista vacía no se abre el DNS a cualquier destino" >&2; return 1; }
    ! grep -q -- '--dport 53' "$TEST_ROOT/restore6" || { echo "IPv6: con la lista vacía se abre DNS" >&2; return 1; }
    # La fila dice lo mismo, en una sola línea y sin pasar de 64 columnas; con lista, la muestra tal cual.
    mock iptables 'exit 1'; HAVE_IP6TABLES=0
    for ui in es en; do
        UI_LANGUAGE="$ui"; ui_init
        if [[ "$ui" == es ]]; then
            any='  DNS del kill switch   cualquiera en IPv4; ninguno en IPv6'; lst='  DNS del kill switch   1.1.1.1 9.9.9.9'
        else
            any='  Kill switch DNS       any on IPv4; none on IPv6'; lst='  Kill switch DNS       1.1.1.1 9.9.9.9'
        fi
        DNS_SERVERS=''
        out="$(print_status 2>&1)"
        grep -Fxq "$any" <<< "$out" || { echo "$ui: la fila con la lista vacía no describe las reglas" >&2; return 1; }
        [[ "$(LC_ALL=C.UTF-8 wc -L <<< "$out")" -le 64 ]] || { echo "$ui: ancho" >&2; return 1; }
        DNS_SERVERS='1.1.1.1 9.9.9.9'
        out="$(print_status 2>&1)"
        grep -Fxq "$lst" <<< "$out" && [[ "$out" != *"$any"* ]] || { echo "$ui: la fila con una lista no la muestra tal cual" >&2; return 1; }
    done
}

T254() {
    new_env
    mock ping 'echo "$*" >> "$TEST_ROOT/ping.log"; exit 0'
    local blank=$'  \t ' key
    local -a keys=(PING_TARGETS DNS_SERVERS ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_PRIORITY VPN_IGNORE VPN_ENDPOINT_OVERRIDE ALERT_HOOK PROMETHEUS_TEXTFILE_DIR)
    # D12: valores de solo espacios y tabuladores en el fichero de configuración.
    for key in "${keys[@]}"; do printf '%s="%s"\n' "$key" "$blank" >> "$CONFIG_FILE"; done
    load_config 2>"$TEST_ROOT/load.err" || return 1
    grep -Eq 'PING_TARGETS (vacío|is empty)' "$TEST_ROOT/load.err" || { echo "PING_TARGETS en blanco: falta el aviso" >&2; return 1; }
    [[ "$PING_TARGETS" == '1.1.1.1 8.8.8.8' ]] || { echo "PING_TARGETS en blanco no vuelve a la lista por defecto" >&2; return 1; }
    for key in DNS_SERVERS ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_ENDPOINT_OVERRIDE ALERT_HOOK PROMETHEUS_TEXTFILE_DIR; do
        [[ -z "${!key}" ]] || { echo "$key en blanco no queda vacío" >&2; return 1; }
    done
    # Consecuencias: el ping de comprobación tiene objetivos y las reglas de ping y de DNS salen.
    check_internet_reachable && grep -Fq '1.1.1.1' "$TEST_ROOT/ping.log" || { echo "check_internet_reachable no tiene objetivos de ping" >&2; return 1; }
    HAVE_IP6TABLES=1; KS_VPN_CANDIDATES=()
    mock iptables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock ip6tables '[[ "$1" == "-w" ]] && shift 2; case "$1" in -C) exit 1;; esac; exit 0'
    mock iptables-restore 'cat > "$TEST_ROOT/restore4"; exit 0'
    mock ip6tables-restore 'cat > "$TEST_ROOT/restore6"; exit 0'
    apply_killswitch_rules tun0 >/dev/null && apply_killswitch_rules6 tun0 >/dev/null || return 1
    grep -Fxq -- '-A NETGUARD_KS -d 1.1.1.1 -p icmp --icmp-type echo-request -j RETURN' "$TEST_ROOT/restore4" || { echo "PING_TARGETS en blanco: IPv4 sin regla de ping" >&2; return 1; }
    grep -Fxq -- '-A NETGUARD_KS -p udp --dport 53 -j RETURN' "$TEST_ROOT/restore4" || { echo "DNS_SERVERS en blanco: IPv4 no abre el DNS" >&2; return 1; }
    ! grep -q -- '--dport 53' "$TEST_ROOT/restore6" || { echo "DNS_SERVERS en blanco: IPv6 abre el DNS" >&2; return 1; }
    # VPN_PRIORITY y VPN_IGNORE en blanco no hacen nada: ni reordenan ni ignoran un perfil.
    KNOWN_VPN=('VPN B' 'VPN A')
    [[ "$(ordered_known_vpn | paste -sd,)" == 'VPN B,VPN A' ]] || { echo "VPN_PRIORITY en blanco cambia el orden" >&2; return 1; }
    ! vpn_is_ignored 'VPN A' || { echo "VPN_IGNORE en blanco ignora un perfil" >&2; return 1; }
    # Red de seguridad del arranque: sin endpoint propio (VPN_ENDPOINT_OVERRIDE en blanco), un bloqueo atascado
    # sin VPN se autodesactiva pasado el margen; con el valor sin corregir «hay endpoint» y no llegaba a actuar.
    KILLSWITCH_BOOT_RACE_AUTO_DISABLE=true; ACTIVE_VPN=''
    KS_BOOT_RACE_PENDING_FILE="$STATE_DIR/boot-race-pending"; KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/boot-race-marker"
    echo 1 > "$KS_BOOT_RACE_PENDING_FILE"; echo on > "$KILLSWITCH_OVERRIDE_FILE"
    disable_killswitch_locked() { : > "$TEST_ROOT/disabled"; }
    run_alert_hook() { :; }; notify_send() { return 1; }
    warn_ks_boot_race_if_stuck
    [[ -e "$TEST_ROOT/disabled" ]] || { echo "VPN_ENDPOINT_OVERRIDE en blanco: el bloqueo atascado no se autodesactiva" >&2; return 1; }
}

# --- 9.6 (a): interfaz de arranque, preferencia por usuario (ui_pref_*) ---
T255() {
    new_env
    umask 022
    local home="$TEST_ROOT/home" f raw rc xdg other blocked
    mkdir -p "$home"; HOME="$home"; unset XDG_CONFIG_HOME
    f="$home/.config/vpn-netguard/start-ui"
    # Sin fichero no hay elección: no imprime nada (manda el origen del arranque, cmd_start_ui),
    # termina con 0, no escribe por stderr y leer no crea nada.
    [[ "$(ui_pref_file)" == "$f" && ! -e "$home/.config" ]] || { echo "sin fichero: ruta errónea o se creó algo" >&2; return 1; }
    [[ -z "$(ui_pref_get 2>&1)" ]] || { echo "sin fichero: ui_pref_get imprime algo: '$(ui_pref_get 2>&1)'" >&2; return 1; }
    ui_pref_get || { echo "sin fichero: ui_pref_get no termina con 0" >&2; return 1; }
    [[ ! -e "$home/.config" ]] || { echo "leer creó algo" >&2; return 1; }
    # Fijar el panel y volver a la terminal: el fichero solo lleva el valor, es privado y no deja temporales.
    ui_pref_set panel || return 1
    [[ "$(cat "$f")" == panel && "$(ui_pref_get)" == panel ]] || { echo "fijar panel" >&2; return 1; }
    [[ "$(stat -c %a "$f")" == 600 && "$(stat -c %a "${f%/*}")" == 700 ]] || { echo "permisos: $(stat -c %a "$f") $(stat -c %a "${f%/*}")" >&2; return 1; }
    [[ -z "$(find "${f%/*}" -name '.start-ui.*')" ]] || { echo "quedó un temporal" >&2; return 1; }
    ui_pref_set terminal || return 1
    [[ "$(cat "$f")" == terminal && "$(ui_pref_get)" == terminal ]] || { echo "fijar terminal" >&2; return 1; }
    # Un valor desconocido se rechaza sin tocar el fichero.
    ui_pref_set panel || return 1
    for raw in paneles Panel '' 'panel ' ' panel'; do
        ! ui_pref_set "$raw" || { echo "ui_pref_set acepta '$raw'" >&2; return 1; }
    done
    [[ "$(cat "$f")" == panel ]] || { echo "un valor rechazado tocó el fichero" >&2; return 1; }
    # Lectura: tolera espacios, tabuladores, fin de línea de Windows y la falta de salto final;
    # un valor desconocido o un fichero vacío no es una elección: sin salida.
    for raw in 'panel' '  panel' $'panel\t ' $'panel\r'; do
        printf '%s' "$raw" > "$f"
        [[ "$(ui_pref_get)" == panel ]] || { echo "se esperaba panel con '$raw'" >&2; return 1; }
    done
    for raw in 'terminal' '  terminal' $'terminal\r'; do
        printf '%s' "$raw" > "$f"
        [[ "$(ui_pref_get)" == terminal ]] || { echo "se esperaba terminal con '$raw'" >&2; return 1; }
    done
    for raw in 'PANEL' 'Terminal' 'panel x' 'p anel' 'paneles' '' $'\npanel'; do
        printf '%s' "$raw" > "$f"
        [[ -z "$(ui_pref_get 2>&1)" ]] || { echo "se esperaba nada con '$raw' y salió '$(ui_pref_get 2>&1)'" >&2; return 1; }
    done
    # XDG_CONFIG_HOME manda si es una ruta absoluta; una relativa se ignora (especificación XDG).
    xdg="$TEST_ROOT/xdg"; mkdir -p "$xdg"
    XDG_CONFIG_HOME="$xdg"
    [[ "$(ui_pref_file)" == "$xdg/vpn-netguard/start-ui" ]] || { echo "XDG_CONFIG_HOME absoluta ignorada" >&2; return 1; }
    ui_pref_set panel && [[ "$(cat "$xdg/vpn-netguard/start-ui")" == panel && "$(ui_pref_get)" == panel ]] || { echo "XDG_CONFIG_HOME: no guarda ahí" >&2; return 1; }
    XDG_CONFIG_HOME="relativa/config"
    [[ "$(ui_pref_file)" == "$f" ]] || { echo "XDG_CONFIG_HOME relativa no se ignora" >&2; return 1; }
    unset XDG_CONFIG_HOME
    # Sin HOME ni XDG_CONFIG_HOME no hay dónde guardar: no hay elección y fijar falla.
    ( unset HOME; ! ui_pref_file >/dev/null && [[ -z "$(ui_pref_get 2>&1)" ]] && ! ui_pref_set panel ) || { echo "sin HOME" >&2; return 1; }
    # Un HOME que no es del usuario efectivo no se usa, ni para leer ni para escribir (sudo que conserva HOME).
    if (( EUID == 0 )); then
        other="$TEST_ROOT/ajeno"; mkdir -p "$other/.config/vpn-netguard"; echo panel > "$other/.config/vpn-netguard/start-ui"
        chown 65534 "$other" || return 1
        ( HOME="$other"; ! ui_pref_file >/dev/null && ! ui_pref_set terminal && [[ -z "$(ui_pref_get 2>&1)" ]] ) || { echo "usa un HOME ajeno" >&2; return 1; }
        [[ "$(cat "$other/.config/vpn-netguard/start-ui")" == panel ]] || { echo "tocó un HOME ajeno" >&2; return 1; }
    fi
    # Un destino imposible (".config" es un fichero): falla sin dejar temporales ni tocar nada.
    blocked="$TEST_ROOT/bloqueado"; mkdir -p "$blocked"; : > "$blocked/.config"
    ( HOME="$blocked"; ! ui_pref_set panel && [[ -z "$(ui_pref_get 2>&1)" && -f "$blocked/.config" ]] ) || { echo "ruta bloqueada" >&2; return 1; }
    # «start-ui» es un directorio: fijar falla sin rastro y leer no es una elección ni escribe nada
    # por stderr (la lectura de un directorio daba «read error: Is a directory» en cada arranque).
    rm -f "$f"; mkdir -p "$f"
    ! ui_pref_set panel || { echo "fijar sobre un directorio no falla" >&2; return 1; }
    [[ -d "$f" && -z "$(find "${f%/*}" -name '.start-ui.*')" && -z "$(ls -A "$f")" ]] || { echo "fallo con rastro" >&2; return 1; }
    [[ -z "$(ui_pref_get 2>&1)" ]] || { echo "start-ui es un directorio: ui_pref_get dice '$(ui_pref_get 2>&1)'" >&2; return 1; }
    # Un FIFO tampoco se lee (read se quedaría esperando un escritor: el arranque se colgaría).
    rm -rf "$f"; mkfifo "$f" || return 1
    raw="$(timeout 5 bash -c 'source "$1"; ui_pref_get 2>&1' _ "$SCRIPT")"; rc=$?
    (( rc == 0 )) || { echo "start-ui es un FIFO: ui_pref_get se cuelga o falla (código $rc)" >&2; return 1; }
    [[ -z "$raw" ]] || { echo "start-ui es un FIFO: ui_pref_get dice '$raw'" >&2; return 1; }
}

# --- 9.6 (b): entrada «interface»: la terminal abre el panel y lo fija; el panel fija la terminal y se cierra ---
T256() {
    new_env
    local home="$TEST_ROOT/home" blocked="$TEST_ROOT/bloqueado" saved_home lang out label want f emulator
    mkdir -p "$home" "$blocked" "${BIN_DST%/*}"; : > "$blocked/.config"
    saved_home="$home"; HOME="$home"; unset XDG_CONFIG_HOME
    f="$home/.config/vpn-netguard/start-ui"
    printf '#!/bin/sh\n' > "$BIN_DST"; chmod +x "$BIN_DST"
    mock zenity 'exit 0'
    DISPLAY=:99; unset WAYLAND_DISPLAY
    pause_enter() { :; }
    cmd_panel() { echo panel >> "$TEST_ROOT/calls"; }
    panel_info_box() { printf '%s\n' "$1" >> "$TEST_ROOT/info"; }
    panel_error_box() { printf '%s\n' "$1" >> "$TEST_ROOT/error"; }
    panel_status_markup() { :; }
    # Terminal: abre el panel una vez, lo fija y el aviso dice cómo volver (etiqueta de la entrada en el panel).
    for lang in es en; do
        UI_LANGUAGE="$lang"; rm -rf "$home/.config"; : > "$TEST_ROOT/calls"; : > "$TEST_ROOT/err"
        label="$(menu_label interface panel)"; printf -v want -- "$(ui_t menu.interface_panel_set)" "$label"
        out="$(menu_open_gui_panel 2>"$TEST_ROOT/err")"
        [[ -n "$label" && "$out" == "$want" && ! -s "$TEST_ROOT/err" ]] || { echo "$lang terminal: aviso distinto de '$want' (salida: '$out')" >&2; return 1; }
        [[ "$(cat "$f")" == panel && "$(cat "$TEST_ROOT/calls")" == panel ]] || { echo "$lang terminal: no fija el panel o no lo abre una vez" >&2; return 1; }
    done
    # Sin dónde guardar: lo dice por stderr, no cambia nada y abre el panel igualmente.
    UI_LANGUAGE=es; : > "$TEST_ROOT/calls"; HOME="$blocked"
    out="$(menu_open_gui_panel 2>"$TEST_ROOT/err")"; HOME="$saved_home"
    [[ -z "$out" && "$(cat "$TEST_ROOT/err")" == "$(ui_t menu.interface_save_failed)" && "$(cat "$TEST_ROOT/calls")" == panel ]] || { echo "terminal: guardado fallido (salida '$out')" >&2; return 1; }
    # Sin zenity, sin sesión gráfica o sin instalar: dice por qué, no fija nada y no abre el panel.
    rm -rf "$home/.config"; : > "$TEST_ROOT/calls"
    out="$(PATH="$TEST_ROOT/sin-zenity"; hash -r; menu_open_gui_panel)"
    [[ "$out" == *"$(ui_t panel.zenity_missing)"* ]] || { echo "sin zenity: no lo dice" >&2; return 1; }
    out="$(unset DISPLAY WAYLAND_DISPLAY; menu_open_gui_panel)"
    [[ "$out" == *"$(ui_t menu.unsupported_gui)"* ]] || { echo "sin sesión gráfica: no lo dice" >&2; return 1; }
    out="$(BIN_DST="$TEST_ROOT/no-such/vpn-netguard.sh"; menu_open_gui_panel)"
    [[ "$out" == *"$(ui_t menu.installed_first)"* ]] || { echo "sin instalar: no lo dice" >&2; return 1; }
    [[ ! -e "$home/.config" && ! -s "$TEST_ROOT/calls" ]] || { echo "una guarda fijó el panel o lo abrió" >&2; return 1; }
    # Panel: «Volver a la terminal» fija la terminal y marca el cierre, sin avisos. Hace falta una terminal (la de
    # quien lanzó el panel) o, sin ella (acceso directo del escritorio), un emulador donde abrirla; sin ninguna
    # de las dos no cambia nada y lo dice en una caja de error. Esa guarda va antes que el guardado.
    terminal_emulator_find() { (( emulator )) && printf 'xterm|-e'; }
    for want in "1 0" "0 1"; do
        have_terminal() { (( ${want% *} )); }; emulator="${want#* }"
        ui_pref_set panel || return 1; : > "$TEST_ROOT/info"; : > "$TEST_ROOT/error"
        PANEL_BACK_TO_TERMINAL=0; panel_back_to_terminal
        [[ "$(cat "$f")" == terminal && "$PANEL_BACK_TO_TERMINAL" == 1 && ! -s "$TEST_ROOT/info" && ! -s "$TEST_ROOT/error" ]] || { echo "panel (terminal/emulador $want): no fija la terminal o avisa" >&2; return 1; }
    done
    have_terminal() { return 1; }; emulator=0
    ui_pref_set panel || return 1; : > "$TEST_ROOT/info"; : > "$TEST_ROOT/error"
    PANEL_BACK_TO_TERMINAL=0; panel_back_to_terminal
    [[ "$(cat "$f")" == panel && "$PANEL_BACK_TO_TERMINAL" == 0 && "$(cat "$TEST_ROOT/error")" == "$(ui_t panel.interface_no_terminal)" && ! -s "$TEST_ROOT/info" ]] || { echo "panel sin terminal ni emulador: cambia algo o no lo dice" >&2; return 1; }
    : > "$TEST_ROOT/error"; HOME="$blocked"
    panel_back_to_terminal; HOME="$saved_home"
    [[ "$(cat "$TEST_ROOT/error")" == "$(ui_t panel.interface_no_terminal)" ]] || { echo "panel sin terminal ni emulador y sin dónde guardar: el motivo no es la falta de terminal" >&2; return 1; }
    # Sin dónde guardar (con terminal, o sin ella pero con emulador): caja de error, no cierra el panel y no avisa de nada más.
    for want in "1 0" "0 1"; do
        have_terminal() { (( ${want% *} )); }; emulator="${want#* }"
        : > "$TEST_ROOT/info"; : > "$TEST_ROOT/error"; PANEL_BACK_TO_TERMINAL=0; HOME="$blocked"
        panel_back_to_terminal; HOME="$saved_home"
        [[ "$(cat "$TEST_ROOT/error")" == "$(ui_t panel.interface_save_failed)" && ! -s "$TEST_ROOT/info" && "$PANEL_BACK_TO_TERMINAL" == 0 ]] || { echo "panel (terminal/emulador $want): guardado fallido" >&2; return 1; }
    done
    # Bucle del panel (zenity simulado: devuelve las elecciones de zseq y falla, como Cancelar, al agotarse):
    # la entrada 14 cierra el panel tras fijar la terminal; si no se puede fijar, sigue abierto.
    zenity_ui() {
        local c; echo x >> "$TEST_ROOT/zcalls"
        c="$(head -n1 "$TEST_ROOT/zseq")"; sed -i 1d "$TEST_ROOT/zseq"
        [[ -n "$c" ]] || return 1
        printf '%s\n' "$c"
    }
    have_terminal() { return 0; }
    [[ "$(menu_id_of_number panel 14)" == interface ]] || return 1
    ui_pref_set panel || return 1; printf '%s\n' 14 > "$TEST_ROOT/zseq"; : > "$TEST_ROOT/zcalls"
    panel_main_menu
    [[ "$(cat "$f")" == terminal && "$(wc -l < "$TEST_ROOT/zcalls")" == 1 ]] || { echo "bucle: no cierra tras fijar la terminal" >&2; return 1; }
    # El cierre del panel anterior no se arrastra: el siguiente sigue abierto tras una acción (menu_run_panel simulado).
    printf '%s\n' 1 > "$TEST_ROOT/zseq"; : > "$TEST_ROOT/zcalls"; : > "$TEST_ROOT/ran"
    ( menu_run_panel() { echo "$1" >> "$TEST_ROOT/ran"; }; panel_main_menu )
    [[ "$(cat "$TEST_ROOT/ran")" == status && "$(wc -l < "$TEST_ROOT/zcalls")" == 2 ]] || { echo "bucle: arrastra el cierre anterior" >&2; return 1; }
    printf '%s\n' 14 > "$TEST_ROOT/zseq"; : > "$TEST_ROOT/zcalls"; HOME="$blocked"
    panel_main_menu 2>/dev/null; HOME="$saved_home"
    [[ "$(wc -l < "$TEST_ROOT/zcalls")" == 2 ]] || { echo "bucle: se cierra aunque no se pudo fijar" >&2; return 1; }
    # Sin terminal ni emulador la entrada tampoco cierra el panel ni cambia la interfaz fijada.
    have_terminal() { return 1; }; emulator=0
    ui_pref_set panel || return 1; printf '%s\n' 14 > "$TEST_ROOT/zseq"; : > "$TEST_ROOT/zcalls"; : > "$TEST_ROOT/error"
    panel_main_menu
    [[ "$(cat "$f")" == panel && "$(wc -l < "$TEST_ROOT/zcalls")" == 2 && "$(cat "$TEST_ROOT/error")" == "$(ui_t panel.interface_no_terminal)" ]] || { echo "bucle: sin terminal ni emulador se cierra o cambia la interfaz" >&2; return 1; }
}

T257() {
    new_env
    local home="$TEST_ROOT/home" xdg="$TEST_ROOT/xdg" calls="$TEST_ROOT/calls" f want got src lang ne win
    mkdir -p "$home" "$xdg/vpn-netguard"; HOME="$home"; unset XDG_CONFIG_HOME
    f="$home/.config/vpn-netguard/start-ui"
    # Despacho: el bloque del «case "$CMD"» del punto de entrada, hecho función y con sus entradas
    # simuladas (lee $SCRIPT: ve también a los mutantes). Sin argumentos manda la interfaz fijada y «launch»
    # (el acceso directo del escritorio) también, pero se lo dice a cmd_start_ui; «menu» y «panel» son
    # explícitos y no la consultan; tras cerrarse el panel, «panel» sigue en el menú de texto si se pidió.
    src="$(awk '/^if \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$\{0\}" \]\]; then$/ {f=1; next} f && /^fi$/ {exit} f' "$SCRIPT")"
    [[ "$src" == *'case "$CMD" in'* ]] || { echo "no se encuentra el despacho del punto de entrada" >&2; return 1; }
    eval "dispatch() { $src
}"
    routed() ( cmd_start_ui() { echo "start_ui${1:+ $1}"; }; cmd_menu() { echo menu; }; cmd_panel() { echo panel; }; panel_continue_in_terminal() { echo continue; }; dispatch "$@" )
    for want in "|start_ui" "launch|start_ui launch" "menu|menu" "panel|panel,continue"; do
        got="$(routed "${want%%|*}" | paste -sd, -)"
        [[ "$got" == "${want#*|}" ]] || { echo "despacho de '${want%%|*}': llega a '$got' y no a '${want#*|}'" >&2; return 1; }
    done
    # D13 y have_terminal con un terminal de verdad (pty; Intro ya tecleado): el mensaje de la pausa sale por
    # stderr y solo con un terminal de entrada; sin él no escribe nada ni falla. Va antes de simular pause_enter.
    cat > "$TEST_ROOT/pty_run.py" <<'PY'
import os, pty, signal, sys
script, lang, snippet = sys.argv[1:4]
signal.alarm(30)
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', '-c', 'source "$1"; UI_LANGUAGE="$2"; ' + snippet, 'bash', script, lang])
os.write(fd, b'\n')
out = b''
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
_, status = os.waitpid(pid, 0)
rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 99
sys.stdout.write(out.decode('utf-8', 'replace') + '\nrc=%d\n' % rc)
PY
    pty_run() {   # pty_run <idioma> <orden>: PTY_OUT (lo que ve quien teclea) y PTY_RC (código de la orden)
        local raw
        raw="$(python3 "$TEST_ROOT/pty_run.py" "$SCRIPT" "$1" "$2")" || return 1
        [[ "$raw" == *$'\n'rc=* ]] || return 1
        PTY_OUT="${raw%$'\n'rc=*}"; PTY_RC="${raw##*$'\n'rc=}"
    }
    for lang in es en; do
        UI_LANGUAGE="$lang"; want="$(ui_t press_enter)"
        pty_run "$lang" 'pause_enter >/dev/null' && [[ "$PTY_RC" == 0 && "$PTY_OUT" == *"$want"* ]] ||
            { echo "pause_enter ($lang): con terminal el mensaje sale por stderr y la pausa termina (rc ${PTY_RC:-?}, salida '${PTY_OUT:-}')" >&2; return 1; }
    done
    pty_run en 'pause_enter 2>/dev/null' && [[ "$PTY_RC" == 0 && "$PTY_OUT" != *"$want"* ]] ||
        { echo "pause_enter: el mensaje no debe salir por stdout (salida '${PTY_OUT:-}')" >&2; return 1; }
    [[ -z "$(printf '\n' | pause_enter 2>&1)" && -z "$(pause_enter <&- 2>&1)" ]] ||
        { echo "pause_enter: sin terminal de entrada no escribe nada" >&2; return 1; }
    pty_run es have_terminal && [[ "$PTY_RC" == 0 ]] || { echo "have_terminal: con entrada y salida en un terminal es cierto" >&2; return 1; }
    pty_run es 'have_terminal >/dev/null' && [[ "$PTY_RC" == 1 ]] || { echo "have_terminal: con la salida redirigida es falso" >&2; return 1; }
    pty_run es 'have_terminal </dev/null' && [[ "$PTY_RC" == 1 ]] || { echo "have_terminal: con la entrada redirigida es falso" >&2; return 1; }
    # cmd_start_ui con sus colaboradores simulados: cada llamada queda en $calls, por orden. La pausa anota lo
    # que ya se había escrito por stderr (el aviso debe salir antes: menu_clear lo borraría). open_text_menu y
    # panel_continue_in_terminal son los reales: solo se simula la terminal (have_terminal), el emulador
    # (terminal_emulator_find, terminal_open) y las ventanas del panel.
    cmd_menu() { echo menu >> "$calls"; }
    cmd_panel() { echo panel >> "$calls"; PANEL_BACK_TO_TERMINAL="$STUB_BACK"; }
    panel_blocker() { echo blocker >> "$calls"; [[ -n "$STUB_WHY" ]] && printf '%s' "$STUB_WHY"; }
    pause_enter() { printf 'pause[%s]\n' "$(cat "$TEST_ROOT/err")" >> "$calls"; }
    have_terminal() { (( STUB_TTY )); }
    terminal_emulator_find() { (( STUB_EMU )) && printf 'xterm|-e'; }
    terminal_open() { echo "window[$*]" >> "$calls"; (( STUB_EMU )); }
    panel_info_box() { printf 'info[%s]\n' "$1" >> "$calls"; }
    panel_error_box() { printf 'error[%s]\n' "$1" >> "$calls"; }
    run_start() {   # run_start <preferencia: panel|terminal|none> <launch 0|1> <terminal 0|1> <emulador 0|1> <motivo del bloqueo> <«volver» 0|1>
        STUB_TTY="$3"; STUB_EMU="$4"; STUB_WHY="$5"; STUB_BACK="$6"; PANEL_BACK_TO_TERMINAL=0
        if [[ "$1" == none ]]; then rm -f "$f"; else ui_pref_set "$1" || return 1; fi
        : > "$calls"; : > "$TEST_ROOT/err"
        if (( $2 )); then cmd_start_ui launch >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; else cmd_start_ui >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; fi
        STATUS=$?
        got="$(paste -sd, "$calls")"
    }
    expect_start() {   # expect_start <escenario> <llamadas esperadas> <stderr esperado> [<código esperado, 0>]; stdout siempre vacío
        [[ "$got" == "$2" && "$(cat "$TEST_ROOT/err")" == "$3" && "$STATUS" == "${4:-0}" && ! -s "$TEST_ROOT/out" ]] || {
            echo "$1: llamadas '$got' (esperadas '$2'), stderr '$(cat "$TEST_ROOT/err")' (esperado '$3'), código $STATUS (esperado ${4:-0}), stdout '$(cat "$TEST_ROOT/out")'" >&2
            return 1; }
    }
    UI_LANGUAGE=en; ne="$(ui_t ui.no_terminal_emulator)"; win="window[bash $SELF menu]"
    want='motivo de prueba: no se puede abrir el panel'
    # Sin argumentos (se ejecuta desde una terminal): sin elección o con la terminal fijada, el menú de texto, también
    # con la entrada en una tubería, y sin consultar el panel.
    run_start terminal 0 1 1 "" 0 && expect_start "terminal fijada" menu "" || return 1
    run_start none 0 1 1 "" 0 && expect_start "sin elección" menu "" || return 1
    run_start terminal 0 0 1 "" 0 && expect_start "terminal fijada, entrada que no es un terminal (sin ventana)" menu "" || return 1
    # Panel fijado: se abre; si se cierra sin más termina, y con «Volver a la terminal» sigue en el menú de texto, aquí
    # con terminal o en una ventana nueva sin ella (con el aviso por stderr si no hay emulador).
    run_start panel 0 1 1 "" 0 && expect_start "panel fijado que se cierra" blocker,panel "" || return 1
    run_start panel 0 1 1 "" 1 && expect_start "«volver a la terminal» con terminal" blocker,panel,menu "" || return 1
    run_start panel 0 0 1 "" 1 && expect_start "«volver» sin terminal, con emulador" "blocker,panel,$win" "" || return 1
    run_start panel 0 0 0 "" 1 && expect_start "«volver» sin terminal ni emulador" "blocker,panel,$win" "$ne" || return 1
    # Panel fijado pero imposible de abrir: el motivo sale por stderr antes de la pausa (solo con terminal) y sigue
    # en el menú de texto sin cambiar la interfaz fijada.
    run_start panel 0 1 1 "$want" 0 && expect_start "panel imposible, con terminal" "blocker,pause[$want],menu" "$want" || return 1
    [[ "$(ui_pref_get)" == panel ]] || { echo "un panel imposible no cambia la interfaz fijada" >&2; return 1; }
    run_start panel 0 0 1 "$want" 0 && expect_start "panel imposible, sin terminal (sin pausa)" blocker,menu "$want" || return 1
    # «launch» (el acceso directo del escritorio, sin terminal): sin elección abre el panel y, con la terminal
    # fijada, el menú de texto en una ventana nueva sin consultar el panel; con una terminal, aquí mismo.
    run_start none 1 0 1 "" 0 && expect_start "launch sin elección: el panel" blocker,panel "" || return 1
    run_start panel 1 0 1 "" 0 && expect_start "launch con el panel fijado" blocker,panel "" || return 1
    run_start panel 1 0 1 "" 1 && expect_start "launch: «volver a la terminal» abre una ventana" "blocker,panel,$win" "" || return 1
    run_start terminal 1 0 1 "" 0 && expect_start "launch con la terminal fijada: una ventana" "$win" "" || return 1
    run_start terminal 1 1 1 "" 0 && expect_start "launch con la terminal fijada y una terminal: aquí" menu "" || return 1
    # «launch» con el panel imposible de abrir (el motivo, que el acceso directo no muestra, sale por stderr) y la
    # terminal fijada pero sin emulador: lo dice por stderr y abre el panel con un aviso, o se rinde (código 1) si
    # tampoco se puede abrir.
    run_start panel 1 0 1 "$want" 0 && expect_start "launch, panel imposible: una ventana" "blocker,$win" "$want" || return 1
    run_start terminal 1 0 0 "" 0 && expect_start "launch sin terminal ni emulador: el panel con un aviso" "$win,blocker,info[$ne],panel" "$ne" || return 1
    run_start terminal 1 0 0 "$want" 0 && expect_start "launch sin terminal, emulador ni panel" "$win,blocker" "$ne" 1 || return 1
    run_start panel 1 0 0 "$want" 0 && expect_start "launch con el panel fijado e imposible, sin emulador" "blocker,$win,blocker" "$want"$'\n'"$ne" 1 || return 1
    # El ciclo con la función real: «Volver a la terminal» fija la terminal y los arranques siguientes ya no abren el
    # panel, ni desde una terminal ni desde el acceso directo; sin terminal ni emulador no puede volver y avisa.
    cmd_panel() { echo panel >> "$calls"; panel_back_to_terminal; }
    run_start panel 0 1 1 "" 0 && expect_start "ciclo: el panel vuelve a la terminal" blocker,panel,menu "" || return 1
    [[ "$(ui_pref_get)" == terminal ]] || { echo "ciclo: la terminal no queda fijada" >&2; return 1; }
    : > "$calls"; cmd_start_ui >/dev/null 2>&1
    [[ "$(paste -sd, "$calls")" == menu ]] || { echo "ciclo: el arranque siguiente no abre solo el menú de texto" >&2; return 1; }
    run_start panel 1 0 1 "" 0 && expect_start "ciclo (launch): el panel vuelve a la terminal" "blocker,panel,$win" "" || return 1
    run_start terminal 1 0 1 "" 0 && expect_start "ciclo (launch): el siguiente arranque abre solo la ventana" "$win" "" || return 1
    run_start panel 1 0 0 "" 0 && expect_start "ciclo (launch): sin terminal ni emulador no vuelve" "blocker,panel,error[$(ui_t panel.interface_no_terminal)]" "" || return 1
    [[ "$(ui_pref_get)" == panel ]] || { echo "ciclo: sin terminal ni emulador la interfaz fijada cambió" >&2; return 1; }
    # De extremo a extremo con el script real (zenity simulado: el motivo es la falta de sesión gráfica): con el
    # panel fijado avisa por stderr y sigue en el menú de texto; con la terminal fijada no avisa.
    mock zenity 'exit 0'
    UI_LANGUAGE=en; want="$(ui_t menu.unsupported_gui)"
    echo panel > "$xdg/vpn-netguard/start-ui"
    got="$(printf '0\n' | env -u DISPLAY -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$xdg" VPN_NETGUARD_LANGUAGE=en bash "$SCRIPT" 2>"$TEST_ROOT/err")"
    grep -Fxq -- "$want" "$TEST_ROOT/err" && grep -Fxq -- " 0) $(ui_t menu.exit0)" <<< "$got" ||
        { echo "real: con el panel fijado y sin sesión gráfica debe avisar por stderr y abrir el menú de texto" >&2; return 1; }
    echo terminal > "$xdg/vpn-netguard/start-ui"
    printf '0\n' | env -u DISPLAY -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$xdg" VPN_NETGUARD_LANGUAGE=en bash "$SCRIPT" >/dev/null 2>"$TEST_ROOT/err"
    ! grep -Fq -- "$want" "$TEST_ROOT/err" || { echo "real: con la terminal fijada no debe avisar de ningún panel" >&2; return 1; }
}

# --- 9.6 (d): la ayuda (es y en) y la cabecera describen la interfaz de arranque: sin argumentos y «launch» abren
# la fijada (terminal o panel); «menu» y «panel» no la consultan. La expresión sale de los avisos de guardado ---
T258() {
    new_env
    local lang phrase always ignoring window cond key out home f rel head_txt flat
    mkdir -p "$TEST_ROOT/home"; home="$TEST_ROOT/home"; HOME="$home"; unset XDG_CONFIG_HOME
    for lang in es en; do
        UI_LANGUAGE="$lang"; ui_init
        case "$lang" in
            es) phrase='interfaz de arranque'; always='siempre'; ignoring='sin consultar'; window='ventana'; cond='si es la terminal' ;;
            *)  phrase='start interface';      always='always';  ignoring='ignoring';      window='window';  cond='if it is the terminal' ;;
        esac
        [[ "$(ui_t menu.interface_save_failed)" == *"$phrase"* ]] || { echo "$lang: los avisos no dicen «$phrase»" >&2; return 1; }
        for key in usage.no_args usage.menu usage.panel usage.launch; do
            [[ "$(ui_t "$key")" == *"$phrase"* ]] || { echo "$key ($lang) sin «$phrase»" >&2; return 1; }
        done
        # Sin argumentos nombra las dos interfaces posibles; «menu» siempre el texto; «menu» y «panel» no la consultan.
        out="$(ui_t usage.no_args)"
        [[ "$out" == *terminal* && "$out" == *panel* && "$out" != *"menú interactivo"* && "$out" != *"interactive terminal menu"* ]] || { echo "usage.no_args ($lang): no nombra terminal y panel" >&2; return 1; }
        [[ "$(ui_t usage.menu)" == *"$always"* && "$(ui_t usage.menu)" == *"$ignoring"* ]] || { echo "usage.menu ($lang): no dice que es siempre el texto y no consulta" >&2; return 1; }
        [[ "$(ui_t usage.panel)" == *"$ignoring"* ]] || { echo "usage.panel ($lang): no dice que no consulta" >&2; return 1; }
        # «launch» sigue la interfaz de arranque y solo la terminal lleva ventana propia (sin elección abre el panel).
        out="$(ui_t usage.launch)"
        [[ "$out" == *"$cond"* && "$out" == *"$window"* ]] || { echo "usage.launch ($lang): no dice que solo la terminal lleva ventana propia" >&2; return 1; }
        # Y son las que salen en --help.
        out="$(VPN_NETGUARD_LANGUAGE=$lang bash "$SCRIPT" --help 2>&1)"
        for key in usage.no_args usage.menu usage.panel usage.launch; do
            grep -Fxq -- "$(ui_t "$key")" <<< "$out" || { echo "--help ($lang) sin $key" >&2; return 1; }
        done
    done
    # Cabecera (en inglés): las tres líneas, «launch» y el párrafo con el fichero de la preferencia (ruta real de
    # ui_pref_file). Las frases del párrafo se parten en líneas de comentario: se comparan con el texto en una línea.
    f="$(ui_pref_file)" || return 1; rel="${f#"$home"/}"
    head_txt="$(awk '/^set -o pipefail$/ {exit} 1' "$SCRIPT")"   # solo la cabecera: el i18n repite las etiquetas
    flat="$(sed -n 's/^# \{0,1\}//p' <<< "$head_txt" | tr '\n' ' ' | tr -s ' ')"
    grep -Eq '^#   vpn-netguard\.sh +\(no arguments\) opens the start interface' <<< "$head_txt" || { echo "cabecera: sin argumentos" >&2; return 1; }
    grep -Eq '^#   vpn-netguard\.sh +menu +always opens the terminal menu .*ignores the start interface' <<< "$head_txt" || { echo "cabecera: menu" >&2; return 1; }
    grep -Eq '^#   vpn-netguard\.sh +panel .*ignores the start interface' <<< "$head_txt" || { echo "cabecera: panel" >&2; return 1; }
    grep -Eq '^#   vpn-netguard\.sh +launch +what the Applications menu entry runs: the start interface' <<< "$head_txt" || { echo "cabecera: launch" >&2; return 1; }
    grep -Fq -- "(~/$rel," <<< "$head_txt" || { echo "cabecera: no nombra ~/$rel" >&2; return 1; }
    UI_LANGUAGE=en; ui_init
    grep -Fq -- "\"$(ui_t panel.back_to_terminal)\" entry" <<< "$flat" || { echo "cabecera: no nombra la entrada del panel" >&2; return 1; }
    grep -Fq -- '("launch") both follow it' <<< "$flat" || { echo "cabecera: no dice que «launch» sigue la interfaz de arranque" >&2; return 1; }
    grep -Fq -- 'the first opens the terminal menu and the second the panel' <<< "$flat" || { echo "cabecera: no dice qué abre cada uno sin elección" >&2; return 1; }
}

# --- Fase 9.8, hallazgo 1 de la revisión de calidad: saltos de línea en ui_wrap, ui_note y ui_row ---
# Un salto de línea separa palabras igual que un espacio: el texto es un solo párrafo. Antes ui_wrap leía solo
# la primera línea y perdía el resto (también ui_note y la rama larga de ui_row, que lo usan), y la rama corta
# de ui_row imprimía el segundo renglón sin sangría.
T259() {
    local nl=$'\n' text_sp="" text_nl="" i out
    C_B= C_0= C_OK= C_WARN= C_BAD=   # sin color aunque la suite se lance desde un terminal
    for i in {1..40}; do text_sp+="palabra$i "; text_nl+="palabra$i$nl"; done
    # ui_wrap: un salto, varios, líneas en blanco y saltos en los extremos.
    [[ "$(ui_wrap ' ' ' ' "a${nl}b")" == ' a b' ]] || { echo "ui_wrap: un salto de línea no equivale a un espacio" >&2; return 1; }
    [[ "$(ui_wrap '  ' '  ' "uno${nl}${nl}${nl}dos")" == '  uno dos' ]] || { echo "ui_wrap: líneas en blanco" >&2; return 1; }
    [[ "$(ui_wrap '  ' '  ' "${nl}uno${nl}")" == '  uno' ]] || { echo "ui_wrap: saltos al principio y al final" >&2; return 1; }
    # Un texto largo con saltos se ajusta igual que con espacios: las 40 palabras, en varias líneas y sin pasar del ancho.
    out="$(ui_wrap '  ' '    ' "$text_nl")"
    [[ "$out" == "$(ui_wrap '  ' '    ' "$text_sp")" ]] || { echo "ui_wrap: el salto no equivale al espacio" >&2; return 1; }
    [[ "$(grep -o 'palabra[0-9]*' <<< "$out" | wc -l)" -eq 40 && "$(wc -l <<< "$out")" -gt 1 &&
       "$(wc -L <<< "$out")" -le "$UI_WIDTH" ]] || { echo "ui_wrap: palabras perdidas o líneas demasiado anchas" >&2; return 1; }
    # ui_note con cada nivel, y ui_row en sus dos ramas (valor corto y valor que baja a su línea), con y sin símbolo.
    [[ "$(ui_note ok "a${nl}b")" == '  ✓ a b' && "$(ui_note warn "uno${nl}${nl}dos")" == '  ⚠ uno dos' &&
       "$(ui_note bad "x${nl}y")" == '  ✗ x y' ]] || { echo "ui_note: texto con saltos de línea" >&2; return 1; }
    [[ "$(ui_row Etiqueta "a${nl}b")" == "$(ui_row Etiqueta 'a b')" && "$(ui_row Etiqueta "a${nl}b" | wc -l)" -eq 1 &&
       "$(ui_row Etiqueta "a${nl}b" ok)" == "$(ui_row Etiqueta 'a b' ok)" ]] || { echo "ui_row: valor corto con saltos de línea" >&2; return 1; }
    [[ "$(ui_row Etiqueta "$text_nl")" == "$(ui_row Etiqueta "$text_sp")" &&
       "$(ui_row Etiqueta "$text_nl" warn)" == "$(ui_row Etiqueta "$text_sp" warn)" ]] || { echo "ui_row: valor largo con saltos de línea" >&2; return 1; }
}

T260() {
    new_env
    nmcli_utf8_mock
    mock systemctl 'exit 1'
    mock ping 'exit 1'
    mock iptables 'exit 1'
    KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race"
    HAVE_IP6TABLES=0; KS_VPN_CANDIDATES=(); DNS_SERVERS=''
    require_root() { :; }
    C_B= C_0= C_OK= C_WARN= C_BAD=   # sin color aunque la suite se lance desde un terminal
    local hdr='timestamp,epoch,event,detail' flat want
    # «Historial de eventos»: eventos = líneas menos la cabecera, nunca por debajo de cero. La pantalla se
    # compara en una sola línea: según la ruta, el valor puede partirse en dos.
    history_row_says() {   # $1 = recuento esperado
        flat="$(print_status 2>&1 | tr -s ' \n' ' ')"
        printf -v want -- "$(ui_t status.v_history_on)" "$EVENT_HISTORY_FILE" "$1"
        [[ "$flat" == *"$want"* ]]
    }
    UI_LANGUAGE=es; ui_init
    rm -f "$EVENT_HISTORY_FILE"
    history_row_says 0 || { echo "sin fichero: la fila no dice 0 eventos" >&2; return 1; }
    : > "$EVENT_HISTORY_FILE"
    history_row_says 0 || { echo "fichero vacío: la fila no dice 0 eventos" >&2; return 1; }
    printf '%s' "$hdr" > "$EVENT_HISTORY_FILE"
    history_row_says 0 || { echo "cabecera sin salto de línea: la fila no dice 0 eventos" >&2; return 1; }
    printf '%s\n' "$hdr" > "$EVENT_HISTORY_FILE"
    history_row_says 0 || { echo "solo la cabecera: la fila no dice 0 eventos" >&2; return 1; }
    printf '%s\na,1,vpn_up,"x"\nb,2,vpn_down,"y"\n' "$hdr" > "$EVENT_HISTORY_FILE"
    history_row_says 2 && [[ "$flat" == *'(2 eventos registrados)'* ]] || { echo "cabecera y 2 eventos: la fila no dice 2 eventos" >&2; return 1; }
    UI_LANGUAGE=en; ui_init
    history_row_says 2 && [[ "$flat" == *'(2 events recorded)'* ]] || { echo "en: la fila no dice 2 events" >&2; return 1; }
    # Con el historial desactivado la fila lo dice y no muestra ruta ni recuento.
    EVENT_HISTORY_ENABLE=false
    flat="$(print_status 2>&1 | tr -s ' \n' ' ')"
    [[ "$flat" == *"$(ui_t status.l_history) $(ui_t status.v_history_off)"* && "$flat" != *"$EVENT_HISTORY_FILE"* ]] ||
        { echo "historial desactivado: la fila no lo dice o muestra un recuento" >&2; return 1; }
}

T261() {
    new_env
    local hdr='timestamp,epoch,event,detail'
    history_ok() {   # $1 = situación, $2 = líneas esperadas: la cabecera, una sola vez y la primera
        [[ "$(head -n1 "$EVENT_HISTORY_FILE")" == "$hdr" && "$(grep -cFx "$hdr" "$EVENT_HISTORY_FILE")" -eq 1 &&
           "$(wc -l < "$EVENT_HISTORY_FILE")" -eq "$2" ]] ||
            { echo "$1: $(wc -l < "$EVENT_HISTORY_FILE") líneas (se esperaban $2) o cabecera mal colocada" >&2; return 1; }
    }
    rm -f "$EVENT_HISTORY_FILE"
    record_event vpn_up one || return 1
    history_ok 'sin fichero' 2 || return 1
    # Vacío (vaciado a mano o una primera escritura fallida): también recibe la cabecera.
    : > "$EVENT_HISTORY_FILE"
    record_event vpn_down two || return 1
    history_ok 'fichero vacío' 2 || return 1
    grep -q ',vpn_down,"two"$' "$EVENT_HISTORY_FILE" || { echo "fichero vacío: falta el evento" >&2; return 1; }
    # Con contenido no se repite la cabecera ni se pierde lo anterior.
    record_event vpn_up three || return 1
    history_ok 'con contenido' 3 || return 1
    grep -q ',vpn_down,"two"$' "$EVENT_HISTORY_FILE" || { echo "con contenido: se perdió el evento anterior" >&2; return 1; }
}

T262() {
    new_env
    local hdr='timestamp,epoch,event,detail' i
    history_text() {   # la cabecera y los eventos e$1..e$2, uno por línea (solo la cabecera si $1 > $2)
        printf '%s\n' "$hdr"
        for (( i = $1; i <= $2; i++ )); do printf '2026-01-01 00:00:00,%d,vpn_up,"e%d"\n' "$i" "$i"; done
    }
    history_is() {   # $1 = situación; $2..$3 = eventos que deben quedar tras la cabecera (la cabecera, una vez y la primera)
        history_text "$2" "$3" | cmp -s - "$EVENT_HISTORY_FILE" ||
            { echo "$1: se esperaban la cabecera y e$2..e$3; hay: $(tr '\n' '|' < "$EVENT_HISTORY_FILE")" >&2; return 1; }
    }
    no_temp() {   # el recorte no deja ficheros temporales junto al historial
        ! compgen -G "$EVENT_HISTORY_FILE.*" > /dev/null || { echo "$1: queda un temporal: $(ls "$EVENT_HISTORY_FILE".*)" >&2; return 1; }
    }
    EVENT_HISTORY_MAX_LINES=3
    # Dentro del límite no se toca nada (ni se repite la cabecera).
    history_text 1 2 > "$EVENT_HISTORY_FILE"
    trim_event_history || return 1
    history_is 'menos eventos que el límite' 1 2 || return 1
    history_text 1 3 > "$EVENT_HISTORY_FILE"
    trim_event_history || return 1
    history_is 'tantos eventos como el límite' 1 3 || return 1
    # Por encima: la cabecera y los más recientes, en orden.
    history_text 1 4 > "$EVENT_HISTORY_FILE"
    trim_event_history || return 1
    history_is 'un evento por encima del límite' 2 4 || return 1
    history_text 1 6 > "$EVENT_HISTORY_FILE"
    trim_event_history || return 1
    history_is 'seis eventos, límite 3' 4 6 || return 1
    no_temp 'tras recortar' || return 1
    # 0 = sin límite.
    EVENT_HISTORY_MAX_LINES=0
    history_text 1 6 > "$EVENT_HISTORY_FILE"
    trim_event_history || return 1
    history_is 'límite 0' 1 6 || return 1
    EVENT_HISTORY_MAX_LINES=3
    # Un recorte que falla deja el historial como estaba, sin temporales, y no hace fallar al registro
    # (record_event ya escribió el evento y record_event_if_changed aún debe guardar su estado).
    mock tail 'exit 1'
    history_text 1 6 > "$EVENT_HISTORY_FILE"
    trim_event_history || { echo "un recorte fallido devolvió error" >&2; return 1; }
    history_is 'recorte fallido' 1 6 || return 1
    no_temp 'recorte fallido' || return 1
    rm -f "$MOCKBIN/tail"; hash -r
    # record_event recorta en cada escritura: nunca más de la cabecera y 3 eventos.
    rm -f "$EVENT_HISTORY_FILE"
    for i in 1 2 3 4 5; do record_event vpn_up "e$i" || return 1; done
    [[ "$(head -n1 "$EVENT_HISTORY_FILE")" == "$hdr" && "$(wc -l < "$EVENT_HISTORY_FILE")" -eq 4 &&
       "$(sed -n 's/.*,"\(e[0-9]*\)"$/\1/p' "$EVENT_HISTORY_FILE" | paste -sd' ')" == 'e3 e4 e5' ]] ||
        { echo "record_event: se esperaban la cabecera y e3 e4 e5; hay: $(tr '\n' '|' < "$EVENT_HISTORY_FILE")" >&2; return 1; }
    no_temp 'tras record_event'
}

# --- 9.6: emuladores de terminal donde abrir el menú de texto cuando no hay terminal (el acceso directo del
# escritorio): la tabla, el primero instalado y cómo se abre una orden en él. Las funciones corren con un PATH
# hermético (bash, env y cat) y los emuladores simulados que cada caso crea: uno real del equipo no cuenta ---
T263() {
    new_env
    local hb="$TEST_ROOT/hbin" t line got want rc
    local -a order
    mkdir -p "$hb"
    for t in bash env cat; do ln -s "$(command -v "$t")" "$hb/$t"; done
    emu() {   # emu <nombre>...: emuladores simulados; anotan sus argumentos (cada uno entre <>) en args.<nombre> y salen con $EMU_RC
        local n
        for n in "$@"; do
            cat > "$hb/$n" <<SCRIPT
#!/usr/bin/env bash
for a in "\$@"; do printf '<%s>' "\$a"; done > "$TEST_ROOT/args.$n"
exit "\${EMU_RC:-0}"
SCRIPT
            chmod +x "$hb/$n"
        done
        hash -r
    }
    drop() { local n; for n in "$@"; do rm -rf "${hb:?}/$n"; done; hash -r; }
    find_is() {   # find_is <escenario> <salida esperada> <código esperado>
        got="$(PATH="$hb" terminal_emulator_find)"; rc=$?
        [[ "$got" == "$2" && "$rc" == "$3" ]] ||
            { echo "$1: terminal_emulator_find da '$got' (código $rc) y no '$2' ($3)" >&2; return 1; }
    }
    # La tabla: el orden es la preferencia (x-terminal-emulator, el que eligió el sistema, primero) y cada emulador
    # lleva la opción que precede a la orden (kitty y foot, ninguna).
    want='x-terminal-emulator|-e gnome-terminal|-- konsole|-e xfce4-terminal|-x mate-terminal|-x lxterminal|-e terminator|-x alacritty|-e kitty| foot| xterm|-e'
    got="$(PATH="$hb" terminal_emulators)"; got="${got//$'\n'/ }"
    [[ "$got" == "$want" ]] || { echo "la tabla de emuladores no es la esperada: '$got'" >&2; return 1; }
    mapfile -t order < <(PATH="$hb" terminal_emulators)
    # Sin emuladores no hay ninguno; un fichero sin permiso de ejecución o un directorio con su nombre tampoco lo es.
    find_is "sin emuladores" "" 1 || return 1
    printf '%s\n' '#!/usr/bin/env bash' > "$hb/konsole"
    mkdir "$hb/gnome-terminal"
    find_is "un fichero no ejecutable y un directorio no son emuladores" "" 1 || return 1
    emu xterm
    find_is "solo xterm" 'xterm|-e' 0 || return 1
    drop xterm konsole gnome-terminal
    emu kitty
    find_is "solo kitty (sin opción)" 'kitty|' 0 || return 1
    drop kitty
    # Con todos instalados manda el orden de la tabla, no el del PATH: se va quitando el primero.
    for line in "${order[@]}"; do emu "${line%%|*}"; done
    for line in "${order[@]}"; do
        find_is "el primero de la tabla ($line)" "$line" 0 || return 1
        drop "${line%%|*}"
    done
    find_is "agotada la tabla" "" 1 || return 1
    # terminal_open: la orden va tras la opción del emulador (o directamente si no la lleva), con cada argumento
    # intacto (espacios, comodín, parecido a una opción, vacío); el estado del emulador no cuenta.
    for line in "${order[@]}"; do
        t="${line%%|*}"; emu "$t"
        EMU_RC=7 PATH="$hb" terminal_open bash 'a b' '*' --x ''; rc=$?
        want="${line#*|}"; [[ -n "$want" ]] && want="<$want>"
        want+='<bash><a b><*><--x><>'
        got="$(< "$TEST_ROOT/args.$t")"
        [[ "$got" == "$want" && "$rc" == 0 ]] ||
            { echo "terminal_open con $t: llama con '$got' (esperado '$want'), código $rc (esperado 0)" >&2; return 1; }
        drop "$t"
    done
    # Sin emulador devuelve 1 sin ejecutar la orden ni escribir nada.
    got="$(PATH="$hb" terminal_open bash -c ': > "$1"' _ "$TEST_ROOT/ran" 2>&1)"; rc=$?
    [[ "$rc" == 1 && -z "$got" && ! -e "$TEST_ROOT/ran" ]] ||
        { echo "terminal_open sin emulador: debe devolver 1 sin ejecutar ni escribir nada (código $rc, salida '$got')" >&2; return 1; }
}

# --- 9.6, de extremo a extremo: «launch» como lo ejecuta el acceso directo del escritorio. Copia «instalada» del script
# (BIN_DST, CONF_DIR y STATE_DIR en el directorio de la prueba), el lanzador que ella misma genera (su línea Exec=), zenity
# y x-terminal-emulator simulados y un PATH hermético (bash, env, cat, mkdir, mktemp, mv y rm más lo que cada caso instale): ni zenity ni
# emuladores del equipo ni su instalación. Sin terminal (entrada y salidas redirigidas), como el lanzador, y con un pty
# para «launch» desde una terminal ---
T264() {
    new_env
    local r="$TEST_ROOT/e2e" t line ne nogui noterm win menu_line prompt
    local hb="$r/hbin" inst="$r/inst/vpn-netguard.sh" home="$r/home" calls="$r/calls"
    local -a argv base
    mkdir -p "$r/inst" "$r/mocks" "$hb" "$home"
    for t in bash env cat mkdir mktemp mv rm; do ln -s "$(command -v "$t")" "$hb/$t"; done
    sed -e "s#^BIN_DST=.*#BIN_DST=\"$inst\"#" -e "s#^CONF_DIR=.*#CONF_DIR=\"$r/etc\"#" -e "s#^STATE_DIR=.*#STATE_DIR=\"$r/state\"#" \
        "$SCRIPT" > "$inst" && chmod +x "$inst" || return 1
    [[ "$(diff "$SCRIPT" "$inst" | grep -c '^>')" == 3 ]] ||
        { echo "la copia instalada debe cambiar solo las líneas BIN_DST, CONF_DIR y STATE_DIR" >&2; return 1; }
    cat > "$r/mocks/zenity" <<'MOCK'
#!/usr/bin/env bash
# zenity simulado (solo órdenes internas de bash): anota la llamada y, en «--list», responde con la siguiente línea de la
# cola; sin ninguna es como cerrar la ventana.
kind=""; text=""
for a in "$@"; do
    case "$a" in --list|--info|--error) kind="${a#--}" ;; --text=*) text="${a#--text=}" ;; esac
done
if [[ "$kind" == list ]]; then
    printf 'zenity list\n' >> "$E2E_CALLS"
    [[ -s "$E2E_QUEUE" ]] || exit 1
    mapfile -t q < "$E2E_QUEUE"; : > "$E2E_QUEUE"
    for a in "${q[@]:1}"; do printf '%s\n' "$a" >> "$E2E_QUEUE"; done
    printf '%s\n' "${q[0]}"
else
    printf 'zenity %s[%s]\n' "$kind" "$text" >> "$E2E_CALLS"
fi
exit 0
MOCK
    cat > "$r/mocks/x-terminal-emulator" <<'MOCK'
#!/usr/bin/env bash
# x-terminal-emulator simulado: anota la llamada y ejecuta la orden que sigue a «-e» como una ventana de terminal
# (entrada tecleada de antemano, salida a E2E_WINDOW_OUT).
printf 'emulator %s\n' "$*" >> "$E2E_CALLS"
[[ "${1:-}" == -e ]] || exit 2
shift
"$@" <<< "0" >> "$E2E_WINDOW_OUT" 2>&1
MOCK
    chmod +x "$r/mocks/zenity" "$r/mocks/x-terminal-emulator"
    cat > "$r/pty_launch.py" <<'PY'
import os, pty, signal, sys
data, cmd = sys.argv[1], sys.argv[2:]
signal.alarm(30)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
os.write(fd, data.encode())
out = b''
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
_, status = os.waitpid(pid, 0)
rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 99
sys.stdout.write(out.decode('utf-8', 'replace') + '\nrc=%d\n' % rc)
PY
    # El lanzador que genera la propia copia: su Exec= es lo que se ejecuta en los casos siguientes.
    UI_LANGUAGE=en; ui_init
    line="$(bash -c 'source "$1"; UI_LANGUAGE=en; ui_init; write_desktop_file' _ "$inst" | grep '^Exec=')"
    read -ra argv <<< "${line#Exec=}"
    [[ "${#argv[@]}" == 2 && "${argv[0]}" == "$inst" && "${argv[1]}" == launch ]] ||
        { echo "el lanzador no ejecuta «launch» de la copia instalada: '$line'" >&2; return 1; }
    ne="$(ui_t ui.no_terminal_emulator)"; nogui="$(ui_t menu.unsupported_gui)"; noterm="$(ui_t panel.interface_no_terminal)"
    prompt="$(ui_t press_enter)"; menu_line=" 0) $(ui_t menu.exit0)"; win="emulator -e bash $inst menu"
    base=(env -i PATH="$hb" HOME="$home" DISPLAY=:9 VPN_NETGUARD_LANGUAGE=en E2E_CALLS="$calls" E2E_QUEUE="$r/queue" E2E_WINDOW_OUT="$r/window")
    provide() {   # provide [zenity] [x-terminal-emulator]: lo único del PATH aparte de las herramientas básicas
        rm -f "$hb/zenity" "$hb/x-terminal-emulator"
        local n; for n in "$@"; do ln -s "$r/mocks/$n" "$hb/$n"; done
    }
    prepare() {   # prepare <preferencia: panel|terminal|none|keep> <cola de zenity>: estado inicial de un caso
        local a
        if [[ "$1" != keep ]]; then
            rm -rf "$home/.config"
            [[ "$1" == none ]] || { mkdir -p "$home/.config/vpn-netguard" && printf '%s\n' "$1" > "$home/.config/vpn-netguard/start-ui"; }
        fi
        : > "$calls"; : > "$r/window"; : > "$r/queue"
        for a in $2; do printf '%s\n' "$a" >> "$r/queue"; done
    }
    pref() { [[ -f "$home/.config/vpn-netguard/start-ui" ]] && cat "$home/.config/vpn-netguard/start-ui"; return 0; }
    run_launch() {   # run_launch <preferencia> <cola> [VAR=valor...]: el Exec= sin terminal, como el menú de Aplicaciones
        local p="$1" q="$2"; shift 2
        prepare "$p" "$q"
        "${base[@]}" "$@" "${argv[@]}" </dev/null >"$r/out" 2>"$r/err"
        STATUS=$?
    }
    expect_launch() {   # expect_launch <caso> <llamadas> <stderr> <código> <preferencia final: panel|terminal|none> <ventana: menu|none>
        local got; got="$(paste -sd, "$calls")"
        [[ "$got" == "$2" && "$(< "$r/err")" == "$3" && "$STATUS" == "$4" && ! -s "$r/out" && "$(pref)" == "${5/none/}" ]] || {
            echo "$1: llamadas '$got' (esperadas '$2'), stderr '$(< "$r/err")' (esperado '$3'), código $STATUS (esperado $4), stdout '$(< "$r/out")', preferencia '$(pref)' (esperada '${5/none/}')" >&2
            return 1; }
        if [[ "$6" == menu ]]; then
            grep -Fxq -- "$menu_line" "$r/window" || { echo "$1: la ventana no muestra el menú de texto" >&2; return 1; }
        else
            [[ ! -s "$r/window" ]] || { echo "$1: no debía abrirse ninguna ventana: $(< "$r/window")" >&2; return 1; }
        fi
    }
    run_pty() {   # run_pty <preferencia> <teclas> <cola> [VAR=valor...]: «launch» en un pty (hay terminal); PTY_OUT y PTY_RC
        local p="$1" keys="$2" q="$3" raw; shift 3
        prepare "$p" "$q"
        raw="$(python3 "$r/pty_launch.py" "$keys" "${base[@]}" "$@" "${argv[@]}")" || return 1
        [[ "$raw" == *$'\n'rc=* ]] || return 1
        PTY_OUT="${raw%$'\n'rc=*}"; PTY_RC="${raw##*$'\n'rc=}"
    }
    before() { local a="${PTY_OUT%%"$1"*}" b="${PTY_OUT%%"$2"*}"; [[ "$PTY_OUT" == *"$1"* && "$PTY_OUT" == *"$2"* && ${#a} -lt ${#b} ]]; }
    # Sin terminal, como el acceso directo. Sin elección abre el panel; «Volver a la terminal» fija la terminal y abre
    # el menú de texto en una ventana nueva, y el siguiente arranque ya solo abre la ventana (sin tocar el panel).
    provide zenity x-terminal-emulator
    run_launch none "" ; expect_launch "sin elección: el panel" "zenity list" "" 0 none none || return 1
    run_launch none 14; expect_launch "panel: «volver a la terminal»" "zenity list,$win" "" 0 terminal menu || return 1
    run_launch keep ""; expect_launch "el arranque siguiente: solo la ventana" "$win" "" 0 terminal menu || return 1
    # Sin zenity ni emulador con la terminal fijada no hay dónde abrir nada: lo dice y sale con 1.
    provide
    run_launch terminal ""; expect_launch "terminal fijada, sin zenity ni emulador" "" "$ne" 1 terminal none || return 1
    # Con el panel fijado y sin emulador no puede volver a la terminal: avisa en el panel y sigue en él (nada cambia).
    provide zenity
    run_launch panel 14; expect_launch "panel, sin emulador: «volver» avisa y no cambia" "zenity list,zenity error[$noterm],zenity list" "" 0 panel none || return 1
    # Con la terminal fijada y sin emulador abre el panel con un aviso (y también por stderr).
    run_launch terminal ""; expect_launch "terminal fijada, sin emulador: el panel con un aviso" "zenity info[$ne],zenity list" "$ne" 0 terminal none || return 1
    # Panel fijado pero sin sesión gráfica: el motivo sale por stderr, que el lanzador no muestra, y el menú de texto
    # va a una ventana nueva (así está hoy; el PLAN lo anota como dudoso).
    provide zenity x-terminal-emulator
    run_launch panel "" DISPLAY=; expect_launch "panel imposible: el motivo por stderr y el menú en una ventana" "$win" "$nogui" 0 panel menu || return 1
    # Con un terminal (pty): con la terminal fijada, aquí mismo y sin ventana; con el panel imposible, el motivo, la
    # pausa y el menú; sin elección el panel, y «Volver a la terminal» sigue en este mismo terminal.
    run_pty terminal $'0\n' "" || { echo "pty: no se pudo ejecutar" >&2; return 1; }
    [[ "$PTY_RC" == 0 && "$PTY_OUT" == *"$menu_line"* && ! -s "$calls" && "$(pref)" == terminal ]] ||
        { echo "launch en un terminal, terminal fijada: debe abrir el menú aquí, sin ventana (código $PTY_RC, llamadas '$(paste -sd, "$calls")', salida '$PTY_OUT')" >&2; return 1; }
    run_pty panel $'\n0\n' "" DISPLAY= || { echo "pty: no se pudo ejecutar" >&2; return 1; }
    [[ "$PTY_RC" == 0 && ! -s "$calls" && "$(pref)" == panel ]] && before "$nogui" "$prompt" && before "$prompt" "$menu_line" ||
        { echo "launch en un terminal, panel imposible: debe decir el motivo, esperar Intro y abrir el menú (código $PTY_RC, salida '$PTY_OUT')" >&2; return 1; }
    run_pty none $'0\n' 14 || { echo "pty: no se pudo ejecutar" >&2; return 1; }
    [[ "$PTY_RC" == 0 && "$(paste -sd, "$calls")" == "zenity list" && "$PTY_OUT" == *"$menu_line"* && "$(pref)" == terminal ]] ||
        { echo "launch en un terminal, sin elección: el panel y «volver» siguen en este terminal, sin ventana (código $PTY_RC, llamadas '$(paste -sd, "$calls")', salida '$PTY_OUT')" >&2; return 1; }
}

T265() {
    # Aislamiento: tras new_env ninguna ruta de instalación del script (estado, configuración, unidades, lanzador, icono,
    # bloqueo, políticas de navegador) apunta al sistema real. La suite se lanza como root y T49 desinstala: con el programa
    # instalado, una ruta sin redirigir se borra o se reescribe. Las rutas se leen de un bash limpio con el script recién
    # cargado (aquí new_env aún no las ha cambiado), así que una ruta nueva del script se detecta sin tocar este test.
    # SELF es el propio script bajo prueba: solo se lee.
    local names=() name val bad=0
    mapfile -t names < <(env -i PATH="$PATH" bash -c '
        base=" $(compgen -v | tr "\n" " ") "
        source "$1" >/dev/null 2>&1
        for v in $(compgen -v); do
            [[ "$base" == *" $v "* || "$v" == SELF || "${!v@a}" == *[aAn]* ]] && continue
            [[ "${!v:-}" == /* ]] && echo "$v"
        done' _ "$SCRIPT")
    [[ " ${names[*]} " == *" STATE_DIR "* ]] ||
        { echo "no se pudo leer la lista de rutas del script (falta STATE_DIR): '${names[*]}'" >&2; return 1; }
    new_env || return 1
    for name in "${names[@]}"; do
        val="${!name:-}"
        [[ "$val" == "$TEST_ROOT" || "$val" == "$TEST_ROOT"/* ]] ||
            { echo "new_env deja $name en '$val', fuera de $TEST_ROOT: redirígela en new_env" >&2; bad=1; }
    done
    return "$bad"
}

T266() {
    new_env
    local d dirs=("$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR/ana/Desktop" "$USERS_HOME_DIR/ana/Escritorio" "$USERS_HOME_DIR/luis/Desktop")
    mkdir -p "$(dirname "$BIN_DST")"
    touch "$BIN_DST"
    mock systemctl 'case "$1" in stop|disable|daemon-reload) exit 0;; is-active) exit 1;; *) exit 0;; esac'
    mock nmcli 'exit 0'
    mock iptables 'exit 1'
    HAVE_IP6TABLES=0
    # Un lanzador en cada Escritorio posible (root y dos usuarios, «Desktop» y «Escritorio») con un fichero ajeno al lado, y
    # un Escritorio sin lanzador.
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
        : > "$d/vpn-netguard.desktop"
        : > "$d/otro.desktop"
    done
    mkdir -p "$USERS_HOME_DIR/eva/Escritorio"
    ( cmd_uninstall ) >/dev/null 2>&1 </dev/null || { echo "la desinstalación debe terminar bien" >&2; return 1; }
    for d in "${dirs[@]}"; do
        [[ ! -e "$d/vpn-netguard.desktop" ]] || { echo "no retiró el lanzador de $d" >&2; return 1; }
        [[ -e "$d/otro.desktop" ]] || { echo "borró un fichero ajeno de $d" >&2; return 1; }
    done
    [[ -d "$USERS_HOME_DIR/eva/Escritorio" ]] || { echo "borró un Escritorio sin lanzador" >&2; return 1; }
}

run_test 'accented NetworkManager profile names keep their characters in status, privacy status, reconnection and the menu (nmcli in UTF-8)' T246
run_test 'monitoring: the metrics folder is chosen with the zenity folder browser (keep, choose, remove; cancelling saves nothing)' T247
run_test 'status screens: VPN NetGuard header, six sections, aligned 64-column rows, identical in C and UTF-8, kill switch screen' T248
run_test 'network privacy: its own section in the status, same rows as the privacy screen, aligned, localized and graded' T249
run_test 'status dialogs: short screens use --info (one button), the long one --text-info; titles, sizes and Pango escaping' T250
run_test 'network privacy settings: OK saves only what changed, asks for confirmation and applies; "saved" only when nothing was applied' T251
run_test 'config options: every allowed key has a short explanation (es/en), shown as the second line of each panel field and in the text menu; the three form texts keep every line within 90 characters' T252
run_test 'status: with DNS_SERVERS empty the "Kill switch DNS" row says what the rules do (any on IPv4, none on IPv6); a list is shown as written' T253
run_test 'config: values made only of spaces count as empty (PING_TARGETS back to its defaults with a warning, DNS_SERVERS and the free-text keys empty); the ping and DNS rules follow' T254
run_test 'start interface: per-user preference (no choice by default; absolute XDG_CONFIG_HOME, own directory only, private file, no temporaries, bad values rejected, a directory or FIFO is no choice)' T255
run_test 'interface entry: the terminal opens the panel and makes it the start interface; the panel makes the terminal the start interface and closes (notices, guards, failed save)' T256
run_test 'start: no arguments and "launch" open the pinned interface (without a choice, the terminal menu from a terminal and the panel from the launcher), "menu" and "panel" are explicit; a blocked panel is reported on stderr with a pause only on a terminal; "back to the terminal" continues in the text menu, here or in a terminal window; pause_enter and have_terminal on a real tty (D13)' T257
run_test 'start interface: the help (es/en) and the script header say that no arguments and "launch" open the chosen interface (only the terminal gets a window of its own) and that "menu" and "panel" ignore it' T258
run_test 'status helpers: a line break in the text counts as a space (ui_wrap, ui_note and both branches of ui_row keep every word; one paragraph, wrapped at 64 columns)' T259
run_test 'status: the event-history row counts events (lines minus the header) and is never negative (no file, empty file, header without a line break, header only; es/en); with the history disabled it shows no count' T260
run_test 'event history: the header is written before the first event when the file is missing or empty, and only then (earlier events are kept)' T261
run_test 'event history: the trim keeps the header and the newest events (0 = no limit; nothing changes within the limit; a failed trim leaves the history intact and leaves no temporaries; record_event trims on every write)' T262
run_test 'terminal emulators: the table (order and option of each), the first installed one wins, and terminal_open runs a command in it (arguments intact, the emulator status does not count, 1 and nothing run without one)' T263
run_test 'launch end to end from an installed copy and its own launcher line (Exec=): panel without a choice, "back to the terminal" opens a window and the next start only the window, no emulator or zenity, blocked panel, and launch from a terminal (pty)' T264
run_test 'test isolation: after new_env every installation path of the script (state, config, units, launcher, icon, lock, browser policies) points inside the test directory, so a run as root never touches an installed system' T265
run_test 'uninstall: removes the launcher copied to the desktops of root and of every user (Desktop and Escritorio), leaves other files and desktops without a launcher alone' T266

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
