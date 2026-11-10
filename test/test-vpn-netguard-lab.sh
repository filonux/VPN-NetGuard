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
COEXIST_MODE=auto
REAL_PATH="$PATH"
PATH="$MOCKBIN:$PATH"
V4_JUMP_COUNT="$TMP/v4-jumps"
V6_JUMP_COUNT="$TMP/v6-jumps"
printf '1\n' > "$V4_JUMP_COUNT"
printf '1\n' > "$V6_JUMP_COUNT"
export STATE_DIR CONFIG_FILE KILLSWITCH_OVERRIDE_FILE CHAIN_NAME CHAIN_NAME_V6 HAVE_IP6TABLES ALLOW_LAN DNS_SERVERS PING_TARGETS VPN_ENDPOINT_OVERRIDE DISABLE_IPV6 LOG_LEVEL DESKTOP_NOTIFICATIONS EVENT_HISTORY_ENABLE ALERT_HOOK COEXIST_MODE PATH RESTORE_OUT V4_JUMP_COUNT V6_JUMP_COUNT
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
COEXIST_MODE=auto
# Lo que foreign_vpn_scan dejaría tras ver NordVPN: el restore validado lleva sus reglas.
FOREIGN_TUNNELS=(nordlynx) FOREIGN_MARKS=(0xe1f1)
FIREFOX_POLICY_FILE="$TMP/firefox/policies.json"
FIREFOX_POLICY_MARKER="$STATE_DIR/browser-doh-firefox-created"
CHROME_POLICY_DIR="$TMP/chrome"
CHROMIUM_POLICY_DIR="$TMP/chromium"
CHROMIUM_BROWSER_POLICY_DIR="$TMP/chromium-browser"
CHROME_POLICY_MARKER="$STATE_DIR/browser-doh-chrome-created"
CHROMIUM_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-created"
CHROMIUM_BROWSER_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-browser-created"

# This script deliberately does not use `set -e` (the sourced script and its
# mocks rely on non-zero returns), so every check that must be able to fail the
# run propagates its status explicitly. Otherwise the final `echo` would make
# the whole lab exit 0 even when a validator or the namespace check failed.
RESTORE_OUT="$TMP/v4.restore" apply_killswitch_rules "tun0"
python3 "$BASE_DIR/test/validate_firewall_restore.py" v4 "$TMP/v4.restore" || exit 1
RESTORE_OUT="$TMP/v6.restore" apply_killswitch_rules6 "tun0"
python3 "$BASE_DIR/test/validate_firewall_restore.py" v6 "$TMP/v6.restore" || exit 1

# Prove the test itself is isolated in a real network namespace.
unshare -Urn bash -c 'set -e; ip link add labA type veth peer labB; ip link set labA up; ip link set labB up; ip link del labA' \
    || { echo 'NETNS: isolation unavailable (unshare/ip failed)' >&2; exit 1; }

