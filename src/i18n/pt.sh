#!/bin/bash
# WayLume — strings em Português (Brasil)
# Carregado por main.sh e fetcher.sh via: source "$(dirname "$0")/i18n/${WAYLUME_LANG:-pt}.sh"

# ── Botões globais ────────────────────────────────────────────────────────────
BTN_CLOSE="Fechar"
BTN_NO="Não"
BTN_YES="Sim"
BTN_OK="OK"

# ── check_dependencies ────────────────────────────────────────────────────────
MSG_DEPS_NEEDED="⚠️ O WayLume precisa de alguns pacotes para funcionar"
MSG_DEPS_ASKING="Solicitando permissão para instalar..."
MSG_DEPS_APT_FAIL="⚠️  apt update falhou (rede?), tentando com índices locais..."
MSG_DEPS_NO_PM="❌ Gerenciador de pacotes não reconhecido."
MSG_DEPS_MANUAL="Por favor, instale manualmente"
MSG_DEPS_OK="✅ Dependências instaladas com sucesso!"

# ── deploy_services ───────────────────────────────────────────────────────────
MSG_DEPLOY_PROGRESS="Aplicando configurações e reiniciando timer..."
MSG_DEPLOY_DONE="Scripts gerados e Timer ativado!\nO sistema rodará a cada %s."

# ── install_or_update ─────────────────────────────────────────────────────────
MSG_UPDATE_DONE="Atualizado com sucesso!\nScripts e timer foram atualizados.\nSuas configurações foram preservadas."
MSG_INSTALL_DONE="Instalado com sucesso!\nAbra o WayLume pelo menu de aplicativos do seu sistema."

# ── uninstall ─────────────────────────────────────────────────────────────────
TITLE_UNINSTALL_CONFIRM="Aviso"
MSG_UNINSTALL_CONFIRM="Deseja realmente remover o WayLume do sistema?\nSua galeria de fotos NÃO será apagada."
MSG_UNINSTALL_DONE="WayLume desinstalado completamente."

# ── set_gallery_dir ───────────────────────────────────────────────────────────
TITLE_GALLERY_PICK="Escolha a pasta da Galeria"
MSG_GALLERY_CHANGED="Galeria alterada para:\n%s"

# ── set_update_interval ───────────────────────────────────────────────────────
TITLE_INTERVAL="Tempo de Atualização"
MSG_INTERVAL_UNIT="Unidade de tempo:"
COL_INTERVAL_UNIT="Unidade"
COL_INTERVAL_VALUE="Valor"
ITEM_INTERVAL_MIN="Minutos"
ITEM_INTERVAL_H="Horas"
LABEL_MINUTES="minutos"
LABEL_HOURS="horas"
MSG_INTERVAL_SCALE="Intervalo em %s:"   # %s = minutos | horas
MSG_INTERVAL_CHANGED="Intervalo alterado para %s."

# ── set_image_sources ─────────────────────────────────────────────────────────
TITLE_SOURCES="Fontes de Imagens"
MSG_SOURCES_PICK="Escolha de onde baixar as imagens novas:"
COL_SOURCES_NAME="Fonte"
MSG_SOURCES_CHANGED="Fontes de imagens alteradas."

# ── set_apod_api_key ──────────────────────────────────────────────────────────
TITLE_APOD_KEY="WayLume - NASA API Key"
MSG_APOD_KEY_DEMO="(usando DEMO_KEY — gere a sua em api.nasa.gov, é grátis!)"
MSG_APOD_KEY_SET="(chave configurada: %s...)"   # %s = primeiros 6 chars
MSG_APOD_KEY_PROMPT="Informe sua API Key da NASA APOD:\n%s"   # %s = MSG_APOD_KEY_*
MSG_APOD_KEY_SAVED="API Key salva!"

# ── clean_gallery ─────────────────────────────────────────────────────────────
MSG_GALLERY_CLEAN_OK="Nenhum arquivo inválido encontrado na galeria. ✅"
TITLE_GALLERY_CLEAN="WayLume - Limpar Galeria"
MSG_GALLERY_CLEAN_CONFIRM="Encontrados %d arquivo(s) corrompido(s):\n%s\n\nDeseja removê-los?"
MSG_GALLERY_CLEAN_DONE="%d arquivo(s) removido(s) da galeria."

