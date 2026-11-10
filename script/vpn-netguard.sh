#!/usr/bin/env bash
#
# Copyright (C) 2026 Filonux
#
# License:
# VPN NetGuard is free software distributed under the terms of the
# GNU General Public License version 3 (GPLv3).
# See the LICENSE.txt file for the full text of the license.
#
# vpn-netguard.sh — all in one (Linux Mint 22.3 Cinnamon; it also runs as a
#                    headless service on a Debian/Ubuntu server with
#                    NetworkManager, with no desktop and no zenity)
# Author: Filonux
# =============================================================================
# A single file that replaces the former separate ones (watcher, panel,
# installer, configuration, systemd units and desktop launcher).
#
# The default configuration, the systemd units (the main service; an
# early-boot oneshot that closes the unprotected window before the main
# service has started; and the optional MAC rotation units) and the desktop
# launcher are embedded here as templates. The `install` subcommand writes
# them to disk.
#
# INSTALLATION (once), from the folder where you saved this file:
#
#     pkexec bash vpn-netguard.sh install
#
# After that, daily use can be graphical: look for "VPN NetGuard" in the
# Applications menu (or on the Desktop, if you asked for that during the
# installation). Every action that needs privileges asks for the password
# through pkexec, so a terminal is never needed; "1-click set & forget" asks
# for it only once for all of its steps.
#
# ON A SERVER WITHOUT A GRAPHICAL ENVIRONMENT (over SSH, no DISPLAY or
# WAYLAND_DISPLAY): use "sudo" instead of "pkexec" (pkexec needs polkit and a
# graphical session, and is usually not installed on a server):
#
#     sudo bash vpn-netguard.sh install
#
# Without a graphical session the installer runs a text wizard instead of
# zenity and installs nothing graphical. The rest of the program (monitoring,
# kill switch, reconnection, menu) is the same binary in both cases; only the
# graphical panel ("panel") needs zenity, and it says so when zenity is
# missing. NetworkManager (nmcli) is required in any case: if the server uses
# plain netplan/systemd-networkd, install NetworkManager as well.
#
# For unattended provisioning (Ansible, cloud-init, Dockerfile...) without an
# interactive terminal, "install" accepts flags, or the VPN_NETGUARD_INSTALL_*
# environment variables, that skip the yes/no questions:
#
#     sudo bash vpn-netguard.sh install --yes
#     sudo bash vpn-netguard.sh install --autostart --start-now --no-privacy
#
# "--yes"/"-y" sets autostart, start now and menu entry to "yes" and network
# privacy to "no", unless a specific flag says otherwise. Specific flags:
# --[no-]autostart, --[no-]start-now, --[no-]privacy, --[no-]menu-entry.
# Without any of them the installer stays interactive; none of them affects
# the graphical installer (zenity).
#
# If you prefer the terminal (or just run this file as it is), an interactive
# menu with every option opens: no subcommand to remember and no zenity needed:
#
#     bash vpn-netguard.sh
#
# That is the start interface by default. The menu entry that opens the graphical
# panel makes the panel the start interface, and the panel's "Back to the terminal"
# entry makes the terminal the one again and takes you there at once: in the terminal
# that launched the panel or, if it came from the Applications menu entry (which has
# none), in a new terminal window. It is a per-user preference
# (~/.config/vpn-netguard/start-ui, or under XDG_CONFIG_HOME) and needs no password.
# "bash vpn-netguard.sh" and the Applications menu entry ("launch") both follow it;
# with no choice made yet, the first opens the terminal menu and the second the panel.
# "menu" and "panel" are explicit and never consult it.
#
# Subcommands (advanced use / terminal debugging):
#   vpn-netguard.sh                       (no arguments) opens the start interface: the terminal menu, or the panel if chosen
#   vpn-netguard.sh menu                  always opens the terminal menu (ignores the start interface)
#   vpn-netguard.sh install               installs the program on the system
#   vpn-netguard.sh uninstall             uninstalls the program from the system
#   vpn-netguard.sh panel                 opens the graphical control panel (zenity; ignores the start interface)
#   vpn-netguard.sh launch                what the Applications menu entry runs: the start interface, in a terminal window if it needs one
#   vpn-netguard.sh start                 runs the watcher (used by systemd)
#   vpn-netguard.sh boot-killswitch       early block before the network is up (used by systemd)
#   vpn-netguard.sh status                shows the current status
#   vpn-netguard.sh check                 health check (cron/monitoring)
#   vpn-netguard.sh doctor                combined diagnostics (dependencies, network, firewall, kill switch, coexistence)
#   vpn-netguard.sh one-click             recommended profile: backup, network privacy, VPN protection and restart
#   vpn-netguard.sh activate              enables VPN protection (marks the VPN as wanted, connects, monitors)
#   vpn-netguard.sh deactivate            disables VPN protection (disconnects the VPN, except VPN_IGNORE
#                                         profiles, and turns the kill switch off)
#   vpn-netguard.sh killswitch on|off|auto|status   single kill switch control
#   vpn-netguard.sh disable-killswitch    alias of "killswitch off"
#   vpn-netguard.sh enable-killswitch     alias of "killswitch on"
#   vpn-netguard.sh apply-privacy         (re)applies network privacy (MAC, IPv6, hostname)
#   vpn-netguard.sh rotate-mac            regenerates the "stable" MAC now (internal use by the timer)
#   vpn-netguard.sh privacy-status        shows the network privacy status
#   vpn-netguard.sh export-config [path]  exports vpn-netguard.conf (backup)
#   vpn-netguard.sh import-config <path>  imports vpn-netguard.conf (restore)
#   vpn-netguard.sh sync-localized        rewrites the installed units and .desktop in the current language
#   vpn-netguard.sh version               shows the installed version
#
# Root is required (systemd, pkexec or sudo) for: install, uninstall, start,
# boot-killswitch, status, check, one-click, activate, deactivate, killswitch,
# enable-killswitch, disable-killswitch, apply-privacy, rotate-mac,
# privacy-status, import-config and sync-localized. Without root: menu, panel,
# export-config, version, --help and doctor (which skips its firewall, kill
# switch and coexistence checks).
#
# Coexistence with other VPN clients (NordVPN, ProtonVPN...): with
# COEXIST_MODE="auto" (the default) NetGuard lets the tunnels and marks of
# other clients through and yields the block while it detects an active
# foreign kill switch; VPN_IGNORE excludes NetworkManager profiles that belong
# to another provider. Both are documented in the default configuration.
# =============================================================================

set -o pipefail

# -----------------------------------------------------------------------------
# Rutas de instalación en el sistema (constantes; las usan tanto el propio
# demonio como el instalador/desinstalador y el panel para llamarse a sí
# mismo con pkexec una vez instalado).
# -----------------------------------------------------------------------------
BIN_DST="/usr/local/bin/vpn-netguard.sh"
CONF_DIR="/etc/vpn-netguard"
CONFIG_FILE="$CONF_DIR/vpn-netguard.conf"
CONFIG_SIG=""   # firma de $CONFIG_FILE en la última carga (ver config_reload_if_changed)
STATE_DIR="/var/lib/vpn-netguard"
STATE_FILE="$STATE_DIR/wanted"   # "on"/vacío = activado, "off" = desactivado explícito; ausente = nunca tocado
KILLSWITCH_OVERRIDE_FILE="$STATE_DIR/killswitch-override"
COEXIST_YIELD_FILE="$STATE_DIR/coexist-yield"   # kill switch(es) ajenos ante los que NetGuard cede el bloqueo; ausente = no cede (ver coexist_sync_yield)
KS_BOOT_RACE_MARKER_FILE="$STATE_DIR/killswitch-autodisabled"   # ver warn_ks_boot_race_if_stuck
KS_BOOT_RACE_PENDING_FILE="$STATE_DIR/killswitch-boot-race-pending"   # epoch de armado; ausente = resuelto/entregado
MAC_ROTATE_TOKEN_FILE="$STATE_DIR/mac-rotate-token"   # semilla que cambia en cada rotación por temporizador
EVENT_HISTORY_FILE="$STATE_DIR/history.csv"          # historial de subidas/caídas (ver EVENT_HISTORY_ENABLE)
EVENT_HISTORY_STATE_FILE="$STATE_DIR/history-last-state"   # dedup independiente del de las notificaciones
HEARTBEAT_FILE="$STATE_DIR/heartbeat"   # epoch de la última reconciliación completa (ver watchdog_ping_if_alive)
UNIT_DST="/etc/systemd/system/vpn-netguard.service"
BOOT_UNIT_DST="/etc/systemd/system/vpn-netguard-boot.service"
MAC_ROTATE_UNIT_DST="/etc/systemd/system/vpn-netguard-mac-rotate.service"
MAC_ROTATE_TIMER_DST="/etc/systemd/system/vpn-netguard-mac-rotate.timer"
DESKTOP_DST="/usr/share/applications/vpn-netguard.desktop"
ICON_DST="/usr/local/share/vpn-netguard/icon.svg"
ROOT_HOME_DIR="/root"     # cmd_uninstall retira el lanzador que instalar copió al Escritorio de root
USERS_HOME_DIR="/home"    # ... y al de cada usuario ($USERS_HOME_DIR/*)
SERVICE="vpn-netguard.service"
BOOT_SERVICE="vpn-netguard-boot.service"
MAC_ROTATE_TIMER="vpn-netguard-mac-rotate.timer"
LOCK_FILE="/run/vpn-netguard.lock"
CHAIN_NAME="NETGUARD_KS"
CHAIN_NAME_V6="NETGUARD_KS6"
TITLE="VPN NetGuard"
VERSION="2.6.0"

# Jerarquía visual de status/doctor/logs: color solo si la salida
# es una terminal real (si no, p.ej. el panel captura este mismo texto con
# "$(...)" para un zenity --text-info, y no debe llevar códigos ANSI) y
# nadie ha pedido NO_COLOR/TERM=dumb. Los símbolos sí se mantienen siempre:
# también dan jerarquía dentro de zenity, que no interpreta color ANSI.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    C_B=$'\033[1m'; C_0=$'\033[0m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'
else
    C_B=; C_0=; C_OK=; C_WARN=; C_BAD=
fi
ui_section() { printf '\n%s%s%s\n' "$C_B" "$1" "$C_0"; }
ui_good()    { printf '%s✓ %s%s\n' "$C_OK" "$1" "$C_0"; }
ui_warn()    { printf '%s⚠ %s%s\n' "$C_WARN" "$1" "$C_0"; }
ui_bad()     { printf '%s✗ %s%s\n' "$C_BAD" "$1" "$C_0"; }

# Pantallas de estado (status, killswitch status, privacy-status): ancho fijo de
# UI_WIDTH columnas, con la etiqueta en las primeras UI_LABEL_W. Todo se cuenta en
# caracteres y no en bytes: pkexec lanza el script sin LANG (locale C) y printf
# rellenaría por bytes, descuadrando los acentos.
UI_WIDTH=64
UI_LABEL_W=22

# Caracteres (no bytes) de $1, también en una locale C: se descartan los bytes de
# continuación UTF-8 (0x80-0xBF).
ui_text_len() {
    local t="${1//[$'\200'-$'\277']/}"
    printf '%d' "${#t}"
}

# ui_rule [carácter]: línea de UI_WIDTH columnas.
ui_rule() {
    local line
    printf -v line '%*s' "$UI_WIDTH" ''
    printf '%s\n' "${line// /${1:-─}}"
}

# ui_banner <título>: «VPN NetGuard · título» entre dos líneas dobles.
ui_banner() {
    local rule
    rule="$(ui_rule '═')"
    printf '%s%s\n  %s · %s\n%s%s\n' "$C_B" "$rule" "$TITLE" "$1" "$rule" "$C_0"
}

# ui_block <título>: línea en blanco y «── título ───…» hasta UI_WIDTH.
ui_block() {
    local head="── $1 " fill pad
    pad=$(( UI_WIDTH - $(ui_text_len "$head") )); (( pad < 0 )) && pad=0
    printf -v fill '%*s' "$pad" ''
    printf '\n%s%s%s%s\n' "$C_B" "$head" "${fill// /─}" "$C_0"
}

# ui_wrap <prefijo 1.ª línea> <prefijo resto> <texto>: ajusta el texto a
# UI_WIDTH por palabras (una palabra más larga se deja entera). Un salto de
# línea cuenta como un espacio: el texto es un solo párrafo («read» solo lee
# la primera línea y perdería el resto).
ui_wrap() {
    local first="$1" rest="$2" word line len wl empty=1
    local -a words
    read -ra words <<< "${3//$'\n'/ }"
    line="$first"; len="$(ui_text_len "$line")"
    for word in "${words[@]}"; do
        wl="$(ui_text_len "$word")"
        if (( empty )); then
            line+="$word"; len=$(( len + wl )); empty=0
        elif (( len + 1 + wl <= UI_WIDTH )); then
            line+=" $word"; len=$(( len + 1 + wl ))
        else
            printf '%s\n' "$line"
            line="$rest$word"; len=$(( $(ui_text_len "$rest") + wl ))
        fi
    done
    printf '%s\n' "$line"
}

# Símbolo y color de un nivel (ok | warn | bad); cualquier otro no lleva ninguno.
# El símbolo distingue el nivel también donde no hay color (zenity).
ui_glyph() { case "$1" in ok) printf '✓' ;; warn) printf '⚠' ;; bad) printf '✗' ;; esac; }
ui_color() { case "$1" in ok) printf '%s' "$C_OK" ;; warn) printf '%s' "$C_WARN" ;; bad) printf '%s' "$C_BAD" ;; esac; }

# ui_row <etiqueta> <valor> [ok|warn|bad]: «  Etiqueta        valor». Un valor que no
# cabe junto a la etiqueta (rutas, listas, frases) baja a su propia línea, con sangría.
# Los saltos de línea del valor cuentan como espacios.
ui_row() {
    local label="$1" value="${2//$'\n'/ }" level="${3:-}" glyph="" color="" shown pad first rest line
    if [[ -n "$level" ]]; then glyph="$(ui_glyph "$level")"; color="$(ui_color "$level")"; fi
    shown="$value"; [[ -n "$glyph" ]] && shown="$glyph $value"
    if (( $(ui_text_len "$label") >= UI_LABEL_W || $(ui_text_len "$shown") > UI_WIDTH - 2 - UI_LABEL_W )); then
        printf '  %s\n' "$label"
        first='    '; rest='    '
        [[ -n "$glyph" ]] && { first="    $glyph "; rest='      '; }
        while IFS= read -r line; do printf '%s%s%s\n' "$color" "$line" "$C_0"; done < <(ui_wrap "$first" "$rest" "$value")
        return 0
    fi
    pad=$(( UI_LABEL_W - $(ui_text_len "$label") ))
    printf '  %s%*s%s%s%s\n' "$label" "$pad" '' "$color" "$shown" "$C_0"
}

# ui_yesno <true|false>: «sí/no» (cualquier valor distinto de true es «no»).
ui_yesno() { if [[ "$1" == true ]]; then ui_t yes; else ui_t no; fi; }

# ui_note <ok|warn|bad> <texto>: aviso de una o varias líneas, con símbolo y sangría.
ui_note() {
    local glyph color line
    glyph="$(ui_glyph "$1")"; color="$(ui_color "$1")"
    while IFS= read -r line; do
        printf '%s%s%s\n' "$color" "$line" "$C_0"
    done < <(ui_wrap "  ${glyph:-·} " '    ' "$2")
}

# Fichero de configuración de NetworkManager donde vive el módulo de
# anonimato de red (MAC aleatoria, IPv6 privado, ocultar nombre de equipo).
# Es un simple "snippet" de NetworkManager.conf: NetworkManager lo lee él
# solo en cada arranque/recarga, así que no hace falta systemd ni un
# proceso propio para que estos ajustes se apliquen y persistan.
NM_PRIVACY_CONF="/etc/NetworkManager/conf.d/80-vpn-netguard-privacy.conf"

# Rutas de política usadas por HARDEN_BROWSER_DOH (ver aviso junto a
# DNS_SERVERS en write_default_config). Firefox lee un único policies.json;
# Chrome/Chromium leen TODOS los .json de su carpeta "managed", así que ahí
# basta con dejar el nuestro con nombre propio. Chromium cambia de ruta
# según cómo lo empaquete cada distro (paquete "chromium" vs "chromium-browser"
# más antiguo); se escribe en ambas por si acaso, es inofensivo si una no aplica.
FIREFOX_POLICY_FILE="/etc/firefox/policies/policies.json"
FIREFOX_POLICY_MARKER="$STATE_DIR/browser-doh-firefox-created"
CHROME_POLICY_DIR="/etc/opt/chrome/policies/managed"
CHROMIUM_POLICY_DIR="/etc/chromium/policies/managed"
CHROMIUM_BROWSER_POLICY_DIR="/etc/chromium-browser/policies/managed"
CHROME_POLICY_MARKER="$STATE_DIR/browser-doh-chrome-created"
CHROMIUM_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-created"
CHROMIUM_BROWSER_POLICY_MARKER="$STATE_DIR/browser-doh-chromium-browser-created"

# Ruta real de este propio fichero en disco (para que `install` pueda
# copiarse a sí mismo en $BIN_DST). Si el script se ha ejecutado por stdin
# (p. ej. `curl ... | bash`) no habrá fichero real; se avisa más abajo.
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

config_key_allowed() {
    case "$1" in
        LANGUAGE|KILLSWITCH_MODE|KILLSWITCH_BOOT_RACE_AUTO_DISABLE|COEXIST_MODE|ALLOW_LAN|ETH_CONNECTION|WIFI_CONNECTION|VPN_CONNECTION|VPN_PRIORITY|VPN_IGNORE|VPN_ENDPOINT_OVERRIDE|CHECK_INTERVAL|RECONNECT_BACKOFF|PING_TARGETS|PING_TIMEOUT|LOG_LEVEL|DNS_SERVERS|DESKTOP_NOTIFICATIONS|ALERT_HOOK|PROMETHEUS_TEXTFILE_DIR|EVENT_HISTORY_ENABLE|EVENT_HISTORY_MAX_LINES|ANONYMIZE_NETWORK|MAC_MODE|MAC_OUI_MASK|ROTATE_MAC_PER_BOOT|ROTATE_MAC_EVERY_HOURS|RANDOMIZE_SCAN_MAC|SPOOF_HOSTNAME|DHCP_HOSTNAME_OVERRIDE|HARDEN_DHCP_IDENTIFIERS|IPV6_PRIVACY|DISABLE_IPV6|DISABLE_MDNS_ANNOUNCE|DISABLE_AVAHI_SERVICE|DISABLE_NETBIOS_SERVICE|HARDEN_BROWSER_DOH) return 0 ;;
        *) return 1 ;;
    esac
}

# Valida que "value" sea un entero decimal <= "max" (ambos sin signo) y lo
# devuelve sin ceros a la izquierda. Compara por longitud/orden lexicográfico
# a propósito, no con (( )): así no rompe con enteros mayores que el rango de
# bash ni con ceros a la izquierda (que (( )) interpretaría como octal).
decimal_normalize_max() {
    local value="$1" max="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    value="${value#"${value%%[!0]*}"}"
    [[ -n "$value" ]] || value=0
    if (( ${#value} < ${#max} )) || {
        # shellcheck disable=SC2071 # cadenas de igual longitud: comparación léxica a propósito, no numérica
        (( ${#value} == ${#max} )) && { [[ "$value" < "$max" ]] || [[ "$value" == "$max" ]]; };
    }; then
        printf '%s\n' "$value"
    else
        return 1
    fi
}

# Máximo de caracteres del valor de una línea de la configuración, ya escapado
# con %q. config_file_is_safe rechaza el fichero ENTERO si una línea lo supera;
# por eso panel_write_config_keys no guarda nada que lo supere.
CONFIG_VALUE_MAX=1024
# Motivo del último rechazo de panel_write_config_keys (vacío si guardó).
CONFIG_WRITE_ERROR=""

# Gatekeeper antes de 'source "$CONFIG_FILE"' (load_config): recorre el
# valor carácter a carácter aceptando solo KEY=VALUE con clave permitida y
# sin sustituciones/metacaracteres sueltos fuera de comillas; si algo no
# cuadra, rechaza el fichero completo (falla cerrado) en vez de sourcearlo.
config_file_is_safe() {
    local line key rhs ch escaped quote ansi separator_seen i
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Fin de línea CRLF (fichero editado desde Windows): "read -r" no
        # recorta el '\r', que quedaría pegado al valor tras el 'source'
        # (p. ej. KILLSWITCH_MODE="auto\r"), rompiendo comparaciones exactas
        # más adelante sin ningún aviso. Se rechaza aquí mismo.
        [[ "$line" == *$'\r'* ]] && return 1
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        rhs="${BASH_REMATCH[2]}"
        config_key_allowed "$key" || return 1
        # Cota de longitud antes del escaneo carácter a carácter: ningún
        # valor legítimo de este fichero necesita acercarse a esto, y sin
        # este límite un valor de ~200000 caracteres tarda ~85s en validarse.
        (( ${#rhs} <= CONFIG_VALUE_MAX )) || return 1

        quote=""
        escaped=0
        ansi=0
        separator_seen=0
        for ((i=0; i<${#rhs}; i++)); do
            ch="${rhs:i:1}"
            if (( escaped )); then
                escaped=0
                continue
            fi
            if (( ansi )); then
                # Contenido de un $'...' (comillas ANSI-C, lo que produce
                # "printf %q" para bytes no imprimibles): "\" escapa el
                # siguiente carácter y no hay expansiones de ningún tipo,
                # así que un "$"/backtick aquí dentro es literal e inofensivo.
                if [[ "$ch" == \\ ]]; then
                    escaped=1
                elif [[ "$ch" == "'" ]]; then
                    ansi=0
                fi
                continue
            fi
            if [[ -n "$quote" ]]; then
                if [[ "$ch" == "$quote" ]]; then
                    quote=""
                elif [[ "$ch" == \\ && "$quote" == '"' ]]; then
                    escaped=1
                elif [[ "$quote" == '"' && ( "$ch" == '$' || "$ch" == '`' ) ]]; then
                    return 1
                fi
                continue
            fi
            # separator_seen=1 tras un espacio sin comillas: cualquier carácter
            # no-espacio después (aunque abra comillas) sería una segunda
            # palabra que "source" ejecutaría como comando aparte (ej.
            # "CLAVE=   ls" ejecuta "ls"); por eso se rechaza aquí.
            case "$ch" in
                \\)
                    (( separator_seen )) && return 1
                    escaped=1
                    ;;
                '$')
                    (( separator_seen )) && return 1
                    if [[ "${rhs:i+1:1}" == "'" ]]; then
                        ansi=1
                        ((i++))
                    else
                        return 1
                    fi
                    ;;
                '"'|"'")
                    (( separator_seen )) && return 1
                    quote="$ch"
                    ;;
                '`'|';'|'|'|'&'|'<'|'>'|'('|')')
                    return 1
                    ;;
                [[:space:]])
                    separator_seen=1
                    ;;
                '#')
                    (( separator_seen )) && break
                    ;;
                *)
                    (( separator_seen )) && return 1
                    ;;
            esac
        done
        [[ $escaped -eq 0 && -z $quote && $ansi -eq 0 ]] || return 1
    done < "$1"
    return 0
}

# =============================================================================
# PLANTILLAS EMBEBIDAS
# =============================================================================

# Configuración por defecto. Solo se escribe si no existe ya un fichero de
# configuración (para no pisar los ajustes de una instalación previa).
write_default_config() {
    local config_language="${UI_LANGUAGE:-es}"
    [[ "$config_language" == es || "$config_language" == en ]] || config_language=es
    cat <<'EOF'
# Configuración de vpn-netguard
# Ruta: /etc/vpn-netguard/vpn-netguard.conf
#
# Los cambios de este fichero (a mano o desde el panel gráfico) los detecta el
# servicio y los aplica solo en unos segundos; no hace falta reiniciarlo.
# Los ajustes de anonimato de red (MAC, hostname, IPv6, DNS-over-HTTPS...) se
# aplican con 'vpn-netguard.sh apply-privacy' (menú de terminal: Ajustes de
# anonimato de red > Aplicar ahora; panel gráfico: Aceptar en ese formulario).

# Idioma de la interfaz (menú, panel, notificaciones).
EOF
    printf 'LANGUAGE="%s"   # es | en\n' "$config_language"
    cat <<'EOF'

# Modo del kill switch:
#   auto  -> el bloqueo se activa solo cuando pulsas "Activar" en el panel
#            (o ejecutas 'vpn-netguard.sh activate') y existe un perfil VPN.
#            Una vez activado así, el bloqueo TAMBIÉN se aplica desde el
#            arranque en cada reinicio posterior (persiste hasta que pulses
#            "Desactivar"), con el mismo riesgo de choque con el kill switch
#            del propio cliente VPN que describe la opción "true" de abajo.
#   true  -> el bloqueo está siempre activo mientras el servicio corre,
#            incluido el arranque del sistema (antes de que NetworkManager
#            esté listo). Si tu cliente VPN (NordVPN, etc.) tiene TAMBIÉN
#            su propio kill switch, ambos pueden pisarse justo al arrancar:
#            el de VPN NetGuard bloquea todo hasta reconocer la VPN, y si
#            eso retrasa la conexión, el kill switch del propio cliente
#            puede quedarse bloqueando aunque VPN NetGuard ya lo permita.
#            Para evitarlo, rellena VPN_ENDPOINT_OVERRIDE más abajo con la
#            dirección real del servidor (así se permite desde el primer
#            segundo del arranque), o desactiva el kill switch del cliente
#            VPN y deja que solo lo controle VPN NetGuard. COEXIST_MODE (más
#            abajo) deja pasar el túnel y la marca del otro cliente, pero con
#            "true" NetGuard no cede el bloqueo.
#   false -> el kill switch nunca bloquea nada (solo vigila y reconecta).
# Este modo es la política "automática". 'vpn-netguard.sh killswitch on|off'
# la fuerza por encima de este valor y 'vpn-netguard.sh killswitch auto'
# vuelve a ella.
KILLSWITCH_MODE="auto"

# Si el choque de arriba ocurre y varias reconciliaciones después sigue sin
# haber VPN activa, este ajuste decide qué hace VPN NetGuard:
#   false -> (por defecto) solo avisa; el bloqueo sigue activo hasta que tú
#            mismo ejecutes 'vpn-netguard.sh killswitch off'.
#   true  -> se desactiva solo (mismo efecto que killswitch off) y avisa
#            de que lo ha hecho, para que tu VPN pueda conectar sin que
#            tengas que intervenir. Vuelve a protegerte tú mismo con
#            'vpn-netguard.sh killswitch auto' en cuanto conecte.
KILLSWITCH_BOOT_RACE_AUTO_DISABLE="false"

# Convivencia con el kill switch de otros clientes VPN (NordVPN, ProtonVPN...).
#   auto   -> (por defecto) VPN NetGuard deja pasar los túneles y las marcas
#             de otros clientes y cede el bloqueo mientras detecte un kill
#             switch ajeno ACTIVO, avisando en el registro y con una
#             notificación. No cede si lo fuerzas con 'vpn-netguard.sh
#             killswitch on' ni con KILLSWITCH_MODE="true".
#   strict -> VPN NetGuard bloquea siempre: no deja pasar nada ajeno ni cede.
COEXIST_MODE="auto"

# Si "true", el tráfico hacia redes locales (LAN) se permite aunque el
# kill switch esté bloqueando el resto del tráfico.
ALLOW_LAN="true"

# Deja estos tres campos vacíos para autodetectar los perfiles de
# NetworkManager. Rellénalos solo si tienes varios perfiles del mismo tipo
# y quieres forzar uno concreto (debe coincidir EXACTAMENTE con el nombre
# que muestra 'nmcli connection show').
ETH_CONNECTION=""
WIFI_CONNECTION=""
VPN_CONNECTION=""

# Orden de prioridad al reconectar (principal primero, respaldo después),
# nombres de perfil separados por espacio y EXACTOS como en 'nmcli connection
# show'. Los perfiles listados aquí se prueban en ese orden; cualquier otro
# perfil VPN conocido no listado se prueba después, en el orden que devuelva
# nmcli (comportamiento anterior). Vacío = sin prioridad explícita, todo
# como antes.
#   VPN_PRIORITY="VPN-Principal VPN-Respaldo"
VPN_PRIORITY=""

# Perfiles VPN de NetworkManager que NetGuard NO debe gestionar: no los
# reconecta ni los desconecta con 'Desactivar'. Pensado para perfiles que crea
# la app de otro proveedor (p. ej. ProtonVPN). Patrones tipo shell separados
# por espacio o coma (* ? [ ]), contra el nombre EXACTO del perfil; un espacio
# dentro del nombre se escribe '?'. Un perfil ignorado que esté conectado sigue
# contando como VPN activa (su túnel pasa), y VPN_CONNECTION, si lo nombras,
# gana sobre este filtro. Máximo 1024 caracteres: si lo supera, se rechaza todo
# el fichero.
#   VPN_IGNORE="pvpn-* ProtonVPN*"
VPN_IGNORE=""

# Solo necesario para VPNs poco habituales (L2TP/IPsec, PPTP...) donde el
# script no puede detectar el endpoint automáticamente.
# Formato: host:puerto:proto   (ej: vpn.miproveedor.com:1194:udp)
VPN_ENDPOINT_OVERRIDE=""

# Cada cuántos segundos se hace una comprobación de respaldo (además de
# reaccionar a los eventos de NetworkManager).
CHECK_INTERVAL=25

# Backoff progresivo de los intentos de reconexión VPN: si el servidor lleva
# caído un rato, espaciar los reintentos evita machacarlo cada CHECK_INTERVAL
# o en cada evento de red. Lista de segundos de espera, creciente, separados
# por espacio; se reinicia al primer valor en cuanto un intento tiene éxito.
# El resto de la reconciliación (killswitch, interfaz física) no se ve
# afectado: solo se espacían los intentos de "nmcli connection up" contra la VPN.
RECONNECT_BACKOFF="5 15 30 60 120"

# Objetivos usados para comprobar que hay Internet real (no solo que la
# interfaz de red esté "up").
PING_TARGETS="1.1.1.1 8.8.8.8"
PING_TIMEOUT=3

# Nivel de detalle en el log: debug | info | warn | error
LOG_LEVEL="info"

# Mientras el kill switch bloquea el resto del tráfico, el DNS (puerto 53)
# solo se permite hacia estos servidores (necesario para poder resolver el
# host de la VPN sin filtrar tus consultas DNS a cualquier resolutor).
# Cambia las IPs por las de tu proveedor de confianza si lo prefieres, o
# déjalo en blanco para permitir DNS hacia cualquier destino (menos privado,
# comportamiento del script original):
#   DNS_SERVERS=""
#
# AVISO (Mint usa systemd-resolved detrás de NetworkManager): esta lista
# solo controla qué IPs de DESTINO puede alcanzar el tráfico DNS saliente;
# no cambia a qué servidor pregunta en realidad el sistema (eso lo decide
# NetworkManager/systemd-resolved, típicamente el DNS del propio router o
# el que te dé la VPN). Si DNS_SERVERS no incluye ese servidor real, el
# killswitch sigue funcionando correctamente (falla cerrado: bloquea esas
# consultas en vez de dejarlas escapar), pero el efecto que verás es que
# la resolución de nombres simplemente deja de funcionar mientras el
# bloqueo esté activo, no que "no hay Internet". Revisa 'vpn-netguard.sh
# status' (muestra el DNS real del sistema junto a este ajuste) y ajusta
# DNS_SERVERS para que coincida, o configura tu VPN/red para usar
# precisamente estos servidores.
#
# AVISO 2 (DNS-over-HTTPS del navegador): esta lista solo controla el DNS
# "de sistema" (puerto 53/853). Firefox trae su propio DoH activado por
# defecto en varias regiones (contra Cloudflare); Chrome/Chromium pueden
# activarlo solos si el resolutor de la red lo anuncia. Ese tráfico va
# dentro de una conexión HTTPS normal al proveedor de DoH, así que ni
# DNS_SERVERS ni el killswitch pueden distinguirlo del resto del tráfico
# HTTPS permitido: el navegador se salta la política sin que este script
# pueda evitarlo por su cuenta. Activa HARDEN_BROWSER_DOH (más abajo, en
# ANONIMATO DE RED) si quieres que Firefox/Chrome/Chromium respeten esta
# lista en vez de resolver por su cuenta.
DNS_SERVERS="1.1.1.1 9.9.9.9"

# Si "true", se muestra una notificación de escritorio (notify-send) cada
# vez que cambia de verdad el estado del kill switch: se activa el bloqueo
# (VPN caída o no conectada), se recupera la VPN y el bloqueo se libera, o
# desactivas la protección. No es un aviso en cada comprobación periódica,
# solo cuando el estado realmente cambia, así que no satura de avisos.
# Requiere notify-send (paquete libnotify-bin, normalmente ya instalado en
# Cinnamon/Mint) y una sesión de escritorio activa; si no están
# disponibles, sencillamente no se muestra nada, sin afectar al resto.
DESKTOP_NOTIFICATIONS="true"

# Para servidores sin sesión de escritorio (donde notify-send no sirve de
# nada): ruta a un comando/script propio que se ejecuta con el mismo
# criterio de "solo cuando cambia de verdad" que la notificación de
# arriba. Recibe dos argumentos: urgencia (low|normal|critical) y mensaje.
# Útil para enganchar un correo, un webhook, etc. Vacío = desactivado.
ALERT_HOOK=""

# Si apuntas esto al directorio "--collector.textfile.directory" de un
# node_exporter que ya corras en este mismo servidor, cada ejecución de
# 'vpn-netguard.sh check' (típicamente por cron) deja ahí un fichero
# vpn_netguard.prom con el resultado (killswitch activo, VPN conectada,
# Internet real, código de estado). Vacío = desactivado. La escritura es
# atómica (fichero temporal + mv), así node_exporter nunca lee un fichero a
# medio escribir.
#   PROMETHEUS_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROMETHEUS_TEXTFILE_DIR=""

# Pequeño historial local de eventos (subida/caída de VPN, activación del
# killswitch...) en $STATE_DIR/history.csv, aparte del journal de systemd:
# una línea CSV por transición real, pensada para importarla en una hoja de
# cálculo o graficar disponibilidad con el tiempo. EVENT_HISTORY_MAX_LINES
# acota su tamaño (se recorta a las líneas más recientes al superarlo).
EVENT_HISTORY_ENABLE="true"
EVENT_HISTORY_MAX_LINES=5000

# =============================================================================
# ANONIMATO DE RED: camufla este equipo frente a la red local en la que
# estés (router, otros dispositivos, administrador de la red). Esto es
# INDEPENDIENTE de la VPN/kill switch de más arriba: la VPN oculta tu
# tráfico frente a Internet, esto oculta tu identidad frente a la propia
# red local (por ejemplo, el WiFi de una cafetería o de un aeropuerto).
# Se aplica escribiendo un "snippet" en NetworkManager, no toca iptables.
# =============================================================================

# Interruptor general del módulo. En "false", se retira cualquier snippet
# de anonimato que hubiera aplicado antes y NetworkManager vuelve a su
# comportamiento de fábrica.
ANONYMIZE_NETWORK="true"

# Política de la MAC "clonada" (la que se muestra al resto de la red) para
# tus conexiones Ethernet y Wi-Fi guardadas, y también para las que crees
# en el futuro (se aplica como valor por defecto global, no hace falta
# tocar cada red una a una):
#   stable -> una MAC aleatoria distinta por cada red, pero SIEMPRE la
#             misma cada vez que te reconectes a esa red concreta. No
#             rompe reservas DHCP fijas ni el "recuerdo" de portales
#             cautivos. Recomendado para el día a día.
#   random -> una MAC aleatoria nueva en CADA conexión, incluso a la misma
#             red. Máxima dificultad de seguimiento entre sesiones, pero
#             puede obligarte a volver a aceptar el portal cautivo de un
#             hotel/aeropuerto o romper una reserva DHCP fija.
#   off    -> no se toca la MAC (se deja la de fábrica del hardware).
MAC_MODE="stable"

# AVANZADO. Solo tiene efecto con MAC_MODE=stable o random. Vacío por
# defecto (comportamiento sin cambios: MAC totalmente aleatoria).
#
# Una MAC "random"/"stable" generada por NetworkManager tiene siempre
# activado el bit "administrado localmente" (2º bit del primer octeto).
# Eso es correcto y necesario, pero tiene un efecto secundario: cualquiera
# que mire esa MAC (el router, un administrador de red, una herramienta
# tipo Wireshark) puede saber AL INSTANTE que es una dirección falsa, sin
# fabricante real asociado. No revela quién eres, pero sí revela "esta
# persona está usando aleatorización de MAC", lo cual en sí mismo puede
# llamar la atención en redes muy vigiladas.
#
# Rellena esta clave para que la parte "de fabricante" (OUI, los 3
# primeros octetos) de la MAC generada se parezca a la de un dispositivo
# real, en vez de a una MAC obviamente aleatoria:
#   - Una sola dirección, p. ej. "FF:FF:FF:00:00:00" -> se aleatorizan
#     los 3 últimos octetos pero se conserva el fabricante de la MAC
#     ACTUAL del propio adaptador (mismo efecto que "macchanger --ending").
#   - Máscara + valor, p. ej. "FF:FF:FF:00:00:00 3C:28:6D:00:00:00" -> se
#     aleatorizan los 3 últimos octetos pero el fabricante que se muestra
#     es el de la dirección indicada (3C:28:6D en este ejemplo), no el de
#     tu adaptador real. Útil si no quieres ni siquiera revelar la marca
#     de tu propio hardware. Busca "IEEE OUI lookup" para encontrar
#     prefijos de fabricantes reales y comunes.
# Formato exacto documentado en nm-settings(5), propiedades
# "wifi.generate-mac-address-mask" / "ethernet.generate-mac-address-mask".
MAC_OUI_MASK=""

# Solo tiene efecto con MAC_MODE=stable. En "true", la MAC "stable" de cada
# red se recalcula en cada arranque del sistema: sigues teniendo la MISMA
# MAC mientras el PC esté encendido (no rompe nada a media sesión), pero un
# observador de la red no puede relacionar tu MAC de hoy con la de otro
# día. Déjalo en "false" si prefieres la MAC más predecible posible por red.
ROTATE_MAC_PER_BOOT="false"

# Igual que ROTATE_MAC_PER_BOOT pero sin esperar a un reinicio: cada N horas
# se genera una MAC "stable" nueva y se reconecta la red activa para que se
# aplique ya. Pensado para equipos que rara vez se apagan (un servidor, un
# portátil que solo se suspende). 0 = desactivado (comportamiento anterior).
# Instala un temporizador systemd ('vpn-netguard-mac-rotate.timer') al
# aplicar el anonimato de red; se retira solo si vuelves a poner 0 aquí.
# La reconexión corta el tráfico un instante: si el kill switch está
# activo, sigue bloqueando durante ese instante (no hay ventana de fuga).
ROTATE_MAC_EVERY_HOURS=0

# Aleatoriza también la MAC que se usa al ESCANEAR redes Wi-Fi, antes de
# conectarte a ninguna. Sin esto, aunque camufles la MAC de conexión,
# cualquiera escuchando el aire ve tu MAC real en cada "probe request"
# mientras el equipo busca redes conocidas. NetworkManager moderno ya lo
# activa por defecto; aquí se fija explícitamente para no depender de eso.
RANDOMIZE_SCAN_MAC="true"

# Si "true", no se envía el nombre real de este equipo (p. ej.
# "juan-portatil") al servidor DHCP del router al pedir IP. Así quien
# administre la red no ve tu nombre de equipo en la lista de clientes
# conectados.
SPOOF_HOSTNAME="true"

# Solo se usa si SPOOF_HOSTNAME="true". Si lo dejas vacío, sencillamente no
# se envía ningún nombre (lo más privado). Algunas redes corporativas con
# 802.1x exigen que el cliente mande *algún* nombre; en ese caso escribe
# aquí un nombre genérico (p. ej. "equipo-invitado") en vez del real.
DHCP_HOSTNAME_OVERRIDE=""

# Si "true", reduce el seguimiento por identificadores DHCP persistentes.
# NetworkManager usa por defecto un DUID-UUID basado en machine-id y un IAID
# derivado del nombre de interfaz. La política generada usa identificadores
# derivados de la MAC cuando el tipo de enlace lo admite; en Wi-Fi DHCPv4 usa
# client-id=none porque client-id=mac solo está soportado para Ethernet.
HARDEN_DHCP_IDENTIFIERS="true"

# Si "true", se usan direcciones IPv6 temporales/aleatorias (RFC 4941) y
# un identificador de interfaz no derivado de la MAC (RFC 7217) en vez del
# clásico EUI-64 (que reconstruye tu MAC a partir de la propia IPv6). Sin
# esto, aunque camufles la MAC en la capa 2, tu dirección IPv6 podría
# seguir delatándote en la capa 3.
IPV6_PRIVACY="true"

# AVANZADO. Si "true", se desactiva IPv6 por completo (a nivel global, para
# todas las conexiones) en vez de solo pedirle direcciones privadas/
# temporales como hace IPV6_PRIVACY arriba. Reduce al mínimo la superficie
# de "huella" en una red no confiable (una sola pila IP en vez de dos, sin
# ningún identificador IPv6 que correlacionar) a costa de perder
# conectividad IPv6 en redes que la requieran. Si "true", tiene prioridad
# sobre IPV6_PRIVACY (no tiene sentido pedir direcciones privadas para una
# pila que está apagada). La mayoría de usuarios puede dejar esto en
# "false" y confiar en IPV6_PRIVACY; actívalo solo si quieres minimizar
# deliberadamente la huella en redes públicas que no conoces.
DISABLE_IPV6="false"

# Si "true", evita que NetworkManager anuncie el nombre de este equipo por
# mDNS (protocolo que usan impresoras, Chromecasts, AirPlay...) en la red
# local. Ojo: si usas impresoras u otros dispositivos por mDNS/Bonjour en
# esa misma red, puede que dejen de encontrar este equipo automáticamente.
DISABLE_MDNS_ANNOUNCE="true"

# DISABLE_MDNS_ANNOUNCE (arriba) solo silencia el mDNS propio de
# NetworkManager. En Linux Mint el anuncio de "nombreequipo.local" al
# resto de la red normalmente lo hace un servicio del sistema aparte,
# "avahi-daemon" (instalado y activo de fábrica en Mint/Ubuntu), que
# seguiría anunciando tu nombre aunque lo de arriba esté en "true". Si
# "true" aquí, se detiene y se enmascara ese servicio (también su socket,
# ya que si solo se detiene el servicio, el socket lo revive solo en
# cuanto algo pide resolución mDNS). Se recuerda si estaba activo antes
# de tocarlo para devolverlo exactamente a ese estado si luego pones esto
# en "false" o desinstalas. Por defecto en "false" (no se toca) porque
# puede hacer que impresoras de red, Chromecasts u otros equipos dejen de
# encontrar este PC automáticamente por Bonjour/mDNS; actívalo solo si no
# usas ese tipo de descubrimiento automático en tu red.
DISABLE_AVAHI_SERVICE="false"

# Igual que DISABLE_AVAHI_SERVICE pero para NetBIOS (el "nmbd" de Samba,
# el otro protocolo clásico de anuncio de nombre de equipo en redes con
# máquinas Windows). No suele venir instalado en un Mint de escritorio
# recién instalado: si no está presente, esta opción simplemente no hace
# nada (no da error). Solo es relevante si en algún momento instalaste
# Samba para compartir carpetas. Por defecto en "false" por la misma
# razón que la anterior: si compartes carpetas con equipos Windows en tu
# LAN doméstica, seguramente SÍ quieras que te encuentren por nombre.
DISABLE_NETBIOS_SERVICE="false"

# Mitigación opcional del AVISO 2 de más arriba (junto a DNS_SERVERS): si
# "true", se instala una política que desactiva el DNS-over-HTTPS propio de
# Firefox y de Chrome/Chromium (uno por navegador, solo si está instalado),
# para que el DNS de esos navegadores vuelva a pasar por el sistema y quede
# sujeto a DNS_SERVERS y al killswitch. Requiere reiniciar el navegador para
# que se note. Por defecto en "false" porque toca ficheros de política de
# terceros y algunos usuarios prefieren el DoH del navegador tal cual.
HARDEN_BROWSER_DOH="false"
EOF
}

# Unidad systemd. ExecStart apunta siempre a la copia instalada en $BIN_DST
# (nunca a la copia de trabajo desde la que se instaló).
#
# Endurecimiento: sin esto, el servicio corre como root sin ningún límite.
# NoNewPrivileges + CapabilityBoundingSet lo reducen a solo las capacidades
# que de verdad usa (NET_ADMIN/NET_RAW para iptables/ip6tables/nmcli/ping;
# SETUID/SETGID porque notify_send() usa runuser para bajar de root a la
# sesión del usuario, ver notify_send). Sigue sin User= propio: el resto de
# subcomandos que sí necesitan root completo (apply-privacy, install...) no
# pasan por esta unidad, pero ProtectSystem=strict + el resto de
# Protect*/Restrict* limitan igualmente lo que ese root "recortado" puede
# tocar. RestrictAddressFamilies solo deja los sockets que de verdad se
# usan: AF_UNIX (D-Bus de nmcli/notify-send/systemd-notify), AF_INET/
# AF_INET6 (ping, iptables) y AF_NETLINK (iptables-nft, wg).
#
# ProtectHome=read-only (no "true"): con "true" /run/user queda inaccesible
# y notify_send ya no podría leer el socket D-Bus de la sesión del usuario
# para avisarle. "read-only" mantiene esa lectura y bloquea igualmente
# cualquier escritura en /home, /root, /run/user. Si tras instalar ves
# errores de permisos inesperados, añade CAP_DAC_OVERRIDE a
# CapabilityBoundingSet con 'systemctl edit vpn-netguard.service'.
#
# ReadWritePaths=... /run, sin estrechar a un RuntimeDirectory= propio:
# $LOCK_FILE (/run/vpn-netguard.lock) lo abren también el menú interactivo
# y los subcomandos sueltos (killswitch off...), que corren fuera de
# este sandbox y no crean esa carpeta por su cuenta. vpn-netguard-boot.service
# no lo usa (boot_killswitch_main no pasa por with_killswitch_lock), así
# que no es el motivo del /run amplio.
#
# Type=notify + WatchdogSec=: daemon_main() avisa a systemd con --ready en
# cuanto termina el arranque, y pinga WATCHDOG=1 solo mientras
# reconcile_locked() siga completando vueltas (ver touch_heartbeat /
# watchdog_ping_if_alive). Si se queda colgada para siempre en una llamada
# de nmcli/iptables, el latido deja de refrescarse y systemd reinicia el
# servicio solo, sin ninguna lógica de timeout propia aquí. TimeoutStartSec
# es generoso porque el primer reconcile_sync() del arranque puede tardar
# si hay varios perfiles guardados e inalcanzables (cada uno hasta
# NMCLI_UP_TIMEOUT); si tienes muchos perfiles y el arranque se corta, sube
# TimeoutStartSec/WatchdogSec en proporción (CHECK_INTERVAL cercano a
# WatchdogSec/2 se avisa solo, en el log).
#
# NotifyAccess=all (no "main"): sd_notify() llama al binario externo
# "systemd-notify", que se ejecuta como un proceso HIJO con su propio PID,
# distinto del PID principal que systemd vigila. Con "main" systemd
# descarta el aviso ("Got notification message from PID ..., but reception
# only permitted for main PID ...") y espera TimeoutStartSec entero antes
# de dar el arranque por fallido, aunque el servicio esté funcionando bien.
write_service_unit() {
    cat <<EOF
[Unit]
Description=$(ui_t systemd.service_description)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=notify
NotifyAccess=all
ExecStart=$BIN_DST start
Restart=always
RestartSec=3
TimeoutStartSec=180
WatchdogSec=300
# Deliberadamente sin ExecStop=: el kill switch debe seguir bloqueando el
# tráfico aunque el servicio se detenga (fail-closed). Para quitarlo a
# propósito: vpn-netguard.sh deactivate (o killswitch off).

# --- Endurecimiento (ver comentario junto a write_service_unit en el .sh) ---
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SETUID CAP_SETGID
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$STATE_DIR /run
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
LockPersonality=true
MemoryDenyWriteExecute=true
RemoveIPC=true
PrivateTmp=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
}

# Segunda unidad systemd, muy pequeña: cierra la ventana entre que arranca
# la red y que "vpn-netguard.service" llega a ejecutarse. Es el gancho
# estándar de systemd para cortafuegos que deben aplicarse antes de que se
# configure cualquier red (documentado en systemd.special(7): DefaultDependencies=no
# + Before=network-pre.target + Wants=network-pre.target es el patrón que
# recomienda la propia documentación de systemd para este caso exacto).
# Solo llama a este mismo script con el subcomando "boot-killswitch"; toda
# la lógica de bloqueo sigue viviendo en apply_killswitch_rules, no se
# duplica nada.
#
# Además de local-fs.target, se exige/ordena tras sysinit.target.
# DefaultDependencies=no saca a esta unidad de la ordenación automática que
# normalmente ata todo a sysinit.target; sin recuperarla explícitamente, este
# oneshot podría ejecutarse en paralelo con udev, la carga de módulos del
# kernel o el desbloqueo de OTROS volúmenes LUKS no-root vía /etc/crypttab
# (que systemd resuelve como parte de sysinit.target, antes de mostrar su
# propio prompt de contraseña). Exigir sysinit.target primero no retrasa la
# protección de forma perceptible (sigue siendo el primer hueco tras el
# sistema base, bastante antes de red) y elimina esa competencia. Si alguna
# vez sospechas de esta unidad en un arranque problemático, se puede
# desactivar sola sin afectar al servicio principal:
#   sudo systemctl disable --now vpn-netguard-boot.service
write_boot_service_unit() {
    cat <<EOF
[Unit]
Description=$(ui_t systemd.boot_description)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
# Garantiza sistema base (udev, módulos, cryptsetup de /etc/crypttab...) y
# /etc + /var montados (config y fichero de estado) antes de leerlos.
Requires=sysinit.target local-fs.target
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=$BIN_DST boot-killswitch
RemainAfterExit=yes
TimeoutStartSec=15

[Install]
WantedBy=multi-user.target
EOF
}

# Tercera y cuarta unidad systemd, opcionales: solo se instalan si
# ROTATE_MAC_EVERY_HOURS > 0 (ver sync_mac_rotate_timer). El oneshot llama
# a este mismo script con "rotate-mac"; el timer lo dispara cada N horas.
write_mac_rotate_service_unit() {
    cat <<EOF
[Unit]
Description=$(ui_t systemd.mac_service_description)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=$BIN_DST rotate-mac
EOF
}

write_mac_rotate_timer_unit() {
    cat <<EOF
[Unit]
Description=$(ui_t systemd.mac_timer_description "$ROTATE_MAC_EVERY_HOURS")

[Timer]
OnActiveSec=${ROTATE_MAC_EVERY_HOURS}h
OnUnitActiveSec=${ROTATE_MAC_EVERY_HOURS}h
# Si el equipo estaba apagado/suspendido cuando tocaba rotar, lo hace en
# cuanto vuelve a arrancar en vez de esperar el intervalo completo.
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Lanzador de escritorio / menú de Aplicaciones. Ejecuta «launch» de este mismo fichero (no un
# script aparte): abre la interfaz de arranque elegida, el panel o el menú de texto en una
# ventana de terminal, así que sigue los cambios entre una y otra sin tocar el lanzador.
write_desktop_file() {
    cat <<EOF
[Desktop Entry]
Type=Application
Name=VPN NetGuard
GenericName=$(ui_t desktop.generic_name)
Comment=$(ui_t desktop.comment)
Exec=$BIN_DST launch
Icon=$ICON_DST
Terminal=false
Categories=Network;System;Security;
StartupNotify=false
EOF
}

# Icono propio (escudo + candado + señal), SVG escalable; ruta fija en vez de
# instalarlo en el tema hicolor para no depender de refrescar la caché de iconos.
write_icon_file() {
    cat <<'EOF'
<svg viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="shieldGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#1E3A5F"/>
      <stop offset="100%" stop-color="#0E7C86"/>
    </linearGradient>
  </defs>
  <path d="M128,7.2 C91.6,7.2 46.8,19.7 10.4,45.9 L10.4,139.4 C10.4,198.7 60.8,237.4 128,248.8 C195.2,237.4 245.6,198.7 245.6,139.4 L245.6,45.9 C209.2,19.7 164.4,7.2 128,7.2 Z"
        fill="url(#shieldGrad)" stroke="#09202E" stroke-width="4"/>
  <path d="M128,20.8 C97.2,20.8 58,32.2 27.2,55 L27.2,137.1 C27.2,187.3 69.2,219.2 128,232.9"
        fill="none" stroke="#ffffff" stroke-opacity="0.18" stroke-width="5" stroke-linecap="round"/>
  <ellipse cx="128" cy="89.2" rx="11.2" ry="9.1" fill="#EAF6F6"/>
  <path d="M94.4,89.2 A33.6,27.4 0 0 1 161.6,89.2" fill="none" stroke="#EAF6F6" stroke-width="9" stroke-linecap="round"/>
  <path d="M94.4,150.8 V125.7 A33.6,27.4 0 0 1 161.6,125.7 V150.8" fill="none" stroke="#EAF6F6" stroke-width="13" stroke-linecap="round"/>
  <rect x="74.8" y="144" width="106.4" height="68.4" rx="17.8" fill="#EAF6F6"/>
  <ellipse cx="128" cy="178.2" rx="15.4" ry="12.5" fill="#0E7C86"/>
</svg>
EOF
}

# Reescribe solo los artefactos ya instalados cuando cambia el idioma.
# No crea unidades opcionales que no existían y no toca el estado de los servicios.
sync_localized_installed_files() {
    require_root
    local tmp
    if [[ -f "$UNIT_DST" ]]; then
        tmp="$(mktemp)" || return 1
        write_service_unit > "$tmp" || { rm -f "$tmp"; return 1; }
        install -o root -g root -m 644 "$tmp" "$UNIT_DST" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    if [[ -f "$BOOT_UNIT_DST" ]]; then
        tmp="$(mktemp)" || return 1
        write_boot_service_unit > "$tmp" || { rm -f "$tmp"; return 1; }
        install -o root -g root -m 644 "$tmp" "$BOOT_UNIT_DST" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    if [[ -f "$MAC_ROTATE_UNIT_DST" ]]; then
        tmp="$(mktemp)" || return 1
        write_mac_rotate_service_unit > "$tmp" || { rm -f "$tmp"; return 1; }
        install -o root -g root -m 644 "$tmp" "$MAC_ROTATE_UNIT_DST" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    if [[ -f "$MAC_ROTATE_TIMER_DST" ]]; then
        tmp="$(mktemp)" || return 1
        write_mac_rotate_timer_unit > "$tmp" || { rm -f "$tmp"; return 1; }
        install -o root -g root -m 644 "$tmp" "$MAC_ROTATE_TIMER_DST" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    if [[ -f "$DESKTOP_DST" ]]; then
        tmp="$(mktemp)" || return 1
        write_desktop_file > "$tmp" || { rm -f "$tmp"; return 1; }
        install -o root -g root -m 644 "$tmp" "$DESKTOP_DST" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 1
}

# =============================================================================
# CONFIGURACIÓN EN TIEMPO DE EJECUCIÓN (carga $CONFIG_FILE si existe)
# =============================================================================
# Interfaz bilingüe. Los comentarios y nombres técnicos del código se mantienen en español.

# Detección real del idioma por el locale del sistema. Antes solo se miraba
# $LANGUAGE (variable de gettext que casi nadie exporta a mano), así que en
# la práctica siempre caía en español aunque el escritorio estuviera en
# inglés. Prioridad: variables de la sesión actual (LC_ALL > LC_MESSAGES >
# LANG > LANGUAGE) y, si ninguna está definida (root sin sesión, cron,
# servicio), el idioma configurado a nivel de sistema en /etc/default/locale.
detect_system_language() {
    local var val
    for var in LC_ALL LC_MESSAGES LANG LANGUAGE; do
        val="${!var:-}"
        [[ -z "$val" || "$val" == C || "$val" == POSIX ]] && continue
        case "${val,,}" in
            en|en_*|english) echo en; return ;;
            es|es_*|spanish) echo es; return ;;
        esac
    done
    if [[ -r /etc/default/locale ]]; then
        val="$(grep -m1 '^LANG=' /etc/default/locale 2>/dev/null | cut -d= -f2 | tr -d '"')"
        case "${val,,}" in
            en_*) echo en; return ;;
            es_*) echo es; return ;;
        esac
    fi
    echo es
}

UI_LANGUAGE="${VPN_NETGUARD_LANGUAGE:-$(detect_system_language)}"

ui_init() {
    case "${UI_LANGUAGE,,}" in
        en|en_*|english) UI_LANGUAGE="en" ;;
        es|es_*|spanish) UI_LANGUAGE="es" ;;
        *) UI_LANGUAGE="es" ;;
    esac
}

log_t() {
    local level="$1" key="$2"
    shift 2
    log "$level" "$(ui_t "$key" "$@")"
}

ui_t() {
    local key="$1"; shift
    local text
    case "$UI_LANGUAGE:$key" in
        es:none) text='ninguno' ;;
        en:none) text='none' ;;
        es:unknown) text='desconocido' ;;
        en:unknown) text='unknown' ;;
        es:active) text='activo' ;;
        en:active) text='active' ;;
        es:inactive) text='inactivo' ;;
        en:inactive) text='inactive' ;;
        es:yes) text='sí' ;;
        en:yes) text='yes' ;;
        es:no) text='no' ;;
        en:no) text='no' ;;
        es:invalid_option) text='Opción no válida.' ;;
        en:invalid_option) text='Invalid option.' ;;
        es:press_enter) text='Pulsa Intro para continuar...' ;;
        en:press_enter) text='Press Enter to continue...' ;;
        es:choose_option) text='Elige una opción: ' ;;
        en:choose_option) text='Choose an option: ' ;;
        es:cancelled) text='Cancelado.' ;;
        en:cancelled) text='Cancelled.' ;;
        es:action_ok) text='(hecho)' ;;
        en:action_ok) text='(done)' ;;
        es:action_failed) text='(la acción terminó con código %s; revisa los mensajes de arriba)' ;;
        en:action_failed) text='(action finished with code %s; review the messages above)' ;;
        es:root_required) text='Este script debe ejecutarse como root (usa sudo, pkexec o el servicio systemd).' ;;
        en:root_required) text='This script must run as root (use sudo, pkexec, or the systemd service).' ;;
        es:missing_dependency) text='Falta el comando requerido: %s' ;;
        en:missing_dependency) text='Required command is missing: %s' ;;
        es:install_dependency) text='Instálalo con: sudo apt install %s' ;;
        en:install_dependency) text='Install it with: sudo apt install %s' ;;
        es:nm_inactive_1) text='Aviso: NetworkManager no está activo. VPN NetGuard depende de él (nmcli)' ;;
        en:nm_inactive_1) text='Warning: NetworkManager is not active. VPN NetGuard depends on it (nmcli)' ;;
        es:nm_inactive_2) text='Es necesario para detectar perfiles, conectar/reconectar y aplicar el anonimato de red.' ;;
        en:nm_inactive_2) text='It is required for profile detection, connection/reconnection, and network privacy.' ;;
        es:nm_inactive_3) text="Si este servidor usa netplan con el renderer 'networkd', instala y" ;;
        en:nm_inactive_3) text="If this server uses netplan with the 'networkd' renderer, install and" ;;
        es:nm_inactive_4) text='activa NetworkManager (o cambia el renderer a NetworkManager):' ;;
        en:nm_inactive_4) text='enable NetworkManager (or switch the renderer to NetworkManager):' ;;
        es:nm_inactive_cmd) text='  sudo apt install network-manager && sudo systemctl enable --now NetworkManager' ;;
        en:nm_inactive_cmd) text='  sudo apt install network-manager && sudo systemctl enable --now NetworkManager' ;;
        es:ufw_warning_1) text='Aviso: ufw está activo en este equipo. VPN NetGuard añade su propia' ;;
        en:ufw_warning_1) text='Warning: ufw is active on this system. VPN NetGuard adds its own' ;;
        es:ufw_warning_2) text='cadena de iptables enganchada a OUTPUT, independiente de las reglas' ;;
        en:ufw_warning_2) text='iptables chain attached to OUTPUT, independent of ufw rules;' ;;
        es:ufw_warning_3) text="de ufw; ambos pueden convivir, pero revisa 'sudo ufw status verbose'" ;;
        en:ufw_warning_3) text="both can coexist, but check 'sudo ufw status verbose'" ;;
        es:ufw_warning_4) text='si algo no se comporta como esperas.' ;;
        en:ufw_warning_4) text='if anything behaves unexpectedly.' ;;

        es:status.title) text='Estado actual' ;;
        en:status.title) text='Current status' ;;
        es:status.section_network) text='Red' ;;
        en:status.section_network) text='Network' ;;
        es:status.section_killswitch) text='Kill switch' ;;
        en:status.section_killswitch) text='Kill switch' ;;
        es:status.section_coexist) text='Convivencia con otros VPN' ;;
        en:status.section_coexist) text='Coexistence with other VPNs' ;;
        es:status.section_connectivity) text='Conectividad' ;;
        en:status.section_connectivity) text='Connectivity' ;;
        es:status.section_alerts) text='Alertas y monitorización' ;;
        en:status.section_alerts) text='Alerts and monitoring' ;;
        es:status.l_eth) text='Ethernet activa' ;;
        en:status.l_eth) text='Active Ethernet' ;;
        es:status.l_wifi) text='Wi-Fi activa' ;;
        en:status.l_wifi) text='Active Wi-Fi' ;;
        es:status.l_vpn) text='VPN activa' ;;
        en:status.l_vpn) text='Active VPN' ;;
        es:status.l_phys) text='Interfaz física' ;;
        en:status.l_phys) text='Physical interface' ;;
        es:status.l_tun) text='Interfaz VPN' ;;
        en:status.l_tun) text='VPN interface' ;;
        es:status.l_eth_profiles) text='Perfiles Ethernet' ;;
        en:status.l_eth_profiles) text='Ethernet profiles' ;;
        es:status.l_wifi_profiles) text='Perfiles Wi-Fi' ;;
        en:status.l_wifi_profiles) text='Wi-Fi profiles' ;;
        es:status.l_vpn_profiles) text='Perfiles VPN' ;;
        en:status.l_vpn_profiles) text='VPN profiles' ;;
        es:status.l_vpn_ignored) text='VPN ignoradas' ;;
        en:status.l_vpn_ignored) text='Ignored VPN profiles' ;;
        es:status.l_ks_mode) text='Modo configurado' ;;
        en:status.l_ks_mode) text='Configured mode' ;;
        es:status.l_ks_forced) text='Forzado' ;;
        en:status.l_ks_forced) text='Forced' ;;
        es:status.l_ks_policy) text='Política efectiva' ;;
        en:status.l_ks_policy) text='Effective policy' ;;
        es:status.l_ks_yield) text='Cesión del bloqueo' ;;
        en:status.l_ks_yield) text='Yielding' ;;
        es:status.l_boot) text='Bloqueo en arranque' ;;
        en:status.l_boot) text='Boot-time block' ;;
        es:status.l_rules4) text='Reglas IPv4' ;;
        en:status.l_rules4) text='IPv4 rules' ;;
        es:status.l_rules6) text='Reglas IPv6' ;;
        en:status.l_rules6) text='IPv6 rules' ;;
        es:status.v_ks_forced_auto) text='no (manda el modo configurado)' ;;
        en:status.v_ks_forced_auto) text='no (the configured mode applies)' ;;
        es:status.v_ks_forced_on) text='ACTIVADO (bloquea siempre)' ;;
        en:status.v_ks_forced_on) text='ON (always blocks)' ;;
        es:status.v_ks_forced_off) text='DESACTIVADO (nunca bloquea)' ;;
        en:status.v_ks_forced_off) text='OFF (never blocks)' ;;
        es:status.v_ks_policy_on) text='bloquear el tráfico fuera del túnel' ;;
        en:status.v_ks_policy_on) text='block traffic outside the tunnel' ;;
        es:status.v_ks_policy_off) text='sin bloqueo' ;;
        en:status.v_ks_policy_off) text='no blocking' ;;
        es:status.v_ks_yielding) text='sí, a %s (kill switch ajeno activo)' ;;
        en:status.v_ks_yielding) text='yes, to %s (other kill switch active)' ;;
        es:status.v_boot_on) text='activado (antes de configurar la red)' ;;
        en:status.v_boot_on) text='enabled (before network configuration)' ;;
        es:status.v_boot_off) text='desactivado (sin bloqueo al arrancar)' ;;
        en:status.v_boot_off) text='disabled (no blocking at boot)' ;;
        es:status.v_rules_on) text='activas' ;;
        en:status.v_rules_on) text='active' ;;
        es:status.v_rules_off) text='inactivas' ;;
        en:status.v_rules_off) text='inactive' ;;
        es:status.v_rules6_missing) text='ip6tables no disponible' ;;
        en:status.v_rules6_missing) text='ip6tables unavailable' ;;
        es:status.l_coexist_mode) text='Modo de convivencia' ;;
        en:status.l_coexist_mode) text='Coexistence mode' ;;
        es:status.l_coexist_tunnels) text='Túneles ajenos' ;;
        en:status.l_coexist_tunnels) text='Other tunnels' ;;
        es:status.l_coexist_marks) text='Marcas ajenas' ;;
        en:status.l_coexist_marks) text='Other fwmarks' ;;
        es:status.l_coexist_ks) text='Kill switch ajeno' ;;
        en:status.l_coexist_ks) text='Other kill switch' ;;
        es:status.l_internet) text='Internet real' ;;
        en:status.l_internet) text='Real Internet' ;;
        es:status.v_internet_ok) text='OK' ;;
        en:status.v_internet_ok) text='OK' ;;
        es:status.v_internet_no) text='SIN RESPUESTA' ;;
        en:status.v_internet_no) text='NO RESPONSE' ;;
        es:status.l_dns) text='DNS del kill switch' ;;
        en:status.l_dns) text='Kill switch DNS' ;;
        es:status.v_dns_any) text='cualquiera en IPv4; ninguno en IPv6' ;;
        en:status.v_dns_any) text='any on IPv4; none on IPv6' ;;
        es:status.l_system_dns) text='DNS real del sistema' ;;
        en:status.l_system_dns) text='System DNS now' ;;
        es:status.l_wg) text='Handshake WireGuard' ;;
        en:status.l_wg) text='WireGuard handshake' ;;
        es:status.v_wg_missing) text='wg no instalado (paquete wireguard-tools); solo se usa el ping' ;;
        en:status.v_wg_missing) text='wg not installed (wireguard-tools); ping only is used' ;;
        es:status.v_wg_recent) text='reciente (túnel vivo)' ;;
        en:status.v_wg_recent) text='recent (tunnel alive)' ;;
        es:status.v_wg_dead) text='SIN RESPUESTA (> %ss; túnel zombie)' ;;
        en:status.v_wg_dead) text='NO RESPONSE (> %ss; tunnel appears to be a zombie)' ;;
        es:status.l_alerts) text='Canal de alertas' ;;
        en:status.l_alerts) text='Alert channel' ;;
        es:status.l_history) text='Historial de eventos' ;;
        en:status.l_history) text='Event history' ;;
        es:status.v_history_on) text='%s (%s eventos registrados)' ;;
        en:status.v_history_on) text='%s (%s events recorded)' ;;
        es:status.v_history_off) text='desactivado (EVENT_HISTORY_ENABLE=false)' ;;
        en:status.v_history_off) text='disabled (EVENT_HISTORY_ENABLE=false)' ;;
        es:status.l_prom) text='Métricas Prometheus' ;;
        en:status.l_prom) text='Prometheus metrics' ;;
        es:status.v_prom) text="%s/vpn_netguard.prom (se actualiza en cada 'check')" ;;
        en:status.v_prom) text="%s/vpn_netguard.prom (updated on each 'check')" ;;
        es:status.doh_warn) text="El DNS-over-HTTPS propio del navegador puede saltarse este filtro (ver HARDEN_BROWSER_DOH / 'vpn-netguard.sh apply-privacy')" ;;
        en:status.doh_warn) text="The browser's built-in DNS-over-HTTPS may bypass this filter (see HARDEN_BROWSER_DOH / 'vpn-netguard.sh apply-privacy')" ;;
        es:status.coexist_none) text='No se detecta otro cliente VPN ni kill switch ajeno.' ;;
        en:status.coexist_none) text='No other VPN client or kill switch detected.' ;;
        es:status.coexist_noroot) text='Sin root no se lee el cortafuegos de NordVPN: su kill switch podría no detectarse.' ;;
        en:status.coexist_noroot) text='Without root the NordVPN firewall cannot be read: its kill switch may go undetected.' ;;
        es:status.coexist_yielding) text='NetGuard cede el bloqueo a %s mientras siga activo.' ;;
        en:status.coexist_yielding) text='NetGuard yields blocking to %s while it stays active.' ;;
        es:status.coexist_rec_strict) text='Recomendado: COEXIST_MODE="auto". Con "strict" NetGuard bloquea el tráfico de %s; si su kill switch está activo, los dos pueden cortarse mutuamente.' ;;
        en:status.coexist_rec_strict) text='Recommended: COEXIST_MODE="auto". With "strict" NetGuard blocks the traffic of %s; if its kill switch is active, the two can cut each other off.' ;;
        es:status.coexist_rec_forced) text='Recomendado: %s. NetGuard bloquea aunque %s esté activo; dos kill switch con bloqueo final pueden cortarse mutuamente.' ;;
        en:status.coexist_rec_forced) text='Recommended: %s. NetGuard blocks even though %s is active; two kill switches that drop at the end can cut each other off.' ;;
        es:status.coexist_proton_stuck) text='El kill switch de ProtonVPN está activo sin túnel y puede estar cortando la red. Si no es intencionado: nmcli connection down pvpn-killswitch' ;;
        en:status.coexist_proton_stuck) text="ProtonVPN's kill switch is active without a tunnel and may be cutting the network. If unintended: nmcli connection down pvpn-killswitch" ;;
        es:status.ks_mismatch) text='Las reglas no coinciden con la política efectiva; el servicio las corrige en su próximo ciclo (comprueba que esté activo).' ;;
        en:status.ks_mismatch) text='The rules do not match the effective policy; the service fixes them on its next cycle (check that it is running).' ;;
        es:status.ks_autodisabled) text='AVISO: autodesactivado el %s por choque con el arranque (sin VPN); vuelve a automático con "killswitch auto" en cuanto tu VPN esté conectada.' ;;
        en:status.ks_autodisabled) text='WARNING: auto-disabled on %s due to a boot race (no VPN); return it to automatic with "killswitch auto" once your VPN is connected.' ;;

        es:privacy.status_title) text='Anonimato de red' ;;
        en:privacy.status_title) text='Network privacy' ;;
        es:privacy.l_module) text='Módulo de anonimato' ;;
        en:privacy.l_module) text='Privacy module' ;;
        es:privacy.v_enabled) text='activado (política de MAC: %s)' ;;
        en:privacy.v_enabled) text='enabled (MAC policy: %s)' ;;
        es:privacy.v_disabled) text='desactivado' ;;
        en:privacy.v_disabled) text='disabled' ;;
        es:privacy.l_snippet) text='Aplicado al sistema' ;;
        en:privacy.l_snippet) text='Applied to system' ;;
        es:privacy.v_snippet_yes) text='sí (%s)' ;;
        en:privacy.v_snippet_yes) text='yes (%s)' ;;
        es:privacy.v_snippet_no) text='NO (se crea al aplicar los ajustes)' ;;
        en:privacy.v_snippet_no) text='NO (created when the settings are applied)' ;;
        es:privacy.l_boot) text='Rotar MAC al inicio' ;;
        en:privacy.l_boot) text='Rotate MAC at boot' ;;
        es:privacy.l_timer) text='Rotación periódica' ;;
        en:privacy.l_timer) text='Periodic rotation' ;;
        es:privacy.v_timer) text='cada %s h (%s)' ;;
        en:privacy.v_timer) text='every %s h (%s)' ;;
        es:privacy.v_timer_off) text='desactivada' ;;
        en:privacy.v_timer_off) text='disabled' ;;
        es:privacy.l_scan) text='Escaneo anónimo' ;;
        en:privacy.l_scan) text='Anonymous scan' ;;
        es:privacy.l_hostname) text='Ocultar nombre DHCP' ;;
        en:privacy.l_hostname) text='Hide name from DHCP' ;;
        es:privacy.l_ipv6) text='IPv6 temporal' ;;
        en:privacy.l_ipv6) text='Temporary IPv6' ;;
        es:privacy.l_ipv6_off) text='IPv6 desactivado' ;;
        en:privacy.l_ipv6_off) text='IPv6 disabled' ;;
        es:privacy.l_mdns) text='Ocultar nombre mDNS' ;;
        en:privacy.l_mdns) text='Hide name (mDNS)' ;;
        es:privacy.l_doh) text='Bloqueo de DoH' ;;
        en:privacy.l_doh) text='DoH blocking' ;;
        es:privacy.l_active_net) text='Red activa' ;;
        en:privacy.l_active_net) text='Active network' ;;
        es:privacy.v_no_net) text='ninguna' ;;
        en:privacy.v_no_net) text='none' ;;
        es:privacy.l_cur_mac) text='MAC en uso' ;;
        en:privacy.l_cur_mac) text='Current MAC' ;;
        es:privacy.l_prof_mac) text='MAC del perfil' ;;
        en:privacy.l_prof_mac) text='Profile MAC policy' ;;
        es:privacy.l_prof_ipv6) text='IPv6 del perfil' ;;
        en:privacy.l_prof_ipv6) text='Profile IPv6 privacy' ;;
        es:privacy.l_prof_host) text='Nombre DHCP (perfil)' ;;
        en:privacy.l_prof_host) text='DHCP name (profile)' ;;

        es:doctor.header) text='== VPN NetGuard: diagnóstico ==' ;;
        en:doctor.header) text='== VPN NetGuard: diagnostics ==' ;;
        es:doctor.deps) text='-- Dependencias --' ;;
        en:doctor.deps) text='-- Dependencies --' ;;
        es:doctor.deps_ok) text='OK: todas las dependencias necesarias están instaladas.' ;;
        en:doctor.deps_ok) text='OK: all required dependencies are installed.' ;;
        es:doctor.nm) text='-- NetworkManager --' ;;
        en:doctor.nm) text='-- NetworkManager --' ;;
        es:doctor.nm_ok) text='OK: NetworkManager está activo.' ;;
        en:doctor.nm_ok) text='OK: NetworkManager is active.' ;;
        es:doctor.fw) text='-- Firewall (ufw) --' ;;
        en:doctor.fw) text='-- Firewall (ufw) --' ;;
        es:doctor.fw_ok) text='OK: sin conflicto de firewall detectado.' ;;
        en:doctor.fw_ok) text='OK: no firewall conflict detected.' ;;
        es:doctor.ks) text='-- Kill switch / VPN --' ;;
        en:doctor.ks) text='-- Kill switch / VPN --' ;;
        es:doctor.ks_boot_race_warn) text='El kill switch bloqueará desde el arranque: hasta reconocer la VPN, todo el tráfico queda cortado desde el primer segundo. Si tu cliente VPN tiene su propio kill switch, puede quedarse sin poder conectar. Rellena VPN_ENDPOINT_OVERRIDE, desactiva el kill switch del cliente VPN, o activa KILLSWITCH_BOOT_RACE_AUTO_DISABLE para que VPN NetGuard se desactive solo si esto pasa.' ;;
        en:doctor.ks_boot_race_warn) text="The kill switch will block from boot: until the VPN is recognized, all traffic is cut from the first second. If your VPN client has its own kill switch, it may be unable to connect. Set VPN_ENDPOINT_OVERRIDE, disable the VPN client's own kill switch, or enable KILLSWITCH_BOOT_RACE_AUTO_DISABLE so VPN NetGuard disables itself automatically if this happens." ;;
        es:doctor.ks_boot_race_warn_autodisable) text='El kill switch bloqueará desde el arranque hasta reconocer la VPN; si tu cliente VPN tiene su propio kill switch, puede tardar en conectar. Como tienes KILLSWITCH_BOOT_RACE_AUTO_DISABLE activado, si esto se alarga VPN NetGuard se desactivará solo y te avisará; vuelve a automático después con "vpn-netguard.sh killswitch auto".' ;;
        en:doctor.ks_boot_race_warn_autodisable) text='The kill switch will block from boot until the VPN is recognized; if your VPN client has its own kill switch, it may take a while to connect. Since you have KILLSWITCH_BOOT_RACE_AUTO_DISABLE enabled, if this drags on VPN NetGuard will disable itself and notify you; return to automatic afterward with "vpn-netguard.sh killswitch auto".' ;;
        es:doctor.coexist) text='-- Convivencia con otros VPN --' ;;
        en:doctor.coexist) text='-- Coexistence with other VPNs --' ;;
        es:doctor.root_skip) text='Omitido (hace falta root para ser fiable): sudo %s doctor' ;;
        en:doctor.root_skip) text='Skipped (root is required for a reliable result): sudo %s doctor' ;;
        es:doctor.not_installed) text='VPN NetGuard no está instalado todavía (%s install).' ;;
        en:doctor.not_installed) text='VPN NetGuard is not installed yet (%s install).' ;;
        es:doctor.summary_ok) text='Resumen: todo correcto.' ;;
        en:doctor.summary_ok) text='Summary: everything is OK.' ;;
        es:doctor.summary_warn) text='Resumen: revisa los avisos de arriba.' ;;
        en:doctor.summary_warn) text='Summary: review the warnings above.' ;;
        es:doctor.summary_crit) text='Resumen: problema crítico, revisa arriba.' ;;
        en:doctor.summary_crit) text='Summary: critical problem, review the output above.' ;;

        es:menu.title) text='VPN NetGuard — menú interactivo   (Programador: Filonux)' ;;
        en:menu.title) text='VPN NetGuard — interactive menu   (Developer: Filonux)' ;;
        es:menu.installed_yes) text=' Instalado          : sí (%s)' ;;
        en:menu.installed_yes) text=' Installed          : yes (%s)' ;;
        es:menu.installed_no) text=' Instalado          : no (opción %s para integrarlo con systemd)' ;;
        en:menu.installed_no) text=' Installed          : no (option %s integrates it with systemd)' ;;
        es:menu.autostart_yes) text=' Arranque automático: sí' ;;
        en:menu.autostart_yes) text=' Autostart          : yes' ;;
        es:menu.autostart_no) text=' Arranque automático: no' ;;
        en:menu.autostart_no) text=' Autostart          : no' ;;
        es:menu.note_privileged) text=' Nota: las acciones que cambian el sistema pedirán la contraseña de administrador.' ;;
        en:menu.note_privileged) text=' Note: actions that change the system will ask for administrator privileges.' ;;
        es:menu.history_missing) text='(todavía no hay historial registrado)' ;;
        en:menu.history_missing) text='(no history has been recorded yet)' ;;
        es:menu.backup_title) text='-- Copia de seguridad de la configuración --' ;;
        en:menu.backup_title) text='-- Configuration backup --' ;;
        es:menu.backup_export) text=' 1) Exportar configuración actual a un fichero' ;;
        en:menu.backup_export) text=' 1) Export current configuration to a file' ;;
        es:menu.backup_import) text=' 2) Importar configuración desde un fichero' ;;
        en:menu.backup_import) text=' 2) Import configuration from a file' ;;
        es:menu.back) text=' 0) Volver' ;;
        en:menu.back) text=' 0) Back' ;;
        es:menu.exit) text='Hasta luego.' ;;
        en:menu.exit) text='Goodbye.' ;;
        es:menu.select_action) text='Elige una acción: ' ;;
        en:menu.select_action) text='Choose an action: ' ;;
        es:menu.save) text='  g) Guardar cambios' ;;
        en:menu.save) text='  g) Save changes' ;;
        es:menu.back_nosave) text='  0) Volver sin guardar' ;;
        en:menu.back_nosave) text='  0) Back without saving' ;;
        es:menu.no_changes) text='No hay cambios pendientes.' ;;
        en:menu.no_changes) text='No pending changes.' ;;
        es:menu.unsaved_confirm) text='Hay cambios sin guardar. ¿Salir sin guardarlos?' ;;
        en:menu.unsaved_confirm) text='There are unsaved changes. Exit without saving them?' ;;
        es:menu.edit_hint) text="Edita un campo por número. Los cambios se guardan todos juntos con 'g'." ;;
        en:menu.edit_hint) text="Edit a field by number. Changes are saved together with 'g'." ;;
        es:menu.actual) text='actual: %s' ;;
        en:menu.actual) text='current: %s' ;;
        es:menu.empty) text='<vacío>' ;;
        en:menu.empty) text='<empty>' ;;
        es:menu.prompt_keep) text=' (actual: %s; Enter = no cambiar): ' ;;
        en:menu.prompt_keep) text=' (current: %s; Enter = keep): ' ;;
        es:menu.prompt_clear) text=" (actual: %s; Enter = no cambiar, '-' = vaciar): " ;;
        en:menu.prompt_clear) text=" (current: %s; Enter = keep, '-' = clear): " ;;
        es:menu.choose_keep) text='Elige una opción (Enter = no cambiar): ' ;;
        en:menu.choose_keep) text='Choose an option (Enter = keep): ' ;;
        es:menu.invalid_keep) text='Opción no válida; se mantiene el valor actual.' ;;
        en:menu.invalid_keep) text='Invalid option; keeping the current value.' ;;
        es:menu.int_gt0) text='Debe ser un número entero mayor que 0.' ;;
        en:menu.int_gt0) text='Must be an integer greater than 0.' ;;
        es:menu.int_ge0) text='Debe ser un número entero de 0 o más.' ;;
        en:menu.int_ge0) text='Must be an integer greater than or equal to 0.' ;;
        es:menu.invalid_format) text='Formato no válido.' ;;
        en:menu.invalid_format) text='Invalid format.' ;;
        es:menu.save_changes) text='Guardando cambios en %s (puede pedir la contraseña de administrador)...' ;;
        en:menu.save_changes) text='Saving changes to %s (administrator privileges may be requested)...' ;;
        es:menu.saved) text='Cambios guardados.' ;;
        en:menu.saved) text='Changes saved.' ;;
        es:menu.applied) text='Aplicado.' ;;
        en:menu.applied) text='Applied.' ;;
        es:menu.saved_auto) text='El servicio detecta el cambio y lo aplica solo en unos segundos; no hace falta reiniciarlo.' ;;
        en:menu.saved_auto) text='The service detects the change and applies it by itself within a few seconds; no restart needed.' ;;
        es:menu.apply_now) text='¿Aplicar los cambios ahora?' ;;
        en:menu.apply_now) text='Apply the changes now?' ;;
        es:menu.wait_hint) text='Puede tardar unos segundos si la VPN no responde de inmediato; no cierres esta ventana.' ;;
        en:menu.wait_hint) text='This may take a few seconds if the VPN does not respond right away; do not close this window.' ;;
        es:menu.save_failed) text='No se pudieron guardar los cambios; se mantienen en el editor para reintentar.' ;;
        en:menu.save_failed) text='Could not save the changes; they remain in the editor so you can retry.' ;;
        es:menu.sync_lang_failed) text='Los cambios se guardaron, pero no se pudo sincronizar el idioma de los ficheros ya instalados (ejecuta "sync-localized" para reintentarlo).' ;;
        en:menu.sync_lang_failed) text='The changes were saved, but the language of the already-installed files could not be synced (run "sync-localized" to retry).' ;;
        es:menu.reopen_app_menu) text='Cierra y vuelve a abrir el menú de Aplicaciones para ver el nombre del programa en el nuevo idioma.' ;;
        en:menu.reopen_app_menu) text='Close and reopen the Applications menu to see the program name in the new language.' ;;

        es:panel.zenity_missing) text="Falta 'zenity'. Instálalo con: sudo apt install zenity" ;;
        en:panel.zenity_missing) text="'zenity' is missing. Install it with: sudo apt install zenity" ;;
        es:panel.no_gui) text='No se detecta una sesión gráfica (DISPLAY/WAYLAND_DISPLAY); el panel gráfico no se puede mostrar aquí.' ;;
        en:panel.no_gui) text='No graphical session detected (DISPLAY/WAYLAND_DISPLAY); the graphical panel cannot be shown here.' ;;
        es:panel.use_menu) text='Usa el menú de texto: vpn-netguard.sh menu' ;;
        en:panel.use_menu) text='Use the text menu: vpn-netguard.sh menu' ;;
        es:panel.not_installed) text='No se encuentra %s. Ejecuta primero la instalación:\npkexec bash vpn-netguard.sh install' ;;
        en:panel.not_installed) text='Cannot find %s. Install VPN NetGuard first:\npkexec bash vpn-netguard.sh install' ;;
        es:panel.fail) text='Fallo al ejecutar:\n%s\n\nSalida:\n%s' ;;
        en:panel.fail) text='Command failed:\n%s\n\nOutput:\n%s' ;;
        es:panel.status) text='Estado' ;;
        en:panel.status) text='Status' ;;
        es:panel.logs) text='Registros' ;;
        en:panel.logs) text='Logs' ;;
        es:panel.logs_header) text='-- Registros del servicio %s (últimas %s líneas) --' ;;
        en:panel.logs_header) text='-- Service logs %s (last %s lines) --' ;;
        es:panel.config) text='Configuración' ;;
        en:panel.config) text='Configuration' ;;
        es:panel.privacy) text='Anonimato de red' ;;
        en:panel.privacy) text='Network privacy' ;;
        es:panel.monitoring) text='Monitorización' ;;
        en:panel.monitoring) text='Monitoring' ;;
        es:panel.diagnostics) text='Diagnóstico' ;;
        en:panel.diagnostics) text='Diagnostics' ;;
        es:panel.service) text='Servicio systemd' ;;
        en:panel.service) text='systemd service' ;;
        es:panel.backup) text='Copia de seguridad' ;;
        en:panel.backup) text='Configuration backup' ;;
        es:panel.back) text='Volver' ;;
        en:panel.back) text='Back' ;;
        es:panel.back_to_terminal) text='Volver a la terminal' ;;
        en:panel.back_to_terminal) text='Back to the terminal' ;;
        es:panel.interface_save_failed) text='No se pudo fijar la terminal como interfaz de arranque (hace falta un directorio de configuración propio con permiso de escritura). No se ha cambiado nada y el panel sigue abierto.' ;;
        en:panel.interface_save_failed) text='Could not set the terminal as the start interface (an own configuration directory with write permission is needed). Nothing was changed and the panel stays open.' ;;
        es:panel.interface_no_terminal) text='No se encontró ningún emulador de terminal donde abrir el menú de texto: sigues en el panel y la interfaz de arranque no ha cambiado. Instala uno (por ejemplo gnome-terminal o xterm) o ejecuta vpn-netguard.sh desde una terminal.' ;;
        en:panel.interface_no_terminal) text='No terminal emulator was found to open the text menu in: you stay in the panel and the start interface has not changed. Install one (for example gnome-terminal or xterm) or run vpn-netguard.sh from a terminal.' ;;
        es:ui.no_terminal_emulator) text='No se encontró ningún emulador de terminal donde abrir el menú de texto. Instala uno (por ejemplo gnome-terminal o xterm) o ejecuta vpn-netguard.sh desde una terminal.' ;;
        en:ui.no_terminal_emulator) text='No terminal emulator was found to open the text menu in. Install one (for example gnome-terminal or xterm) or run vpn-netguard.sh from a terminal.' ;;
        es:panel.svc_start) text='Iniciar servicio' ;;
        en:panel.svc_start) text='Start service' ;;
        es:panel.svc_stop) text='Detener servicio' ;;
        en:panel.svc_stop) text='Stop service' ;;
        es:panel.svc_restart) text='Reiniciar servicio' ;;
        en:panel.svc_restart) text='Restart service' ;;
        es:panel.svc_enable) text='Habilitar arranque automático' ;;
        en:panel.svc_enable) text='Enable autostart' ;;
        es:panel.svc_disable) text='Deshabilitar arranque automático' ;;
        en:panel.svc_disable) text='Disable autostart' ;;
        es:panel.one_click) text='1-click y olvidar' ;;
        en:panel.one_click) text='1-click set & forget' ;;
        es:panel.activate) text='Protección VPN activada: la VPN se conecta y queda vigilada.' ;;
        en:panel.activate) text='VPN protection enabled: the VPN is connecting and is being monitored.' ;;
        es:panel.deactivate) text='Protección VPN desactivada: la VPN se ha desconectado (salvo un perfil de VPN_IGNORE) y el kill switch está desactivado.' ;;
        en:panel.deactivate) text='VPN protection disabled: the VPN is disconnected (except a VPN_IGNORE profile) and the kill switch is off.' ;;
        es:panel.ks_enabled) text='Kill switch forzado: todo el tráfico fuera de la VPN queda bloqueado.' ;;
        en:panel.ks_enabled) text='Kill switch forced on: all traffic outside the VPN is now blocked.' ;;
        es:panel.ks_disabled) text='Kill switch desactivado: sin bloqueo hasta que lo pongas en automático.' ;;
        en:panel.ks_disabled) text='Kill switch turned off: no blocking until you set it to automatic.' ;;
        es:panel.ks_auto) text='Kill switch en automático: manda el modo de la configuración.' ;;
        en:panel.ks_auto) text='Kill switch set to automatic: the configured mode applies.' ;;
        es:panel.service_started) text='Servicio iniciado.' ;;
        en:panel.service_started) text='Service started.' ;;
        es:panel.service_stopped) text='Servicio detenido.' ;;
        en:panel.service_stopped) text='Service stopped.' ;;
        es:panel.service_restarted) text='Servicio reiniciado.' ;;
        en:panel.service_restarted) text='Service restarted.' ;;
        es:panel.autostart_on) text='Arranque automático activado.' ;;
        en:panel.autostart_on) text='Autostart enabled.' ;;
        es:panel.autostart_off) text='Arranque automático desactivado.' ;;
        en:panel.autostart_off) text='Autostart disabled.' ;;
        es:panel.privacy_applied) text='Anonimato de red aplicado.' ;;
        en:panel.privacy_applied) text='Network privacy applied.' ;;
        es:panel.doh_restart_browser) text='Cierra y vuelve a abrir Firefox/Chrome para que el cambio en su DNS-over-HTTPS tenga efecto.' ;;
        en:panel.doh_restart_browser) text='Close and reopen Firefox/Chrome for the change to their DNS-over-HTTPS to take effect.' ;;
        es:panel.privacy_reconnect_hint) text='Los cambios de MAC, IPv6 y nombre de equipo solo se aplican a partir de la próxima conexión: si ya estabas conectado, desconecta y reconecta esta red (o reinicia) para que surtan efecto del todo.' ;;
        en:panel.privacy_reconnect_hint) text='Changes to MAC, IPv6, and hostname only apply from the next connection onward: if you were already connected, disconnect and reconnect this network (or reboot) for them to fully take effect.' ;;
        es:panel.uninstalled) text='VPN NetGuard se ha desinstalado.' ;;
        en:panel.uninstalled) text='VPN NetGuard has been uninstalled.' ;;
        es:panel.one_click_done) text='Perfil recomendado aplicado: kill switch automático (cede ante otro kill switch activo y se autodesactiva si choca con el arranque de tu VPN), anonimato de red y protección VPN activada.' ;;
        en:panel.one_click_done) text='Recommended profile applied: automatic kill switch (yields to another active kill switch and turns itself off if it clashes with your VPN at boot), network privacy, and VPN protection enabled.' ;;

        es:install.title) text='Instalador de VPN NetGuard' ;;
        en:install.title) text='VPN NetGuard installer' ;;
        es:install.cancelled) text='Instalación cancelada.' ;;
        en:install.cancelled) text='Installation cancelled.' ;;
        es:install.completed) text='Instalación completada.' ;;
        en:install.completed) text='Installation completed.' ;;
        es:install.ready) text='Listo' ;;
        en:install.ready) text='Ready' ;;
        es:install.privacy_q) text='¿Aplicar el módulo de anonimato de red ahora?' ;;
        en:install.privacy_q) text='Apply the network privacy module now?' ;;
        es:install.ssh_warning) text="Aviso: pareces estar conectado por SSH (posible servidor remoto).\n\nEl anonimato de red cambia la MAC de las tarjetas; en un VPS o servidor remoto esto puede cortar tu propia conexión si el proveedor filtra por MAC.\n\n¿Aplicarlo de todas formas ahora?" ;;
        en:install.ssh_warning) text="Warning: you appear to be connected over SSH (possibly a remote server).\n\nNetwork privacy changes adapter MAC addresses; on a VPS or remote server this may cut your own connection if the provider filters by MAC.\n\nApply it anyway?" ;;
        es:install.finish_hint) text="Usa 'sudo bash %s' (o 'vpn-netguard.sh') para el menú interactivo,\n'vpn-netguard.sh status' para ver el estado, o 'vpn-netguard.sh activate'\npara conectar la VPN y activar el kill switch." ;;
        en:install.finish_hint) text="Use 'sudo bash %s' (or 'vpn-netguard.sh') for the interactive menu,\n'vpn-netguard.sh status' to view the status, or 'vpn-netguard.sh activate'\nto connect the VPN and enable the kill switch." ;;
        es:install.finish_privacy_no) text='Recuerda: el anonimato de red sigue sin aplicarse.' ;;
        en:install.finish_privacy_no) text='Remember: network privacy is still not applied.' ;;

        es:systemd.service_description) text='VPN NetGuard - vigilancia de red y kill switch de VPN' ;;
        en:systemd.service_description) text='VPN NetGuard - network monitoring and VPN kill switch' ;;
        es:systemd.boot_description) text='VPN NetGuard - bloqueo temprano antes de configurar la red' ;;
        en:systemd.boot_description) text='VPN NetGuard - early blocking before network configuration' ;;
        es:systemd.mac_service_description) text='VPN NetGuard - rotación periódica de la MAC "stable"' ;;
        en:systemd.mac_service_description) text='VPN NetGuard - periodic "stable" MAC rotation' ;;
        es:systemd.mac_timer_description) text='VPN NetGuard - temporizador de rotación de MAC "stable" (cada %sh)' ;;
        en:systemd.mac_timer_description) text='VPN NetGuard - "stable" MAC rotation timer (every %sh)' ;;

        es:uninstall.confirm) text='¿Seguro que quieres desinstalar VPN NetGuard?\nSe detendrá el servicio, se retirará el kill switch y se borrarán los datos guardados. Al final podrás elegir si conservar la configuración.' ;;
        en:uninstall.confirm) text='Are you sure you want to uninstall VPN NetGuard?\nThe service will stop, the kill switch will be removed, and stored data will be deleted. At the end you can choose whether to keep the configuration.' ;;
        es:uninstall.done) text='VPN NetGuard desinstalado.' ;;
        en:uninstall.done) text='VPN NetGuard uninstalled.' ;;
        es:uninstall.remove_dir_failed) text='No se pudo eliminar %s del todo; revísalo manualmente.' ;;
        en:uninstall.remove_dir_failed) text='Could not fully remove %s; please check it manually.' ;;
        es:uninstall.keep_config_q) text='¿Quieres conservar la configuración para reinstalar más adelante con los mismos ajustes?' ;;
        en:uninstall.keep_config_q) text='Do you want to keep the configuration to reinstall later with the same settings?' ;;
        es:uninstall.kept_config) text='Se ha conservado %s.' ;;
        en:uninstall.kept_config) text='%s has been kept.' ;;
        es:uninstall.teardown_failed) text='No se pudo retirar de forma segura el estado activo; la instalación se conserva para poder reintentarlo.' ;;
        en:uninstall.teardown_failed) text='The active state could not be removed safely; the installation is kept so it can be retried.' ;;

        es:warning.ssh) text='Aviso: pareces estar conectado por SSH (posible servidor remoto).' ;;
        en:warning.ssh) text='Warning: you appear to be connected over SSH (possibly a remote server).' ;;
        es:warning.ssh2) text='El anonimato de red cambia la MAC de las tarjetas; en un VPS o servidor remoto' ;;
        en:warning.ssh2) text='Network privacy changes adapter MAC addresses; on a VPS or remote server' ;;
        es:warning.ssh3) text='remoto esto puede cortar tu propia conexión si el proveedor filtra por MAC.' ;;
        en:warning.ssh3) text='this may cut your own connection if the provider filters by MAC.' ;;

        es:export.no_config) text='No existe %s; instala primero VPN NetGuard.' ;;
        en:export.no_config) text='%s does not exist; install VPN NetGuard first.' ;;
        es:export.ok) text='Configuración exportada a: %s' ;;
        en:export.ok) text='Configuration exported to: %s' ;;
        es:export.fail) text='No se pudo exportar la configuración a: %s' ;;
        en:export.fail) text='Could not export configuration to: %s' ;;

        es:config.missing) text='No existe %s todavía. Instala primero VPN NetGuard.' ;;
        en:config.missing) text='%s does not exist yet. Install VPN NetGuard first.' ;;

        es:usage.header) text='Uso: %s [comando]' ;;
        en:usage.header) text='Usage: %s [command]' ;;
        es:usage.no_args) text='(sin argumentos)      abre la interfaz de arranque: el menú de la terminal, o el panel gráfico si se eligió usarlo al iniciar' ;;
        en:usage.no_args) text='(no arguments)       opens the start interface: the terminal menu, or the graphical panel if you chose to use it at start' ;;
        es:usage.start) text='  start                 arranca el vigilante en primer plano (lo usa systemd)' ;;
        en:usage.start) text='  start                 runs the watcher in the foreground (used by systemd)' ;;
        es:usage.boot) text='  boot-killswitch       aplica el bloqueo temprano antes de configurar la red' ;;
        en:usage.boot) text='  boot-killswitch       applies early blocking before network configuration' ;;
        es:usage.author) text='Programador: Filonux' ;;
        en:usage.author) text='Developer: Filonux' ;;
        es:usage.menu) text='  menu                  abre siempre el menú de la terminal, sin consultar la interfaz de arranque; sin recordar subcomandos' ;;
        en:usage.menu) text='  menu                  always opens the terminal menu, ignoring the start interface: all options without remembering subcommands' ;;
        es:usage.install) text='  install               instala VPN NetGuard en el sistema' ;;
        en:usage.install) text='  install               installs VPN NetGuard on the system' ;;
        es:usage.uninstall) text='  uninstall             desinstala VPN NetGuard del sistema' ;;
        en:usage.uninstall) text='  uninstall             uninstalls VPN NetGuard from the system' ;;
        es:usage.panel) text='  panel                 abre el panel de control gráfico (zenity), sin consultar la interfaz de arranque' ;;
        en:usage.panel) text='  panel                 opens the graphical control panel (zenity), ignoring the start interface' ;;
        es:usage.launch) text='  launch                lo que ejecuta el acceso directo del menú: la interfaz de arranque (si es la terminal, en una ventana propia)' ;;
        en:usage.launch) text='  launch                what the Applications menu entry runs: the start interface (if it is the terminal, in a window of its own)' ;;
        es:usage.status) text='  status                muestra el estado actual' ;;
        en:usage.status) text='  status                shows the current status' ;;
        es:usage.check) text='  check                 comprobación de salud para monitorización automática' ;;
        en:usage.check) text='  check                 health check for automated monitoring' ;;
        es:usage.doctor) text='  doctor                diagnóstico combinado (dependencias, red, firewall, kill switch, convivencia)' ;;
        en:usage.doctor) text='  doctor                combined diagnostics (dependencies, network, firewall, kill switch, coexistence)' ;;
        es:usage.one_click) text='  one-click             aplica el perfil recomendado (con copia de seguridad) y activa la protección; no pregunta' ;;
        en:usage.one_click) text='  one-click             applies the recommended profile (with a backup) and enables protection; asks nothing' ;;
        es:usage.activate) text='  activate              activa la protección VPN: marca "quiero VPN", conecta y vigila' ;;
        en:usage.activate) text='  activate              enables VPN protection: marks the VPN as desired, connects, and monitors' ;;
        es:usage.deactivate) text='  deactivate            desactiva la protección VPN: desconecta la VPN (salvo perfiles de VPN_IGNORE) y desactiva el kill switch' ;;
        en:usage.deactivate) text='  deactivate            disables VPN protection: disconnects the VPN (except VPN_IGNORE profiles) and turns the kill switch off' ;;
        es:usage.killswitch) text='  killswitch on|off|auto|status   control único: forzar, quitar, volver a automático o ver estado' ;;
        en:usage.killswitch) text='  killswitch on|off|auto|status   single control: force, remove, return to automatic, or show status' ;;
        es:usage.disable) text='  disable-killswitch    alias de "killswitch off"' ;;
        en:usage.disable) text='  disable-killswitch    alias of "killswitch off"' ;;
        es:usage.enable) text='  enable-killswitch     alias de "killswitch on"' ;;
        en:usage.enable) text='  enable-killswitch     alias of "killswitch on"' ;;
        es:killswitch.usage) text='Uso: killswitch on|off|auto|status' ;;
        en:killswitch.usage) text='Usage: killswitch on|off|auto|status' ;;
        es:killswitch.failed) text='No se pudo cambiar el kill switch; revisa los mensajes anteriores.' ;;
        en:killswitch.failed) text='Could not change the kill switch; review the messages above.' ;;
        es:killswitch.set_on) text='Kill switch forzado: ACTIVADO (bloquea siempre, también tras reiniciar).' ;;
        en:killswitch.set_on) text='Kill switch forced: ON (always blocks, also after a reboot).' ;;
        es:killswitch.set_off) text='Kill switch forzado: DESACTIVADO (sin bloqueo hasta que vuelvas a automático).' ;;
        en:killswitch.set_off) text='Kill switch forced: OFF (no blocking until you return to automatic).' ;;
        es:killswitch.set_auto) text='Kill switch en automático: manda el modo de la configuración (%s).' ;;
        en:killswitch.set_auto) text='Kill switch set to automatic: the configured mode applies (%s).' ;;
        es:usage.privacy) text='  apply-privacy         (re)aplica el módulo de anonimato de red' ;;
        en:usage.privacy) text='  apply-privacy         (re)applies the network privacy module' ;;
        es:usage.rotate) text='  rotate-mac            regenera y aplica ya la MAC "stable"' ;;
        en:usage.rotate) text='  rotate-mac            regenerates and immediately applies the "stable" MAC' ;;
        es:usage.privacy_status) text='  privacy-status        muestra el estado del anonimato de red' ;;
        en:usage.privacy_status) text='  privacy-status        shows network privacy status' ;;
        es:usage.export) text='  export-config [ruta]  exporta vpn-netguard.conf (backup)' ;;
        en:usage.export) text='  export-config [path]  exports vpn-netguard.conf (backup)' ;;
        es:usage.import) text='  import-config <ruta>  importa vpn-netguard.conf (restore)' ;;
        en:usage.import) text='  import-config <path>  imports vpn-netguard.conf (restore)' ;;
        es:usage.sync_localized) text='  sync-localized        reescribe las unidades/.desktop ya instaladas con el idioma actual' ;;
        en:usage.sync_localized) text='  sync-localized        rewrites the already-installed units/.desktop with the current language' ;;
        es:usage.version) text='  version               muestra la versión instalada' ;;
        en:usage.version) text='  version               shows the installed version' ;;
        es:menu.header_line) text='======================================================' ;;
        en:menu.header_line) text='======================================================' ;;
        es:menu.cat_main) text='── Principal ──' ;;
        en:menu.cat_main) text='── Main ──' ;;
        es:menu.cat_config) text='── Configuración ──' ;;
        en:menu.cat_config) text='── Configuration ──' ;;
        es:menu.cat_advanced) text='── Avanzado ──' ;;
        en:menu.cat_advanced) text='── Advanced ──' ;;
        es:menu.status) text='Ver estado actual' ;;
        en:menu.status) text='View current status' ;;
        es:menu.protection) text='Protección VPN (activar / desactivar)' ;;
        en:menu.protection) text='VPN protection (enable / disable)' ;;
        es:protection.title) text='Protección VPN' ;;
        en:protection.title) text='VPN protection' ;;
        es:protection.menu_on) text='Activar (conectar la VPN y mantenerla vigilada)' ;;
        en:protection.menu_on) text='Enable (connect the VPN and keep it monitored)' ;;
        es:protection.menu_off) text='Desactivar (desconectar la VPN)' ;;
        en:protection.menu_off) text='Disable (disconnect the VPN)' ;;
        es:menu.killswitch) text='Kill switch (activar / desactivar / automático)' ;;
        en:menu.killswitch) text='Kill switch (on / off / automatic)' ;;
        es:killswitch.title) text='Kill switch' ;;
        en:killswitch.title) text='Kill switch' ;;
        es:killswitch.menu_on) text='Activar (bloquea siempre)' ;;
        en:killswitch.menu_on) text='Turn on (always blocks)' ;;
        es:killswitch.menu_off) text='Desactivar (nunca bloquea)' ;;
        en:killswitch.menu_off) text='Turn off (never blocks)' ;;
        es:killswitch.menu_auto) text='Automático (manda la configuración)' ;;
        en:killswitch.menu_auto) text='Automatic (follows the configuration)' ;;
        es:killswitch.status_title) text='Estado del kill switch' ;;
        en:killswitch.status_title) text='Kill switch status' ;;
        es:killswitch.menu_status) text='Ver estado del kill switch' ;;
        en:killswitch.menu_status) text='View kill switch status' ;;
        es:menu.privacy) text='Ajustes de anonimato de red (configurar / aplicar / ver estado)' ;;
        en:menu.privacy) text='Network privacy settings (configure / apply / status)' ;;
        es:privacy.title) text='Ajustes de anonimato de red' ;;
        en:privacy.title) text='Network privacy settings' ;;
        es:privacy.menu_config) text='Configurar (MAC, IPv6, hostname, mDNS...)' ;;
        en:privacy.menu_config) text='Configure (MAC, IPv6, hostname, mDNS...)' ;;
        es:privacy.menu_apply) text='Aplicar ahora (con la configuración guardada)' ;;
        en:privacy.menu_apply) text='Apply now (with the saved configuration)' ;;
        es:privacy.menu_status) text='Ver estado' ;;
        en:privacy.menu_status) text='View status' ;;
        es:menu.config) text='Configuración general (kill switch, red, DNS...)' ;;
        en:menu.config) text='General configuration (kill switch, network, DNS...)' ;;
        es:menu.monitoring) text='Configuración de monitorización (Prometheus, historial de eventos)' ;;
        en:menu.monitoring) text='Monitoring configuration (Prometheus, event history)' ;;
        es:menu.service) text='Servicio systemd (iniciar/detener/reiniciar/arranque automático)' ;;
        en:menu.service) text='systemd service (start/stop/restart/autostart)' ;;
        es:menu.logs) text='Ver registros del servicio y disponibilidad' ;;
        en:menu.logs) text='View service logs and availability' ;;
        es:menu.open_panel) text='Abrir panel gráfico (zenity) y usarlo al iniciar' ;;
        en:menu.open_panel) text='Open graphical panel (zenity) and use it at start' ;;
        es:menu.interface_panel_set) text="Desde ahora vpn-netguard.sh y el acceso directo del menú de aplicaciones abren el panel gráfico. Para volver a la terminal, elige '%s' en el panel." ;;
        en:menu.interface_panel_set) text="From now on vpn-netguard.sh and the Applications menu entry open the graphical panel. To go back to the terminal, choose '%s' in the panel." ;;
        es:menu.interface_save_failed) text='No se pudo fijar el panel como interfaz de arranque (hace falta un directorio de configuración propio con permiso de escritura): no cambia. Se abre el panel igualmente.' ;;
        en:menu.interface_save_failed) text='Could not set the panel as the start interface (an own configuration directory with write permission is needed): it stays as it was. Opening the panel anyway.' ;;
        es:menu.install) text='Instalar VPN NetGuard en el sistema' ;;
        en:menu.install) text='Install VPN NetGuard on the system' ;;
        es:menu.uninstall) text='Desinstalar VPN NetGuard' ;;
        en:menu.uninstall) text='Uninstall VPN NetGuard' ;;
        es:menu.backup) text='Copia de seguridad de la configuración (exportar/importar)' ;;
        en:menu.backup) text='Configuration backup (export/import)' ;;
        es:menu.doctor) text='Diagnóstico completo (dependencias, red, firewall, kill switch)' ;;
        en:menu.doctor) text='Full diagnostics (dependencies, network, firewall, kill switch)' ;;
        es:menu.language) text='Cambiar idioma de la interfaz (es/en)' ;;
        en:menu.language) text='Change interface language (es/en)' ;;
        es:menu.exit0) text='Salir' ;;
        en:menu.exit0) text='Exit' ;;
        es:panel.col_num) text='Nº' ;;
        en:panel.col_num) text='No.' ;;
        es:panel.col_action) text='Acción' ;;
        en:panel.col_action) text='Action' ;;
        es:panel.col_desc) text='Descripción' ;;
        en:panel.col_desc) text='Description' ;;
        es:panel.btn_open) text='Abrir' ;;
        en:panel.btn_open) text='Open' ;;
        es:menu.st_service) text='Servicio' ;;
        en:menu.st_service) text='Service' ;;
        es:menu.st_protection) text='Protección VPN' ;;
        en:menu.st_protection) text='VPN protection' ;;
        es:menu.st_vpn) text='Conexión VPN' ;;
        en:menu.st_vpn) text='VPN connection' ;;
        es:menu.st_killswitch) text='Kill switch' ;;
        en:menu.st_killswitch) text='Kill switch' ;;
        es:menu.st_active) text='activo' ;;
        en:menu.st_active) text='active' ;;
        es:menu.st_inactive) text='inactivo' ;;
        en:menu.st_inactive) text='inactive' ;;
        es:menu.st_enabled) text='activada' ;;
        en:menu.st_enabled) text='enabled' ;;
        es:menu.st_disabled) text='desactivada' ;;
        en:menu.st_disabled) text='disabled' ;;
        es:menu.st_vpn_none) text='ninguna' ;;
        en:menu.st_vpn_none) text='none' ;;
        es:menu.st_vpn_waiting) text='ninguna (se intentará reconectar)' ;;
        en:menu.st_vpn_waiting) text='none (a reconnection will be attempted)' ;;
        es:menu.st_ks_on) text='activado (forzado)' ;;
        en:menu.st_ks_on) text='on (forced)' ;;
        es:menu.st_ks_off) text='desactivado (forzado)' ;;
        en:menu.st_ks_off) text='off (forced)' ;;
        es:menu.st_ks_auto) text='automático (modo %s)' ;;
        en:menu.st_ks_auto) text='automatic (mode %s)' ;;
        es:menu.st_ks_yield) text='cedido a %s' ;;
        en:menu.st_ks_yield) text='yielding to %s' ;;
        es:menu.desc_status) text='Servicio, VPN, kill switch y reglas del cortafuegos' ;;
        en:menu.desc_status) text='Service, VPN, kill switch and firewall rules' ;;
        es:menu.desc_one_click) text='Aplica el perfil recomendado y activa la protección' ;;
        en:menu.desc_one_click) text='Applies the recommended profile and enables protection' ;;
        es:menu.desc_protection) text='Activa o desactiva la VPN y su vigilancia' ;;
        en:menu.desc_protection) text='Enables or disables the VPN and its monitoring' ;;
        es:menu.desc_killswitch) text='Bloqueo de red: activado, desactivado o automático' ;;
        en:menu.desc_killswitch) text='Network block: on, off or automatic' ;;
        es:menu.desc_language) text='Español o inglés' ;;
        en:menu.desc_language) text='Spanish or English' ;;
        es:menu.desc_config) text='Kill switch, red, DNS y reconexión' ;;
        en:menu.desc_config) text='Kill switch, network, DNS and reconnection' ;;
        es:menu.desc_privacy) text='MAC, nombre de equipo, IPv6 y DNS: configurar y aplicar' ;;
        en:menu.desc_privacy) text='MAC, hostname, IPv6 and DNS: configure and apply' ;;
        es:menu.desc_monitoring) text='Prometheus e historial de eventos' ;;
        en:menu.desc_monitoring) text='Prometheus and event history' ;;
        es:menu.desc_service) text='Iniciar, detener, reiniciar y arranque automático' ;;
        en:menu.desc_service) text='Start, stop, restart and autostart' ;;
        es:menu.desc_backup) text='Exportar o importar la configuración' ;;
        en:menu.desc_backup) text='Export or import the configuration' ;;
        es:menu.desc_logs) text='Registros del servicio y disponibilidad' ;;
        en:menu.desc_logs) text='Service logs and availability' ;;
        es:menu.desc_doctor) text='Dependencias, red, cortafuegos, kill switch y convivencia' ;;
        en:menu.desc_doctor) text='Dependencies, network, firewall, kill switch and coexistence' ;;
        es:menu.desc_uninstall) text='Quita VPN NetGuard del sistema' ;;
        en:menu.desc_uninstall) text='Removes VPN NetGuard from the system' ;;
        es:menu.desc_interface) text='Vuelve a la terminal y la usa al iniciar' ;;
        en:menu.desc_interface) text='Goes back to the terminal and uses it at start' ;;
        es:menu.confirm_activate) text='Esto conectará la VPN (si no lo está), la mantendrá vigilada y dejará el kill switch en automático (salvo que lo tengas forzado como activado): el tráfico fuera del túnel se bloqueará mientras la VPN esté caída. Puede tardar unos segundos si la VPN no responde de inmediato. ¿Continuar?' ;;
        en:menu.confirm_activate) text='This will connect the VPN (if needed), keep it monitored, and set the kill switch to automatic (unless you forced it on): traffic outside the tunnel will be blocked while the VPN is down. This may take a few seconds if the VPN does not respond right away. Continue?' ;;
        es:menu.confirm_deactivate) text='Esto desconectará la VPN, dejará de vigilarla y desactivará también el kill switch para que no te quedes sin conexión. Tu tráfico volverá a salir sin pasar por el túnel. Un perfil de VPN_IGNORE no se desconecta. ¿Continuar?' ;;
        en:menu.confirm_deactivate) text='This will disconnect the VPN, stop monitoring it, and also turn the kill switch off so you are not left without a connection. Your traffic will leave without going through the tunnel. A VPN_IGNORE profile is not disconnected. Continue?' ;;
        es:menu.confirm_enable_ks) text='Esto bloquea ya todo el tráfico fuera de la VPN, aunque no esté conectada (puede cortar esta misma sesión SSH). ¿Continuar?' ;;
        en:menu.confirm_enable_ks) text='This blocks all traffic outside the VPN right away, even if it is not connected (may cut this very SSH session). Continue?' ;;
        es:menu.confirm_disable) text='Esto retira el bloqueo y lo mantiene desactivado hasta que lo pongas en automático; no cambia si quieres la VPN activa. ¿Continuar?' ;;
        en:menu.confirm_disable) text='This removes blocking and keeps it off until you set it to automatic; it does not change whether the VPN is wanted. Continue?' ;;
        es:menu.confirm_privacy) text='Esto aplicará el anonimato de red (MAC, IPv6, hostname, mDNS...) ahora mismo. ¿Continuar?' ;;
        en:menu.confirm_privacy) text='This will apply network privacy (MAC, IPv6, hostname, mDNS...) now. Continue?' ;;
        es:menu.unsupported_gui) text='No se detecta una sesión gráfica; el panel gráfico no se puede abrir desde aquí.' ;;
        en:menu.unsupported_gui) text='No graphical session detected; the graphical panel cannot be opened from here.' ;;
        es:menu.no_self) text='No se encuentra el propio fichero del script en disco (%s); no se puede elevar privilegios.' ;;
        en:menu.no_self) text='Cannot find the script file on disk (%s); cannot elevate privileges.' ;;
        es:menu.installed_first) text='VPN NetGuard no está instalado todavía. Instálalo primero.' ;;
        en:menu.installed_first) text='VPN NetGuard is not installed yet. Install it first.' ;;
        es:menu.install_hint) text='Guarda vpn-netguard.sh en una carpeta y ejecútalo desde ahí, por ejemplo:' ;;
        en:menu.install_hint) text='Save vpn-netguard.sh in a directory and run it from there, for example:' ;;
        es:menu.confirm_reinstall) text='VPN NetGuard ya parece estar instalado. ¿Reinstalar/actualizar de todas formas?' ;;
        en:menu.confirm_reinstall) text='VPN NetGuard already appears to be installed. Reinstall/update anyway?' ;;
        es:menu.stop_keep_ks) text='¿Detener el servicio? Si el kill switch estaba activo, el bloqueo se mantiene por seguridad hasta que lo quites explícitamente.' ;;
        en:menu.stop_keep_ks) text='Stop the service? If the kill switch was active, blocking remains for safety until you explicitly remove it.' ;;
        es:menu.overwrite) text="Ya existe '%s'. ¿Sobrescribir?" ;;
        en:menu.overwrite) text="'%s' already exists. Overwrite?" ;;
        es:menu.import_confirm) text="Esto sustituirá la configuración actual por '%s' (se guarda antes una copia). ¿Continuar?" ;;
        en:menu.import_confirm) text="This will replace the current configuration with '%s' (a backup is created first). Continue?" ;;
        es:menu.path_dest) text='Ruta destino (Enter = ./vpn-netguard-%s.conf): ' ;;
        en:menu.path_dest) text='Destination path (Enter = ./vpn-netguard-%s.conf): ' ;;
        es:menu.path_src) text='Ruta del fichero a importar (Enter = cancelar): ' ;;
        en:menu.path_src) text='Path of the file to import (Enter = cancel): ' ;;
        es:menu.service_title) text='-- Servicio systemd (%s) --' ;;
        en:menu.service_title) text='-- systemd service (%s) --' ;;
        es:menu.start) text=' 1) Iniciar' ;;
        en:menu.start) text=' 1) Start' ;;
        es:menu.stop) text=' 2) Detener' ;;
        en:menu.stop) text=' 2) Stop' ;;
        es:menu.restart) text=' 3) Reiniciar' ;;
        en:menu.restart) text=' 3) Restart' ;;
        es:menu.enable_autostart) text=' 4) Habilitar arranque automático' ;;
        en:menu.enable_autostart) text=' 4) Enable autostart' ;;
        es:menu.disable_autostart) text=' 5) Deshabilitar arranque automático' ;;
        en:menu.disable_autostart) text=' 5) Disable autostart' ;;
        es:menu.logs_history) text='-- Historial de disponibilidad (últimos eventos, %s) --' ;;
        en:menu.logs_history) text='-- Availability history (latest events, %s) --' ;;
        es:menu.no_logs) text='VPN NetGuard no está instalado todavía: no hay registros de systemd que mostrar.' ;;
        en:menu.no_logs) text='VPN NetGuard is not installed yet: there are no systemd logs to show.' ;;
        es:menu.no_service) text='VPN NetGuard no está instalado todavía: no hay servicio systemd que gestionar.' ;;
        en:menu.no_service) text='VPN NetGuard is not installed yet: there is no systemd service to manage.' ;;

        es:check.crit) text='CRÍTICO: el kill switch debería estar activo pero no lo está (tráfico sin proteger).' ;;
        en:check.crit) text='CRITICAL: the kill switch should be active but is not (traffic is unprotected).' ;;
        es:check.warn_down) text='AVISO: VPN caída; el tráfico está bloqueado por el kill switch (fail-closed).' ;;
        en:check.warn_down) text='WARNING: VPN is down; traffic is blocked by the kill switch (fail-closed).' ;;
        es:check.vpn_nointernet) text='AVISO: VPN conectada (%s) pero sin respuesta real de Internet (o túnel WireGuard zombie).' ;;
        en:check.vpn_nointernet) text='WARNING: VPN connected (%s) but no Internet response (or a zombie WireGuard tunnel).' ;;
        es:check.ok_protected) text='OK: protegido por VPN (%s).' ;;
        en:check.ok_protected) text='OK: protected by VPN (%s).' ;;
        es:check.warn_unexpected_ks) text='AVISO: el kill switch sigue activo aunque no debería estarlo (modo %s).' ;;
        en:check.warn_unexpected_ks) text='WARNING: the kill switch is still active even though it should not be (mode %s).' ;;
        es:check.warn_autodisabled) text='AVISO: kill switch autodesactivado por choque de arranque (%s); vuelve a automático con "killswitch auto" tras conectar tu VPN.' ;;
        en:check.warn_autodisabled) text='WARNING: kill switch auto-disabled due to a boot race (%s); return it to automatic with "killswitch auto" once your VPN is connected.' ;;
        es:check.warn_nointernet) text='AVISO: sin respuesta real de Internet (kill switch no aplica en este modo).' ;;
        en:check.warn_nointernet) text='WARNING: no Internet response (kill switch is not active in this mode).' ;;
        es:check.ok_not_required) text='OK: kill switch no requerido ahora mismo (modo %s).' ;;
        en:check.ok_not_required) text='OK: kill switch is not required right now (mode %s).' ;;
        es:check.ok_yielding) text='OK: kill switch ajeno activo (%s); NetGuard cede el bloqueo.' ;;
        en:check.ok_yielding) text='OK: another kill switch is active (%s); NetGuard yields blocking.' ;;

        es:panel.one_click_confirm) text='Esto aplicará el perfil recomendado: kill switch automático (cede ante otro kill switch activo y se autodesactiva si choca con el arranque de tu VPN), red local permitida, notificaciones y anonimato de red (MAC estable por red que cambia en cada arranque, IPv6 privado, nombre de equipo y mDNS ocultos). No bloquea Avahi, NetBIOS ni el DNS-over-HTTPS de los navegadores: si NetGuard los había restringido, se restauran. Se guarda una copia de tu configuración y después se activa la protección VPN. ¿Continuar?' ;;
        en:panel.one_click_confirm) text='This will apply the recommended profile: automatic kill switch (yields to another active kill switch and turns itself off if it clashes with your VPN at boot), local network allowed, notifications, and network privacy (stable per-network MAC that changes at every boot, private IPv6, hidden hostname and mDNS). It does not block Avahi, NetBIOS or browser DNS-over-HTTPS: if NetGuard had restricted them, they are restored. A copy of your configuration is saved, then VPN protection is enabled. Continue?' ;;
        es:panel.one_click_confirm_ssh) text='Aviso: pareces estar conectado por SSH (posible servidor remoto).\n\nEsto cambiará la MAC de las tarjetas de red y activará el kill switch; en un VPS o servidor remoto puede cortar tu propia conexión si el proveedor filtra por MAC o si la VPN tarda en conectar.\n\n¿Continuar de todas formas con la configuración recomendada?' ;;
        en:panel.one_click_confirm_ssh) text='Warning: you appear to be connected over SSH (possibly a remote server).\n\nThis will change your network adapters MAC address and enable the kill switch; on a VPS or remote server this may cut your own connection if the provider filters by MAC or if the VPN is slow to connect.\n\nContinue anyway with the recommended setup?' ;;
        es:oneclick.config_unsafe) text='La configuración actual (%s) tiene líneas no admitidas y NetGuard la ignora entera, así que el perfil no tendría efecto. Corrígela o restaura una copia (import-config) y repite. No se ha cambiado nada.' ;;
        en:oneclick.config_unsafe) text='The current configuration (%s) has unsupported lines and NetGuard ignores the whole file, so the profile would have no effect. Fix it or restore a copy (import-config) and try again. Nothing was changed.' ;;
        es:oneclick.backup_fail) text='No se pudo guardar la copia de seguridad de la configuración. No se ha cambiado nada.' ;;
        en:oneclick.backup_fail) text='Could not save the configuration backup. Nothing was changed.' ;;
        es:oneclick.backup_ok) text='Copia de seguridad de la configuración: %s' ;;
        en:oneclick.backup_ok) text='Configuration backup: %s' ;;
        es:oneclick.save_fail) text='No se pudo guardar el perfil en %s. La configuración sigue como estaba.' ;;
        en:oneclick.save_fail) text='Could not save the profile to %s. The configuration is as it was.' ;;
        es:oneclick.restore_fail) text='No se pudo guardar el perfil y la configuración quedó dañada: restáurala con la copia %s' ;;
        en:oneclick.restore_fail) text='Could not save the profile and the configuration was left damaged: restore it from the backup %s' ;;
        es:oneclick.profile_ok) text='Perfil recomendado guardado en %s' ;;
        en:oneclick.profile_ok) text='Recommended profile saved to %s' ;;
        es:oneclick.privacy_ok) text='Anonimato de red aplicado' ;;
        en:oneclick.privacy_ok) text='Network privacy applied' ;;
        es:oneclick.privacy_fail) text='El anonimato de red no se aplicó por completo' ;;
        en:oneclick.privacy_fail) text='Network privacy was not fully applied' ;;
        es:oneclick.activate_ok) text='Protección VPN activada' ;;
        en:oneclick.activate_ok) text='VPN protection enabled' ;;
        es:oneclick.activate_fail) text='No se pudo activar la protección VPN' ;;
        en:oneclick.activate_fail) text='Could not enable VPN protection' ;;
        es:oneclick.service_ok) text='Servicio %s reiniciado' ;;
        en:oneclick.service_ok) text='Service %s restarted' ;;
        es:oneclick.service_fail) text='No se pudo reiniciar el servicio %s' ;;
        en:oneclick.service_fail) text='Could not restart the service %s' ;;
        es:oneclick.service_skip) text='El servicio %s no está instalado: no se reinicia' ;;
        en:oneclick.service_skip) text='The service %s is not installed: not restarted' ;;
        es:oneclick.pre_title) text='Comprobaciones previas' ;;
        en:oneclick.pre_title) text='Pre-checks' ;;
        es:oneclick.pre_tunnels) text='Hay un túnel VPN ajeno activo (%s) sin kill switch: NetGuard lo deja pasar.' ;;
        en:oneclick.pre_tunnels) text='Another VPN tunnel is active (%s) without a kill switch: NetGuard lets it through.' ;;
        es:oneclick.pre_autostart) text='El servicio %s está instalado pero no arranca solo: ejecuta «systemctl enable %s».' ;;
        en:oneclick.pre_autostart) text='The service %s is installed but does not start on its own: run "systemctl enable %s".' ;;
        es:oneclick.partial) text='El perfil está guardado, pero algún paso falló (✗ arriba). Repite 1-click o usa cada opción del menú por separado.' ;;
        en:oneclick.partial) text='The profile is saved, but a step failed (✗ above). Run 1-click again or use each menu option separately.' ;;
        es:panel.confirm_stop) text='Esto detiene el servicio de fondo (vigilancia y reconexión automática). Si el kill switch estaba activo, las reglas de bloqueo se mantienen por seguridad hasta que las quites explícitamente. ¿Detener el servicio?' ;;
        en:panel.confirm_stop) text='This stops the background service (monitoring and automatic reconnection). If the kill switch was active, blocking rules remain for safety until you explicitly remove them. Stop the service?' ;;
        es:panel.confirm_start) text='Esto iniciará el servicio de vigilancia y aplicará la protección configurada; puede tardar unos segundos si la VPN no responde de inmediato. ¿Continuar?' ;;
        en:panel.confirm_start) text='This will start the monitoring service and apply the configured protection; this may take a few seconds if the VPN does not respond right away. Continue?' ;;
        es:panel.confirm_restart) text='Esto reiniciará el servicio de vigilancia; puede tardar unos segundos si la VPN no responde de inmediato. ¿Continuar?' ;;
        en:panel.confirm_restart) text='This will restart the monitoring service; this may take a few seconds if the VPN does not respond right away. Continue?' ;;
        es:panel.config_saved) text='Configuración guardada.' ;;
        en:panel.config_saved) text='Configuration saved.' ;;
        es:panel.config_auto) text='El servicio detecta el cambio y lo aplica solo en unos segundos; no hace falta reiniciarlo.' ;;
        en:panel.config_auto) text='The service detects the change and applies it by itself within a few seconds; no restart needed.' ;;
        es:panel.config_save_fail) text='No se pudo guardar la configuración.' ;;
        en:panel.config_save_fail) text='Could not save the configuration.' ;;
        es:panel.sync_lang_failed) text='Los cambios se guardaron, pero no se pudo sincronizar el idioma de los ficheros ya instalados (ejecuta "sync-localized" para reintentarlo).' ;;
        en:panel.sync_lang_failed) text='The changes were saved, but the language of the already-installed files could not be synced (run "sync-localized" to retry).' ;;
        es:panel.reopen_app_menu) text='Cierra y vuelve a abrir el menú de Aplicaciones para ver el nombre del programa en el nuevo idioma.' ;;
        en:panel.reopen_app_menu) text='Close and reopen the Applications menu to see the program name in the new language.' ;;
        es:panel.privacy_saved) text='Configuración de anonimato guardada.' ;;
        en:panel.privacy_saved) text='Network privacy configuration saved.' ;;
        es:panel.privacy_save_fail) text='No se pudo guardar la configuración de anonimato.' ;;
        en:panel.privacy_save_fail) text='Could not save the network privacy configuration.' ;;
        es:panel.monitor_help) text="«Elegir carpeta...» abre el explorador de carpetas para las métricas.\nDeja el campo de texto en blanco para mantener su valor actual." ;;
        en:panel.monitor_help) text="\"Choose folder...\" opens the folder browser for the metrics.\nLeave the text field blank to keep its current value." ;;
        es:panel.prom_keep) text='Mantener (%s)' ;;
        en:panel.prom_keep) text='Keep (%s)' ;;
        es:panel.prom_choose) text='Elegir carpeta...' ;;
        en:panel.prom_choose) text='Choose folder...' ;;
        es:panel.prom_clear) text='Quitar (sin métricas)' ;;
        en:panel.prom_clear) text='Remove (no metrics)' ;;
        es:panel.prom_pick_title) text='Carpeta de las métricas de Prometheus' ;;
        en:panel.prom_pick_title) text='Prometheus metrics folder' ;;
        es:panel.monitor_saved) text='Configuración de monitorización guardada.' ;;
        en:panel.monitor_saved) text='Monitoring configuration saved.' ;;
        es:panel.monitor_save_fail) text='No se pudo guardar la configuración de monitorización.' ;;
        en:panel.monitor_save_fail) text='Could not save the monitoring configuration.' ;;
        es:panel.remove_confirm) text='Esto detendrá el servicio y eliminará VPN NetGuard del sistema. Al final podrás elegir si conservar la configuración. ¿Continuar?' ;;
        en:panel.remove_confirm) text='This will stop the service and remove VPN NetGuard from the system. At the end you can choose whether to keep the configuration. Continue?' ;;
        es:ui.current) text='actual: %s' ;;
        en:ui.current) text='current: %s' ;;
        es:ui.none_value) text='ninguno' ;;
        en:ui.none_value) text='none' ;;
        es:config.install_first) text='No existe %s todavía. Instala primero VPN NetGuard.' ;;
        en:config.install_first) text='Cannot find %s yet. Install VPN NetGuard first.' ;;
        es:config.not_importable) text='Indica un fichero de configuración válido a importar.' ;;
        en:config.not_importable) text='Specify a valid configuration file to import.' ;;
        es:config.invalid_syntax) text='El fichero no parece una configuración válida (falla la sintaxis).' ;;
        en:config.invalid_syntax) text='The file does not look like a valid configuration (syntax error).' ;;
        es:config.invalid_content) text='El fichero contiene contenido no permitido; se rechaza para evitar ejecutar código.' ;;
        en:config.invalid_content) text='The file contains disallowed content; it was rejected to prevent code execution.' ;;
        es:log.config_unsafe_file) text='Configuración rechazada por contenido no permitido: %s' ;;
        en:log.config_unsafe_file) text='Configuration rejected because it contains disallowed content: %s' ;;
        es:log.config_reloaded) text='Configuración recargada desde %s (modo kill switch: %s, intervalo respaldo: %ss)' ;;
        en:log.config_reloaded) text='Configuration reloaded from %s (kill switch mode: %s, backup interval: %ss)' ;;
        es:log.config_reload_kept) text='No se recarga la configuración (fichero ausente o con contenido no permitido): %s; se mantiene la anterior' ;;
        en:log.config_reload_kept) text='Configuration not reloaded (file missing or contains disallowed content): %s; keeping the previous one' ;;
        es:config.backup_fail) text='No se pudo hacer una copia de seguridad previa; se cancela la importación.' ;;
        en:config.backup_fail) text='Could not create the backup first; import cancelled.' ;;
        es:config.imported) text='Configuración importada desde: %s' ;;
        en:config.imported) text='Configuration imported from: %s' ;;
        es:config.import_fail) text='No se pudo importar la configuración (se conserva la copia de seguridad en %s).' ;;
        en:config.import_fail) text='Could not import the configuration (backup preserved at %s).' ;;
        es:config.write_too_long) text='No se ha guardado nada: el valor de %s ocupa %d caracteres (con las barras de escape) y el máximo es %d. Acórtalo y repite.' ;;
        en:config.write_too_long) text='Nothing was saved: the value of %s takes %d characters (counting escape backslashes) and the maximum is %d. Shorten it and try again.' ;;
        es:config.write_rejected) text='No se ha guardado nada: la configuración resultante sería rechazada por contenido no admitido y NetGuard volvería a los valores por defecto.' ;;
        en:config.write_rejected) text='Nothing was saved: the resulting configuration would be rejected for disallowed content and NetGuard would fall back to the defaults.' ;;
        es:config.write_current_rejected) text='No se ha guardado nada: la configuración actual (%s) tiene líneas no admitidas y NetGuard la ignora entera. Corrígela o restaura una copia (import-config) y repite.' ;;
        en:config.write_current_rejected) text='Nothing was saved: the current configuration (%s) has unsupported lines and NetGuard ignores the whole file. Fix it or restore a copy (import-config) and try again.' ;;
        es:config.install_root) text='Este instalador debe ejecutarse como root (pkexec en escritorio; sudo en servidor).' ;;
        en:config.install_root) text='This installer must run as root (pkexec on a desktop; sudo on a server).' ;;
        es:config.self_missing) text='No se encuentra el propio fichero del script en disco.' ;;
        en:config.self_missing) text='The script file cannot be found on disk.' ;;
        es:config.self_hint) text='Guarda vpn-netguard.sh en una carpeta y ejecuta: sudo bash /ruta/a/vpn-netguard.sh install' ;;
        en:config.self_hint) text='Save vpn-netguard.sh in a directory and run: sudo bash /path/to/vpn-netguard.sh install' ;;
        es:install.summary) text='Este asistente instalará VPN NetGuard:' ;;
        en:install.summary) text='This wizard will install VPN NetGuard:' ;;
        es:install.accept) text='Pulsa Aceptar para continuar.' ;;
        en:install.accept) text='Click OK to continue.' ;;
        es:install.nm_warn) text="Aviso: NetworkManager no está activo.

VPN NetGuard depende de él (nmcli) para todo. Instálalo/actívalo con:
  sudo apt install network-manager
  sudo systemctl enable --now NetworkManager

¿Continuar la instalación de todas formas?" ;;
        en:install.nm_warn) text="Warning: NetworkManager is not active.

VPN NetGuard depends on it (nmcli) for everything. Install/enable it with:
  sudo apt install network-manager
  sudo systemctl enable --now NetworkManager

Continue the installation anyway?" ;;
        es:install.ufw_warn) text="Aviso: ufw está activo.

VPN NetGuard añade su propia cadena de iptables en OUTPUT, independiente de ufw. Ambos pueden convivir; revisa 'sudo ufw status verbose' si algo no se comporta como esperas." ;;
        en:install.ufw_warn) text="Warning: ufw is active.

VPN NetGuard adds its own iptables chain in OUTPUT, independent of ufw. Both can coexist; check 'sudo ufw status verbose' if anything behaves unexpectedly." ;;
        es:install.autostart_q) text='¿Quieres que el servicio arranque automáticamente al iniciar el sistema?' ;;
        en:install.autostart_q) text='Should the service start automatically at system boot?' ;;
        es:install.start_now_q) text='¿Quieres iniciar el servicio ahora, nada más terminar la instalación?' ;;
        en:install.start_now_q) text='Start the service now, immediately after installation?' ;;
        es:install.ssh_privacy_warn) text="Aviso: pareces estar conectado por SSH (posible servidor remoto).

El anonimato de red cambia la MAC de las tarjetas; en un VPS o servidor remoto esto puede cortar tu propia conexión si el proveedor filtra por MAC.

¿Aplicarlo de todas formas ahora? Si dices que no, podrás activarlo luego con: vpn-netguard.sh apply-privacy" ;;
        en:install.ssh_privacy_warn) text="Warning: you appear to be connected over SSH (possibly a remote server).

Network privacy changes adapter MAC addresses; on a VPS or remote server this may cut your own connection if the provider filters by MAC.

Apply it anyway? You can enable it later with: vpn-netguard.sh apply-privacy" ;;
        es:install.progress_privacy_skip) text='Anonimato de red NO aplicado (omitido; usa "apply-privacy" cuando quieras)...' ;;
        en:install.progress_privacy_skip) text='Network privacy NOT applied (skipped; run "apply-privacy" whenever you want)...' ;;
        es:install.progress_copy) text='Copiando el programa...' ;;
        en:install.progress_copy) text='Copying the program...' ;;
        es:install.progress_config) text='Preparando configuración...' ;;
        en:install.progress_config) text='Preparing configuration...' ;;
        es:install.progress_systemd) text='Instalando el servicio systemd...' ;;
        en:install.progress_systemd) text='Installing the systemd service...' ;;
        es:install.progress_desktop) text='Creando entrada en el menú de Aplicaciones...' ;;
        en:install.progress_desktop) text='Creating the Applications menu entry...' ;;
        es:install.progress_boot) text='Aplicando preferencias de arranque (puede tardar unos segundos si la VPN no responde de inmediato; no cierres esta ventana)...' ;;
        en:install.progress_boot) text='Applying startup preferences (this may take a few seconds if the VPN does not respond right away; do not close this window)...' ;;
        es:install.fatal_interrupt) text='La instalación se ha interrumpido.' ;;
        en:install.fatal_interrupt) text='Installation was interrupted.' ;;
        es:menu.config_title) text='Configuración general — VPN NetGuard' ;;
        en:menu.config_title) text='General configuration — VPN NetGuard' ;;
        es:menu.privacy_title) text='Anonimato de red — VPN NetGuard' ;;
        en:menu.privacy_title) text='Network privacy — VPN NetGuard' ;;
        es:menu.monitoring_title) text='Monitorización y alertas — VPN NetGuard' ;;
        en:menu.monitoring_title) text='Monitoring and alerts — VPN NetGuard' ;;
        es:desktop.generic_name) text='Panel de control VPN' ;;
        en:desktop.generic_name) text='VPN control panel' ;;
        es:desktop.comment) text='Configura, activa o desactiva la protección de VPN NetGuard (kill switch y reconexión automática)' ;;
        en:desktop.comment) text='Configure, enable or disable VPN NetGuard protection (kill switch and automatic reconnection)' ;;
        es:panel.config_help) text="Un campo de texto en blanco mantiene su valor; '-' vacía los campos opcionales." ;;
        en:panel.config_help) text="A blank text field keeps its value; '-' clears optional fields." ;;
        es:panel.privacy_help) text="El anonimato de red se aplica a la red local y no depende del kill switch de la VPN.\nUsa '-' en los campos opcionales para vaciarlos.\nAceptar guarda y aplica (pide confirmación); '%s' descarta lo escrito." ;;
        en:panel.privacy_help) text="Network privacy applies to the local network and does not depend on the VPN kill switch.\nUse '-' in optional fields to clear them.\nOK saves and applies (asks for confirmation); '%s' discards what you typed." ;;
        es:panel.invalid_history) text='El máximo de líneas del historial debe ser un número entero (0 o más).' ;;
        en:panel.invalid_history) text='Event-history maximum must be an integer (0 or greater).' ;;
        es:panel.export_title) text='Exportar configuración' ;;
        en:panel.export_title) text='Export configuration' ;;
        es:panel.import_title) text='Importar configuración' ;;
        en:panel.import_title) text='Import configuration' ;;
        es:panel.config_missing) text='No existe %s todavía. Instala primero VPN NetGuard.' ;;
        en:panel.config_missing) text='Cannot find %s yet. Install VPN NetGuard first.' ;;
        es:panel.exported) text='Configuración exportada a:\n%s' ;;
        en:panel.exported) text='Configuration exported to:\n%s' ;;
        es:panel.export_failed) text='No se pudo exportar la configuración a:\n%s' ;;
        en:panel.export_failed) text='Could not export the configuration to:\n%s' ;;
        es:panel.imported_auto) text='Configuración importada.\n\nEl servicio la aplicará solo en unos segundos; no hace falta reiniciarlo.' ;;
        en:panel.imported_auto) text='Configuration imported.\n\nThe service will apply it by itself within a few seconds; no restart needed.' ;;
        es:panel.confirm_import) text='Esto sustituirá la configuración actual por:\n%s\n\n(se guarda antes una copia de la actual)\n\n¿Continuar?' ;;
        en:panel.confirm_import) text='This will replace the current configuration with:\n%s\n\n(a backup of the current configuration is created first)\n\nContinue?' ;;
        es:install.zenity_fail) text="No se pudo instalar zenity. Instálalo manualmente: apt install zenity" ;;
        en:install.zenity_fail) text="Could not install zenity. Install it manually: apt install zenity" ;;
        es:install.zenity_installing) text='Instalando zenity (necesario para los diálogos gráficos)...' ;;
        en:install.zenity_installing) text='Installing zenity (required for graphical dialogs)...' ;;
        es:install.menu_entry_q) text='¿Añadir VPN NetGuard al menú de Aplicaciones (con su propio icono)?' ;;
        en:install.menu_entry_q) text='Add VPN NetGuard to the Applications menu (with its own icon)?' ;;
        es:install.progress_desktop_skip) text='Omitiendo la entrada del menú de Aplicaciones (lo elegiste así)...' ;;
        en:install.progress_desktop_skip) text='Skipping the Applications menu entry (as you chose)...' ;;
        es:install.menu_entry_failed) text='Aviso: no se pudo crear el icono o la entrada del menú de Aplicaciones (revisa permisos). El resto de la instalación continúa; el programa funciona igual desde la terminal.' ;;
        en:install.menu_entry_failed) text='Warning: could not create the icon or the Applications menu entry (check permissions). The rest of the installation continues; the program still works from the terminal.' ;;
        es:install.desktop_q) text='¿Quieres añadir también un icono en el Escritorio, además de en el menú de Aplicaciones?' ;;
        en:install.desktop_q) text='Add a desktop icon as well as the Applications menu entry?' ;;
        es:install.progress_desktop_icon) text='Creando icono de escritorio...' ;;
        en:install.progress_desktop_icon) text='Creating desktop icon...' ;;
        es:install.progress_installing) text='Instalando...' ;;
        en:install.progress_installing) text='Installing...' ;;
        es:install.complete_message) text="Instalación completada.\n\n%s\n\nPor defecto, la protección de VPN (kill switch) NO está activa hasta que la actives desde el panel.\n\n%s" ;;
        en:install.complete_message) text="Installation completed.\n\n%s\n\nBy default, VPN protection (kill switch) is NOT active until you enable it from the panel.\n\n%s" ;;
        es:install.find_it_menu) text="Busca 'VPN NetGuard' en el menú de Aplicaciones (o en el Escritorio, si lo pediste)\npara configurar, activar o desactivar la protección." ;;
        en:install.find_it_menu) text="Find 'VPN NetGuard' in the Applications menu (or on the Desktop, if requested)\nto configure, enable or disable protection." ;;
        es:install.find_it_nomenu) text="No se creó la entrada del menú de Aplicaciones (elegiste omitirla). Para configurar o activar la protección, ejecuta:\n%s panel" ;;
        en:install.find_it_nomenu) text="The Applications menu entry was not created (you chose to skip it). To configure or enable protection, run:\n%s panel" ;;
        es:install.privacy_active) text="El anonimato de red (MAC aleatoria, IPv6 privado, hostname oculto) SÍ está\nactivo ya mismo, por defecto. Puedes revisarlo o ajustarlo desde el panel,\nen 'Anonimato de red'." ;;
        en:install.privacy_active) text="Network privacy (random MAC, private IPv6, hidden hostname) is already\nactive by default. You can review or adjust it from the 'Network privacy' panel." ;;
        es:install.privacy_pending) text="El anonimato de red NO se ha aplicado (elegiste no aplicarlo por la sesión SSH).\nPuedes activarlo luego con: vpn-netguard.sh apply-privacy" ;;
        en:install.privacy_pending) text="Network privacy was NOT applied (you chose not to apply it for the SSH session).\nYou can enable it later with: vpn-netguard.sh apply-privacy" ;;
        es:install.text_header) text='== Instalador de VPN NetGuard (modo texto) ==' ;;
        en:install.text_header) text='== VPN NetGuard installer (text mode) ==' ;;
        es:install.will_install) text='Se instalará:' ;;
        en:install.will_install) text='The following will be installed:' ;;
        es:install.app_entry) text='Entrada en el menú de Aplicaciones (sin efecto si no hay escritorio)' ;;
        en:install.app_entry) text='Applications menu entry (no effect without a desktop)' ;;
        es:install.privacy_default) text='Anonimato de red (MAC, IPv6, hostname...)' ;;
        en:install.privacy_default) text='Network privacy (MAC, IPv6, hostname...)' ;;
        es:install.remote_warning) text='Aviso: el módulo de anonimato de red cambia la MAC de tus tarjetas y otros identificadores. En un SERVIDOR REMOTO (VPS, dedicado), esto puede cortar tu propia conexión si el proveedor filtra por MAC. Si no estás seguro, di que no y pruébalo más tarde con: vpn-netguard.sh apply-privacy' ;;
        en:install.remote_warning) text='Warning: the network privacy module changes adapter MAC addresses and other identifiers. On a REMOTE SERVER (VPS, dedicated server), this may cut your own connection if the provider filters by MAC. If unsure, answer no and try it later with: vpn-netguard.sh apply-privacy' ;;
        es:install.fixed_yes) text='# %s: sí (fijado por bandera/entorno)' ;;
        en:install.fixed_yes) text='# %s: yes (set by flag/environment)' ;;
        es:install.fixed_no) text='# %s: no (fijado por bandera/entorno)' ;;
        en:install.fixed_no) text='# %s: no (set by flag/environment)' ;;
        es:install.fail_mkdir) text='Fallo al crear %s o %s' ;;
        en:install.fail_mkdir) text='Failed to create %s or %s' ;;
        es:install.fail_tmp) text='Fallo al crear el fichero temporal para %s' ;;
        en:install.fail_tmp) text='Failed to create the temporary file for %s' ;;
        es:menu.current_marker) text='actual' ;;
        en:menu.current_marker) text='current' ;;
        es:warning.apply_anyway) text='¿Aplicarlo de todas formas ahora?' ;;
        en:warning.apply_anyway) text='Apply it anyway now?' ;;
        es:menu.self_warning) text='Aviso: no se puede leer el propio fichero del script en disco (%s).' ;;
        en:menu.self_warning) text='Warning: the script file cannot be read from disk (%s).' ;;
        es:menu.self_warning2) text="Si lo has ejecutado con 'curl ... | bash' o similar, guarda primero vpn-netguard.sh en una carpeta." ;;
        en:menu.self_warning2) text="If you ran it with 'curl ... | bash' or similar, save vpn-netguard.sh in a directory first." ;;
        es:menu.self_warning3) text='Las acciones que necesitan privilegios de administrador requieren ese fichero para poder volver a ejecutarse.' ;;
        en:menu.self_warning3) text='Actions that need administrator privileges require that file to re-run themselves.' ;;
        es:menu.elevation_missing) text="Falta 'pkexec' (paquete policykit-1) o 'sudo'; esta acción necesita privilegios de root." ;;
        en:menu.elevation_missing) text="'pkexec' (policykit-1) or 'sudo' is required; this action needs root privileges." ;;
        es:menu.elevation_hint) text='Instala alguno, o vuelve a lanzar el menú con: sudo bash "%s"' ;;
        en:menu.elevation_hint) text='Install one of them, or run the menu again with: sudo bash "%s"' ;;
        es:export.backup) text='Copia de seguridad de la anterior en: %s' ;;
        en:export.backup) text='Previous configuration backup: %s' ;;
        es:install.nm_continue_q) text='¿Continuar la instalación de todas formas?' ;;
        en:install.nm_continue_q) text='Continue the installation anyway?' ;;
        es:install.autostart_label) text='Arranque automático' ;;
        en:install.autostart_label) text='Autostart' ;;
        es:install.start_label) text='Inicio inmediato' ;;
        en:install.start_label) text='Start now' ;;
        es:install.privacy_label) text='Anonimato de red' ;;
        en:install.privacy_label) text='Network privacy' ;;
        es:install.menu_entry_label) text='Entrada de menú' ;;
        en:install.menu_entry_label) text='Menu entry' ;;
        es:install.progress_privacy) text='Aplicando anonimato de red (MAC, IPv6, hostname)...' ;;
        en:install.progress_privacy) text='Applying network privacy (MAC, IPv6, hostname)...' ;;
        es:log.config_invalid_level) text="LOG_LEVEL inválido en config ('%s'); usando 'info'" ;;
        en:log.config_invalid_level) text="Invalid LOG_LEVEL in config ('%s'); using 'info'" ;;
        es:log.config_invalid_ks_mode) text="KILLSWITCH_MODE inválido en config ('%s'); usando 'auto'" ;;
        en:log.config_invalid_ks_mode) text="Invalid KILLSWITCH_MODE in config ('%s'); using 'auto'" ;;
        es:log.invalid_ks_boot_race_auto) text="KILLSWITCH_BOOT_RACE_AUTO_DISABLE inválido en config ('%s'); usando 'false'" ;;
        en:log.invalid_ks_boot_race_auto) text="Invalid KILLSWITCH_BOOT_RACE_AUTO_DISABLE in config ('%s'); using 'false'" ;;
        es:log.invalid_coexist_mode) text="COEXIST_MODE inválido en config ('%s'); usando 'auto'" ;;
        en:log.invalid_coexist_mode) text="Invalid COEXIST_MODE in config ('%s'); using 'auto'" ;;
        es:log.coexist_yield) text='Convivencia: kill switch ajeno activo (%s); NetGuard cede el bloqueo (COEXIST_MODE=auto)' ;;
        en:log.coexist_yield) text='Coexistence: another kill switch is active (%s); NetGuard yields blocking (COEXIST_MODE=auto)' ;;
        es:log.coexist_resume) text='Convivencia: NetGuard deja de ceder el bloqueo' ;;
        en:log.coexist_resume) text='Coexistence: NetGuard stops yielding blocking' ;;
        es:log.coexist_state_fail) text='No se pudo escribir %s: el estado de la cesión no se mostrará' ;;
        en:log.coexist_state_fail) text='Could not write %s: the yield state will not be shown' ;;
        es:log.invalid_check_interval) text="CHECK_INTERVAL inválido en config ('%s'); usando 25" ;;
        en:log.invalid_check_interval) text="Invalid CHECK_INTERVAL in config ('%s'); using 25" ;;
        es:log.invalid_backoff) text="RECONNECT_BACKOFF inválido en config ('%s'); usando '5 15 30 60 120'" ;;
        en:log.invalid_backoff) text="Invalid RECONNECT_BACKOFF in config ('%s'); using '5 15 30 60 120'" ;;
        es:log.invalid_ping_timeout) text="PING_TIMEOUT inválido en config ('%s'); usando 3" ;;
        en:log.invalid_ping_timeout) text="Invalid PING_TIMEOUT in config ('%s'); using 3" ;;
        es:log.empty_ping_targets) text="PING_TARGETS vacío en config; usando '1.1.1.1 8.8.8.8'" ;;
        en:log.empty_ping_targets) text="PING_TARGETS is empty in config; using '1.1.1.1 8.8.8.8'" ;;
        es:log.invalid_desktop_notifications) text="DESKTOP_NOTIFICATIONS inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_desktop_notifications) text="Invalid DESKTOP_NOTIFICATIONS in config ('%s'); using 'true'" ;;
        es:log.invalid_allow_lan) text="ALLOW_LAN inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_allow_lan) text="Invalid ALLOW_LAN in config ('%s'); using 'true'" ;;
        es:log.invalid_history_enable) text="EVENT_HISTORY_ENABLE inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_history_enable) text="Invalid EVENT_HISTORY_ENABLE in config ('%s'); using 'true'" ;;
        es:log.invalid_history_max) text="EVENT_HISTORY_MAX_LINES inválido en config ('%s'); usando 5000" ;;
        en:log.invalid_history_max) text="Invalid EVENT_HISTORY_MAX_LINES in config ('%s'); using 5000" ;;
        es:log.invalid_mac_mode) text="MAC_MODE inválido en config ('%s'); usando 'stable'" ;;
        en:log.invalid_mac_mode) text="Invalid MAC_MODE in config ('%s'); using 'stable'" ;;
        es:log.invalid_anonymize) text="ANONYMIZE_NETWORK inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_anonymize) text="Invalid ANONYMIZE_NETWORK in config ('%s'); using 'true'" ;;
        es:log.invalid_rotate_boot) text="ROTATE_MAC_PER_BOOT inválido en config ('%s'); usando 'false'" ;;
        en:log.invalid_rotate_boot) text="Invalid ROTATE_MAC_PER_BOOT in config ('%s'); using 'false'" ;;
        es:log.invalid_rotate_hours) text="ROTATE_MAC_EVERY_HOURS inválido en config ('%s'); usando 0" ;;
        en:log.invalid_rotate_hours) text="Invalid ROTATE_MAC_EVERY_HOURS in config ('%s'); using 0" ;;
        es:log.invalid_scan_mac) text="RANDOMIZE_SCAN_MAC inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_scan_mac) text="Invalid RANDOMIZE_SCAN_MAC in config ('%s'); using 'true'" ;;
        es:log.invalid_spoof_hostname) text="SPOOF_HOSTNAME inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_spoof_hostname) text="Invalid SPOOF_HOSTNAME in config ('%s'); using 'true'" ;;
        es:log.invalid_ipv6_privacy) text="IPV6_PRIVACY inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_ipv6_privacy) text="Invalid IPV6_PRIVACY in config ('%s'); using 'true'" ;;
        es:log.invalid_disable_ipv6) text="DISABLE_IPV6 inválido en config ('%s'); usando 'false'" ;;
        en:log.invalid_disable_ipv6) text="Invalid DISABLE_IPV6 in config ('%s'); using 'false'" ;;
        es:log.invalid_mdns) text="DISABLE_MDNS_ANNOUNCE inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_mdns) text="Invalid DISABLE_MDNS_ANNOUNCE in config ('%s'); using 'true'" ;;
        es:log.invalid_dhcp_ids) text="HARDEN_DHCP_IDENTIFIERS inválido en config ('%s'); usando 'true'" ;;
        en:log.invalid_dhcp_ids) text="Invalid HARDEN_DHCP_IDENTIFIERS in config ('%s'); using 'true'" ;;
        es:log.invalid_avahi) text="DISABLE_AVAHI_SERVICE inválido en config ('%s'); usando 'false'" ;;
        en:log.invalid_avahi) text="Invalid DISABLE_AVAHI_SERVICE in config ('%s'); using 'false'" ;;
        es:log.invalid_netbios) text="DISABLE_NETBIOS_SERVICE inválido en config ('%s'); usando 'false'" ;;
        en:log.invalid_netbios) text="Invalid DISABLE_NETBIOS_SERVICE in config ('%s'); using 'false'" ;;
        es:log.invalid_browser_doh) text="HARDEN_BROWSER_DOH inválido en config ('%s'); usando 'false'" ;;
        en:log.invalid_browser_doh) text="Invalid HARDEN_BROWSER_DOH in config ('%s'); using 'false'" ;;
        es:log.physical_eth_try) text='Intentando activar conexión Ethernet: %s' ;;
        en:log.physical_eth_try) text='Trying to activate Ethernet connection: %s' ;;
        es:log.physical_eth_ok) text='Ethernet activada: %s' ;;
        en:log.physical_eth_ok) text='Ethernet activated: %s' ;;
        es:log.physical_wifi_try) text='Intentando activar conexión Wi-Fi: %s' ;;
        en:log.physical_wifi_try) text='Trying to activate Wi-Fi connection: %s' ;;
        es:log.physical_wifi_ok) text='Wi-Fi activada: %s' ;;
        en:log.physical_wifi_ok) text='Wi-Fi activated: %s' ;;
        es:log.physical_failed) text='No se pudo restablecer ninguna conexión física conocida' ;;
        en:log.physical_failed) text='Could not restore any known physical connection' ;;
        es:log.reconnect_wait) text='Backoff VPN: esperando %ss más antes de reintentar (paso %s)' ;;
        en:log.reconnect_wait) text='VPN backoff: waiting %ss more before retry (step %s)' ;;
        es:log.vpn_try) text='Intentando reconectar la VPN: %s' ;;
        en:log.vpn_try) text='Trying to reconnect VPN: %s' ;;
        es:log.vpn_ok) text='VPN reconectada: %s' ;;
        en:log.vpn_ok) text='VPN reconnected: %s' ;;
        es:log.vpn_failed) text='No se pudo reconectar ninguna VPN conocida todavía; próximo intento en ~%ss' ;;
        en:log.vpn_failed) text='Could not reconnect any known VPN yet; next attempt in ~%ss' ;;
        es:log.rules_fallback) text='%s falló al aplicar %s; usando un método de respaldo seguro' ;;
        en:log.rules_fallback) text='%s failed while applying %s; using a safe fallback method' ;;
        es:log.ks_apply_fail) text='No se pudo aplicar por completo el kill switch; se conserva el bloqueo seguro y se reintentará.' ;;
        en:log.ks_apply_fail) text='The kill switch could not be fully applied; the safe blocking state is retained and will be retried.' ;;
        es:log.heartbeat_fail) text='No se pudo actualizar el latido de supervisión; systemd debería considerar el servicio no saludable' ;;
        en:log.heartbeat_fail) text='The supervision heartbeat could not be updated; systemd should consider the service unhealthy' ;;
        es:log.rotate_fail) text='No se pudo completar la rotación de MAC; revisa el estado de la red' ;;
        en:log.rotate_fail) text='MAC rotation could not be completed; check the network state' ;;
        es:log.endpoint_unresolved) text="VPN_ENDPOINT_OVERRIDE: no se pudo resolver '%s'; excepción de endpoint omitida en esta vuelta" ;;
        en:log.endpoint_unresolved) text="VPN_ENDPOINT_OVERRIDE: could not resolve '%s'; endpoint exception skipped this cycle" ;;
        es:log.ks_boot_race_autodisabled) text='Choque de arranque con el kill switch del cliente VPN: kill switch desactivado automáticamente (KILLSWITCH_BOOT_RACE_AUTO_DISABLE); pendiente volver a automático con "killswitch auto"' ;;
        en:log.ks_boot_race_autodisabled) text='VPN client kill switch boot race: kill switch automatically disabled (KILLSWITCH_BOOT_RACE_AUTO_DISABLE); return to automatic with "killswitch auto" once connected' ;;
        es:log.dns_mismatch) text='DNS_SERVERS (%s) no coincide con el DNS real del sistema (%s); con el kill switch bloqueando, la resolución de nombres puede dejar de funcionar (no es una fuga: falla cerrado). Revisa %s' ;;
        en:log.dns_mismatch) text='DNS_SERVERS (%s) does not match the current system DNS (%s); with the kill switch blocking, name resolution may stop working (this is not a leak: it fails closed). Check %s' ;;
        es:log.ks_blocking) text='Kill switch: bloqueando tráfico saliente (IPv4 e IPv6) que no vaya por la VPN (VPN caída)' ;;
        en:log.ks_blocking) text='Kill switch: blocking outbound IPv4 and IPv6 traffic not going through the VPN (VPN down)' ;;
        es:log.ks_allowing) text='Kill switch: tráfico permitido a través del túnel (%s)' ;;
        en:log.ks_allowing) text='Kill switch: traffic allowed through the tunnel (%s)' ;;
        es:log.ks4_removed) text='Killswitch IPv4 desactivado y reglas retiradas' ;;
        en:log.ks4_removed) text='IPv4 kill switch disabled and rules removed' ;;
        es:log.ks6_removed) text='Killswitch IPv6 desactivado y reglas retiradas' ;;
        en:log.ks6_removed) text='IPv6 kill switch disabled and rules removed' ;;
        es:notify.ks_blocking) text='VPN caída: bloqueando todo el tráfico que no vaya por el túnel.' ;;
        en:notify.ks_blocking) text='VPN down: blocking all traffic that does not go through the tunnel.' ;;
        es:notify.ks_allowing) text='VPN conectada (%s): tráfico protegido por el túnel.' ;;
        en:notify.ks_allowing) text='VPN connected (%s): traffic protected by the tunnel.' ;;
        es:notify.ks_disabled) text='Kill switch desactivado: el tráfico ya no está restringido a la VPN.' ;;
        en:notify.ks_disabled) text='Kill switch disabled: traffic is no longer restricted to the VPN.' ;;
        es:notify.coexist_yield) text='Otro kill switch está activo (%s): NetGuard cede el bloqueo. Con «killswitch on» bloquearía siempre.' ;;
        en:notify.coexist_yield) text='Another kill switch is active (%s): NetGuard yields blocking. "killswitch on" would always block.' ;;
        es:notify.vpn_down) text='VPN caída (sin kill switch activo); reintentando conexión.' ;;
        en:notify.vpn_down) text='VPN down (kill switch not active); retrying connection.' ;;
        es:notify.vpn_up) text='VPN conectada (%s).' ;;
        en:notify.vpn_up) text='VPN connected (%s).' ;;
        es:notify.ks_boot_race) text='VPN NetGuard bloquea todo el tráfico desde el arranque y la VPN aún no conecta: si tu cliente VPN tiene su propio kill switch, puede quedarse sin poder conectar. Solución rápida: "vpn-netguard.sh killswitch off" (protege de nuevo con "killswitch auto" en cuanto conectes), o configura VPN_ENDPOINT_OVERRIDE para que esto no vuelva a pasar.' ;;
        en:notify.ks_boot_race) text='VPN NetGuard has been blocking all traffic since boot and the VPN still has not connected: if your VPN client has its own kill switch, it may be unable to connect. Quick fix: "vpn-netguard.sh killswitch off" (protect again with "killswitch auto" once connected), or set VPN_ENDPOINT_OVERRIDE so this stops happening.' ;;
        es:notify.ks_boot_race_autodisabled) text='VPN NetGuard ha desactivado el kill switch automáticamente: llevaba desde el arranque bloqueando todo el tráfico sin que tu VPN conectara. Ya puedes conectar tu VPN con normalidad. En cuanto esté conectada, vuelve a protegerte con "vpn-netguard.sh killswitch auto".' ;;
        en:notify.ks_boot_race_autodisabled) text='VPN NetGuard has automatically disabled the kill switch: it had been blocking all traffic since boot with no VPN connected. You can now connect your VPN normally. Once it is connected, restore protection with "vpn-netguard.sh killswitch auto".' ;;
        es:log.avahi_stopped) text='Anonimato de red: avahi-daemon (mDNS) detenido y enmascarado; este equipo ya no se anuncia como "%s.local" en la LAN' ;;
        en:log.avahi_stopped) text='Network privacy: avahi-daemon (mDNS) stopped and masked; this host is no longer advertised as "%s.local" on the LAN' ;;
        es:log.netbios_stopped) text='Anonimato de red: nmbd (NetBIOS) detenido y enmascarado' ;;
        en:log.netbios_stopped) text='Network privacy: nmbd (NetBIOS) stopped and masked' ;;
        es:log.browser_firefox) text='Anonimato de red: DoH de Firefox desactivado por política (respeta DNS_SERVERS)' ;;
        en:log.browser_firefox) text='Network privacy: Firefox DoH disabled by policy (respects DNS_SERVERS)' ;;
        es:log.browser_policy_modified) text="No se modifica la política de navegador gestionada porque el fichero fue alterado fuera de VPN NetGuard: %s" ;;
        en:log.browser_policy_modified) text="The managed browser policy was modified outside VPN NetGuard; it is preserved: %s" ;;
        es:log.browser_firefox_existing) text='Anonimato de red: %s ya existe y no lo creamos nosotros; no se toca. Añade "DNSOverHTTPS": {"Enabled": false, "Locked": true} a mano si quieres que Firefox respete DNS_SERVERS' ;;
        en:log.browser_firefox_existing) text='Network privacy: %s already exists and was not created by us; not modified. Add "DNSOverHTTPS": {"Enabled": false, "Locked": true} manually if you want Firefox to respect DNS_SERVERS' ;;
        es:log.browser_chrome) text='Anonimato de red: DoH de Google Chrome desactivado por política' ;;
        en:log.browser_chrome) text='Network privacy: Google Chrome DoH disabled by policy' ;;
        es:log.browser_chromium) text='Anonimato de red: DoH de Chromium desactivado por política' ;;
        en:log.browser_chromium) text='Network privacy: Chromium DoH disabled by policy' ;;
        es:log.browser_policy_conflict) text='Anonimato de red: %s ya existe y no lo creamos nosotros; no se toca' ;;
        en:log.browser_policy_conflict) text='Network privacy: %s already exists and was not created by VPN NetGuard; it is preserved' ;;
        es:log.privacy_applied) text='Anonimato de red: configuración aplicada (MAC: %s, IPv6 desactivado: %s, IPv6 privado: %s, hostname DHCP oculto: %s, identificadores DHCP endurecidos: %s)' ;;
        en:log.privacy_applied) text='Network privacy: configuration applied (MAC: %s, IPv6 disabled: %s, private IPv6: %s, hidden DHCP hostname: %s, hardened DHCP identifiers: %s)' ;;
        es:log.privacy_write_fail) text='No se pudo escribir la configuración de privacidad de red: %s' ;;
        en:log.privacy_write_fail) text='Could not write network privacy configuration: %s' ;;
        es:log.privacy_reload_fail) text='Anonimato de red: configuración escrita en %s pero no se pudo recargar NetworkManager automáticamente; se aplicará en el próximo arranque' ;;
        en:log.privacy_reload_fail) text='Network privacy: configuration written to %s but NetworkManager could not be reloaded automatically; it will apply on next boot' ;;
        es:log.privacy_removed) text='Anonimato de red: configuración retirada, NetworkManager vuelve a su comportamiento de fábrica' ;;
        en:log.privacy_removed) text='Network privacy: configuration removed; NetworkManager restored to its default behavior' ;;
        es:log.rotate_enabled) text='Rotación de MAC por temporizador: activa (cada %sh)' ;;
        es:log.rotate_enable_fail) text='No se pudo activar el temporizador de rotación de MAC: %s' ;;
        en:log.rotate_enable_fail) text='Could not enable the MAC rotation timer: %s' ;;
        en:log.rotate_enabled) text='MAC rotation timer: enabled (every %sh)' ;;
        es:log.rotate_disabled) text='Rotación de MAC por temporizador: no aplica con la configuración actual (MAC_MODE=%s, ROTATE_MAC_EVERY_HOURS=%s); retirando el temporizador si estaba instalado' ;;
        en:log.rotate_disabled) text='MAC rotation timer: not applicable with the current configuration (MAC_MODE=%s, ROTATE_MAC_EVERY_HOURS=%s); removing timer if installed' ;;
        es:log.rotate_reconnect) text='Rotación de MAC: reconectando %s para aplicar la nueva dirección' ;;
        en:log.rotate_reconnect) text='MAC rotation: reconnecting %s to apply the new address' ;;
        es:log.rotate_done) text="Rotación de MAC por temporizador: nueva MAC 'stable' generada" ;;
        en:log.rotate_done) text="MAC rotation timer: new 'stable' MAC generated" ;;
        es:log.boot_blocking) text='Arranque temprano (antes de network-pre.target): aplicando bloqueo básico sin excepción de túnel; %s lo completará en segundos' ;;
        en:log.boot_blocking) text='Early boot (before network-pre.target): applying basic blocking without tunnel exception; %s will complete it within seconds' ;;
        es:log.boot_skip) text='Arranque temprano: protección no solicitada (modo=%s); no se aplica bloqueo' ;;
        en:log.boot_skip) text='Early boot: protection not requested (mode=%s); no blocking applied' ;;
        es:log.wg_zombie) text="WireGuard '%s' (%s): sin handshake reciente (> %ss); túnel zombie" ;;
        en:log.wg_zombie) text="WireGuard '%s' (%s): no recent handshake (> %ss); zombie tunnel" ;;
        es:log.no_physical) text='Sin conexión física activa (ni Ethernet ni Wi-Fi); intentando restablecer' ;;
        en:log.no_physical) text='No active physical connection (neither Ethernet nor Wi-Fi); attempting to restore' ;;
        es:log.vpn_zombie) text="VPN '%s' figura activa según NetworkManager pero sin Internet real (túnel caído/zombie); forzando reconexión" ;;
        en:log.vpn_zombie) text="VPN '%s' is active according to NetworkManager but has no real Internet access (tunnel down or zombie); forcing reconnect" ;;
        es:log.internet_no_response) text='Sin respuesta real de Internet aunque la interfaz reporte actividad' ;;
        en:log.internet_no_response) text='No real Internet response even though the interface reports activity' ;;
        es:log.watchdog_stale) text='Latido de reconciliación obsoleto (%ss); no se avisa al watchdog de systemd (posible cuelgue en curso)' ;;
        en:log.watchdog_stale) text='Reconciliation heartbeat is stale (%ss); watchdog is not notified (possible hang in progress)' ;;
        es:log.daemon_stop) text='Deteniendo vpn-netguard...' ;;
        en:log.daemon_stop) text='Stopping vpn-netguard...' ;;
        es:log.daemon_start) text='Iniciando vpn-netguard (modo kill switch: %s, intervalo respaldo: %ss)' ;;
        en:log.daemon_start) text='Starting vpn-netguard (kill switch mode: %s, backup interval: %ss)' ;;
        es:log.alert_hook_missing) text='ALERT_HOOK está configurado ("%s") pero el comando no se encuentra o no es ejecutable' ;;
        en:log.alert_hook_missing) text='ALERT_HOOK is configured ("%s") but the command cannot be found or is not executable' ;;
        es:log.watchdog_interval) text='CHECK_INTERVAL (%ss) es demasiado alto frente al WatchdogSec de la unidad (%ss): podrían darse reinicios espurios del servicio. Baja CHECK_INTERVAL o sube WatchdogSec.' ;;
        en:log.watchdog_interval) text='CHECK_INTERVAL (%ss) is too high relative to the unit WatchdogSec (%ss): spurious service restarts may occur. Lower CHECK_INTERVAL or increase WatchdogSec.' ;;
        es:log.nmcli_monitor) text='nmcli monitor: %s' ;;
        en:log.nmcli_monitor) text='nmcli monitor: %s' ;;
        es:log.nmcli_ended) text='nmcli monitor finalizó inesperadamente; saliendo para que systemd reinicie el servicio' ;;
        en:log.nmcli_ended) text='nmcli monitor ended unexpectedly; exiting so systemd can restart the service' ;;
        es:log.prom_dir_missing) text='PROMETHEUS_TEXTFILE_DIR (%s) no existe; no se escriben métricas' ;;
        en:log.prom_dir_missing) text='PROMETHEUS_TEXTFILE_DIR (%s) does not exist; metrics will not be written' ;;
        es:log.prom_tmp_fail) text='No se pudo crear el fichero temporal de métricas en %s' ;;
        en:log.prom_tmp_fail) text='Could not create the metrics temporary file in %s' ;;
        es:log.prom_write_fail) text='No se pudo escribir %s' ;;
        en:log.prom_write_fail) text='Could not write %s' ;;
        es:log.activate) text='Activación solicitada: se marca la VPN como deseada y se intenta conectar' ;;
        en:log.activate) text='Activation requested: VPN marked as desired and connection will be attempted' ;;
        es:log.no_vpn_profiles) text='Añade primero una conexión VPN en NetworkManager (nmcli o el gestor de redes); si no se detecta sola, indícala en VPN_CONNECTION dentro de %s' ;;
        en:log.no_vpn_profiles) text='First add a VPN connection in NetworkManager (nmcli or the network manager); if it is not detected automatically, set it in VPN_CONNECTION in %s' ;;
        es:log.deactivate) text='Desactivación solicitada: se quita la marca de VPN deseada y se retira el kill switch' ;;
        en:log.deactivate) text='Deactivation requested: VPN request cleared and kill switch removed' ;;
        es:log.vpn_disconnected) text='VPN desconectada: %s' ;;
        en:log.vpn_disconnected) text='VPN disconnected: %s' ;;
        es:log.vpn_ignored_kept) text="VPN '%s' ignorada (VPN_IGNORE): no se desconecta" ;;
        en:log.vpn_ignored_kept) text="VPN '%s' is ignored (VPN_IGNORE): not disconnected" ;;
        es:log.vpn_all_ignored) text='Todos los perfiles VPN (%s) están en VPN_IGNORE: NetGuard no tiene ninguna VPN que gestionar. Quita alguno de VPN_IGNORE en %s o añade otra conexión VPN' ;;
        en:log.vpn_all_ignored) text='All VPN profiles (%s) are in VPN_IGNORE: NetGuard has no VPN to manage. Remove one from VPN_IGNORE in %s or add another VPN connection' ;;
        es:sdnotify.status) text='Vigilando (kill switch: %s, intervalo: %ss)' ;;
        en:sdnotify.status) text='Monitoring (kill switch: %s, interval: %ss)' ;;
        es:ui.desktop_notification) text='notificación de escritorio' ;;
        en:ui.desktop_notification) text='desktop notification' ;;
        es:ui.warning_missing_exec) text='AVISO: no se encuentra o no es ejecutable' ;;
        en:ui.warning_missing_exec) text='WARNING: missing or not executable' ;;
        es:ui.no_output) text='sin salida' ;;
        en:ui.no_output) text='no output' ;;
        *) text="$key" ;;
    esac
    if (($#)); then
        printf -- "$text" "$@"
    else
        printf '%b' "$text"
    fi
    return 0   # el éxito de ui_t es "hay texto que mostrar", no el de printf
}

ui_field_label() {
    case "$UI_LANGUAGE:$1" in
        es:LANGUAGE) echo 'Idioma de la interfaz' ;; en:LANGUAGE) echo 'Interface language' ;;
        es:KILLSWITCH_MODE) echo 'Modo del kill switch' ;; en:KILLSWITCH_MODE) echo 'Kill switch mode' ;;
        es:KILLSWITCH_BOOT_RACE_AUTO_DISABLE) echo 'Autodesactivar si se atasca al arrancar' ;; en:KILLSWITCH_BOOT_RACE_AUTO_DISABLE) echo 'Auto-disable if stuck at boot' ;;
        es:COEXIST_MODE) echo 'Convivencia con otros kill switch' ;; en:COEXIST_MODE) echo 'Coexistence with other kill switches' ;;
        es:ALLOW_LAN) echo 'Permitir tráfico LAN' ;; en:ALLOW_LAN) echo 'Allow LAN traffic' ;;
        es:ETH_CONNECTION) echo 'Conexión Ethernet forzada' ;; en:ETH_CONNECTION) echo 'Forced Ethernet connection' ;;
        es:WIFI_CONNECTION) echo 'Conexión Wi-Fi forzada' ;; en:WIFI_CONNECTION) echo 'Forced Wi-Fi connection' ;;
        es:VPN_CONNECTION) echo 'Conexión VPN forzada' ;; en:VPN_CONNECTION) echo 'Forced VPN connection' ;;
        es:VPN_PRIORITY) echo 'Prioridad de reconexión VPN' ;; en:VPN_PRIORITY) echo 'VPN reconnection priority' ;;
        es:VPN_IGNORE) echo 'Perfiles VPN a ignorar' ;; en:VPN_IGNORE) echo 'VPN profiles to ignore' ;;
        es:VPN_ENDPOINT_OVERRIDE) echo 'Endpoint VPN manual' ;; en:VPN_ENDPOINT_OVERRIDE) echo 'Manual VPN endpoint' ;;
        es:CHECK_INTERVAL) echo 'Intervalo de comprobación (segundos)' ;; en:CHECK_INTERVAL) echo 'Check interval (seconds)' ;;
        es:RECONNECT_BACKOFF) echo 'Backoff de reconexión VPN' ;; en:RECONNECT_BACKOFF) echo 'VPN reconnection backoff' ;;
        es:PING_TARGETS) echo 'Objetivos de ping' ;; en:PING_TARGETS) echo 'Ping targets' ;;
        es:PING_TIMEOUT) echo 'Timeout de ping (segundos)' ;; en:PING_TIMEOUT) echo 'Ping timeout (seconds)' ;;
        es:LOG_LEVEL) echo 'Nivel de log' ;; en:LOG_LEVEL) echo 'Log level' ;;
        es:DNS_SERVERS) echo 'Servidores DNS permitidos durante el bloqueo' ;; en:DNS_SERVERS) echo 'Allowed DNS servers while blocking' ;;
        es:DESKTOP_NOTIFICATIONS) echo 'Notificaciones de escritorio' ;; en:DESKTOP_NOTIFICATIONS) echo 'Desktop notifications' ;;
        es:ALERT_HOOK) echo 'Comando de alerta' ;; en:ALERT_HOOK) echo 'Alert hook command' ;;
        es:ANONYMIZE_NETWORK) echo 'Anonimato de red activado' ;; en:ANONYMIZE_NETWORK) echo 'Network privacy enabled' ;;
        es:MAC_MODE) echo 'Política de dirección MAC' ;; en:MAC_MODE) echo 'MAC address policy' ;;
        es:MAC_OUI_MASK) echo 'Máscara OUI de fabricante' ;; en:MAC_OUI_MASK) echo 'Vendor OUI mask' ;;
        es:ROTATE_MAC_PER_BOOT) echo 'Rotar MAC en cada arranque' ;; en:ROTATE_MAC_PER_BOOT) echo 'Rotate MAC at boot' ;;
        es:ROTATE_MAC_EVERY_HOURS) echo 'Rotar MAC cada N horas' ;; en:ROTATE_MAC_EVERY_HOURS) echo 'Rotate MAC every N hours' ;;
        es:RANDOMIZE_SCAN_MAC) echo 'MAC aleatoria al escanear Wi-Fi' ;; en:RANDOMIZE_SCAN_MAC) echo 'Random MAC when scanning Wi-Fi' ;;
        es:SPOOF_HOSTNAME) echo 'Ocultar hostname al pedir IP por DHCP' ;; en:SPOOF_HOSTNAME) echo 'Hide hostname when requesting DHCP' ;;
        es:DHCP_HOSTNAME_OVERRIDE) echo 'Nombre genérico para DHCP' ;; en:DHCP_HOSTNAME_OVERRIDE) echo 'Generic DHCP hostname' ;;
        es:HARDEN_DHCP_IDENTIFIERS) echo 'Endurecer identificadores DHCP' ;; en:HARDEN_DHCP_IDENTIFIERS) echo 'Harden DHCP identifiers' ;;
        es:IPV6_PRIVACY) echo 'IPv6 privado/temporal' ;; en:IPV6_PRIVACY) echo 'Private/temporary IPv6' ;;
        es:DISABLE_IPV6) echo 'Desactivar IPv6 por completo' ;; en:DISABLE_IPV6) echo 'Disable IPv6 completely' ;;
        es:DISABLE_MDNS_ANNOUNCE) echo 'Ocultar nombre por mDNS/LLMNR' ;; en:DISABLE_MDNS_ANNOUNCE) echo 'Hide name via mDNS/LLMNR' ;;
        es:DISABLE_AVAHI_SERVICE) echo 'Detener avahi-daemon (mDNS/Bonjour)' ;; en:DISABLE_AVAHI_SERVICE) echo 'Stop avahi-daemon (mDNS/Bonjour)' ;;
        es:DISABLE_NETBIOS_SERVICE) echo 'Detener nmbd (NetBIOS)' ;; en:DISABLE_NETBIOS_SERVICE) echo 'Stop nmbd (NetBIOS)' ;;
        es:HARDEN_BROWSER_DOH) echo 'Bloquear DoH propio del navegador' ;; en:HARDEN_BROWSER_DOH) echo 'Block browser built-in DoH' ;;
        es:PROMETHEUS_TEXTFILE_DIR) echo 'Directorio textfile-collector de Prometheus' ;; en:PROMETHEUS_TEXTFILE_DIR) echo 'Prometheus textfile-collector directory' ;;
        es:EVENT_HISTORY_ENABLE) echo 'Registrar historial de eventos' ;; en:EVENT_HISTORY_ENABLE) echo 'Record event history' ;;
        es:EVENT_HISTORY_MAX_LINES) echo 'Máximo de líneas del historial' ;; en:EVENT_HISTORY_MAX_LINES) echo 'Maximum event-history lines' ;;
        *) echo "$1" ;;
    esac
}

# Explicación breve (qué es y qué hace) de cada opción de configuración: una sola línea, sin
# marcado ni '_' (zenity 3.x podría tomarlo por mnemónico). El panel la pone como segunda línea de
# la etiqueta del campo (panel_field_label) y el menú de texto la muestra, ajustada con ui_wrap, al
# elegir la opción (menu_print_field_help). Una clave sin texto no imprime nada.
ui_field_help() {
    case "$UI_LANGUAGE:$1" in
        es:LANGUAGE) echo 'Idioma del menú, del panel y de los avisos (es o en)' ;; en:LANGUAGE) echo 'Language of the menu, the panel and the notifications (es or en)' ;;
        es:KILLSWITCH_MODE) echo 'Bloqueo sin VPN: auto = con la protección activada, true = siempre, false = nunca' ;; en:KILLSWITCH_MODE) echo 'Blocking without VPN: auto = while protection is on, true = always, false = never' ;;
        es:KILLSWITCH_BOOT_RACE_AUTO_DISABLE) echo 'Si a los 40 s de arrancar bloqueado sigue sin VPN, apaga el kill switch y avisa' ;; en:KILLSWITCH_BOOT_RACE_AUTO_DISABLE) echo 'If still no VPN 40 s after starting blocked, turns the kill switch off and warns' ;;
        es:COEXIST_MODE) echo 'auto cede ante otro cliente VPN con kill switch propio; strict bloquea siempre' ;; en:COEXIST_MODE) echo 'auto yields to another VPN client with its own kill switch; strict always blocks' ;;
        es:ALLOW_LAN) echo 'Permite el tráfico hacia la red local aunque el kill switch bloquee lo demás' ;; en:ALLOW_LAN) echo 'Allows traffic to the local network even while the kill switch blocks the rest' ;;
        es:ETH_CONNECTION) echo 'Nombre exacto del perfil Ethernet de NetworkManager; vacío = autodetectar' ;; en:ETH_CONNECTION) echo 'Exact name of the NetworkManager Ethernet profile; empty = autodetect' ;;
        es:WIFI_CONNECTION) echo 'Nombre exacto del perfil Wi-Fi de NetworkManager; vacío = autodetectar' ;; en:WIFI_CONNECTION) echo 'Exact name of the NetworkManager Wi-Fi profile; empty = autodetect' ;;
        es:VPN_CONNECTION) echo 'Nombre exacto del único perfil VPN que se gestiona; vacío = todos los detectados' ;; en:VPN_CONNECTION) echo 'Exact name of the only VPN profile to manage; empty = all detected ones' ;;
        es:VPN_PRIORITY) echo 'Perfiles VPN en orden de reconexión (el principal primero), separados por espacios' ;; en:VPN_PRIORITY) echo 'VPN profiles in reconnection order (main one first), separated by spaces' ;;
        es:VPN_IGNORE) echo 'Perfiles VPN ajenos que NetGuard no reconecta ni desconecta (patrones con * y ?)' ;; en:VPN_IGNORE) echo 'VPN profiles of other apps never reconnected or disconnected (patterns with * and ?)' ;;
        es:VPN_ENDPOINT_OVERRIDE) echo 'Servidor VPN (host:puerto:proto) si no se detecta; se permite desde el arranque' ;; en:VPN_ENDPOINT_OVERRIDE) echo 'VPN server (host:port:proto) if not detected; allowed from boot' ;;
        es:CHECK_INTERVAL) echo 'Segundos entre comprobaciones de respaldo, además de los eventos de red' ;; en:CHECK_INTERVAL) echo 'Seconds between backup checks, in addition to network events' ;;
        es:RECONNECT_BACKOFF) echo 'Segundos entre reintentos de reconexión VPN; acabada la lista, se repite el último valor' ;; en:RECONNECT_BACKOFF) echo 'Seconds between VPN reconnection attempts; once the list ends, the last value repeats' ;;
        es:PING_TARGETS) echo 'Direcciones a las que se hace ping para comprobar que hay Internet real' ;; en:PING_TARGETS) echo 'Addresses pinged to check that there is real Internet access' ;;
        es:PING_TIMEOUT) echo 'Segundos que se espera la respuesta de cada ping antes de darlo por fallido' ;; en:PING_TIMEOUT) echo 'Seconds to wait for each ping reply before it counts as failed' ;;
        es:LOG_LEVEL) echo 'Detalle del registro: debug (el máximo), info, warn o error (el mínimo)' ;; en:LOG_LEVEL) echo 'Log detail: debug (the most), info, warn or error (the least)' ;;
        es:DNS_SERVERS) echo 'Únicos DNS permitidos durante el bloqueo; vacío = cualquiera en IPv4 y ninguno en IPv6' ;; en:DNS_SERVERS) echo 'Only DNS servers allowed while blocking; empty = any on IPv4, none on IPv6' ;;
        es:DESKTOP_NOTIFICATIONS) echo 'Muestra un aviso de escritorio cuando cambia el estado del kill switch o de la VPN' ;; en:DESKTOP_NOTIFICATIONS) echo 'Shows a desktop notice when the kill switch or VPN state changes' ;;
        es:ALERT_HOOK) echo 'Ruta de un programa propio que recibe urgencia y mensaje de cada aviso; vacío = ninguno' ;; en:ALERT_HOOK) echo 'Path of your own program, run with the urgency and message of each alert; empty = none' ;;
        es:PROMETHEUS_TEXTFILE_DIR) echo 'Carpeta donde la orden check deja las métricas para Prometheus (node exporter)' ;; en:PROMETHEUS_TEXTFILE_DIR) echo 'Folder where the check command leaves metrics for Prometheus (node exporter)' ;;
        es:EVENT_HISTORY_ENABLE) echo 'Guarda en un CSV local cada subida o caída de la VPN y cada cambio del kill switch' ;; en:EVENT_HISTORY_ENABLE) echo 'Saves each VPN up or down and each kill switch change to a local CSV file' ;;
        es:EVENT_HISTORY_MAX_LINES) echo 'Líneas que conserva el historial (las más antiguas se recortan); 0 = sin límite' ;; en:EVENT_HISTORY_MAX_LINES) echo 'Lines the history keeps (the oldest are trimmed); 0 = no limit' ;;
        es:ANONYMIZE_NETWORK) echo 'Interruptor general; en false se retira el anonimato aplicado a NetworkManager' ;; en:ANONYMIZE_NETWORK) echo 'Master switch; false removes the privacy settings applied to NetworkManager' ;;
        es:MAC_MODE) echo 'Dirección MAC: stable = una por red, random = nueva en cada conexión, off = la real' ;; en:MAC_MODE) echo 'MAC address: stable = one per network, random = new on each connection, off = real' ;;
        es:MAC_OUI_MASK) echo 'Avanzado: máscara que conserva el fabricante en la MAC generada; ej. FF:FF:FF:00:00:00' ;; en:MAC_OUI_MASK) echo 'Advanced: mask that keeps the vendor in the generated MAC; e.g. FF:FF:FF:00:00:00' ;;
        es:ROTATE_MAC_PER_BOOT) echo 'Con MAC stable, cambia la MAC de cada red en cada arranque del equipo' ;; en:ROTATE_MAC_PER_BOOT) echo 'With a stable MAC, changes each network MAC at every boot' ;;
        es:ROTATE_MAC_EVERY_HOURS) echo 'Con MAC stable, cambia la MAC cada N horas y reconecta; 0 = no rotar' ;; en:ROTATE_MAC_EVERY_HOURS) echo 'With a stable MAC, changes it every N hours and reconnects; 0 = never' ;;
        es:RANDOMIZE_SCAN_MAC) echo 'Usa una MAC aleatoria al buscar redes Wi-Fi, antes de conectarte a ninguna' ;; en:RANDOMIZE_SCAN_MAC) echo 'Uses a random MAC when scanning for Wi-Fi networks, before connecting to any' ;;
        es:SPOOF_HOSTNAME) echo 'No envía el nombre real del equipo al servidor DHCP de la red' ;; en:SPOOF_HOSTNAME) echo 'Does not send the real computer name to the network DHCP server' ;;
        es:DHCP_HOSTNAME_OVERRIDE) echo 'Con el nombre oculto, se envía este nombre genérico; vacío = no se envía ninguno' ;; en:DHCP_HOSTNAME_OVERRIDE) echo 'With the name hidden, this generic name is sent; empty = none is sent' ;;
        es:HARDEN_DHCP_IDENTIFIERS) echo 'Reduce el seguimiento por identificadores DHCP persistentes (usa los de la MAC)' ;; en:HARDEN_DHCP_IDENTIFIERS) echo 'Reduces tracking by persistent DHCP identifiers (uses MAC-based ones)' ;;
        es:IPV6_PRIVACY) echo 'Direcciones IPv6 temporales y no derivadas de la MAC, para no delatarte por IPv6' ;; en:IPV6_PRIVACY) echo 'Temporary IPv6 addresses not derived from your MAC, so IPv6 cannot give you away' ;;
        es:DISABLE_IPV6) echo 'Avanzado: apaga IPv6 por completo (prevalece sobre IPv6 privado)' ;; en:DISABLE_IPV6) echo 'Advanced: turns IPv6 off completely (takes priority over private IPv6)' ;;
        es:DISABLE_MDNS_ANNOUNCE) echo 'Evita que NetworkManager anuncie este equipo por mDNS y LLMNR en la red' ;; en:DISABLE_MDNS_ANNOUNCE) echo 'Stops NetworkManager from announcing this computer via mDNS and LLMNR' ;;
        es:DISABLE_AVAHI_SERVICE) echo 'Detiene avahi-daemon (Bonjour); puede romper impresoras y Chromecast' ;; en:DISABLE_AVAHI_SERVICE) echo 'Stops avahi-daemon (Bonjour); may break printers and Chromecast' ;;
        es:DISABLE_NETBIOS_SERVICE) echo 'Detiene nmbd (NetBIOS); los equipos Windows pueden dejar de encontrarte por nombre' ;; en:DISABLE_NETBIOS_SERVICE) echo 'Stops nmbd (NetBIOS); Windows computers may no longer find you by name' ;;
        es:HARDEN_BROWSER_DOH) echo 'Desactiva por política DoH en Firefox, Chrome y Chromium; hay que reiniciar el navegador' ;; en:HARDEN_BROWSER_DOH) echo 'Disables DoH in Firefox, Chrome and Chromium by policy; restart the browser' ;;
        *) ;;
    esac
}

ui_init

load_config() {
    LANGUAGE="$(detect_system_language)"
    KILLSWITCH_MODE="auto"      # auto | true | false
    KILLSWITCH_BOOT_RACE_AUTO_DISABLE="false"   # true = autodesactivar el bloqueo si se atasca sin VPN al arrancar
    COEXIST_MODE="auto"         # auto | strict
    ALLOW_LAN="true"
    ETH_CONNECTION=""
    WIFI_CONNECTION=""
    VPN_CONNECTION=""
    VPN_PRIORITY=""             # orden de reconexión, principal primero (ver config)
    VPN_IGNORE=""               # patrones de perfiles VPN ajenos que NetGuard no gestiona (ver config)
    VPN_ENDPOINT_OVERRIDE=""    # host:puerto:proto; IPv6: [2001:db8::1]:443:udp
    CHECK_INTERVAL=25
    RECONNECT_BACKOFF="5 15 30 60 120"   # backoff progresivo, ver comentario en la config
    PING_TARGETS="1.1.1.1 8.8.8.8"
    PING_TIMEOUT=3
    LOG_LEVEL="info"            # debug | info | warn | error
    DNS_SERVERS="1.1.1.1 9.9.9.9"  # solo se permite DNS a estas IPs durante el bloqueo
                                    # "" = se permite DNS a cualquier destino (menos privado)
    DESKTOP_NOTIFICATIONS="true"   # avisos de escritorio (notify-send) al cambiar el estado del killswitch/VPN
    ALERT_HOOK=""                  # comando propio opcional para alertar sin sesión de escritorio (ver config)
    PROMETHEUS_TEXTFILE_DIR=""     # directorio textfile-collector de node_exporter (ver config); vacío = desactivado
    EVENT_HISTORY_ENABLE="true"    # registrar transiciones en $STATE_DIR/history.csv
    EVENT_HISTORY_MAX_LINES=5000   # recorte del historial (ver config)

    # Módulo de anonimato de red (ver comentarios de write_default_config
    # para la explicación de cada clave).
    ANONYMIZE_NETWORK="true"
    MAC_MODE="stable"           # stable | random | off
    MAC_OUI_MASK=""              # avanzado, ver comentario en write_default_config
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

    # La firma se toma ANTES de leer: si el fichero cambia durante la carga,
    # la siguiente comprobación de config_reload_if_changed lo detecta.
    CONFIG_SIG="$(config_signature)"
    if [[ -f "$CONFIG_FILE" ]]; then
        if config_file_is_safe "$CONFIG_FILE"; then
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
        else
            log_t warn log.config_unsafe_file "$CONFIG_FILE" >&2
        fi
    fi
    UI_LANGUAGE="${VPN_NETGUARD_LANGUAGE:-${LANGUAGE:-es}}"
    ui_init

    case "$LOG_LEVEL" in
        debug|info|warn|error) ;;
        *) log_t warn log.config_invalid_level "$LOG_LEVEL" >&2; LOG_LEVEL="info" ;;
    esac
    case "$KILLSWITCH_MODE" in
        auto|true|false) ;;
        *) log_t warn log.config_invalid_ks_mode "$KILLSWITCH_MODE" >&2; KILLSWITCH_MODE="auto" ;;
    esac
    case "$KILLSWITCH_BOOT_RACE_AUTO_DISABLE" in
        true|false) ;;
        *) log_t warn log.invalid_ks_boot_race_auto "$KILLSWITCH_BOOT_RACE_AUTO_DISABLE" >&2; KILLSWITCH_BOOT_RACE_AUTO_DISABLE="false" ;;
    esac
    case "$COEXIST_MODE" in
        auto|strict) ;;
        *) log_t warn log.invalid_coexist_mode "$COEXIST_MODE" >&2; COEXIST_MODE="auto" ;;
    esac
    # Estos valores entran en expresiones aritméticas; se validan, acotan y normalizan antes de usarlos.
    local normalized
    if normalized="$(decimal_normalize_max "$CHECK_INTERVAL" 9223372036854775807)" && (( normalized > 0 )); then
        CHECK_INTERVAL=$normalized
    else
        log_t warn log.invalid_check_interval "$CHECK_INTERVAL" >&2
        CHECK_INTERVAL=25
    fi
    if [[ "$RECONNECT_BACKOFF" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]]; then
        local -a backoff_steps normalized_backoff=()
        local backoff_step normalized_step
        read -ra backoff_steps <<< "$RECONNECT_BACKOFF"
        for backoff_step in "${backoff_steps[@]}"; do
            normalized_step="$(decimal_normalize_max "$backoff_step" 9223372036854775807)" || {
                backoff_steps=()
                break
            }
            if (( normalized_step == 0 )); then
                backoff_steps=()
                break
            fi
            normalized_backoff+=("$normalized_step")
        done
        if (( ${#normalized_backoff[@]} == ${#backoff_steps[@]} && ${#normalized_backoff[@]} > 0 )); then
            RECONNECT_BACKOFF="${normalized_backoff[*]}"
        else
            log_t warn log.invalid_backoff "$RECONNECT_BACKOFF" >&2
            RECONNECT_BACKOFF="5 15 30 60 120"
        fi
    else
        log_t warn log.invalid_backoff "$RECONNECT_BACKOFF" >&2
        RECONNECT_BACKOFF="5 15 30 60 120"
    fi
    if normalized="$(decimal_normalize_max "$PING_TIMEOUT" 9223372036854775807)" && (( normalized > 0 )); then
        PING_TIMEOUT=$normalized
    else
        log_t warn log.invalid_ping_timeout "$PING_TIMEOUT" >&2
        PING_TIMEOUT=3
    fi
    # Un valor de solo espacios cuenta como vacío: `[[ -n ]]` lo daría por puesto y `for x in $LISTA`
    # no recorrería nada (sin reglas de ping ni de DNS, D12).
    [[ "$PING_TARGETS" =~ [^[:space:]] ]] || { log_t warn log.empty_ping_targets >&2; PING_TARGETS="1.1.1.1 8.8.8.8"; }
    [[ "$DNS_SERVERS" =~ [^[:space:]] ]] || DNS_SERVERS=""
    local blank_key
    for blank_key in ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_ENDPOINT_OVERRIDE ALERT_HOOK PROMETHEUS_TEXTFILE_DIR; do
        [[ "${!blank_key}" =~ [^[:space:]] ]] || printf -v "$blank_key" ''
    done
    case "$DESKTOP_NOTIFICATIONS" in
        true|false) ;;
        *) log_t warn log.invalid_desktop_notifications "$DESKTOP_NOTIFICATIONS" >&2; DESKTOP_NOTIFICATIONS="true" ;;
    esac
    case "$ALLOW_LAN" in
        true|false) ;;
        *) log_t warn log.invalid_allow_lan "$ALLOW_LAN" >&2; ALLOW_LAN="true" ;;
    esac
    case "$EVENT_HISTORY_ENABLE" in
        true|false) ;;
        *) log_t warn log.invalid_history_enable "$EVENT_HISTORY_ENABLE" >&2; EVENT_HISTORY_ENABLE="true" ;;
    esac
    if normalized="$(decimal_normalize_max "$EVENT_HISTORY_MAX_LINES" 9223372036854775807)"; then
        EVENT_HISTORY_MAX_LINES=$normalized
    else
        log_t warn log.invalid_history_max "$EVENT_HISTORY_MAX_LINES" >&2
        EVENT_HISTORY_MAX_LINES=5000
    fi

    # Misma validación defensiva que arriba, aplicada a las claves del
    # módulo de anonimato: un fichero de configuración editado a mano con
    # un valor no reconocido cae al valor por defecto (avisando en el log)
    # en vez de propagar una cadena inválida a nmcli / al snippet de
    # NetworkManager.
    case "$MAC_MODE" in
        stable|random|off) ;;
        *) log_t warn log.invalid_mac_mode "$MAC_MODE" >&2; MAC_MODE="stable" ;;
    esac
    case "$ANONYMIZE_NETWORK" in
        true|false) ;;
        *) log_t warn log.invalid_anonymize "$ANONYMIZE_NETWORK" >&2; ANONYMIZE_NETWORK="true" ;;
    esac
    case "$ROTATE_MAC_PER_BOOT" in
        true|false) ;;
        *) log_t warn log.invalid_rotate_boot "$ROTATE_MAC_PER_BOOT" >&2; ROTATE_MAC_PER_BOOT="false" ;;
    esac
    if normalized="$(decimal_normalize_max "$ROTATE_MAC_EVERY_HOURS" 9223372036854775807)"; then
        ROTATE_MAC_EVERY_HOURS=$normalized
    else
        log_t warn log.invalid_rotate_hours "$ROTATE_MAC_EVERY_HOURS" >&2
        ROTATE_MAC_EVERY_HOURS=0
    fi
    case "$RANDOMIZE_SCAN_MAC" in
        true|false) ;;
        *) log_t warn log.invalid_scan_mac "$RANDOMIZE_SCAN_MAC" >&2; RANDOMIZE_SCAN_MAC="true" ;;
    esac
    case "$SPOOF_HOSTNAME" in
        true|false) ;;
        *) log_t warn log.invalid_spoof_hostname "$SPOOF_HOSTNAME" >&2; SPOOF_HOSTNAME="true" ;;
    esac
    case "$IPV6_PRIVACY" in
        true|false) ;;
        *) log_t warn log.invalid_ipv6_privacy "$IPV6_PRIVACY" >&2; IPV6_PRIVACY="true" ;;
    esac
    case "$DISABLE_IPV6" in
        true|false) ;;
        *) log_t warn log.invalid_disable_ipv6 "$DISABLE_IPV6" >&2; DISABLE_IPV6="false" ;;
    esac
    case "$DISABLE_MDNS_ANNOUNCE" in
        true|false) ;;
        *) log_t warn log.invalid_mdns "$DISABLE_MDNS_ANNOUNCE" >&2; DISABLE_MDNS_ANNOUNCE="true" ;;
    esac
    case "$HARDEN_DHCP_IDENTIFIERS" in
        true|false) ;;
        *) log_t warn log.invalid_dhcp_ids "$HARDEN_DHCP_IDENTIFIERS" >&2; HARDEN_DHCP_IDENTIFIERS="true" ;;
    esac
    case "$DISABLE_AVAHI_SERVICE" in
        true|false) ;;
        *) log_t warn log.invalid_avahi "$DISABLE_AVAHI_SERVICE" >&2; DISABLE_AVAHI_SERVICE="false" ;;
    esac
    case "$DISABLE_NETBIOS_SERVICE" in
        true|false) ;;
        *) log_t warn log.invalid_netbios "$DISABLE_NETBIOS_SERVICE" >&2; DISABLE_NETBIOS_SERVICE="false" ;;
    esac
    case "$HARDEN_BROWSER_DOH" in
        true|false) ;;
        *) log_t warn log.invalid_browser_doh "$HARDEN_BROWSER_DOH" >&2; HARDEN_BROWSER_DOH="false" ;;
    esac
    # MAC_OUI_MASK es de formato libre (lo valida NetworkManager, no
    # nosotros) pero no debe contener saltos de línea: rompería la
    # sintaxis del snippet de NetworkManager.conf (una clave por línea).
    MAC_OUI_MASK="${MAC_OUI_MASK//$'\n'/ }"
}

# Firma del fichero de configuración: dispositivo, inodo, tamaño, mtime y
# ctime (el ctime delata una restauración con "cp -p", que conserva el mtime).
# -L sigue enlaces simbólicos. "missing" = no existe o no se puede leer.
config_signature() {
    stat -L -c '%d:%i:%s:%y:%z' -- "$CONFIG_FILE" 2>/dev/null || echo missing
}

# D4: el demonio relee $CONFIG_FILE cuando cambia. Lo llaman sus dos bucles
# (eventos de NetworkManager y periódico), que son procesos con copia propia
# de las variables; cada reconciliación hereda la del bucle que la lanza.
# Con el argumento "announce" (solo el bucle periódico, para que cada cambio
# se registre una sola vez) la recarga se anota en el log; sin él es
# silenciosa. Un fichero ausente o rechazado por config_file_is_safe NO
# sustituye la configuración en uso: caer a los valores por defecto por una
# errata podría debilitar el kill switch. La firma se actualiza igualmente,
# para no repetir el aviso en cada vuelta; al corregir el fichero cambia de
# nuevo y se recarga.
config_reload_if_changed() {
    local announce=0 sig
    [[ "${1:-}" == announce ]] && announce=1
    sig="$(config_signature)"
    [[ "$sig" == "$CONFIG_SIG" ]] && return 0
    if [[ "$sig" == missing ]] || ! config_file_is_safe "$CONFIG_FILE"; then
        CONFIG_SIG="$sig"
        (( announce )) && log_t warn log.config_reload_kept "$CONFIG_FILE"
        return 0
    fi
    if (( announce )); then
        load_config >/dev/null
        log_t info log.config_reloaded "$CONFIG_FILE" "$KILLSWITCH_MODE" "$CHECK_INTERVAL"
        configure_watchdog
        sd_notify --status="$(ui_t sdnotify.status "$KILLSWITCH_MODE" "$CHECK_INTERVAL")"
    else
        load_config >/dev/null 2>&1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Utilidades
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local lvl_num msg_num
    case "$LOG_LEVEL" in
        debug) lvl_num=0 ;; info) lvl_num=1 ;; warn) lvl_num=2 ;; error) lvl_num=3 ;;
        *)     lvl_num=1 ;;
    esac
    case "$level" in
        debug) msg_num=0 ;; info) msg_num=1 ;; warn) msg_num=2 ;; error) msg_num=3 ;;
        *)     msg_num=1 ;;
    esac
    (( msg_num < lvl_num )) && return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level^^}" "$*"
}

# -----------------------------------------------------------------------------
# Notificaciones de escritorio (notify-send). Puntero de estado en
# $STATE_DIR para avisar solo cuando el estado cambia de verdad, nunca en
# cada ciclo de reconciliación. Si algo falta (notify-send, D-Bus, sesión
# gráfica: caso normal en un servidor) no se avisa y no se rompe nada más.
# -----------------------------------------------------------------------------
NOTIFY_STATE_FILE="$STATE_DIR/notify-state"

notify_state_changed() {
    local new="$1" old=""
    [[ -f "$NOTIFY_STATE_FILE" ]] && old="$(<"$NOTIFY_STATE_FILE")"
    [[ "$new" == "$old" ]] && return 1
    mkdir -p "$STATE_DIR" && printf '%s' "$new" > "$NOTIFY_STATE_FILE"
    return 0
}

# Localiza una sesión gráfica (x11/wayland) activa para poder enviarle una
# notificación aunque este proceso corra como root (systemd/pkexec).
notify_find_session() {
    local sid type uid user
    while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        type="$(loginctl show-session "$sid" -p Type --value 2>/dev/null)"
        case "$type" in x11|wayland) ;; *) continue ;; esac
        uid="$(loginctl show-session "$sid" -p User --value 2>/dev/null)"
        user="$(loginctl show-session "$sid" -p Name --value 2>/dev/null)"
        [[ -n "$uid" && -n "$user" ]] || continue
        printf '%s %s\n' "$uid" "$user"
        return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
    return 1
}

# Marca el lanzador .desktop copiado al Escritorio como "de confianza"
# (metadato gio), para que Nautilus/Cinnamon no lo abran bloqueado
# pidiendo "Permitir ejecución" en el primer doble clic. Sin gio no hay
# forma de fijar ese metadato, así que se ignora en silencio (return 0):
# el lanzador queda igual de funcional, solo exige ese primer clic extra.
mark_desktop_trusted() {
    local user="$1" desktop_file="$2"
    command -v gio >/dev/null 2>&1 || return 0
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- gio set "$desktop_file" metadata::trusted true >/dev/null 2>&1
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$user" -- gio set "$desktop_file" metadata::trusted true >/dev/null 2>&1
    else
        return 1
    fi
}

# notify_send <urgency: low|normal|critical> <mensaje>
# El "--" antes de los posicionales evita que notify-send trate un $body que
# empiece por "--" como una opción desconocida (mismo patrón que ui_t/printf).
notify_send() {
    [[ "$DESKTOP_NOTIFICATIONS" == "true" ]] || return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    local urgency="$1" body="$2"

    if [[ $EUID -ne 0 ]]; then
        notify-send -u "$urgency" -a "$TITLE" -i "$ICON_DST" -- "$TITLE" "$body" >/dev/null 2>&1
        return 0
    fi

    command -v loginctl >/dev/null 2>&1 || return 0
    local uid user runtime_dir
    # "return 1" (no 0) en estos dos: significa "todavía no hay a quién
    # avisar" (sin sesión de escritorio, típico justo tras arrancar y antes
    # de iniciar sesión), no "ya está resuelto". Lo aprovecha
    # warn_ks_boot_race_if_stuck() para reintentar en vez de darlo por
    # entregado; el resto de llamadas (vía notify_event) ignoran este valor
    # de retorno, así que no cambia su comportamiento.
    read -r uid user < <(notify_find_session) || return 1
    runtime_dir="/run/user/$uid"
    [[ -S "$runtime_dir/bus" ]] || return 1

    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            notify-send -u "$urgency" -a "$TITLE" -i "$ICON_DST" -- "$TITLE" "$body" >/dev/null 2>&1
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$user" env DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            notify-send -u "$urgency" -a "$TITLE" -i "$ICON_DST" -- "$TITLE" "$body" >/dev/null 2>&1
    fi
    return 0
}

# Alerta para servidores sin sesión de escritorio: si ALERT_HOOK apunta a
# un comando, se ejecuta con la urgencia y el mensaje como argumentos. Con
# timeout de 10s y en segundo plano para que un hook colgado no bloquee la
# reconciliación del demonio.
run_alert_hook() {
    [[ -n "$ALERT_HOOK" ]] || return 0
    local urgency="$1" body="$2"
    if command -v timeout >/dev/null 2>&1; then
        ( timeout 10 "$ALERT_HOOK" "$urgency" "$body" >/dev/null 2>&1 & )
    else
        ( "$ALERT_HOOK" "$urgency" "$body" >/dev/null 2>&1 & )
    fi
}

# notify_event <clave_estado> <urgency> <mensaje> — combina el filtro de
# "solo si cambia" con el envío a los dos canales disponibles (notify-send
# y/o ALERT_HOOK); así cada punto de llamada queda en una sola línea. Este
# es el único sitio que debe comprobar si algún canal está activo antes de
# tocar el fichero de estado (para no perder la próxima transición real si
# el usuario reactiva los avisos más tarde).
notify_event() {
    local state_key="$1" urgency="$2" body="$3"
    # Historial en CSV: dedup PROPIO (record_event_if_changed), a propósito
    # separado de notify_state_changed de abajo. Así el historial registra
    # transiciones reales pase lo que pase con DESKTOP_NOTIFICATIONS/
    # ALERT_HOOK, sin heredar el "no tocar el marcador si no hay canal
    # activo" que sí necesita la lógica de notificaciones (ver su comentario).
    record_event_if_changed "$state_key" "$body"

    [[ "$DESKTOP_NOTIFICATIONS" == "true" || -n "$ALERT_HOOK" ]] || return 0
    notify_state_changed "$state_key" || return 0
    notify_send "$urgency" "$body"
    run_alert_hook "$urgency" "$body"
}

# -----------------------------------------------------------------------------
# Historial local de eventos ($STATE_DIR/history.csv): una línea por
# transición real de estado (VPN arriba/abajo, killswitch activado/
# desactivado), además del journal de systemd, pensado para poder importarlo
# en una hoja de cálculo o graficar disponibilidad con el tiempo. Único
# punto de entrada: record_event_if_changed, llamado desde notify_event.
# -----------------------------------------------------------------------------
record_event_if_changed() {
    [[ "$EVENT_HISTORY_ENABLE" == "true" ]] || return 0
    local key="$1" detail="$2" old=""
    [[ -f "$EVENT_HISTORY_STATE_FILE" ]] && old="$(<"$EVENT_HISTORY_STATE_FILE")"
    [[ "$key" == "$old" ]] && return 0
    record_event "$key" "$detail" || return 1
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    printf '%s' "$key" > "$EVENT_HISTORY_STATE_FILE" || return 1
}

record_event() {
    local event="$1" detail="$2"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    if [[ ! -s "$EVENT_HISTORY_FILE" ]]; then   # -s: un fichero vacío también necesita su cabecera
        printf 'timestamp,epoch,event,detail\n' > "$EVENT_HISTORY_FILE" || return 1
    fi
    detail="${detail//\"/\"\"}"
    printf '%s,%s,%s,"%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" "$event" "$detail" >> "$EVENT_HISTORY_FILE" || return 1
    trim_event_history
}

# Recorta el historial a las EVENT_HISTORY_MAX_LINES líneas más recientes
# (+ cabecera) cuando se supera ese límite, para que no crezca sin límite en
# un equipo que lleve meses encendido con la VPN entrando y saliendo.
trim_event_history() {
    (( EVENT_HISTORY_MAX_LINES > 0 )) || return 0
    local lines
    lines="$(wc -l < "$EVENT_HISTORY_FILE" 2>/dev/null)" || return 0
    (( lines <= 1 || EVENT_HISTORY_MAX_LINES >= lines - 1 )) && return 0
    local tmp
    tmp="$(mktemp "${EVENT_HISTORY_FILE}.XXXXXX" 2>/dev/null)" || return 0
    if { head -n1 "$EVENT_HISTORY_FILE"; tail -n "$EVENT_HISTORY_MAX_LINES" "$EVENT_HISTORY_FILE"; } > "$tmp"; then
        mv -f "$tmp" "$EVENT_HISTORY_FILE"
    else
        rm -f "$tmp"
    fi
}

HAVE_IP6TABLES=0

# Salida de foreign_vpn_scan (ver esa función).
FOREIGN_TUNNELS=() FOREIGN_MARKS=() FOREIGN_KS=()

# Perfiles VPN cuyo endpoint debe quedar exceptuado del bloqueo (ver
# apply_killswitch_rules). En modo "bloqueando" incluye TODOS los perfiles
# conocidos, no solo uno, porque try_reconnect_vpn() los prueba en orden y
# cualquiera podría ser el que finalmente conecte. Cada punto de llamada
# rellena este array justo antes de invocar apply_killswitch_rules.
KS_VPN_CANDIDATES=()

# Perfiles VPN de NetworkManager que VPN_IGNORE excluye de KNOWN_VPN (los
# rellena detect_known_profiles). NetGuard no los reconecta ni los baja.
IGNORED_VPN=()

# Paquete apt que provee cada dependencia; en Mint de escritorio casi
# siempre ya están, pero en un servidor mínimo (sobre todo nmcli/ping) es
# habitual que falten, así que el aviso incluye cómo instalarlo.
dep_apt_package() {
    case "$1" in
        nmcli) echo "network-manager" ;;
        iptables) echo "iptables" ;;
        ping) echo "iputils-ping" ;;
        getent) echo "libc-bin" ;;
        flock) echo "util-linux" ;;
        awk) echo "awk" ;;
        sed) echo "sed" ;;
        grep) echo "grep" ;;
        systemctl) echo "systemd" ;;
        *) echo "$1" ;;
    esac
}

check_dependencies() {
    local dep pkg msg missing=0
    for dep in nmcli iptables ping getent flock awk sed grep systemctl; do
        command -v "$dep" >/dev/null 2>&1 || {
            pkg="$(dep_apt_package "$dep")"
            printf -v msg -- "$(ui_t missing_dependency)" "$dep"; ui_bad "$msg" >&2
            printf -v msg -- "$(ui_t install_dependency)" "$pkg"; echo "  $msg" >&2
            missing=1
        }
    done
    (( missing )) && exit 1
    HAVE_IP6TABLES=0
    command -v ip6tables >/dev/null 2>&1 && HAVE_IP6TABLES=1
    # ip6tables es opcional: sin él esto no es un fallo (doctor lee el código).
    return 0
}

# Entorno fijo de TODA llamada a nmcli: mensajes en inglés (el script los
# interpreta) pero en UTF-8. Con LC_ALL=C nmcli cambia por '?' cualquier carácter
# fuera de ASCII: «Conexión cableada 1» salía «Conexi?n cableada 1» y, al
# devolvérselo a nmcli, ya no coincidía con ningún perfil. C.UTF-8 viene con glibc
# y no traduce; LANGUAGE=C evita que una LANGUAGE del entorno lo traduzca.
NMCLI_ENV=(LC_ALL=C.UTF-8 LANGUAGE=C)

nmcli_c() {
    env "${NMCLI_ENV[@]}" nmcli "$@"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "%s\n" "$(ui_t root_required)" >&2
        exit 1
    fi
}

# Sesión gráfica (X11/Wayland) disponible para este proceso. Se usa para
# elegir entre diálogos zenity o el equivalente de texto, y para no intentar
# abrir una ventana donde no hay dónde mostrarla (típicamente un servidor
# por SSH, aunque zenity esté instalado por cualquier otro motivo).
have_gui_session() {
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

# Sesión SSH detectada (posible servidor remoto). Se usa para reforzar el
# aviso antes de tocar la MAC fuera del instalador ("aplicar anonimato de
# red ahora" desde el panel/menú): un "ssh -X/-Y" reenvía DISPLAY, así que
# have_gui_session() por sí sola no basta para descartar un servidor remoto.
is_ssh_session() {
    [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]
}

# Hay terminal en la entrada y en la salida: solo así se puede "volver" a él desde
# el panel. Un lanzador de escritorio (Terminal=false) no lo tiene.
have_terminal() {
    [[ -t 0 && -t 1 ]]
}

# -----------------------------------------------------------------------------
# Interfaz de arranque: la que abren "vpn-netguard.sh" sin argumentos y el acceso directo del
# escritorio ("launch"): el menú de texto ("terminal") o el panel gráfico ("panel"). Es una
# preferencia de quien ejecuta el programa y vive en su directorio de configuración: cambiarla
# no pide contraseña. Los subcomandos explícitos "menu" y "panel" no la consultan.
# -----------------------------------------------------------------------------
# Ruta del fichero; sin salida y con código 1 si no hay un directorio de configuración
# propio. Con un sudo que conserva HOME, root escribiría ahí ficheros suyos en el perfil
# de otro usuario, así que el directorio ha de ser del usuario efectivo. XDG_CONFIG_HOME
# solo vale si es una ruta absoluta (especificación XDG).
ui_pref_file() {
    local owner_dir base
    if [[ "${XDG_CONFIG_HOME:-}" == /* ]]; then
        owner_dir="$XDG_CONFIG_HOME"; base="$XDG_CONFIG_HOME"
    elif [[ -n "${HOME:-}" ]]; then
        owner_dir="$HOME"; base="$HOME/.config"
    else
        return 1
    fi
    [[ -d "$owner_dir" && -O "$owner_dir" ]] || return 1
    printf '%s/vpn-netguard/start-ui' "$base"
}

# "panel" o "terminal" si se ha elegido una; sin salida si no (fichero ausente, ilegible, con otro
# contenido o que no es un fichero regular: un directorio daría un error de lectura y un FIFO
# colgaría el arranque): entonces manda el origen del arranque (cmd_start_ui).
ui_pref_get() {
    local file value=""
    if file="$(ui_pref_file)" && [[ -f "$file" && -r "$file" ]]; then
        read -r value < "$file" || true   # sin IFS=: recorta espacios y tabuladores de los extremos
        value="${value%$'\r'}"
    fi
    [[ "$value" == panel || "$value" == terminal ]] && printf '%s' "$value"
    return 0
}

# ui_pref_set <panel|terminal>: escribe el fichero entero o nada (temporal + mv).
ui_pref_set() {
    local value="$1" file dir tmp
    [[ "$value" == panel || "$value" == terminal ]] || return 1
    file="$(ui_pref_file)" || return 1
    dir="${file%/*}"
    # El padre con el modo por defecto y solo el directorio propio en 0700 (con -p, -m no
    # alcanza al padre: SC2174). Si ya existía, mkdir falla y basta con que sea un directorio.
    mkdir -p -- "${dir%/*}" 2>/dev/null || return 1
    mkdir -m 0700 -- "$dir" 2>/dev/null || [[ -d "$dir" ]] || return 1
    tmp="$(mktemp "$dir/.start-ui.XXXXXX" 2>/dev/null)" || return 1
    if printf '%s\n' "$value" > "$tmp" 2>/dev/null && mv -fT -- "$tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# Emuladores de terminal donde abrir el menú de texto cuando no hay terminal (el acceso directo
# del escritorio no lo tiene), por orden de preferencia: x-terminal-emulator (la alternativa de
# Debian y derivadas) es el que eligió el sistema. Una línea por emulador, "orden|opción que
# precede a la orden que ejecuta" (vacía si la orden va a continuación): cada uno la toma de una
# forma (xterm -e ..., gnome-terminal -- ..., kitty ...). Sin probar en un escritorio real (§10).
terminal_emulators() {
    cat <<'EMULATORS'
x-terminal-emulator|-e
gnome-terminal|--
konsole|-e
xfce4-terminal|-x
mate-terminal|-x
lxterminal|-e
terminator|-x
alacritty|-e
kitty|
foot|
xterm|-e
EMULATORS
}

# Primer emulador instalado: imprime su línea de terminal_emulators; código 1 si no hay ninguno.
# Con type -P y -x, no con command -v: este da por bueno un fichero sin permiso de ejecución, que
# terminal_open no podría lanzar (el acceso directo no abriría nada y sin aviso).
terminal_emulator_find() {
    local line path
    while IFS= read -r line; do
        path="$(type -P "${line%%|*}")" || continue
        [[ -x "$path" ]] || continue
        printf '%s' "$line"
        return 0
    done < <(terminal_emulators)
    return 1
}

# terminal_open <orden> [argumentos]: ejecuta la orden en una ventana de terminal nueva y vuelve
# cuando el emulador acaba (los que se separan del cliente, como gnome-terminal, en cuanto se
# abre la ventana). Código 1, sin ejecutar nada, si no hay emulador; el estado de la orden no
# cuenta: así 1 solo significa "no hay dónde abrirla".
terminal_open() {
    local found name flag
    found="$(terminal_emulator_find)" || return 1
    name="${found%%|*}"; flag="${found#*|}"
    if [[ -n "$flag" ]]; then
        "$name" "$flag" "$@"
    else
        "$name" "$@"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Ayuda de parseo: nmcli -t escapa los ':' de los nombres como '\:'. Un split
# ingenuo por ':' rompería esos nombres, así que protegemos los caracteres
# escapados con un separador temporal antes de partir la línea.
# -----------------------------------------------------------------------------
_PLACEHOLDER=$'\x01'      # sustituye temporalmente a un ':' escapado ('\:')
_PLACEHOLDER_BS=$'\x02'   # sustituye temporalmente a un '\' escapado ('\\')

# Debe aplicarse SIEMPRE tras proteger primero las barras invertidas
# escapadas de la línea cruda (ver nmcli_protect_escapes): así, cuando se
# llega aquí, cualquier '\' que quede ya solo puede formar parte de un
# '\:' genuino, sin ambigüedad con un nombre que termine en '\'.
nmcli_unescape() {
    local value="${1//$_PLACEHOLDER/:}"
    value="${value//$_PLACEHOLDER_BS/\\}"
    printf '%s' "$value"
}

# Protege, en ese orden, las barras invertidas escapadas ('\\') y los ':'
# escapados ('\:') de una línea cruda de "nmcli -t" antes de partirla por
# ':'. El orden importa: si se protegiera primero '\:' con un nombre que
# termina en '\' (que nmcli representa como '\\' + el ':' real de
# separación), ese '\\:' se confundiría con "barra + dos puntos escapados"
# y se tragaría el separador real, fusionando dos campos en uno.
nmcli_protect_escapes() {
    local value="${1//\\\\/$_PLACEHOLDER_BS}"
    printf '%s' "${value//\\:/$_PLACEHOLDER}"
}

# -----------------------------------------------------------------------------
# Detección de perfiles conocidos y estado activo (nombres reales, no fijos).
# bond/team/bridge/vlan se tratan como "física" además de 802-3-ethernet:
# poco comunes en un portátil, pero habituales en un servidor (bonding para
# redundancia, bridge en hosts de virtualización KVM/libvirt).
# -----------------------------------------------------------------------------
# vpn_is_ignored <perfil>: 0 si VPN_IGNORE lo excluye. Patrones tipo shell
# (* ? [ ]) separados por espacio o coma, contra el nombre exacto; un espacio
# dentro de un nombre se escribe '?'. VPN_CONNECTION nunca se ignora (lo
# explícito gana). Evalúa los patrones en cada llamada: no depende de que
# detect_known_profiles haya corrido.
vpn_is_ignored() {
    local name="$1" pat
    local -a pats
    [[ -n "$VPN_IGNORE" && -n "$name" ]] || return 1
    [[ -n "$VPN_CONNECTION" && "$name" == "$VPN_CONNECTION" ]] && return 1
    IFS=$', \t\n' read -r -a pats <<< "$VPN_IGNORE"
    for pat in "${pats[@]}"; do
        # shellcheck disable=SC2053  # el patrón sin comillas es lo que se quiere
        [[ -n "$pat" && "$name" == $pat ]] && return 0
    done
    return 1
}

# La VPN conectada (ACTIVE_VPN) es un perfil que VPN_IGNORE excluye: su túnel
# se acepta, pero NetGuard no la baja ni la reconecta.
active_vpn_is_ignored() {
    [[ -n "$ACTIVE_VPN" ]] && vpn_is_ignored "$ACTIVE_VPN"
}

detect_known_profiles() {
    KNOWN_ETH=()
    KNOWN_WIFI=()
    KNOWN_VPN=()
    IGNORED_VPN=()

    local raw name type
    while IFS= read -r raw; do
        [[ -z "$raw" ]] && continue
        raw="$(nmcli_protect_escapes "$raw")"
        IFS=: read -r name type <<< "$raw"
        name="$(nmcli_unescape "$name")"
        type="$(nmcli_unescape "$type")"
        [[ -z "$name" ]] && continue
        case "$type" in
            802-3-ethernet|bond|team|bridge|vlan) KNOWN_ETH+=("$name") ;;
            802-11-wireless) KNOWN_WIFI+=("$name") ;;
            vpn|wireguard)
                if vpn_is_ignored "$name"; then IGNORED_VPN+=("$name"); else KNOWN_VPN+=("$name"); fi ;;
        esac
    done < <(nmcli_c -t -e yes -f NAME,TYPE connection show 2>/dev/null)

    # Permitir forzar nombres concretos desde la configuración
    [[ -n "$ETH_CONNECTION" ]] && KNOWN_ETH=("$ETH_CONNECTION")
    [[ -n "$WIFI_CONNECTION" ]] && KNOWN_WIFI=("$WIFI_CONNECTION")
    [[ -n "$VPN_CONNECTION" ]] && KNOWN_VPN=("$VPN_CONNECTION")
    return 0
}

detect_active_state() {
    ACTIVE_ETH=""
    ACTIVE_WIFI=""
    ACTIVE_VPN=""
    VPN_IFACE=""
    VPN_TYPE=""
    PHYS_IFACE=""

    local raw name type device
    while IFS= read -r raw; do
        [[ -z "$raw" ]] && continue
        raw="$(nmcli_protect_escapes "$raw")"
        IFS=: read -r name type device <<< "$raw"
        name="$(nmcli_unescape "$name")"
        type="$(nmcli_unescape "$type")"
        device="$(nmcli_unescape "$device")"
        [[ -z "$name" ]] && continue
        case "$type" in
            802-3-ethernet|bond|team|bridge|vlan)
                ACTIVE_ETH="$name"
                PHYS_IFACE="$device"
                ;;
            802-11-wireless)
                ACTIVE_WIFI="$name"
                [[ -z "$PHYS_IFACE" ]] && PHYS_IFACE="$device"
                ;;
            vpn|wireguard)
                ACTIVE_VPN="$name"
                VPN_IFACE="$device"
                VPN_TYPE="$type"
                ;;
        esac
    done < <(nmcli_c -t -e yes -f NAME,TYPE,DEVICE connection show --active 2>/dev/null)
}

# -----------------------------------------------------------------------------
# Estado deseado ("¿el usuario quiere la VPN activa?"), usado por el modo
# KILLSWITCH_MODE=auto. Se controla con `activate` / `deactivate` (lo usa
# el panel gráfico), no simplemente por tener un perfil VPN guardado.
# -----------------------------------------------------------------------------
want_vpn_active() {
    [[ -f "$STATE_FILE" ]] || return 1
    # "!= off", no "== on": un STATE_FILE vacío (versiones anteriores del
    # script lo creaban con "touch", sin contenido) sigue contando como
    # "activado" y no se apaga solo al actualizar el script.
    [[ "$(cat "$STATE_FILE" 2>/dev/null)" != "off" ]]
}

# "Deactivate" explícito, distinto de "nunca se ha activado" (STATE_FILE
# ausente): lo consulta vpn_reconnect_wanted() para que ningún modo
# reconecte la VPN a espaldas de un "Desactivar" ya pedido por el usuario.
vpn_explicitly_deactivated() {
    [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "off" ]]
}

# El panel (sin root) lee "wanted" y el forzado del kill switch para su cabecera
# de estado. El demonio corre con UMask=0027 y los crearía 0640, ilegibles para
# el usuario: el panel mostraría "auto" aunque el kill switch esté forzado. Solo
# contienen on/off/auto (y nombres de cliente en coexist-yield), así que se
# dejan en 0644 al escribirlos y al arrancar.
state_files_make_readable() {
    local f
    for f in "$STATE_FILE" "$KILLSWITCH_OVERRIDE_FILE" "$COEXIST_YIELD_FILE"; do
        [[ -f "$f" ]] && chmod 0644 "$f" 2>/dev/null
    done
    return 0
}

mark_vpn_wanted() {
    mkdir -p "$STATE_DIR"
    printf 'on\n' > "$STATE_FILE" || return
    state_files_make_readable
}

unmark_vpn_wanted() {
    mkdir -p "$STATE_DIR"
    printf 'off\n' > "$STATE_FILE" || return
    state_files_make_readable
}

# -----------------------------------------------------------------------------
# Reconexión
# -----------------------------------------------------------------------------
# "nmcli connection up" espera por defecto el timeout propio de
# NetworkManager (habitualmente ~90s) antes de rendirse con un perfil
# guardado pero inalcanzable (red fuera de rango, servidor VPN caído). Sin
# límite propio, un solo perfil así congelaría la reconciliación —síncrona
# en el arranque del servicio y en cada evento/ciclo— antes de probar el
# siguiente candidato. Se acota con "timeout" si está disponible.
NMCLI_UP_TIMEOUT=20

nmcli_up() {
    if command -v timeout >/dev/null 2>&1; then
        env "${NMCLI_ENV[@]}" timeout "$NMCLI_UP_TIMEOUT" nmcli connection up "$1" >/dev/null 2>&1
    else
        nmcli_c connection up "$1" >/dev/null 2>&1
    fi
}

try_reconnect_physical() {
    local name
    for name in "${KNOWN_ETH[@]}"; do
        log_t info log.physical_eth_try "$name"
        if nmcli_up "$name"; then
            log_t info log.physical_eth_ok "$name"
            return 0
        fi
    done
    for name in "${KNOWN_WIFI[@]}"; do
        log_t info log.physical_wifi_try "$name"
        if nmcli_up "$name"; then
            log_t info log.physical_wifi_ok "$name"
            return 0
        fi
    done
    log_t error log.physical_failed
    return 1
}

# Backoff progresivo (ver RECONNECT_BACKOFF en la config). Estado en memoria:
# solo tiene sentido dentro del proceso demonio de larga duración
# (daemon_main); una invocación puntual de CLI/panel siempre empieza sin
# backoff, que es lo correcto para una acción manual.
VPN_BACKOFF_STEP=0
VPN_BACKOFF_LAST_ATTEMPT=0

vpn_backoff_seconds() {
    local -a steps
    read -ra steps <<< "$RECONNECT_BACKOFF"
    local idx=$(( VPN_BACKOFF_STEP - 1 ))
    (( idx < 0 )) && idx=0
    (( idx >= ${#steps[@]} )) && idx=$(( ${#steps[@]} - 1 ))
    printf '%s\n' "${steps[idx]}"
}

vpn_backoff_reset() {
    VPN_BACKOFF_STEP=0
    VPN_BACKOFF_LAST_ATTEMPT=0
}

vpn_backoff_register_failure() {
    local -a steps
    read -ra steps <<< "$RECONNECT_BACKOFF"
    (( VPN_BACKOFF_STEP < ${#steps[@]} )) && ((VPN_BACKOFF_STEP++))
    VPN_BACKOFF_LAST_ATTEMPT=$(date +%s)
}

# Aplica VPN_PRIORITY sobre KNOWN_VPN: primero los nombres listados en
# VPN_PRIORITY que existan de verdad entre los perfiles conocidos, en ese
# orden; admite perfiles con espacios buscando la coincidencia conocida más
# larga. Después se añaden los perfiles no priorizados en el orden de nmcli.
ordered_known_vpn() {
    local -a ordered=()
    local name p already remaining best
    remaining="$VPN_PRIORITY"
    while [[ -n "${remaining//[[:space:]]/}" ]]; do
        remaining="${remaining#"${remaining%%[![:space:]]*}"}"
        best=""
        for p in "${KNOWN_VPN[@]}"; do
            [[ -n "$p" ]] || continue
            if [[ "$remaining" == "$p" || "$remaining" == "$p "* ]]; then
                if (( ${#p} > ${#best} )); then
                    best="$p"
                fi
            fi
        done
        if [[ -n "$best" ]]; then
            name="$best"
            remaining="${remaining:${#best}}"
        else
            name="${remaining%%[[:space:]]*}"
            remaining="${remaining:${#name}}"
        fi
        already=0
        for p in "${ordered[@]}"; do
            [[ "$p" == "$name" ]] && { already=1; break; }
        done
        [[ $already -eq 0 ]] && for p in "${KNOWN_VPN[@]}"; do
            [[ "$p" == "$name" ]] && { ordered+=("$p"); break; }
        done
    done
    for p in "${KNOWN_VPN[@]}"; do
        already=0
        for name in "${ordered[@]}"; do
            [[ "$p" == "$name" ]] && { already=1; break; }
        done
        [[ $already -eq 0 ]] && ordered+=("$p")
    done
    printf '%s\n' "${ordered[@]}"
}

try_reconnect_vpn() {
    if [[ $VPN_BACKOFF_STEP -gt 0 ]]; then
        local wait_s elapsed
        wait_s="$(vpn_backoff_seconds)"
        elapsed=$(( $(date +%s) - VPN_BACKOFF_LAST_ATTEMPT ))
        if (( elapsed < wait_s )); then
            log_t debug log.reconnect_wait "$(( wait_s - elapsed ))" "$VPN_BACKOFF_STEP"
            return 1
        fi
    fi

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        log_t info log.vpn_try "$name"
        if nmcli_up "$name"; then
            log_t info log.vpn_ok "$name"
            vpn_backoff_reset
            return 0
        fi
    done < <(ordered_known_vpn)

    vpn_backoff_register_failure
    log_t warn log.vpn_failed "$(vpn_backoff_seconds)"
    return 1
}

# -----------------------------------------------------------------------------
# Kill switch (iptables / ip6tables)
# -----------------------------------------------------------------------------
killswitch_should_be_active() {
    case "$(cat "$KILLSWITCH_OVERRIDE_FILE" 2>/dev/null)" in
        on) return 0 ;;
        off) return 1 ;;
    esac
    case "$KILLSWITCH_MODE" in
        false) return 1 ;;
        true) return 0 ;;
        auto) [[ ${#KNOWN_VPN[@]} -gt 0 ]] && want_vpn_active && ! coexist_yielding ;;
        *) return 1 ;;
    esac
}

set_killswitch_override() {
    local value="$1"
    mkdir -p "$STATE_DIR" || return 1
    printf '%s\n' "$value" > "$KILLSWITCH_OVERRIDE_FILE"
    state_files_make_readable
    rm -f "$KS_BOOT_RACE_MARKER_FILE"
}

clear_killswitch_override() {
    rm -f "$KILLSWITCH_OVERRIDE_FILE" "$KS_BOOT_RACE_MARKER_FILE"
}

disable_killswitch_locked() {
    remove_killswitch_if_present && set_killswitch_override off
}

# Separa "¿hay que bloquear tráfico?" (killswitch_should_be_active) de
# "¿hay que intentar mantener la VPN conectada?" (esta función). Coinciden
# en modo=true/auto; en modo=false no hay bloqueo pero sí debe reconectar,
# tal como documenta KILLSWITCH_MODE en write_default_config(). Un
# "deactivate" explícito (STATE_FILE=off) gana siempre, en cualquier modo:
# si no, con modo=true/false la VPN volvería a conectarse sola justo
# después de que el usuario la desconectara a propósito.
vpn_reconnect_wanted() {
    vpn_explicitly_deactivated && return 1
    case "$KILLSWITCH_MODE" in
        true)  return 0 ;;
        false) [[ ${#KNOWN_VPN[@]} -gt 0 ]] ;;
        auto)  [[ ${#KNOWN_VPN[@]} -gt 0 ]] && want_vpn_active ;;
        *)     return 1 ;;
    esac
}

# Envuelven iptables/ip6tables para esperar (hasta 5s) el lock de xtables en
# vez de fallar al instante si otro proceso (ufw, Docker, este mismo script
# desde otra instancia) lo tiene tomado justo en ese momento. Único punto de
# invocación real: el resto del script llama siempre a "ipt"/"ipt6".
ipt()  { iptables  -w 5 "$@"; }
ipt6() { ip6tables -w 5 "$@"; }

# ensure_jump <función_ipt> <binario_restore> <cadena>
#
# Deja un único salto OUTPUT -> <cadena> en la posición 1 sin ningún instante
# sin él. Antes se borraban todos los saltos y se reinsertaba uno: ventana sin
# bloqueo en cada reconciliación y disputa de la posición 1 con otros
# cortafuegos.
#   - Ya es la primera regla y no está repetido: no se escribe nada.
#   - No existe: se inserta.
#   - Repetido o en otra posición: transacción atómica de *-restore (-D de cada
#     salto + -I en la posición 1). Si OUTPUT cambió entre la lectura y la
#     transacción, esta se revierte entera.
#   - Sin *-restore, o con la transacción revertida: se inserta primero y se
#     borran después los saltos antiguos por número, de mayor a menor y solo si
#     esa posición sigue siendo el salto (nunca se borra una regla ajena).
ensure_jump() {
    local ipt_fn="$1" restore_bin="$2" chain="$3"
    local jump="-A OUTPUT -j $chain" out line n=0 count=0 first=0 i pos off
    local -a stale=()

    if ! out="$("$ipt_fn" -S OUTPUT 2>/dev/null)"; then
        # OUTPUT ilegible (lock de xtables...): sin ver la posición no se reordena.
        "$ipt_fn" -C OUTPUT -j "$chain" 2>/dev/null && return 0
        "$ipt_fn" -I OUTPUT 1 -j "$chain"
        return
    fi
    while IFS= read -r line; do
        [[ "$line" == "-A OUTPUT "* ]] || continue
        n=$((n + 1))
        [[ "$line" == "$jump" ]] || continue
        count=$((count + 1))
        if (( n == 1 )); then first=1; else stale+=("$n"); fi
    done <<< "$out"

    (( count == 1 && first == 1 )) && return 0
    if (( count == 0 )); then
        "$ipt_fn" -I OUTPUT 1 -j "$chain"
        return
    fi
    if command -v "$restore_bin" >/dev/null 2>&1; then
        {
            echo "*filter"
            for (( i = 0; i < count; i++ )); do echo "-D OUTPUT -j $chain"; done
            echo "-I OUTPUT 1 -j $chain"
            echo "COMMIT"
        } | "$restore_bin" --wait=5 --noflush 2>/dev/null && return 0
    fi
    (( first == 1 )) || "$ipt_fn" -I OUTPUT 1 -j "$chain" || return 1
    off=$(( 1 - first ))
    for (( i = ${#stale[@]} - 1; i >= 0; i-- )); do
        pos=$(( stale[i] + off ))
        [[ "$("$ipt_fn" -S OUTPUT "$pos" 2>/dev/null)" == "$jump" ]] || continue
        "$ipt_fn" -D OUTPUT "$pos" || return 1
    done
}

ensure_chain() {
    ipt -N "$CHAIN_NAME" 2>/dev/null || true
    ensure_jump ipt iptables-restore "$CHAIN_NAME"
}

ensure_chain6() {
    [[ $HAVE_IP6TABLES -eq 1 ]] || return 0
    ipt6 -N "$CHAIN_NAME_V6" 2>/dev/null || true
    ensure_jump ipt6 ip6tables-restore "$CHAIN_NAME_V6"
}

# -----------------------------------------------------------------------------
# Terceros (NordVPN, ProtonVPN y otros túneles): detección SOLO de lectura.
# foreign_vpn_scan rellena, para quien decida (COEXIST_MODE, status, doctor):
#   FOREIGN_TUNNELS  interfaces de túnel activas que NetworkManager no
#                    gestiona (la VPN activa de NM, VPN_IFACE, no cuenta).
#   FOREIGN_MARKS    fwmark del tráfico propio de un cliente (NordVPN 0xe1f1).
#   FOREIGN_KS       kill switch ajeno ACTIVO verificado: nordvpn | protonvpn.
# Para ampliar la lista: un patrón en foreign_iface_is_tunnel o una
# comprobación en foreign_vpn_scan. Basada en documentación y reportes públicos
# (PLAN, sección 3): no está probada con los clientes instalados. Leer
# iptables exige root; sin él no se detecta el cortafuegos de NordVPN (sin error).
# -----------------------------------------------------------------------------
foreign_iface_is_tunnel() {
    case "$1" in
        tun[0-9]*|tap[0-9]*|wg[0-9]*|ppp[0-9]*|proton[0-9]*|nordlynx|nordtun) return 0 ;;
    esac
    return 1
}

# Llamar después de detect_active_state (usa VPN_IFACE). SYS_NET_DIR existe para
# los tests. Con el argumento "boot" no se consulta NetworkManager (aún no corre
# en el arranque temprano, ver boot_killswitch_main): sin esa lectura no se
# detecta el kill switch de ProtonVPN.
foreign_vpn_scan() {
    FOREIGN_TUNNELS=()
    FOREIGN_MARKS=()
    FOREIGN_KS=()
    local sysdir="${SYS_NET_DIR:-/sys/class/net}"
    local path iface state fn out line name
    local nord_seen=0 nord_drop=0 proton=0
    local nord_re='--comment "?nordvpn"?( |$)'
    local boot=0
    [[ "${1:-}" == boot ]] && boot=1

    for path in "$sysdir"/*; do
        [[ -e "$path" ]] || continue
        iface="${path##*/}"
        case "$iface" in
            pvpnksintrf0|ipv6leakintrf0) proton=1; continue ;;
        esac
        foreign_iface_is_tunnel "$iface" || continue
        [[ -n "${VPN_IFACE:-}" && "$iface" == "$VPN_IFACE" ]] && continue
        state="$(cat "$path/operstate" 2>/dev/null)"
        case "$state" in down|notpresent|lowerlayerdown) continue ;; esac
        FOREIGN_TUNNELS+=("$iface")
        case "$iface" in nordlynx|nordtun) nord_seen=1 ;; esac
    done

    command -v nordvpn >/dev/null 2>&1 && nord_seen=1
    # NordVPN marca sus reglas con "--comment nordvpn"; un DROP/REJECT con esa
    # marca en OUTPUT es su kill switch.
    for fn in ipt ipt6; do
        [[ "$fn" == ipt6 && $HAVE_IP6TABLES -ne 1 ]] && continue
        out="$("$fn" -S OUTPUT 2>/dev/null)" || continue
        while IFS= read -r line; do
            [[ "$line" == "-A OUTPUT "* && "$line" =~ $nord_re ]] || continue
            nord_seen=1
            if [[ "$line" == *" -j DROP" || "$line" == *" -j REJECT"* ]]; then nord_drop=1; fi
        done <<< "$out"
    done

    # ProtonVPN: kill switch sin reglas de firewall, con conexiones "dummy" de NM.
    if (( ! boot )); then
        while IFS= read -r name; do
            case "$name" in pvpn-killswitch*|pvpn-ipv6leak-protection*) proton=1 ;; esac
        done < <(nmcli_c -t -f NAME connection show --active 2>/dev/null)
    fi

    if (( nord_seen )); then FOREIGN_MARKS+=(0xe1f1); fi
    if (( nord_drop )); then FOREIGN_KS+=(nordvpn); fi
    if (( proton )); then FOREIGN_KS+=(protonvpn); fi
    return 0
}

# -----------------------------------------------------------------------------
# Convivencia (COEXIST_MODE, PLAN K4).
#   coexist_scan [boot] auto: foreign_vpn_scan [boot]. strict: vacía FOREIGN_* y
#                      no ejecuta nada. Llamar tras detect_active_state y antes
#                      de decidir o aplicar reglas ("boot": sin NetworkManager).
#   coexist_pass_rules auto: una regla por línea que deja pasar (RETURN) cada
#                      túnel y marca ajenos. strict: nada. Los valores entran
#                      tal cual en el texto de iptables-restore, así que solo se
#                      aceptan formas estrictas y el resto se descarta.
# Cesión del bloqueo (solo la política automática, sin forzado):
#   coexist_yielding       hay un kill switch ajeno activo y COEXIST_MODE=auto.
#                          Solo la consulta la rama auto de
#                          killswitch_should_be_active; un forzado y
#                          KILLSWITCH_MODE=true nunca ceden.
#   killswitch_is_yielding NetGuard cede AHORA: sin el kill switch ajeno la
#                          política automática bloquearía.
#   coexist_sync_yield     tras coexist_scan: mantiene COEXIST_YIELD_FILE (lo
#                          leen status, check y menús sin root) y avisa solo al
#                          empezar, cambiar de cliente o terminar la cesión.
#   coexist_yield_load     para quien no escanea: llena FOREIGN_KS desde ese
#                          fichero.
# -----------------------------------------------------------------------------
coexist_scan() {
    FOREIGN_TUNNELS=() FOREIGN_MARKS=() FOREIGN_KS=()
    [[ "$COEXIST_MODE" == auto ]] || return 0
    foreign_vpn_scan "$@"
}

coexist_pass_rules() {
    [[ "$COEXIST_MODE" == auto ]] || return 0
    local item
    for item in "${FOREIGN_TUNNELS[@]}"; do
        [[ "$item" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$ ]] && printf -- '-o %s -j RETURN\n' "$item"
    done
    for item in "${FOREIGN_MARKS[@]}"; do
        [[ "$item" =~ ^0x[0-9a-fA-F]{1,8}$ ]] && printf -- '-m mark --mark %s -j RETURN\n' "$item"
    done
    return 0
}

coexist_yielding() {
    [[ "$COEXIST_MODE" == auto && ${#FOREIGN_KS[@]} -gt 0 ]]
}

# Debe coincidir con la rama auto de killswitch_should_be_active (T208).
killswitch_is_yielding() {
    [[ "$(killswitch_override_value)" == auto && "$KILLSWITCH_MODE" == auto ]] || return 1
    [[ ${#KNOWN_VPN[@]} -gt 0 ]] && want_vpn_active && coexist_yielding
}

coexist_sync_yield() {
    local want="" have=""
    if killswitch_is_yielding; then want="${FOREIGN_KS[*]}"; fi
    if [[ -f "$COEXIST_YIELD_FILE" ]]; then have="$(head -n1 "$COEXIST_YIELD_FILE" 2>/dev/null)"; fi
    [[ "$want" == "$have" ]] && return 0
    if [[ -z "$want" ]]; then
        rm -f "$COEXIST_YIELD_FILE"
        log_t info log.coexist_resume
        return 0
    fi
    if ! { mkdir -p "$STATE_DIR" && printf '%s\n' "$want" > "$COEXIST_YIELD_FILE"; } 2>/dev/null; then
        log_t error log.coexist_state_fail "$COEXIST_YIELD_FILE"
        return 0
    fi
    state_files_make_readable
    log_t warn log.coexist_yield "$want"
    notify_event yield normal "$(ui_t notify.coexist_yield "$want")"
}

coexist_yield_load() {
    FOREIGN_KS=()
    [[ "$COEXIST_MODE" == auto && -f "$COEXIST_YIELD_FILE" ]] || return 0
    local line name
    local -a names
    line="$(head -n1 "$COEXIST_YIELD_FILE" 2>/dev/null)"
    read -ra names <<< "$line"
    for name in "${names[@]}"; do
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && FOREIGN_KS+=("$name")
    done
    return 0
}

have_root() { [[ $EUID -eq 0 ]]; }

# Sección de convivencia de status y doctor (quien la llama imprime la
# cabecera). Lee en vivo con foreign_vpn_scan, también en strict: sin leer no
# habría nada que recomendar. Requiere detect_known_profiles y
# detect_active_state previos y deja intactas las FOREIGN_* del llamador.
# Devuelve 1 si emite alguna recomendación.
print_coexist_status() {
    local -a FOREIGN_TUNNELS=() FOREIGN_MARKS=() FOREIGN_KS=() names=()
    local line others fix rc=0 blocking=0
    foreign_vpn_scan
    names=("${FOREIGN_KS[@]}" "${FOREIGN_TUNNELS[@]}")
    ui_row "$(ui_t status.l_coexist_mode)" "$COEXIST_MODE"
    ui_row "$(ui_t status.l_coexist_tunnels)" "${FOREIGN_TUNNELS[*]:-$(ui_t none)}"
    ui_row "$(ui_t status.l_coexist_marks)" "${FOREIGN_MARKS[*]:-$(ui_t none)}"
    ui_row "$(ui_t status.l_coexist_ks)" "${FOREIGN_KS[*]:-$(ui_t none)}"
    have_root || ui_note warn "$(ui_t status.coexist_noroot)"
    if (( ${#names[@]} + ${#FOREIGN_MARKS[@]} == 0 )); then
        ui_note ok "$(ui_t status.coexist_none)"
        return 0
    fi
    killswitch_should_be_active && blocking=1
    printf -v others '%s, ' "${names[@]}"; others="${others%, }"
    if [[ "$COEXIST_MODE" == strict ]]; then
        if (( blocking && ${#names[@]} )); then
            printf -v line -- "$(ui_t status.coexist_rec_strict)" "$others"; ui_note warn "$line"; rc=1
        fi
    elif (( ${#FOREIGN_KS[@]} )); then
        if killswitch_is_yielding; then
            printf -v line -- "$(ui_t status.coexist_yielding)" "${FOREIGN_KS[*]}"; ui_note ok "$line"
        elif (( blocking )); then
            fix='KILLSWITCH_MODE="auto"'
            [[ "$(killswitch_override_value)" == on ]] && fix='killswitch auto'
            printf -v line -- "$(ui_t status.coexist_rec_forced)" "$fix" "${FOREIGN_KS[*]}"; ui_note warn "$line"; rc=1
        fi
    fi
    if [[ " ${FOREIGN_KS[*]} " == *" protonvpn "* && ${#FOREIGN_TUNNELS[@]} -eq 0 && -z "${ACTIVE_VPN:-}" ]]; then
        ui_note warn "$(ui_t status.coexist_proton_stuck)"; rc=1
    fi
    return "$rc"
}

# ks_restore_apply <cadena> <función_ipt> <binario_restore> <regla...>
#
# Sustituye TODO el contenido de <cadena> (vacía + repuebla + DROP final) en
# una única transacción atómica de iptables-restore/ip6tables-restore, en
# vez de la secuencia "flush + una llamada a iptables por regla" de antes.
# Motivo: cada llamada a iptables es, en sí misma, atómica, pero entre DOS
# llamadas separadas (p. ej. el flush y la siguiente regla) el kernel ya ha
# confirmado el estado intermedio; con una cadena enganchada a OUTPUT, ese
# instante intermedio (cadena vacía = sin bloqueo) es real y se repite en
# cada reconciliación. --noflush deja intacto el resto de cadenas/tablas
# (OUTPUT salvo su regla de salto, INPUT, reglas de ufw/Docker...); dentro
# del lote sí se incluye un "-F <cadena>" explícito, así que la cadena en sí
# queda completamente sustituida, pero como una sola transacción: nunca hay
# un instante en que esté vacía mientras se reconstruye. Si el binario
# *-restore no está disponible o el lote falla por cualquier motivo, se cae
# al método anterior (no atómico, pero funcional) para no dejar el kill
# switch sin aplicar.
ks_restore_apply() {
    local chain="$1" ipt_fn="$2" restore_bin="$3"; shift 3
    if command -v "$restore_bin" >/dev/null 2>&1; then
        {
            echo "*filter"
            echo ":${chain} - [0:0]"
            echo "-F ${chain}"
            local r
            for r in "$@"; do echo "-A ${chain} ${r}"; done
            echo "-A ${chain} -j DROP"
            echo "COMMIT"
        } | "$restore_bin" --wait=5 --noflush 2>/dev/null && return 0
        log_t warn log.rules_fallback "$restore_bin" "$chain"
    fi
    "$ipt_fn" -F "$chain" || return 1
    local r
    for r in "$@"; do
        # shellcheck disable=SC2086
        "$ipt_fn" -A "$chain" $r || return 1
    done
    "$ipt_fn" -A "$chain" -j DROP || return 1
}

# Extrae "host puerto proto" del perfil VPN indicado (OpenVPN / WireGuard).
# Es un intento "best effort": para VPNs poco habituales (L2TP/IPsec, PPTP)
# usa VPN_ENDPOINT_OVERRIDE en el archivo de configuración.
parse_endpoint_spec() {
    local spec="$1" default_port="$2" default_proto="$3" host port proto
    if [[ "$spec" =~ ^\[([^]]+)\]:([0-9]+)(:([[:alnum:]_-]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        proto="${BASH_REMATCH[4]:-$default_proto}"
    elif [[ "$spec" =~ ^\[([^]]+)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="$default_port"
        proto="$default_proto"
    elif valid_ipv6_literal "$spec"; then
        host="$spec"
        port="$default_port"
        proto="$default_proto"
    elif [[ "$spec" =~ ^(.+):([0-9]+):([[:alpha:]][[:alnum:]_-]*)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        proto="${BASH_REMATCH[3]}"
    elif [[ "$spec" =~ ^(.+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        proto="$default_proto"
    elif [[ "$spec" == *:* ]]; then
        return 1
    else
        host="$spec"
        port="$default_port"
        proto="$default_proto"
    fi
    if [[ -z "$host" ]]; then
        return 1
    fi
    port="$(decimal_normalize_max "$port" 65535)" || return 1
    (( port > 0 )) || return 1
    [[ "$proto" =~ ^(tcp|udp)$ ]] || return 1
    printf '%s %s %s\n' "$host" "$port" "$proto"
}

get_vpn_endpoints() {
    local vpn_name="$1" full token
    full="$(nmcli_c connection show "$vpn_name" 2>/dev/null)"

    while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        parse_endpoint_spec "$token" 1194 udp
    done < <(printf '%s\n' "$full" | sed -nE 's/.*remote[[:space:]]*=[[:space:]]*([^,[:space:]]+).*/\1/p')

    while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        parse_endpoint_spec "$token" 51820 udp
    done < <(printf '%s\n' "$full" | sed -nE 's/.*endpoint[[:space:]]*[=:][[:space:]]*([^,[:space:]]+).*/\1/ip')
}

looks_like_ipv6() {
    [[ "$1" == *:* ]]
}

valid_ipv4_literal() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local -a octets
    IFS=. read -r -a octets <<< "$1"
    (( ${#octets[@]} == 4 )) || return 1
    local octet
    for octet in "${octets[@]}"; do
        decimal_normalize_max "$octet" 255 >/dev/null || return 1
    done
}

valid_ipv6_literal() {
    local value="$1" left right side part total=0 double=0 part_index saw_ipv4=0
    local -a parts=()
    [[ "$value" == *:* && "$value" != *%* && "$value" != *[^0-9A-Fa-f:.]* ]] || return 1
    if [[ "$value" == *::* ]]; then
        [[ "$value" != *::*::* ]] || return 1
        double=1
        left="${value%%::*}"
        right="${value#*::}"
    else
        left="$value"
        right=""
    fi
    for side in "$left" "$right"; do
        [[ -z "$side" ]] && continue
        IFS=: read -r -a parts <<< "$side"
        for part_index in "${!parts[@]}"; do
            part="${parts[$part_index]}"
            [[ -n "$part" ]] || return 1
            if [[ "$part" == *.* ]]; then
                (( part_index == ${#parts[@]} - 1 )) || return 1
                valid_ipv4_literal "$part" || return 1
                saw_ipv4=1
                (( total += 2 ))
            else
                (( saw_ipv4 == 0 )) || return 1
                [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                (( total++ ))
            fi
        done
    done
    if (( double )); then
        (( total < 8 ))
    else
        (( total == 8 ))
    fi
}

resolve_ipv4() {
    local host="$1"
    if valid_ipv4_literal "$host"; then
        echo "$host"
    elif command -v timeout >/dev/null 2>&1; then
        timeout 3 getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
    else
        getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
    fi
}

resolve_ipv6() {
    local host="$1" resolved
    if valid_ipv6_literal "$host"; then
        printf '%s\n' "$host"
        return 0
    fi
    if looks_like_ipv6 "$host"; then
        return 1
    elif command -v timeout >/dev/null 2>&1; then
        resolved="$(timeout 3 getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1 {print $1; exit}')"
    else
        resolved="$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1 {print $1; exit}')"
    fi
    [[ -n "$resolved" ]] && printf '%s\n' "$resolved"
}


# apply_killswitch_rules [<interfaz_tunel>]
#
# Los perfiles VPN cuyo endpoint debe quedar exceptuado del bloqueo se
# indican en el array global KS_VPN_CANDIDATES (rellenado por quien llama a
# esta función), en vez de recibir un único nombre por parámetro como antes.
# Esto permite, en modo "bloqueando" (ver apply_killswitch_blocking), abrir
# el endpoint de TODOS los perfiles VPN conocidos —no solo el primero—
# porque try_reconnect_vpn() los prueba todos en orden y cualquiera de
# ellos podría ser el que finalmente conecte.
#
# Si no se pasa interfaz de túnel, el tráfico solo puede salir por las
# excepciones explícitas (LAN, DNS, DHCP, endpoint(s) VPN) => bloqueo total.
#
# Las excepciones acaban en RETURN, no en ACCEPT: un ACCEPT cierra el recorrido
# de OUTPUT y se saltaría las reglas de ufw, Docker u otro kill switch que
# vengan después de este salto; RETURN solo sale de esta cadena y deja decidir
# a las demás reglas y a la política de OUTPUT. Lo que no encaja en ninguna
# excepción cae en el DROP final que añade ks_restore_apply (fail-closed).
apply_killswitch_rules() {
    local tun_iface="${1:-}"
    local -a rules=()

    rules+=("-o lo -j RETURN")
    rules+=("-m conntrack --ctstate ESTABLISHED,RELATED -j RETURN")

    # DHCP: necesario para obtener IP antes de que exista túnel
    rules+=("-p udp --dport 67:68 -j RETURN")

    # DNS: por defecto se permite a cualquier destino para poder resolver el
    # host de la VPN (esto puede filtrar consultas DNS fuera del túnel si la
    # VPN cae). Si defines DNS_SERVERS en la config, se restringe solo a esas IPs.
    # Las entradas IPv6 se descartan aquí y se aplican en apply_killswitch_rules6.
    if [[ -n "$DNS_SERVERS" ]]; then
        local dns_ip
        for dns_ip in $DNS_SERVERS; do
            looks_like_ipv6 "$dns_ip" && continue
            rules+=("-d $dns_ip -p udp --dport 53 -j RETURN")
            rules+=("-d $dns_ip -p tcp --dport 53 -j RETURN")
        done
    else
        rules+=("-p udp --dport 53 -j RETURN")
        rules+=("-p tcp --dport 53 -j RETURN")
    fi

    # ICMP echo-request solo hacia PING_TARGETS: lo justo para que
    # check_internet_reachable() funcione mientras el killswitch bloquea, sin
    # abrir ping hacia cualquier destino. Los objetivos IP literales (el caso
    # habitual) no necesitan la excepción de DNS de arriba: resolve_ipv4()
    # los reconoce por regex y no hace ninguna consulta de red.
    local ping_target ping_ip
    for ping_target in $PING_TARGETS; do
        looks_like_ipv6 "$ping_target" && continue
        ping_ip="$(resolve_ipv4 "$ping_target")"
        [[ -n "$ping_ip" ]] && rules+=("-d $ping_ip -p icmp --icmp-type echo-request -j RETURN")
    done

    if [[ "$ALLOW_LAN" == "true" ]]; then
        local net
        # 169.254.0.0/16 (enlace local/APIPA) incluido para paridad con el
        # fe80::/10 que apply_killswitch_rules6 ya permite en IPv6.
        for net in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 169.254.0.0/16; do
            rules+=("-d $net -j RETURN")
        done
    fi

    # Permitir el propio tráfico de establecimiento/keepalive de cada perfil
    # VPN candidato (ver comentario de cabecera de esta función).
    local vpn_name host port proto ip
    for vpn_name in "${KS_VPN_CANDIDATES[@]}"; do
        [[ -z "$vpn_name" ]] && continue
        while read -r host port proto; do
            [[ -z "$host" ]] && continue
            ip="$(resolve_ipv4 "$host")"
            [[ -n "$ip" ]] && rules+=("-d $ip -p $proto --dport $port -j RETURN")
        done < <(get_vpn_endpoints "$vpn_name")
    done

    if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]]; then
        host=""; port=""; proto=""; ip=""
        if read -r host port proto < <(parse_endpoint_spec "$VPN_ENDPOINT_OVERRIDE" 1194 udp); then
            ip="$(resolve_ipv4 "$host")"
            if [[ -n "$ip" ]]; then
                rules+=("-d $ip -p $proto --dport $port -j RETURN")
            else
                log_t warn log.endpoint_unresolved "$host"
            fi
        else
            log_t warn log.endpoint_unresolved "$VPN_ENDPOINT_OVERRIDE"
        fi
    fi

    # Túneles y marcas de otros clientes VPN (solo COEXIST_MODE=auto).
    mapfile -t -O "${#rules[@]}" rules < <(coexist_pass_rules)

    # Tráfico que sale por el túnel: esta cadena no lo restringe
    if [[ -n "$tun_iface" ]]; then
        rules+=("-o $tun_iface -j RETURN")
    fi

    # Todas las reglas se han calculado arriba sin tocar iptables todavía;
    # se aplican ahora en una única transacción atómica (ver ks_restore_apply):
    # la cadena nunca queda vacía ni a medio reconstruir, y el DROP final
    # siempre acaba siendo la última regla.
    ensure_chain || return 1
    ks_restore_apply "$CHAIN_NAME" ipt iptables-restore "${rules[@]}"
}

# Réplica en IPv6. La mayoría de VPN domésticas no enrutan IPv6, así que el
# criterio por defecto es: si el killswitch está activo, IPv6 se bloquea por
# completo salvo loopback/LAN/túnel/endpoint(s) VPN (evita que el tráfico
# "se salte" la VPN usando IPv6 mientras el IPv4 va protegido). El endpoint
# se exceptúa igual que en apply_killswitch_rules (mismos
# KS_VPN_CANDIDATES/VPN_ENDPOINT_OVERRIDE): sin esto, un servidor VPN solo
# alcanzable por IPv6 (o resuelto por AAAA antes que por A) nunca podría
# conectar con este chain activo. Si el host no tiene AAAA (lo habitual),
# no se añade ninguna regla aquí y el caso IPv4 ya queda cubierto aparte.
apply_killswitch_rules6() {
    [[ $HAVE_IP6TABLES -eq 1 ]] || return 0
    if [[ "$DISABLE_IPV6" == "true" ]]; then
        remove_killswitch6_if_present
        return $?
    fi
    local tun_iface="${1:-}"
    local -a rules=()

    rules+=("-o lo -j RETURN")
    rules+=("-m conntrack --ctstate ESTABLISHED,RELATED -j RETURN")
    # DHCPv6
    rules+=("-p udp --dport 546:547 -j RETURN")
    # Vecinos / enlace local, necesario para el funcionamiento básico de IPv6
    rules+=("-s fe80::/10 -j RETURN")
    # Echo-request: réplica IPv6 de la regla ICMP de apply_killswitch_rules,
    # restringida igual a PING_TARGETS (no a cualquier destino, para no
    # contradecir el "bloquear IPv6 casi por completo" de la cabecera).
    # Sin esto, check_internet_reachable() fallaría siempre que PING_TARGETS
    # incluya un objetivo IPv6 y el bloqueo esté activo.
    local ping_target6 ping_ip6
    for ping_target6 in $PING_TARGETS; do
        looks_like_ipv6 "$ping_target6" || continue
        ping_ip6="$(resolve_ipv6 "$ping_target6")"
        [[ -n "$ping_ip6" ]] && rules+=("-d $ping_ip6 -p icmpv6 --icmpv6-type echo-request -j RETURN")
    done

    # Réplica IPv6 de la excepción de DNS. A diferencia de IPv4, si
    # DNS_SERVERS está vacío NO se abre DNS a cualquier destino: el
    # criterio aquí es bloquear IPv6 casi por completo (ver cabecera de
    # esta función), y la resolución para levantar la VPN ya la cubre la
    # excepción de IPv4.
    if [[ -n "$DNS_SERVERS" ]]; then
        local dns_ip6
        for dns_ip6 in $DNS_SERVERS; do
            looks_like_ipv6 "$dns_ip6" || continue
            rules+=("-d $dns_ip6 -p udp --dport 53 -j RETURN")
            rules+=("-d $dns_ip6 -p tcp --dport 53 -j RETURN")
        done
    fi

    if [[ "$ALLOW_LAN" == "true" ]]; then
        rules+=("-d fc00::/7 -j RETURN")
        rules+=("-d fe80::/10 -j RETURN")
    fi

    # Endpoint(s) VPN por IPv6 (ver cabecera de esta función). No se avisa
    # si un host no resuelve por AAAA: es el caso normal de una VPN
    # solo-IPv4 y ya queda cubierto por la excepción equivalente en
    # apply_killswitch_rules.
    local vpn_name6 host port proto ip6
    for vpn_name6 in "${KS_VPN_CANDIDATES[@]}"; do
        [[ -z "$vpn_name6" ]] && continue
        while read -r host port proto; do
            [[ -z "$host" ]] && continue
            ip6="$(resolve_ipv6 "$host")"
            [[ -n "$ip6" ]] && rules+=("-d $ip6 -p $proto --dport $port -j RETURN")
        done < <(get_vpn_endpoints "$vpn_name6")
    done
    if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]]; then
        host=""; port=""; proto=""; ip6=""
        if read -r host port proto < <(parse_endpoint_spec "$VPN_ENDPOINT_OVERRIDE" 1194 udp); then
            ip6="$(resolve_ipv6 "$host")"
            [[ -n "$ip6" ]] && rules+=("-d $ip6 -p $proto --dport $port -j RETURN")
        else
            log_t warn log.endpoint_unresolved "$VPN_ENDPOINT_OVERRIDE"
        fi
    fi

    # Túneles y marcas de otros clientes VPN (solo COEXIST_MODE=auto).
    mapfile -t -O "${#rules[@]}" rules < <(coexist_pass_rules)

    if [[ -n "$tun_iface" ]]; then
        rules+=("-o $tun_iface -j RETURN")
    fi

    # Mismo criterio que apply_killswitch_rules (excepciones con RETURN, DROP
    # final): aplicación atómica, la cadena nunca queda vacía ni a medio
    # reconstruir (ver ks_restore_apply).
    ensure_chain6 || return 1
    ks_restore_apply "$CHAIN_NAME_V6" ipt6 ip6tables-restore "${rules[@]}"
}

# Servidores DNS que NetworkManager/systemd-resolved tienen configurados
# AHORA MISMO para la interfaz física activa (no los de DNS_SERVERS, que
# solo son la lista de destinos permitidos por el killswitch). Se usa
# únicamente para avisar de un posible desajuste, nunca para decidir el
# bloqueo en sí. "resolvectl" es lo habitual en Mint (systemd-resolved); si
# no está, se cae a la propiedad IP4/IP6.DNS que reporta el propio nmcli.
system_dns_servers() {
    [[ -n "$PHYS_IFACE" ]] || return 0
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns "$PHYS_IFACE" 2>/dev/null | sed -E 's/^[^:]+:\s*//'
    else
        { nmcli_c -g IP4.DNS device show "$PHYS_IFACE" 2>/dev/null
          nmcli_c -g IP6.DNS device show "$PHYS_IFACE" 2>/dev/null; } | tr '|' ' '
    fi | tr ' ' '\n' | sed '/^[[:space:]]*$/d'
}

# Avisa (una vez, no en cada reconciliación) si DNS_SERVERS no incluye
# ninguno de los servidores DNS que el sistema usa de verdad: ver el aviso
# junto a DNS_SERVERS en write_default_config para el porqué.
DNS_MISMATCH_WARNED=0

warn_if_dns_mismatch() {
    [[ -n "$DNS_SERVERS" ]] || return 0
    local sys_dns d s match=0
    sys_dns="$(system_dns_servers)"
    [[ -z "$sys_dns" ]] && return 0
    for d in $DNS_SERVERS; do
        while IFS= read -r s; do
            [[ "$s" == "$d" ]] && { match=1; break 2; }
        done <<< "$sys_dns"
    done
    if [[ $match -eq 0 ]]; then
        if [[ $DNS_MISMATCH_WARNED -eq 0 ]]; then
            log_t warn log.dns_mismatch "$DNS_SERVERS" "$(tr '\n' ' ' <<< "$sys_dns")" "$CONFIG_FILE"
            DNS_MISMATCH_WARNED=1
        fi
    else
        DNS_MISMATCH_WARNED=0
    fi
}

apply_killswitch_blocking() {
    # Con KNOWN_VPN vacío (KILLSWITCH_MODE=true o "killswitch on" sin
    # perfiles guardados) igualmente se aplica el bloqueo básico, sin
    # excepción de endpoint VPN: KILLSWITCH_MODE=true no admite un no-op
    # silencioso solo porque no haya perfiles. Los perfiles de VPN_IGNORE
    # también: su cliente debe poder conectar mientras NetGuard bloquea.
    KS_VPN_CANDIDATES=("${KNOWN_VPN[@]}" "${IGNORED_VPN[@]}")
    local rc=0
    apply_killswitch_rules "" || rc=1
    apply_killswitch_rules6 "" || rc=1
    if (( rc != 0 )); then
        log_t error log.ks_apply_fail
        return 1
    fi
    log_t warn log.ks_blocking
    notify_event blocking critical "$(ui_t notify.ks_blocking)"
    warn_if_dns_mismatch
}

# Usa "$ACTIVE_VPN" (el perfil realmente conectado, según detect_active_state),
# no el primer perfil conocido, para que la excepción del túnel corresponda
# siempre al servidor real cuando hay varios perfiles VPN guardados.
apply_killswitch_allowing() {
    [[ -z "$ACTIVE_VPN" ]] && return 0
    KS_VPN_CANDIDATES=("$ACTIVE_VPN")
    local rc=0
    apply_killswitch_rules "$VPN_IFACE" || rc=1
    apply_killswitch_rules6 "$VPN_IFACE" || rc=1
    if (( rc != 0 )); then
        log_t error log.ks_apply_fail
        return 1
    fi
    log_t debug log.ks_allowing "$VPN_IFACE"
    notify_event allowing normal "$(ui_t notify.ks_allowing "$ACTIVE_VPN")"
}

remove_killswitch6_if_present() {
    [[ $HAVE_IP6TABLES -eq 1 ]] || return 0
    local found=0
    while ipt6 -C OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null; do
        found=1
        ipt6 -D OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null || return 1
    done
    (( found )) || return 0
    ipt6 -F "$CHAIN_NAME_V6" 2>/dev/null || return 1
    ipt6 -X "$CHAIN_NAME_V6" 2>/dev/null || return 1
    log_t info log.ks6_removed
}

remove_killswitch_if_present() {
    local removed=0 rc4=0 rc6=0 found4=0 found6=0
    while ipt -C OUTPUT -j "$CHAIN_NAME" 2>/dev/null; do
        found4=1
        ipt -D OUTPUT -j "$CHAIN_NAME" 2>/dev/null || { rc4=1; break; }
    done
    if (( found4 && rc4 == 0 )); then
        ipt -F "$CHAIN_NAME" 2>/dev/null || rc4=1
        if (( rc4 == 0 )); then
            ipt -X "$CHAIN_NAME" 2>/dev/null || rc4=1
        fi
    fi
    if (( found4 && rc4 == 0 )); then
        log_t info log.ks4_removed
        removed=1
    fi

    if [[ $HAVE_IP6TABLES -eq 1 ]]; then
        while ipt6 -C OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null; do
            found6=1
            ipt6 -D OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null || { rc6=1; break; }
        done
        if (( found6 && rc6 == 0 )); then
            ipt6 -F "$CHAIN_NAME_V6" 2>/dev/null || rc6=1
            if (( rc6 == 0 )); then
                ipt6 -X "$CHAIN_NAME_V6" 2>/dev/null || rc6=1
            fi
        fi
        if (( found6 && rc6 == 0 )); then
            log_t info log.ks6_removed
            removed=1
        fi
    fi
    # Al ceder, el aviso de cesión (coexist_sync_yield) ya lo explica: "desactivado"
    # sería falso, otro kill switch sigue restringiendo el tráfico.
    [[ $removed -eq 1 ]] && ! killswitch_is_yielding && notify_event off normal "$(ui_t notify.ks_disabled)"
    [[ $rc4 -eq 0 && $rc6 -eq 0 ]]
}
# Envuelve cualquier mutación de iptables con el mismo flock que usa
# reconcile_sync/reconcile_async, para que la reconciliación del demonio y
# una acción manual (activate/deactivate, killswitch on/off/auto) nunca
# se solapen y dejen el cortafuegos a medio aplicar.
with_killswitch_lock() {
    (
        flock 9 || exit 1
        "$@"
    ) 9>"$LOCK_FILE"
}

# -----------------------------------------------------------------------------
# Control único del kill switch (subcomando "killswitch on|off|auto|status").
#   on   -> forzado ON : bloquea siempre, también tras reiniciar.
#   off  -> forzado OFF: sin bloqueo hasta volver a "auto".
#   auto -> borra el forzado: manda KILLSWITCH_MODE de la configuración.
# Las tres variantes cambian el forzado y las reglas bajo el mismo flock que
# usa la reconciliación del demonio. No reinician el servicio: el demonio
# relee el forzado en cada reconciliación.
# -----------------------------------------------------------------------------
killswitch_override_value() {
    local value
    value="$(cat "$KILLSWITCH_OVERRIDE_FILE" 2>/dev/null)"
    case "$value" in
        on|off) printf '%s\n' "$value" ;;
        *) printf 'auto\n' ;;
    esac
}

# Aplica YA la política efectiva (killswitch_should_be_active): bloquea o
# deja pasar el túnel si debe estar activo y retira las reglas si no. No
# reconecta la VPN (eso lo hace la reconciliación). Llamar con el flock tomado.
killswitch_apply_policy_now() {
    detect_known_profiles
    detect_active_state
    coexist_scan
    coexist_sync_yield
    if killswitch_should_be_active; then
        if [[ -n "$ACTIVE_VPN" ]]; then
            apply_killswitch_allowing
        else
            apply_killswitch_blocking
        fi
    else
        remove_killswitch_if_present
    fi
}

killswitch_force_on_locked() {
    set_killswitch_override on || return 1
    killswitch_apply_policy_now
}

killswitch_set_auto_locked() {
    clear_killswitch_override
    killswitch_apply_policy_now
}

# =============================================================================
# ANONIMATO DE RED: camufla este equipo frente a la red local (MAC, IPv6,
# nombre de equipo). No usa iptables ni proceso propio: se implementa como
# un "snippet" de NetworkManager.conf(5)/conf.d, el mecanismo nativo y
# documentado para esto (nmcli(1)), en vez de "ip link set address" o
# macchanger, porque: (1) NetworkManager reaplica la política él solo en
# cada conexión, sin depender de que nuestro daemon llegue a tiempo; (2) al
# ser un valor por DEFECTO global, se aplica igual a redes ya guardadas y a
# cualquiera futura sin tocar nada; (3) es 100% reversible borrando el
# fichero y recargando NetworkManager.
# =============================================================================

# Traduce MAC_MODE (la palabra que ve el usuario) a la palabra clave real
# de NetworkManager para "*.cloned-mac-address". "off" no es una palabra
# clave de NetworkManager: significa "no escribas nada", así se deja la
# MAC de fábrica sin fijar ningún valor por defecto global.
mac_mode_keyword() {
    case "$MAC_MODE" in
        stable) echo "stable" ;;
        random) echo "random" ;;
        *)      echo "" ;;
    esac
}

# Genera el contenido del snippet de NetworkManager a partir de la
# configuración actual (ya cargada por load_config) y lo instala en
# $NM_PRIVACY_CONF con los permisos correctos.
#
# NOTA: como valor por defecto global, NetworkManager.conf(5) exige el
# número real de la propiedad en vez de los alias de texto de nmcli; por
# eso "ipv6.addr-gen-mode=1" (stable-privacy, RFC 7217) y no la cadena
# "stable-privacy". Excepción: "*.cloned-mac-address" sí admite
# "stable"/"random" tal cual (blog de Thomas Haller/GNOME, ArchWiki,
# Fedora Magazine, con este mismo snippet).
write_privacy_conf() {
    local mac_kw tmp
    mac_kw="$(mac_mode_keyword)"
    tmp="$(mktemp "${NM_PRIVACY_CONF}.XXXXXX")" || return 1

    {
        if [[ "$UI_LANGUAGE" == "en" ]]; then
            echo "# Automatically generated by vpn-netguard.sh (network privacy module)."
            echo "# DO NOT EDIT MANUALLY: this file is overwritten whenever the configuration is applied."
            echo "# Adjust the corresponding options in $CONFIG_FILE (or from the panel)."
            echo "# Then run: vpn-netguard.sh apply-privacy"
        else
            echo "# Generado automáticamente por vpn-netguard.sh (módulo de anonimato de red)."
            echo "# NO EDITAR A MANO: se sobrescribe cada vez que se aplica la configuración."
            echo "# Ajusta las opciones correspondientes en $CONFIG_FILE (o desde el panel)."
            echo "# Después ejecuta: vpn-netguard.sh apply-privacy"
        fi
        echo

        echo "[device]"
        if [[ "$RANDOMIZE_SCAN_MAC" == "true" ]]; then
            # "yes" ya es el valor por defecto en NetworkManager moderno;
            # se fija explícitamente para no depender de eso.
            echo "wifi.scan-rand-mac-address=yes"
            if [[ -n "$MAC_OUI_MASK" ]]; then
                echo "wifi.scan-generate-mac-address-mask=$MAC_OUI_MASK"
            fi
        fi
        echo

        echo "[connection]"
        if [[ -n "$mac_kw" ]]; then
            echo "wifi.cloned-mac-address=$mac_kw"
            echo "ethernet.cloned-mac-address=$mac_kw"
            if [[ -n "$MAC_OUI_MASK" ]]; then
                echo "wifi.generate-mac-address-mask=$MAC_OUI_MASK"
                echo "ethernet.generate-mac-address-mask=$MAC_OUI_MASK"
            fi
            if [[ "$mac_kw" == "stable" ]]; then
                # "${CONNECTION}"/"${BOOT}" son especificadores que interpreta
                # NetworkManager (no bash) al derivar la MAC "stable"; ver
                # NetworkManager.conf(5)/nm-settings(5), "connection.stable-id".
                # Se añaden solo los trozos que correspondan según la
                # configuración, para no tocar el valor por defecto (deriva
                # de connection.uuid) cuando ninguna rotación está activa.
                # shellcheck disable=SC2016 # sin expandir a propósito: lo interpreta NetworkManager, no bash
                local stable_id='${CONNECTION}'
                # shellcheck disable=SC2016 # ídem
                [[ "$ROTATE_MAC_PER_BOOT" == "true" ]] && stable_id+='/${BOOT}'
                if (( ROTATE_MAC_EVERY_HOURS > 0 )); then
                    # Trozo propio (no lo interpreta NetworkManager): un
                    # token que solo cambia cuando rotate_mac_now() lo
                    # regenera, así la MAC se mantiene igual entre
                    # reconciliaciones normales y solo salta cuando toca.
                    mkdir -p "$STATE_DIR" || { rm -f "$tmp"; return 1; }
                    if [[ ! -s "$MAC_ROTATE_TOKEN_FILE" ]]; then
                        date +%s%N > "$MAC_ROTATE_TOKEN_FILE" || { rm -f "$tmp"; return 1; }
                    fi
                    local rotate_token
                    rotate_token="$(cat "$MAC_ROTATE_TOKEN_FILE" 2>/dev/null)" || { rm -f "$tmp"; return 1; }
                    [[ -n "$rotate_token" ]] || { rm -f "$tmp"; return 1; }
                    stable_id+="/$rotate_token"
                fi
                # shellcheck disable=SC2016 # sin expandir a propósito: lo interpreta NetworkManager, no bash
                if [[ "$stable_id" != '${CONNECTION}' ]]; then
                    # shellcheck disable=SC2016 # sin expandir a propósito: lo interpreta NetworkManager, no bash
                    echo "connection.stable-id=$stable_id"
                fi
            fi
        fi
        if [[ "$HARDEN_DHCP_IDENTIFIERS" == "true" ]]; then
            # DHCPv4 client-id=mac solo es válido para Ethernet. En Wi-Fi,
            # "none" evita enviar un identificador persistente independiente
            # de la MAC ya camuflada.
            echo "[connection-ethernet]"
            echo "match-device=type:ethernet"
            echo "ipv4.dhcp-client-id=mac"
            echo "ipv4.dhcp-iaid=mac"
            echo "ipv6.dhcp-duid=ll"
            echo "ipv6.dhcp-iaid=mac"
            echo
            echo "[connection-wifi]"
            echo "match-device=type:wifi"
            echo "ipv4.dhcp-client-id=none"
            echo "ipv4.dhcp-iaid=mac"
            echo "ipv6.dhcp-duid=ll"
            echo "ipv6.dhcp-iaid=mac"
            echo
        fi
        if [[ "$DISABLE_IPV6" == "true" ]]; then
            # "disabled" desactiva la pila IPv6 por completo para todas las
            # conexiones (valor documentado en nm-settings(5), "ipv6.method").
            # Tiene prioridad sobre IPV6_PRIVACY: no tiene sentido pedir
            # direcciones privadas/temporales para una pila que ni siquiera
            # se va a levantar.
            echo "ipv6.method=disabled"
        elif [[ "$IPV6_PRIVACY" == "true" ]]; then
            echo "ipv6.ip6-privacy=2"        # 2 = habilitado, prefiere direcciones temporales (RFC 4941)
            echo "ipv6.addr-gen-mode=1"       # 1 = stable-privacy (RFC 7217); no derivar de la MAC (eui64)
        fi
        if [[ "$SPOOF_HOSTNAME" == "true" ]]; then
            if [[ -n "$DHCP_HOSTNAME_OVERRIDE" ]]; then
                echo "ipv4.dhcp-send-hostname=true"
                echo "ipv6.dhcp-send-hostname=true"
                echo "ipv4.dhcp-hostname=$DHCP_HOSTNAME_OVERRIDE"
                echo "ipv6.dhcp-hostname=$DHCP_HOSTNAME_OVERRIDE"
            else
                echo "ipv4.dhcp-send-hostname=false"
                echo "ipv6.dhcp-send-hostname=false"
            fi
        fi
        if [[ "$DISABLE_MDNS_ANNOUNCE" == "true" ]]; then
            echo "connection.mdns=0"    # 0 = no anunciar/resolver mDNS para este equipo
            echo "connection.llmnr=0"   # 0 = igual para LLMNR
        fi
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    install -D -o root -g root -m 644 "$tmp" "$NM_PRIVACY_CONF" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# Servicios del sistema que anuncian el nombre de este equipo en la LAN por
# FUERA de NetworkManager (avahi-daemon para mDNS/Bonjour, nmbd para
# NetBIOS). El snippet de arriba no puede silenciarlos porque son demonios
# systemd independientes. Se enmascaran (no solo "disable") porque varios
# usan activación por socket y, si no, el propio socket los revive; y se
# recuerda con un marcador en $STATE_DIR si estaban activos antes de tocar
# nada, para restaurar exactamente ese estado al desactivar o desinstalar.
# -----------------------------------------------------------------------------
# "systemctl list-unit-files <unidad>" siempre devuelve código de salida 0
# aunque la unidad no exista ("0 unit files listed." también sale con
# éxito), así que hay que comprobar el contenido de la salida, no el
# código de salida, para saber si la unidad existe de verdad.
unit_file_exists() {
    systemctl list-unit-files "$1" --no-legend 2>/dev/null |
        awk -v unit="$1" '$1 == unit { found=1; exit } END { exit !found }'
}

unit_saved_state() {
    local unit="$1" enabled active_state
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    case "$enabled" in
        masked|masked-runtime) printf 'masked'; return 0 ;;
        enabled|enabled-runtime|linked|linked-runtime|alias)
            if systemctl is-active --quiet "$unit" 2>/dev/null; then printf 'enabled-active'; else printf 'enabled-inactive'; fi
            return 0
            ;;
        static|indirect|generated|transient)
            if systemctl is-active --quiet "$unit" 2>/dev/null; then active_state=active; else active_state=inactive; fi
            printf '%s-%s' "$enabled" "$active_state"
            return 0
            ;;
    esac
    if systemctl is-active --quiet "$unit" 2>/dev/null; then printf 'disabled-active'; else printf 'disabled-inactive'; fi
}

mask_service_remembering_state() {
    local unit="$1" socket_unit="$2" marker="$STATE_DIR/$3" unit_state socket_state='' tmp_marker just_saved=0
    unit_file_exists "$unit" || return 0
    # Si el marcador ya existe, NO se vuelve a guardar el estado (se
    # corromperia con el estado ya enmascarado), pero sí se reafirma el
    # mask: si algo externo (actualización de paquete, admin) lo hubiera
    # desenmascarado entre medias, "apply-privacy-now" debe poder corregirlo.
    if [[ ! -f "$marker" ]]; then
        unit_state="$(unit_saved_state "$unit")"
        if [[ -n "$socket_unit" ]] && unit_file_exists "$socket_unit"; then
            socket_state="$(unit_saved_state "$socket_unit")"
        fi
        mkdir -p "$STATE_DIR" || return 1
        tmp_marker="$(mktemp "${marker}.XXXXXX")" || return 1
        printf '%s\n%s\n' "$unit_state" "$socket_state" > "$tmp_marker" || { rm -f "$tmp_marker"; return 1; }
        if ! mv -f "$tmp_marker" "$marker"; then
            rm -f "$tmp_marker"
            return 1
        fi
        just_saved=1
    fi
    if ! systemctl mask --now "$unit" ${socket_unit:+"$socket_unit"} >/dev/null 2>&1; then
        (( just_saved )) && rm -f "$marker"
        return 1
    fi
    return 0
}

restore_one_unit() {
    local unit="$1" state="$2"
    [[ -n "$unit" && -n "$state" ]] || return 0
    case "$state" in
        masked) systemctl mask "$unit" >/dev/null 2>&1 ;;
        enabled-active) systemctl unmask "$unit" >/dev/null 2>&1 && systemctl enable --now "$unit" >/dev/null 2>&1 ;;
        enabled-inactive) systemctl unmask "$unit" >/dev/null 2>&1 && systemctl enable "$unit" >/dev/null 2>&1 ;;
        disabled-active) systemctl unmask "$unit" >/dev/null 2>&1 && systemctl start "$unit" >/dev/null 2>&1 && systemctl disable "$unit" >/dev/null 2>&1 ;;
        disabled-inactive) systemctl unmask "$unit" >/dev/null 2>&1 ;;
        static-active|indirect-active|generated-active|transient-active) systemctl unmask "$unit" >/dev/null 2>&1 && systemctl start "$unit" >/dev/null 2>&1 ;;
        static-inactive|indirect-inactive|generated-inactive|transient-inactive) systemctl unmask "$unit" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

unmask_service_restoring_state() {
    local unit="$1" socket_unit="$2" marker="$STATE_DIR/$3" unit_state socket_state='' _saved_states=()
    if ! unit_file_exists "$unit"; then
        rm -f "$marker"
        return 0
    fi
    [[ -f "$marker" ]] || return 0
    mapfile -t _saved_states < "$marker" 2>/dev/null || { rm -f "$marker"; return 1; }
    unit_state="${_saved_states[0]:-}"
    socket_state="${_saved_states[1]:-}"
    restore_one_unit "$unit" "$unit_state" || return 1
    [[ -z "$socket_unit" ]] || restore_one_unit "$socket_unit" "$socket_state" || return 1
    rm -f "$marker"
    return 0
}

apply_avahi_privacy() {
    if [[ "$DISABLE_AVAHI_SERVICE" == "true" ]]; then
        mask_service_remembering_state avahi-daemon.service avahi-daemon.socket avahi-was-enabled \
            && log_t info log.avahi_stopped "$(hostname 2>/dev/null)"
    else
        unmask_service_restoring_state avahi-daemon.service avahi-daemon.socket avahi-was-enabled
    fi
}

# Usada desde remove_network_privacy() (módulo desactivado / desinstalación):
# restaura avahi-daemon SIEMPRE, sin mirar el valor actual de la clave de
# configuración, para que "retirar el módulo" deshaga de verdad todo lo
# que hubiera aplicado antes.
restore_avahi_daemon() {
    unmask_service_restoring_state avahi-daemon.service avahi-daemon.socket avahi-was-enabled
}

apply_netbios_privacy() {
    if [[ "$DISABLE_NETBIOS_SERVICE" == "true" ]]; then
        mask_service_remembering_state nmbd.service "" netbios-was-enabled \
            && log_t info log.netbios_stopped
    else
        unmask_service_restoring_state nmbd.service "" netbios-was-enabled
    fi
}

restore_netbios_service() {
    unmask_service_restoring_state nmbd.service "" netbios-was-enabled
}

# Mitigación opcional del AVISO 2 de DNS_SERVERS (ver write_default_config):
# instala políticas que fuerzan a Firefox/Chrome/Chromium a no usar su
# propio DNS-over-HTTPS. Firefox solo tiene UN policies.json; si ya existe uno
# ajeno a NetGuard, se conserva. La versión antigua usaba una marca privada
# dentro del JSON y se migra una sola vez a un marcador externo en $STATE_DIR.
browser_policy_compact() {
    tr -d '[:space:]' < "$1"
}

firefox_policy_is_legacy_managed() {
    [[ -f "$FIREFOX_POLICY_FILE" ]] || return 1
    [[ "$(browser_policy_compact "$FIREFOX_POLICY_FILE")" == '{"policies":{"_vpn_netguard_managed":true,"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}' ]]
}

firefox_policy_is_managed() {
    [[ -f "$FIREFOX_POLICY_FILE" ]] || return 1
    [[ "$(browser_policy_compact "$FIREFOX_POLICY_FILE")" == '{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true}}}' ]] || firefox_policy_is_legacy_managed
}

chromium_policy_is_managed() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    [[ "$(browser_policy_compact "$path")" == '{"DnsOverHttpsMode":"off"}' ]]
}

apply_browser_doh_policy() {
    if [[ "$HARDEN_BROWSER_DOH" != "true" ]]; then
        remove_browser_doh_policy
        return $?
    fi

    local rc_ff=0 rc_chrome=0 rc_chromium=0 tmp
    local chrome_created=0 chromium_created=0 chromium_browser_created=0
    write_json_atomic() {
        local dest="$1"
        tmp="$(mktemp "${dest}.XXXXXX")" || return 1
        cat > "$tmp" <<'EOF'
{
  "DnsOverHttpsMode": "off"
}
EOF
        if ! install -D -o root -g root -m 644 "$tmp" "$dest"; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    }

    if command -v firefox >/dev/null 2>&1; then
        if [[ -e "$FIREFOX_POLICY_FILE" ]] &&
           [[ ! -f "$FIREFOX_POLICY_MARKER" ]] &&
           ! firefox_policy_is_managed && ! firefox_policy_is_legacy_managed; then
            log_t warn log.browser_policy_conflict "$FIREFOX_POLICY_FILE"
            rc_ff=1
        elif [[ ! -e "$FIREFOX_POLICY_FILE" ]]; then
            mkdir -p "$(dirname "$FIREFOX_POLICY_FILE")" || rc_ff=1
            if (( rc_ff == 0 )); then
                tmp="$(mktemp "${FIREFOX_POLICY_FILE}.XXXXXX")" || rc_ff=1
            fi
            if (( rc_ff == 0 )); then
                cat > "$tmp" <<'EOF'
{
  "policies": {
    "DNSOverHTTPS": { "Enabled": false, "Locked": true }
  }
}
EOF
                install -D -o root -g root -m 644 "$tmp" "$FIREFOX_POLICY_FILE" || rc_ff=1
                rm -f "$tmp"
            fi
            if (( rc_ff == 0 )); then
                mkdir -p "$STATE_DIR" || rc_ff=1
                if (( rc_ff == 0 )); then
                    printf '%s\n' "$FIREFOX_POLICY_FILE" > "${FIREFOX_POLICY_MARKER}.tmp" && mv -f "${FIREFOX_POLICY_MARKER}.tmp" "$FIREFOX_POLICY_MARKER" || { rm -f "${FIREFOX_POLICY_MARKER}.tmp" "$FIREFOX_POLICY_FILE"; rc_ff=1; }
                fi
            fi
            (( rc_ff == 0 )) && log_t info log.browser_firefox
        elif [[ -f "$FIREFOX_POLICY_MARKER" ]] && firefox_policy_is_managed; then
            log_t info log.browser_firefox
        elif firefox_policy_is_legacy_managed; then
            mkdir -p "$STATE_DIR" || rc_ff=1
            if (( rc_ff == 0 )); then
                tmp="$(mktemp "${FIREFOX_POLICY_FILE}.XXXXXX")" || rc_ff=1
            fi
            if (( rc_ff == 0 )); then
                cat > "$tmp" <<'EOF'
{
  "policies": {
    "DNSOverHTTPS": { "Enabled": false, "Locked": true }
  }
}
EOF
                install -D -o root -g root -m 644 "$tmp" "$FIREFOX_POLICY_FILE" || rc_ff=1
                rm -f "$tmp"
            fi
            if (( rc_ff == 0 )); then
                printf '%s\n' "$FIREFOX_POLICY_FILE" > "${FIREFOX_POLICY_MARKER}.tmp" && mv -f "${FIREFOX_POLICY_MARKER}.tmp" "$FIREFOX_POLICY_MARKER" || rc_ff=1
            fi
            (( rc_ff == 0 )) && log_t info log.browser_firefox
        else
            log_t warn log.browser_firefox_existing "$FIREFOX_POLICY_FILE"
            rc_ff=1
        fi
    fi

    if command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; then
        local chrome_policy="$CHROME_POLICY_DIR/vpn-netguard-doh.json"
        if [[ -e "$chrome_policy" ]]; then
            if [[ ! -f "$CHROME_POLICY_MARKER" ]] || ! chromium_policy_is_managed "$chrome_policy"; then
                log_t warn log.browser_policy_conflict "$chrome_policy"
                rc_chrome=1
            else
                log_t info log.browser_chrome
            fi
        else
            if mkdir -p "$CHROME_POLICY_DIR" && write_json_atomic "$chrome_policy"; then
                chrome_created=1
                if mkdir -p "$STATE_DIR" && printf '%s\n' "$chrome_policy" > "${CHROME_POLICY_MARKER}.tmp" && mv -f "${CHROME_POLICY_MARKER}.tmp" "$CHROME_POLICY_MARKER"; then
                    log_t info log.browser_chrome
                else
                    rm -f "$chrome_policy" "$CHROME_POLICY_MARKER" "${CHROME_POLICY_MARKER}.tmp"
                    rc_chrome=1
                fi
            else
                rc_chrome=1
            fi
        fi
        if (( rc_chrome != 0 && chrome_created )); then
            rm -f "$chrome_policy" "$CHROME_POLICY_MARKER" "${CHROME_POLICY_MARKER}.tmp"
        fi
    fi

    if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
        local chromium_policy="$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json"
        local chromium_browser_policy="$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json"
        local chromium_need_write=0 chromium_browser_need_write=0
        if [[ -e "$chromium_policy" ]]; then
            if [[ ! -f "$CHROMIUM_POLICY_MARKER" ]] || ! chromium_policy_is_managed "$chromium_policy"; then
                log_t warn log.browser_policy_conflict "$chromium_policy"
                rc_chromium=1
            fi
        else
            chromium_need_write=1
        fi
        if [[ -e "$chromium_browser_policy" ]]; then
            if [[ ! -f "$CHROMIUM_BROWSER_POLICY_MARKER" ]] || ! chromium_policy_is_managed "$chromium_browser_policy"; then
                log_t warn log.browser_policy_conflict "$chromium_browser_policy"
                rc_chromium=1
            fi
        else
            chromium_browser_need_write=1
        fi
        if (( rc_chromium == 0 )); then
            mkdir -p "$CHROMIUM_POLICY_DIR" "$CHROMIUM_BROWSER_POLICY_DIR" || rc_chromium=1
            if (( rc_chromium == 0 && chromium_need_write )); then
                write_json_atomic "$chromium_policy" && chromium_created=1 || rc_chromium=1
            fi
            if (( rc_chromium == 0 && chromium_browser_need_write )); then
                write_json_atomic "$chromium_browser_policy" && chromium_browser_created=1 || rc_chromium=1
            fi
            if (( rc_chromium == 0 )); then
                mkdir -p "$STATE_DIR" || rc_chromium=1
                if (( rc_chromium == 0 && chromium_created )); then
                    printf '%s\n' "$chromium_policy" > "${CHROMIUM_POLICY_MARKER}.tmp" && mv -f "${CHROMIUM_POLICY_MARKER}.tmp" "$CHROMIUM_POLICY_MARKER" || rc_chromium=1
                fi
                if (( rc_chromium == 0 && chromium_browser_created )); then
                    printf '%s\n' "$chromium_browser_policy" > "${CHROMIUM_BROWSER_POLICY_MARKER}.tmp" && mv -f "${CHROMIUM_BROWSER_POLICY_MARKER}.tmp" "$CHROMIUM_BROWSER_POLICY_MARKER" || rc_chromium=1
                fi
            fi
            (( rc_chromium == 0 )) && log_t info log.browser_chromium
        fi
        if (( rc_chromium != 0 )); then
            if (( chromium_created )); then rm -f "$chromium_policy" "${CHROMIUM_POLICY_MARKER}.tmp"; fi
            if (( chromium_browser_created )); then rm -f "$chromium_browser_policy" "${CHROMIUM_BROWSER_POLICY_MARKER}.tmp"; fi
            if (( chromium_created )); then rm -f "$CHROMIUM_POLICY_MARKER"; fi
            if (( chromium_browser_created )); then rm -f "$CHROMIUM_BROWSER_POLICY_MARKER"; fi
        fi
    fi
    (( rc_ff == 0 && rc_chrome == 0 && rc_chromium == 0 ))
}
remove_browser_doh_policy() {
    local rc=0 path
    if [[ -f "$FIREFOX_POLICY_MARKER" ]]; then
        if [[ ! -e "$FIREFOX_POLICY_FILE" ]]; then
            rm -f "$FIREFOX_POLICY_MARKER" || rc=1
        elif firefox_policy_is_managed; then
            rm -f "$FIREFOX_POLICY_FILE" "$FIREFOX_POLICY_MARKER" || rc=1
        else
            log_t warn log.browser_policy_modified "$FIREFOX_POLICY_FILE"
            rc=1
        fi
    elif [[ -f "$FIREFOX_POLICY_FILE" ]] && firefox_policy_is_legacy_managed; then
        rm -f "$FIREFOX_POLICY_FILE" || rc=1
    elif [[ -f "$FIREFOX_POLICY_FILE" ]] && grep -q '_vpn_netguard_managed' "$FIREFOX_POLICY_FILE" 2>/dev/null; then
        log_t warn log.browser_policy_modified "$FIREFOX_POLICY_FILE"
        rc=1
    fi
    if [[ -f "$CHROME_POLICY_MARKER" ]]; then
        path="$CHROME_POLICY_DIR/vpn-netguard-doh.json"
        if [[ ! -e "$path" ]]; then
            rm -f "$CHROME_POLICY_MARKER" || rc=1
        elif chromium_policy_is_managed "$path"; then
            rm -f "$path" "$CHROME_POLICY_MARKER" || rc=1
        else
            log_t warn log.browser_policy_modified "$path"
            rc=1
        fi
    fi
    if [[ -f "$CHROMIUM_POLICY_MARKER" ]]; then
        path="$CHROMIUM_POLICY_DIR/vpn-netguard-doh.json"
        if [[ ! -e "$path" ]]; then
            rm -f "$CHROMIUM_POLICY_MARKER" || rc=1
        elif chromium_policy_is_managed "$path"; then
            rm -f "$path" "$CHROMIUM_POLICY_MARKER" || rc=1
        else
            log_t warn log.browser_policy_modified "$path"
            rc=1
        fi
    fi
    if [[ -f "$CHROMIUM_BROWSER_POLICY_MARKER" ]]; then
        path="$CHROMIUM_BROWSER_POLICY_DIR/vpn-netguard-doh.json"
        if [[ ! -e "$path" ]]; then
            rm -f "$CHROMIUM_BROWSER_POLICY_MARKER" || rc=1
        elif chromium_policy_is_managed "$path"; then
            rm -f "$path" "$CHROMIUM_BROWSER_POLICY_MARKER" || rc=1
        else
            log_t warn log.browser_policy_modified "$path"
            rc=1
        fi
    fi
    return "$rc"
}

# Recarga la configuración de NetworkManager SIN reiniciar el servicio: a
# diferencia de "systemctl restart NetworkManager", esto no interrumpe las
# conexiones activas ni afecta a las reglas de iptables del kill switch
# (son subsistemas independientes). "nmcli general reload conf" es el
# mecanismo soportado desde hace años; "systemctl reload" es el mismo
# mecanismo a través de systemd, usado aquí solo como respaldo.
reload_networkmanager_conf() {
    if nmcli_c general reload conf >/dev/null 2>&1; then
        return 0
    fi
    systemctl reload NetworkManager >/dev/null 2>&1
}

apply_network_privacy() {
    if [[ "$ANONYMIZE_NETWORK" != "true" ]]; then
        remove_network_privacy
        return $?
    fi
    mkdir -p "$(dirname "$NM_PRIVACY_CONF")" || return 1
    write_privacy_conf || { log_t warn log.privacy_write_fail "$NM_PRIVACY_CONF"; return 1; }
    local rc=0
    apply_avahi_privacy || rc=1
    apply_netbios_privacy || rc=1
    apply_browser_doh_policy || rc=1
    sync_mac_rotate_timer || rc=1
    # El log de éxito solo sale si TODO lo de arriba fue bien, no solo el
    # snippet de NetworkManager: si no se gatea con "rc", un fallo silencioso
    # de avahi/netbios/DoH de navegador quedaría enmascarado por un mensaje
    # de éxito (mismo criterio que remove_network_privacy más abajo).
    if reload_networkmanager_conf; then
        [[ $rc -eq 0 ]] && log_t info log.privacy_applied "$MAC_MODE" "$DISABLE_IPV6" "$IPV6_PRIVACY" "$SPOOF_HOSTNAME" "$HARDEN_DHCP_IDENTIFIERS"
    else
        log_t warn log.privacy_reload_fail "$NM_PRIVACY_CONF"
        rc=1
    fi
    return "$rc"
}

remove_network_privacy() {
    local rc=0
    restore_avahi_daemon || rc=1
    restore_netbios_service || rc=1
    remove_browser_doh_policy || rc=1
    remove_mac_rotate_timer || rc=1
    if [[ -f "$NM_PRIVACY_CONF" ]]; then
        rm -f "$NM_PRIVACY_CONF" || rc=1
        if ! reload_networkmanager_conf; then rc=1; fi
        [[ $rc -eq 0 ]] && log_t info log.privacy_removed
    fi
    return "$rc"
}

# Instala/retira el temporizador systemd de rotación de MAC según
# MAC_MODE/ROTATE_MAC_EVERY_HOURS actuales. Idempotente: se puede llamar en
# cada apply_network_privacy() sin pasar por install/uninstall aparte.
sync_mac_rotate_timer() {
    if [[ "$MAC_MODE" == "stable" ]] && (( ROTATE_MAC_EVERY_HOURS > 0 )); then
        local tmp_service tmp_timer
        tmp_service="$(mktemp "${MAC_ROTATE_UNIT_DST}.XXXXXX")" || return 1
        tmp_timer="$(mktemp "${MAC_ROTATE_TIMER_DST}.XXXXXX")" || { rm -f "$tmp_service"; return 1; }
        write_mac_rotate_service_unit > "$tmp_service" || { rm -f "$tmp_service" "$tmp_timer"; return 1; }
        write_mac_rotate_timer_unit > "$tmp_timer" || { rm -f "$tmp_service" "$tmp_timer"; return 1; }
        install -D -o root -g root -m 644 "$tmp_service" "$MAC_ROTATE_UNIT_DST" || { rm -f "$tmp_service" "$tmp_timer"; return 1; }
        install -D -o root -g root -m 644 "$tmp_timer" "$MAC_ROTATE_TIMER_DST" || { rm -f "$tmp_service" "$tmp_timer"; return 1; }
        rm -f "$tmp_service" "$tmp_timer"
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        if ! systemctl enable --now "$MAC_ROTATE_TIMER" >/dev/null 2>&1; then
            log_t error log.rotate_enable_fail "$MAC_ROTATE_TIMER"
            systemctl disable --now "$MAC_ROTATE_TIMER" >/dev/null 2>&1 || true
            rm -f "$MAC_ROTATE_UNIT_DST" "$MAC_ROTATE_TIMER_DST"
            systemctl daemon-reload >/dev/null 2>&1 || true
            return 1
        fi
        log_t info log.rotate_enabled "$ROTATE_MAC_EVERY_HOURS"
    else
        remove_mac_rotate_timer
    fi
}

remove_mac_rotate_timer() {
    if unit_file_exists "$MAC_ROTATE_TIMER"; then
        systemctl disable --now "$MAC_ROTATE_TIMER" >/dev/null 2>&1 || return 1
    fi
    rm -f "$MAC_ROTATE_UNIT_DST" "$MAC_ROTATE_TIMER_DST" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
}

# Subcomando "rotate-mac": lo dispara el propio timer systemd (o se puede
# lanzar a mano para forzar una rotación ya). Genera un token nuevo, vuelve
# a escribir el snippet de NetworkManager con él y reconecta la red física
# activa para que la MAC nueva se aplique de verdad (NetworkManager solo la
# fija al activar la conexión, no en caliente sobre una ya conectada).
rotate_mac_now() {
    if [[ "$MAC_MODE" != "stable" ]] || (( ROTATE_MAC_EVERY_HOURS <= 0 )); then
        log_t info log.rotate_disabled "$MAC_MODE" "$ROTATE_MAC_EVERY_HOURS"
        remove_mac_rotate_timer || { log_t error log.rotate_fail; return 1; }
        return 0
    fi

    mkdir -p "$STATE_DIR" || { log_t error log.rotate_fail; return 1; }
    date +%s%N > "$MAC_ROTATE_TOKEN_FILE" || { log_t error log.rotate_fail; return 1; }
    write_privacy_conf || { log_t error log.rotate_fail; return 1; }
    reload_networkmanager_conf || { log_t error log.rotate_fail; return 1; }

    detect_known_profiles
    detect_active_state
    local name="${ACTIVE_WIFI:-$ACTIVE_ETH}"
    if [[ -n "$name" ]]; then
        log_t info log.rotate_reconnect "'$name'"
        nmcli_c connection down "$name" >/dev/null 2>&1 || { log_t error log.rotate_fail; return 1; }
        nmcli_up "$name" || { log_t error log.rotate_fail; return 1; }
    fi
    log_t info log.rotate_done
}

# Filas del anonimato de red, con la misma presentación que el resto del estado. Las usan
# «status» (sección propia; la red activa ya sale en su sección Red) y «privacy-status»
# (pantalla propia: $1 = standalone añade la red activa). Requiere detect_active_state.
print_privacy_rows() {
    local standalone="${1:-}" line timer_state timer_level active_name="" prop_prefix=""
    local cur_mac cloned_policy ip6priv dhcp_host empty
    empty="($(ui_t menu.empty))"
    if [[ "$ANONYMIZE_NETWORK" == "true" ]]; then
        printf -v line -- "$(ui_t privacy.v_enabled)" "$MAC_MODE"
        ui_row "$(ui_t privacy.l_module)" "$line" ok
    else
        ui_row "$(ui_t privacy.l_module)" "$(ui_t privacy.v_disabled)"
    fi
    if [[ -f "$NM_PRIVACY_CONF" ]]; then
        printf -v line -- "$(ui_t privacy.v_snippet_yes)" "$NM_PRIVACY_CONF"
        ui_row "$(ui_t privacy.l_snippet)" "$line" "$([[ "$ANONYMIZE_NETWORK" == "true" ]] && echo ok)"
    elif [[ "$ANONYMIZE_NETWORK" == "true" ]]; then
        ui_row "$(ui_t privacy.l_snippet)" "$(ui_t privacy.v_snippet_no)" warn
    else
        ui_row "$(ui_t privacy.l_snippet)" "$(ui_t no)"
    fi
    ui_row "$(ui_t privacy.l_boot)" "$(ui_yesno "$ROTATE_MAC_PER_BOOT")"
    if (( ROTATE_MAC_EVERY_HOURS > 0 )); then
        if systemctl is-active "$MAC_ROTATE_TIMER" >/dev/null 2>&1; then
            timer_state="$(ui_t active)"; timer_level=ok
        else
            timer_state="$(ui_t inactive)"; timer_level=warn
        fi
        printf -v line -- "$(ui_t privacy.v_timer)" "$ROTATE_MAC_EVERY_HOURS" "$timer_state"
        ui_row "$(ui_t privacy.l_timer)" "$line" "$timer_level"
    else
        ui_row "$(ui_t privacy.l_timer)" "$(ui_t privacy.v_timer_off)"
    fi
    ui_row "$(ui_t privacy.l_scan)" "$(ui_yesno "$RANDOMIZE_SCAN_MAC")"
    ui_row "$(ui_t privacy.l_hostname)" "$(ui_yesno "$SPOOF_HOSTNAME")"
    ui_row "$(ui_t privacy.l_ipv6)" "$(ui_yesno "$IPV6_PRIVACY")"
    ui_row "$(ui_t privacy.l_ipv6_off)" "$(ui_yesno "$DISABLE_IPV6")"
    ui_row "$(ui_t privacy.l_mdns)" "$(ui_yesno "$DISABLE_MDNS_ANNOUNCE")"
    ui_row "$(ui_t privacy.l_doh)" "$(ui_yesno "$HARDEN_BROWSER_DOH")"

    if [[ -n "$ACTIVE_WIFI" ]]; then
        active_name="$ACTIVE_WIFI"; prop_prefix="wifi"
    elif [[ -n "$ACTIVE_ETH" ]]; then
        active_name="$ACTIVE_ETH"; prop_prefix="ethernet"
    fi
    if [[ -n "$active_name" && -n "$PHYS_IFACE" ]]; then
        cur_mac="$(cat "/sys/class/net/$PHYS_IFACE/address" 2>/dev/null)"
        cloned_policy="$(nmcli_c -g "${prop_prefix}.cloned-mac-address" connection show "$active_name" 2>/dev/null)"
        ip6priv="$(nmcli_c -g ipv6.ip6-privacy connection show "$active_name" 2>/dev/null)"
        dhcp_host="$(nmcli_c -g ipv4.dhcp-send-hostname connection show "$active_name" 2>/dev/null)"
        [[ -n "$standalone" ]] && ui_row "$(ui_t privacy.l_active_net)" "$active_name ($PHYS_IFACE)"
        ui_row "$(ui_t privacy.l_cur_mac)" "${cur_mac:-$(ui_t unknown)}"
        ui_row "$(ui_t privacy.l_prof_mac)" "${cloned_policy:-$empty}"
        ui_row "$(ui_t privacy.l_prof_ipv6)" "${ip6priv:-$empty}"
        ui_row "$(ui_t privacy.l_prof_host)" "${dhcp_host:-$empty}"
    elif [[ -n "$standalone" ]]; then
        ui_row "$(ui_t privacy.l_active_net)" "$(ui_t privacy.v_no_net)"
    fi
}

# Pantalla «Ver estado del anonimato» (subcomando "privacy-status" y botón del panel).
print_privacy_status() {
    detect_known_profiles
    detect_active_state
    ui_banner "$(ui_t privacy.status_title)"
    echo
    print_privacy_rows standalone
}

# -----------------------------------------------------------------------------
# Arranque temprano (subcomando "boot-killswitch"): lo invoca ÚNICAMENTE la
# unidad systemd "vpn-netguard-boot" (Before=network-pre.target), nunca hace
# falta lanzarlo a mano. Cierra la ventana entre que arranca la red y que
# vpn-netguard.service llega a ejecutarse de verdad.
#
# A esta altura NetworkManager TODAVÍA NO está en marcha, así que nmcli no
# sirve de nada: detect_known_profiles/detect_active_state no darían datos
# fiables. Por eso este oneshot no razona sobre perfiles VPN concretos: solo
# decide SI debe bloquear (con KILLSWITCH_MODE y el fichero "wanted") y, si
# toca, llama a apply_killswitch_rules sin candidatos ni interfaz de túnel
# (loopback, LAN, DNS, DHCP; todo lo demás cae) — el mismo resultado que
# daría apply_killswitch_blocking() con 0 perfiles conocidos. Con
# COEXIST_MODE=auto además deja pasar (RETURN) lo ajeno visible sin
# NetworkManager (coexist_scan boot: túneles ya activos y la marca de NordVPN
# si hay rastro de su cliente), para que un cliente con autoconexión no tenga
# que esperar al demonio. No cede el bloqueo: sin NetworkManager no se sabe si
# hay perfiles VPN, y de ceder se encarga el demonio segundos después.
#
# Segundos después, cuando arranca vpn-netguard.service (con NetworkManager
# ya listo), daemon_main -> reconcile_sync sustituye estas reglas por las
# completas o las retira si no procede. Ese es el único punto de
# reconciliación real; este oneshot solo evita tráfico sin proteger
# mientras tanto.
# -----------------------------------------------------------------------------
# ¿Bloqueará boot_killswitch_main en el PRÓXIMO arranque, con el estado y
# configuración actuales? Extraída para que doctor/panel/menú puedan avisar
# de un futuro choque con el kill switch del propio cliente VPN ANTES de
# reiniciar, sin duplicar este case en varios sitios. A propósito NO
# reutiliza killswitch_should_be_active(): esa exige además
# ${#KNOWN_VPN[@]} > 0 en modo "auto", un dato que a esta altura del
# arranque (antes de que NetworkManager exista) todavía no se puede saber.
boot_killswitch_would_block() {
    case "$(cat "$KILLSWITCH_OVERRIDE_FILE" 2>/dev/null)" in
        on) return 0 ;;
        off) return 1 ;;
    esac
    case "$KILLSWITCH_MODE" in
        true) return 0 ;;
        auto) want_vpn_active ;;
        *) return 1 ;;
    esac
}

# Aviso de escritorio específico de este choque: solo tiene sentido en el
# PRIMER episodio de bloqueo-sin-VPN de cada arranque del servicio, no en
# cualquier caída de VPN posterior durante el día -esa ya la cubre
# notify_event('blocking') de siempre-. Estado en KS_BOOT_RACE_PENDING_FILE
# (no en variable de proceso): reconcile_locked corre siempre dentro de un
# subshell (flock, ver reconcile_sync/reconcile_async), así que una
# variable normal se perdería al salir de él y el aviso se repetiría sin
# fin en vez de una sola vez.
# Margen antes de dar el choque por "atascado": dentro de este tiempo el
# propio backoff de try_reconnect_vpn (pasos 5/15/30s) puede resolverlo
# solo, así que una VPN simplemente lenta al arrancar no dispara un aviso
# ni una autodesactivación que no hacían falta.
KS_BOOT_RACE_GRACE_SECONDS=40

# Un único punto que decide qué variante del aviso de choque de arranque
# mostrar (doctor, panel, menú de texto tras guardar), según qué mitigación
# tenga ya activada el usuario. Antes cada sitio mostraba siempre el texto
# genérico, ignorando KILLSWITCH_BOOT_RACE_AUTO_DISABLE.
ks_boot_race_warning_text() {
    if [[ "$KILLSWITCH_BOOT_RACE_AUTO_DISABLE" == "true" ]]; then
        ui_t doctor.ks_boot_race_warn_autodisable
    else
        ui_t doctor.ks_boot_race_warn
    fi
}

warn_ks_boot_race_if_stuck() {
    [[ -f "$KS_BOOT_RACE_PENDING_FILE" ]] || return 0
    if [[ -n "$ACTIVE_VPN" ]]; then
        rm -f "$KS_BOOT_RACE_PENDING_FILE"
        return 0
    fi
    # Ya autodesactivado en un ciclo anterior: lo único pendiente puede ser
    # reentregar el aviso de escritorio. Desactivar/marcar/loguear ya
    # ocurrió y no debe repetirse ni depender de si el aviso llega o no.
    if [[ -f "$KS_BOOT_RACE_MARKER_FILE" ]]; then
        run_alert_hook critical "$(ui_t notify.ks_boot_race_autodisabled)"
        notify_send critical "$(ui_t notify.ks_boot_race_autodisabled)" && rm -f "$KS_BOOT_RACE_PENDING_FILE"
        return 0
    fi
    if [[ -n "$VPN_ENDPOINT_OVERRIDE" ]] || ! boot_killswitch_would_block; then
        rm -f "$KS_BOOT_RACE_PENDING_FILE"
        return 0
    fi
    # Todavía dentro del margen de gracia: puede resolverse solo, se
    # reintenta en la próxima reconciliación sin avisar ni desactivar nada.
    local armed_at
    armed_at="$(<"$KS_BOOT_RACE_PENDING_FILE")"
    [[ "$armed_at" =~ ^[0-9]+$ ]] || armed_at=0
    (( $(date +%s) - armed_at >= KS_BOOT_RACE_GRACE_SECONDS )) || return 0
    if [[ "$KILLSWITCH_BOOT_RACE_AUTO_DISABLE" == "true" ]]; then
        disable_killswitch_locked
        date '+%Y-%m-%d %H:%M:%S' > "$KS_BOOT_RACE_MARKER_FILE" 2>/dev/null
        log_t warn log.ks_boot_race_autodisabled
        # Si aún no hay sesión de escritorio, notify_send devuelve 1: se
        # reintenta en la próxima reconciliación (rama "-f MARKER" de
        # arriba), pero lo importante -desactivar y dejar constancia- ya ha
        # ocurrido pase lo que pase con el aviso.
        run_alert_hook critical "$(ui_t notify.ks_boot_race_autodisabled)"
        notify_send critical "$(ui_t notify.ks_boot_race_autodisabled)" && rm -f "$KS_BOOT_RACE_PENDING_FILE"
        return 0
    fi
    run_alert_hook critical "$(ui_t notify.ks_boot_race)"
    notify_send critical "$(ui_t notify.ks_boot_race)" && rm -f "$KS_BOOT_RACE_PENDING_FILE"
}

boot_killswitch_main() {
    check_dependencies
    require_root
    load_config

    # El arranque nunca cede: la cesión de la sesión anterior ya no vale. Sin
    # esto, status y los menús (leen el fichero sin escanear) dirían "cedido"
    # con las reglas puestas. El demonio decide de nuevo al arrancar.
    rm -f "$COEXIST_YIELD_FILE"

    if boot_killswitch_would_block; then
        log_t info log.boot_blocking "$SERVICE"
        KS_VPN_CANDIDATES=()
        coexist_scan boot
        apply_killswitch_rules ""
        apply_killswitch_rules6 ""
    else
        log_t info log.boot_skip "$KILLSWITCH_MODE"
    fi

    # Este oneshot nunca debe hacer fallar el arranque: si algo fallara aquí,
    # vpn-netguard.service corrige el estado del cortafuegos segundos después
    # de todas formas.
    exit 0
}

# -----------------------------------------------------------------------------
# Comprobación real de conectividad (además de lo que reporte NetworkManager)
# -----------------------------------------------------------------------------
check_internet_reachable() {
    local target
    for target in $PING_TARGETS; do
        if ping -c1 -W"$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# WireGuard no tiene un estado "conectado" como OpenVPN: la interfaz puede
# seguir en pie con el servidor caído. El último handshake (se renueva cada
# ~120s si hay tráfico, es el propio protocolo) es una señal mucho más fiable
# de que el túnel sigue vivo que un simple ping, que con KILLSWITCH_MODE=false
# podría seguir respondiendo por la interfaz física aunque el túnel esté
# muerto. Requiere el paquete wireguard-tools (comando "wg"); si no está,
# el llamador debe seguir confiando solo en check_internet_reachable().
WG_HANDSHAKE_MAX_AGE=180   # segundos; algo más que el rekey por defecto (120s)

wg_tunnel_alive() {
    local iface="$1" hs
    hs="$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{if ($2>max) max=$2} END{print max+0}')"
    [[ "$hs" -gt 0 ]] || return 1
    (( $(date +%s) - hs <= WG_HANDSHAKE_MAX_AGE ))
}

# Combina check_internet_reachable() con wg_tunnel_alive() cuando la VPN
# activa es WireGuard: un ping que sigue respondiendo por la interfaz física
# no basta para descartar un túnel zombie, sobre todo con KILLSWITCH_MODE=false
# (sin bloqueo que fuerce todo el tráfico por el túnel).
tunnel_reachable() {
    check_internet_reachable || return 1
    if [[ -n "$ACTIVE_VPN" && "$VPN_TYPE" == "wireguard" ]] && command -v wg >/dev/null 2>&1; then
        if ! wg_tunnel_alive "$VPN_IFACE"; then
            log_t warn log.wg_zombie "$ACTIVE_VPN" "$VPN_IFACE" "$WG_HANDSHAKE_MAX_AGE"
            return 1
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Reconciliación: se ejecuta ante cada evento de NetworkManager y, como red
# de seguridad, cada CHECK_INTERVAL segundos.
# -----------------------------------------------------------------------------
reconcile_locked() {
    detect_known_profiles
    detect_active_state

    if [[ -z "$PHYS_IFACE" ]]; then
        log_t warn log.no_physical
        try_reconnect_physical
        detect_active_state
    fi
    coexist_scan
    coexist_sync_yield

    if killswitch_should_be_active; then
        if [[ -z "$ACTIVE_VPN" ]]; then
            apply_killswitch_blocking || return 1
            try_reconnect_vpn
            detect_active_state
            if [[ -n "$ACTIVE_VPN" ]]; then
                apply_killswitch_allowing || return 1
            fi
        else
            apply_killswitch_allowing || return 1
        fi
        # Se llama también con VPN ya activa: es la única forma de limpiar
        # KS_BOOT_RACE_PENDING_FILE al resolverse (ver warn_ks_boot_race_if_stuck);
        # si no, una caída de VPN normal de más tarde heredaría la marca de
        # tiempo del arranque y se leería como un choque recién atascado.
        warn_ks_boot_race_if_stuck
    else
        remove_killswitch_if_present || return 1
        # Sin bloqueo activo se notifica el estado de la VPN en sí (caída /
        # reconectada) en vez del estado del killswitch.
        if vpn_reconnect_wanted && [[ -z "$ACTIVE_VPN" ]]; then
            notify_event vpn_down critical "$(ui_t notify.vpn_down)"
            try_reconnect_vpn
            detect_active_state
            [[ -n "$ACTIVE_VPN" ]] && notify_event vpn_up normal "$(ui_t notify.vpn_up "$ACTIVE_VPN")"
        fi
    fi

    # tunnel_reachable() puede fallar aun con la VPN "activa" según
    # NetworkManager: el túnel puede quedar zombie (interfaz en pie, servidor
    # remoto sin responder; para WireGuard esto se detecta por el último
    # handshake, ver tunnel_reachable()). Si se necesita VPN y no da Internet
    # real, se fuerza una reconexión (down + up) y se resincroniza el
    # killswitch con el estado final, para no dejar aplicadas reglas que ya
    # no correspondan.
    if ! tunnel_reachable; then
        if [[ -z "$PHYS_IFACE" ]]; then
            try_reconnect_physical || true
        fi

        # vpn_reconnect_wanted (no killswitch_should_be_active): en modo
        # KILLSWITCH_MODE=false hay que seguir reconectando la VPN aunque no
        # haya bloqueo que aplicar; si se usara killswitch_should_be_active
        # aquí, una VPN "zombie" nunca se reconectaría en ese modo. Una VPN de
        # VPN_IGNORE no es de NetGuard: ni se baja ni se reconecta.
        if vpn_reconnect_wanted && ! active_vpn_is_ignored; then
            if [[ -n "$ACTIVE_VPN" ]]; then
                log_t warn log.vpn_zombie "$ACTIVE_VPN"
                nmcli_c connection down "$ACTIVE_VPN" >/dev/null 2>&1
            else
                log_t warn log.internet_no_response
            fi
            try_reconnect_vpn
        else
            log_t warn log.internet_no_response
        fi

        detect_active_state
        coexist_scan
        coexist_sync_yield
        if killswitch_should_be_active; then
            if [[ -n "$ACTIVE_VPN" ]]; then
                apply_killswitch_allowing || return 1
            else
                apply_killswitch_blocking || return 1
            fi
        fi
    fi

    # Última línea de la función a propósito: si algo de lo anterior se
    # queda colgado (nmcli/iptables que nunca vuelve), esta línea nunca se
    # alcanza y el latido queda obsoleto (ver watchdog_ping_if_alive).
    touch_heartbeat || { log_t error log.heartbeat_fail; return 1; }
}

reconcile_async() {
    (
        flock -n 9 || exit 0
        reconcile_locked
    ) 9>"$LOCK_FILE" &
}

# Versión síncrona (bloqueante) usada por los subcomandos de CLI/panel, para
# que quien la invoque (p. ej. el panel gráfico) sepa cuándo ha terminado.
reconcile_sync() {
    (
        flock 9 || exit 1
        reconcile_locked
    ) 9>"$LOCK_FILE"
}

# -----------------------------------------------------------------------------
# Integración con systemd (Type=notify + WatchdogSec=, ver write_service_unit).
# Sin nada de esto, "Type=notify" es solo una promesa vacía: systemd espera
# READY=1 hasta TimeoutStartSec y, si nunca llega, da el arranque por
# fallido y lo reinicia en bucle. sd_notify() usa el binario "systemd-notify"
# (parte del propio paquete systemd, siempre presente) en vez de hablar el
# protocolo del socket a mano; si no corre bajo systemd (NOTIFY_SOCKET vacío,
# p. ej. probando "start" a mano en una terminal) no hace nada y no falla.
# Ojo: al ser un binario aparte, systemd-notify envía el aviso con SU PROPIO
# PID, no con el del script; por eso la unidad usa NotifyAccess=all en vez
# de "main" (ver write_service_unit). No cambiar esto sin repetir el mismo
# arreglo ahí.
# -----------------------------------------------------------------------------
sd_notify() {
    [[ -n "${NOTIFY_SOCKET:-}" ]] || return 0
    command -v systemd-notify >/dev/null 2>&1 && systemd-notify "$@" >/dev/null 2>&1
    return 0
}

touch_heartbeat() {
    local tmp
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    tmp="$(mktemp "${HEARTBEAT_FILE}.XXXXXX" 2>/dev/null)" || return 1
    date +%s > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$HEARTBEAT_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Se llama periódicamente desde el bucle principal (ver daemon_main). Solo
# avisa al watchdog de systemd si reconcile_locked() ha completado una
# vuelta hace poco (heartbeat "fresco"): si se queda colgada para siempre en
# una llamada de nmcli/iptables/D-Bus, el heartbeat deja de refrescarse y,
# pasado WatchdogSec sin avisos, systemd mata y reinicia el servicio solo
# (Restart=always), sin ninguna lógica de timeout propia aquí.
watchdog_ping_if_alive() {
    local age=999999 heartbeat
    if [[ -f "$HEARTBEAT_FILE" ]]; then
        heartbeat="$(<"$HEARTBEAT_FILE")"
        if [[ "$heartbeat" =~ ^[0-9]+$ ]]; then
            age=$(( $(date +%s) - heartbeat ))
        fi
    fi
    if (( age < WATCHDOG_STALE_AFTER )); then
        sd_notify WATCHDOG=1
    else
        log_t warn log.watchdog_stale "$age"
    fi
}

# -----------------------------------------------------------------------------
# Bucle principal del demonio
# -----------------------------------------------------------------------------
PERIODIC_PID=""
MONITOR_PID=""
# Calculados en daemon_main a partir de $WATCHDOG_USEC (la fija systemd solo
# si la unidad tiene WatchdogSec>0); en 0 el watchdog queda inactivo, igual
# que si se ejecuta fuera de systemd.
WATCHDOG_PING_INTERVAL=0
WATCHDOG_STALE_AFTER=0

periodic_loop() {
    while true; do
        sleep "$CHECK_INTERVAL"
        config_reload_if_changed announce
        reconcile_async
    done
}

cleanup() {
    log_t info log.daemon_stop
    [[ -n "$PERIODIC_PID" ]] && kill "$PERIODIC_PID" 2>/dev/null
    [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null
    # Deliberadamente NO se retiran las reglas de killswitch al detener el
    # servicio: si el proceso muere o se para, el cortafuegos debe seguir
    # bloqueando el tráfico fuera de la VPN ("fail closed"). Para quitarlo
    # a propósito usa: vpn-netguard.sh killswitch off (o deactivate)
    exit 0
}

configure_watchdog() {
    local watchdog_usec="${WATCHDOG_USEC:-}" normalized watchdog_sec
    [[ "$watchdog_usec" =~ ^[0-9]+$ ]] || return 0
    normalized="$(decimal_normalize_max "$watchdog_usec" 9223372036854775807)" || return 0
    (( normalized > 0 )) || return 0
    watchdog_sec=$(( normalized / 1000000 ))
    (( watchdog_sec > 0 )) || return 0
    WATCHDOG_PING_INTERVAL=$(( watchdog_sec / 2 ))
    (( WATCHDOG_PING_INTERVAL < 1 )) && WATCHDOG_PING_INTERVAL=1
    WATCHDOG_STALE_AFTER=$(( watchdog_sec - WATCHDOG_PING_INTERVAL ))
    if (( CHECK_INTERVAL >= (watchdog_sec + 1) / 2 )); then
        log_t warn log.watchdog_interval "$CHECK_INTERVAL" "$watchdog_sec"
    fi
}

daemon_main() {
    require_root
    mkdir -p "$STATE_DIR"
    state_files_make_readable
    log_t info log.daemon_start "$KILLSWITCH_MODE" "$CHECK_INTERVAL"
    if [[ -n "$ALERT_HOOK" ]] && ! command -v "${ALERT_HOOK%% *}" >/dev/null 2>&1; then
        log_t warn log.alert_hook_missing "$ALERT_HOOK"
    fi
    # Arma el aviso de choque boot-killswitch (ver warn_ks_boot_race_if_stuck)
    # para el primer episodio de bloqueo-sin-VPN de este arranque.
    date +%s > "$KS_BOOT_RACE_PENDING_FILE" 2>/dev/null

    trap cleanup TERM INT

    # Síncrona a propósito: así, si el kill switch debe estar activo, las
    # reglas de bloqueo quedan aplicadas ANTES de seguir arrancando, en vez
    # de dejarlo en segundo plano y abrir una pequeña ventana sin protección
    # justo al iniciar el servicio.
    reconcile_sync || return 1

    # A partir de aquí el arranque se considera terminado: se avisa a
    # systemd (Type=notify) y, si tarda más de TimeoutStartSec en llegar,
    # sube ese valor en vez de tocar nada aquí (ver write_service_unit).
    sd_notify --ready --status="$(ui_t sdnotify.status "$KILLSWITCH_MODE" "$CHECK_INTERVAL")"

    configure_watchdog

    periodic_loop &
    PERIODIC_PID=$!

    # "coproc" (en vez de "exec 3< <(nmcli monitor)") expone un PID real en
    # "$NMCLI_MON_PID": necesario para que cleanup() pueda matar el proceso
    # "nmcli monitor" de verdad al detener el servicio.
    coproc NMCLI_MON { nmcli_c monitor; }
    # shellcheck disable=SC2154 # "coproc NAME" crea NAME_PID automáticamente (bash 4+); no es una variable sin asignar
    MONITOR_PID="$NMCLI_MON_PID"
    local rc
    while true; do
        if (( WATCHDOG_PING_INTERVAL > 0 )); then
            # Con watchdog activo, "read -t" hace de temporizador: si no
            # llega ninguna línea de nmcli monitor en ese rato, se despierta
            # igualmente para poder pingar (o no) al watchdog, sin dejar de
            # atender eventos reales de red en cuanto aparecen.
            IFS= read -r -u "${NMCLI_MON[0]}" -t "$WATCHDOG_PING_INTERVAL" line
            rc=$?
            if (( rc > 128 )); then
                watchdog_ping_if_alive
                continue
            elif (( rc != 0 )); then
                break   # EOF real: nmcli monitor ha terminado
            fi
        else
            IFS= read -r -u "${NMCLI_MON[0]}" line || break
        fi
        config_reload_if_changed
        log_t debug log.nmcli_monitor "$line"
        reconcile_async
    done

    # Si nmcli monitor termina (p. ej. reinicio de NetworkManager),
    # dejamos que systemd reinicie el servicio (Restart=always).
    log_t warn log.nmcli_ended
    cleanup
}

# Filas del kill switch: forzado, modo configurado, política efectiva y reglas
# reales (sin cabecera: la pone quien la llama, ver print_status y cmd_killswitch).
# Requiere KNOWN_VPN ya detectado (la política "auto" depende de ella) y root para
# leer iptables.
print_killswitch_status() {
    local line policy_on=0 rules4=0
    coexist_yield_load
    ui_row "$(ui_t status.l_ks_mode)" "$KILLSWITCH_MODE"
    case "$(killswitch_override_value)" in
        on)  ui_row "$(ui_t status.l_ks_forced)" "$(ui_t status.v_ks_forced_on)" ok ;;
        off) ui_row "$(ui_t status.l_ks_forced)" "$(ui_t status.v_ks_forced_off)" warn ;;
        *)   ui_row "$(ui_t status.l_ks_forced)" "$(ui_t status.v_ks_forced_auto)" ;;
    esac
    if want_vpn_active; then
        ui_row "$(ui_t menu.st_protection)" "$(ui_t menu.st_enabled)" ok
    else
        ui_row "$(ui_t menu.st_protection)" "$(ui_t menu.st_disabled)"
    fi
    if killswitch_should_be_active; then
        policy_on=1; ui_row "$(ui_t status.l_ks_policy)" "$(ui_t status.v_ks_policy_on)"
    else
        ui_row "$(ui_t status.l_ks_policy)" "$(ui_t status.v_ks_policy_off)"
        if killswitch_is_yielding; then
            printf -v line -- "$(ui_t status.v_ks_yielding)" "${FOREIGN_KS[*]}"
            ui_row "$(ui_t status.l_ks_yield)" "$line" warn
        fi
    fi
    if systemctl is-enabled "$BOOT_SERVICE" >/dev/null 2>&1; then
        ui_row "$(ui_t status.l_boot)" "$(ui_t status.v_boot_on)" ok
    else
        ui_row "$(ui_t status.l_boot)" "$(ui_t status.v_boot_off)" warn
    fi
    if ipt -C OUTPUT -j "$CHAIN_NAME" 2>/dev/null; then
        rules4=1; ui_row "$(ui_t status.l_rules4)" "$(ui_t status.v_rules_on)" ok
    else
        ui_row "$(ui_t status.l_rules4)" "$(ui_t status.v_rules_off)" warn
    fi
    if [[ $HAVE_IP6TABLES -eq 1 ]]; then
        if ipt6 -C OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null; then
            ui_row "$(ui_t status.l_rules6)" "$(ui_t status.v_rules_on)" ok
        else
            ui_row "$(ui_t status.l_rules6)" "$(ui_t status.v_rules_off)" warn
        fi
    else
        ui_row "$(ui_t status.l_rules6)" "$(ui_t status.v_rules6_missing)" warn
    fi
    (( policy_on == rules4 )) || ui_note warn "$(ui_t status.ks_mismatch)"
    if [[ -f "$KS_BOOT_RACE_MARKER_FILE" ]]; then
        printf -v line -- "$(ui_t status.ks_autodisabled)" "$(<"$KS_BOOT_RACE_MARKER_FILE")"; ui_note bad "$line"
    fi
}

print_status() {
    detect_known_profiles
    detect_active_state
    local line none alert_desc hist_lines sys_dns_line
    none="$(ui_t none)"
    ui_banner "$(ui_t status.title)"
    ui_block "$(ui_t status.section_network)"
    ui_row "$(ui_t status.l_eth)" "${ACTIVE_ETH:-$none}"
    ui_row "$(ui_t status.l_wifi)" "${ACTIVE_WIFI:-$none}"
    ui_row "$(ui_t status.l_vpn)" "${ACTIVE_VPN:-$none}"
    ui_row "$(ui_t status.l_phys)" "${PHYS_IFACE:-$none}"
    ui_row "$(ui_t status.l_tun)" "${VPN_IFACE:-$none}"
    ui_row "$(ui_t status.l_eth_profiles)" "${KNOWN_ETH[*]:-$none}"
    ui_row "$(ui_t status.l_wifi_profiles)" "${KNOWN_WIFI[*]:-$none}"
    ui_row "$(ui_t status.l_vpn_profiles)" "${KNOWN_VPN[*]:-$none}"
    if [[ ${#IGNORED_VPN[@]} -gt 0 ]]; then
        ui_row "$(ui_t status.l_vpn_ignored)" "${IGNORED_VPN[*]}"
    fi
    ui_block "$(ui_t status.section_killswitch)"
    print_killswitch_status
    ui_block "$(ui_t status.section_coexist)"
    print_coexist_status
    ui_block "$(ui_t privacy.status_title)"
    print_privacy_rows
    ui_block "$(ui_t status.section_connectivity)"
    if check_internet_reachable; then
        ui_row "$(ui_t status.l_internet)" "$(ui_t status.v_internet_ok)" ok
    else
        ui_row "$(ui_t status.l_internet)" "$(ui_t status.v_internet_no)" bad
    fi
    ui_row "$(ui_t status.l_dns)" "${DNS_SERVERS:-$(ui_t status.v_dns_any)}"
    if [[ -n "$DNS_SERVERS" ]]; then
        sys_dns_line="$(system_dns_servers | tr '\n' ' ')"
        sys_dns_line="${sys_dns_line% }"
        ui_row "$(ui_t status.l_system_dns)" "${sys_dns_line:-$(ui_t unknown)}"
        [[ "$HARDEN_BROWSER_DOH" != "true" ]] && ui_note warn "$(ui_t status.doh_warn)"
    fi
    if [[ -n "$ACTIVE_VPN" && "$VPN_TYPE" == "wireguard" ]]; then
        if ! command -v wg >/dev/null 2>&1; then
            ui_row "$(ui_t status.l_wg)" "$(ui_t status.v_wg_missing)"
        elif wg_tunnel_alive "$VPN_IFACE"; then
            ui_row "$(ui_t status.l_wg)" "$(ui_t status.v_wg_recent)" ok
        else
            printf -v line -- "$(ui_t status.v_wg_dead)" "$WG_HANDSHAKE_MAX_AGE"
            ui_row "$(ui_t status.l_wg)" "$line" bad
        fi
    fi
    ui_block "$(ui_t status.section_alerts)"
    alert_desc="$none"
    [[ "$DESKTOP_NOTIFICATIONS" == "true" ]] && alert_desc="$(ui_t ui.desktop_notification)"
    if [[ -n "$ALERT_HOOK" ]]; then
        [[ "$alert_desc" == "$none" ]] && alert_desc="" || alert_desc+=" + "
        if command -v "${ALERT_HOOK%% *}" >/dev/null 2>&1; then
            alert_desc+="hook (${ALERT_HOOK})"
        else
            alert_desc+="hook (${ALERT_HOOK}) [$(ui_t ui.warning_missing_exec)]"
        fi
    fi
    ui_row "$(ui_t status.l_alerts)" "${alert_desc:-$none}"
    if [[ "$EVENT_HISTORY_ENABLE" == "true" ]]; then
        hist_lines=0
        if [[ -f "$EVENT_HISTORY_FILE" ]]; then
            hist_lines=$(( $(wc -l < "$EVENT_HISTORY_FILE" 2>/dev/null || echo 1) - 1 ))   # eventos = líneas - cabecera
            (( hist_lines >= 0 )) || hist_lines=0   # vacío o cabecera sin salto de línea: wc da 0
        fi
        printf -v line -- "$(ui_t status.v_history_on)" "$EVENT_HISTORY_FILE" "$hist_lines"
        ui_row "$(ui_t status.l_history)" "$line"
    else
        ui_row "$(ui_t status.l_history)" "$(ui_t status.v_history_off)"
    fi
    if [[ -n "$PROMETHEUS_TEXTFILE_DIR" ]]; then
        printf -v line -- "$(ui_t status.v_prom)" "$PROMETHEUS_TEXTFILE_DIR"
        ui_row "$(ui_t status.l_prom)" "$line"
    fi
}

# -----------------------------------------------------------------------------
# Métricas para node_exporter (textfile collector). Solo se llama desde
# cmd_check (ver PROMETHEUS_TEXTFILE_DIR en write_default_config). Escritura
# atómica: fichero temporal en el MISMO directorio + mv, para que
# node_exporter —que puede leer el .prom en cualquier instante— nunca vea un
# fichero a medio escribir.
# -----------------------------------------------------------------------------
write_prometheus_metrics() {
    [[ -n "$PROMETHEUS_TEXTFILE_DIR" ]] || return 0
    if [[ ! -d "$PROMETHEUS_TEXTFILE_DIR" ]]; then
        log_t warn log.prom_dir_missing "$PROMETHEUS_TEXTFILE_DIR"
        return 0
    fi

    local status="$1" ks_active="$2" vpn_connected="$3" internet_ok="$4"
    local out="$PROMETHEUS_TEXTFILE_DIR/vpn_netguard.prom" tmp
    tmp="$(mktemp "${PROMETHEUS_TEXTFILE_DIR}/.vpn_netguard.prom.XXXXXX" 2>/dev/null)" || {
        log_t warn log.prom_tmp_fail "$PROMETHEUS_TEXTFILE_DIR"
        return 0
    }

    cat > "$tmp" <<METRICS
# HELP vpn_netguard_check_status Resultado de la última comprobación 'check' (0=OK, 1=AVISO, 2=CRITICO)
# TYPE vpn_netguard_check_status gauge
vpn_netguard_check_status ${status}
# HELP vpn_netguard_killswitch_active Si el kill switch de iptables está activo ahora mismo
# TYPE vpn_netguard_killswitch_active gauge
vpn_netguard_killswitch_active ${ks_active}
# HELP vpn_netguard_vpn_connected Si hay un perfil VPN conectado según NetworkManager
# TYPE vpn_netguard_vpn_connected gauge
vpn_netguard_vpn_connected ${vpn_connected}
# HELP vpn_netguard_internet_reachable Si hay conectividad real (ping) a través del túnel/interfaz activa
# TYPE vpn_netguard_internet_reachable gauge
vpn_netguard_internet_reachable ${internet_ok}
# HELP vpn_netguard_last_check_timestamp_seconds Epoch Unix de esta ejecución de 'check'
# TYPE vpn_netguard_last_check_timestamp_seconds gauge
vpn_netguard_last_check_timestamp_seconds $(date +%s)
METRICS

    chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$out" 2>/dev/null || { log_t warn log.prom_write_fail "$out"; rm -f "$tmp"; }
}

# Comprobación de salud con código de salida, para monitorización en un
# servidor (Nagios/Zabbix/cron) donde nadie mira el texto de "status" a
# diario. Un único resumen en stdout + código de salida:
#   0 = OK        1 = AVISO (degradado pero explicado)   2 = CRÍTICO
# Además, si PROMETHEUS_TEXTFILE_DIR está configurado, deja un .prom con el
# mismo resultado para node_exporter (ver write_prometheus_metrics).
cmd_check() {
    detect_known_profiles
    detect_active_state
    coexist_yield_load

    # ks6_active empieza en 1 (sin problema): si no hay ip6tables, el resto
    # del script ya trata la parte v6 como no aplicable (ver ensure_chain6,
    # apply_killswitch_rules6), así que aquí tampoco debe contar como fallo.
    local ks_active=0 ks6_active=1 vpn_connected=0 internet_ok=0
    ipt -C OUTPUT -j "$CHAIN_NAME" 2>/dev/null && ks_active=1
    if [[ "$DISABLE_IPV6" != "true" && $HAVE_IP6TABLES -eq 1 ]]; then
        ipt6 -C OUTPUT -j "$CHAIN_NAME_V6" 2>/dev/null || ks6_active=0
    fi
    [[ -n "$ACTIVE_VPN" ]] && vpn_connected=1
    tunnel_reachable && internet_ok=1

    local status=0 message=""
    if killswitch_should_be_active; then
        if [[ $ks_active -eq 0 || $ks6_active -eq 0 ]]; then
            status=2; message="$(ui_t check.crit)"
        elif [[ $vpn_connected -eq 0 ]]; then
            status=1; message="$(ui_t check.warn_down)"
        elif [[ $internet_ok -eq 0 ]]; then
            status=1; printf -v message -- "$(ui_t check.vpn_nointernet)" "$ACTIVE_VPN"
        else
            status=0; printf -v message -- "$(ui_t check.ok_protected)" "$ACTIVE_VPN"
        fi
    elif [[ -f "$KS_BOOT_RACE_MARKER_FILE" ]]; then
        status=1; printf -v message -- "$(ui_t check.warn_autodisabled)" "$(<"$KS_BOOT_RACE_MARKER_FILE")"
    elif killswitch_is_yielding && [[ $ks_active -eq 0 ]]; then
        if [[ $internet_ok -eq 0 ]]; then
            status=1; message="$(ui_t check.warn_nointernet)"
        else
            status=0; printf -v message -- "$(ui_t check.ok_yielding)" "${FOREIGN_KS[*]}"
        fi
    elif [[ $ks_active -eq 1 ]]; then
        status=1; printf -v message -- "$(ui_t check.warn_unexpected_ks)" "$KILLSWITCH_MODE"
    elif [[ $internet_ok -eq 0 ]]; then
        status=1; message="$(ui_t check.warn_nointernet)"
    else
        status=0; printf -v message -- "$(ui_t check.ok_not_required)" "$KILLSWITCH_MODE"
    fi

    write_prometheus_metrics "$status" "$((ks_active && ks6_active))" "$vpn_connected" "$internet_ok"
    case $status in
        0) ui_good "$message" ;;
        1) ui_warn "$message" ;;
        *) ui_bad "$message" ;;
    esac
    exit "$status"
}

# Punto único de control del kill switch (ver killswitch_* arriba).
# enable-killswitch / disable-killswitch son alias de "on" / "off".
cmd_killswitch() {
    local action="${1:-}" rc=0
    case "$action" in
        on|off|auto|status) ;;
        *) printf '%s\n' "$(ui_t killswitch.usage)" >&2; return 1 ;;
    esac
    require_root
    case "$action" in
        status)
            detect_known_profiles
            ui_banner "$(ui_t killswitch.status_title)"
            echo
            print_killswitch_status
            return 0
            ;;
        on)   with_killswitch_lock killswitch_force_on_locked || rc=$? ;;
        off)  with_killswitch_lock disable_killswitch_locked || rc=$? ;;
        auto) with_killswitch_lock killswitch_set_auto_locked || rc=$? ;;
    esac
    if (( rc != 0 )); then
        log_t error killswitch.failed
        return "$rc"
    fi
    case "$action" in
        on)   log_t info killswitch.set_on ;;
        off)  log_t info killswitch.set_off ;;
        auto) log_t info killswitch.set_auto "$KILLSWITCH_MODE" ;;
    esac
}

do_activate() {
    detect_known_profiles
    # Solo se retira un "off" forzado. Un "on" explícito del usuario se
    # respeta: activar la protección VPN no debilita el kill switch, que se
    # controla aparte (killswitch on|off|auto).
    if [[ "$(killswitch_override_value)" == off ]]; then
        clear_killswitch_override
    fi
    mark_vpn_wanted
    vpn_backoff_reset
    log_t info log.activate
    if [[ ${#KNOWN_VPN[@]} -eq 0 && ${#IGNORED_VPN[@]} -gt 0 ]]; then
        local ignored_list
        printf -v ignored_list '%s, ' "${IGNORED_VPN[@]}"
        log_t error log.vpn_all_ignored "${ignored_list%, }" "$CONFIG_FILE"
    elif [[ ${#KNOWN_VPN[@]} -eq 0 ]]; then
        log_t error log.no_vpn_profiles "$CONFIG_FILE"
    fi
    reconcile_sync || return 1
}

do_deactivate() {
    detect_known_profiles
    detect_active_state
    log_t info log.deactivate
    unmark_vpn_wanted
    # Fuerza el override a "off" (no solo lo limpia): si KILLSWITCH_MODE=true,
    # limpiarlo dejaría que la próxima reconciliación lo reactivara solo.
    # "Desactivar protección" tiene que significar apagado de verdad, sin
    # importar el modo configurado. Mismo patrón que "killswitch off" manual.
    # Bajo el mismo flock que usa la reconciliación del demonio (ver
    # with_killswitch_lock), para no intercalarse con ella.
    with_killswitch_lock disable_killswitch_locked || return 1
    if active_vpn_is_ignored; then
        log_t info log.vpn_ignored_kept "$ACTIVE_VPN"
    elif [[ -n "$ACTIVE_VPN" ]]; then
        nmcli_c connection down "$ACTIVE_VPN" >/dev/null 2>&1 || return 1
        log_t info log.vpn_disconnected "$ACTIVE_VPN"
    fi
}

# -----------------------------------------------------------------------------
# "1-click y olvidar" (K6): un subcomando raíz, así que sudo/pkexec piden la
# contraseña UNA vez. No pregunta nada: menú y panel piden confirmación antes
# (como con apply-privacy). El perfil es one_click_config_keys.
# Antes de tocar nada muestra avisos de solo lectura (one_click_preflight; no
# cambian el resultado). Pasos: copia de seguridad, perfil, anonimato de red,
# protección VPN y reinicio del servicio; cada uno se muestra con ✓ / ✗ y, si
# falla, con su salida.
# Salida: 0 = perfil aplicado; 1 = no se cambió nada (sin configuración o
# rechazada por config_file_is_safe, sin copia de seguridad, perfil sin guardar);
# 2 = perfil guardado pero algún paso posterior falló.
# -----------------------------------------------------------------------------
ONE_CLICK_FAILED=0

# one_click_step <texto_ok> <texto_fallo> <comando...>: ejecuta el paso sin
# ensuciar el resumen con su registro; solo lo muestra, sangrado, si falla.
one_click_step() {
    local ok_msg="$1" fail_msg="$2" out rc
    shift 2
    out="$("$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then
        ui_good "$ok_msg"
        return 0
    fi
    ui_bad "$fail_msg"
    [[ -n "$out" ]] && sed 's/^/    /' <<< "$out"
    ONE_CLICK_FAILED=$((ONE_CLICK_FAILED + 1))
    return "$rc"
}

# Avisos previos, una línea por aviso y solo lectura. El perfil fija
# COEXIST_MODE=auto, así que se escanea aunque ahora esté en strict. Un forzado
# OFF no cuenta: do_activate lo retira.
one_click_preflight() {
    local -a FOREIGN_TUNNELS=() FOREIGN_MARKS=() FOREIGN_KS=()
    local line
    detect_known_profiles
    detect_active_state
    foreign_vpn_scan
    if (( ${#FOREIGN_KS[@]} )); then
        if [[ "$(killswitch_override_value)" == on ]]; then
            printf -v line -- "$(ui_t status.coexist_rec_forced)" 'killswitch auto' "${FOREIGN_KS[*]}"
        else
            printf -v line -- "$(ui_t status.coexist_yielding)" "${FOREIGN_KS[*]}"
        fi
        printf '%s\n' "$line"
    elif (( ${#FOREIGN_TUNNELS[@]} )); then
        printf -v line -- "$(ui_t oneclick.pre_tunnels)" "${FOREIGN_TUNNELS[*]}"
        printf '%s\n' "$line"
    fi
    if [[ -f "$UNIT_DST" ]] && ! systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then
        printf -v line -- "$(ui_t oneclick.pre_autostart)" "$SERVICE" "$SERVICE"
        printf '%s\n' "$line"
    fi
    return 0
}

# do_activate devuelve 0 sin perfil VPN (solo deja la protección «deseada»):
# 1-click no puede anunciarla como activada. Su registro lleva la razón y
# one_click_step lo muestra al fallar.
one_click_activate() {
    do_activate || return 1
    (( ${#KNOWN_VPN[@]} > 0 ))
}

# Deshace una escritura fallida del perfil: si la configuración ya no es la de
# la copia (install borra el destino antes de escribirlo), la restaura. Borra la
# copia solo cuando la configuración vuelve a estar como estaba.
one_click_rollback() {
    local backup="$1" msg
    if ! cmp -s -- "$backup" "$CONFIG_FILE" &&
       ! install -o root -g root -m 644 "$backup" "$CONFIG_FILE" 2>/dev/null; then
        printf -v msg -- "$(ui_t oneclick.restore_fail)" "$backup"
        ui_bad "$msg" >&2
        return 1
    fi
    rm -f "$backup"
    printf -v msg -- "$(ui_t oneclick.save_fail)" "$CONFIG_FILE"
    ui_bad "$msg" >&2
}

cmd_one_click() {
    local backup msg line old_doh="$HARDEN_BROWSER_DOH"
    local -a pre
    ONE_CLICK_FAILED=0
    ui_section "$(ui_t panel.one_click)"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf -v msg -- "$(ui_t config.install_first)" "$CONFIG_FILE"
        ui_bad "$msg" >&2
        return 1
    fi
    # Un fichero rechazado se ignora ENTERO (load_config usa los valores por
    # defecto): escribirle el perfil sería anunciar un éxito que no existe.
    if ! config_file_is_safe "$CONFIG_FILE"; then
        printf -v msg -- "$(ui_t oneclick.config_unsafe)" "$CONFIG_FILE"
        ui_bad "$msg" >&2
        return 1
    fi
    mapfile -t pre < <(one_click_preflight)
    if (( ${#pre[@]} )); then
        ui_section "$(ui_t oneclick.pre_title)"
        for line in "${pre[@]}"; do ui_warn "$line"; done
    fi
    backup="$(config_backup_make)" || { ui_bad "$(ui_t oneclick.backup_fail)" >&2; return 1; }
    printf -v msg -- "$(ui_t oneclick.backup_ok)" "$backup"
    ui_good "$msg"

    local -a keys
    mapfile -t keys < <(one_click_config_keys)
    if ! panel_write_config_keys "${keys[@]}"; then
        one_click_rollback "$backup"
        return 1
    fi
    printf -v msg -- "$(ui_t oneclick.profile_ok)" "$CONFIG_FILE"
    ui_good "$msg"
    load_config >/dev/null 2>&1   # los pasos siguientes usan el perfil, no la configuración anterior

    one_click_step "$(ui_t oneclick.privacy_ok)" "$(ui_t oneclick.privacy_fail)" apply_network_privacy
    one_click_step "$(ui_t oneclick.activate_ok)" "$(ui_t oneclick.activate_fail)" one_click_activate
    if [[ -f "$UNIT_DST" ]]; then
        local ok_msg fail_msg
        printf -v ok_msg -- "$(ui_t oneclick.service_ok)" "$SERVICE"
        printf -v fail_msg -- "$(ui_t oneclick.service_fail)" "$SERVICE"
        one_click_step "$ok_msg" "$fail_msg" systemctl restart "$SERVICE"
    else
        printf -v msg -- "$(ui_t oneclick.service_skip)" "$SERVICE"
        ui_warn "$msg"
    fi

    echo
    if (( ONE_CLICK_FAILED > 0 )); then
        ui_warn "$(ui_t oneclick.partial)"
        return 2
    fi
    echo "$(ui_t panel.one_click_done)"
    echo "$(ui_t panel.privacy_reconnect_hint)"
    [[ "$old_doh" != "$HARDEN_BROWSER_DOH" ]] && echo "$(ui_t panel.doh_restart_browser)"
    return 0
}

# =============================================================================
# PANEL GRÁFICO (antes vpn-netguard-panel.sh) — se ejecuta como usuario
# normal; cada acción que necesita privilegios de root la eleva puntualmente
# con `pkexec`, llamando siempre a la copia instalada en $BIN_DST.
# =============================================================================
panel_require_zenity() {
    if ! command -v zenity >/dev/null 2>&1; then
        echo "$(ui_t panel.zenity_missing)" >&2
        exit 1
    fi
    if ! have_gui_session; then
        echo "$(ui_t panel.no_gui)" >&2
        echo "$(ui_t panel.use_menu)" >&2
        exit 1
    fi
}

# Envoltorio fino sobre el binario real: todas las llamadas del script usan
# "zenity_ui" en vez de "zenity" para que cada ventana lleve nuestro icono
# (si no, cada diálogo muestra el icono genérico de zenity según su tipo).
zenity_ui() {
    # Si el locale activo no es UTF-8 (sesión gráfica/lanzador que no exporta
    # LANG, o locale es_ES.UTF-8 no generado), GOption rechaza con un error
    # opaco cualquier texto con tildes/ñ y zenity ni abre ventana: el panel
    # "no se abre" sin ningún aviso (Terminal=false en el .desktop se lo
    # traga). Forzamos C.UTF-8 -viene con glibc, no requiere locale-gen-
    # solo para esta llamada y solo si hace falta.
    local -a lc_fix=()
    [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]] || lc_fix=(env LC_ALL=C.UTF-8)
    if [[ -r "$ICON_DST" ]]; then
        "${lc_fix[@]}" zenity --window-icon="$ICON_DST" "$@"
    else
        "${lc_fix[@]}" zenity "$@"
    fi
}

panel_require_installed() {
    if [[ ! -x "$BIN_DST" ]]; then
        local msg
        printf -v msg -- "$(ui_t panel.not_installed)" "$BIN_DST"
        zenity_ui --error --title="$TITLE" --width=420 --text="$msg"
        exit 1
    fi
}

panel_info_box() {
    zenity_ui --info --title="$TITLE" --width=480 --text="$1"
}

panel_error_box() {
    zenity_ui --error --title="$TITLE" --width=480 --text="$1"
}

panel_confirm_box() {
    zenity_ui --question --title="$TITLE" --width=420 --text="$1"
}

# Ejecuta un comando privilegiado vía pkexec y muestra el resultado si falla.
# Uso: panel_run_privileged -- comando args...
panel_run_privileged() {
    [[ "$1" == "--" ]] && shift
    local out rc msg
    out="$(pkexec "$@" 2>&1)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        printf -v msg -- "$(ui_t panel.fail)" "$*" "${out:-$(ui_t ui.no_output)}"
        panel_error_box "$msg"
    fi
    return $rc
}

# Las pantallas de estado miden UI_WIDTH (64) columnas: en Monospace piden ~620 px.
PANEL_STATUS_W=640

# Un texto de estado corto va en --info (un solo botón: Aceptar); uno largo, en --text-info, que
# desplaza pero lleva siempre Cancelar y Aceptar (zenity 4 no admite --no-cancel ahí). --info
# ignora --height y crece con el texto: por eso el tope de saltos de línea.
PANEL_INFO_MAX_LINES=28

# 1 si el panel se cerró porque se eligió «interface» (volver a la terminal), 0 si salió de otro
# modo. panel_main_menu la pone a 0 al empezar; el llamador de cmd_panel la lee al volver.
PANEL_BACK_TO_TERMINAL=0

panel_status_screen() {   # <título> <alto de --text-info> <texto>
    local title="$1" height="$2" text="$3" nl
    nl="${text//[^$'\n']/}"
    if (( ${#nl} < PANEL_INFO_MAX_LINES )); then
        zenity_ui --info --title="$title" --width="$PANEL_STATUS_W" --no-wrap --text="<tt>$(pango_escape "$text")</tt>"
    else
        zenity_ui --text-info --title="$title" --width="$PANEL_STATUS_W" --height="$height" --font="Monospace" <<< "$text"
    fi
}

panel_action_status() {
    local out
    out="$(pkexec "$BIN_DST" status 2>&1)"
    panel_status_screen "$TITLE - $(ui_t panel.status)" 600 "$out"
}

panel_action_activate() {
    panel_confirm_box "$(ui_t menu.confirm_activate)" || return
    panel_run_privileged -- "$BIN_DST" activate && panel_info_box "$(ui_t panel.activate)"
}

panel_action_deactivate() {
    panel_confirm_box "$(ui_t menu.confirm_deactivate)" || return
    panel_run_privileged -- "$BIN_DST" deactivate && panel_info_box "$(ui_t panel.deactivate)"
}

# Protección VPN: un solo submenú (Activar / Desactivar).
panel_protection_submenu() {
    while true; do
        local choice
        choice="$(zenity_ui --list --title="$TITLE - $(ui_t protection.title)" --width=480 --height=260 \
            --text="$(ui_t protection.title)" --hide-header --print-column=1 --hide-column=1 \
            --column="ID" --column="$(ui_t protection.title)" -- \
            1 "$(ui_t protection.menu_on)" \
            2 "$(ui_t protection.menu_off)" \
            0 "$(ui_t panel.back)")"
        [[ $? -ne 0 || -z "$choice" ]] && return
        case "$choice" in
            1) panel_action_activate ;;
            2) panel_action_deactivate ;;
            0) return ;;
        esac
    done
}

# Kill switch: un solo submenú (Activar / Desactivar / Automático / Estado).
# Las confirmaciones reutilizan los textos del menú de texto.
panel_action_killswitch_on() {
    panel_confirm_box "$(ui_t menu.confirm_enable_ks)" || return
    panel_run_privileged -- "$BIN_DST" killswitch on && panel_info_box "$(ui_t panel.ks_enabled)"
}

panel_action_killswitch_off() {
    panel_confirm_box "$(ui_t menu.confirm_disable)" || return
    panel_run_privileged -- "$BIN_DST" killswitch off && panel_info_box "$(ui_t panel.ks_disabled)"
}

panel_action_killswitch_auto() {
    panel_run_privileged -- "$BIN_DST" killswitch auto && panel_info_box "$(ui_t panel.ks_auto)"
}

panel_action_killswitch_status() {
    local out
    out="$(pkexec "$BIN_DST" killswitch status 2>&1)"
    panel_status_screen "$TITLE - $(ui_t killswitch.title)" 340 "$out"
}

panel_killswitch_submenu() {
    while true; do
        local choice
        choice="$(zenity_ui --list --title="$TITLE - $(ui_t killswitch.title)" --width=480 --height=320 \
            --text="$(ui_t killswitch.title)" --hide-header --print-column=1 --hide-column=1 \
            --column="ID" --column="$(ui_t killswitch.title)" -- \
            1 "$(ui_t killswitch.menu_on)" \
            2 "$(ui_t killswitch.menu_off)" \
            3 "$(ui_t killswitch.menu_auto)" \
            4 "$(ui_t killswitch.menu_status)" \
            0 "$(ui_t panel.back)")"
        [[ $? -ne 0 || -z "$choice" ]] && return
        case "$choice" in
            1) panel_action_killswitch_on ;;
            2) panel_action_killswitch_off ;;
            3) panel_action_killswitch_auto ;;
            4) panel_action_killswitch_status ;;
            0) return ;;
        esac
    done
}

# Perfil "1-click y olvidar" ("equilibrado y compatible", PLAN sección 8),
# compartido por el panel y el menú de texto: kill switch automático que cede
# ante otro kill switch activo, LAN permitida, notificaciones y anonimato de
# red sin lo que rompe cosas (MAC estable por red que cambia en cada arranque,
# IPv6 privado, hostname y mDNS ocultos; sin tocar Avahi, NetBIOS ni el DoH de
# los navegadores). Las opciones más estrictas siguen en "Ajustes de anonimato".
one_click_config_keys() {
    printf '%s\n' \
        KILLSWITCH_MODE=auto \
        COEXIST_MODE=auto \
        KILLSWITCH_BOOT_RACE_AUTO_DISABLE=true \
        ALLOW_LAN=true \
        DESKTOP_NOTIFICATIONS=true \
        ANONYMIZE_NETWORK=true \
        MAC_MODE=stable \
        ROTATE_MAC_PER_BOOT=true \
        RANDOMIZE_SCAN_MAC=true \
        SPOOF_HOSTNAME=true \
        HARDEN_DHCP_IDENTIFIERS=true \
        IPV6_PRIVACY=true \
        DISABLE_MDNS_ANNOUNCE=true \
        DISABLE_AVAHI_SERVICE=false \
        DISABLE_NETBIOS_SERVICE=false \
        HARDEN_BROWSER_DOH=false
}

# "1-click y olvidar": un único aviso antes de tocar nada (reforzado si hay
# sesión SSH, mismo criterio que panel_confirm_apply_privacy) porque sustituye
# de golpe varios ajustes, incluidos la MAC de red y el kill switch. Todo el
# trabajo lo hace el subcomando raíz one-click: una sola llamada a pkexec, una
# sola contraseña. Salida 0, 1 o 2 = el subcomando habló y se muestra su
# resumen; otro código (pkexec 126 o 127: cancelado o sin autorización) es un
# fallo de la elevación y va a una caja de error.
panel_action_one_click() {
    [[ -f "$CONFIG_FILE" ]] || { local m; printf -v m -- "$(ui_t config.missing)" "$CONFIG_FILE"; panel_error_box "$m"; return; }

    local text out rc msg
    text="$(ui_t panel.one_click_confirm)"
    is_ssh_session && text="$(ui_t panel.one_click_confirm_ssh)"
    panel_confirm_box "$text" || return

    out="$(pkexec "$BIN_DST" one-click 2>&1)"
    rc=$?
    case $rc in
        0|1|2)
            load_config >/dev/null 2>&1
            zenity_ui --text-info --title="$TITLE - $(ui_t panel.one_click)" --width=680 --height=480 --font="Monospace" <<< "$out"
            ;;
        *)
            printf -v msg -- "$(ui_t panel.fail)" "$BIN_DST one-click" "${out:-$(ui_t ui.no_output)}"
            panel_error_box "$msg"
            ;;
    esac
}

panel_action_start_service() {
    panel_run_privileged -- systemctl start "$SERVICE" && panel_info_box "$(ui_t panel.service_started)"
}

panel_action_stop_service() {
    panel_confirm_box "$(ui_t panel.confirm_stop)" || return
    panel_run_privileged -- systemctl stop "$SERVICE" && panel_info_box "$(ui_t panel.service_stopped)"
}

panel_action_restart_service() {
    panel_run_privileged -- systemctl restart "$SERVICE" && panel_info_box "$(ui_t panel.service_restarted)"
}

panel_action_enable_autostart() {
    panel_run_privileged -- systemctl enable "$SERVICE" "$BOOT_SERVICE" && panel_info_box "$(ui_t panel.autostart_on)"
}

panel_action_disable_autostart() {
    panel_run_privileged -- systemctl disable "$SERVICE" "$BOOT_SERVICE" && panel_info_box "$(ui_t panel.autostart_off)"
}

panel_action_logs() {
    local out header
    printf -v header -- "$(ui_t panel.logs_header)" "$SERVICE" 300
    out="$(pkexec journalctl -u "$SERVICE" -n 300 --no-pager 2>&1)"
    zenity_ui --text-info --title="$TITLE - $(ui_t panel.logs)" --width=780 --height=500 --font="Monospace" <<< "$header"$'\n\n'"$out"
}

panel_get_val() {
    local key="$1"
    ( load_config >/dev/null; printf '%s' "${!key}" )
}

panel_order_combo() {
    local current="$1"; shift
    local list="$current" o
    for o in "$@"; do
        [[ "$o" != "$current" ]] && list+="|$o"
    done
    echo "$list"
}

# Mismo centinela que menu_prompt_text: en blanco = no cambiar, "-" = vaciar
# el campo. Los --add-entry de zenity no distinguen "vacío" de "no tocado",
# así que sin esto no hay forma de borrar un campo opcional (VPN_CONNECTION,
# ALERT_HOOK...) desde el panel sin editar el fichero a mano.
panel_sentinel_or_keep() {
    local new="$1" current="$2"
    if [[ "$new" == "-" ]]; then
        printf ''
    elif [[ "$new" =~ ^[[:space:]]*$ ]]; then
        # En blanco o solo espacios (p. ej. un espacio suelto escrito por
        # error): se trata igual que "no tocado", no como un valor real.
        printf '%s' "$current"
    else
        printf '%s' "$new"
    fi
}

# panel_enum_or_keep <CLAVE> <valor_nuevo> <valor_actual>
# Para campos de combo (enum): solo acepta <valor_nuevo> si coincide EXACTO
# con una de las opciones reales de <CLAVE> (las mismas que ofrece su combo,
# obtenidas de menu_field_spec); cualquier otra cosa -vacío, con espacios, o
# lo que sea- conserva <valor_actual>. Antes de esto, el resultado de zenity
# se escribía tal cual en el config sin validar, y un valor inesperado en un
# combo (p. ej. un solo espacio) quedaba guardado sin que nada lo impidiera;
# como load_config solo corrige el valor en memoria y nunca reescribe el
# fichero, el aviso de "valor inválido" se repetía en cada arranque.
panel_enum_or_keep() {
    local key="$1" new="$2" current="$3"
    local spec opts o
    spec="$(menu_field_spec "$key")"
    [[ "$spec" == enum:* ]] || { printf '%s' "$new"; return; }
    IFS=',' read -r -a opts <<< "${spec#*:}"
    for o in "${opts[@]}"; do
        [[ "$new" == "$o" ]] && { printf '%s' "$new"; return; }
    done
    printf '%s' "$current"
}

# panel_write_config_keys "CLAVE1=valor1" "CLAVE2=valor2" ...
#
# Reemplaza (o añade al final si no existiera) solo las claves indicadas en
# "$@", leyendo $CONFIG_FILE línea a línea; todo lo demás —comentarios,
# otras claves, orden del fichero— queda intacto. Así el diálogo de
# killswitch y el de anonimato de red pueden guardar cada uno sus propias
# claves sin pisar las del otro. El VALOR va sin comillas manuales del
# llamador: se escapa aquí con "%q" (a prueba de espacios, comillas,
# "$(...)", etc.), así que "CLAVE=$valor" basta y queda seguro para el
# "source" posterior de load_config aunque $valor venga de un campo de
# texto libre del panel/menú.
#
# No guarda nada que config_file_is_safe rechazaría: load_config ignora ENTERO
# un fichero rechazado y se perderían, entre otros, KILLSWITCH_MODE y
# DNS_SERVERS. Ni sobre una configuración que ya lo es (el cambio no tendría
# efecto) ni un valor que supere CONFIG_VALUE_MAX. Devuelve 1 sin tocar
# $CONFIG_FILE, con el motivo en $CONFIG_WRITE_ERROR y en stderr.
panel_write_config_keys() {
    CONFIG_WRITE_ERROR=""
    [[ -f "$CONFIG_FILE" ]] || return 1
    if ! config_file_is_safe "$CONFIG_FILE"; then
        printf -v CONFIG_WRITE_ERROR -- "$(ui_t config.write_current_rejected)" "$CONFIG_FILE"
        printf '%s\n' "$CONFIG_WRITE_ERROR" >&2
        return 1
    fi

    local -A pending=()
    local kv
    for kv in "$@"; do
        pending["${kv%%=*}"]="${kv#*=}"
    done

    local tmpfile
    tmpfile="$(mktemp)" || return 1
    local line key found=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            if [[ -v "pending[$key]" ]]; then
                printf '%s=%q\n' "$key" "${pending[$key]}" >> "$tmpfile"
                found+=" $key "
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmpfile"
    done < "$CONFIG_FILE"

    for key in "${!pending[@]}"; do
        [[ "$found" == *" $key "* ]] || printf '%s=%q\n' "$key" "${pending[$key]}" >> "$tmpfile"
    done

    # Lo que se instala lo acepta config_file_is_safe. Motivo: el primer valor de
    # "$@" que, escapado, supera CONFIG_VALUE_MAX; si es otra cosa, rechazo genérico.
    if ! config_file_is_safe "$tmpfile"; then
        rm -f "$tmpfile"
        CONFIG_WRITE_ERROR="$(ui_t config.write_rejected)"
        local rhs
        for kv in "$@"; do
            key="${kv%%=*}"
            printf -v rhs '%q' "${pending[$key]}"
            (( ${#rhs} > CONFIG_VALUE_MAX )) || continue
            printf -v CONFIG_WRITE_ERROR -- "$(ui_t config.write_too_long)" "$key" "${#rhs}" "$CONFIG_VALUE_MAX"
            break
        done
        printf '%s\n' "$CONFIG_WRITE_ERROR" >&2
        return 1
    fi

    # Misma elevación que menu_elevate (root directo; sudo antes que pkexec
    # si no hay sesión gráfica). Antes usaba pkexec en cuanto no era root,
    # lo que fallaba al guardar desde el menú de texto en un servidor sin
    # agente de polkit de escritorio.
    if menu_elevate install -D -o root -g root -m 644 "$tmpfile" "$CONFIG_FILE"; then
        rm -f "$tmpfile"
        return 0
    fi
    rm -f "$tmpfile"
    return 1
}

# Cuadro de error de un guardado fallido: el texto general y, debajo, el motivo
# de panel_write_config_keys (CONFIG_WRITE_ERROR). Desde un lanzador el stderr no
# se ve, y el motivo lleva la ruta de la configuración y nombres de clave: se escapa.
panel_config_write_error_box() {
    local msg="$1"
    [[ -n "$CONFIG_WRITE_ERROR" ]] && msg+="\n\n$(pango_escape "$CONFIG_WRITE_ERROR")"
    panel_error_box "$msg"
}

# Etiqueta de un campo de formulario: nombre de la opción, valor actual entre paréntesis (solo con
# 2.º argumento: los campos de texto; un combo ya lo muestra seleccionado) y, en una segunda línea,
# su explicación (ui_field_help). Sin explicación, una sola línea.
panel_field_label() {   # <CLAVE> [valor actual]
    local text help
    text="$(ui_field_label "$1")"
    (( $# > 1 )) && text+=" ($(printf -- "$(ui_t ui.current)" "$2"))"
    help="$(ui_field_help "$1")"
    [[ -n "$help" ]] && text+=$'\n'"$help"
    printf '%s' "$text"
}

# Acceso directo al idioma: mismo guardado/sincronizado que panel_action_configure
# (panel_write_config_keys + sync-localized si cambia), pero con un único
# combo en vez del formulario completo de configuración general.
panel_action_change_language() {
    [[ -f "$CONFIG_FILE" ]] || { local m; printf -v m -- "$(ui_t config.missing)" "$CONFIG_FILE"; panel_error_box "$m"; return; }

    local label val result old_language="$UI_LANGUAGE"
    label="$(ui_field_label LANGUAGE)"
    val="$(panel_get_val LANGUAGE)"
    result="$(zenity_ui --forms --title="$TITLE - $label" --width=360 \
        --add-combo="$label" --combo-values="$(panel_order_combo "$val" es en)")" || return
    [[ -z "$result" ]] && return
    result="$(panel_enum_or_keep LANGUAGE "$result" "$val")"

    if panel_write_config_keys "LANGUAGE=$result"; then
        load_config >/dev/null 2>&1
        local saved_msg
        saved_msg="$(ui_t panel.config_saved)"
        [[ -x "$BIN_DST" ]] && saved_msg+="\n\n$(ui_t panel.config_auto)"
        if [[ "$old_language" != "$UI_LANGUAGE" && -x "$BIN_DST" ]]; then
            panel_run_privileged -- "$BIN_DST" sync-localized || panel_error_box "$(ui_t panel.sync_lang_failed)"
            saved_msg+="\n\n$(ui_t panel.reopen_app_menu)"
        fi
        panel_info_box "$saved_msg"
    else
        panel_config_write_error_box "$(ui_t panel.config_save_fail)"
    fi
}

panel_action_configure() {
    [[ -f "$CONFIG_FILE" ]] || { local m; printf -v m -- "$(ui_t config.missing)" "$CONFIG_FILE"; panel_error_box "$m"; return; }

    local -a keys=(LANGUAGE KILLSWITCH_MODE KILLSWITCH_BOOT_RACE_AUTO_DISABLE COEXIST_MODE ALLOW_LAN LOG_LEVEL DESKTOP_NOTIFICATIONS CHECK_INTERVAL RECONNECT_BACKOFF PING_TARGETS PING_TIMEOUT ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_PRIORITY VPN_IGNORE VPN_ENDPOINT_OVERRIDE DNS_SERVERS ALERT_HOOK)
    local -a forms=()
    local k val
    for k in "${keys[@]}"; do
        val="$(panel_get_val "$k")"
        case "$k" in
            LANGUAGE) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" es en)") ;;
            KILLSWITCH_MODE) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" auto true false)") ;;
            KILLSWITCH_BOOT_RACE_AUTO_DISABLE) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" false true)") ;;
            COEXIST_MODE) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" auto strict)") ;;
            ALLOW_LAN) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" true false)") ;;
            LOG_LEVEL) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" info debug warn error)") ;;
            DESKTOP_NOTIFICATIONS) forms+=(--add-combo="$(panel_field_label "$k")" --combo-values="$(panel_order_combo "$val" true false)") ;;
            CHECK_INTERVAL|RECONNECT_BACKOFF|PING_TARGETS|PING_TIMEOUT|ETH_CONNECTION|WIFI_CONNECTION|VPN_CONNECTION|VPN_PRIORITY|VPN_IGNORE|VPN_ENDPOINT_OVERRIDE|DNS_SERVERS|ALERT_HOOK)
                forms+=(--add-entry="$(panel_field_label "$k" "${val:-auto}")") ;;
        esac
    done

    local -a dialog=(--forms --title="$TITLE - $(ui_t panel.config)" --width=560
        --text="$(ui_t panel.config_help)")
    dialog+=("${forms[@]}")
    local result
    result="$(zenity_ui "${dialog[@]}" )" || return
    [[ -z "$result" ]] && return

    local -a vals=()
    IFS='|' read -r -a vals <<< "$result"
    local old_language="$UI_LANGUAGE"
    local i new
    local -a kvs=()
    for i in "${!keys[@]}"; do
        new="${vals[$i]-}"
        val="$(panel_get_val "${keys[$i]}")"
        case "${keys[$i]}" in
            CHECK_INTERVAL|RECONNECT_BACKOFF|PING_TARGETS|PING_TIMEOUT|ETH_CONNECTION|WIFI_CONNECTION|VPN_CONNECTION|VPN_PRIORITY|VPN_IGNORE|VPN_ENDPOINT_OVERRIDE|DNS_SERVERS|ALERT_HOOK)
                new="$(panel_sentinel_or_keep "$new" "$val")" ;;
            *)
                new="$(panel_enum_or_keep "${keys[$i]}" "$new" "$val")" ;;
        esac
        kvs+=("${keys[$i]}=$new")
    done

    if panel_write_config_keys "${kvs[@]}"; then
        load_config >/dev/null 2>&1
        local saved_msg
        saved_msg="$(ui_t panel.config_saved)"
        [[ -x "$BIN_DST" ]] && saved_msg+="\n\n$(ui_t panel.config_auto)"
        if [[ "$old_language" != "$UI_LANGUAGE" && -x "$BIN_DST" ]]; then
            panel_run_privileged -- "$BIN_DST" sync-localized || panel_error_box "$(ui_t panel.sync_lang_failed)"
            saved_msg+="\n\n$(ui_t panel.reopen_app_menu)"
        fi
        if [[ -z "$VPN_ENDPOINT_OVERRIDE" ]] && boot_killswitch_would_block; then
            saved_msg+="\n\n$(ks_boot_race_warning_text)"
        fi
        panel_info_box "$saved_msg"
    else
        panel_config_write_error_box "$(ui_t panel.config_save_fail)"
    fi
}

# Confirmación antes de aplicar anonimato de red de verdad, con el aviso
# reforzado si hay sesión SSH (posible servidor remoto, ver is_ssh_session):
# la usa Aceptar en «Ajustes de anonimato de red» (aviso del riesgo de perder la
# propia conexión en un VPS que filtre por MAC).
panel_confirm_apply_privacy() {
    local text
    text="$(ui_t menu.confirm_privacy)"
    is_ssh_session && text="$(ui_t install.ssh_warning)"
    panel_confirm_box "$text"
}

# -----------------------------------------------------------------------------
# Panel: anonimato de red (MAC, IPv6, hostname, mDNS/NetBIOS). Es la entrada de
# «Ajustes de anonimato de red» (sin submenú). Diálogo independiente del de
# arriba para no mezclar dos temas en un único formulario gigante, y para que
# guardar uno nunca pise las claves del otro (panel_write_config_keys solo toca
# las claves que se le pasan).
# Botones: Cancelar, Aceptar y «Ver estado» (--extra-button; zenity 4.0.1 lo
# admite en --forms). Medido: Cancelar sale con 1 y sin salida, Aceptar con 0 y
# los valores, «Ver estado» con 1 y solo su etiqueta (sin valores: lo escrito se
# pierde y el formulario se reabre con los guardados).
# Aceptar guarda solo si algún valor cambió (si falla, caja de error y no se
# aplica), pide confirmación (con el aviso de SSH) y aplica. Sin cambios también
# confirma y aplica. «Guardada» solo sale si hubo cambios y no se llegó a aplicar.
# -----------------------------------------------------------------------------
panel_action_configure_privacy() {
    [[ -f "$CONFIG_FILE" ]] || { local m; printf -v m -- "$(ui_t config.missing)" "$CONFIG_FILE"; panel_error_box "$m"; return; }

    local -a keys=(ANONYMIZE_NETWORK MAC_MODE MAC_OUI_MASK ROTATE_MAC_PER_BOOT ROTATE_MAC_EVERY_HOURS RANDOMIZE_SCAN_MAC SPOOF_HOSTNAME DHCP_HOSTNAME_OVERRIDE HARDEN_DHCP_IDENTIFIERS IPV6_PRIVACY DISABLE_IPV6 DISABLE_MDNS_ANNOUNCE DISABLE_AVAHI_SERVICE DISABLE_NETBIOS_SERVICE HARDEN_BROWSER_DOH)
    local -a forms=() form_now=()
    local key val
    for key in "${keys[@]}"; do
        val="$(panel_get_val "$key")"; form_now+=("$val")
        case "$key" in
            ANONYMIZE_NETWORK|ROTATE_MAC_PER_BOOT|RANDOMIZE_SCAN_MAC|SPOOF_HOSTNAME|HARDEN_DHCP_IDENTIFIERS|IPV6_PRIVACY|DISABLE_IPV6|DISABLE_MDNS_ANNOUNCE|DISABLE_AVAHI_SERVICE|DISABLE_NETBIOS_SERVICE|HARDEN_BROWSER_DOH)
                forms+=(--add-combo="$(panel_field_label "$key")" --combo-values="$(panel_order_combo "$val" false true)") ;;
            MAC_MODE) forms+=(--add-combo="$(panel_field_label "$key")" --combo-values="$(panel_order_combo "$val" stable random off)") ;;
            *) forms+=(--add-entry="$(panel_field_label "$key" "${val:-$(ui_t ui.none_value)}")") ;;
        esac
    done
    local result rc status_label help
    status_label="$(ui_t privacy.menu_status)"
    printf -v help -- "$(ui_t panel.privacy_help)" "$status_label"
    local -a dialog=(--forms --title="$TITLE - $(ui_t panel.privacy)" --width=600 --text="$help")
    dialog+=("${forms[@]}")
    while true; do
        result="$(zenity_ui "${dialog[@]}" --extra-button="$status_label")"; rc=$?
        [[ $rc -eq 1 && "$result" == "$status_label" ]] || break
        panel_action_privacy_status
    done
    [[ $rc -eq 0 && -n "$result" ]] || return

    local -a vals=(); IFS='|' read -r -a vals <<< "$result"
    local -a kvs=()
    local i new changed=0 doh_changed=0
    for i in "${!keys[@]}"; do
        new="${vals[$i]-}"; val="${form_now[$i]}"
        case "${keys[$i]}" in
            MAC_OUI_MASK|ROTATE_MAC_EVERY_HOURS|DHCP_HOSTNAME_OVERRIDE) new="$(panel_sentinel_or_keep "$new" "$val")" ;;
            *) new="$(panel_enum_or_keep "${keys[$i]}" "$new" "$val")" ;;
        esac
        if [[ "$new" != "$val" ]]; then
            changed=1
            [[ "${keys[$i]}" == HARDEN_BROWSER_DOH ]] && doh_changed=1
        fi
        kvs+=("${keys[$i]}=$new")
    done
    if (( changed )); then
        if panel_write_config_keys "${kvs[@]}"; then
            load_config >/dev/null 2>&1
        else
            panel_config_write_error_box "$(ui_t panel.privacy_save_fail)"
            return
        fi
    fi
    local applied=0
    if panel_confirm_apply_privacy; then
        local applied_msg
        applied_msg="$(ui_t panel.privacy_applied)\n\n$(ui_t panel.privacy_reconnect_hint)"
        (( doh_changed )) && applied_msg+="\n\n$(ui_t panel.doh_restart_browser)"
        if panel_run_privileged -- "$BIN_DST" apply-privacy; then
            applied=1
            panel_info_box "$applied_msg"
        fi
    fi
    (( changed && ! applied )) && panel_info_box "$(ui_t panel.privacy_saved)"
    return 0
}

# Panel: monitorización y alertas. Formulario independiente (no forma parte
# de panel_action_configure) por lo mismo que el de anonimato: que guardar
# uno no pise las claves del otro. Espejo de menu_configure_monitoring.
panel_action_configure_monitoring() {
    [[ -f "$CONFIG_FILE" ]] || { local m; printf -v m -- "$(ui_t config.missing)" "$CONFIG_FILE"; panel_error_box "$m"; return; }
    local cur_histenable cur_prom cur_histmax
    cur_histenable="$(panel_get_val EVENT_HISTORY_ENABLE)"; cur_prom="$(panel_get_val PROMETHEUS_TEXTFILE_DIR)"; cur_histmax="$(panel_get_val EVENT_HISTORY_MAX_LINES)"
    # La carpeta de métricas se elige con el explorador de zenity (como al exportar la
    # configuración), no se escribe: un combo "mantener / elegir / quitar" y, solo si se
    # pide elegir, el selector de carpetas. "|" separa los valores de un combo.
    local prom_keep prom_choose prom_clear prom_values
    printf -v prom_keep -- "$(ui_t panel.prom_keep)" "${cur_prom:-$(ui_t ui.none_value)}"
    prom_keep="${prom_keep//|/¦}"
    prom_choose="$(ui_t panel.prom_choose)"
    prom_clear="$(ui_t panel.prom_clear)"
    prom_values="$prom_keep|$prom_choose"
    [[ -n "$cur_prom" ]] && prom_values+="|$prom_clear"
    local result
    result="$(zenity_ui --forms --title="$TITLE - $(ui_t panel.monitoring)" --width=560 \
        --text="$(ui_t panel.monitor_help)" \
        --add-combo="$(panel_field_label EVENT_HISTORY_ENABLE)" --combo-values="$(panel_order_combo "$cur_histenable" true false)" \
        --add-combo="$(panel_field_label PROMETHEUS_TEXTFILE_DIR)" --combo-values="$prom_values" \
        --add-entry="$(panel_field_label EVENT_HISTORY_MAX_LINES "${cur_histmax:-5000}")")" || return
    [[ -z "$result" ]] && return
    local new_histenable new_prom_choice new_histmax new_prom="$cur_prom"
    IFS='|' read -r new_histenable new_prom_choice new_histmax <<< "$result"
    new_histenable="$(panel_enum_or_keep EVENT_HISTORY_ENABLE "$new_histenable" "$cur_histenable")"
    case "$new_prom_choice" in
        "$prom_choose")
            local picked
            picked="$(zenity_ui --file-selection --directory --title="$TITLE - $(ui_t panel.prom_pick_title)" \
                --filename="${cur_prom:-$HOME}/" 2>/dev/null)"
            # Sin carpeta (diálogo cancelado) no se guarda nada: ni un cambio a medias.
            [[ -z "$picked" ]] && return
            [[ "$picked" == / ]] || picked="${picked%/}"
            new_prom="$picked" ;;
        "$prom_clear") new_prom="" ;;
    esac
    [[ -z "$new_histmax" ]] && new_histmax="${cur_histmax:-5000}"
    if ! [[ "$new_histmax" =~ ^[0-9]+$ ]]; then
        panel_error_box "$(ui_t panel.invalid_history)"
        return
    fi
    if panel_write_config_keys "EVENT_HISTORY_ENABLE=$new_histenable" "PROMETHEUS_TEXTFILE_DIR=$new_prom" "EVENT_HISTORY_MAX_LINES=$new_histmax"; then
        load_config >/dev/null 2>&1
        panel_info_box "$(ui_t panel.monitor_saved)\n\n$(ui_t panel.config_auto)"
    else
        panel_config_write_error_box "$(ui_t panel.monitor_save_fail)"
    fi
}

panel_action_privacy_status() {
    local out
    out="$(pkexec "$BIN_DST" privacy-status 2>&1)"
    panel_status_screen "$TITLE - $(ui_t panel.privacy)" 520 "$out"
}

panel_action_doctor() {
    local out
    out="$(pkexec "$BIN_DST" doctor 2>&1)"
    zenity_ui --text-info --title="$TITLE - $(ui_t panel.diagnostics)" --width=680 --height=480 --font="Monospace" <<< "$out"
}

panel_action_export_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local m; printf -v m -- "$(ui_t panel.config_missing)" "$CONFIG_FILE"; panel_error_box "$m"; return
    fi
    local dest title
    title="$(ui_t panel.export_title)"
    dest="$(zenity_ui --file-selection --save --confirm-overwrite --title="$TITLE - $title" \
        --filename="$HOME/vpn-netguard-$(date +%Y%m%d).conf" 2>/dev/null)"
    [[ -z "$dest" ]] && return
    if cp -p "$CONFIG_FILE" "$dest" 2>/dev/null; then
        local msg; printf -v msg -- "$(ui_t panel.exported)" "$dest"; panel_info_box "$msg"
    else
        local msg; printf -v msg -- "$(ui_t panel.export_failed)" "$dest"; panel_error_box "$msg"
    fi
}

panel_action_import_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local m; printf -v m -- "$(ui_t panel.config_missing)" "$CONFIG_FILE"; panel_error_box "$m"; return
    fi
    local src title confirm
    title="$(ui_t panel.import_title)"
    src="$(zenity_ui --file-selection --title="$TITLE - $title" 2>/dev/null)"
    [[ -z "$src" ]] && return
    printf -v confirm -- "$(ui_t panel.confirm_import)" "$src"
    panel_confirm_box "$confirm" || return
    if panel_run_privileged -- "$BIN_DST" import-config "$src"; then
        panel_info_box "$(ui_t panel.imported_auto)"
    fi
}

# Submenú "Servicio systemd": mismas acciones y confirmaciones que antes
# tenía el menú principal (ver panel_main_menu antiguo), solo que agrupadas
# en su propia ventana en vez de 5 filas sueltas en el listado grande.
# Submenú "Servicio": agrupa iniciar/detener/reiniciar/autoarranque (antes
# 5 filas sueltas en el listado grande), igual que menu_service_submenu.
panel_service_submenu() {
    while true; do
        local choice
        choice="$(zenity_ui --list --title="$TITLE - $(ui_t panel.service)" --width=480 --height=340 \
            --text="$(ui_t panel.service)" --hide-header --print-column=1 --hide-column=1 \
            --column="ID" --column="$(ui_t panel.service)" -- \
            1 "$(ui_t panel.svc_start)" \
            2 "$(ui_t panel.svc_stop)" \
            3 "$(ui_t panel.svc_restart)" \
            4 "$(ui_t panel.svc_enable)" \
            5 "$(ui_t panel.svc_disable)" \
            0 "$(ui_t panel.back)")"
        [[ $? -ne 0 || -z "$choice" ]] && return
        case "$choice" in
            1) panel_confirm_box "$(ui_t panel.confirm_start)" && panel_action_start_service ;;
            2) panel_action_stop_service ;;
            3) panel_confirm_box "$(ui_t panel.confirm_restart)" && panel_action_restart_service ;;
            4) panel_action_enable_autostart ;;
            5) panel_action_disable_autostart ;;
            0) return ;;
        esac
    done
}

# Submenú "Copia de seguridad": agrupa exportar/importar (antes dos filas
# sueltas en el listado grande) en su propia ventana, igual que hace ya el
# menú de texto con menu_backup_submenu.
panel_backup_submenu() {
    while true; do
        local choice
        choice="$(zenity_ui --list --title="$TITLE - $(ui_t panel.backup)" --width=480 --height=280 \
            --text="$(ui_t panel.backup)" --hide-header --print-column=1 --hide-column=1 \
            --column="ID" --column="$(ui_t panel.backup)" -- \
            1 "$(ui_t panel.export_title)" \
            2 "$(ui_t panel.import_title)" \
            0 "$(ui_t panel.back)")"
        [[ $? -ne 0 || -z "$choice" ]] && return
        case "$choice" in
            1) panel_action_export_config ;;
            2) panel_action_import_config ;;
            0) return ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# MODELO DE MENÚ ÚNICO (K3). De esta tabla salen las filas, los números y el
# despacho del menú de texto y del panel gráfico: una entrada significa lo
# mismo y lleva el mismo número en ambos. Formato, una línea por fila:
#   H|clave_de_categoría            cabecera (no seleccionable)
#   E|icono|id|ámbito               entrada; ámbito "all" = terminal y panel,
#                                   "text" = solo terminal
# Los números no se escriben a mano: se asignan en orden de aparición, así que
# coinciden mientras las entradas "text" vayan al final de la tabla. Para
# añadir o mover una entrada se toca esta tabla, menu_label y los despachadores
# menu_run_panel / menu_run_text.
# "interface" es una sola entrada con la acción contraria en cada interfaz: en el
# terminal abre el panel y lo fija como interfaz de arranque; en el panel fija la
# terminal, cierra el panel y sigue en el menú de texto (ui_pref_set, 9.6).
# -----------------------------------------------------------------------------
menu_model() {
    cat <<'MODEL'
H|menu.cat_main
E|✓|status|all
E|★|one_click|all
E|✓|protection|all
E|✓|killswitch|all
H|menu.cat_config
E|⚙|language|all
E|⚙|config|all
E|⚙|privacy|all
E|⚙|monitoring|all
H|menu.cat_advanced
E|▸|service|all
E|▸|backup|all
E|▸|logs|all
E|▸|doctor|all
E|▸|uninstall|all
E|▸|interface|all
E|▸|install|text
MODEL
}

# menu_rows <text|panel>: una línea "tipo|núm|icono|id" por fila visible. En las
# cabeceras (H) núm e icono van vacíos e id lleva la clave de la categoría.
menu_rows() {
    local iface="$1" kind a b c n=0
    while IFS='|' read -r kind a b c; do
        if [[ "$kind" == H ]]; then
            printf 'H|||%s\n' "$a"
            continue
        fi
        [[ "$iface" == panel && "$c" == text ]] && continue
        n=$((n + 1))
        printf 'E|%d|%s|%s\n' "$n" "$a" "$b"
    done < <(menu_model)
}

# Número de una entrada en el menú de texto (el de más entradas) y, al revés,
# id de la entrada que lleva un número en cada interfaz. Vacío si no existe.
menu_number_of() {
    local kind num icon id
    while IFS='|' read -r kind num icon id; do
        [[ "$kind" == E && "$id" == "$1" ]] && { printf '%s' "$num"; return 0; }
    done < <(menu_rows text)
    return 1
}

menu_id_of_number() {
    local kind num icon id
    while IFS='|' read -r kind num icon id; do
        [[ "$kind" == E && "$num" == "$2" ]] && { printf '%s' "$id"; return 0; }
    done < <(menu_rows "$1")
    return 1
}

# Etiqueta de una entrada en una interfaz (text|panel): larga en el terminal
# (menu.<id>) y corta en el panel, donde la descripción va en otra columna
# (menu_desc). Una entrada nueva necesita su rama aquí.
menu_label() {
    local id="$1" iface="$2" key
    case "$iface:$id" in
        *:status)         key=menu.status ;;
        *:one_click)      key=panel.one_click ;;
        *:uninstall)      key=menu.uninstall ;;
        text:protection)  key=menu.protection ;;
        text:killswitch)  key=menu.killswitch ;;
        text:language)    key=menu.language ;;
        text:config)      key=menu.config ;;
        text:privacy)     key=menu.privacy ;;
        text:monitoring)  key=menu.monitoring ;;
        text:service)     key=menu.service ;;
        text:backup)      key=menu.backup ;;
        text:logs)        key=menu.logs ;;
        text:doctor)      key=menu.doctor ;;
        text:install)     key=menu.install ;;
        text:interface)   key=menu.open_panel ;;
        panel:interface)  key=panel.back_to_terminal ;;
        panel:protection) key=protection.title ;;
        panel:killswitch) key=killswitch.title ;;
        panel:language)   ui_field_label LANGUAGE; return 0 ;;
        panel:config)     key=panel.config ;;
        panel:privacy)    key=privacy.title ;;
        panel:monitoring) key=panel.monitoring ;;
        panel:service)    key=panel.service ;;
        panel:backup)     key=panel.backup ;;
        panel:logs)       key=panel.logs ;;
        panel:doctor)     key=panel.diagnostics ;;
        *) return 1 ;;
    esac
    ui_t "$key"
}

# Descripción corta de una entrada del menú (columna "Descripción" del panel).
# Las entradas solo de terminal no la tienen.
menu_desc() {
    case "$1" in
        status|one_click|protection|killswitch|language|config|privacy|monitoring|service|backup|logs|doctor|uninstall|interface)
            ui_t "menu.desc_$1" ;;
        *) return 1 ;;
    esac
}

# Escapa &, < y > en datos dinámicos que van dentro de marcado Pango. Con
# patsub_replacement (bash 5.2+, activo por defecto) un "&" sin comillas en el
# reemplazo significa "el texto encontrado" y corrompería el resultado: se
# desactiva mientras dura la función y se restaura (en bash anteriores la
# opción no existe y shopt -q falla, sin efecto).
pango_escape() {
    local t="$1" restore=0
    if shopt -q patsub_replacement 2>/dev/null; then restore=1; shopt -u patsub_replacement; fi
    t="${t//&/&amp;}"; t="${t//</&lt;}"; t="${t//>/&gt;}"
    (( restore )) && shopt -s patsub_replacement
    printf '%s' "$t"
}

# Nombre del primer perfil VPN/WireGuard activo en NetworkManager (sin root;
# con tiempo máximo para que una NM colgada no bloquee la interfaz). Vacío y
# código 1 si no hay ninguno.
menu_active_vpn_name() {
    local raw name type
    while IFS= read -r raw; do
        [[ -z "$raw" ]] && continue
        raw="$(nmcli_protect_escapes "$raw")"
        IFS=: read -r name type _ <<< "$raw"
        name="$(nmcli_unescape "$name")"; type="$(nmcli_unescape "$type")"
        case "$type" in
            vpn|wireguard) printf '%s' "$name"; return 0 ;;
        esac
    done < <(timeout 3 env "${NMCLI_ENV[@]}" nmcli -t -e yes -f NAME,TYPE connection show --active 2>/dev/null)
    return 1
}

# Estado resumido que se puede leer sin root: una línea "nivel|etiqueta|valor"
# por dato (nivel: ok | warn | off). Lo comparten la cabecera del panel y la del
# menú de texto. Del cortafuegos solo se muestra lo que dicen el forzado y la
# configuración: leer iptables exige root.
menu_status_items() {
    local vpn wanted=0 ov line
    want_vpn_active && wanted=1
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        printf 'ok|%s|%s\n' "$(ui_t menu.st_service)" "$(ui_t menu.st_active)"
    else
        printf 'warn|%s|%s\n' "$(ui_t menu.st_service)" "$(ui_t menu.st_inactive)"
    fi
    if (( wanted )); then
        printf 'ok|%s|%s\n' "$(ui_t menu.st_protection)" "$(ui_t menu.st_enabled)"
    else
        printf 'off|%s|%s\n' "$(ui_t menu.st_protection)" "$(ui_t menu.st_disabled)"
    fi
    if vpn="$(menu_active_vpn_name)"; then
        printf 'ok|%s|%s\n' "$(ui_t menu.st_vpn)" "$vpn"
    elif (( wanted )); then
        printf 'warn|%s|%s\n' "$(ui_t menu.st_vpn)" "$(ui_t menu.st_vpn_waiting)"
    else
        printf 'off|%s|%s\n' "$(ui_t menu.st_vpn)" "$(ui_t menu.st_vpn_none)"
    fi
    ov="$(killswitch_override_value)"
    case "$ov" in
        on)  printf 'ok|%s|%s\n' "$(ui_t menu.st_killswitch)" "$(ui_t menu.st_ks_on)" ;;
        off) printf 'warn|%s|%s\n' "$(ui_t menu.st_killswitch)" "$(ui_t menu.st_ks_off)" ;;
        *)
            coexist_yield_load
            printf -v line -- "$(ui_t menu.st_ks_auto)" "$KILLSWITCH_MODE"
            if [[ "$KILLSWITCH_MODE" == auto ]] && (( wanted )) && coexist_yielding; then
                printf -v line -- "$(ui_t menu.st_ks_yield)" "${FOREIGN_KS[*]}"
                printf 'warn|%s|%s\n' "$(ui_t menu.st_killswitch)" "$line"
            elif [[ "$KILLSWITCH_MODE" == false ]]; then
                printf 'warn|%s|%s\n' "$(ui_t menu.st_killswitch)" "$line"
            else
                printf 'ok|%s|%s\n' "$(ui_t menu.st_killswitch)" "$line"
            fi
            ;;
    esac
}

# Cabecera Pango del panel: un punto de color por dato (zenity no colorea
# celdas, pero --text sí admite marcado), dos datos por línea.
panel_status_markup() {
    local level label value color out="" n=0
    while IFS='|' read -r level label value; do
        case "$level" in
            ok)   color="#3fa65b" ;;
            warn) color="#e0a030" ;;
            *)    color="#8a8a8a" ;;
        esac
        (( n > 0 )) && { if (( n % 2 )); then out+="     "; else out+=$'\n'; fi; }
        out+="<span foreground=\"$color\">●</span> <b>$(pango_escape "$label")</b>: $(pango_escape "$value")"
        n=$((n + 1))
    done < <(menu_status_items)
    printf '%s' "$out"
}

# Entrada «interface» del panel: fija la terminal como interfaz de arranque y cierra el panel;
# quien lo lanzó sigue entonces en el menú de texto (panel_continue_in_terminal): en su terminal
# o, si el panel salió del acceso directo del escritorio, en una ventana nueva. Sin terminal ni
# emulador donde abrirla, o si no se puede guardar, no cambia nada y el panel sigue abierto.
panel_back_to_terminal() {
    if ! have_terminal && ! terminal_emulator_find >/dev/null; then
        panel_error_box "$(ui_t panel.interface_no_terminal)"
        return 0
    fi
    if ! ui_pref_set terminal; then
        panel_error_box "$(ui_t panel.interface_save_failed)"
        return 0
    fi
    PANEL_BACK_TO_TERMINAL=1
}

menu_run_panel() {
    case "$1" in
        status) panel_action_status ;;
        one_click) panel_action_one_click ;;
        protection) panel_protection_submenu ;;
        killswitch) panel_killswitch_submenu ;;
        language) panel_action_change_language ;;
        config) panel_action_configure ;;
        privacy) panel_action_configure_privacy ;;
        monitoring) panel_action_configure_monitoring ;;
        service) panel_service_submenu ;;
        backup) panel_backup_submenu ;;
        logs) panel_action_logs ;;
        doctor) panel_action_doctor ;;
        uninstall)
            panel_confirm_box "$(ui_t panel.remove_confirm)" && panel_run_privileged -- "$BIN_DST" uninstall && panel_info_box "$(ui_t panel.uninstalled)"
            ;;
        interface) panel_back_to_terminal ;;
    esac
}

# Menú principal del panel: filas de menu_rows panel en cuatro columnas (ID
# oculto, Nº, Acción, Descripción) bajo una cabecera Pango con el estado. Las
# cabeceras de categoría usan el ID compartido "H" (sin acción: se vuelve a
# mostrar la lista). Salir es el botón Cancelar; también termina una acción que
# deja PANEL_BACK_TO_TERMINAL=1. La altura sale del número de filas para que no
# haga falta desplazarse; validar en un escritorio real.
panel_main_menu() {
    PANEL_BACK_TO_TERMINAL=0
    while true; do
        local -a rows=()
        local kind num icon id height
        while IFS='|' read -r kind num icon id; do
            if [[ "$kind" == H ]]; then
                rows+=(H "" "$(ui_t "$id")" "")
            else
                rows+=("$num" "$num" "$icon $(menu_label "$id" panel)" "$(menu_desc "$id")")
            fi
        done < <(menu_rows panel)
        height=$(( 150 + 27 * ${#rows[@]} / 4 ))
        (( height > 700 )) && height=700
        local choice
        choice="$(zenity_ui --list --title="$TITLE" --width=860 --height="$height" \
            --text="$(panel_status_markup)"$'\n\n'"$(ui_t menu.select_action)" \
            --ok-label="$(ui_t panel.btn_open)" --cancel-label="$(ui_t menu.exit0)" \
            --print-column=1 --hide-column=1 \
            --column="ID" --column="$(ui_t panel.col_num)" --column="$(ui_t panel.col_action)" \
            --column="$(ui_t panel.col_desc)" -- "${rows[@]}")"
        local rc=$?
        [[ $rc -ne 0 || -z "$choice" ]] && break
        [[ "$choice" == H ]] && continue
        menu_run_panel "$(menu_id_of_number panel "$choice")"
        (( PANEL_BACK_TO_TERMINAL )) && break
    done
}

cmd_panel() {
    panel_require_zenity
    panel_require_installed
    panel_main_menu
}

# =============================================================================
# INSTALADOR (antes install.sh) — se copia a sí mismo a $BIN_DST y genera
# el resto de piezas (config por defecto, unidad systemd, entrada de
# escritorio) a partir de las plantillas embebidas más arriba.
# =============================================================================
install_fail() {
    zenity_ui --error --title="$(ui_t install.title)" --width=420 --text="$1" 2>/dev/null || printf '%s\n' "$1" >&2
    exit 1
}

check_networkmanager_active() {
    systemctl is-active --quiet NetworkManager 2>/dev/null
}

# Aviso (no bloqueante) si NetworkManager no está activo: todo el programa
# depende de nmcli, y en un servidor es habitual que la red la gestione
# netplan con renderer "networkd" en vez de NetworkManager.
warn_if_networkmanager_inactive() {
    check_networkmanager_active && return 0
    echo "$(ui_t nm_inactive_1)" >&2
    echo "$(ui_t nm_inactive_2)" >&2
    echo "$(ui_t nm_inactive_3)" >&2
    echo "$(ui_t nm_inactive_4)" >&2
    echo "  $(ui_t nm_inactive_cmd)" >&2
    return 1
}

# Aviso (no bloqueante) si ufw está activo: poco habitual en un Mint de
# escritorio, pero frecuente en un servidor Ubuntu. El kill switch añade su
# propia cadena ("NETGUARD_KS") enganchada a OUTPUT, independiente de las
# cadenas de ufw; ambos pueden convivir, pero conviene que el administrador
# lo sepa de antemano en vez de descubrirlo al depurar una conexión bloqueada.
warn_if_ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status 2>/dev/null | grep -q "^Status: active" || return 0
    echo "$(ui_t ufw_warning_1)" >&2
    echo "$(ui_t ufw_warning_2)" >&2
    echo "$(ui_t ufw_warning_3)" >&2
    echo "$(ui_t ufw_warning_4)" >&2
    return 1
}

# Diagnóstico combinado (dependencias + NetworkManager + ufw + cmd_check) en
# una sola salida, pensado para primer uso o soporte. check_dependencies y
# cmd_check corren en subshell "( ... )" para que su "exit" propio no corte
# el resto del diagnóstico; el código de salida final es el peor de todos
# (0 OK, 1 aviso, 2 crítico). El estado del killswitch y el de ufw necesitan
# root para ser fiables (iptables/ufw), así que ambos se omiten sin
# privilegios en vez de arriesgar un diagnóstico incorrecto.
cmd_doctor() {
    printf '%s%s%s\n' "$C_B" "$(ui_t doctor.header)" "$C_0"
    local worst=0 rc skip_msg
    ui_section "$(ui_t doctor.deps)"
    if ( check_dependencies ); then ui_good "$(ui_t doctor.deps_ok)"; else worst=2; fi
    ui_section "$(ui_t doctor.nm)"
    if warn_if_networkmanager_inactive; then ui_good "$(ui_t doctor.nm_ok)"; else (( worst < 1 )) && worst=1; fi
    ui_section "$(ui_t doctor.fw)"
    if ! have_root; then
        printf -v skip_msg -- "$(ui_t doctor.root_skip)" "$0"; ui_warn "$skip_msg"; (( worst < 1 )) && worst=1
    elif warn_if_ufw_active; then ui_good "$(ui_t doctor.fw_ok)"; else (( worst < 1 )) && worst=1; fi
    ui_section "$(ui_t doctor.ks)"
    if ! have_root; then
        printf -v skip_msg -- "$(ui_t doctor.root_skip)" "$0"; ui_warn "$skip_msg"; (( worst < 1 )) && worst=1
    elif [[ ! -f "$CONFIG_FILE" ]]; then
        printf -v skip_msg -- "$(ui_t doctor.not_installed)" "$0"; ui_warn "$skip_msg"; (( worst < 1 )) && worst=1
    else
        load_config; rc=0; ( cmd_check ) || rc=$?; (( rc > worst )) && worst=$rc
        if [[ -z "$VPN_ENDPOINT_OVERRIDE" ]] && boot_killswitch_would_block; then
            ui_warn "$(ks_boot_race_warning_text)"; (( worst < 1 )) && worst=1
        fi
    fi
    ui_section "$(ui_t doctor.coexist)"
    if ! have_root; then
        printf -v skip_msg -- "$(ui_t doctor.root_skip)" "$0"; ui_warn "$skip_msg"; (( worst < 1 )) && worst=1
    else
        detect_known_profiles; detect_active_state
        print_coexist_status || { (( worst < 1 )) && worst=1; }
    fi
    echo
    case $worst in
        0) ui_good "$(ui_t doctor.summary_ok)" ;;
        1) ui_warn "$(ui_t doctor.summary_warn)" ;;
        *) ui_bad "$(ui_t doctor.summary_crit)" ;;
    esac
    exit "$worst"
}

# cmd_export_config [ruta_destino]
# Copia $CONFIG_FILE tal cual (comentarios incluidos) a la ruta indicada, o
# a ./vpn-netguard-AAAAMMDD.conf si se omite. Útil para reinstalar o
# replicar el ajuste en varios equipos (ver cmd_import_config). No necesita
# privilegios: el fichero se instala con lectura para cualquier usuario.
cmd_export_config() {
    local dest="${1:-}"
    [[ -f "$CONFIG_FILE" ]] || { printf -- "$(ui_t export.no_config)\n" "$CONFIG_FILE" >&2; return 1; }
    [[ -z "$dest" ]] && dest="./vpn-netguard-$(date +%Y%m%d).conf"
    if cp -p "$CONFIG_FILE" "$dest" 2>/dev/null; then
        printf -- "$(ui_t export.ok)\n" "$dest"
        return 0
    fi
    printf -- "$(ui_t export.fail)\n" "$dest" >&2
    return 1
}

# Copia de $CONFIG_FILE junto a él (${CONFIG_FILE}.bak-XXXXXXXX, root, 0644).
# Escribe la ruta en stdout. Si falla no deja ningún fichero y devuelve 1 sin
# mensaje: cada llamador explica qué cancela.
config_backup_make() {
    local backup
    backup="$(mktemp "${CONFIG_FILE}.bak-XXXXXXXX" 2>/dev/null)" || return 1
    if ! install -o root -g root -m 644 "$CONFIG_FILE" "$backup" 2>/dev/null; then
        rm -f "$backup"
        return 1
    fi
    printf '%s' "$backup"
}

# cmd_import_config <ruta_origen>
# Sustituye $CONFIG_FILE por una copia exportada antes (ver
# cmd_export_config), tras una comprobación mínima de sintaxis. Guarda
# primero una copia de la configuración anterior (config_backup_make) y
# cancela si falla, para no quedarse sin forma de deshacerlo.
# Necesita privilegios de root (lo exige el punto de entrada).
cmd_import_config() {
    local src="${1:-}" backup
    [[ -n "$src" && -f "$src" ]] || { printf '%s\n' "$(ui_t config.not_importable)" >&2; return 1; }
    [[ -f "$CONFIG_FILE" ]] || { printf -- "$(ui_t config.install_first)\n" "$CONFIG_FILE" >&2; return 1; }
    bash -n "$src" 2>/dev/null || { printf '%s\n' "$(ui_t config.invalid_syntax)" >&2; return 1; }
    config_file_is_safe "$src" || { printf '%s\n' "$(ui_t config.invalid_content)" >&2; return 1; }

    backup="$(config_backup_make)" || { printf '%s\n' "$(ui_t config.backup_fail)" >&2; return 1; }
    local tmp_import
    tmp_import="$(mktemp "${CONFIG_FILE}.import-XXXXXXXX" 2>/dev/null)" || {
        printf -- "$(ui_t config.import_fail)\n" "$backup" >&2
        return 1
    }
    if install -o root -g root -m 644 "$src" "$tmp_import" && mv -f "$tmp_import" "$CONFIG_FILE"; then
        printf -- "$(ui_t config.imported)\n" "$src"
        printf -- "$(ui_t export.backup)\n" "$backup"
        return 0
    fi
    rm -f "$tmp_import"
    printf -- "$(ui_t config.import_fail)\n" "$backup" >&2
    return 1
}

# Punto de entrada único de instalación: comprobaciones comunes a ambos
# caminos (root, fichero propio legible) y despacho al asistente gráfico
# (zenity, si hay sesión gráfica) o al de texto (pensado para un servidor
# por SSH sin escritorio, sin instalar ningún paquete gráfico).
cmd_install() {
    [[ $EUID -eq 0 ]] || {
        printf '%s\n' "$(ui_t config.install_root)" >&2
        exit 1
    }
    if [[ ! -r "$SELF" ]]; then
        printf '%s\n' "$(ui_t config.self_missing)" >&2
        printf '%s\n' "$(ui_t config.self_hint)" >&2
        exit 1
    fi

    # Instalación desatendida (Ansible/cloud-init/Dockerfile: sin terminal
    # interactiva que responda los menu_confirm de cmd_install_text). Cada
    # pregunta se puede fijar aparte por bandera o variable de entorno;
    # "--yes" solo rellena las que no se hayan fijado ya (autoarranque e
    # inicio en "sí"; anonimato de red en "no", por el riesgo ya explicado
    # más abajo si el proveedor filtra por MAC). Sin nada de esto, igual que
    # siempre: todo interactivo. Sin efecto en el asistente gráfico (zenity).
    INSTALL_YES="${VPN_NETGUARD_INSTALL_YES:-false}"
    INSTALL_OPT_AUTOSTART="${VPN_NETGUARD_INSTALL_AUTOSTART:-}"
    INSTALL_OPT_START_NOW="${VPN_NETGUARD_INSTALL_START_NOW:-}"
    INSTALL_OPT_PRIVACY="${VPN_NETGUARD_INSTALL_PRIVACY:-}"
    INSTALL_OPT_MENU_ENTRY="${VPN_NETGUARD_INSTALL_MENU_ENTRY:-}"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)       INSTALL_YES="true" ;;
            --autostart)    INSTALL_OPT_AUTOSTART="true" ;;
            --no-autostart) INSTALL_OPT_AUTOSTART="false" ;;
            --start-now)    INSTALL_OPT_START_NOW="true" ;;
            --no-start-now) INSTALL_OPT_START_NOW="false" ;;
            --privacy)      INSTALL_OPT_PRIVACY="true" ;;
            --no-privacy)   INSTALL_OPT_PRIVACY="false" ;;
            --menu-entry)   INSTALL_OPT_MENU_ENTRY="true" ;;
            --no-menu-entry) INSTALL_OPT_MENU_ENTRY="false" ;;
            *) printf '%s\n' "$(ui_t invalid_option)" >&2; exit 1 ;;
        esac
    done
    if [[ "$INSTALL_YES" == "true" ]]; then
        : "${INSTALL_OPT_AUTOSTART:=true}"
        : "${INSTALL_OPT_START_NOW:=true}"
        : "${INSTALL_OPT_PRIVACY:=false}"
        : "${INSTALL_OPT_MENU_ENTRY:=true}"
    fi

    # Aquí también (no solo al usar cada subcomando): así avisa de una
    # dependencia que falte (nmcli, iptables...) en vez de "completarse" y
    # que el servicio falle luego en silencio.
    check_dependencies

    if have_gui_session; then
        command -v zenity >/dev/null 2>&1 || {
            echo "$(ui_t install.zenity_installing)"
            apt-get update -qq && apt-get install -y zenity
        }
    fi

    if have_gui_session && command -v zenity >/dev/null 2>&1; then
        cmd_install_gui
    else
        cmd_install_text
    fi
}

cmd_install_gui() {
    local INSTALL_TITLE
    INSTALL_TITLE="$(ui_t install.title)"
    command -v zenity >/dev/null 2>&1 || install_fail "$(ui_t install.zenity_fail)"
    zenity_ui --info --title="$INSTALL_TITLE" --width=520 --text="$(ui_t install.summary)\n\n• $BIN_DST\n• $CONFIG_FILE\n• vpn-netguard.service\n• vpn-netguard-boot.service\n• $(ui_t install.app_entry)\n• $(ui_t install.privacy_default)\n\n$(ui_t install.accept)" || exit 0
    if ! check_networkmanager_active; then
        zenity_ui --question --title="$INSTALL_TITLE" --width=460 --text="$(ui_t install.nm_warn)" || exit 0
    fi
    if ! warn_if_ufw_active; then
        zenity_ui --info --title="$INSTALL_TITLE" --width=460 --text="$(ui_t install.ufw_warn)"
    fi
    zenity_ui --question --title="$INSTALL_TITLE" --width=420 --text="$(ui_t install.autostart_q)"; local AUTOSTART=$?
    zenity_ui --question --title="$INSTALL_TITLE" --width=420 --text="$(ui_t install.start_now_q)"; local START_NOW=$?
    zenity_ui --question --title="$INSTALL_TITLE" --width=420 --text="$(ui_t install.menu_entry_q)"; local MENU_ENTRY=$?
    local DESKTOP_ICON=1
    if [[ $MENU_ENTRY -eq 0 ]]; then
        zenity_ui --question --title="$INSTALL_TITLE" --width=420 --text="$(ui_t install.desktop_q)"; DESKTOP_ICON=$?
    fi
    if is_ssh_session; then
        zenity_ui --question --title="$INSTALL_TITLE" --width=480 --text="$(ui_t install.ssh_privacy_warn)"
    else
        zenity_ui --question --title="$INSTALL_TITLE" --width=420 --text="$(ui_t install.privacy_q)"
    fi
    local DO_PRIVACY=$?
    local menu_fail_marker; menu_fail_marker="$(mktemp)"
    (
    echo "10"; echo "# $(ui_t install.progress_copy)"
    if [[ "$(readlink -f "$SELF")" != "$(readlink -f "$BIN_DST" 2>/dev/null || echo "$BIN_DST")" ]]; then
        install -D -o root -g root -m 755 "$SELF" "$BIN_DST" || exit 1
    fi
    echo "35"; echo "# $(ui_t install.progress_config)"
    mkdir -p "$CONF_DIR" "$STATE_DIR" || exit 1
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local tmp_conf; tmp_conf="$(mktemp)"; write_default_config > "$tmp_conf"; install -D -o root -g root -m 644 "$tmp_conf" "$CONFIG_FILE" || exit 1; rm -f "$tmp_conf"
    fi
    load_config
    if [[ $DO_PRIVACY -eq 0 ]]; then
        echo "45"; echo "# $(ui_t install.progress_privacy)"; apply_network_privacy || exit 1
    else
        echo "45"; echo "# $(ui_t install.progress_privacy_skip)"
    fi
    echo "55"; echo "# $(ui_t install.progress_systemd)"
    local tmp_unit tmp_boot_unit; tmp_unit="$(mktemp)"; write_service_unit > "$tmp_unit"; install -D -o root -g root -m 644 "$tmp_unit" "$UNIT_DST" || exit 1; rm -f "$tmp_unit"
    tmp_boot_unit="$(mktemp)"; write_boot_service_unit > "$tmp_boot_unit"; install -D -o root -g root -m 644 "$tmp_boot_unit" "$BOOT_UNIT_DST" || exit 1; rm -f "$tmp_boot_unit"
    systemctl daemon-reload || exit 1
    if [[ $MENU_ENTRY -eq 0 ]]; then
        echo "70"; echo "# $(ui_t install.progress_desktop)"
        local tmp_icon; tmp_icon="$(mktemp)"
        write_icon_file > "$tmp_icon" && install -D -o root -g root -m 644 "$tmp_icon" "$ICON_DST" || echo fail > "$menu_fail_marker"
        rm -f "$tmp_icon"
        local tmp_desktop; tmp_desktop="$(mktemp)"
        write_desktop_file > "$tmp_desktop" && install -D -o root -g root -m 644 "$tmp_desktop" "$DESKTOP_DST" || echo fail > "$menu_fail_marker"
        rm -f "$tmp_desktop"
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications >/dev/null 2>&1
    else
        echo "70"; echo "# $(ui_t install.progress_desktop_skip)"
    fi
    echo "85"; echo "# $(ui_t install.progress_boot)"
    if [[ $AUTOSTART -eq 0 ]]; then
        systemctl enable "$SERVICE" "$BOOT_SERVICE" >/dev/null 2>&1 || exit 1
    else
        systemctl disable "$SERVICE" "$BOOT_SERVICE" >/dev/null 2>&1 || true
    fi
    if [[ $START_NOW -eq 0 ]]; then
        systemctl start "$BOOT_SERVICE" >/dev/null 2>&1 || exit 1
        systemctl restart "$SERVICE" >/dev/null 2>&1 || exit 1
    else
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    fi
    echo "95"; echo "# $(ui_t install.progress_desktop_icon)"
    if [[ $DESKTOP_ICON -eq 0 ]]; then
        local real_user home_dir desktop_dir
        real_user="${PKEXEC_UID:-${SUDO_UID:-}}"
        if [[ -n "$real_user" ]]; then real_user="$(getent passwd "$real_user" | cut -d: -f1)"; else real_user="$(logname 2>/dev/null || true)"; fi
        if [[ -n "$real_user" ]]; then
            home_dir="$(getent passwd "$real_user" | cut -d: -f6)"; desktop_dir=""
            if command -v su >/dev/null 2>&1; then desktop_dir="$(su - "$real_user" -c 'command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP' 2>/dev/null)"; fi
            [[ -z "$desktop_dir" && -d "$home_dir/Escritorio" ]] && desktop_dir="$home_dir/Escritorio"; [[ -z "$desktop_dir" && -d "$home_dir/Desktop" ]] && desktop_dir="$home_dir/Desktop"
            if [[ -n "$desktop_dir" && -d "$desktop_dir" ]]; then
                local real_group; real_group="$(id -gn "$real_user" 2>/dev/null || echo "$real_user")"; cp "$DESKTOP_DST" "$desktop_dir/vpn-netguard.desktop"; chmod 755 "$desktop_dir/vpn-netguard.desktop"; chown "$real_user":"$real_group" "$desktop_dir/vpn-netguard.desktop"
                mark_desktop_trusted "$real_user" "$desktop_dir/vpn-netguard.desktop" || true
            fi
        fi
    fi
    echo "100"; echo "# $(ui_t install.ready)"
    ) | zenity_ui --progress --title="$INSTALL_TITLE" --width=420 --auto-close --no-cancel --text="$(ui_t install.progress_installing)"
    if [[ $? -ne 0 ]]; then install_fail "$(ui_t install.fatal_interrupt)"; fi
    local find_it_msg
    if [[ $MENU_ENTRY -eq 0 ]]; then find_it_msg="$(ui_t install.find_it_menu)"; else printf -v find_it_msg -- "$(ui_t install.find_it_nomenu)" "$BIN_DST"; fi
    local privacy_msg; [[ $DO_PRIVACY -eq 0 ]] && privacy_msg="$(ui_t install.privacy_active)" || privacy_msg="$(ui_t install.privacy_pending)"
    local complete_msg; printf -v complete_msg -- "$(ui_t install.complete_message)" "$find_it_msg" "$privacy_msg"
    if [[ -s "$menu_fail_marker" ]]; then
        zenity_ui --warning --title="$INSTALL_TITLE" --width=460 --text="$(ui_t install.menu_entry_failed)"
    fi
    rm -f "$menu_fail_marker"
    zenity_ui --info --title="$INSTALL_TITLE" --width=460 --text="$complete_msg"
    return 0
}

# Progreso "[paso/total]" para el instalador de texto, paralelo a la barra
# de zenity del instalador gráfico (ver cmd_install_gui).
text_step() {
    printf '[%d/%d] %s\n' "$1" "$2" "$3"
}

# Asistente de instalación en texto plano: mismos pasos que cmd_install_gui
# (copiar el binario, escribir configuración, aplicar anonimato de red,
# instalar las dos unidades systemd, entrada de menú de Aplicaciones —
# opcional, por si más adelante se añade un escritorio) pero sin zenity,
# pensado para un servidor por SSH. Se omite la pregunta del icono en el
# Escritorio del usuario (no aplica sin sesión gráfica) y se advierte
# explícitamente del riesgo de aplicar el módulo de anonimato de red (MAC
# aleatoria) sobre la interfaz con la que se administra el servidor
# remotamente. Un fallo al crear el icono/la entrada de menú no aborta el
# resto de la instalación: no hace falta para que la protección funcione.
cmd_install_text() {
    echo "$(ui_t install.text_header)"; echo; echo "$(ui_t install.will_install)"
    echo "  - $BIN_DST"; echo "  - $CONFIG_FILE"; echo "  - vpn-netguard.service"; echo "  - vpn-netguard-boot.service"; echo "  - $(ui_t install.app_entry)"; echo
    if ! warn_if_networkmanager_inactive; then [[ "$INSTALL_YES" == "true" ]] || menu_confirm "$(ui_t install.nm_continue_q)" || { echo "$(ui_t install.cancelled)"; exit 1; }; fi
    warn_if_ufw_active
    local AUTOSTART=1 START_NOW=1 DO_PRIVACY=1 MENU_ENTRY=1
    if [[ -n "$INSTALL_OPT_AUTOSTART" ]]; then [[ "$INSTALL_OPT_AUTOSTART" == "true" ]] && AUTOSTART=0; if (( AUTOSTART==0 )); then printf -- "$(ui_t install.fixed_yes)\n" "$(ui_t install.autostart_label)"; else printf -- "$(ui_t install.fixed_no)\n" "$(ui_t install.autostart_label)"; fi; else menu_confirm "$(ui_t install.autostart_q)" && AUTOSTART=0; fi
    if [[ -n "$INSTALL_OPT_START_NOW" ]]; then [[ "$INSTALL_OPT_START_NOW" == "true" ]] && START_NOW=0; if (( START_NOW==0 )); then printf -- "$(ui_t install.fixed_yes)\n" "$(ui_t install.start_label)"; else printf -- "$(ui_t install.fixed_no)\n" "$(ui_t install.start_label)"; fi; else menu_confirm "$(ui_t install.start_now_q)" && START_NOW=0; fi
    if [[ -n "$INSTALL_OPT_MENU_ENTRY" ]]; then [[ "$INSTALL_OPT_MENU_ENTRY" == "true" ]] && MENU_ENTRY=0; if (( MENU_ENTRY==0 )); then printf -- "$(ui_t install.fixed_yes)\n" "$(ui_t install.menu_entry_label)"; else printf -- "$(ui_t install.fixed_no)\n" "$(ui_t install.menu_entry_label)"; fi; else menu_confirm "$(ui_t install.menu_entry_q)" && MENU_ENTRY=0; fi
    echo; echo "$(ui_t install.remote_warning)"
    if [[ -n "$INSTALL_OPT_PRIVACY" ]]; then [[ "$INSTALL_OPT_PRIVACY" == "true" ]] && DO_PRIVACY=0; if (( DO_PRIVACY==0 )); then printf -- "$(ui_t install.fixed_yes)\n" "$(ui_t install.privacy_label)"; else printf -- "$(ui_t install.fixed_no)\n" "$(ui_t install.privacy_label)"; fi; else menu_confirm "$(ui_t install.privacy_q)" && DO_PRIVACY=0; fi
    echo; text_step 1 6 "$(ui_t install.progress_copy)"
    if [[ "$(readlink -f "$SELF")" != "$(readlink -f "$BIN_DST" 2>/dev/null || echo "$BIN_DST")" ]]; then install -D -o root -g root -m 755 "$SELF" "$BIN_DST" || exit 1; fi
    text_step 2 6 "$(ui_t install.progress_config)"
    mkdir -p "$CONF_DIR" "$STATE_DIR" || { printf -- "$(ui_t install.fail_mkdir)\n" "$CONF_DIR" "$STATE_DIR" >&2; exit 1; }
    if [[ ! -f "$CONFIG_FILE" ]]; then local tmp_conf; tmp_conf="$(mktemp)" || { printf -- "$(ui_t install.fail_tmp)\n" "$CONFIG_FILE" >&2; exit 1; }; write_default_config > "$tmp_conf"; install -D -o root -g root -m 644 "$tmp_conf" "$CONFIG_FILE" || exit 1; rm -f "$tmp_conf"; fi
    load_config
    if (( DO_PRIVACY==0 )); then text_step 3 6 "$(ui_t install.progress_privacy)"; apply_network_privacy || exit 1; else text_step 3 6 "$(ui_t install.progress_privacy_skip)"; fi
    text_step 4 6 "$(ui_t install.progress_systemd)"
    local tmp_unit tmp_boot_unit; tmp_unit="$(mktemp)" || { printf -- "$(ui_t install.fail_tmp)\n" "$UNIT_DST" >&2; exit 1; }; write_service_unit > "$tmp_unit"; install -D -o root -g root -m 644 "$tmp_unit" "$UNIT_DST" || exit 1; rm -f "$tmp_unit"
    tmp_boot_unit="$(mktemp)" || { printf -- "$(ui_t install.fail_tmp)\n" "$BOOT_UNIT_DST" >&2; exit 1; }; write_boot_service_unit > "$tmp_boot_unit"; install -D -o root -g root -m 644 "$tmp_boot_unit" "$BOOT_UNIT_DST" || exit 1; rm -f "$tmp_boot_unit"; systemctl daemon-reload || exit 1
    if (( MENU_ENTRY==0 )); then
        text_step 5 6 "$(ui_t install.progress_desktop)"
        local tmp_icon; tmp_icon="$(mktemp)" || { printf -- "$(ui_t install.fail_tmp)\n" "$ICON_DST" >&2; exit 1; }
        write_icon_file > "$tmp_icon" && install -D -o root -g root -m 644 "$tmp_icon" "$ICON_DST" || printf '%s\n' "$(ui_t install.menu_entry_failed)" >&2
        rm -f "$tmp_icon"
        local tmp_desktop; tmp_desktop="$(mktemp)" || { printf -- "$(ui_t install.fail_tmp)\n" "$DESKTOP_DST" >&2; exit 1; }
        if write_desktop_file > "$tmp_desktop" && install -D -o root -g root -m 644 "$tmp_desktop" "$DESKTOP_DST"; then
            command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications >/dev/null 2>&1
        else
            printf '%s\n' "$(ui_t install.menu_entry_failed)" >&2
        fi
        rm -f "$tmp_desktop"
    else
        text_step 5 6 "$(ui_t install.progress_desktop_skip)"
    fi
    text_step 6 6 "$(ui_t install.progress_boot)"
    if (( AUTOSTART==0 )); then
        systemctl enable "$SERVICE" "$BOOT_SERVICE" >/dev/null 2>&1 || exit 1
    else
        systemctl disable "$SERVICE" "$BOOT_SERVICE" >/dev/null 2>&1 || true
    fi
    if (( START_NOW==0 )); then
        systemctl start "$BOOT_SERVICE" >/dev/null 2>&1 || exit 1
        systemctl restart "$SERVICE" >/dev/null 2>&1 || exit 1
    else
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    fi
    echo; echo "$(ui_t install.completed)"; printf -- "$(ui_t install.finish_hint)\n" "$BIN_DST"; (( DO_PRIVACY!=0 )) && echo "$(ui_t install.finish_privacy_no)"
    return 0
}

cmd_uninstall() {
    require_root

    if command -v zenity >/dev/null 2>&1 && have_gui_session; then
        zenity_ui --question --title="$TITLE" --width=420 \
            --text="$(ui_t uninstall.confirm)" \
            2>/dev/null || { echo "$(ui_t cancelled)" >&2; exit 1; }
    elif [[ -t 0 ]]; then
        menu_confirm "$(ui_t uninstall.confirm)" || { echo "$(ui_t cancelled)" >&2; exit 1; }
    fi

    systemctl stop "$SERVICE" "$BOOT_SERVICE" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null || systemctl is-active --quiet "$BOOT_SERVICE" 2>/dev/null; then
        echo "$(ui_t uninstall.teardown_failed)" >&2
        exit 1
    fi
    if ! systemctl disable "$SERVICE" "$BOOT_SERVICE" >/dev/null 2>&1; then
        local unit enabled_state
        for unit in "$SERVICE" "$BOOT_SERVICE"; do
            enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
            case "$enabled_state" in
                enabled|enabled-runtime|linked|linked-runtime|alias)
                    echo "$(ui_t uninstall.teardown_failed)" >&2
                    exit 1
                    ;;
            esac
        done
    fi

    HAVE_IP6TABLES=0
    command -v ip6tables >/dev/null 2>&1 && HAVE_IP6TABLES=1
    detect_known_profiles 2>/dev/null
    if ! remove_killswitch_if_present 2>/dev/null; then
        echo "$(ui_t uninstall.teardown_failed)" >&2
        exit 1
    fi
    if ! remove_network_privacy 2>/dev/null; then
        echo "$(ui_t uninstall.teardown_failed)" >&2
        exit 1
    fi
    if ! remove_mac_rotate_timer 2>/dev/null; then
        echo "$(ui_t uninstall.teardown_failed)" >&2
        exit 1
    fi

    rm -f "$UNIT_DST" "$BOOT_UNIT_DST" || exit 1
    systemctl daemon-reload >/dev/null 2>&1 || exit 1

    rm -f "$DESKTOP_DST" || exit 1
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications >/dev/null 2>&1

    rm -f "$ICON_DST" || exit 1
    rmdir "$(dirname "$ICON_DST")" 2>/dev/null || true

    local d
    for d in "$ROOT_HOME_DIR/Desktop" "$ROOT_HOME_DIR/Escritorio" "$USERS_HOME_DIR"/*/Desktop "$USERS_HOME_DIR"/*/Escritorio; do
        [[ -f "$d/vpn-netguard.desktop" ]] && rm -f "$d/vpn-netguard.desktop"
    done

    rm -f "$BIN_DST" || exit 1

    local line
    # STATE_DIR solo guarda datos operativos (heartbeat, historial de
    # eventos, token de rotación de MAC, estado de notificaciones...), sin
    # valor si vas a reinstalar más adelante; por eso se borra sin preguntar,
    # a diferencia de CONFIG_FILE (tus preferencias) unas líneas más abajo.
    if ! rm -rf "$STATE_DIR"; then
        printf -v line -- "$(ui_t uninstall.remove_dir_failed)" "$STATE_DIR"
        ui_warn "$line"
    fi

    local keep_config=1
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v zenity >/dev/null 2>&1 && have_gui_session; then
            zenity_ui --question --title="$TITLE" --width=420 \
                --text="$(ui_t uninstall.keep_config_q)" 2>/dev/null && keep_config=0
        elif [[ -t 0 ]]; then
            menu_confirm "$(ui_t uninstall.keep_config_q)" && keep_config=0
        fi
        if (( keep_config == 0 )); then
            printf -v line -- "$(ui_t uninstall.kept_config)" "$CONFIG_FILE"
            echo "$line"
        elif ! rm -rf "$CONF_DIR"; then
            printf -v line -- "$(ui_t uninstall.remove_dir_failed)" "$CONF_DIR"
            ui_warn "$line"
        fi
    fi

    echo "$(ui_t uninstall.done)"
}


# =============================================================================
# MENÚ INTERACTIVO EN TERMINAL
# -----------------------------------------------------------------------------
# Lo abre el subcomando "menu" y, sin argumentos, cmd_start_ui cuando toca la terminal
# (la interfaz de arranque por defecto): no depende de zenity ni de una sesión gráfica
# ni de tener el programa ya instalado. Reutiliza las mismas
# funciones que el panel gráfico (panel_get_val / panel_write_config_keys /
# cmd_install / cmd_uninstall / cmd_panel): un único sitio donde se lee y se
# escribe $CONFIG_FILE, tanto desde el panel como desde este menú de texto.
# =============================================================================

menu_clear() {
    [[ -t 1 ]] && clear
    return 0
}

# "read -p" escribe su mensaje por stderr (y solo con un terminal de entrada): con "2>/dev/null" se
# lo tragaba y la pausa esperaba en silencio. El mensaje sale aparte; el silencio es solo para read.
pause_enter() {
    [[ -t 0 ]] && printf '%s' "$(ui_t press_enter)" >&2
    read -r _ 2>/dev/null
}

menu_confirm() {
    local ans
    read -rp "$1 [$( [[ "$UI_LANGUAGE" == "en" ]] && echo y/N || echo s/N )]: " ans
    [[ "$ans" =~ ^[sSyY]$ ]]
}

# Confirmación antes de "Aplicar ahora" (anonimato de red) en el menú de
# texto, con el mismo aviso reforzado que el panel gráfico si se detecta
# sesión SSH (ver panel_confirm_apply_privacy/is_ssh_session).
confirm_apply_privacy_text() {
    if is_ssh_session; then
        echo
        echo "$(ui_t warning.ssh)"
        echo "$(ui_t warning.ssh2)"
        echo "$(ui_t warning.ssh3)"
        menu_confirm "$(ui_t warning.apply_anyway)"
    else
        menu_confirm "$(ui_t menu.confirm_privacy)"
    fi
}

# "1-click y olvidar" del menú de texto: confirma aquí (igual que el panel) y
# delega todo en el subcomando raíz one-click, de modo que sudo/pkexec piden la
# contraseña una vez. Sirve también en un servidor sin entorno gráfico.
menu_action_one_click() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo
        printf -- "$(ui_t config.install_first)\n" "$CONFIG_FILE"
        pause_enter
        return
    fi
    echo
    local text
    text="$(ui_t panel.one_click_confirm)"
    is_ssh_session && text="$(ui_t panel.one_click_confirm_ssh)"
    menu_confirm "$text" || return
    menu_action one-click
}

# Ejecuta un comando con privilegios de root: directo si ya es root (p. ej.
# "sudo bash ..."), si no, con sudo o pkexec según haya sesión gráfica.
# pkexec depende de un agente de polkit de escritorio que no suele existir
# en un servidor por SSH (se colgaría o fallaría sin explicación), así que
# ahí se usa sudo, igual que recomienda la cabecera para el "install"
# inicial. A diferencia de panel_run_privileged (zenity), esta es de texto.
menu_elevate() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
        return $?
    fi
    if ! have_gui_session && command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return $?
    fi
    if command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return $?
    fi
    echo "$(ui_t menu.elevation_missing)" >&2
    printf -- "$(ui_t menu.elevation_hint)\n" "$SELF" >&2
    return 1
}

# Ejecuta un subcomando de este mismo script ("status", "activate"...) con
# privilegios de root, mostrando la salida tal cual (nada de zenity) y
# dejando una pausa para poder leerla antes de volver al menú.
menu_action() {
    if [[ ! -r "$SELF" ]]; then
        printf -- "$(ui_t menu.no_self)\n" "$SELF" >&2
        pause_enter
        return 1
    fi
    echo
    menu_elevate bash "$SELF" "$@"
    local rc=$?
    echo
    if [[ $rc -eq 0 ]]; then
        echo "$(ui_t action_ok)"
    else
        printf -- "$(ui_t action_failed)\n" "$rc"
    fi
    pause_enter
    return $rc
}

# Color solo en un terminal y si NO_COLOR no está definido (no-color.org).
menu_stdout_is_tty() { [[ -t 1 ]]; }
menu_color_enabled() {
    [[ -z "${NO_COLOR:-}" ]] && menu_stdout_is_tty
}

# Línea de estado del menú de texto: los mismos datos que la cabecera del panel
# (menu_status_items). El símbolo distingue el nivel aunque no haya color:
# ● ok, ▲ aviso, ○ apagado.
menu_print_status() {
    local level label value glyph c0 c1="" pad
    local color=0
    menu_color_enabled && { color=1; c1=$'\e[0m'; }
    while IFS='|' read -r level label value; do
        case "$level" in
            ok)   glyph='●'; c0=$'\e[32m' ;;
            warn) glyph='▲'; c0=$'\e[33m' ;;
            *)    glyph='○'; c0=$'\e[90m' ;;
        esac
        (( color )) || c0=""
        pad=$(( 17 - $(ui_text_len "$label") )); (( pad < 1 )) && pad=1
        printf ' %s%s%s %s%*s: %s\n' "$c0" "$glyph" "$c1" "$label" "$pad" "" "$value"
    done < <(menu_status_items)
}

menu_show_header() {
    echo "$(ui_t menu.header_line)"
    echo " $(ui_t menu.title)"
    echo "$(ui_t menu.header_line)"
    if [[ -x "$BIN_DST" ]]; then
        printf -- "$(ui_t menu.installed_yes)\n" "$BIN_DST"
        if systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then echo "$(ui_t menu.autostart_yes)"; else echo "$(ui_t menu.autostart_no)"; fi
        menu_print_status
    else
        printf -- "$(ui_t menu.installed_no)\n" "$(menu_number_of install)"
    fi
    [[ $EUID -ne 0 ]] && echo "$(ui_t menu.note_privileged)"
    echo "$(ui_t menu.header_line)"
}

menu_logs() {
    if [[ ! -x "$BIN_DST" ]]; then
        echo; echo "$(ui_t menu.no_logs)"; pause_enter; return
    fi
    local header
    printf -v header -- "$(ui_t panel.logs_header)" "$SERVICE" 200
    ui_section "$header"
    menu_elevate journalctl -u "$SERVICE" -n 200 --no-pager
    printf -v header -- "$(ui_t menu.logs_history)" "$EVENT_HISTORY_FILE"
    ui_section "$header"
    menu_elevate tail -n 40 "$EVENT_HISTORY_FILE" 2>/dev/null || echo "$(ui_t menu.history_missing)"
    echo
    pause_enter
}

menu_service_submenu() {
    if [[ ! -x "$BIN_DST" ]]; then
        echo
        echo "$(ui_t menu.no_service)"
        pause_enter
        return
    fi
    local opt
    while true; do
        menu_clear
        printf -- "$(ui_t menu.service_title)\n" "$SERVICE"
        echo "$(ui_t menu.start)"
        echo "$(ui_t menu.stop)"
        echo "$(ui_t menu.restart)"
        echo "$(ui_t menu.enable_autostart)"
        echo "$(ui_t menu.disable_autostart)"
        echo "$(ui_t menu.back)"
        echo
        read -rp "$(ui_t choose_option)" opt
        case "$opt" in
            1) echo "$(ui_t menu.wait_hint)"; menu_elevate systemctl start "$SERVICE" && echo "$(ui_t panel.service_started)"; pause_enter ;;
            2) menu_confirm "$(ui_t menu.stop_keep_ks)" && { menu_elevate systemctl stop "$SERVICE" && echo "$(ui_t panel.service_stopped)"; pause_enter; } ;;
            3) echo "$(ui_t menu.wait_hint)"; menu_elevate systemctl restart "$SERVICE" && echo "$(ui_t panel.service_restarted)"; pause_enter ;;
            4) menu_elevate systemctl enable "$SERVICE" "$BOOT_SERVICE" && echo "$(ui_t panel.autostart_on)"; pause_enter ;;
            5) menu_elevate systemctl disable "$SERVICE" "$BOOT_SERVICE" && echo "$(ui_t panel.autostart_off)"; pause_enter ;;
            0|"") return ;;
            *) echo "$(ui_t invalid_option)"; sleep 1 ;;
        esac
    done
}

menu_protection_submenu() {
    local opt
    while true; do
        menu_clear
        printf '-- %s --\n' "$(ui_t protection.title)"
        printf ' %d) %s\n' 1 "$(ui_t protection.menu_on)"
        printf ' %d) %s\n' 2 "$(ui_t protection.menu_off)"
        echo "$(ui_t menu.back)"
        echo
        read -rp "$(ui_t choose_option)" opt
        case "$opt" in
            1) menu_confirm "$(ui_t menu.confirm_activate)" && menu_action activate ;;
            2) menu_confirm "$(ui_t menu.confirm_deactivate)" && menu_action deactivate ;;
            0|"") return ;;
            *) echo "$(ui_t invalid_option)"; sleep 1 ;;
        esac
    done
}

menu_killswitch_submenu() {
    local opt
    while true; do
        menu_clear
        printf '-- %s --\n' "$(ui_t killswitch.title)"
        printf ' %d) %s\n' 1 "$(ui_t killswitch.menu_on)"
        printf ' %d) %s\n' 2 "$(ui_t killswitch.menu_off)"
        printf ' %d) %s\n' 3 "$(ui_t killswitch.menu_auto)"
        printf ' %d) %s\n' 4 "$(ui_t killswitch.menu_status)"
        echo "$(ui_t menu.back)"
        echo
        read -rp "$(ui_t choose_option)" opt
        case "$opt" in
            1) menu_confirm "$(ui_t menu.confirm_enable_ks)" && menu_action killswitch on ;;
            2) menu_confirm "$(ui_t menu.confirm_disable)" && menu_action killswitch off ;;
            3) menu_action killswitch auto ;;
            4) menu_action killswitch status ;;
            0|"") return ;;
            *) echo "$(ui_t invalid_option)"; sleep 1 ;;
        esac
    done
}

menu_export_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo
        printf -- "$(ui_t config.install_first)\n" "$CONFIG_FILE"
        pause_enter
        return
    fi
    local dest
    printf -- "$(ui_t menu.path_dest)" "$(date +%Y%m%d)" >&2; read -r dest
    dest="${dest:-./vpn-netguard-$(date +%Y%m%d).conf}"
    if [[ -e "$dest" ]] && ! { local q; printf -v q -- "$(ui_t menu.overwrite)" "$dest"; menu_confirm "$q"; }; then
        pause_enter
        return
    fi
    if cp -p "$CONFIG_FILE" "$dest" 2>/dev/null; then
        printf -- "$(ui_t export.ok)\n" "$dest"
    else
        printf -- "$(ui_t export.fail)\n" "$dest" >&2
    fi
    pause_enter
}

menu_import_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo
        printf -- "$(ui_t config.install_first)\n" "$CONFIG_FILE"
        pause_enter
        return
    fi
    local src
    read -rp "$(ui_t menu.path_src)" src
    [[ -z "$src" ]] && return
    if [[ ! -f "$src" ]]; then
        printf -- "$(ui_t export.no_config)\n" "$src" >&2
        pause_enter
        return
    fi
    local import_q; printf -v import_q -- "$(ui_t menu.import_confirm)" "$src"; menu_confirm "$import_q" || return

    echo
    if menu_elevate bash "$SELF" import-config "$src"; then
        echo "$(ui_t menu.saved_auto)"
    fi
    pause_enter
}

menu_backup_submenu() {
    local opt
    while true; do
        menu_clear
        echo "$(ui_t menu.backup_title)"
        echo "$(ui_t menu.backup_export)"
        echo "$(ui_t menu.backup_import)"
        echo "$(ui_t menu.back)"
        echo
        read -rp "$(ui_t choose_option)" opt
        case "$opt" in
            1) menu_export_config ;;
            2) menu_import_config ;;
            0|"") return ;;
            *) echo "$(ui_t invalid_option)" ;;
        esac
    done
}

# Por qué el panel no se puede abrir desde aquí (sin zenity, sin sesión gráfica o sin instalar):
# imprime el motivo y devuelve 0; sin salida y con 1 si se puede abrir.
panel_blocker() {
    if ! command -v zenity >/dev/null 2>&1; then
        ui_t panel.zenity_missing
    elif ! have_gui_session; then
        ui_t menu.unsupported_gui
    elif [[ ! -x "$BIN_DST" ]]; then
        ui_t menu.installed_first
    else
        return 1
    fi
}

menu_open_gui_panel() {
    local why
    if why="$(panel_blocker)"; then
        echo; echo "$why"; pause_enter; return
    fi
    # Entrada «interface»: además de abrir el panel lo fija como interfaz de arranque. Si no se
    # puede guardar se avisa y el panel se abre igualmente.
    if ui_pref_set panel; then
        printf -- "$(ui_t menu.interface_panel_set)\n" "$(menu_label interface panel)"
    else
        printf '%s\n' "$(ui_t menu.interface_save_failed)" >&2
    fi
    cmd_panel
}

menu_do_install() {
    if [[ -x "$BIN_DST" ]]; then
        menu_confirm "$(ui_t menu.confirm_reinstall)" || return
    fi
    if [[ $EUID -eq 0 ]]; then
        cmd_install
    elif [[ -r "$SELF" ]]; then
        menu_elevate bash "$SELF" install
    else
        printf -- "$(ui_t menu.no_self)\n" "$SELF" >&2
        echo "$(ui_t menu.install_hint)"
        printf '%s\n' "  sudo bash /path/to/vpn-netguard.sh install"
    fi
    pause_enter
}

menu_do_uninstall() {
    if [[ ! -x "$BIN_DST" ]]; then
        echo; echo "$(ui_t menu.installed_first)"; pause_enter; return
    fi
    # Sin confirmación propia: cmd_uninstall ya la pide (rama "hay TTY sin
    # sesión gráfica"), y este subproceso elevado siempre hereda la misma
    # terminal, así que preguntar aquí también duplicaría el aviso.
    if [[ ! -r "$SELF" ]]; then
        printf -- "$(ui_t menu.no_self)\n" "$SELF" >&2
        pause_enter
        return
    fi
    echo
    menu_elevate bash "$SELF" uninstall
    pause_enter
}

# -----------------------------------------------------------------------------
# Editor de configuración en terminal: sustituye a los formularios de zenity
# (panel_action_configure / panel_action_configure_privacy) por un menú
# numerado de "un campo por vez", pero termina escribiendo con la MISMA
# función que usa el panel gráfico (panel_write_config_keys), así que ambos
# caminos guardan exactamente igual y nunca se pisan entre sí.
# -----------------------------------------------------------------------------

# Tipo de prompt por clave de configuración. Formato de salida:
#   "enum:opcion1,opcion2,..."  -> menú de opciones fijas
#   "int:valor_por_defecto"     -> entero mayor que 0
#   "uint:valor_por_defecto"    -> entero de 0 o más (0 = "desactivado")
#   "pattern:regex:valor_por_defecto" -> debe cumplir el regex (ERE de bash)
#   "text"                      -> texto libre (puede dejarse vacío)
menu_field_spec() {
    case "$1" in
        LANGUAGE)                echo "enum:es,en" ;;
        KILLSWITCH_MODE)         echo "enum:auto,true,false" ;;
        KILLSWITCH_BOOT_RACE_AUTO_DISABLE) echo "enum:false,true" ;;
        COEXIST_MODE)            echo "enum:auto,strict" ;;
        ALLOW_LAN)                echo "enum:true,false" ;;
        LOG_LEVEL)                 echo "enum:info,debug,warn,error" ;;
        CHECK_INTERVAL)           echo "int:25" ;;
        RECONNECT_BACKOFF)       echo "pattern:^[0-9]+([[:space:]]+[0-9]+)*\$:5 15 30 60 120" ;;
        PING_TIMEOUT)              echo "int:3" ;;
        DESKTOP_NOTIFICATIONS)    echo "enum:true,false" ;;
        EVENT_HISTORY_ENABLE)    echo "enum:true,false" ;;
        EVENT_HISTORY_MAX_LINES) echo "uint:5000" ;;
        ANONYMIZE_NETWORK)        echo "enum:true,false" ;;
        MAC_MODE)                  echo "enum:stable,random,off" ;;
        ROTATE_MAC_PER_BOOT)      echo "enum:false,true" ;;
        ROTATE_MAC_EVERY_HOURS)  echo "uint:0" ;;
        RANDOMIZE_SCAN_MAC)       echo "enum:true,false" ;;
        SPOOF_HOSTNAME)            echo "enum:true,false" ;;
        HARDEN_DHCP_IDENTIFIERS) echo "enum:true,false" ;;
        IPV6_PRIVACY)              echo "enum:true,false" ;;
        DISABLE_IPV6)              echo "enum:false,true" ;;
        DISABLE_MDNS_ANNOUNCE)    echo "enum:true,false" ;;
        DISABLE_AVAHI_SERVICE)    echo "enum:false,true" ;;
        DISABLE_NETBIOS_SERVICE) echo "enum:false,true" ;;
        HARDEN_BROWSER_DOH)       echo "enum:false,true" ;;
        *)                          echo "text" ;;
    esac
}

# Los prompts de abajo escriben SIEMPRE su diálogo en stderr (nunca en
# stdout) y solo el valor final resultante va a stdout, porque se usan como
# "new[$k]=\"$(menu_prompt_... ...)\"": cualquier cosa que fuera a stdout
# quedaría capturada como si fuera el valor elegido.
menu_prompt_enum() {
    local label="$1" current="$2"; shift 2
    local -a opts=("$@")
    {
        echo
        printf '%s: %s\n' "$label" "$(printf -- "$(ui_t menu.actual)" "${current:-$(ui_t menu.empty)}")"
        local i=1 o mark
        for o in "${opts[@]}"; do
            mark=""
            [[ "$o" == "$current" ]] && mark="  ← $(ui_t menu.current_marker)"
            printf '  %d) %s%s\n' "$i" "$o" "$mark"
            ((i++))
        done
        printf '%s' "$(ui_t menu.choose_keep)"
    } >&2
    local sel
    read -r sel
    if [[ -z "$sel" ]]; then
        printf '%s' "$current"
    elif [[ "$sel" =~ ^[1-9][0-9]*$ ]] && (( sel <= ${#opts[@]} )); then
        printf '%s' "${opts[sel-1]}"
    else
        echo "$(ui_t menu.invalid_keep)" >&2
        printf '%s' "$current"
    fi
}

menu_prompt_text() {
    local label="$1" current="$2" val
    printf '\n%s\n' "$label" >&2; printf '%s' "$(printf -- "$(ui_t menu.prompt_clear)" "${current:-$(ui_t menu.empty)}")" >&2
    read -r val
    if [[ "$val" =~ ^[[:space:]]*$ ]]; then
        printf '%s' "$current"
    elif [[ "$val" == "-" ]]; then
        printf ''
    else
        printf '%s' "$val"
    fi
}

menu_prompt_int() {
    local label="$1" current="$2" default="$3" val normalized
    while true; do
        printf '\n%s' "$label" >&2; printf '%s' "$(printf -- "$(ui_t menu.prompt_keep)" "${current:-$default}")" >&2
        read -r val
        if [[ -z "$val" ]]; then
            printf '%s' "${current:-$default}"
            return 0
        fi
        if [[ "$val" =~ ^[0-9]+$ ]] && normalized="$(decimal_normalize_max "$val" 9223372036854775807)" && (( normalized > 0 )); then
            printf '%s' "$normalized"
            return 0
        fi
        echo "$(ui_t menu.int_gt0)" >&2
    done
}

# Igual que menu_prompt_int pero admite 0 (claves tipo "0 = desactivado",
# como ROTATE_MAC_EVERY_HOURS).
menu_prompt_uint() {
    local label="$1" current="$2" default="$3" val normalized
    while true; do
        printf '\n%s' "$label" >&2; printf '%s' "$(printf -- "$(ui_t menu.prompt_keep)" "${current:-$default}")" >&2
        read -r val
        if [[ -z "$val" ]]; then
            printf '%s' "${current:-$default}"
            return 0
        fi
        if [[ "$val" =~ ^[0-9]+$ ]] && normalized="$(decimal_normalize_max "$val" 9223372036854775807)"; then
            printf '%s' "$normalized"
            return 0
        fi
        echo "$(ui_t menu.int_ge0)" >&2
    done
}

# Como menu_prompt_int, pero exige que el valor cumpla un patrón regex en
# vez de "es un entero" (p. ej. RECONNECT_BACKOFF), para que el menú de
# texto valide estos campos con la misma regla que ya usa el panel gráfico.
menu_prompt_pattern() {
    local label="$1" current="$2" default="$3" pattern="$4" val
    while true; do
        printf '\n%s' "$label" >&2; printf '%s' "$(printf -- "$(ui_t menu.prompt_keep)" "${current:-$default}")" >&2
        read -r val
        if [[ -z "$val" ]]; then
            printf '%s' "${current:-$default}"
            return 0
        fi
        if [[ "$val" =~ $pattern ]]; then
            printf '%s' "$val"
            return 0
        fi
        echo "$(ui_t menu.invalid_format)" >&2
    done
}

# menu_save_config_changes <array_asociativo_con_los_cambios> [<subcomando_para_aplicarlos>]
# Sin 2º argumento: avisa de que el servicio relee el fichero solo (D4; no hace
# falta reiniciarlo). Con él (p. ej. "apply-privacy", que el servicio NO
# ejecuta): ofrece ese subcomando.
menu_save_config_changes() {
    local -n changes="$1"
    local apply_cmd="${2:-}"
    local old_language="$UI_LANGUAGE"
    local old_doh
    old_doh="$(panel_get_val HARDEN_BROWSER_DOH)"
    local -a kvs=()
    local k
    for k in "${!changes[@]}"; do
        kvs+=("$k=${changes[$k]}")
    done
    echo
    printf -- "$(ui_t menu.save_changes)\n" "$CONFIG_FILE"
    if panel_write_config_keys "${kvs[@]}"; then
        load_config >/dev/null 2>&1
        if [[ "$old_language" != "$UI_LANGUAGE" && -x "$BIN_DST" ]]; then
            menu_elevate bash "$SELF" sync-localized || echo "$(ui_t menu.sync_lang_failed)" >&2
            echo "$(ui_t menu.reopen_app_menu)"
        fi
        echo "$(ui_t menu.saved)"
        if [[ -z "$VPN_ENDPOINT_OVERRIDE" ]] && boot_killswitch_would_block; then
            ui_warn "$(ks_boot_race_warning_text)"
        fi
        if [[ "$apply_cmd" == "apply-privacy" ]]; then
            if [[ -x "$BIN_DST" ]] && confirm_apply_privacy_text; then
                menu_elevate bash "$SELF" "$apply_cmd" && echo "$(ui_t menu.applied)"
                echo "$(ui_t panel.privacy_reconnect_hint)"
                [[ "$old_doh" != "$HARDEN_BROWSER_DOH" ]] && echo "$(ui_t panel.doh_restart_browser)"
            fi
        elif [[ -x "$BIN_DST" && -n "$apply_cmd" ]] && menu_confirm "$(ui_t menu.apply_now)"; then
            menu_elevate bash "$SELF" "$apply_cmd" && echo "$(ui_t menu.applied)"
        elif [[ -x "$BIN_DST" && -z "$apply_cmd" ]]; then
            echo "$(ui_t menu.saved_auto)"
        fi
        pause_enter
        return 0
    fi
    echo "$(ui_t menu.save_failed)" >&2
    pause_enter
    return 1
}

# Explicación de la opción (ui_field_help) ajustada a UI_WIDTH, justo antes de pedir su valor.
menu_print_field_help() {   # <CLAVE>
    local help
    help="$(ui_field_help "$1")"
    [[ -n "$help" ]] || return 0
    echo
    ui_wrap '  ' '  ' "$help"
}

# menu_configure_keys "Título" <subcomando_para_aplicar_o_vacío> CLAVE1 CLAVE2 ...
menu_configure_keys() {
    local title="$1" apply_cmd="$2"; shift 2
    local -a keys=("$@")

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo
        printf -- "$(ui_t config.install_first)\n" "$CONFIG_FILE"
        pause_enter
        return
    fi

    local -A cur=() new=()
    local k
    for k in "${keys[@]}"; do cur[$k]="$(panel_get_val "$k")"; done

    local opt
    while true; do
        menu_clear
        echo "======================================================"
        echo " $title"
        echo "======================================================"
        echo "$(ui_t menu.edit_hint)"
        echo
        local i=1
        for k in "${keys[@]}"; do
            local shown="${new[$k]-${cur[$k]}}"
            printf ' %2d) %-34s: %s\n' "$i" "$(ui_field_label "$k")" "${shown:-$(ui_t menu.empty)}"
            ((i++))
        done
        echo
        echo "$(ui_t menu.save)"
        echo "$(ui_t menu.back_nosave)"
        echo
        read -rp "$(ui_t choose_option)" opt
        case "$opt" in
            0|"")
                if [[ ${#new[@]} -gt 0 ]]; then
                    menu_confirm "$(ui_t menu.unsaved_confirm)" || continue
                fi
                return
                ;;
            g|G)
                if [[ ${#new[@]} -eq 0 ]]; then
                    echo "$(ui_t menu.no_changes)"
                    pause_enter
                    return
                fi
                menu_save_config_changes new "$apply_cmd" && return
                ;;
            *)
                if [[ "$opt" =~ ^[1-9][0-9]*$ ]] && (( opt <= ${#keys[@]} )); then
                    k="${keys[opt-1]}"
                    menu_print_field_help "$k"
                    local spec type curval
                    spec="$(menu_field_spec "$k")"
                    type="${spec%%:*}"
                    curval="${new[$k]-${cur[$k]}}"
                    case "$type" in
                        enum)
                            local -a opts
                            IFS=',' read -r -a opts <<< "${spec#*:}"
                            new[$k]="$(menu_prompt_enum "$(ui_field_label "$k")" "$curval" "${opts[@]}")"
                            ;;
                        int)
                            new[$k]="$(menu_prompt_int "$(ui_field_label "$k")" "$curval" "${spec#*:}")"
                            ;;
                        uint)
                            new[$k]="$(menu_prompt_uint "$(ui_field_label "$k")" "$curval" "${spec#*:}")"
                            ;;
                        pattern)
                            local prest="${spec#*:}"
                            new[$k]="$(menu_prompt_pattern "$(ui_field_label "$k")" "$curval" "${prest##*:}" "${prest%:*}")"
                            ;;
                        *)
                            new[$k]="$(menu_prompt_text "$(ui_field_label "$k")" "$curval")"
                            ;;
                    esac
                else
                    echo "$(ui_t invalid_option)"
                fi
                ;;
        esac
    done
}

menu_configure_general() {
    menu_configure_keys "$(ui_t menu.config_title)" "" \
        LANGUAGE KILLSWITCH_MODE KILLSWITCH_BOOT_RACE_AUTO_DISABLE COEXIST_MODE ALLOW_LAN ETH_CONNECTION WIFI_CONNECTION VPN_CONNECTION VPN_PRIORITY VPN_IGNORE \
        VPN_ENDPOINT_OVERRIDE CHECK_INTERVAL RECONNECT_BACKOFF PING_TARGETS PING_TIMEOUT LOG_LEVEL \
        DNS_SERVERS DESKTOP_NOTIFICATIONS ALERT_HOOK
}

# Acceso directo al idioma: mismo mecanismo que menu_configure_general (y
# por tanto el mismo guardado/sincronizado de artefactos ya instalados),
# pero sin tener que recorrer los demás campos solo para cambiarlo.
menu_configure_language() {
    menu_configure_keys "$(ui_field_label LANGUAGE)" "" LANGUAGE
}

menu_configure_privacy() {
    menu_configure_keys "$(ui_t menu.privacy_title)" apply-privacy \
        ANONYMIZE_NETWORK MAC_MODE MAC_OUI_MASK ROTATE_MAC_PER_BOOT ROTATE_MAC_EVERY_HOURS \
        RANDOMIZE_SCAN_MAC SPOOF_HOSTNAME DHCP_HOSTNAME_OVERRIDE HARDEN_DHCP_IDENTIFIERS \
        IPV6_PRIVACY DISABLE_IPV6 DISABLE_MDNS_ANNOUNCE DISABLE_AVAHI_SERVICE \
        DISABLE_NETBIOS_SERVICE HARDEN_BROWSER_DOH
}

# Ajustes de anonimato de red: un solo submenú (Configurar / Aplicar ahora /
# Ver estado). "Aplicar" conserva la confirmación reforzada por SSH.
menu_privacy_submenu() {
    local opt
    while true; do
        menu_clear
        printf '-- %s --\n' "$(ui_t privacy.title)"
        printf ' %d) %s\n' 1 "$(ui_t privacy.menu_config)"
        printf ' %d) %s\n' 2 "$(ui_t privacy.menu_apply)"
        printf ' %d) %s\n' 3 "$(ui_t privacy.menu_status)"
        echo "$(ui_t menu.back)"
        echo
        read -rp "$(ui_t choose_option)" opt
        case "$opt" in
            1) menu_configure_privacy ;;
            2) confirm_apply_privacy_text && menu_action apply-privacy ;;
            3) menu_action privacy-status ;;
            0|"") return ;;
            *) echo "$(ui_t invalid_option)"; sleep 1 ;;
        esac
    done
}

menu_configure_monitoring() {
    menu_configure_keys "$(ui_t menu.monitoring_title)" "" \
        PROMETHEUS_TEXTFILE_DIR EVENT_HISTORY_ENABLE EVENT_HISTORY_MAX_LINES
}

# Pinta el menú de texto desde menu_rows (mismos números que el panel).
menu_print_text() {
    local kind num icon id
    while IFS='|' read -r kind num icon id; do
        if [[ "$kind" == H ]]; then
            echo "$(ui_t "$id")"
        else
            printf '%2d) %s %s\n' "$num" "$icon" "$(menu_label "$id" text)"
        fi
    done < <(menu_rows text)
    printf ' 0) %s\n' "$(ui_t menu.exit0)"
}

menu_run_text() {
    case "$1" in
        status) menu_action status ;;
        one_click) menu_action_one_click ;;
        protection) menu_protection_submenu ;;
        killswitch) menu_killswitch_submenu ;;
        language) menu_configure_language ;;
        config) menu_configure_general ;;
        privacy) menu_privacy_submenu ;;
        monitoring) menu_configure_monitoring ;;
        service) menu_service_submenu ;;
        backup) menu_backup_submenu ;;
        logs) menu_logs ;;
        doctor) menu_action doctor ;;
        uninstall) menu_do_uninstall ;;
        interface) menu_open_gui_panel ;;
        install) menu_do_install ;;
    esac
}

# Menú de texto: lo abre el subcomando "menu" (siempre, sin consultar la interfaz de
# arranque) y, sin argumentos, cmd_start_ui cuando toca la terminal.
cmd_menu() {
    # Sin check_dependencies aquí a propósito: cada opción que la necesita
    # (status, activate...) ya la vuelve a comprobar al reejecutarse como
    # subcomando (menu_action -> bash "$SELF" <subcomando>, ver el "case"
    # del punto de entrada). Exigirla también aquí dejaría todo el menú
    # inutilizable —incluida la opción de instalar— en un sistema donde
    # aún falte nmcli/iptables, justo el caso que el menú debe poder resolver.

    if [[ ! -r "$SELF" ]]; then
        printf -- "$(ui_t menu.self_warning)\n" "$SELF" >&2
        printf '%s\n' "$(ui_t menu.self_warning2)" >&2
        printf '%s\n' "$(ui_t menu.self_warning3)" >&2
        echo >&2
    fi

    local opt id
    while true; do
        menu_clear
        menu_show_header
        menu_print_text
        echo
        if ! read -rp "$(ui_t choose_option)" opt; then
            echo
            echo "$(ui_t menu.exit)"
            break
        fi
        case "$opt" in
            0|"") echo "$(ui_t menu.exit)"; break ;;
            *)
                if [[ "$opt" =~ ^[0-9]+$ ]] && id="$(menu_id_of_number text "$opt")"; then
                    menu_run_text "$id"
                else
                    echo "$(ui_t invalid_option)"; sleep 1
                fi
                ;;
        esac
    done
}

# Menú de texto: aquí mismo si hay terminal; si no, en una ventana de terminal nueva
# (terminal_open). Código 1 si no hay ni una cosa ni otra.
open_text_menu() {
    if have_terminal; then
        cmd_menu
        return 0
    fi
    terminal_open bash "$SELF" menu
}

# Tras cerrarse el panel: si fue con «Volver a la terminal» (PANEL_BACK_TO_TERMINAL), sigue en el
# menú de texto, en la terminal de quien lo lanzó o en una ventana nueva si no la hay.
panel_continue_in_terminal() {
    (( PANEL_BACK_TO_TERMINAL )) || return 0
    open_text_menu || printf '%s\n' "$(ui_t ui.no_terminal_emulator)" >&2
}

# Arranque: abre la interfaz elegida (ui_pref_get, 9.6). Sin elección manda el origen: sin
# argumentos (se ejecuta desde una terminal) el menú de texto; con «launch» (el acceso directo
# del escritorio, que no tiene terminal) el panel. Solo «launch» abre una ventana de terminal
# cuando hace falta: una entrada que no es un terminal (una tubería) sigue siendo la del menú de
# texto. Con el panel elegido pero imposible de abrir (panel_blocker) dice por qué por stderr y
# sigue en el menú de texto; la pausa evita que menu_clear borre el aviso y solo se hace con
# terminal (sin él leería de la entrada de otro programa). Si en el panel se elige «Volver a la
# terminal» sigue en el menú de texto (panel_continue_in_terminal); otra salida del panel termina.
cmd_start_ui() {
    local launcher=0 pref why
    [[ "${1:-}" == launch ]] && launcher=1
    pref="$(ui_pref_get)"
    if [[ -z "$pref" ]]; then
        if (( launcher )); then pref=panel; else pref=terminal; fi
    fi
    if [[ "$pref" == panel ]]; then
        if ! why="$(panel_blocker)"; then
            cmd_panel
            panel_continue_in_terminal
            return 0
        fi
        printf '%s\n' "$why" >&2
        have_terminal && pause_enter
    fi
    if (( ! launcher )); then
        cmd_menu
    elif ! open_text_menu; then
        # Sin terminal ni emulador donde abrirla: el panel, si se puede abrir, con el motivo.
        printf '%s\n' "$(ui_t ui.no_terminal_emulator)" >&2
        panel_blocker >/dev/null && return 1
        panel_info_box "$(ui_t ui.no_terminal_emulator)"
        cmd_panel
    fi
}

# =============================================================================
# PUNTO DE ENTRADA
# =============================================================================
print_usage() {
    printf -- "$(ui_t usage.header)\n" "$0"
    printf '\n%s\n' "$(ui_t usage.no_args)"
    printf '%s\n' "$(ui_t usage.menu)" "$(ui_t usage.install)" "$(ui_t usage.uninstall)" \
        "$(ui_t usage.panel)" "$(ui_t usage.launch)" "$(ui_t usage.start)" "$(ui_t usage.boot)" "$(ui_t usage.status)" \
        "$(ui_t usage.check)" "$(ui_t usage.doctor)" "$(ui_t usage.one_click)" "$(ui_t usage.activate)" "$(ui_t usage.deactivate)" \
        "$(ui_t usage.killswitch)" "$(ui_t usage.disable)" "$(ui_t usage.enable)" "$(ui_t usage.privacy)" "$(ui_t usage.rotate)" \
        "$(ui_t usage.privacy_status)" "$(ui_t usage.export)" "$(ui_t usage.import)" "$(ui_t usage.sync_localized)" "$(ui_t usage.version)"
    printf '\n%s\n' "$(ui_t usage.author)"
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
load_config >/dev/null 2>&1 || true
CMD="${1:-}"
case "$CMD" in
    "")
        # Sin argumentos: la interfaz de arranque fijada (menú de texto por defecto, que no
        # depende de zenity ni de tener el programa instalado).
        cmd_start_ui
        ;;
    launch)
        # Lo que ejecuta el acceso directo del escritorio: la interfaz de arranque, con una ventana de
        # terminal propia si es el menú de texto y no hay terminal.
        cmd_start_ui launch
        ;;
    menu)
        # Siempre el menú de texto, sin consultar la interfaz de arranque.
        cmd_menu
        ;;
    install)
        cmd_install "${@:2}"
        ;;
    uninstall)
        cmd_uninstall
        ;;
    panel)
        cmd_panel
        panel_continue_in_terminal
        ;;
    start)
        check_dependencies
        load_config
        daemon_main
        ;;
    boot-killswitch)
        boot_killswitch_main
        ;;
    status)
        check_dependencies
        load_config
        require_root
        print_status
        ;;
    check)
        check_dependencies
        load_config
        require_root
        cmd_check
        ;;
    doctor)
        # Sin check_dependencies aquí a propósito (a diferencia de los demás
        # subcomandos): cmd_doctor ya la comprueba internamente en subshell
        # para que una dependencia que falte no corte el resto del diagnóstico.
        cmd_doctor
        ;;
    activate)
        check_dependencies
        load_config
        require_root
        do_activate
        ;;
    deactivate)
        check_dependencies
        load_config
        require_root
        do_deactivate
        ;;
    one-click)
        check_dependencies
        load_config
        require_root
        cmd_one_click
        ;;
    killswitch)
        check_dependencies
        load_config
        cmd_killswitch "${2:-}"
        ;;
    disable-killswitch)   # alias de "killswitch off"
        check_dependencies
        load_config
        cmd_killswitch off
        ;;
    enable-killswitch)    # alias de "killswitch on"
        check_dependencies
        load_config
        cmd_killswitch on
        ;;
    apply-privacy)
        check_dependencies
        load_config
        require_root
        apply_network_privacy
        ;;
    rotate-mac)
        check_dependencies
        load_config
        require_root
        rotate_mac_now
        ;;
    privacy-status)
        check_dependencies
        load_config
        require_root
        print_privacy_status
        ;;
    export-config)
        cmd_export_config "${2:-}"
        ;;
    import-config)
        require_root
        cmd_import_config "${2:-}"
        ;;
    sync-localized)
        load_config
        sync_localized_installed_files
        ;;
    version|--version|-v)
        echo "$TITLE $VERSION"
        ;;
    -h|--help)
        print_usage
        exit 0
        ;;
    *)
        print_usage >&2
        exit 1
        ;;
esac
fi
