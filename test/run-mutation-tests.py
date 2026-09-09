#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'script' / 'vpn-netguard.sh'
SUITE = ROOT / 'test' / 'test-vpn-netguard.sh'

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
]

failures = 0
with tempfile.TemporaryDirectory(prefix='vpn-netguard-mut-') as td:
    td = Path(td)
    original = SCRIPT.read_text(encoding='utf-8')
    for name, test_id, needle, replacement in MUTATIONS:
        count = original.count(needle)
        if count != 1:
            print(f'FAIL mutation {name} [{test_id}]: target count={count}', file=sys.stderr)
            failures += 1
            continue
        mutant = td / f'{test_id}.sh'
        mutant.write_text(original.replace(needle, replacement, 1), encoding='utf-8')
        proc = subprocess.run(
            [str(SUITE)], cwd=ROOT,
            env={**os.environ, 'VPN_NETGUARD_TEST_SCRIPT': str(mutant), 'VPN_NETGUARD_TEST_ONLY': test_id},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        if proc.returncode == 0:
            print(f'FAIL mutation {name} [{test_id}]: targeted test stayed green', file=sys.stderr)
            print(proc.stdout, file=sys.stderr)
            failures += 1
        else:
            print(f'ok   mutation {name} [{test_id}]: detected')

print(f'\nMutation test summary: {len(MUTATIONS) - failures}/{len(MUTATIONS)} detected')
sys.exit(1 if failures else 0)
