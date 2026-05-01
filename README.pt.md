# <img src="src/waylume.svg" width="52" align="center" alt="WayLume icon"> WayLume

🌐 **Idioma / Language:** 🇧🇷 Português (atual) · [🇺🇸 English](README.en.md)

WayLume é um gerenciador de papéis de parede minimalista, autônomo e de consumo zero de recursos em background para desktops Linux.

Ele foi criado para preencher a lacuna deixada por ferramentas como o Variety, que enfrentam problemas de estabilidade no Wayland, optando por uma arquitetura robusta baseada em **Systemd Timers** e scripts nativos em vez de daemons persistentes.

**Ambientes de desktop suportados:** GNOME · ubuntu:GNOME · MATE · Cinnamon · KDE Plasma ≥ 5.26 · XFCE

## ✨ Destaques

* **Consumo Zero:** Não roda em background. A GUI abre apenas quando você quer configurar. O Systemd cuida do agendamento.
* **Agnóstico de Daemon:** Ao fechar a janela, nenhuma RAM é consumida pelo WayLume.
* **Multi-Desktop:** Funciona no GNOME, ubuntu:GNOME, MATE, Cinnamon, KDE Plasma ≥ 5.26 e XFCE — detectado automaticamente via `XDG_CURRENT_DESKTOP`.
* **Cinco Fontes de Imagens:** Bing (Foto do Dia), NASA APOD (Astronomy Picture of the Day), Unsplash, Wikimedia Picture of the Day e **Galeria Local** (rotaciona suas imagens sem download) — escolha uma ou mais.
* **Um Download por Fonte por Dia:** Cada fonte é limitada a uma nova imagem por dia. Nas execuções seguintes do timer, o WayLume rotaciona automaticamente pela galeria local — sem desperdício de banda.
* **Limite da Galeria:** Número máximo de imagens configurado em disco (padrão: 60). As imagens mais antigas são removidas automaticamente após cada download.
* **Título Sobreposto:** Quando disponível, o título da imagem e o nome **WayLume** são renderizados diretamente no wallpaper via ImageMagick. A sobreposição pode ser ativada ou desativada nas Configurações (padrão: ativada).
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

Pacotes específicos por DE (pré-instalados nos respectivos desktops):

* `xfconf` — necessário no XFCE (parte da instalação padrão do XFCE)
* `plasma-apply-wallpaperimage` — necessário no KDE Plasma ≥ 5.26 (incluído no Plasma)

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

## 🗑️ Desinstalação

A galeria de fotos **não é apagada** em nenhum dos procedimentos abaixo. Somente os arquivos do WayLume (scripts, timer, ícone, atalho e configurações) são removidos.

### Via interface gráfica

1. Abra o WayLume pelo menu de aplicativos
2. Selecione **🔧 Manutenção**
3. Selecione **🗑️ Remover WayLume**
4. Confirme na janela de aviso

### Via terminal (CLI)

Se o WayLume já está instalado em `~/.local/bin`:

```bash
waylume --uninstall
```

Ou, a partir da pasta do código-fonte:

```bash
./waylume.sh --uninstall
```

Uma janela de confirmação será exibida antes de qualquer remoção.

> **O que é removido:** scripts (`~/.local/bin/waylume*`), timer e service do systemd, ícone, atalho do menu e o diretório de configuração (`~/.config/waylume/`). A galeria de imagens permanece intacta.

## 📖 Mini-manual de uso

### Menu Principal

![Menu Principal](assets/pt/screenshot-menu-main.png)

| Opção | O que faz |
| --- | --- |
| ⬇️ Baixar nova imagem agora | Baixa agora uma imagem da internet e aplica como wallpaper |
| 🎲 Imagem aleatória da galeria | Escolhe uma imagem já na galeria local (instantaneamente, sem download) |
| ➡️ Próxima imagem da galeria | Avança na galeria (ordem cronológica, circular) |
| ⬅️ Imagem anterior da galeria | Volta na galeria (ordem cronológica, circular) |
| ⚙️ Configurações | Abre o submenu de configurações |
| 🔧 Manutenção | Abre o submenu de manutenção |
| 🚪 Sair | Fecha o WayLume |

---

### Submenu: Configurações

![Submenu Configurações](assets/pt/screenshot-menu-settings.png)

| Opção | O que configura |
| --- | --- |
| 📂 Pasta da galeria | Diretório onde as fotos são armazenadas |
| ⏱️ Tempo de atualização | Com que frequência o timer troca o wallpaper (minutos ou horas) |
| 🌍 Fontes de imagens | **Bing** (foto do dia), **Unsplash** (aleatória), **APOD** (NASA), **Wikimedia** (foto do dia) e/ou **Local** (galeria local, sem internet) — cada fonte online baixa no máximo uma imagem nova por dia |
| 🔑 API Key da NASA | Chave para a API do APOD (padrão: `DEMO_KEY`) |
| 🖼️ Limite da galeria | Número máximo de imagens mantidas no disco (0 = sem limite, padrão: 60) |
| 🎨 Título nas imagens | Ativa ou desativa a exibição do título e do nome WayLume sobre o wallpaper (padrão: ativado) |

Obs. 1:
> **Fluxo de configuração:** as alterações ficam em memória até o usuário sair do submenu. Ao sair (item 7 ou botão Fechar), se houver mudanças, o WayLume pergunta se deseja aplicar. Ao confirmar, salva e reinicia o timer automaticamente.

Obs. 2:
> **Dica NASA APOD:** A chave `DEMO_KEY` tem limite de 30 req/hora. Para uso contínuo, registre uma chave gratuita em [api.nasa.gov](https://api.nasa.gov) (limite: 1.000 req/dia).

---

### Submenu: Manutenção

![Submenu Manutenção](assets/pt/screenshot-menu-maintenance.png)

| Opção | O que faz |
| --- | --- |
| ⏸️/▶️ Pausar / Retomar timer | Para ou reinicia o timer automático. O wallpaper não muda enquanto pausado; retomar não apaga a galeria |
| 🧹 Limpar galeria | Remove da galeria arquivos corrompidos ou com MIME inválido |
| 🗑️ Remover WayLume | Desinstala completamente o WayLume. Sua galeria de fotos **não** é apagada |

## 📁 Arquivos Instalados

Seguindo o padrão XDG, tudo vai para a home do usuário:

| Arquivo | Local |
| --- | --- |
| Script principal | `~/.local/bin/waylume` |
| Worker do Systemd | `~/.local/bin/waylume-fetch` |
| Ícone | `~/.local/share/icons/hicolor/scalable/apps/waylume.svg` |
| Atalho do menu | `~/.local/share/applications/waylume.desktop` |
| Configuração | `~/.config/waylume/waylume.conf` |
| Estado de downloads | `~/.config/waylume/waylume.state` |
| Timer e Service | `~/.config/systemd/user/waylume.*` |
| Galeria de imagens | `~/Imagens/WayLume` *(padrão, configurável)* |

## 🛠️ Para Desenvolvedores

Consulte o arquivo [DEVELOPER.md](DEVELOPER.md) para a documentação técnica completa: arquitetura, build system, i18n, guias para adicionar novas fontes e idiomas, e o log de decisões de arquitetura.

## 📄 Licença

Este projeto está licenciado sob a GNU General Public License v3.0 (GPLv3) — [veja o arquivo LICENSE.md](LICENSE.md) para detalhes.