# ensure_chain / ensure_chain6 con el iptables REAL, dentro de un netns propio
# (el del host no se toca). Sin mocks: el modelo de la suite no sustituye al
# comportamiento de iptables-nft. Sin iptables en el PATH se omite con aviso.
cat > "$TMP/real-jump.sh" <<'EOF'
set -u -o pipefail
source "$1"
LOG_LEVEL=error; DESKTOP_NOTIFICATIONS=false; EVENT_HISTORY_ENABLE=false; ALERT_HOOK=''
CHAIN_NAME=NETGUARD_KS; CHAIN_NAME_V6=NETGUARD_KS6
bad=0
rules() { "$1" -S OUTPUT | sed 1d | tr '\n' '|'; }
expect() {  # nombre, obtenido, esperado
    [[ "$2" == "$3" ]] && return 0
    printf 'FAIL real %s\n  obtenido: %s\n  esperado: %s\n' "$1" "$2" "$3" >&2; bad=1
}
# scenario <iptables|ip6tables> <ensure_chain|ensure_chain6> <cadena>
scenario() {
    local tool="$1" fn="$2" ch="$3" j="-A OUTPUT -j $3|" f1='-A OUTPUT -o eth9 -j DROP|' f2='-A OUTPUT -o eth8 -j DROP|'
    local before
    "$tool" -F OUTPUT; "$tool" -N "$ch" 2>/dev/null
    "$tool" -A OUTPUT -o eth9 -j DROP
    "$fn"; expect "$tool ausente" "$(rules "$tool")" "$j$f1"
    before="$(rules "$tool")"
    "$fn"; "$fn"; expect "$tool ya primera" "$(rules "$tool")" "$before"
    "$tool" -F OUTPUT
    "$tool" -A OUTPUT -o eth9 -j DROP; "$tool" -A OUTPUT -j "$ch"; "$tool" -A OUTPUT -o eth8 -j DROP
    "$fn"; expect "$tool desplazada" "$(rules "$tool")" "$j$f1$f2"
    "$tool" -F OUTPUT
    "$tool" -A OUTPUT -o eth9 -j DROP; "$tool" -A OUTPUT -j "$ch"; "$tool" -A OUTPUT -o eth8 -j DROP; "$tool" -A OUTPUT -j "$ch"
    "$fn"; expect "$tool repetida" "$(rules "$tool")" "$j$f1$f2"
    "$tool" -F OUTPUT
    "$tool" -A OUTPUT -o eth9 -j DROP; "$tool" -A OUTPUT -j "$ch"; "$tool" -A OUTPUT -o eth8 -j DROP; "$tool" -A OUTPUT -j "$ch"
    mkdir -p "$SHIM"; printf '#!/bin/sh\nexit 1\n' > "$SHIM/$tool-restore"; chmod +x "$SHIM/$tool-restore"
    PATH="$SHIM:$PATH" "$fn"; expect "$tool repetida sin transaccion" "$(rules "$tool")" "$j$f1$f2"
    rm -f "$SHIM/$tool-restore"
}
SHIM="$(mktemp -d)"
scenario iptables ensure_chain NETGUARD_KS
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT >/dev/null 2>&1; then
    HAVE_IP6TABLES=1; scenario ip6tables ensure_chain6 NETGUARD_KS6
else
    echo 'SKIP real ip6tables: no disponible' >&2
fi
rm -rf "$SHIM"
(( bad == 0 )) && echo 'REAL: ensure_chain/ensure_chain6 correctos con iptables real'
exit "$bad"
EOF
if PATH="$REAL_PATH" command -v iptables >/dev/null 2>&1; then
    unshare -Urn env PATH="$REAL_PATH" bash "$TMP/real-jump.sh" "$SCRIPT" || exit 1
else
    echo 'SKIP real iptables: no esta en el PATH' >&2
fi

# Convivencia (5.4) con el iptables REAL y un sysfs propio, dentro de su netns:
# foreign_vpn_scan lee las interfaces del netns (un veth "nordlynx" hace de
# túnel ajeno), la cadena se aplica con iptables-restore real y se comprueba qué
# paquetes salen. En auto pasan el túnel ajeno y un paquete con marca 0xe1f1 y el
# resto recibe EPERM por el DROP final; en strict se bloquean los tres. Se omite
# con aviso si faltan iptables, ip o python3 o el entorno no deja montar sysfs.
cat > "$TMP/real-coexist.sh" <<'EOF'
set -u -o pipefail
source "$1"
LOG_LEVEL=error; DESKTOP_NOTIFICATIONS=false; EVENT_HISTORY_ENABLE=false; ALERT_HOOK=''
CHAIN_NAME=NETGUARD_KS; CHAIN_NAME_V6=NETGUARD_KS6
ALLOW_LAN=false; DNS_SERVERS=''; PING_TARGETS='1.2.3.4'; VPN_ENDPOINT_OVERRIDE=''
DISABLE_IPV6=false; KS_VPN_CANDIDATES=(); VPN_IFACE=''; HAVE_IP6TABLES=0
bad=0
skip() { echo "SKIP real coexistencia: $1" >&2; exit 0; }
expect() {  # nombre, obtenido, esperado
    [[ "$2" == "$3" ]] && return 0
    printf 'FAIL real %s\n  obtenido: %s\n  esperado: %s\n' "$1" "$2" "$3" >&2; bad=1
}
send() {  # <4|6> <destino> <marca|0> -> SENT o ERR<errno>
    python3 - "$@" <<'PY'
import socket, sys
fam, dst, mark = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
s = socket.socket(socket.AF_INET6 if fam == '6' else socket.AF_INET, socket.SOCK_DGRAM)
if mark:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
try:
    s.sendto(b'x', (dst, 9))
    print('SENT')
except OSError as e:
    print(f'ERR{e.errno}')
PY
}
mount -t sysfs sysfs /sys 2>/dev/null || skip 'no se puede montar sysfs en el netns'
ip link set lo up || skip 'ip link falla'
mkveth() {  # <nombre> <v4/len> <v6/len>
    ip link add "$1" type veth peer name "${1}p" && ip link set "$1" up && ip link set "${1}p" up &&
    ip addr add "$2" dev "$1" || return 1
    ip -6 addr add "$3" dev "$1" nodad 2>/dev/null && V6=1
    return 0
}
V6=0
mkveth nordlynx 100.64.0.1/24 2001:db8:64::1/64 && mkveth eth9 203.0.113.1/24 2001:db8:113::1/64 ||
    skip 'no se pueden crear los veth'