# ── fetch_and_apply_wallpaper ─────────────────────────────────────────────────
MSG_FETCH_NO_SCRIPTS="Os scripts não foram gerados. Execute: waylume --install"
MSG_FETCH_PROGRESS="Baixando e aplicando novo wallpaper..."
MSG_FETCH_DONE="Wallpaper aplicado com sucesso! 🎉"

# ── bootstrap (auto-install / update prompt) ──────────────────────────────────
TITLE_UPDATE_PROMPT="WayLume Atualização"
MSG_UPDATE_PROMPT="O WayLume já está instalado.\nDeseja atualizar para a versão desta pasta?\n\nSuas configurações serão preservadas."
TITLE_INSTALL_PROMPT="WayLume Instalação"
MSG_INSTALL_PROMPT="O WayLume não está instalado no sistema.\nDeseja instalar agora na sua pasta de usuário (~/.local/bin)?"
MSG_PIN_FAVORITES="Fixar WayLume na barra de favoritos (Dash) para acesso rápido?"

# ── main menu ─────────────────────────────────────────────────────────────────
TITLE_MENU="WayLume - Menu"
MSG_MENU_HEADER="Gerenciador de Wallpapers para GNOME\nGaleria Atual: %s\nAtualização: %s"
COL_MENU_OPTION="Opção"
COL_MENU_ACTION="Ação"
MENU_ITEM_1="⬇️  1. Baixar nova imagem agora"
MENU_ITEM_2="🎲 2. Imagem aleatória da galeria"
MENU_ITEM_3="➡️  3. Próxima imagem da galeria"
MENU_ITEM_4="⬅️  4. Imagem anterior da galeria"
MENU_ITEM_5="⚙️  5. Configurações"
MENU_ITEM_6="🔧 6. Manutenção"
MENU_ITEM_7="🚪 7. Sair"

# ── submenu configurações ───────────────────────────────────────────────────────────────────
TITLE_SETTINGS="WayLume — Configurações"
MSG_SETTINGS_HEADER="Altere as opções desejadas. Ao sair, você poderá aplicar as mudanças."
MENU_SETTINGS_1="📂 1. Pasta da galeria"
MENU_SETTINGS_2="⏱️  2. Tempo de atualização"
MENU_SETTINGS_3="🌍 3. Fontes de imagens"
MENU_SETTINGS_4="🔑 4. API Key da NASA"
MENU_SETTINGS_5="🚪 5. Sair"
MSG_SETTINGS_APPLY_PROMPT="Configurações foram alteradas. Deseja aplicar agora?\nIsso também reinicia o timer com o novo intervalo."

# ── submenu manutenção ────────────────────────────────────────────────────────────────────────────
TITLE_MAINTENANCE="WayLume — Manutenção"
MENU_MAINTENANCE_1="🧹 1. Limpar galeria"
MENU_MAINTENANCE_2="🗑️  2. Remover WayLume"

# ── navegação na galeria ────────────────────────────────────────────────────────────────────────
MSG_NAV_APPLIED="📸 %s"
MSG_NAV_NO_IMAGES="Nenhuma imagem na galeria. Baixe novas imagens primeiro."

# ── fetcher: mensagens de notify-send ────────────────────────────────────────
MSG_FETCH_NO_IMAGES="Nenhuma imagem encontrada na galeria."
MSG_FETCH_APOD_ERROR="APOD API: %s\nUsando galeria local.\nDica: registre uma API key gratuita em api.nasa.gov"
MSG_FETCH_INVALID_MIME="⚠️ Download inválido ignorado (%s). Tente novamente."
MSG_FETCH_LOCAL="🔄 Galeria local (%s já baixado hoje)"
MSG_FETCH_SOURCE_BING="Novo wallpaper baixado via Bing"
MSG_FETCH_SOURCE_UNSPLASH="Novo wallpaper baixado via Unsplash"
MSG_FETCH_SOURCE_APOD="Novo wallpaper baixado via APOD"
MSG_FETCH_SOURCE_WIKIMEDIA="Novo wallpaper baixado via Wikimedia POTD"
