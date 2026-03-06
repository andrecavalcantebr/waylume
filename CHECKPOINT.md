# CHECKPOINT — Sessão 05/03/2026

> Leia este arquivo no início de cada sessão para recuperar o contexto de desenvolvimento.

---

## Estado atual do repositório

- **Repo:** github.com/andrecavalcantebr/waylume
- **Branch:** main
- **Último commit:** `4eb823e` — feat: i18n integração completa — strings externalizadas, auto-detecção de LANG
- **Git log:**
  ```
  4eb823e  feat: i18n integração completa — strings externalizadas, auto-detecção de LANG
  87ed124  docs: README.md vira hub de idiomas; conteúdo PT em README.pt.md
  b58e767  docs: atualizar CHECKPOINT — i18n scaffolding e brand strip text
  bba49eb  feat: i18n scaffolding — pt.sh / en.sh + README bilíngue
  2a3ba8b  refactor: substituir brand.png por texto puro no overlay do wallpaper
  6ccda8a  feat: brand strip (ícone + WayLume + QR code) no overlay do wallpaper
  31a284e  (origin/main) chore: adicionar CHECKPOINT da sessão 04/03/2026
  ```

---

## Estrutura de arquivos

```
waylume/
  src/
    main.sh       (505 linhas) — instalador e GUI; placeholders ##FETCHER_CONTENT## ##ICON_CONTENT## ##I18N_PT## ##I18N_EN##
    fetcher.sh    (236 linhas) — worker do Systemd (waylume-fetch); testável isolado com: bash src/fetcher.sh
    waylume.svg   ( 22 linhas) — ícone SVG da aplicação
    i18n/
      pt.sh       ( 99 linhas) — todas as strings em Português (Brasil)
      en.sh       ( 99 linhas) — todas as strings em English
  build.sh        ( 46 linhas) — combina os arquivos acima → waylume.sh
  waylume.sh      (961 linhas) — ARTEFATO GERADO; não editar diretamente
  README.md       (12 linhas)  — hub de idiomas (links → README.pt.md e README.en.md)
  README.pt.md                 — documentação pública em Português
  README.en.md                 — documentação pública em English
  LICENSE.md                   — GPLv3 (texto autorizado em inglês)
  LICENSE.pt.md                — resumo informativo da GPLv3 em português (não substitui o EN)
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

O `build.sh` usa Python 3 para substituir quatro placeholders em `src/main.sh`:

| Placeholder | Substituído por |
|---|---|
| `##FETCHER_CONTENT##` | conteúdo de `src/fetcher.sh` |
| `##ICON_CONTENT##` | conteúdo de `src/waylume.svg` |
| `##I18N_PT##` | conteúdo de `src/i18n/pt.sh` |
| `##I18N_EN##` | conteúdo de `src/i18n/en.sh` |

Os placeholders `##I18N_PT##` e `##I18N_EN##` ficam **dentro de heredocs** em `install_or_update`:

```bash
cat << 'WL_I18N_PT' > "$CONFIG_DIR/i18n/pt.sh"
##I18N_PT##
WL_I18N_PT
```

O Python os substitui antes do runtime, portanto o heredoc resultante contém o bundle de strings correto.

Resultado: `waylume.sh` auto-suficiente (961 linhas, arquivo único para distribuição).

---

## Internacionalização (i18n) — COMPLETA

### Arquitetura

- Bundles em `src/i18n/{lang}.sh` — variáveis `BTN_*`, `TITLE_*`, `MSG_*`, `COL_*`, `ITEM_*`, `LABEL_*`, `MENU_ITEM_*`
- Embutidos em `waylume.sh` via `##I18N_PT##` / `##I18N_EN##` dentro de heredocs
- Extraídos para `~/.config/waylume/i18n/` em `--install`
- Carregados em runtime no início de `main.sh` e `fetcher.sh`

### Detecção de idioma

