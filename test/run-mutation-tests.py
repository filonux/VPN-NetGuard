#!/usr/bin/env python3
# Uso: run-mutation-tests.py [T<n> ...]   (sin argumentos, todas las mutaciones)
# Cada mutación es (nombre, test, texto a sustituir, sustituto). Orden de comprobación: 1) el texto aparece una
# sola vez en el script; 2) el test pasa, solo, contra el script original; 3) contra el mutante falla o se cuelga.
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'script' / 'vpn-netguard.sh'
SUITE = ROOT / 'test' / 'test-vpn-netguard.sh'
TIMEOUT = int(os.environ.get('MUTATION_TIMEOUT', '120'))   # s por mutante; un cuelgue cuenta como detectado

MUTATIONS = [
    ('IPv4 override parse guard removed', 'T124',
     '''if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]]; then
        host=""; port=""; proto=""; ip=""
        if read -r host port proto < <(parse_endpoint_spec "$VPN_ENDPOINT_OVERRIDE" 1194 udp); then''',
     '''if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]]; then
        host=""; port=""; proto=""; ip=""
        if true; then'''),
    ('IPv6 override parse guard removed', 'T125',
     '''if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]]; then
        host=""; port=""; proto=""; ip6=""
        if read -r host port proto < <(parse_endpoint_spec "$VPN_ENDPOINT_OVERRIDE" 1194 udp); then''',
     '''if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]]; then
        host=""; port=""; proto=""; ip6=""
        if true; then'''),
    ('IPv4 failure gates IPv6 teardown', 'T126',
     '''    if [[ $HAVE_IP6TABLES -eq 1 ]]; then
        while ipt6 -C OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null; do''',
     '''    if [[ $HAVE_IP6TABLES -eq 1 && $rc4 -eq 0 ]]; then
        while ipt6 -C OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null; do'''),
    ('Firefox conflict gates Chrome', 'T127',
     '''    if command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; then
''',
     '''    if (( rc_ff == 0 )) && { command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; }; then
'''),
    ('Firefox conflict gates Chromium', 'T129',
     '''    if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
''',
     '''    if (( rc_ff == 0 )) && { command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; }; then
'''),
    ('Config-language whitelist removed', 'T103',
     '''    [[ "$config_language" == es || "$config_language" == en ]] || config_language=es
''',
     '''    true
'''),
    ('Translation conflict entries removed', 'T132',
     """        es:log.browser_policy_conflict) text='Anonimato de red: %s ya existe y no lo creamos nosotros; no se toca' ;;
        en:log.browser_policy_conflict) text='Network privacy: %s already exists and was not created by VPN NetGuard; it is preserved' ;;
""",
     ''),
    ('Atomic restore DROP weakened', 'T135',
     '            echo "-A ${chain} -j DROP"\n',
     '            echo "-A ${chain} -j ACCEPT"\n'),
    ('Config reload ignores the file signature', 'T182',
     '''    [[ "$sig" == "$CONFIG_SIG" ]] && return 0\n''',
     '''    true\n'''),
    ('Unsafe config replaces the running config', 'T183',
     '''    if [[ "$sig" == missing ]] || ! config_file_is_safe "$CONFIG_FILE"; then\n''',
     '''    if [[ "$sig" == missing ]]; then\n'''),
    ('Periodic loop stops reloading the config', 'T184',
     '''        config_reload_if_changed announce\n        reconcile_async\n''',
     '''        reconcile_async\n'''),
    ('Event loop stops reloading the config', 'T185',
     '''        config_reload_if_changed\n        log_t debug log.nmcli_monitor "$line"\n''',
     '''        log_t debug log.nmcli_monitor "$line"\n'''),
    ('Text config save asks to restart again', 'T186',
     '''        elif [[ -x "$BIN_DST" && -z "$apply_cmd" ]]; then\n            echo "$(ui_t menu.saved_auto)"\n''',
     '''        elif [[ -x "$BIN_DST" && -z "$apply_cmd" ]] && menu_confirm "$(ui_t menu.saved_auto)"; then\n            menu_elevate systemctl restart "$SERVICE"\n'''),
    ('Graphical config import restarts the service again', 'T187',
     '''        panel_info_box "$(ui_t panel.imported_auto)"\n''',
     '''        panel_info_box "$(ui_t panel.imported_auto)"; panel_action_restart_service\n'''),
    ('Panel menu lists terminal-only entries', 'T188',
     '''        [[ "$iface" == panel && "$c" == text ]] && continue\n''',
     '''        :\n'''),
    ('The interface entry is terminal-only (the panel loses it)', 'T188',
     r'''E|▸|interface|all''',
     r'''E|▸|interface|text'''),
    ('Install comes before the interface entry (their numbers swap)', 'T188',
     '''E|▸|interface|all\nE|▸|install|text\nMODEL''',
     '''E|▸|install|text\nE|▸|interface|all\nMODEL'''),
    ('Text menu dispatches Uninstall to Install', 'T189',
     '''        uninstall) menu_do_uninstall ;;\n        interface) menu_open_gui_panel ;;''',
     '''        uninstall) menu_do_install ;;\n        interface) menu_open_gui_panel ;;'''),
    ('Text menu dispatches the interface entry to Install', 'T189',
     '''        interface) menu_open_gui_panel ;;\n        install) menu_do_install ;;''',
     '''        interface) menu_do_install ;;\n        install) menu_do_install ;;'''),
    ('Panel menu dispatches the interface entry to the status', 'T189',
     r'''        interface) panel_back_to_terminal ;;''',
     r'''        interface) panel_action_status ;;'''),
    ('Network privacy settings lose the extra Status button', 'T180',
     r'''result="$(zenity_ui "${dialog[@]}" --extra-button="$status_label")"; rc=$?''',
     r'''result="$(zenity_ui "${dialog[@]}")"; rc=$?'''),
    ('Network privacy settings take Cancel for the Status button', 'T180',
     r'''[[ $rc -eq 1 && "$result" == "$status_label" ]] || break''',
     r'''[[ $rc -eq 1 ]] || break'''),
    ('Network privacy settings close after showing the status', 'T180',
     r'''        panel_action_privacy_status
    done''',
     r'''        panel_action_privacy_status; return
    done'''),
    ('Panel menu opens the privacy status instead of the settings', 'T189',
     r'''        privacy) panel_action_configure_privacy ;;''',
     r'''        privacy) panel_action_privacy_status ;;'''),
    ('Forced-off kill switch shown as healthy', 'T190',
     '''        off) printf 'warn|%s|%s\\n' "$(ui_t menu.st_killswitch)" "$(ui_t menu.st_ks_off)" ;;\n''',
     '''        off) printf 'ok|%s|%s\\n' "$(ui_t menu.st_killswitch)" "$(ui_t menu.st_ks_off)" ;;\n'''),
    ('Panel header leaves dynamic data unescaped', 'T191',
     '''<b>$(pango_escape "$label")</b>: $(pango_escape "$value")"\n''',
     '''<b>$(pango_escape "$label")</b>: $value"\n'''),
    ('Panel list loses the Open button label', 'T191',
     '''            --ok-label="$(ui_t panel.btn_open)" --cancel-label="$(ui_t menu.exit0)" \\\n''',
     '''            --cancel-label="$(ui_t menu.exit0)" \\\n'''),
    ('Pango escape forgets ampersands', 'T192',
     '''    t="${t//&/&amp;}"; t="${t//</&lt;}"''',
     '''    t="${t//</&lt;}"'''),
    ('Kill switch override written unreadable for the panel', 'T193',
     '''    printf '%s\\n' "$value" > "$KILLSWITCH_OVERRIDE_FILE"\n    state_files_make_readable\n''',
     '''    printf '%s\\n' "$value" > "$KILLSWITCH_OVERRIDE_FILE"\n'''),
    ('Daemon start leaves old state files unreadable', 'T193',
     '''    mkdir -p "$STATE_DIR"\n    state_files_make_readable\n    log_t info log.daemon_start''',
     '''    mkdir -p "$STATE_DIR"\n    log_t info log.daemon_start'''),
    ('Terminal header drops the shared status lines', 'T194',
     '''        menu_print_status\n    else\n''',
     '''    else\n'''),
    ('Terminal status shows a warning with the healthy symbol', 'T194',
     '''warn) glyph='▲';''',
     '''warn) glyph='●';'''),
    ('Terminal status aligns columns counting bytes', 'T194',
     '''pad=$(( 17 - $(ui_text_len "$label") ))''',
     '''pad=$(( 17 - ${#label} ))'''),
    ('Terminal status ignores NO_COLOR', 'T194',
     '''    [[ -z "${NO_COLOR:-}" ]] && menu_stdout_is_tty\n''',
     '''    menu_stdout_is_tty\n'''),
    ('Menu label points to a key with no translation', 'T162',
     '''        *:status)         key=menu.status ;;''',
     '''        *:status)         key=menu.statuz ;;'''),
    ('Terminal menu rows lose their number format', 'T156',
     '''printf '%2d) %s %s\\n' "$num" "$icon" "$(menu_label "$id" text)"''',
     '''printf '%2d. %s %s\\n' "$num" "$icon" "$(menu_label "$id" text)"'''),
    ('IPv4 tunnel exception goes back to ACCEPT', 'T196',
     '''        rules+=("-o $tun_iface -j RETURN")\n    fi\n\n    # Todas las reglas''',
     '''        rules+=("-o $tun_iface -j ACCEPT")\n    fi\n\n    # Todas las reglas'''),
    ('IPv6 LAN exception goes back to ACCEPT', 'T196',
     '''rules+=("-d fc00::/7 -j RETURN")''',
     '''rules+=("-d fc00::/7 -j ACCEPT")'''),
    ('Jump already first is rewritten on every pass', 'T197',
     '''    (( count == 1 && first == 1 )) && return 0\n''',
     '''    false && return 0\n'''),
    ('Absent jump is appended instead of inserted first', 'T198',
     '''    if (( count == 0 )); then\n        \"$ipt_fn\" -I OUTPUT 1 -j \"$chain\"''',
     '''    if (( count == 0 )); then\n        \"$ipt_fn\" -A OUTPUT -j \"$chain\"'''),
    ('Jump repair deletes a position without checking it is still the jump', 'T199',
     '''        [[ \"$(\"$ipt_fn\" -S OUTPUT \"$pos\" 2>/dev/null)\" == \"$jump\" ]] || continue\n''',
     ''''''),
    ('Jump repair without a transaction never inserts the new jump', 'T199',
     '''    (( first == 1 )) || \"$ipt_fn\" -I OUTPUT 1 -j \"$chain\" || return 1\n''',
     '''    true\n'''),
    ('Jump repair miscounts positions after inserting', 'T199',
     '''    off=$(( 1 - first ))\n''',
     '''    off=0\n'''),
    ('IPv6 jump repair goes through iptables', 'T200',
     '''    ensure_jump ipt6 ip6tables-restore \"$CHAIN_NAME_V6\"''',
     '''    ensure_jump ipt ip6tables-restore \"$CHAIN_NAME_V6\"'''),
    ('Unreadable OUTPUT reinserts an existing jump', 'T200',
     '''        \"$ipt_fn\" -C OUTPUT -j \"$chain\" 2>/dev/null && return 0\n''',
     ''''''),
    ('Scan keeps results from the previous call', 'T201',
     '''    FOREIGN_TUNNELS=()\n    FOREIGN_MARKS=()\n    FOREIGN_KS=()\n    local sysdir=''',
     '''    local sysdir='''),
    ('Scan counts the NetworkManager tunnel as foreign', 'T201',
     '''        [[ -n \"${VPN_IFACE:-}\" && \"$iface\" == \"$VPN_IFACE\" ]] && continue\n''',
     ''''''),
    ('Scan counts a down tunnel as active', 'T201',
     '''        case \"$state\" in down|notpresent|lowerlayerdown) continue ;; esac\n''',
     ''''''),
    ('NordVPN rules without a DROP count as a kill switch', 'T202',
     '''            if [[ \"$line\" == *\" -j DROP\" || \"$line\" == *\" -j REJECT\"* ]]; then nord_drop=1; fi\n''',
     '''            nord_drop=1\n'''),
    ('A look-alike comment counts as NordVPN', 'T202',
     '''    local nord_re='--comment \"?nordvpn\"?( |$)'\n''',
     '''    local nord_re='--comment \"?nordvpn'\n'''),
    ('ProtonVPN kill switch connection is not recognised', 'T203',
     '''            case \"$name\" in pvpn-killswitch*|pvpn-ipv6leak-protection*) proton=1 ;; esac\n''',
     '''            case \"$name\" in pvpn-ipv6leak-protection*) proton=1 ;; esac\n'''),
    ('Scan lists OUTPUT with a different command', 'T204',
     '''        out=\"$(\"$fn\" -S OUTPUT 2>/dev/null)\" || continue\n''',
     '''        out=\"$(\"$fn\" -L OUTPUT 2>/dev/null)\" || continue\n'''),
    ('COEXIST_MODE is missing from the config whitelist', 'T205',
     '''KILLSWITCH_BOOT_RACE_AUTO_DISABLE|COEXIST_MODE|ALLOW_LAN''',
     '''KILLSWITCH_BOOT_RACE_AUTO_DISABLE|ALLOW_LAN'''),
    ('Invalid COEXIST_MODE falls back to strict', 'T205',
     '''COEXIST_MODE="auto" ;;''',
     '''COEXIST_MODE="strict" ;;'''),
    ('Text config menu offers COEXIST_MODE with the wrong options', 'T205',
     '''        COEXIST_MODE)            echo "enum:auto,strict" ;;''',
     '''        COEXIST_MODE)            echo "enum:auto,true" ;;'''),
    ('Foreign tunnel exception uses ACCEPT', 'T206',
     r'''printf -- '-o %s -j RETURN\n' "$item"''',
     r'''printf -- '-o %s -j ACCEPT\n' "$item"'''),
    ('Foreign mark exception uses ACCEPT', 'T206',
     r'''printf -- '-m mark --mark %s -j RETURN\n' "$item"''',
     r'''printf -- '-m mark --mark %s -j ACCEPT\n' "$item"'''),
    ('Foreign tunnel names are not validated', 'T206',
     r'''[[ "$item" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$ ]] && printf''',
     r'''printf'''),
    ('Foreign tunnel names may start with a dash', 'T206',
     r'''^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$''',
     r'''^[A-Za-z0-9_.-]{1,15}$'''),
    ('Foreign marks are not validated', 'T206',
     r'''[[ "$item" =~ ^0x[0-9a-fA-F]{1,8}$ ]] && printf''',
     r'''printf'''),
    ('Strict still passes foreign interfaces and marks', 'T206',
     r'''    [[ "$COEXIST_MODE" == auto ]] || return 0
    local item''',
     r'''    local item'''),
    ('IPv4 rules omit the foreign exceptions', 'T206',
     r'''    mapfile -t -O "${#rules[@]}" rules < <(coexist_pass_rules)

    # Tráfico que sale por el túnel: esta cadena no lo restringe''',
     r'''    :

    # Tráfico que sale por el túnel: esta cadena no lo restringe'''),
    ('IPv6 rules omit the foreign exceptions', 'T206',
     r'''    mapfile -t -O "${#rules[@]}" rules < <(coexist_pass_rules)

    if [[ -n "$tun_iface" ]]; then''',
     r'''    :

    if [[ -n "$tun_iface" ]]; then'''),
    ('Strict still runs the foreign scan', 'T207',
     r'''    [[ "$COEXIST_MODE" == auto ]] || return 0
    foreign_vpn_scan''',
     r'''    foreign_vpn_scan'''),
    ('Policy now decides without scanning', 'T207',
     r'''    detect_active_state
    coexist_scan
    coexist_sync_yield
    if killswitch_should_be_active; then
        if [[ -n "$ACTIVE_VPN" ]]; then
            apply_killswitch_allowing''',
     r'''    detect_active_state
    if killswitch_should_be_active; then
        if [[ -n "$ACTIVE_VPN" ]]; then
            apply_killswitch_allowing'''),
    ('Reconcile decides without scanning', 'T207',
     r'''    fi
    coexist_scan
    coexist_sync_yield

    if killswitch_should_be_active; then''',
     r'''    fi

    if killswitch_should_be_active; then'''),
    ('Zombie recovery decides without scanning', 'T207',
     r'''        detect_active_state
        coexist_scan
        coexist_sync_yield
        if killswitch_should_be_active; then''',
     r'''        detect_active_state
        if killswitch_should_be_active; then'''),
    # --- 5.4 (c): cesión del bloqueo ---
    ('Yielding removed from the automatic policy', 'T208',
     r'''want_vpn_active && ! coexist_yielding ;;''',
     r'''want_vpn_active ;;'''),
    ('KILLSWITCH_MODE=true also yields', 'T208',
     r'''        true) return 0 ;;
        auto) [[ ${#KNOWN_VPN[@]} -gt 0 ]] && want_vpn_active && ! coexist_yielding ;;''',
     r'''        true) ! coexist_yielding ;;
        auto) [[ ${#KNOWN_VPN[@]} -gt 0 ]] && want_vpn_active && ! coexist_yielding ;;'''),
    ('Strict still yields to a foreign kill switch', 'T208',
     r'''    [[ "$COEXIST_MODE" == auto && ${#FOREIGN_KS[@]} -gt 0 ]]''',
     r'''    [[ ${#FOREIGN_KS[@]} -gt 0 ]]'''),
    ('Yield state ignores a forced kill switch', 'T208',
     r'''    [[ "$(killswitch_override_value)" == auto && "$KILLSWITCH_MODE" == auto ]] || return 1''',
     r'''    [[ "$KILLSWITCH_MODE" == auto ]] || return 1'''),
    ('Yield file is rewritten and logged on every cycle', 'T209',
     r'''    [[ "$want" == "$have" ]] && return 0''',
     r'''    true'''),
    ('Yield start is not notified', 'T209',
     '    notify_event yield normal "$(ui_t notify.coexist_yield "$want")"\n',
     ''),
    ('Yield file stays unreadable for the panel', 'T209',
     r'''    for f in "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE" "$COEXIST_YIELD_FILE"; do''',
     r'''    for f in "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE"; do'''),
    ('Leaving the yield keeps the file', 'T209',
     r'''        rm -f "$COEXIST_YIELD_FILE"
        log_t info log.coexist_resume''',
     r'''        log_t info log.coexist_resume'''),
    ('Yield file write failure is silent', 'T209',
     '        log_t error log.coexist_state_fail "$COEXIST_YIELD_FILE"\n',
     ''),
    ('Policy now does not sync the yield', 'T210',
     r'''    detect_active_state
    coexist_scan
    coexist_sync_yield
    if killswitch_should_be_active; then
        if [[ -n "$ACTIVE_VPN" ]]; then
            apply_killswitch_allowing''',
     r'''    detect_active_state
    coexist_scan
    if killswitch_should_be_active; then
        if [[ -n "$ACTIVE_VPN" ]]; then
            apply_killswitch_allowing'''),
    ('Reconcile does not sync the yield', 'T210',
     r'''    coexist_scan
    coexist_sync_yield

    if killswitch_should_be_active; then''',
     r'''    coexist_scan

    if killswitch_should_be_active; then'''),
    ('Zombie recovery does not sync the yield', 'T210',
     r'''        coexist_scan
        coexist_sync_yield
        if killswitch_should_be_active; then''',
     r'''        coexist_scan
        if killswitch_should_be_active; then'''),
    ('Yielding still sends the kill switch disabled notice', 'T211',
     r'''[[ $removed -eq 1 ]] && ! killswitch_is_yielding && notify_event off''',
     r'''[[ $removed -eq 1 ]] && notify_event off'''),
    ('Status ignores the yield file', 'T212',
     r'''    local line policy_on=0 rules4=0
    coexist_yield_load
''',
     r'''    local line policy_on=0 rules4=0
'''),
    ('Check ignores the yield file', 'T212',
     r'''    detect_active_state
    coexist_yield_load

    # ks6_active''',
     r'''    detect_active_state

    # ks6_active'''),
    ('Menu header ignores the yield', 'T212',
     r'''if [[ "$KILLSWITCH_MODE" == auto ]] && (( wanted )) && coexist_yielding; then''',
     r'''if false; then'''),
    ('Menu header shows a yield without the protection wanted', 'T212',
     r'''if [[ "$KILLSWITCH_MODE" == auto ]] && (( wanted )) && coexist_yielding; then''',
     r'''if [[ "$KILLSWITCH_MODE" == auto ]] && coexist_yielding; then'''),
    ('Yield file loader accepts any name', 'T212',
     r'''        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && FOREIGN_KS+=("$name")''',
     r'''        FOREIGN_KS+=("$name")'''),
    ('Coexist section never warns in strict', 'T213',
     r'''        if (( blocking && ${#names[@]} )); then''',
     r'''        if false; then'''),
    ('Coexist section warns in strict without blocking', 'T213',
     r'''        if (( blocking && ${#names[@]} )); then''',
     r'''        if (( ${#names[@]} )); then'''),
    ('Coexist section does not scan in strict', 'T213',
     r'''    foreign_vpn_scan
    names=(''',
     r'''    [[ "$COEXIST_MODE" == auto ]] && foreign_vpn_scan
    names=('''),
    ('Coexist forced warning ignores the cause', 'T213',
     r'''            [[ "$(killswitch_override_value)" == on ]] && fix='killswitch auto'
''',
     r'''            :
'''),
    ('Coexist section announces a yield while blocking', 'T213',
     r'''    elif (( ${#FOREIGN_KS[@]} )); then
        if killswitch_is_yielding; then''',
     r'''    elif (( ${#FOREIGN_KS[@]} )); then
        if true; then'''),
    ('Coexist section leaks FOREIGN_* to the caller', 'T213',
     r'''    local -a FOREIGN_TUNNELS=() FOREIGN_MARKS=() FOREIGN_KS=() names=()''',
     r'''    local -a names=()'''),
    ('Proton stuck warning ignores live tunnels', 'T213',
     r'''*" protonvpn "* && ${#FOREIGN_TUNNELS[@]} -eq 0 && -z''',
     r'''*" protonvpn "* && -z'''),
    ('Proton stuck warning ignores the NetGuard VPN', 'T213',
     r'''${#FOREIGN_TUNNELS[@]} -eq 0 && -z "${ACTIVE_VPN:-}" ]]''',
     r'''${#FOREIGN_TUNNELS[@]} -eq 0 ]]'''),
    ('Coexist section hides the missing root', 'T213',
     r'''    have_root || ui_note warn "$(ui_t status.coexist_noroot)"
''',
     r'''    :
'''),
    ('Status omits the coexistence section', 'T213',
     r'''    ui_block "$(ui_t status.section_coexist)"
    print_coexist_status
''',
     r''''''),
    ('Doctor ignores the coexistence recommendations', 'T214',
     r'''        print_coexist_status || { (( worst < 1 )) && worst=1; }''',
     r'''        print_coexist_status || true'''),
    ('Doctor coexistence lowers a critical result', 'T214',
     r'''        print_coexist_status || { (( worst < 1 )) && worst=1; }''',
     r'''        print_coexist_status || worst=1'''),
    ('Doctor coexistence skips the detection', 'T214',
     r'''        detect_known_profiles; detect_active_state
        print_coexist_status''',
     r'''        print_coexist_status'''),
    ('Doctor coexistence runs without root', 'T214',
     r'''    ui_section "$(ui_t doctor.coexist)"
    if ! have_root; then''',
     r'''    ui_section "$(ui_t doctor.coexist)"
    if false; then'''),
    ('VPN_IGNORE is missing from the config whitelist', 'T215',
     r'''VPN_PRIORITY|VPN_IGNORE|VPN_ENDPOINT_OVERRIDE|CHECK_INTERVAL''',
     r'''VPN_PRIORITY|VPN_ENDPOINT_OVERRIDE|CHECK_INTERVAL'''),
    ('VPN_IGNORE defaults to a non-empty value', 'T215',
     r'''    VPN_IGNORE=""               # patrones''',
     r'''    VPN_IGNORE="x"              # patrones'''),
    ('Config line limit raised above 1024', 'T215',
     r'''CONFIG_VALUE_MAX=1024''',
     r'''CONFIG_VALUE_MAX=4096'''),
    ('VPN_IGNORE has no English label', 'T215',
     r''' en:VPN_IGNORE) echo 'VPN profiles to ignore' ;;''',
     r''''''),
    ('Text config menu omits VPN_IGNORE', 'T216',
     r'''VPN_CONNECTION VPN_PRIORITY VPN_IGNORE \
        VPN_ENDPOINT_OVERRIDE CHECK_INTERVAL''',
     r'''VPN_CONNECTION VPN_PRIORITY \
        VPN_ENDPOINT_OVERRIDE CHECK_INTERVAL'''),
    ('Panel key list omits VPN_IGNORE', 'T216',
     r'''ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_PRIORITY VPN_IGNORE VPN_ENDPO''',
     r'''ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_PRIORITY VPN_ENDPO'''),
    ('Panel shows no entry field for VPN_IGNORE', 'T216',
     r'''VPN_PRIORITY|VPN_IGNORE|VPN_ENDPOINT_OVERRIDE|DNS_SERVERS|ALERT_HOOK)
                forms+=(--add-entry=''',
     r'''VPN_PRIORITY|VPN_ENDPOINT_OVERRIDE|DNS_SERVERS|ALERT_HOOK)
                forms+=(--add-entry='''),
    ('Panel saves a blank VPN_IGNORE as an empty value', 'T216',
     r'''VPN_PRIORITY|VPN_IGNORE|VPN_ENDPOINT_OVERRIDE|DNS_SERVERS|ALERT_HOOK)
                new="$(panel_sentinel_or_keep''',
     r'''VPN_PRIORITY|VPN_ENDPOINT_OVERRIDE|DNS_SERVERS|ALERT_HOOK)
                new="$(panel_sentinel_or_keep'''),
    ('Config writer reports success without writing', 'T216',
     r'''    if menu_elevate install -D -o root -g root -m 644 "$tmpfile" "$CONFIG_FILE"; then''',
     r'''    if true; then'''),
    ('Ignored profiles stay in KNOWN_VPN', 'T217',
     r'''                if vpn_is_ignored "$name"; then IGNORED_VPN+=("$name"); else KNOWN_VPN+=("$name"); fi ;;''',
     r'''                KNOWN_VPN+=("$name") ;;'''),
    ('Ignored profiles are dropped instead of recorded', 'T217',
     r'''then IGNORED_VPN+=("$name"); else''',
     r'''then :; else'''),
    ('VPN_CONNECTION can be ignored', 'T217',
     r'''    [[ -n "$VPN_CONNECTION" && "$name" == "$VPN_CONNECTION" ]] && return 1
''',
     r''''''),
    ('IGNORED_VPN is not reset on each detection', 'T217',
     r'''    KNOWN_VPN=()
    IGNORED_VPN=()
''',
     r'''    KNOWN_VPN=()
'''),
    ('VPN_IGNORE patterns undergo pathname expansion', 'T217',
     r'''    IFS=$', \t\n' read -r -a pats <<< "$VPN_IGNORE"''',
     r'''    IFS=$', \t\n'; pats=($VPN_IGNORE); IFS=$' \t\n\''''),
    ('VPN_IGNORE matches a substring, not the whole name', 'T217',
     r'''[[ -n "$pat" && "$name" == $pat ]] && return 0''',
     r'''[[ -n "$pat" && "$name" == *$pat* ]] && return 0'''),
    ('Blocking leaves out the ignored VPN endpoints', 'T218',
     r'''KS_VPN_CANDIDATES=("${KNOWN_VPN[@]}" "${IGNORED_VPN[@]}")''',
     r'''KS_VPN_CANDIDATES=("${KNOWN_VPN[@]}")'''),
    ('Zombie handling brings down and reconnects an ignored VPN', 'T219',
     r'''        if vpn_reconnect_wanted && ! active_vpn_is_ignored; then''',
     r'''        if vpn_reconnect_wanted; then'''),
    ('Deactivate brings down an ignored VPN', 'T220',
     r'''    if active_vpn_is_ignored; then
        log_t info log.vpn_ignored_kept "$ACTIVE_VPN"
    elif [[ -n "$ACTIVE_VPN" ]]; then''',
     r'''    if [[ -n "$ACTIVE_VPN" ]]; then'''),
    ('Deactivate keeps an ignored VPN without a log line', 'T220',
     r'''        log_t info log.vpn_ignored_kept "$ACTIVE_VPN"''',
     r'''        :'''),
    ('Activate gives the generic message when all profiles are ignored', 'T220',
     r'''    if [[ ${#KNOWN_VPN[@]} -eq 0 && ${#IGNORED_VPN[@]} -gt 0 ]]; then''',
     r'''    if false; then'''),
    ('The all-ignored message has no English text', 'T220',
     r'''        en:log.vpn_all_ignored) text='All VPN profiles (%s) are in VPN_IGNORE: NetGuard has no VPN to manage. Remove one from VPN_IGNORE in %s or add another VPN connection' ;;
''',
     r''''''),
    ('Status never lists the ignored VPN profiles', 'T221',
     r'''    if [[ ${#IGNORED_VPN[@]} -gt 0 ]]; then
        ui_row "$(ui_t status.l_vpn_ignored)" "${IGNORED_VPN[*]}"''',
     r'''    if false; then
        ui_row "$(ui_t status.l_vpn_ignored)" "${IGNORED_VPN[*]}"'''),
    # --- 5.7: arranque temprano con cliente ajeno ---
    ('Boot blocking never scans for foreign clients', 'T222',
     r'''        coexist_scan boot
''',
     r''''''),
    ('Boot scans after applying the rules', 'T222',
     r'''        coexist_scan boot
        apply_killswitch_rules ""
        apply_killswitch_rules6 ""
''',
     r'''        apply_killswitch_rules ""
        apply_killswitch_rules6 ""
        coexist_scan boot
'''),
    ('Boot scans even when it does not block', 'T222',
     r'''    if boot_killswitch_would_block; then
        log_t info log.boot_blocking "$SERVICE"
        KS_VPN_CANDIDATES=()
        coexist_scan boot
''',
     r'''    coexist_scan boot
    if boot_killswitch_would_block; then
        log_t info log.boot_blocking "$SERVICE"
        KS_VPN_CANDIDATES=()
'''),
    ('Boot scan runs in strict', 'T222',
     r'''    [[ "$COEXIST_MODE" == auto ]] || return 0
    foreign_vpn_scan "$@"''',
     r'''    foreign_vpn_scan "$@"'''),
    ('Boot scan queries NetworkManager', 'T222',
     r'''    if (( ! boot )); then
''',
     r'''    if true; then
'''),
    ('The scan drops the boot flag', 'T222',
     r'''    foreign_vpn_scan "$@"
}''',
     r'''    foreign_vpn_scan
}'''),
    # --- 5.8: el arranque no hereda la cesión ---
    ('Boot keeps the yield of the previous session', 'T223',
     r'''    rm -f "$COEXIST_YIELD_FILE"

    if boot_killswitch_would_block; then''',
     r'''    if boot_killswitch_would_block; then'''),
    ('Boot drops the yield only when it blocks', 'T223',
     r'''    rm -f "$COEXIST_YIELD_FILE"

    if boot_killswitch_would_block; then
        log_t info log.boot_blocking "$SERVICE"''',
     r'''    if boot_killswitch_would_block; then
        rm -f "$COEXIST_YIELD_FILE"
        log_t info log.boot_blocking "$SERVICE"'''),
    # --- 6.2: perfil de 1-click ---
    ('1-click profile uses random MAC', 'T224',
     r'''        MAC_MODE=stable \
        ROTATE_MAC_PER_BOOT=true''',
     r'''        MAC_MODE=random \
        ROTATE_MAC_PER_BOOT=true'''),
    ('1-click profile stops Avahi', 'T224',
     r'''        DISABLE_AVAHI_SERVICE=false \
        DISABLE_NETBIOS_SERVICE=false''',
     r'''        DISABLE_AVAHI_SERVICE=true \
        DISABLE_NETBIOS_SERVICE=false'''),
    ('1-click profile hardens browser DoH', 'T224',
     r'''        HARDEN_BROWSER_DOH=false
}''',
     r'''        HARDEN_BROWSER_DOH=true
}'''),
    ('1-click profile drops COEXIST_MODE', 'T224',
     r'''        COEXIST_MODE=auto \
        KILLSWITCH_BOOT_RACE_AUTO_DISABLE=true''',
     r'''        KILLSWITCH_BOOT_RACE_AUTO_DISABLE=true'''),
    ('1-click profile does not rotate the MAC per boot', 'T224',
     r'''        ROTATE_MAC_PER_BOOT=true \
        RANDOMIZE_SCAN_MAC=true''',
     r'''        ROTATE_MAC_PER_BOOT=false \
        RANDOMIZE_SCAN_MAC=true'''),
    ('Failed config backup leaves an empty file', 'T225',
     r'''        rm -f "$backup"
        return 1
    fi
    printf '%s' "$backup"''',
     r'''        return 1
    fi
    printf '%s' "$backup"'''),
    ('Import continues without a backup', 'T225',
     r'''    backup="$(config_backup_make)" || { printf '%s\n' "$(ui_t config.backup_fail)" >&2; return 1; }''',
     r'''    backup="$(config_backup_make)" || true'''),
    # --- 6.1 (b): subcomando one-click ---
    ('One-click accepts a rejected configuration', 'T227',
     r'''    if ! config_file_is_safe "$CONFIG_FILE"; then
        printf -v msg -- "$(ui_t oneclick.config_unsafe)" "$CONFIG_FILE"''',
     r'''    if false; then
        printf -v msg -- "$(ui_t oneclick.config_unsafe)" "$CONFIG_FILE"'''),
    ('One-click continues without a backup', 'T227',
     r'''    backup="$(config_backup_make)" || { ui_bad "$(ui_t oneclick.backup_fail)" >&2; return 1; }''',
     r'''    backup="$(config_backup_make)" || true'''),
    ('One-click does not roll back a damaged configuration', 'T227',
     r'''        one_click_rollback "$backup"
        return 1
''',
     r'''        return 1
'''),
    ('One-click keeps the old configuration loaded', 'T226',
     r'''    load_config >/dev/null 2>&1   # los pasos siguientes usan el perfil, no la configuración anterior
''',
     ''),
    ('One-click prints the log of the steps that work', 'T226',
     r'''    if (( rc == 0 )); then
        ui_good "$ok_msg"
        return 0
    fi''',
     r'''    if (( rc == 0 )); then
        ui_good "$ok_msg"
        [[ -n "$out" ]] && echo "$out"
        return 0
    fi'''),
    ('One-click applies privacy after protecting', 'T226',
     r'''    one_click_step "$(ui_t oneclick.privacy_ok)" "$(ui_t oneclick.privacy_fail)" apply_network_privacy
    one_click_step "$(ui_t oneclick.activate_ok)" "$(ui_t oneclick.activate_fail)" one_click_activate
''',
     r'''    one_click_step "$(ui_t oneclick.activate_ok)" "$(ui_t oneclick.activate_fail)" one_click_activate
    one_click_step "$(ui_t oneclick.privacy_ok)" "$(ui_t oneclick.privacy_fail)" apply_network_privacy
'''),
    ('One-click hides a failed step in the exit code', 'T228',
     r'''    ONE_CLICK_FAILED=$((ONE_CLICK_FAILED + 1))
    return "$rc"
''',
     r'''    return "$rc"
'''),
    ('One-click stops at the first failed step', 'T228',
     r'''"$(ui_t oneclick.privacy_fail)" apply_network_privacy
''',
     r'''"$(ui_t oneclick.privacy_fail)" apply_network_privacy || return 2
'''),
    ('One-click restarts a service that is not installed', 'T228',
     r'''    if [[ -f "$UNIT_DST" ]]; then
        local ok_msg fail_msg''',
     r'''    if true; then
        local ok_msg fail_msg'''),
    ('One-click subcommand skips the root check', 'T229',
     r'''    one-click)
        check_dependencies
        load_config
        require_root
        cmd_one_click''',
     r'''    one-click)
        check_dependencies
        load_config
        cmd_one_click'''),
    # --- 6.3: avisos previos y sin perfil VPN (D7) ---
    ('Pre-check scan depends on the current COEXIST_MODE', 'T230',
     r'''    detect_active_state
    foreign_vpn_scan
    if (( ${#FOREIGN_KS[@]} )); then
        if [[ "$(killswitch_override_value)" == on ]]; then''',
     r'''    detect_active_state
    coexist_scan
    if (( ${#FOREIGN_KS[@]} )); then
        if [[ "$(killswitch_override_value)" == on ]]; then'''),
    ('Pre-check scans without detecting profiles first', 'T230',
     r'''    local line
    detect_known_profiles
    detect_active_state
    foreign_vpn_scan
''',
     r'''    local line
    foreign_vpn_scan
'''),
    ('Pre-check writes state', 'T230',
     r'''    local line
    detect_known_profiles
    detect_active_state
    foreign_vpn_scan
''',
     r'''    local line
    echo x > "$STATE_DIR/oc-pre"
    detect_known_profiles
    detect_active_state
    foreign_vpn_scan
'''),
    ('Pre-check ignores a forced ON', 'T230',
     r'''        if [[ "$(killswitch_override_value)" == on ]]; then
            printf -v line -- "$(ui_t status.coexist_rec_forced)" 'killswitch auto' "${FOREIGN_KS[*]}"''',
     r'''        if false; then
            printf -v line -- "$(ui_t status.coexist_rec_forced)" 'killswitch auto' "${FOREIGN_KS[*]}"'''),
    ('Pre-check treats a forced OFF as forced', 'T230',
     r'''        if [[ "$(killswitch_override_value)" == on ]]; then
            printf -v line -- "$(ui_t status.coexist_rec_forced)" 'killswitch auto' "${FOREIGN_KS[*]}"''',
     r'''        if [[ "$(killswitch_override_value)" != auto ]]; then
            printf -v line -- "$(ui_t status.coexist_rec_forced)" 'killswitch auto' "${FOREIGN_KS[*]}"'''),
    ('Pre-check recommends the wrong fix', 'T230',
     r'''"$(ui_t status.coexist_rec_forced)" 'killswitch auto' "${FOREIGN_KS[*]}"
        else
            printf -v line -- "$(ui_t status.coexist_yielding)"''',
     r'''"$(ui_t status.coexist_rec_forced)" 'killswitch on' "${FOREIGN_KS[*]}"
        else
            printf -v line -- "$(ui_t status.coexist_yielding)"'''),
    ('Pre-check reports tunnels next to their kill switch', 'T230',
     r'''        printf '%s\n' "$line"
    elif (( ${#FOREIGN_TUNNELS[@]} )); then''',
     r'''        printf '%s\n' "$line"
    fi
    if (( ${#FOREIGN_TUNNELS[@]} )); then'''),
    ('Pre-check warns about autostart without the unit', 'T230',
     r'''    if [[ -f "$UNIT_DST" ]] && ! systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then''',
     r'''    if ! systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then'''),
    ('Pre-check warns about autostart when enabled', 'T230',
     r'''    if [[ -f "$UNIT_DST" ]] && ! systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then''',
     r'''    if [[ -f "$UNIT_DST" ]] && systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then'''),
    ('One-click prints the pre-check title without warnings', 'T231',
     r'''    if (( ${#pre[@]} )); then
        ui_section "$(ui_t oneclick.pre_title)"''',
     r'''    if true; then
        ui_section "$(ui_t oneclick.pre_title)"'''),
    ('One-click counts the pre-check warnings as failures', 'T231',
     r'''        for line in "${pre[@]}"; do ui_warn "$line"; done''',
     r'''        for line in "${pre[@]}"; do ui_warn "$line"; ONE_CLICK_FAILED=$((ONE_CLICK_FAILED + 1)); done'''),
    ('One-click shows the pre-checks after the backup', 'T231',
     r'''    mapfile -t pre < <(one_click_preflight)
    if (( ${#pre[@]} )); then
        ui_section "$(ui_t oneclick.pre_title)"
        for line in "${pre[@]}"; do ui_warn "$line"; done
    fi
    backup="$(config_backup_make)" || { ui_bad "$(ui_t oneclick.backup_fail)" >&2; return 1; }
    printf -v msg -- "$(ui_t oneclick.backup_ok)" "$backup"
    ui_good "$msg"
''',
     r'''    backup="$(config_backup_make)" || { ui_bad "$(ui_t oneclick.backup_fail)" >&2; return 1; }
    printf -v msg -- "$(ui_t oneclick.backup_ok)" "$backup"
    ui_good "$msg"
    mapfile -t pre < <(one_click_preflight)
    if (( ${#pre[@]} )); then
        ui_section "$(ui_t oneclick.pre_title)"
        for line in "${pre[@]}"; do ui_warn "$line"; done
    fi
'''),
    ('One-click shows the pre-checks before the configuration checks', 'T231',
     r'''    ui_section "$(ui_t panel.one_click)"

    if [[ ! -f "$CONFIG_FILE" ]]; then''',
     r'''    ui_section "$(ui_t panel.one_click)"
    mapfile -t pre < <(one_click_preflight)
    if (( ${#pre[@]} )); then
        ui_section "$(ui_t oneclick.pre_title)"
        for line in "${pre[@]}"; do ui_warn "$line"; done
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then'''),
    ('One-click accepts a missing VPN profile', 'T232',
     r'''    do_activate || return 1
    (( ${#KNOWN_VPN[@]} > 0 ))
''',
     r'''    do_activate || return 1
    return 0
'''),
    ('One-click ignores a failing activation', 'T232',
     r'''    do_activate || return 1
    (( ${#KNOWN_VPN[@]} > 0 ))
''',
     r'''    do_activate || true
    (( ${#KNOWN_VPN[@]} > 0 ))
'''),
    ('One-click activates through do_activate directly', 'T232',
     r'''"$(ui_t oneclick.activate_fail)" one_click_activate
''',
     r'''"$(ui_t oneclick.activate_fail)" do_activate
'''),
    # --- 6.4: menú de texto y panel llaman al subcomando one-click ---
    ('Text menu 1-click also runs a step on its own', 'T233',
     r'''    menu_confirm "$text" || return
    menu_action one-click
''',
     r'''    menu_confirm "$text" || return
    menu_elevate bash "$SELF" apply-privacy
    menu_action one-click
'''),
    ('Text menu 1-click skips the confirmation', 'T233',
     r'''    menu_confirm "$text" || return
    menu_action one-click
''',
     r'''    menu_action one-click
'''),
    ('Text menu 1-click ignores the SSH warning', 'T233',
     r'''    is_ssh_session && text="$(ui_t panel.one_click_confirm_ssh)"
    menu_confirm "$text" || return
    menu_action one-click
''',
     r'''    menu_confirm "$text" || return
    menu_action one-click
'''),
    ('Text menu 1-click does not check the configuration', 'T233',
     r'''menu_action_one_click() {
    if [[ ! -f "$CONFIG_FILE" ]]; then''',
     r'''menu_action_one_click() {
    if false; then'''),
    ('Panel 1-click ignores the SSH warning', 'T234',
     r'''    is_ssh_session && text="$(ui_t panel.one_click_confirm_ssh)"
    panel_confirm_box "$text" || return

    out="$(pkexec''',
     r'''    panel_confirm_box "$text" || return

    out="$(pkexec'''),
    ('Panel 1-click skips the confirmation', 'T234',
     r'''    panel_confirm_box "$text" || return

    out="$(pkexec''',
     r'''
    out="$(pkexec'''),
    ('Panel 1-click does not check the configuration', 'T234',
     r'''panel_action_one_click() {
    [[ -f "$CONFIG_FILE" ]] || {''',
     r'''panel_action_one_click() {
    false || {'''),
    ('Panel 1-click elevates the steps separately', 'T234',
     r'''    out="$(pkexec "$BIN_DST" one-click 2>&1)"''',
     r'''    pkexec "$BIN_DST" apply-privacy >/dev/null 2>&1
    out="$(pkexec "$BIN_DST" one-click 2>&1)"'''),
    ('Panel 1-click runs a different command', 'T234',
     r'''    out="$(pkexec "$BIN_DST" one-click 2>&1)"''',
     r'''    out="$(pkexec "$SELF" one-click 2>&1)"'''),
    ('Panel 1-click shows a failed step as an error box', 'T234',
     r'''        0|1|2)
            load_config >/dev/null 2>&1''',
     r'''        0|1)
            load_config >/dev/null 2>&1'''),
    ('Panel 1-click shows an elevation failure as a summary', 'T234',
     r'''        0|1|2)
            load_config >/dev/null 2>&1''',
     r'''        0|1|2|126|127)
            load_config >/dev/null 2>&1'''),
    ('Panel 1-click hides the output of a failed elevation', 'T234',
     r'''"$BIN_DST one-click" "${out:-$(ui_t ui.no_output)}"''',
     r'''"$BIN_DST one-click" "$(ui_t ui.no_output)"'''),
    ('Panel 1-click keeps the old configuration loaded', 'T234',
     r'''            load_config >/dev/null 2>&1
            zenity_ui --text-info --title="$TITLE - $(ui_t panel.one_click)"''',
     r'''            zenity_ui --text-info --title="$TITLE - $(ui_t panel.one_click)"'''),
    # --- 7.2: versión, configuración por defecto, cabecera y ayuda ---
    ('Version not bumped', 'T60',
     r'''VERSION="2.6.0"
''',
     r'''VERSION="1.0.0"
'''),
    ('Default config asks to restart the service again', 'T235',
     r'''# Los cambios de este fichero (a mano o desde el panel gráfico) los detecta el
# servicio y los aplica solo en unos segundos; no hace falta reiniciarlo.
''',
     r'''# Después de editar este fichero (a mano o desde el panel gráfico), reinicia
# el servicio para aplicar los cambios:
#   sudo systemctl restart vpn-netguard.service
'''),
    ('Default config stops naming apply-privacy', 'T235',
     r"""# aplican con 'vpn-netguard.sh apply-privacy' (menú de terminal: Ajustes de
""",
     r"""# aplican (menú de terminal: Ajustes de
"""),
    ('Help drops a subcommand', 'T237',
     r'''"$(ui_t usage.check)" "$(ui_t usage.doctor)" "$(ui_t usage.one_click)"''',
     r'''"$(ui_t usage.check)" "$(ui_t usage.one_click)"'''),
    ('Script header drops a subcommand', 'T237',
     r'''#   vpn-netguard.sh doctor                combined diagnostics (dependencies, network, firewall, kill switch, coexistence)
''',
     ''),
    # --- doctor nombra la convivencia en la ayuda, el panel y la cabecera (T243) ---
    ('Doctor help drops the coexistence check (es)', 'T243',
     """        es:usage.doctor) text='  doctor                diagnóstico combinado (dependencias, red, firewall, kill switch, convivencia)' ;;\n""",
     """        es:usage.doctor) text='  doctor                diagnóstico combinado (dependencias, red, firewall, kill switch)' ;;\n"""),
    ('Doctor help drops the coexistence check (en)', 'T243',
     """        en:usage.doctor) text='  doctor                combined diagnostics (dependencies, network, firewall, kill switch, coexistence)' ;;\n""",
     """        en:usage.doctor) text='  doctor                combined diagnostics (dependencies, network, firewall, kill switch)' ;;\n"""),
    ('Doctor panel description drops the coexistence check (es)', 'T243',
     """        es:menu.desc_doctor) text='Dependencias, red, cortafuegos, kill switch y convivencia' ;;\n""",
     """        es:menu.desc_doctor) text='Dependencias, red, cortafuegos y kill switch' ;;\n"""),
    ('Doctor panel description drops the coexistence check (en)', 'T243',
     """        en:menu.desc_doctor) text='Dependencies, network, firewall, kill switch and coexistence' ;;\n""",
     """        en:menu.desc_doctor) text='Dependencies, network, firewall and kill switch' ;;\n"""),
    ('Script header drops the coexistence check of doctor', 'T243',
     """#   vpn-netguard.sh doctor                combined diagnostics (dependencies, network, firewall, kill switch, coexistence)\n""",
     """#   vpn-netguard.sh doctor                combined diagnostics (dependencies, network, firewall, kill switch)\n"""),
    # --- 7.3: ninguna clave i18n sin uso (T132) ---
    ('Dead translation key comes back', 'T132',
     """        es:panel.privacy_saved) text='Configuración de anonimato guardada.' ;;
        en:panel.privacy_saved) text='Network privacy configuration saved.' ;;
""",
     """        es:panel.privacy_saved) text='Configuración de anonimato guardada.' ;;
        en:panel.privacy_saved) text='Network privacy configuration saved.' ;;
        es:panel.privacy_apply_q) text='¿Aplicarla ahora?' ;;
        en:panel.privacy_apply_q) text='Apply it now?' ;;
"""),
    # --- 8: el guardado rechazado dice por qué (D9; T244 y T245) ---
    ('A rejected current config gives no reason', 'T244',
     r'''        printf -v CONFIG_WRITE_ERROR -- "$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
''',
     ''),
    ('A rejected current config is not echoed to stderr', 'T244',
     r'''"$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
        printf '%s\n' "$CONFIG_WRITE_ERROR" >&2
''',
     r'''"$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
'''),
    ('A too-long value is reported against the first key instead of the offending one', 'T244',
     r'''            (( ${#rhs} > CONFIG_VALUE_MAX )) || continue
''',
     r'''            :
'''),
    ('The length is measured before %q escaping', 'T244',
     r'''            printf -v rhs '%q' "${pending[$key]}"
''',
     r'''            rhs="${pending[$key]}"
'''),
    ('A too-long value is not echoed to stderr', 'T244',
     r'''            break
        done
        printf '%s\n' "$CONFIG_WRITE_ERROR" >&2
''',
     r'''            break
        done
'''),
    ('The general rejection has no text', 'T244',
     r'''        CONFIG_WRITE_ERROR="$(ui_t config.write_rejected)"
''',
     r'''        CONFIG_WRITE_ERROR=""
'''),
    ('The reason of the previous save is kept', 'T244',
     r'''panel_write_config_keys() {
    CONFIG_WRITE_ERROR=""
''',
     r'''panel_write_config_keys() {
'''),
    ('The error box drops the reason', 'T245',
     r'''[[ -n "$CONFIG_WRITE_ERROR" ]] && msg+="\n\n$(pango_escape "$CONFIG_WRITE_ERROR")"''',
     r'''[[ -n "$CONFIG_WRITE_ERROR" ]] && msg+=""'''),
    ('The error box does not escape the reason for Pango', 'T245',
     r'''msg+="\n\n$(pango_escape "$CONFIG_WRITE_ERROR")"''',
     r'''msg+="\n\n$CONFIG_WRITE_ERROR"'''),
    ('The error box adds an empty paragraph when there is no reason', 'T245',
     r'''[[ -n "$CONFIG_WRITE_ERROR" ]] && msg+="\n\n$(pango_escape''',
     r'''msg+="\n\n$(pango_escape'''),
    ('The language dialog shows a bare error box', 'T245',
     r'''        panel_config_write_error_box "$(ui_t panel.config_save_fail)"
    fi
}

panel_action_configure() {''',
     r'''        panel_error_box "$(ui_t panel.config_save_fail)"
    fi
}

panel_action_configure() {'''),
    ('The general dialog shows a bare error box', 'T245',
     r'''        panel_config_write_error_box "$(ui_t panel.config_save_fail)"
    fi
}

# Confirmación antes de aplicar anonimato''',
     r'''        panel_error_box "$(ui_t panel.config_save_fail)"
    fi
}

# Confirmación antes de aplicar anonimato'''),
    ('The privacy dialog shows a bare error box', 'T245',
     r'''panel_config_write_error_box "$(ui_t panel.privacy_save_fail)"''',
     r'''panel_error_box "$(ui_t panel.privacy_save_fail)"'''),
    ('The monitoring dialog shows a bare error box', 'T245',
     r'''panel_config_write_error_box "$(ui_t panel.monitor_save_fail)"''',
     r'''panel_error_box "$(ui_t panel.monitor_save_fail)"'''),
    ('The text menu hides the reason of a failed save', 'T245',
     r'''    printf -- "$(ui_t menu.save_changes)\n" "$CONFIG_FILE"
    if panel_write_config_keys "${kvs[@]}"; then''',
     r'''    printf -- "$(ui_t menu.save_changes)\n" "$CONFIG_FILE"
    if panel_write_config_keys "${kvs[@]}" 2>/dev/null; then'''),
    ('nmcli_c goes back to the ASCII-only C locale', 'T246',
     r'''NMCLI_ENV=(LC_ALL=C.UTF-8 LANGUAGE=C)''',
     r'''NMCLI_ENV=(LC_ALL=C LANGUAGE=C)'''),
    ('nmcli_c lets LANGUAGE from the environment translate nmcli', 'T246',
     r'''NMCLI_ENV=(LC_ALL=C.UTF-8 LANGUAGE=C)''',
     r'''NMCLI_ENV=(LC_ALL=C.UTF-8)'''),
    ('nmcli_up reconnects with the ASCII-only C locale', 'T246',
     r'''env "${NMCLI_ENV[@]}" timeout "$NMCLI_UP_TIMEOUT" nmcli connection up''',
     r'''LC_ALL=C timeout "$NMCLI_UP_TIMEOUT" nmcli connection up'''),
    ('The menu header reads the active VPN with the ASCII-only C locale', 'T246',
     r'''timeout 3 env "${NMCLI_ENV[@]}" nmcli -t -e yes -f NAME,TYPE connection show --active''',
     r'''timeout 3 env LC_ALL=C nmcli -t -e yes -f NAME,TYPE connection show --active'''),
    # --- Fase 9: carpeta de métricas con el selector de zenity (T247) ---
    ('The metrics picker lets the user choose a file instead of a folder', 'T247',
     r'''zenity_ui --file-selection --directory --title="$TITLE - $(ui_t panel.prom_pick_title)"''',
     r'''zenity_ui --file-selection --title="$TITLE - $(ui_t panel.prom_pick_title)"'''),
    ('A cancelled metrics picker still saves the form', 'T247',
     r'''            [[ -z "$picked" ]] && return
            [[ "$picked" == / ]]''',
     r'''            [[ "$picked" == / ]]'''),
    ('The metrics picker offers "remove" even with no folder set', 'T247',
     r'''    [[ -n "$cur_prom" ]] && prom_values+="|$prom_clear"''',
     r'''    prom_values+="|$prom_clear"'''),
    ('The chosen folder keeps its trailing slash', 'T247',
     r'''            [[ "$picked" == / ]] || picked="${picked%/}"
''',
     ''),
    ('The metrics picker ignores the current folder', 'T247',
     r'''--filename="${cur_prom:-$HOME}/"''',
     r'''--filename="$HOME/"'''),
    ('"Remove" does not clear the metrics folder', 'T247',
     r'''        "$prom_clear") new_prom="" ;;''',
     r'''        "$prom_clear") ;;'''),
    ('The metrics combo no longer offers the folder browser', 'T247',
     r'''    prom_values="$prom_keep|$prom_choose"''',
     r'''    prom_values="$prom_keep"'''),
    ('A current folder containing "|" splits the metrics combo', 'T247',
     r'''    prom_keep="${prom_keep//|/¦}"
''',
     ''),
    # --- Fase 9.2: presentación de las pantallas de estado (T248) ---
    ('The banner names the program in lowercase', 'T248',
     r'''"$C_B" "$rule" "$TITLE" "$1" "$rule" "$C_0"''',
     r'''"$C_B" "$rule" "vpn-netguard" "$1" "$rule" "$C_0"'''),
    ('The banner uses a single line instead of the double rule', 'T248',
     r'''    rule="$(ui_rule '═')"''',
     r'''    rule="$(ui_rule)"'''),
    ('ui_text_len counts bytes, so accents misalign in the C locale', 'T248',
     r'''    local t="${1//[$'\200'-$'\277']/}"''',
     r'''    local t="$1"'''),
    ('The status screens grow wider than 64 columns', 'T248',
     r'''UI_WIDTH=64''',
     r'''UI_WIDTH=72'''),
    ('The label column is narrower than 22 characters', 'T248',
     r'''UI_LABEL_W=22''',
     r'''UI_LABEL_W=20'''),
    ('Section titles are padded by bytes, not by characters', 'T248',
     r'''    pad=$(( UI_WIDTH - $(ui_text_len "$head") )); (( pad < 0 )) && pad=0''',
     r'''    pad=$(( UI_WIDTH - ${#head} )); (( pad < 0 )) && pad=0'''),
    ('Warnings lose their symbol', 'T248',
     r'''warn) printf '⚠' ;;''',
     r'''warn) printf '' ;;'''),
    ('Long warnings are no longer wrapped', 'T248',
     r'''        elif (( len + 1 + wl <= UI_WIDTH )); then''',
     r'''        elif true; then'''),
    ('Status omits the alerts section', 'T248',
     r'''    ui_block "$(ui_t status.section_alerts)"
''',
     ''),
    ('The kill switch screen has no header of its own', 'T248',
     r'''            ui_banner "$(ui_t killswitch.status_title)"
            echo
''',
     ''),
    ('The kill switch screen is titled as the general status', 'T248',
     r'''            ui_banner "$(ui_t killswitch.status_title)"''',
     r'''            ui_banner "$(ui_t status.title)"'''),
    ('The status dialog goes back to 560 px', 'T250',
     r'''PANEL_STATUS_W=640''',
     r'''PANEL_STATUS_W=560'''),
    # --- Fase 9.3: el anonimato de red dentro de «Ver estado actual» (T249) ---
    ('Status omits the network privacy section', 'T249',
     r'''    ui_block "$(ui_t privacy.status_title)"
    print_privacy_rows
''',
     ''),
    ('Status repeats the active network inside the privacy section', 'T249',
     r'''    ui_block "$(ui_t privacy.status_title)"
    print_privacy_rows
''',
     r'''    ui_block "$(ui_t privacy.status_title)"
    print_privacy_rows standalone
'''),
    ('The privacy screen drops the active network', 'T249',
     r'''        [[ -n "$standalone" ]] && ui_row "$(ui_t privacy.l_active_net)" "$active_name ($PHYS_IFACE)"
''',
     ''),
    ('The privacy screen says nothing without an active network', 'T249',
     r'''    elif [[ -n "$standalone" ]]; then
        ui_row "$(ui_t privacy.l_active_net)" "$(ui_t privacy.v_no_net)"''',
     r'''    elif false; then
        ui_row "$(ui_t privacy.l_active_net)" "$(ui_t privacy.v_no_net)"'''),
    ('The privacy screen has no header of its own', 'T249',
     r'''    ui_banner "$(ui_t privacy.status_title)"
    echo
''',
     ''),
    ('ui_yesno inverts true and false', 'T249',
     r'''ui_yesno() { if [[ "$1" == true ]]; then''',
     r'''ui_yesno() { if [[ "$1" != true ]]; then'''),
    ('The enabled privacy module loses its check mark', 'T249',
     r'''        ui_row "$(ui_t privacy.l_module)" "$line" ok''',
     r'''        ui_row "$(ui_t privacy.l_module)" "$line"'''),
    ('A missing privacy snippet is not flagged', 'T249',
     r'''"$(ui_t privacy.v_snippet_no)" warn''',
     r'''"$(ui_t privacy.v_snippet_no)"'''),
    ('A stopped MAC rotation timer is shown as healthy', 'T249',
     r'''timer_state="$(ui_t inactive)"; timer_level=warn''',
     r'''timer_state="$(ui_t inactive)"; timer_level=ok'''),
    ('A running MAC rotation timer is flagged', 'T249',
     r'''timer_state="$(ui_t active)"; timer_level=ok''',
     r'''timer_state="$(ui_t active)"; timer_level=warn'''),
    ('The snippet counts as correct even with the module disabled', 'T249',
     r'''"$([[ "$ANONYMIZE_NETWORK" == "true" ]] && echo ok)"''',
     r'''ok'''),
    # --- Fase 9.4: pantallas de estado con un solo botón (T250) ---
    ('Short status screens go back to --text-info (two buttons)', 'T250',
     r'''(( ${#nl} < PANEL_INFO_MAX_LINES ))''',
     r'''(( 0 ))'''),
    ('The long status screen is shown with --info (the window grows past the screen)', 'T250',
     r'''(( ${#nl} < PANEL_INFO_MAX_LINES ))''',
     r'''(( 1 ))'''),
    ('A text exactly at the line limit still goes to --info', 'T250',
     r'''(( ${#nl} < PANEL_INFO_MAX_LINES ))''',
     r'''(( ${#nl} <= PANEL_INFO_MAX_LINES ))'''),
    ('The line limit is raised above the general status', 'T250',
     r'''PANEL_INFO_MAX_LINES=28
''',
     r'''PANEL_INFO_MAX_LINES=60
'''),
    ('The line limit is lowered below the kill switch screen', 'T250',
     r'''PANEL_INFO_MAX_LINES=28
''',
     r'''PANEL_INFO_MAX_LINES=8
'''),
    ('The --info text is not escaped for Pango', 'T250',
     r'''--text="<tt>$(pango_escape "$text")</tt>"''',
     r'''--text="<tt>$text</tt>"'''),
    ('The --info text loses its monospace markup', 'T250',
     r'''--text="<tt>$(pango_escape "$text")</tt>"''',
     r'''--text="$(pango_escape "$text")"'''),
    ('The --info text wraps long lines again', 'T250',
     r''' --no-wrap --text="<tt>''',
     r''' --text="<tt>'''),
    ('The --info dialog goes back to 480 px', 'T250',
     r'''zenity_ui --info --title="$title" --width="$PANEL_STATUS_W"''',
     r'''zenity_ui --info --title="$title" --width=480'''),
    ('The --info dialog ignores the screen title', 'T250',
     r'''zenity_ui --info --title="$title"''',
     r'''zenity_ui --info --title="$TITLE"'''),
    ('The long status dialog goes back to 560 px', 'T250',
     r'''zenity_ui --text-info --title="$title" --width="$PANEL_STATUS_W"''',
     r'''zenity_ui --text-info --title="$title" --width=560'''),
    ('The --text-info dialog ignores the screen title', 'T250',
     r'''zenity_ui --text-info --title="$title"''',
     r'''zenity_ui --text-info --title="$TITLE"'''),
    ('The long status loses its monospace font', 'T250',
     r''' --height="$height" --font="Monospace" <<< "$text"''',
     r''' --height="$height" <<< "$text"'''),
    ('The long status ignores its height', 'T250',
     r'''--width="$PANEL_STATUS_W" --height="$height" --font="Monospace"''',
     r'''--width="$PANEL_STATUS_W" --font="Monospace"'''),
    ('The long status shows no text', 'T250',
     r'''--font="Monospace" <<< "$text"''',
     r'''--font="Monospace" <<< ""'''),
    ('The kill switch status skips panel_status_screen', 'T250',
     r'''    panel_status_screen "$TITLE - $(ui_t killswitch.title)" 340 "$out"
''',
     r'''    zenity_ui --text-info --title="$TITLE - $(ui_t killswitch.title)" --width="$PANEL_STATUS_W" --height=340 --font="Monospace" <<< "$out"
'''),
    ('The privacy status skips panel_status_screen', 'T250',
     r'''    panel_status_screen "$TITLE - $(ui_t panel.privacy)" 520 "$out"
''',
     r'''    zenity_ui --text-info --title="$TITLE - $(ui_t panel.privacy)" --width="$PANEL_STATUS_W" --height=520 --font="Monospace" <<< "$out"
'''),
    ('The general status is shown with --info', 'T250',
     r'''    panel_status_screen "$TITLE - $(ui_t panel.status)" 600 "$out"
''',
     r'''    zenity_ui --info --title="$TITLE - $(ui_t panel.status)" --width="$PANEL_STATUS_W" --no-wrap --text="<tt>$(pango_escape "$out")</tt>"
'''),
    # --- 9.4 (c): Aceptar en «Ajustes de anonimato de red» (T181 y T251) ---
    ('Privacy OK saves even when nothing changed', 'T251',
     r'''    if (( changed )); then
        if panel_write_config_keys "${kvs[@]}"; then''',
     r'''    if true; then
        if panel_write_config_keys "${kvs[@]}"; then'''),
    ('Privacy OK never saves', 'T251',
     r'''    if (( changed )); then
        if panel_write_config_keys "${kvs[@]}"; then''',
     r'''    if false; then
        if panel_write_config_keys "${kvs[@]}"; then'''),
    ('Privacy OK counts a blank or "-" field as a change', 'T251',
     r'''        if [[ "$new" != "$val" ]]; then
            changed=1''',
     r'''        if [[ "${vals[$i]-}" != "$val" ]]; then
            changed=1'''),
    ('Privacy OK keeps going after a rejected save', 'T251',
     r'''            panel_config_write_error_box "$(ui_t panel.privacy_save_fail)"
            return
        fi
    fi
    local applied=0''',
     r'''            panel_config_write_error_box "$(ui_t panel.privacy_save_fail)"
        fi
    fi
    local applied=0'''),
    ('Privacy OK applies without asking', 'T181',
     r'''    if panel_confirm_apply_privacy; then
        local applied_msg''',
     r'''    if true; then
        local applied_msg'''),
    ('Privacy OK asks and applies only when something changed', 'T251',
     r'''    if panel_confirm_apply_privacy; then
        local applied_msg''',
     r'''    if (( changed )) && panel_confirm_apply_privacy; then
        local applied_msg'''),
    ('Privacy "saved" notice also after applying', 'T251',
     r'''    (( changed && ! applied )) && panel_info_box''',
     r'''    (( changed )) && panel_info_box'''),
    ('Privacy "saved" notice lost when nothing is applied', 'T251',
     r'''    (( changed && ! applied )) && panel_info_box "$(ui_t panel.privacy_saved)"
    return 0''',
     r'''    return 0'''),
    ('Privacy failed apply counted as applied', 'T251',
     r'''        if panel_run_privileged -- "$BIN_DST" apply-privacy; then
            applied=1
            panel_info_box "$applied_msg"
        fi''',
     r'''        panel_run_privileged -- "$BIN_DST" apply-privacy
        applied=1
        panel_info_box "$applied_msg"'''),
    ('Privacy browser hint shown on every apply', 'T251',
     r'''        (( doh_changed )) && applied_msg+=''',
     r'''        applied_msg+='''),
    ('Privacy browser hint never shown', 'T251',
     r'''        (( doh_changed )) && applied_msg+=''',
     r'''        false && applied_msg+='''),
    ('Privacy browser hint on any changed field', 'T251',
     r'''            [[ "${keys[$i]}" == HARDEN_BROWSER_DOH ]] && doh_changed=1''',
     r'''            doh_changed=1'''),
    ('Privacy help loses the status button label', 'T251',
     r'''    printf -v help -- "$(ui_t panel.privacy_help)" "$status_label"''',
     r'''    help="$(ui_t panel.privacy_help)"'''),
    # --- 9.5: explicación de cada opción de configuración (T252) ---
    ('Field label drops the explanation', 'T252',
     r'''    [[ -n "$help" ]] && text+=$'\n'"$help"
''',
     r''''''),
    ('Field label puts the explanation on the same line', 'T252',
     r'''text+=$'\n'"$help"''',
     r'''text+=" $help"'''),
    ('Field label drops the current value', 'T252',
     r'''(( $# > 1 )) && text+=''',
     r'''false && text+='''),
    ('Text menu never shows the explanation', 'T252',
     r'''                    menu_print_field_help "$k"
''',
     r''''''),
    ('Text menu explanation is not wrapped', 'T252',
     r'''    ui_wrap '  ' '  ' "$help"''',
     r'''    printf '  %s\n' "$help"'''),
    ('Text menu explanation loses its indentation', 'T252',
     r'''    ui_wrap '  ' '  ' "$help"''',
     r'''    ui_wrap '' '' "$help"'''),
    ('Text menu prints a blank block for an unknown key', 'T252',
     r'''    [[ -n "$help" ]] || return 0
    echo
    ui_wrap''',
     r'''    echo
    ui_wrap'''),
    ('Option without explanation (es)', 'T252',
     r'''es:HARDEN_BROWSER_DOH) echo 'Desactiva por política DoH en Firefox, Chrome y Chromium; hay que reiniciar el navegador' ;; ''',
     r''''''),
    ('Explanation with an underscore', 'T252',
     r'''Detiene avahi-daemon (Bonjour); puede romper impresoras y Chromecast''',
     r'''Detiene avahi_daemon (Bonjour); puede romper impresoras y Chromecast'''),
    ('Explanation longer than 90 characters', 'T252',
     r'''Permite el tráfico hacia la red local aunque el kill switch bloquee lo demás''',
     r'''Permite el tráfico hacia la red local aunque el kill switch bloquee lo demás, y también el resto'''),
    ('Explanation untranslated (same text in es and en)', 'T252',
     r'''en:ALLOW_LAN) echo 'Allows traffic to the local network even while the kill switch blocks the rest''',
     r'''en:ALLOW_LAN) echo 'Permite el tráfico hacia la red local aunque el kill switch bloquee lo demás'''),
    ('Explanation quotes a different boot-race delay', 'T252',
     r'''Si a los 40 s de arrancar bloqueado sigue sin VPN''',
     r'''Si a los 30 s de arrancar bloqueado sigue sin VPN'''),
    ('Unknown key gets a fallback explanation', 'T252',
     r'''        *) ;;
    esac
}

ui_init
''',
     r'''        *) echo "$1" ;;
    esac
}

ui_init
'''),
    ('General form text fields lose the explanation', 'T252',
     r'''forms+=(--add-entry="$(panel_field_label "$k" "${val:-auto}")") ;;''',
     r'''forms+=(--add-entry="$(ui_field_label "$k")") ;;'''),
    ('General form combos lose the explanation', 'T252',
     r'''LANGUAGE) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values=''',
     r'''LANGUAGE) forms+=(--add-combo="$(ui_field_label "$k")" --combo-values='''),
    ('Privacy form on/off combos lose the explanation', 'T252',
     r'''forms+=(--add-combo="$(panel_field_label "$key")" --combo-values="$(panel_order_combo "$val" false true)") ;;''',
     r'''forms+=(--add-combo="$(ui_field_label "$key")" --combo-values="$(panel_order_combo "$val" false true)") ;;'''),
    ('Privacy form MAC policy combo loses the explanation', 'T252',
     r'''MAC_MODE) forms+=(--add-combo="$(panel_field_label "$key")"''',
     r'''MAC_MODE) forms+=(--add-combo="$(ui_field_label "$key")"'''),
    ('General form computes a label it then discards', 'T252',
     r'''        val="$(panel_get_val "$k")"
        case "$k" in
            LANGUAGE) forms+=(''',
     r'''        : "$(panel_field_label "$k")"; val="$(panel_get_val "$k")"
        case "$k" in
            LANGUAGE) forms+=('''),
    ('Privacy form computes a label it then discards', 'T252',
     r'''        val="$(panel_get_val "$key")"; form_now+=("$val")''',
     r'''        : "$(panel_field_label "$key")"; val="$(panel_get_val "$key")"; form_now+=("$val")'''),
    ('Monitoring form combo loses the explanation', 'T252',
     r'''--add-combo="$(panel_field_label EVENT_HISTORY_ENABLE)"''',
     r'''--add-combo="$(ui_field_label EVENT_HISTORY_ENABLE)"'''),
    # --- 9.5: tope de 90 caracteres por línea en el --text de los tres formularios (T252) ---
    ('General form text longer than 90 characters (es)', 'T252',
     r'''vacía los campos opcionales." ;;''',
     r'''vacía los campos opcionales, y se guarda sin reiniciar nada." ;;'''),
    ('General form text longer than 90 characters (en)', 'T252',
     r'''clears optional fields." ;;''',
     r'''clears optional fields, and it is saved without restarting anything at all." ;;'''),
    ('Privacy form text on a single line (es)', 'T252',
     r'''de la VPN.\nUsa '-' en los campos opcionales para vaciarlos.\nAceptar''',
     r'''de la VPN. Usa '-' en los campos opcionales para vaciarlos. Aceptar'''),
    ('Privacy form text on a single line (en)', 'T252',
     r'''VPN kill switch.\nUse '-' in optional fields to clear them.\nOK saves''',
     r'''VPN kill switch. Use '-' in optional fields to clear them. OK saves'''),
    ('Privacy form middle line longer than 90 characters', 'T252',
     r'''Usa '-' en los campos opcionales para vaciarlos.\n''',
     r'''Usa '-' en los campos opcionales para vaciarlos, y déjalos en blanco si no los necesitas ahora.\n'''),
    ('Privacy form line only exceeds 90 characters once the button label is inserted', 'T252',
     r'''Aceptar guarda y aplica (pide confirmación); '%s' descarta lo escrito.''',
     r'''Aceptar guarda y aplica (pide confirmación antes de cambiar); '%s' descarta lo escrito.'''),
    ('Monitoring form text on a single line (es)', 'T252',
     r'''para las métricas.\nDeja el campo''',
     r'''para las métricas. Deja el campo'''),
    ('Monitoring form text on a single line (en)', 'T252',
     r'''for the metrics.\nLeave the text field''',
     r'''for the metrics. Leave the text field'''),
    ('General form has no --text', 'T252',
     r'''
        --text="$(ui_t panel.config_help)")''',
     r''')'''),
    ('Privacy form has no --text', 'T252',
     r'''--width=600 --text="$help")''',
     r'''--width=600)'''),
    ('Monitoring form has no --text', 'T252',
     r'''        --text="$(ui_t panel.monitor_help)" \
''',
     r''''''),
    ('DNS row shows "none" for an empty list', 'T253',
     r'''    ui_row "$(ui_t status.l_dns)" "${DNS_SERVERS:-$(ui_t status.v_dns_any)}"''',
     r'''    ui_row "$(ui_t status.l_dns)" "${DNS_SERVERS:-$none}"'''),
    ('DNS row ignores the configured list', 'T253',
     r'''    ui_row "$(ui_t status.l_dns)" "${DNS_SERVERS:-$(ui_t status.v_dns_any)}"''',
     r'''    ui_row "$(ui_t status.l_dns)" "$(ui_t status.v_dns_any)"'''),
    ('DNS row text claims IPv6 is open too (es)', 'T253',
     r'''text='cualquiera en IPv4; ninguno en IPv6' ;;''',
     r'''text='cualquiera en IPv4 e IPv6' ;;'''),
    ('DNS row text claims IPv6 is open too (en)', 'T253',
     r'''text='any on IPv4; none on IPv6' ;;''',
     r'''text='any on IPv4 and IPv6' ;;'''),
    ('Empty DNS list opens DNS in IPv6', 'T253',
     r'''            rules+=("-d $dns_ip6 -p tcp --dport 53 -j RETURN")
        done
    fi
''',
     r'''            rules+=("-d $dns_ip6 -p tcp --dport 53 -j RETURN")
        done
    else
        rules+=("-p udp --dport 53 -j RETURN")
        rules+=("-p tcp --dport 53 -j RETURN")
    fi
'''),
    ('Empty DNS list stops opening DNS in IPv4', 'T253',
     r'''    else
        rules+=("-p udp --dport 53 -j RETURN")
        rules+=("-p tcp --dport 53 -j RETURN")
    fi
''',
     r'''    fi
'''),
    ('Blank PING_TARGETS passes the empty check', 'T254',
     r'''    [[ "$PING_TARGETS" =~ [^[:space:]] ]] || { log_t warn log.empty_ping_targets >&2; PING_TARGETS="1.1.1.1 8.8.8.8"; }
''',
     r'''    [[ -n "$PING_TARGETS" ]] || { log_t warn log.empty_ping_targets >&2; PING_TARGETS="1.1.1.1 8.8.8.8"; }
'''),
    ('Blank PING_TARGETS falls back without a warning', 'T254',
     r'''{ log_t warn log.empty_ping_targets >&2; PING_TARGETS="1.1.1.1 8.8.8.8"; }''',
     r'''{ PING_TARGETS="1.1.1.1 8.8.8.8"; }'''),
    ('Blank PING_TARGETS warns but keeps its blank value', 'T254',
     r'''{ log_t warn log.empty_ping_targets >&2; PING_TARGETS="1.1.1.1 8.8.8.8"; }''',
     r'''{ log_t warn log.empty_ping_targets >&2; }'''),
    ('Boot-race safety net never fires', 'T254',
     r'''    if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]] || ! boot_killswitch_would_block; then''',
     r'''    if true; then'''),
    ('A tab does not count as blank', 'T254',
     r'''    [[ "$PING_TARGETS" =~ [^[:space:]] ]] ||''',
     r'''    [[ "$PING_TARGETS" =~ [^\ ] ]] ||'''),
    ('Blank DNS_SERVERS is kept as is', 'T254',
     r'''    [[ "$DNS_SERVERS" =~ [^[:space:]] ]] || DNS_SERVERS=""
''',
     r''''''),
    ('Blank free-text keys are kept as is', 'T254',
     r'''    local blank_key
    for blank_key in ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_ENDPOINT_OVERRIDE ALERT_HOOK PROMETHEUS_TEXTFILE_DIR; do
        [[ "${!blank_key}" =~ [^[:space:]] ]] || printf -v "$blank_key" ''
    done
''',
     r''''''),
    ('Blank VPN_ENDPOINT_OVERRIDE is kept as is', 'T254',
     r'''VPN_CONNECTION VPN_ENDPOINT_OVERRIDE ALERT_HOOK''',
     r'''VPN_CONNECTION ALERT_HOOK'''),
    ('Start interface: any stored value is accepted', 'T255',
     r'''    [[ "$value" == panel || "$value" == terminal ]] && printf '%s' "$value"
''',
     r'''    printf '%s' "$value"
'''),
    ('Start interface: a Windows line ending is not stripped', 'T255',
     r'''        value="${value%$'\r'}"
''',
     r''''''),
    ('Start interface: an unknown value is accepted when saving', 'T255',
     r'''    [[ "$value" == panel || "$value" == terminal ]] || return 1
    file="$(ui_pref_file)" || return 1
''',
     r'''    file="$(ui_pref_file)" || return 1
'''),
    ('Start interface: the directory does not have to be the user\'s', 'T255',
     r'''[[ -d "$owner_dir" && -O "$owner_dir" ]] || return 1''',
     r'''[[ -d "$owner_dir" ]] || return 1'''),
    ('Start interface: a relative XDG_CONFIG_HOME is accepted', 'T255',
     r'''if [[ "${XDG_CONFIG_HOME:-}" == /* ]]; then''',
     r'''if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then'''),
    ('Start interface: XDG_CONFIG_HOME is ignored', 'T255',
     r'''if [[ "${XDG_CONFIG_HOME:-}" == /* ]]; then''',
     r'''if false; then'''),
    ('Start interface: the file is written in place (no temporary and mv)', 'T255',
     r'''    if printf '%s\n' "$value" > "$tmp" 2>/dev/null && mv -fT -- "$tmp" "$file" 2>/dev/null; then''',
     r'''    if printf '%s\n' "$value" > "$file" 2>/dev/null; then'''),
    ('Start interface: the directory is not private', 'T255',
     r'''    mkdir -m 0700 -- "$dir" 2>/dev/null || [[ -d "$dir" ]] || return 1
''',
     r'''    mkdir -- "$dir" 2>/dev/null || [[ -d "$dir" ]] || return 1
'''),
    ('Start interface: a failed save leaves its temporary file', 'T255',
     r'''    rm -f -- "$tmp"
    return 1
''',
     r'''    return 1
'''),
    ('Start interface: mv moves the file into a directory instead of failing', 'T255',
     r'''mv -fT -- "$tmp" "$file"''',
     r'''mv -f -- "$tmp" "$file"'''),
    ('Interface entry: opening the panel does not make it the start interface', 'T256',
     r'''    if ui_pref_set panel; then
''',
     r'''    if true; then
'''),
    ('Interface entry: the notice does not say how to go back', 'T256',
     r'''printf -- "$(ui_t menu.interface_panel_set)\n" "$(menu_label interface panel)"''',
     r'''printf -- "$(ui_t menu.interface_panel_set)\n" ""'''),
    ('Interface entry: a failed save from the terminal is silent', 'T256',
     r'''        printf '%s\n' "$(ui_t menu.interface_save_failed)" >&2
''',
     r'''        :
'''),
    ('Interface entry: a failed save from the terminal does not open the panel', 'T256',
     r'''        printf '%s\n' "$(ui_t menu.interface_save_failed)" >&2
    fi
    cmd_panel''',
     r'''        printf '%s\n' "$(ui_t menu.interface_save_failed)" >&2
        return
    fi
    cmd_panel'''),
    ('Interface entry: back to the terminal does not save the terminal', 'T256',
     r'''    if ! ui_pref_set terminal; then''',
     r'''    if ! true; then'''),
    ('Interface entry: a failed save in the panel closes it anyway', 'T256',
     r'''        panel_error_box "$(ui_t panel.interface_save_failed)"
        return 0
''',
     r'''        panel_error_box "$(ui_t panel.interface_save_failed)"
'''),
    ('Interface entry: back to the terminal leaves the panel open', 'T256',
     r'''    PANEL_BACK_TO_TERMINAL=1
}''',
     r'''    PANEL_BACK_TO_TERMINAL=0
}'''),
    ('Interface entry: no notice when the panel has neither a terminal nor an emulator', 'T256',
     r'''        panel_error_box "$(ui_t panel.interface_no_terminal)"
''',
     r'''        :
'''),
    ('Interface entry: with a terminal but no emulator the panel refuses to go back', 'T256',
     r'''    if ! have_terminal && ! terminal_emulator_find >/dev/null; then''',
     r'''    if ! terminal_emulator_find >/dev/null; then'''),
    ('Interface entry: without a terminal an emulator does not help', 'T256',
     r'''    if ! have_terminal && ! terminal_emulator_find >/dev/null; then''',
     r'''    if ! have_terminal; then'''),
    ('Panel loop: the close flag of a previous panel is not reset', 'T256',
     r'''panel_main_menu() {
    PANEL_BACK_TO_TERMINAL=0
''',
     r'''panel_main_menu() {
'''),
    ('Panel loop: the panel stays open after the interface entry', 'T256',
     r'''        (( PANEL_BACK_TO_TERMINAL )) && break
''',
     r'''        :
'''),
    ('Panel blocker: a missing zenity is not detected', 'T256',
     r'''    if ! command -v zenity >/dev/null 2>&1; then
        ui_t panel.zenity_missing''',
     r'''    if false; then
        ui_t panel.zenity_missing'''),
    ('Panel blocker: a missing graphical session is not detected', 'T256',
     r'''    elif ! have_gui_session; then
        ui_t menu.unsupported_gui''',
     r'''    elif false; then
        ui_t menu.unsupported_gui'''),
    ('Panel blocker: a missing installation is not detected', 'T256',
     r'''    elif [[ ! -x "$BIN_DST" ]]; then
        ui_t menu.installed_first''',
     r'''    elif false; then
        ui_t menu.installed_first'''),
    ('Start: no arguments ignore the start interface', 'T257',
     r'''        cmd_start_ui
        ;;
    launch)''',
     r'''        cmd_menu
        ;;
    launch)'''),
    ('Start: "launch" does not tell the start interface that it comes from the launcher', 'T257',
     r'''        cmd_start_ui launch
''',
     r'''        cmd_start_ui
'''),
    ('Start: "menu" consults the start interface', 'T257',
     r'''        cmd_menu
        ;;
    install)''',
     r'''        cmd_start_ui
        ;;
    install)'''),
    ('Start: "panel" consults the start interface', 'T257',
     r'''    panel)
        cmd_panel
        panel_continue_in_terminal''',
     r'''    panel)
        cmd_start_ui
        panel_continue_in_terminal'''),
    ('Start: the pinned panel is ignored', 'T257',
     r'''    if [[ "$pref" == panel ]]; then''',
     r'''    if false; then'''),
    ('Start: the terminal is ignored (the panel always opens)', 'T257',
     r'''    if [[ "$pref" == panel ]]; then''',
     r'''    if true; then'''),
    ('Start: a blocked panel is not reported', 'T257',
     r'''        printf '%s\n' "$why" >&2
        have_terminal && pause_enter''',
     r'''        :
        have_terminal && pause_enter'''),
    ('Start: the reason of a blocked panel goes to stdout', 'T257',
     r'''        printf '%s\n' "$why" >&2
        have_terminal''',
     r'''        printf '%s\n' "$why"
        have_terminal'''),
    ('Start: a blocked panel pauses even without a terminal', 'T257',
     r'''have_terminal && pause_enter''',
     r'''pause_enter'''),
    ('Start: a blocked panel never pauses', 'T257',
     r'''have_terminal && pause_enter''',
     r''':'''),
    ('Start: the reason of a blocked panel is written after the pause', 'T257',
     r'''        printf '%s\n' "$why" >&2
        have_terminal && pause_enter''',
     r'''        have_terminal && pause_enter
        printf '%s\n' "$why" >&2'''),
    ('Start: a blocked panel does not continue in the text menu', 'T257',
     r'''        have_terminal && pause_enter
    fi''',
     r'''        have_terminal && pause_enter
        return 0
    fi'''),
    ('Start: a blocked panel is launched anyway', 'T257',
     r'''        if ! why="$(panel_blocker)"; then''',
     r'''        if true; then'''),
    ('Start: after the panel the text menu always follows', 'T257',
     r'''    (( PANEL_BACK_TO_TERMINAL )) || return 0
''',
     ''),
    ('Start: «back to the terminal» ends the program', 'T257',
     r'''    (( PANEL_BACK_TO_TERMINAL )) || return 0
''',
     r'''    return 0
'''),
    ('Start: «back to the terminal» opens no window without a terminal', 'T257',
     r'''    terminal_open bash "$SELF" menu
}''',
     r'''    return 1
}'''),
    ('Start: a blocked panel resets the start interface to the terminal', 'T257',
     r'''        printf '%s\n' "$why" >&2
''',
     r'''        printf '%s\n' "$why" >&2
        ui_pref_set terminal
'''),
    ('pause_enter: read swallows its own message (D13)', 'T257',
     r'''    [[ -t 0 ]] && printf '%s' "$(ui_t press_enter)" >&2
    read -r _ 2>/dev/null''',
     r'''    read -rp "$(ui_t press_enter)" _ 2>/dev/null'''),
    ('pause_enter: the message goes to stdout', 'T257',
     r'''printf '%s' "$(ui_t press_enter)" >&2''',
     r'''printf '%s' "$(ui_t press_enter)"'''),
    ('pause_enter: the message is written without a terminal', 'T257',
     r'''    [[ -t 0 ]] && printf '%s' "$(ui_t press_enter)" >&2''',
     r'''    printf '%s' "$(ui_t press_enter)" >&2'''),
    ('pause_enter: no message', 'T257',
     r'''    [[ -t 0 ]] && printf '%s' "$(ui_t press_enter)" >&2
''',
     r'''    :
'''),
    ('pause_enter: read errors are visible', 'T257',
     r'''    read -r _ 2>/dev/null
}''',
     r'''    read -r _
}'''),
    ('have_terminal ignores the output', 'T257',
     r'''    [[ -t 0 && -t 1 ]]''',
     r'''    [[ -t 0 ]]'''),
    ('have_terminal ignores the input', 'T257',
     r'''    [[ -t 0 && -t 1 ]]''',
     r'''    [[ -t 1 ]]'''),
    ('have_terminal accepts either one', 'T257',
     r'''    [[ -t 0 && -t 1 ]]''',
     r'''    [[ -t 0 || -t 1 ]]'''),
    ('Help (es): no arguments still open the terminal menu', 'T258',
     r'''abre la interfaz de arranque: el menú de la terminal, o el panel gráfico si se eligió usarlo al iniciar''',
     r'''abre el menú interactivo en la terminal (igual que "menu")'''),
    ('Help (en): no arguments still open the terminal menu', 'T258',
     r'''opens the start interface: the terminal menu, or the graphical panel if you chose to use it at start''',
     r'''opens the interactive terminal menu (same as "menu")'''),
    ('Help (es): menu does not say it ignores the start interface', 'T258',
     r'''abre siempre el menú de la terminal, sin consultar la interfaz de arranque; sin recordar subcomandos''',
     r'''abre el menú interactivo en la terminal; sin recordar subcomandos'''),
    ('Help (en): menu does not say it ignores the start interface', 'T258',
     r'''always opens the terminal menu, ignoring the start interface: all options without remembering subcommands''',
     r'''opens the interactive terminal menu: all options without remembering subcommands'''),
    ('Help (es): panel does not say it ignores the start interface', 'T258',
     r'''abre el panel de control gráfico (zenity), sin consultar la interfaz de arranque''',
     r'''abre el panel de control gráfico (zenity)'''),
    ('Help (en): panel does not say it ignores the start interface', 'T258',
     r'''opens the graphical control panel (zenity), ignoring the start interface''',
     r'''opens the graphical control panel (zenity)'''),
    ('Header: no arguments still open the interactive menu', 'T258',
     r'''(no arguments) opens the start interface: the terminal menu, or the panel if chosen''',
     r'''(no arguments) opens the interactive menu'''),
    ('Header: menu does not say it ignores the start interface', 'T258',
     r'''always opens the terminal menu (ignores the start interface)''',
     r'''opens the interactive menu in the terminal'''),
    ('Header: panel does not say it ignores the start interface', 'T258',
     r'''opens the graphical control panel (zenity; ignores the start interface)''',
     r'''opens the graphical control panel (zenity)'''),
    ('Header: the preference file is misnamed', 'T258',
     r'''(~/.config/vpn-netguard/start-ui,''',
     r'''(~/.config/vpn-netguard/interface,'''),
    ('Header: the way back to the terminal is not named after the panel entry', 'T258',
     r'''and the panel's "Back to the terminal"''',
     r'''and the panel's "Return"'''),
    # --- Fase 9.8: saltos de línea en ui_wrap, ui_note y ui_row (T259) ---
    ('ui_wrap reads only the first line of its text', 'T259',
     r'''    read -ra words <<< "${3//$'\n'/ }"''',
     r'''    read -ra words <<< "$3"'''),
    ('ui_wrap glues the lines of its text together', 'T259',
     r'''    read -ra words <<< "${3//$'\n'/ }"''',
     r'''    read -ra words <<< "${3//$'\n'/}"'''),
    ('ui_note passes only the first line of its text', 'T259',
     r'''    done < <(ui_wrap "  ${glyph:-·} " '    ' "$2")''',
     r'''    done < <(ui_wrap "  ${glyph:-·} " '    ' "${2%%$'\n'*}")'''),
    ('ui_row prints a short value with its line breaks', 'T259',
     r'''    local label="$1" value="${2//$'\n'/ }" level="${3:-}" glyph="" color="" shown pad first rest line''',
     r'''    local label="$1" value="$2" level="${3:-}" glyph="" color="" shown pad first rest line'''),
    # --- Fase 9.8: fila «Historial de eventos» de «Ver estado actual» (T260) ---
    ('Event history row: an empty file is counted as -1 events', 'T260',
     r'''            (( hist_lines >= 0 )) || hist_lines=0''',
     r'''            :'''),
    ('Event history row: the header line is counted as an event', 'T260',
     r'''|| echo 1) - 1 ))''',
     r'''|| echo 1) ))'''),
    ('Event history row: a missing file leaves the count empty', 'T260',
     r'''        hist_lines=0
        if [[ -f "$EVENT_HISTORY_FILE" ]]; then''',
     r'''        if [[ -f "$EVENT_HISTORY_FILE" ]]; then'''),
    ('Event history row: a disabled history still shows its path and count', 'T260',
     r'''    if [[ "$EVENT_HISTORY_ENABLE" == "true" ]]; then
        hist_lines=0''',
     r'''    if true; then
        hist_lines=0'''),
    ('Event history row: the count ignores the file', 'T260',
     r'''hist_lines=$(( $(wc -l < "$EVENT_HISTORY_FILE" 2>/dev/null || echo 1) - 1 ))''',
     r'''hist_lines=0'''),
    ('Event history row (es): the text is not Spanish', 'T260',
     r'''es:status.v_history_on) text='%s (%s eventos registrados)' ;;''',
     r'''es:status.v_history_on) text='%s (%s events recorded)' ;;'''),
    ('Event history row (en): the text is not English', 'T260',
     r'''en:status.v_history_on) text='%s (%s events recorded)' ;;''',
     r'''en:status.v_history_on) text='%s (%s eventos registrados)' ;;'''),
    # --- Fase 9.8: cabecera del historial de eventos (T261) ---
    ('Event history: an empty file does not get its header', 'T261',
     r'''    if [[ ! -s "$EVENT_HISTORY_FILE" ]]; then''',
     r'''    if [[ ! -f "$EVENT_HISTORY_FILE" ]]; then'''),
    ('Event history: every event starts the file over with only the header', 'T261',
     r'''    if [[ ! -s "$EVENT_HISTORY_FILE" ]]; then''',
     r'''    if true; then'''),
    ('Event history: a new file gets no header', 'T261',
     r'''    if [[ ! -s "$EVENT_HISTORY_FILE" ]]; then''',
     r'''    if false; then'''),
    # --- Fase 9.8: aserciones evaluadas de T31 y T64 (hallazgo 9) ---
    ('Event history: a repeated state is recorded again', 'T31',
     r'''    [[ "$key" == "$old" ]] && return 0
''',
     ''),
    ('Event history: quotes in the detail are not doubled', 'T31',
     r'''    detail="${detail//\"/\"\"}"
''',
     ''),
    ('Backoff: a failure never advances the step', 'T64',
     r'''    (( VPN_BACKOFF_STEP < ${#steps[@]} )) && ((VPN_BACKOFF_STEP++))''',
     r'''    :'''),
    ('Backoff: the step grows past the last delay', 'T64',
     r'''    (( VPN_BACKOFF_STEP < ${#steps[@]} )) && ((VPN_BACKOFF_STEP++))''',
     r'''    ((VPN_BACKOFF_STEP++))'''),
    ('Backoff: the delay is read one step ahead', 'T64',
     r'''    local idx=$(( VPN_BACKOFF_STEP - 1 ))''',
     r'''    local idx=$(( VPN_BACKOFF_STEP ))'''),
    ('Backoff: a reset keeps the time of the last attempt', 'T64',
     r'''    VPN_BACKOFF_STEP=0
    VPN_BACKOFF_LAST_ATTEMPT=0
}''',
     r'''    VPN_BACKOFF_STEP=0
}'''),
    ('Backoff: a failure does not stamp the time of the attempt', 'T64',
     r'''    VPN_BACKOFF_LAST_ATTEMPT=$(date +%s)''',
     r'''    :'''),
    ('Backoff: the steps are not normalized when the configuration is loaded', 'T64',
     r'''            RECONNECT_BACKOFF="${normalized_backoff[*]}"''',
     r'''            RECONNECT_BACKOFF="${backoff_steps[*]}"'''),
    # --- Fase 9.8: recorte del historial de eventos (T262, hallazgo 9) ---
    ('Event history trim: 0 no longer means no limit', 'T262',
     r'''    (( EVENT_HISTORY_MAX_LINES > 0 )) || return 0
''',
     ''),
    ('Event history trim: the header is dropped', 'T262',
     r'''    if { head -n1 "$EVENT_HISTORY_FILE"; tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"; then''',
     r'''    if { tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"; then'''),
    ('Event history trim: keeps the oldest events instead of the newest', 'T262',
     r'''tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"''',
     r'''head -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"'''),
    ('Event history trim: keeps one event too many', 'T262',
     r'''tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"''',
     r'''tail -n "$(( EVENT_HISTORY_MAX_LINES + 1 ))" "$EVENT_HISTORY_FILE"; } > "$tmp"'''),
    ('Event history trim: a history within the limit is rewritten', 'T262',
     r'''    (( lines <= 1 || EVENT_HISTORY_MAX_LINES >= lines - 1 )) && return 0
''',
     ''),
    ('Event history trim: one event over the limit is not trimmed', 'T262',
     r'''EVENT_HISTORY_MAX_LINES >= lines - 1 ))''',
     r'''EVENT_HISTORY_MAX_LINES >= lines - 2 ))'''),
    ('Event history trim: a failed write still replaces the history', 'T262',
     r'''    if { head -n1 "$EVENT_HISTORY_FILE"; tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"; then''',
     r'''    { head -n1 "$EVENT_HISTORY_FILE"; tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"
    if true; then'''),
    ('Event history trim: the temporary file is left behind', 'T262',
     r'''        mv -f "$tmp" "$EVENT_HISTORY_FILE"''',
     r'''        cp -f "$tmp" "$EVENT_HISTORY_FILE"'''),
    ('Event history trim: a failed trim leaves its temporary file', 'T262',
     r'''    else
        rm -f "$tmp"
    fi
}

HAVE_IP6TABLES=0''',
     r'''    else
        :
    fi
}

HAVE_IP6TABLES=0'''),
    ('record_event no longer trims the history', 'T262',
     r'''    trim_event_history
}
''',
     r'''}
'''),
    # --- Aserciones antes sueltas de T25, T87, T90 y T102 (9.8 b, hallazgo 10) ---
    ('Fallback restore: the final DROP is missing', 'T25',
     r'''    "$ipt_fn" -A "$chain" -j DROP || return 1
}''',
     r'''}'''),
    ('Fallback restore: the final rule accepts instead of dropping', 'T25',
     r'''    "$ipt_fn" -A "$chain" -j DROP || return 1''',
     r'''    "$ipt_fn" -A "$chain" -j ACCEPT || return 1'''),
    ('Fallback restore: the chain is not flushed first', 'T25',
     r'''    "$ipt_fn" -F "$chain" || return 1
''',
     ''),
    ('Fallback restore: the exception rules are skipped', 'T25',
     r'''    for r in "$@"; do
        # shellcheck disable=SC2086
        "$ipt_fn" -A "$chain" $r || return 1
    done
''',
     ''),
    ('check_dependencies fails without ip6tables (D14)', 'T87',
     r'''    # ip6tables es opcional: sin él esto no es un fallo (doctor lee el código).
    return 0
''',
     ''),
    ('check_dependencies keeps the IPv6 state of the previous check', 'T87',
     r'''    HAVE_IP6TABLES=0
    command -v ip6tables >/dev/null 2>&1 && HAVE_IP6TABLES=1
    # ip6tables es opcional''',
     r'''    command -v ip6tables >/dev/null 2>&1 && HAVE_IP6TABLES=1
    # ip6tables es opcional'''),
    ('check_dependencies never detects ip6tables', 'T87',
     r'''command -v ip6tables >/dev/null 2>&1 && HAVE_IP6TABLES=1
    # ip6tables es opcional''',
     r'''command -v ip6tables >/dev/null 2>&1 && HAVE_IP6TABLES=0
    # ip6tables es opcional'''),
    ('Unowned Firefox policy: apply adopts it', 'T90',
     r'''            log_t warn log.browser_firefox_existing "$FIREFOX_POLICY_FILE"
            rc_ff=1
''',
     r'''            printf '%s\n' "$FIREFOX_POLICY_FILE" > "$FIREFOX_POLICY_MARKER"
'''),
    ('Unowned Firefox policy: remove deletes a file with identical content', 'T90',
     r'''    elif [[ -f "$FIREFOX_POLICY_FILE" ]] && firefox_policy_is_legacy_managed; then
        rm -f "$FIREFOX_POLICY_FILE" || rc=1''',
     r'''    elif [[ -f "$FIREFOX_POLICY_FILE" ]] && firefox_policy_is_managed; then
        rm -f "$FIREFOX_POLICY_FILE" || rc=1'''),
    ('Unowned Firefox policy: remove reports failure', 'T90',
     r'''    elif [[ -f "$FIREFOX_POLICY_FILE" ]] && grep -q '_vpn_netguard_managed' "$FIREFOX_POLICY_FILE" 2>/dev/null; then''',
     r'''    elif [[ -f "$FIREFOX_POLICY_FILE" ]]; then'''),
    ('Config gatekeeper accepts $ inside double quotes', 'T102',
     r'''        elif [[ "$quote" == '"' && ( "$ch" == '$' || "$ch" == '`' ) ]]; then''',
     r'''        elif [[ "$quote" == '"' && ( "$ch" == '`' ) ]]; then'''),
    ('load_config sources a file the gatekeeper rejects', 'T102',
     r'''        if config_file_is_safe "$CONFIG_FILE"; then
            # shellcheck source=/dev/null''',
     r'''        if true; then
            # shellcheck source=/dev/null'''),
    ('load_config rejects the file without a warning', 'T102',
     r'''            log_t warn log.config_unsafe_file "$CONFIG_FILE" >&2
''',
     r'''            :
'''),
    ('load_config fails when it rejects the file', 'T102',
     r'''            log_t warn log.config_unsafe_file "$CONFIG_FILE" >&2
        fi
    fi
''',
     r'''            log_t warn log.config_unsafe_file "$CONFIG_FILE" >&2
            return 1
        fi
    fi
'''),
    ('load_config warns but applies the rejected file anyway', 'T102',
     r'''            log_t warn log.config_unsafe_file "$CONFIG_FILE" >&2
        fi
    fi
''',
     r'''            log_t warn log.config_unsafe_file "$CONFIG_FILE" >&2
            source "$CONFIG_FILE"
        fi
    fi
'''),
    ('Terminal emulators: the system alternative is no longer the first', 'T263',
     r'''x-terminal-emulator|-e
gnome-terminal|--
''',
     r'''gnome-terminal|--
x-terminal-emulator|-e
'''),
    ('Terminal emulators: xfce4-terminal takes -e instead of -x', 'T263',
     r'''xfce4-terminal|-x
''',
     r'''xfce4-terminal|-e
'''),
    ('Terminal emulators: kitty gets an option it does not take', 'T263',
     r'''kitty|
foot|
''',
     r'''kitty|-e
foot|
'''),
    ('Terminal emulators: a file without execute permission counts as installed', 'T263',
     r'''        [[ -x "$path" ]] || continue
''',
     ''),
    ('Terminal emulators: every installed one is listed, not only the first', 'T263',
     r'''        printf '%s' "$line"
        return 0
''',
     r'''        printf '%s' "$line"
'''),
    ('terminal_open passes an empty option to emulators that take none', 'T263',
     r'''    if [[ -n "$flag" ]]; then
        "$name" "$flag" "$@"
''',
     r'''    if true; then
        "$name" "$flag" "$@"
'''),
    ('terminal_open returns the emulator status', 'T263',
     r'''        "$name" "$@"
    fi
    return 0
}
''',
     r'''        "$name" "$@"
    fi
}
'''),
    ('terminal_open splits the command arguments', 'T263',
     r'''        "$name" "$flag" "$@"
''',
     r'''        "$name" "$flag" $@
'''),
    ('terminal_open runs xterm instead of failing without an emulator', 'T263',
     r'''    found="$(terminal_emulator_find)" || return 1
''',
     r'''    found="$(terminal_emulator_find)" || found='xterm|-e'
'''),
    ('The desktop launcher runs panel instead of launch', 'T264',
     r'''Exec=$BIN_DST launch
''',
     r'''Exec=$BIN_DST panel
'''),
    ('launch without a choice opens the terminal', 'T264',
     r'''        if (( launcher )); then pref=panel; else pref=terminal; fi
''',
     r'''        pref=terminal
'''),
    ('Back to the terminal opens no window', 'T264',
     r'''    (( PANEL_BACK_TO_TERMINAL )) || return 0
''',
     r'''    return 0
'''),
    ('The terminal window runs no menu', 'T264',
     r'''    terminal_open bash "$SELF" menu
''',
     r'''    terminal_open bash "$SELF"
'''),
    ('launch from a terminal opens a window instead of the menu here', 'T264',
     r'''    if have_terminal; then
        cmd_menu
        return 0
''',
     r'''    if false; then
        cmd_menu
        return 0
'''),
    ('launch without terminal, emulator or panel exits 0', 'T264',
     r'''        panel_blocker >/dev/null && return 1
''',
     r'''        panel_blocker >/dev/null && return 0
'''),
    ('launch without an emulator opens the panel without the notice', 'T264',
     r'''        panel_info_box "$(ui_t ui.no_terminal_emulator)"
        cmd_panel
''',
     r'''        cmd_panel
'''),
    ('launch with a blocked panel does not say why', 'T264',
     r'''        printf '%s\n' "$why" >&2
        have_terminal && pause_enter
''',
     r'''        have_terminal && pause_enter
'''),
    ('launch with a blocked panel does not pause on a terminal', 'T264',
     r'''        have_terminal && pause_enter
''',
     r''':
'''),
    ('The dispatcher drops the launch argument', 'T264',
     r'''        cmd_start_ui launch
''',
     r'''        cmd_start_ui
'''),
    ('The start interface ignores the saved preference', 'T264',
     r'''    pref="$(ui_pref_get)"
''',
     r'''    pref=""
'''),
    ('launch never opens the text menu window', 'T264',
     r'''    elif ! open_text_menu; then
''',
     r'''    elif false; then
'''),
    ('A new state file that new_env does not redirect', 'T265',
     r'''HEARTBEAT_FILE="$STATE_DIR/heartbeat"   # epoch de la última reconciliación completa (ver watchdog_ping_if_alive)
''',
     r'''HEARTBEAT_FILE="$STATE_DIR/heartbeat"   # epoch de la última reconciliación completa (ver watchdog_ping_if_alive)
NEW_STATE_FILE="$STATE_DIR/new-state"
'''),
    ('A new system path outside the state directory that new_env does not redirect', 'T265',
     r'''LOCK_FILE="/run/vpn-netguard.lock"
''',
     r'''LOCK_FILE="/run/vpn-netguard.lock"
NEW_RUN_FILE="/run/vpn-netguard-new"
'''),
    ('Uninstall ignores the desktops of root', 'T266',
     r'''    for d in "$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR"/*/Desktop "$USERS_HOME_DIR"/*/Escritorio; do
''',
     r'''    for d in "$USERS_HOME_DIR"/*/Desktop "$USERS_HOME_DIR"/*/Escritorio; do
'''),
    ('Uninstall ignores the desktops of the users', 'T266',
     r'''    for d in "$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR"/*/Desktop "$USERS_HOME_DIR"/*/Escritorio; do
''',
     r'''    for d in "$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio"; do
'''),
    ('Uninstall ignores the Spanish desktop folder', 'T266',
     r'''    for d in "$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR"/*/Desktop "$USERS_HOME_DIR"/*/Escritorio; do
''',
     r'''    for d in "$ROOT_HOME_DIR/Desktop" "$USERS_HOME_DIR"/*/Desktop; do
'''),
    ('Uninstall ignores the English desktop folder', 'T266',
     r'''    for d in "$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR"/*/Desktop "$USERS_HOME_DIR"/*/Escritorio; do
''',
     r'''    for d in "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR"/*/Escritorio; do
'''),
    ('Uninstall removes the whole desktop folder', 'T266',
     r'''        [[ -f "$d/vpn-netguard.desktop" ]] && rm -f "$d/vpn-netguard.desktop"
''',
     r'''        [[ -f "$d/vpn-netguard.desktop" ]] && rm -rf "$d"
'''),
    ('IPv4 kill switch removal reports failure after a clean teardown', 'T95',
     '''    [[ $removed -eq 1 ]] && ! killswitch_is_yielding && notify_event off normal "$(ui_t notify.ks_disabled)"
    [[ $rc4 -eq 0 && $rc6 -eq 0 ]]
}''',
     '''    [[ $removed -eq 1 ]] && ! killswitch_is_yielding && notify_event off normal "$(ui_t notify.ks_disabled)"
    [[ $rc4 -eq 0 && $rc6 -eq 0 ]] && return 1
}'''),
    ('IPv6 kill switch removal reports failure after a clean teardown', 'T96',
     '''    ipt6 -X "$CHAIN_NAME_V6" 2>/dev/null || return 1
    log_t info log.ks6_removed
}''',
     '''    ipt6 -X "$CHAIN_NAME_V6" 2>/dev/null || return 1
    log_t info log.ks6_removed
    return 1
}'''),
]