# Las reglas v6 se aplican con ip6tables-restore real si hay ip6tables; los paquetes
# v6 solo se envían si el netns tiene pila IPv6 (hay kernels sin ella).
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT >/dev/null 2>&1; then
    HAVE_IP6TABLES=1
    (( V6 )) || echo 'SKIP real coexistencia IPv6 (paquetes): el netns no tiene pila IPv6; solo se comprueban las reglas' >&2
else
    echo 'SKIP real coexistencia IPv6: ip6tables no disponible' >&2
fi
# scenario <modo> <túnel> <marca> <resto> <reglas ajenas>: lo esperado para cada paquete
# (SENT o ERR1 = EPERM) y cuántas excepciones ajenas lleva cada cadena (2 en auto, 0 en strict).
scenario() {
    local mode="$1" want_tun="$2" want_mark="$3" want_plain="$4" want_rules="$5"
    COEXIST_MODE="$mode"
    coexist_scan
    if [[ "$mode" == auto ]]; then
        expect "$mode escaneo" "${FOREIGN_TUNNELS[*]}|${FOREIGN_MARKS[*]}" 'nordlynx|0xe1f1'
    else
        expect "$mode escaneo" "${#FOREIGN_TUNNELS[@]}|${#FOREIGN_MARKS[@]}" '0|0'
    fi
    apply_killswitch_rules '' || { echo "FAIL real $mode: apply_killswitch_rules" >&2; bad=1; }
    expect "$mode v4 salto primero" "$(iptables -S OUTPUT | sed -n 2p)" '-A OUTPUT -j NETGUARD_KS'
    expect "$mode v4 reglas ajenas" "$(iptables -S NETGUARD_KS | grep -cE -e '^-A NETGUARD_KS -o nordlynx -j RETURN$' -e '^-A NETGUARD_KS -m mark --mark 0xe1f1 -j RETURN$')" "$want_rules"
    expect "$mode v4 DROP final" "$(iptables -S NETGUARD_KS | tail -n1)" '-A NETGUARD_KS -j DROP'
    expect "$mode v4 túnel" "$(send 4 100.64.0.9 0)" "$want_tun"
    expect "$mode v4 marca" "$(send 4 203.0.113.9 0xe1f1)" "$want_mark"
    expect "$mode v4 resto" "$(send 4 203.0.113.9 0)" "$want_plain"
    expect "$mode v4 otra marca" "$(send 4 203.0.113.9 0x1234)" "$want_plain"
    (( HAVE_IP6TABLES )) || return 0
    apply_killswitch_rules6 '' || { echo "FAIL real $mode: apply_killswitch_rules6" >&2; bad=1; }
    expect "$mode v6 salto primero" "$(ip6tables -S OUTPUT | sed -n 2p)" '-A OUTPUT -j NETGUARD_KS6'
    expect "$mode v6 reglas ajenas" "$(ip6tables -S NETGUARD_KS6 | grep -cE -e '^-A NETGUARD_KS6 -o nordlynx -j RETURN$' -e '^-A NETGUARD_KS6 -m mark --mark 0xe1f1 -j RETURN$')" "$want_rules"
    expect "$mode v6 DROP final" "$(ip6tables -S NETGUARD_KS6 | tail -n1)" '-A NETGUARD_KS6 -j DROP'
    (( V6 )) || return 0
    expect "$mode v6 túnel" "$(send 6 2001:db8:64::9 0)" "$want_tun"
    expect "$mode v6 marca" "$(send 6 2001:db8:113::9 0xe1f1)" "$want_mark"
    expect "$mode v6 resto" "$(send 6 2001:db8:113::9 0)" "$want_plain"
}
scenario auto SENT SENT ERR1 2
scenario strict ERR1 ERR1 ERR1 0
# Auto otra vez: la cadena se rehace por completo y recupera las excepciones ajenas.
scenario auto SENT SENT ERR1 2
(( bad == 0 )) && echo 'REAL: convivencia correcta con iptables real (auto deja pasar túnel y marca ajenos; strict bloquea los tres)'
exit "$bad"
EOF
if PATH="$REAL_PATH" command -v iptables >/dev/null 2>&1 && PATH="$REAL_PATH" command -v ip >/dev/null 2>&1 &&
   PATH="$REAL_PATH" command -v python3 >/dev/null 2>&1; then
    unshare -Urnm env PATH="$REAL_PATH" bash "$TMP/real-coexist.sh" "$SCRIPT" || exit 1