```bash
_wl_lang="${LANG:-${LANGUAGE:-pt}}"
_wl_lang="${_wl_lang%%.*}"   # strip .UTF-8
_wl_lang="${_wl_lang%%_*}"   # strip _BR, _US, _AU…
_wl_lang="${_wl_lang,,}"     # lowercase
source "$CONFIG_DIR/i18n/${_wl_lang}.sh" 2>/dev/null \
    || source "$CONFIG_DIR/i18n/pt.sh" 2>/dev/null || true
```

| LANG | Resultado |
|---|---|
| `pt_BR.UTF-8`, `pt_PT.UTF-8`, `pt` | `pt.sh` ✅ |
| `en_US.UTF-8`, `en_AU.UTF-8`, `en_GB.UTF-8`, `en` | `en.sh` ✅ |
| `de_DE.UTF-8`, `C`, vazio | fallback `pt.sh` |

### First-run (antes do --install)

Variáveis de botões e títulos têm **fallbacks inline** com `${VAR:=valor}` para funcionar sem i18n files:

```bash
: "${BTN_CLOSE:=Fechar}"
: "${BTN_YES:=Sim}"
: "${BTN_NO:=Não}"
: "${BTN_OK:=OK}"
# etc.
```

### Convenções de strings dinâmicas

```bash
# Simples:
--text="${MSG_CONFIRM_DELETE}"

# Com valor dinâmico (printf):
--text="$(printf "${MSG_CONFIRM_DELETE_N}" "$COUNT")"
notify-send "WayLume" "$(printf "${MSG_FETCH_INVALID_MIME}" "$MIME")"
```

### Para adicionar um novo idioma

1. `cp src/i18n/pt.sh src/i18n/XX.sh` → traduzir
2. Adicionar `##I18N_XX##` placeholder em `install_or_update` dentro de um heredoc em `src/main.sh`
3. Atualizar `build.sh` com a nova variável `I18N_XX` e o parâmetro extra ao Python
4. `./build.sh && ./waylume.sh --install`

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
- **Overlay de título:** ImageMagick via `-composite` (JPEG sem canal alpha)
- **Brand strip (NorthWest):** texto puro no overlay: `WayLume` (DejaVu-Sans-Bold 16pt branco +14+17) + `is.gd/48OrTP` (DejaVu-Sans 13pt #bbbbbb +14+35). Sem assets externos.
- **APOD:** usa `url` (960px) em vez de `hdurl` (4K) — ~10x mais rápido

### Bugs corrigidos (sessões anteriores)
- `yad_info/error/question` chamavam a si mesmas recursivamente → segfault
- `SOURCES` salvo pelo yad com `\n` literal → `case` não casava → fontes nunca baixavam
- Overlay de título com `-fill '#00000099' -draw "rectangle"` invisível em JPEG (corrigido com composite)
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

### 1. Push para o origin

```bash
git push origin main
```

6 commits locais ainda não estão no GitHub.

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

**Gatilho para implementar:** quando uma 4ª fonte for adicionada.  
Com apenas 3 fontes, o custo de setup não se justifica ainda.

---

## Decisões de arquitetura já consolidadas

| Decisão | Raciocínio |
|---|---|
| `waylume.sh` é artefato único distribuído | Preserva "Unix Way": `curl .../waylume.sh \| bash` funciona |
| `src/` contém os fontes de desenvolvimento | Syntax highlighting, shellcheck, testabilidade isolada |
| `.desktop`, `.service`, `.timer` permanecem como heredocs em `src/main.sh` | Dependem de variáveis interpoladas em tempo de deploy (`$INTERVAL`, `$FETCHER_SCRIPT`) |
| Não fragmentar `src/main.sh` por menu/funcionalidade | Acoplamento total de estado global; sem testabilidade isolada real |
| i18n via arquivos `.sh` (Opção B), não gettext | Sem dependências externas; compatível com arquivo único distribuído |
| Brand strip texto puro (sem assets) | QR codes ficam ilegíveis comprimidos em JPEG; ícone SVG é dissonante no overlay |
| APOD usa `url` (960px) | `hdurl` (4K) causava 30s+ de download sem ganho visual perceptível |
