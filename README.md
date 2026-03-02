# WayLume 🌌

WayLume é um gerenciador de papéis de parede minimalist, autônomo e de consumo zero de recursos em background, projetado especificamente para ambientes Wayland (atualmente focado no **GNOME**).

Ele foi criado para preencher a lacuna deixada por ferramentas como o Variety, que enfrentam problemas de estabilidade no Wayland, optando por uma arquitetura robusta baseada em **Systemd Timers** e scripts nativos em vez de daemons persistentes.

## ✨ Destaques

* **Unix Way:** Um único script (`waylume.sh`) que atua como instalador, configurador (GUI), gerador de serviços e desinstalador.
* **Consumo Zero:** Não roda em background. A GUI abre apenas quando você quer configurar. O Systemd cuida do agendamento.
* **Agnóstico de Daemon:** Ao clicar em fechar, nenhuma RAM é consumida pelo WayLume.
* **Fontes Nativas:** Baixa imagens dinâmicas do Bing (Foto do Dia), NASA APOD (Astronomy Picture of the Day) ou Unsplash (Natureza).
* **Resiliência:** O Systemd Timer com `Persistent=true` garante que atualizações perdidas (com o PC desligado) sejam executadas assim que você logar.
* **Desinstalação Limpa:** Inclui uma opção de remoção completa que remove timers, scripts e arquivos de configuração, mantendo apenas as suas fotos baixadas.

## 🛠️ Pré-requisitos

O script `waylume.sh` tentará instalar automaticamente os pré-requisitos na primeira execução (requer `sudo`). Os pacotes necessários são:

* `zenity` (para a interface gráfica)
* `curl` (para baixar as imagens)
* `notify-send` / `libnotify` (para notificações discretas)

## 🚀 Instalação e Uso

O WayLume segue uma filosofia de instalação baseada na home do usuário (`~/.local/...`), sem poluir o sistema.

1.  **Clone ou Baixe o repositório** em uma pasta qualquer (ex: `~/Downloads/waylume`).

2.  Garante que o ícone `waylume.svg` está na mesma pasta.

3.  **Torne o script executável** e rode-o:

```bash
chmod +x waylume.sh
./waylume.sh
```

4. O script detectará que não está instalado e oferecerá a auto-instalação para ~/.local/bin/waylume.

5. A partir de agora, você pode fechar o terminal. O WayLume aparecerá no seu menu de aplicativos (em Acessórios ou buscando por "WayLume").


## No Menu de Configuração

Ao abrir o WayLume pelo menu do sistema, você poderá configurar:

1. 📂 Pasta da galeria: Onde as fotos serão salvas.

1. ⏱️ Tempo de atualização: De quanto em quanto tempo o Systemd baixará uma foto nova.

1. 🌍 Fontes de imagens: Escolher entre Bing, Unsplash e APOD.

1. 🚀 Instalar/Atualizar Scripts: É necessário clicar aqui após mudar as opções 1, 2 ou 3 para que as mudanças no Systemd sejam aplicadas.

1. 🎲 Mudar imagem AGORA: Sorteia uma imagem da sua galeria local e aplica instantaneamente (o "Próximo" do Variety).

1. 🗑️ Remover WayLume: Faz a faxina completa do sistema.

## 📁 Estrutura de Pastas

Para manter tudo organizado seguindo o padrão XDG, o WayLume instala os arquivos nos seguintes locais da sua Home:

- Binário e Icone: ~/.local/bin/, ~/.local/share/icons/

- Interface (Menu): ~/.local/share/applications/waylume.desktop

- Configuração: ~/.config/waylume/waylume.conf

- Background Worker: ~/.local/bin/waylume-fetch

- Agendador: ~/.config/systemd/user/waylume.*

- Imagens: ~/Pictures/WayLume (padrão)

## 📄 Licença

Este projeto está licenciado sob a GNU General Public License v3.0 (GPLv3) - [veja o arquivo LICENSE.md](LICENSE.md) para detalhes.

