#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${VPN_NETGUARD_TEST_SCRIPT:-$ROOT/script/vpn-netguard.sh}"
PINNED="0.11.0"
EXPECTED_SHA="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"

run_local() {
    local bin="$1" version
    version="$($bin --version 2>/dev/null)" || return 1
    grep -Eq "(^|[[:space:]])version:[[:space:]]+$PINNED([[:space:]]|$)" <<<"$version" || {
        echo "Expected ShellCheck $PINNED; got:" >&2
        printf '%s\n' "$version" >&2
        return 1
    }
    "$bin" -e SC2317,SC2034 -S warning "$SCRIPT"
}

if command -v shellcheck >/dev/null 2>&1; then
    run_local shellcheck
    exit $?
fi

if [[ -x "$ROOT/test/tools/shellcheck" ]]; then
    run_local "$ROOT/test/tools/shellcheck"
    exit $?
fi

if [[ "${VPN_NETGUARD_DISABLE_SHELLCHECK_DOCKER:-0}" != 1 ]] && command -v docker >/dev/null 2>&1; then
    exec docker run --rm --network=none -v "$ROOT:/src:ro" \
        "koalaman/shellcheck:v$PINNED" -e SC2317,SC2034 -S warning /src/script/vpn-netguard.sh
fi

if [[ "${VPN_NETGUARD_DISABLE_SHELLCHECK_PODMAN:-0}" != 1 ]] && command -v podman >/dev/null 2>&1; then
    exec podman run --rm --network=none -v "$ROOT:/src:ro" \
        "koalaman/shellcheck:v$PINNED" -e SC2317,SC2034 -S warning /src/script/vpn-netguard.sh
fi

if [[ "${VPN_NETGUARD_DISABLE_SHELLCHECK_NPM:-0}" != 1 ]] && command -v npm >/dev/null 2>&1; then
    if npm exec --offline --no -- shellcheck --version >/dev/null 2>&1; then
        exec npm exec --offline --no -- shellcheck -e SC2317,SC2034 -S warning "$SCRIPT"
    fi
fi

download_shellcheck() {
    local arch url sha work tarball bin
    arch="$(uname -m)"
    case "$arch" in
        x86_64)
            url="https://github.com/koalaman/shellcheck/releases/download/v$PINNED/shellcheck-v$PINNED.linux.x86_64.tar.xz"
            sha="$EXPECTED_SHA"
            ;;
        aarch64)
            url="https://github.com/koalaman/shellcheck/releases/download/v$PINNED/shellcheck-v$PINNED.linux.aarch64.tar.xz"
            sha="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
            ;;
        *) return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || return 1
    command -v tar >/dev/null 2>&1 || return 1
    work="$ROOT/test/.tools"
    mkdir -p "$work" || return 1
    tarball="$work/shellcheck-v$PINNED.$arch.tar.xz"
    bin="$work/shellcheck"
    if [[ ! -x "$bin" ]]; then
        rm -f "$tarball"
        curl -fsSL --connect-timeout 5 --max-time 30 "$url" -o "$tarball" || return 1
        printf '%s  %s\n' "$sha" "$tarball" | sha256sum -c - >/dev/null || { rm -f "$tarball"; return 1; }
        tar -xJf "$tarball" -C "$work" || return 1
        cp "$work/shellcheck-v$PINNED/shellcheck" "$bin" || return 1
        chmod 755 "$bin"
        rm -rf "$work/shellcheck-v$PINNED" "$tarball"
    fi
    [[ -x "$bin" ]] || return 1
    printf '%s\n' "$bin"
}

if [[ "${VPN_NETGUARD_DISABLE_SHELLCHECK_DOWNLOAD:-0}" != 1 ]] && bin="$(download_shellcheck 2>/dev/null)"; then
    run_local "$bin"
    exit $?
fi

run_go_shellcheck() {
    command -v go >/dev/null 2>&1 || return 1
    (cd "$ROOT" && go run "github.com/wasilibs/go-shellcheck/cmd/shellcheck@v$PINNED" --version 2>/dev/null) | grep -Eq "(^|[[:space:]])version:[[:space:]]+$PINNED([[:space:]]|$)" || return 1
    cd "$ROOT" || return 1
    go run "github.com/wasilibs/go-shellcheck/cmd/shellcheck@v$PINNED" -e SC2317,SC2034 -S warning "$SCRIPT"
}

if [[ "${VPN_NETGUARD_DISABLE_SHELLCHECK_GO:-0}" != 1 ]]; then
    if command -v go >/dev/null 2>&1 && (cd "$ROOT" && go run "github.com/wasilibs/go-shellcheck/cmd/shellcheck@v$PINNED" --version >/dev/null 2>&1); then
        run_go_shellcheck
        exit $?
    fi
fi

cat >&2 <<MSG
ShellCheck $PINNED is not available in this environment.
Expected official Linux x86_64 archive SHA-256: $EXPECTED_SHA
Run this helper again on a machine with one of: shellcheck, Docker, Podman, or npm shellcheck.
MSG
exit 2
