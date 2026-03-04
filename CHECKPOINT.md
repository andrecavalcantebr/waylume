# CHECKPOINT — Sessão 04/03/2026

> Leia este arquivo no início de cada sessão para recuperar o contexto de desenvolvimento.

---

## Estado atual do repositório

- **Repo:** github.com/andrecavalcantebr/waylume
- **Branch:** main
- **Último commit:** `c3ac1a8` — docs: ícone SVG no título do README
- **Git log:**
  ```
  c3ac1a8  docs: substituir emoji 🌌 pelo ícone SVG do WayLume no título do README
  d364a3c  refactor: estrutura de desenvolvimento src/ + build.sh
  a1aab18  fix: timer, overlay de título, limpeza de galeria e UX
  42b91db  Initial commit
  ```

---

## Estrutura de arquivos

```
waylume/
  src/
    main.sh       (479 linhas) — instalador e GUI; contém placeholders ##FETCHER_CONTENT## e ##ICON_CONTENT##
    fetcher.sh    (162 linhas) — worker do Systemd (waylume-fetch); testável isolado com: bash src/fetcher.sh
    waylume.svg   ( 23 linhas) — ícone SVG da aplicação, editável com Inkscape
  build.sh        ( 57 linhas) — combina os três arquivos acima → waylume.sh
  waylume.sh      (662 linhas) — ARTEFATO GERADO; não editar diretamente
  README.md                   — documentação pública
  CHECKPOINT.md               — este arquivo
```

### Regra de ouro
**Sempre editar em `src/`, nunca em `waylume.sh` diretamente.**  
Após qualquer mudança:
```bash
./build.sh && ./waylume.sh --install
```

---

## Arquitetura do build.sh

O `build.sh` usa Python 3 para substituir dois placeholders em `src/main.sh`:

| Placeholder | Substituído por |
|---|---|
| `##FETCHER_CONTENT##` | conteúdo de `src/fetcher.sh` |
| `##ICON_CONTENT##` | conteúdo de `src/waylume.svg` |

Resultado: `waylume.sh` auto-suficiente (arquivo único para distribuição).

---

## Funcionalidades implementadas

### Menu (src/main.sh)
| Opção | Função |
|---|---|
| 📂 Pasta da galeria | `set_gallery_dir` |
| ⏱️ Tempo de atualização | `set_update_interval` |
| 🌍 Fontes de imagens | `set_image_sources` |
| 🔑 API Key da NASA | `set_apod_api_key` |
| 🚀 Instalar/Atualizar | `deploy_services` |
| 🎲 Mudar imagem AGORA | `fetch_and_apply_wallpaper` |
| 🧹 Limpar galeria | `clean_gallery` |
| 🗑️ Remover WayLume | `uninstall` |

### Fetcher (src/fetcher.sh)
- **3 fontes:** Bing (foto do dia), Unsplash (aleatório), APOD (NASA)
- **Cache diário:** APOD e Bing baixam apenas 1x/dia; execuções seguintes do timer rotacionam da galeria local (~0.06s, sem rede)
- **Estado persistido:** `~/.config/waylume/waylume.state` (`APOD_LAST_DATE`, `BING_LAST_DATE`)
- **Detecção de erro de API:** rate limit / key inválida → notifica usuário + usa galeria local + marca data (sem loop)
- **Overlay de título:** ImageMagick via `-composite` (método correto para JPEG sem canal alpha)
- **Portrait vs. landscape:** título no topo em imagens retrato (evita crop do GNOME), no rodapé em paisagem
- **APOD:** usa `url` (960px) em vez de `hdurl` (4K) — ~10x mais rápido

### Bugs corrigidos nesta sessão
- `yad_info/error/question` chamavam a si mesmas recursivamente → segfault (corrigido: chamam `yad` corretamente)
- `SOURCES` salvo pelo yad com `\n` literal entre itens → `case` não casava → fontes nunca baixavam (corrigido: `tr -d '[:space:]'`)
- Overlay de título com `-fill '#00000099' -draw "rectangle"` invisível em JPEG (corrigido: composite)
- `hdurl` do APOD causava demora de 30s+ (corrigido: usar `url`)

---

## Configuração atual de desenvolvimento

```bash
# ~/.config/waylume/waylume.conf
DEST_DIR="/home/andre/Imagens/WayLume"
INTERVAL="3min"
SOURCES="Bing,Unsplash,APOD"
APOD_API_KEY="KKa2wel7uNRXlBQVQTHScVwPTrYklxe79uRSRmX0"
```

> ⚠️ A API Key da NASA acima é pessoal. Para publicação/testes em outra máquina, usar `DEMO_KEY` (limite: 30 req/hora).

---

## Agenda da próxima sessão

### 1. Internacionalização (i18n) — Opção B acordada

**Abordagem:** arquivos de strings por idioma em `src/i18n/`, embutidos pelo `build.sh`.

```
src/
  i18n/
    pt_BR.sh   ← variáveis $MSG_* com strings em português (atual)
    en.sh      ← tradução para inglês
```

**Implementação:**
- Extrair todas as strings de `src/main.sh` e `src/fetcher.sh` para variáveis `$MSG_*`
- No runtime: `source "$I18N_DIR/${LANG%%_*}.sh" 2>/dev/null || source "$I18N_DIR/en.sh"`
- `build.sh` embute `pt_BR.sh` e `en.sh` como heredocs adicionais em `src/main.sh`

**Estimativa:** ~2h de refactor (extração das strings) + ~30min (tradução do en.sh)

---

### 2. Modularização das fontes — quando houver 4ª fonte

**Abordagem:** cada fonte vira um arquivo independente em `src/sources/`.

```
src/
  sources/
    apod.sh       ← testável com: bash src/sources/apod.sh
    bing.sh
    unsplash.sh
  fetcher.sh      ← orquestrador fino (~50 linhas): pick → source → validate → overlay → apply
```

**Convenção de interface (a definir):**
- Entrada: `$TARGET_PATH` (onde salvar), variáveis do `waylume.conf`
- Saída: arquivo de imagem gravado + `$IMG_TITLE` + `$MESSAGE`
- Cache de data: cada fonte gerencia o seu próprio no `waylume.state`

**Build em dois níveis:**
1. Embute `src/sources/*.sh` → `src/fetcher.sh` temporário
2. Embute fetcher temporário + `src/waylume.svg` → `waylume.sh`

**Gatilho para implementar:** quando uma 4ª fonte for adicionada.  
Com apenas 3 fontes, o custo de setup não se justifica ainda.

---

## Decisões de arquitetura já consolidadas

| Decisão | Raciocínio |
|---|---|
| `waylume.sh` é artefato único distribuído | Preserva "Unix Way": `curl .../waylume.sh \| bash` funciona |
| `src/` contém os fontes de desenvolvimento | Syntax highlighting, shellcheck, testabilidade isolada |
| `.desktop`, `.service`, `.timer` permanecem como heredocs em `src/main.sh` | Dependem de variáveis interpoladas em tempo de deploy (`$INTERVAL`, `$FETCHER_SCRIPT`) — não são artefatos com vida própria |
| Não fragmentar `src/main.sh` por menu/funcionalidade | Acoplamento total de estado global (`$YAD_BASE`, `$CONF_FILE` etc.); sem testabilidade isolada real |
| i18n via Opção B (arquivos .sh), não gettext | Sem dependências externas; compatível com arquivo único distribuído |