else
    echo 'SKIP real coexistencia: faltan iptables, ip o python3' >&2
fi

# Cesión del bloqueo (5.4 c, 5.8) con el iptables REAL: la regla etiquetada de
# NordVPN (-m comment --comment nordvpn -j DROP) se lee de "iptables -S", la
# política decide y NetGuard cede (sin cadena ni salto), bloquea al forzar o en
# strict y retoma el bloqueo cuando la regla ajena desaparece. En ningún caso
# toca la regla ajena. Solo se sustituyen las dos funciones que hablan con
# NetworkManager; el firewall, el escaneo y la política son los reales.
cat > "$TMP/real-yield.sh" <<'EOF'
set -u -o pipefail
source "$1"
LOG_LEVEL=error; DESKTOP_NOTIFICATIONS=false; EVENT_HISTORY_ENABLE=false; ALERT_HOOK=''
CHAIN_NAME=NETGUARD_KS; CHAIN_NAME_V6=NETGUARD_KS6
ALLOW_LAN=false; DNS_SERVERS=''; PING_TARGETS='1.2.3.4'; VPN_ENDPOINT_OVERRIDE=''
DISABLE_IPV6=false; HAVE_IP6TABLES=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STATE_DIR="$T/state"; mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/wanted"
KILLSWITCH_OVERRIDE_FILE="$STATE_DIR/killswitch-override"
COEXIST_YIELD_FILE="$STATE_DIR/coexist-yield"
KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/ks-boot-race-marker"
SYS_NET_DIR="$T/sys"; mkdir -p "$SYS_NET_DIR/nordlynx"; echo unknown > "$SYS_NET_DIR/nordlynx/operstate"
detect_known_profiles() { KNOWN_VPN=(vpn); IGNORED_VPN=(); }
detect_active_state() { ACTIVE_VPN=''; VPN_IFACE=''; PHYS_IFACE=eth9; }
bad=0
expect() {  # nombre, obtenido, esperado
    [[ "$2" == "$3" ]] && return 0
    printf 'FAIL real %s\n  obtenido: %s\n  esperado: %s\n' "$1" "$2" "$3" >&2; bad=1
}
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT >/dev/null 2>&1; then HAVE_IP6TABLES=1; fi
fams=(iptables); (( HAVE_IP6TABLES )) && fams+=(ip6tables)
chain_of() { [[ "$1" == iptables ]] && echo NETGUARD_KS || echo NETGUARD_KS6; }
nord() {  # <add|del>: la regla del kill switch de NordVPN, tal como la escribe su cliente
    local f op=-A; [[ "$1" == del ]] && op=-D
    for f in "${fams[@]}"; do "$f" $op OUTPUT -o eth9 -m comment --comment nordvpn -j DROP || bad=1; done
}
# state <nombre> <salto: yes|no> <reglas ajenas: 0|1> <cadena: hay|no> <fichero de cesión: none|texto>
state() {
    local name="$1" jump="$2" nordn="$3" chain="$4" yield="$5" f c j
    for f in "${fams[@]}"; do
        c="$(chain_of "$f")"
        j="$("$f" -S OUTPUT | sed -n 2p)"
        if [[ "$jump" == yes ]]; then expect "$name $f salto primero" "$j" "-A OUTPUT -j $c"
        else expect "$name $f sin salto" "$("$f" -S OUTPUT | grep -c -- "-j $c")" 0; fi
        expect "$name $f regla ajena intacta" "$("$f" -S OUTPUT | grep -c -- '--comment nordvpn')" "$nordn"
        if [[ "$chain" == hay ]]; then
            expect "$name $f DROP final" "$("$f" -S "$c" | tail -n1)" "-A $c -j DROP"
            expect "$name $f sin ACCEPT" "$("$f" -S "$c" | grep -c ACCEPT)" 0
        else
            expect "$name $f sin cadena" "$("$f" -S | grep -c -- "-N $c")" 0
        fi
    done
    if [[ "$yield" == none ]]; then
        [[ ! -e "$COEXIST_YIELD_FILE" ]] || { echo "FAIL real $name: queda coexist-yield" >&2; bad=1; }
    else
        expect "$name coexist-yield" "$(cat "$COEXIST_YIELD_FILE" 2>/dev/null)" "$yield"
    fi
}
policy() { killswitch_apply_policy_now >/dev/null 2>&1 || { echo "FAIL real $1: killswitch_apply_policy_now" >&2; bad=1; }; }
KILLSWITCH_MODE=auto; COEXIST_MODE=auto; printf 'on\n' > "$STATE_FILE"
# 1. Sin kill switch ajeno: NetGuard bloquea.
policy 'sin ajeno'; state 'sin ajeno' yes 0 hay none
# 2. Aparece el de NordVPN: se detecta en iptables -S, NetGuard cede y deja la regla ajena.
nord add; policy 'cede'; state 'cede' no 1 no nordvpn
# 3. Con la cesión vigente, otra reconciliación no cambia nada.
policy 'cede otra vez'; state 'cede otra vez' no 1 no nordvpn
# 4. Forzado ON: bloquea siempre, convive con la regla ajena, deja pasar lo ajeno y no hay cesión.
printf 'on\n' > "$KILLSWITCH_OVERRIDE_FILE"; policy 'forzado'; state 'forzado' yes 1 hay none
for f in "${fams[@]}"; do
    c="$(chain_of "$f")"
    expect "forzado $f deja pasar el túnel ajeno" "$("$f" -S "$c" | grep -c -e '-o nordlynx -j RETURN')" 1
    expect "forzado $f deja pasar la marca ajena" "$("$f" -S "$c" | grep -c -e '--mark 0xe1f1 -j RETURN')" 1
