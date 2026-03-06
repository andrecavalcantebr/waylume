# <img src="src/waylume.svg" width="52" align="center" alt="WayLume icon"> WayLume

🌐 **Idioma / Language:** 🇧🇷 Português (atual) · [🇺🇸 English](README.en.md)

WayLume é um gerenciador de papéis de parede minimalista, autônomo e de consumo zero de recursos em background, projetado especificamente para ambientes Wayland (atualmente focado no **GNOME**).

Ele foi criado para preencher a lacuna deixada por ferramentas como o Variety, que enfrentam problemas de estabilidade no Wayland, optando por uma arquitetura robusta baseada em **Systemd Timers** e scripts nativos em vez de daemons persistentes.

## ✨ Destaques

* **Consumo Zero:** Não roda em background. A GUI abre apenas quando você quer configurar. O Systemd cuida do agendamento.
* **Agnóstico de Daemon:** Ao fechar a janela, nenhuma RAM é consumida pelo WayLume.
* **Três Fontes de Imagens:** Bing (Foto do Dia), NASA APOD (Astronomy Picture of the Day) ou Unsplash — escolha uma ou mais.
* **Inteligente:** Fontes com imagem-do-dia (APOD, Bing) baixam apenas uma vez por dia. Nas execuções seguintes do timer, o WayLume rotaciona automaticamente pela galeria local — sem desperdício de banda.
* **Título Sobreposto:** Quando disponível, o título da imagem é renderizado diretamente no wallpaper via ImageMagick (opcional).
* **Resiliência:** O Systemd Timer com `Persistent=true` garante que execuções perdidas (PC desligado) sejam recuperadas ao logar.
* **Desinstalação Limpa:** Remove timers, scripts e configurações sem apagar sua galeria de fotos.
* **Distribuição em Arquivo Único:** O `waylume.sh` é auto-suficiente — instalador, configurador (GUI), gerador de serviços e desinstalador, tudo em um script.

## 🛠️ Pré-requisitos

O script tentará instalar automaticamente os pré-requisitos na primeira execução (requer `sudo`). Os pacotes necessários são:

* `yad` — interface gráfica (diálogos)
* `curl` — download das imagens
* `libnotify` / `notify-send` — notificações do sistema
* `file` — validação do tipo MIME das imagens baixadas
* `imagemagick` *(opcional)* — sobreposição do título da imagem no wallpaper

## 🚀 Instalação e Uso

O WayLume instala tudo na home do usuário (`~/.local/...`), sem precisar de `sudo` após a instalação de dependências.

```bash
git clone https://github.com/andrecavalcantebr/waylume.git
cd waylume
chmod +x waylume.sh
./waylume.sh
```

O script detectará que não está instalado e oferecerá a auto-instalação. A partir daí, feche o terminal — o WayLume aparecerá no menu de aplicativos do sistema (busque por "WayLume").

Para instalar diretamente sem a pergunta interativa:

```bash
./waylume.sh --install
```

## ⚙️ Menu de Configuração

Ao abrir o WayLume pelo menu do sistema:

| Opção | Descrição |
|---|---|
| 📂 Pasta da galeria | Onde as fotos serão salvas |
| ⏱️ Tempo de atualização | Intervalo do Systemd Timer (minutos ou horas) |
| 🌍 Fontes de imagens | Bing, Unsplash e/ou APOD |
| 🔑 API Key da NASA | Chave para a API do APOD (padrão: `DEMO_KEY`) |
| 🚀 Instalar/Atualizar Scripts | Aplica configurações e reinicia o timer |
| 🎲 Mudar imagem AGORA | Rotaciona imediatamente pela galeria local |
| 🧹 Limpar galeria | Remove arquivos corrompidos ou inválidos |
| 🗑️ Remover WayLume | Desinstalação completa (galeria preservada) |

> **NASA APOD API Key:** A chave `DEMO_KEY` funciona, mas tem limite de 30 req/hora. Para uso contínuo, registre uma chave gratuita em [api.nasa.gov](https://api.nasa.gov) (limite: 1.000 req/dia) e informe no menu **🔑 API Key da NASA**.

## 📁 Arquivos Instalados

Seguindo o padrão XDG, tudo vai para a home do usuário:

| Arquivo | Local |
|---|---|
| Script principal | `~/.local/bin/waylume` |
| Worker do Systemd | `~/.local/bin/waylume-fetch` |
| Ícone | `~/.local/share/icons/hicolor/scalable/apps/waylume.svg` |
| Atalho do menu | `~/.local/share/applications/waylume.desktop` |
| Configuração | `~/.config/waylume/waylume.conf` |
| Estado de downloads | `~/.config/waylume/waylume.state` |
| Timer e Service | `~/.config/systemd/user/waylume.*` |
| Galeria de imagens | `~/Imagens/WayLume` *(padrão, configurável)* |

## 🛠️ Para Desenvolvedores

O `waylume.sh` é um **artefato gerado** — não edite-o diretamente. Os fontes estão em `src/`:

```
src/
  fetcher.sh    ← worker do Systemd (waylume-fetch): lógica de download e aplicação
  main.sh       ← instalador e GUI: menus, configuração, deploy de serviços
  waylume.svg   ← ícone da aplicação (editável com Inkscape ou à mão)
  i18n/
    pt.sh       ← strings em Português (Brasil)
    en.sh       ← strings em English
build.sh        ← combina os arquivos e gera waylume.sh
waylume.sh      ← saída do build (arquivo distribuído)
```

### Ciclo de desenvolvimento

```bash
# 1. Edite os fontes em src/
nano src/fetcher.sh

# 2. Teste o fetcher isoladamente (sem precisar instalar)
bash src/fetcher.sh

# 3. Rebuild e reinstale
./build.sh && ./waylume.sh --install
```

O `build.sh` embute `src/fetcher.sh` e `src/waylume.svg` nos respectivos heredocs de `src/main.sh`, produzindo o `waylume.sh` auto-suficiente. Requer Python 3 (presente em qualquer distro moderna).

## 📄 Licença

Este projeto está licenciado sob a GNU General Public License v3.0 (GPLv3) — [veja o arquivo LICENSE.md](LICENSE.md) para detalhes.
