#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def test_body(text: str, test_id: str) -> str:
    marker = re.search(rf'^T{int(test_id[1:])}\(\) \{{', text, re.M)
    if not marker:
        raise AssertionError(f'{test_id} has no function definition')
    start = marker.start()
    nxt = re.search(r'^T\d+\(\) \{', text[marker.end():], re.M)
    end = marker.end() + nxt.start() if nxt else len(text)
    return text[start:end]


def main(path: str) -> int:
    text = Path(path).read_text(encoding='utf-8')
    defs = re.findall(r'^T(\d+)\(\) \{', text, re.M)
    regs = re.findall(r'^run_test .*?\s(T\d+)$', text, re.M)
    if len(defs) != len(set(defs)):
        raise AssertionError('duplicate test function IDs')
    if len(regs) != len(set(regs)):
        raise AssertionError('duplicate named test registrations')
    if set(defs) != {x[1:] for x in regs}:
        raise AssertionError('defined/registered test IDs differ')
    if 'VPN_NETGUARD_TEST_SCRIPT' not in text:
        raise AssertionError('test suite cannot substitute its script under mutation testing')
    if not re.search(r'^T17\(\)', text, re.M):
        raise AssertionError('T17 missing')
    t17 = test_body(text, 'T17')
    if 'jump-count' not in t17 or re.search(r'mock iptables [\'\"]exit 0', t17):
        raise AssertionError('T17 firewall mock is not stateful; ensure_chain could hang')
    if '-C) n=$(cat "$TEST_ROOT/jump-count")' not in t17:
        raise AssertionError('T17 does not make -C eventually fail')
    print(f'harness: {len(defs)} named tests registered exactly once; T17 mock is finite')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_test_harness.py TEST_SUITE')
    raise SystemExit(main(sys.argv[1]))