done
# 5. Vuelve a auto: cede otra vez.
rm -f "$KILLSWITCH_OVERRIDE_FILE"; policy 'auto'; state 'auto' no 1 no nordvpn
# 6. strict: bloquea aunque haya un kill switch ajeno y no exceptúa nada ajeno.
COEXIST_MODE=strict; policy 'strict'; state 'strict' yes 1 hay none
for f in "${fams[@]}"; do
    expect "strict $f sin excepciones ajenas" "$("$f" -S "$(chain_of "$f")" | grep -c -e nordlynx -e mark)" 0
done
# 7. Desaparece la regla ajena: NetGuard retoma el bloqueo (sin cesión).
COEXIST_MODE=auto; nord del; policy 'retoma'; state 'retoma' yes 0 hay none
(( bad == 0 )) && echo 'REAL: cesión correcta con iptables real (cede ante la regla de NordVPN, bloquea al forzar o en strict y no toca la regla ajena)'
exit "$bad"
EOF
if PATH="$REAL_PATH" command -v iptables >/dev/null 2>&1; then
    unshare -Urn env PATH="$REAL_PATH" bash "$TMP/real-yield.sh" "$SCRIPT" || exit 1
else
    echo 'SKIP real cesion: iptables no esta en el PATH' >&2
fi

echo 'NETNS: isolated network capabilities available'
