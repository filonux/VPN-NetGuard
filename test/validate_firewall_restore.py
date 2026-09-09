#!/usr/bin/env python3
import sys
from pathlib import Path


def parse(text: str):
    lines = [x.strip() for x in text.splitlines() if x.strip()]
    assert lines[0] == '*filter', 'missing filter table'
    assert lines[-1] == 'COMMIT', 'missing COMMIT'
    chain_decl = next((x for x in lines if x.startswith(':NETGUARD_')), None)
    assert chain_decl, 'missing NetGuard chain declaration'
    chain = chain_decl.split()[0][1:]
    body = lines[lines.index(chain_decl)+1:-1]
    flush = f'-F {chain}'
    assert flush in body, 'chain is not flushed in transaction'
    adds = [x for x in body if x.startswith(f'-A {chain} ')]
    assert adds, 'chain has no rules'
    assert adds[-1] == f'-A {chain} -j DROP', 'DROP is not final'
    assert all(x != f'-A {chain} -j DROP' for x in adds[:-1]), 'duplicate DROP before final rule'
    prefix=f'-A {chain} '
    return chain, [x[len(prefix):] for x in adds[:-1]]


def validate_v4(text: str):
    chain, rules = parse(text)
    required = [
        '-o lo -j ACCEPT',
        '-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
        '-p udp --dport 67:68 -j ACCEPT',
        '-d 1.1.1.1 -p udp --dport 53 -j ACCEPT',
        '-d 1.1.1.1 -p tcp --dport 53 -j ACCEPT',
        '-d 1.2.3.4 -p icmp --icmp-type echo-request -j ACCEPT',
        '-o tun0 -j ACCEPT',
    ]
    for r in required:
        assert r in rules, f'missing IPv4 rule: {r}'
    assert all('--icmpv6-type' not in r for r in rules)
    return chain


def validate_v6(text: str):
    chain, rules = parse(text)
    required = [
        '-o lo -j ACCEPT',
        '-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
        '-p udp --dport 546:547 -j ACCEPT',
        '-s fe80::/10 -j ACCEPT',
        '-d 2001:4860:4860::8888 -p icmpv6 --icmpv6-type echo-request -j ACCEPT',
        '-d 2001:4860:4860::8888 -p udp --dport 53 -j ACCEPT',
        '-d 2001:4860:4860::8888 -p tcp --dport 53 -j ACCEPT',
        '-o tun0 -j ACCEPT',
    ]
    for r in required:
        assert r in rules, f'missing IPv6 rule: {r}'
    assert all('--icmp-type' not in r for r in rules)
    return chain


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: validate_firewall_restore.py v4|v6 FILE')
    mode, path = sys.argv[1:]
    text = Path(path).read_text()
    if mode == 'v4':
        validate_v4(text)
    elif mode == 'v6':
        validate_v6(text)
    else:
        raise SystemExit('mode must be v4 or v6')
    print(f'{mode}: restore transaction structurally valid')


if __name__ == '__main__':
    main()
