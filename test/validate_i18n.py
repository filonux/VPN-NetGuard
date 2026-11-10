#!/usr/bin/env python3
import re
import sys
from pathlib import Path

LANGS = ('es', 'en')
KEY_RE = re.compile(r'^\s*(es|en):([A-Za-z0-9_.-]+)\)\s+text=', re.M)
UI_REF_RE = re.compile(r'\bui_t\s+(?:"([A-Za-z0-9_.-]+)"|\'([A-Za-z0-9_.-]+)\')')
# menu_label elige la clave con "key=nombre.clave" y la traduce después con ui_t "$key".
KEY_ASSIGN_RE = re.compile(r'\bkey=([a-z][a-z0-9_]*\.[A-Za-z0-9_]+)')
# Entrada completa (clave y texto): se quita del cuerpo para buscar referencias fuera de ella.
ENTRY_RE = re.compile(r'^[ \t]*(?:es|en):[A-Za-z0-9_.-]+\)[ \t]+text=.*?;;[ \t]*$', re.M | re.S)
# Ids del modelo del menú ("E|icono|id|ámbito"): menu_desc arma menu.desc_<id> al vuelo.
MENU_ID_RE = re.compile(r'^E\|[^|]*\|([a-z_]+)\|', re.M)
LOG_REF_RE = re.compile(r'\blog_t\s+(?:debug|info|warn|error)\s+(?:"([A-Za-z0-9_.-]+)"|\'([A-Za-z0-9_.-]+)\'|([A-Za-z0-9_.-]+))')


def main(path: str) -> int:
    text = Path(path).read_text(encoding='utf-8')
    entries = {lang: set() for lang in LANGS}
    for lang, key in KEY_RE.findall(text):
        entries[lang].add(key)

    if entries['es'] != entries['en']:
        raise AssertionError(
            f"translation key mismatch: only-es={sorted(entries['es']-entries['en'])}, "
            f"only-en={sorted(entries['en']-entries['es'])}"
        )

    ui_refs = {a or b for a, b in UI_REF_RE.findall(text)}
    ui_refs -= {'key'}
    ui_refs |= set(KEY_ASSIGN_RE.findall(text))
    log_refs = {a or b or c for a, b, c in LOG_REF_RE.findall(text)}
    missing_ui = sorted(ui_refs - entries['es'])
    missing_log = sorted(log_refs - entries['es'])
    if missing_ui or missing_log:
        raise AssertionError(f"missing translations: ui={missing_ui}, log={missing_log}")

    body = ENTRY_RE.sub('', text)
    menu_ids = set(MENU_ID_RE.findall(text))
    unused = sorted(
        key for key in entries['es']
        if (key[len('menu.desc_'):] not in menu_ids if key.startswith('menu.desc_')
            else not re.search(rf'(?<![\w.-]){re.escape(key)}(?![\w-]|\.[A-Za-z])', body))
    )
    if unused:
        raise AssertionError(f'unused translation keys: {unused}')

    print(f"i18n: {len(entries['es'])} keys, ES/EN symmetric, literal references resolved, none unused")
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_i18n.py SCRIPT')
    raise SystemExit(main(sys.argv[1]))
