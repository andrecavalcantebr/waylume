#!/bin/bash
# build.sh — Combines src/main.sh + src/fetcher.sh → waylume.sh
# Usage: ./build.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN="$SCRIPT_DIR/src/main.sh"
FETCHER="$SCRIPT_DIR/src/fetcher.sh"
ICON="$SCRIPT_DIR/src/waylume.svg"
I18N_PT="$SCRIPT_DIR/src/i18n/pt.sh"
I18N_EN="$SCRIPT_DIR/src/i18n/en.sh"
OUTPUT="$SCRIPT_DIR/waylume.sh"

# Validate sources exist
for f in "$MAIN" "$FETCHER" "$ICON" "$I18N_PT" "$I18N_EN"; do
    [ -f "$f" ] || { echo "❌ Arquivo não encontrado: $f"; exit 1; }
done

# Embed all sources into waylume.sh via placeholder substitution
python3 - "$MAIN" "$FETCHER" "$ICON" "$I18N_PT" "$I18N_EN" "$OUTPUT" <<'PYEOF'
import sys

main_path, fetcher_path, icon_path, i18n_pt_path, i18n_en_path, output_path = sys.argv[1:]

with open(main_path) as f:
    main = f.read()
with open(fetcher_path) as f:
    fetcher = f.read().rstrip('\n')
with open(icon_path) as f:
    icon = f.read().rstrip('\n')
with open(i18n_pt_path) as f:
    i18n_pt = f.read().rstrip('\n')
with open(i18n_en_path) as f:
    i18n_en = f.read().rstrip('\n')

for placeholder in ('##FETCHER_CONTENT##', '##ICON_CONTENT##', '##I18N_PT##', '##I18N_EN##'):
    assert placeholder in main, f"Placeholder {placeholder} não encontrado em src/main.sh!"

result = (main
    .replace('##FETCHER_CONTENT##', fetcher)
    .replace('##ICON_CONTENT##',    icon)
    .replace('##I18N_PT##',         i18n_pt)
    .replace('##I18N_EN##',         i18n_en)
)

with open(output_path, 'w') as f:
    f.write(result)

lines = result.count('\n')
print(f"  src/main.sh      : {main.count(chr(10))} linhas")
print(f"  src/fetcher.sh   : {fetcher.count(chr(10))} linhas")
print(f"  src/waylume.svg  : {icon.count(chr(10))} linhas")
print(f"  src/i18n/pt.sh   : {i18n_pt.count(chr(10))} linhas")
print(f"  src/i18n/en.sh   : {i18n_en.count(chr(10))} linhas")
print(f"  waylume.sh       : {lines} linhas (saída)")
PYEOF

chmod +x "$OUTPUT"

# Optional: run shellcheck if available
if command -v shellcheck &>/dev/null; then
    echo "🔍 Rodando shellcheck..."
    shellcheck -S warning "$OUTPUT" && echo "  ✅ shellcheck OK" || echo "  ⚠️  shellcheck encontrou avisos"
fi

echo "✅ Build concluído: waylume.sh"