def run_suite(test_id, script):
    """Ejecuta solo el test indicado contra `script`: (código de salida, salida); (None, '') si se cuelga."""
    proc = subprocess.Popen(
        [str(SUITE)], cwd=ROOT, start_new_session=True,
        env={**os.environ, 'VPN_NETGUARD_TEST_ONLY': test_id, 'VPN_NETGUARD_TEST_SCRIPT': str(script)},
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    try:
        out, _ = proc.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)   # el grupo entero: un subshell huérfano seguiría ciclando
        proc.communicate()
        return None, ''
    return proc.returncode, out


def run_mutant(name, test_id, script):
    """True si el test detecta el mutante (la suite falla o se cuelga)."""
    rc, out = run_suite(test_id, script)
    if rc is None:
        print(f'ok   mutation {name} [{test_id}]: detected (timeout {TIMEOUT} s)')
        return True
    if rc == 0:
        print(f'FAIL mutation {name} [{test_id}]: targeted test stayed green', file=sys.stderr)
        print(out, file=sys.stderr)
        return False
    print(f'ok   mutation {name} [{test_id}]: detected')
    return True


def precheck(test_ids):
    """Cada test debe pasar, solo, contra el script sin mutar: si ya falla o se cuelga, «detectaría» cualquier
    mutante sin probar nada. Un test inexistente también cuenta: el arnés sale con 0 sin ejecutar nada, así que se
    exige su línea «ok   T<n> ». Devuelve los que no pasan."""
    failing = set()
    for test_id in sorted(test_ids, key=lambda t: (len(t), t)):
        rc, out = run_suite(test_id, SCRIPT)
        if rc == 0 and any(line.startswith(f'ok   {test_id} ') for line in out.splitlines()):
            continue
        failing.add(test_id)
        print(f'FAIL precheck [{test_id}]: {"timeout" if rc is None else "does not pass on the original script"}', file=sys.stderr)
        print(out, file=sys.stderr)
    print(f'Precheck: {len(test_ids) - len(failing)}/{len(test_ids)} tests pass on the original script')
    return failing


ONLY = set(sys.argv[1:])
if ONLY:
    MUTATIONS = [m for m in MUTATIONS if m[1] in ONLY]
    if not MUTATIONS:
        sys.exit(f'no hay mutaciones para {sorted(ONLY)}')

detected = 0
with tempfile.TemporaryDirectory(prefix='vpn-netguard-mut-') as td:
    td = Path(td)
    original = SCRIPT.read_text(encoding='utf-8')
    ready = []
    for mutation in MUTATIONS:
        count = original.count(mutation[2])
        if count == 1:
            ready.append(mutation)
        else:
            print(f'FAIL mutation {mutation[0]} [{mutation[1]}]: target count={count}', file=sys.stderr)
    failing = precheck({m[1] for m in ready})
    for name, test_id, needle, replacement in ready:
        if test_id in failing:
            continue
        mutant = td / f'{test_id}.sh'
        mutant.write_text(original.replace(needle, replacement, 1), encoding='utf-8')
        detected += run_mutant(name, test_id, mutant)

total = len(MUTATIONS)
print(f'\nMutation test summary: {detected}/{total} detected')
sys.exit(0 if detected == total else 1)
