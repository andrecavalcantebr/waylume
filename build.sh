#!/bin/bash
# build.sh — Combines src/main.sh + src/fetcher.sh → waylume.sh
# Usage: ./build.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN="$SCRIPT_DIR/src/main.sh"
FETCHER="$SCRIPT_DIR/src/fetcher.sh"
ICON="$SCRIPT_DIR/src/waylume.svg"
OUTPUT="$SCRIPT_DIR/waylume.sh"

# Validate sources exist
for f in "$MAIN" "$FETCHER" "$ICON"; do
    [ -f "$f" ] || { echo "❌ Arquivo não encontrado: $f"; exit 1; }
done

# Embed src/fetcher.sh inside the heredoc placeholder in src/main.sh → waylume.sh
python3 - "$MAIN" "$FETCHER" "$ICON" "$OUTPUT" <<'PYEOF'
import sys

main_path, fetcher_path, icon_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(main_path) as f:
    main = f.read()

with open(fetcher_path) as f:
    # Strip trailing newline: the heredoc adds its own
    fetcher = f.read().rstrip('\n')

with open(icon_path) as f:
    # Strip trailing newline: the heredoc adds its own
    icon = f.read().rstrip('\n')

assert '##FETCHER_CONTENT##' in main, "Placeholder não encontrado em src/main.sh!"
assert '##ICON_CONTENT##'    in main, "Placeholder não encontrado em src/main.sh!"

result = main.replace('##FETCHER_CONTENT##', fetcher).replace('##ICON_CONTENT##', icon)

with open(output_path, 'w') as f:
    f.write(result)

lines = result.count('\n')
print(f"  src/main.sh   : {main.count(chr(10))} linhas")
print(f"  src/fetcher.sh: {fetcher.count(chr(10))} linhas")
print(f"  src/waylume.svg: {icon.count(chr(10))} linhas")
print(f"  waylume.sh    : {lines} linhas (saída)")
PYEOF

chmod +x "$OUTPUT"

# Optional: run shellcheck if available
if command -v shellcheck &>/dev/null; then
    echo "🔍 Rodando shellcheck..."
    shellcheck -S warning "$OUTPUT" && echo "  ✅ shellcheck OK" || echo "  ⚠️  shellcheck encontrou avisos"
fi

echo "✅ Build concluído: waylume.sh"
