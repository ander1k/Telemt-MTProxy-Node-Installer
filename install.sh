#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Telemt Installer v1.0
# Repository: https://github.com/ander1k/telemt
# Installer copyright (c) 2026 ander1k. MIT License.
# Telemt itself remains an independent upstream project.

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
INSTALL_ROOT=/opt/telemt
CONFIG_DIR=$INSTALL_ROOT/config
DEFAULT_VERSION=3.4.25
IMAGE_REPO=ghcr.io/telemt/telemt
INSTALLER_VERSION=1.0
PROJECT_NAME="Telemt Installer"
STEP_NO=0
STEP_TIMER_PID=""; STEP_STARTED_AT=0; STEP_TITLE=""; STEP_ACTIVE=false; STEP_HEARTBEAT=false
STUB_ENABLE=false; STUB_PORT=9443; STUB_PUBLIC_HTTPS=false
METRICS_ENABLE=false; METRICS_REMOTE=false; METRICS_PORT=9090
GEO_ENABLE=false; GEO_METRICS_PORT=9095
NODE_EXPORTER_ENABLE=false; NODE_EXPORTER_VERSION=1.5.0; NODE_EXPORTER_PORT=9100
NODE_EXPORTER_SHA256=af999fd31ab54ed3a34b9f0b10c28e9acee9ef5ac5a5d5edfdde85437db7acbb
GEOBLOCK_STATUS=not_configured

finish_step_timer() {
    local finished_at elapsed
    [[ "${STEP_ACTIVE:-false}" == true ]] || return 0
    if [[ -n "${STEP_TIMER_PID:-}" ]]; then kill "$STEP_TIMER_PID" 2>/dev/null || true; wait "$STEP_TIMER_PID" 2>/dev/null || true; fi
    finished_at=$(date +%s); elapsed=$((finished_at - STEP_STARTED_AT))
    printf "${GREEN}  ✔ ШАГ %02d завершён за %d сек.${NC}\n" "$STEP_NO" "$elapsed"
    STEP_TIMER_PID=""; STEP_ACTIVE=false
}
step() {
    finish_step_timer
    STEP_NO=$((STEP_NO+1)); STEP_TITLE=$1; STEP_STARTED_AT=$(date +%s); STEP_ACTIVE=true
    echo ""; printf "${BLUE}╭─${NC} ${BOLD}${CYAN}ШАГ %02d${NC} ${BLUE}─────────────────────────────────────────${NC}\n" "$STEP_NO"; printf "${BLUE}│${NC} ${BOLD}%s${NC}\n" "$1"; echo -e "${BLUE}╰──────────────────────────────────────────────────${NC}"
    if [[ "$STEP_HEARTBEAT" == true ]]; then
        (
            while sleep 5; do
                now=$(date +%s)
                printf "${CYAN}  ◷ ШАГ %02d выполняется: %d сек. — %s${NC}\n" "$STEP_NO" "$((now - STEP_STARTED_AT))" "$STEP_TITLE" >&2
            done
        ) &
        STEP_TIMER_PID=$!
    fi
}
ok()   { echo -e "${GREEN}  ✔ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
info() { echo -e "${CYAN}  → $1${NC}"; }
hint() { echo -e "${BLUE}  ℹ $1${NC}"; }
option() { printf "  ${GREEN}%s${NC}) ${BOLD}%s${NC}" "$1" "$2"; [[ -n "${3:-}" ]] && printf " ${CYAN}— %s${NC}" "$3"; printf "\n"; }
result_begin() { echo -e "${GREEN}  ╭─ РЕЗУЛЬТАТ: ${BOLD}$1${NC}"; }
result_line() { printf "${GREEN}  │${NC} %-20s ${BOLD}%s${NC}\n" "$1" "$2"; }
result_end() { echo -e "${GREEN}  ╰────────────────────────────────────────────────${NC}"; }
safe_install() {
    local mode=$1 source=$2 target=$3
    if [[ -e "$target" && "$source" -ef "$target" ]]; then
        chmod "$mode" "$target"
    else
        install -m "$mode" "$source" "$target"
    fi
}
die()  { echo -e "${RED}  ✖ $1${NC}" >&2; exit 1; }
yesno() { local answer; read -rp "$(echo -e "${YELLOW}$1 [$2]: ${NC}")" answer; answer=${answer:-$2}; [[ "$answer" =~ ^[YyДд]$ ]]; }
valid_ipv4() {
    local ip=$1 octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}
existing_stack_owns_port() {
    local port=$1 line pid container
    command -v ss >/dev/null 2>&1 || return 1
    line=$(ss -H -ltnp "sport = :$port" 2>/dev/null || true)
    [[ -n "$line" ]] || return 1
    if systemctl is-active --quiet telemt-node-exporter.service 2>/dev/null && \
       grep -Eq -- "--web.listen-address=[^[:space:]]*:${port}([[:space:]]|$)" /etc/systemd/system/telemt-node-exporter.service 2>/dev/null; then
        return 0
    fi
    command -v docker >/dev/null 2>&1 || return 1
    for container in telemt telemt-stub geo-exporter; do
        pid=$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || true)
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && grep -q "pid=$pid," <<< "$line" && return 0
    done
    return 1
}
check_aux_port() {
    local port=$1 label=$2
    command -v ss >/dev/null 2>&1 || return 0
    if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
        if existing_stack_owns_port "$port"; then warn "$label TCP/$port занят текущим стеком Telemt и будет безопасно переиспользован"
        else die "$label TCP/$port уже занят другим процессом"; fi
    else
        ok "$label TCP/$port свободен"
    fi
}

on_error() {
    local rc=$?
    finish_step_timer
    echo -e "\n${RED}Установка прервана (строка ${BASH_LINENO[0]}, код ${rc}).${NC}" >&2
    echo -e "${YELLOW}После исправления причины скрипт можно запустить повторно.${NC}" >&2
    exit "$rc"
}
trap on_error ERR
trap finish_step_timer EXIT

[[ $(id -u) -eq 0 ]] || die "Запустите установщик от root: sudo bash install.sh"
[[ -d /run/systemd/system ]] || die "Требуется Linux с systemd"

clear 2>/dev/null || true
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}${GREEN}●${NC} ${BOLD}TELEMT INSTALLER${NC}                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    ${BLUE}Secure MTProto stack · release v${INSTALLER_VERSION}${NC}          ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "${GREEN}  ✔${NC} Безопасные значения по умолчанию"
echo -e "${CYAN}  →${NC} Каждый выбор сопровождается подсказкой"
echo -e "${YELLOW}  ⚠${NC} Изменения применятся только после итогового подтверждения"
echo -e "${BLUE}  Каталог установки: ${INSTALL_ROOT}${NC}"

step "Предварительная проверка"
[[ -r /etc/os-release ]] || die "Не удалось определить операционную систему"
. /etc/os-release
case "${ID_LIKE:-$ID}" in
    *debian*|*ubuntu*) PKG_FAMILY=apt ;;
    *rhel*|*fedora*|*centos*) PKG_FAMILY=dnf ;;
    *) die "Поддерживаются Debian/Ubuntu и RHEL/Fedora/CentOS" ;;
esac

AVAILABLE_MB=$(df -Pm /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
[[ "$AVAILABLE_MB" -ge 1024 ]] || warn "Свободно менее 1 ГБ на разделе /opt"
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[[ "$MEM_MB" -ge 1024 ]] || warn "Оперативной памяти менее 1 ГБ"
ok "ОС: ${PRETTY_NAME}; RAM: ${MEM_MB} МБ"

SERVER_IP=$(curl -fsS -4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || curl -fsS -4 --connect-timeout 5 https://icanhazip.com 2>/dev/null || true)
SERVER_IP=${SERVER_IP//$'\n'/}
valid_ipv4 "$SERVER_IP" || SERVER_IP=""
[[ -n "$SERVER_IP" ]] && ok "Публичный IPv4: $SERVER_IP" || warn "Публичный IPv4 не определён"
ADMIN_IP=$(awk '{print $1}' <<< "${SSH_CONNECTION:-}")
[[ "$ADMIN_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || ADMIN_IP=""
result_begin "сервер готов к настройке"
result_line "ОС" "${PRETTY_NAME}"
result_line "RAM" "${MEM_MB} МБ"
result_line "Публичный IPv4" "${SERVER_IP:-не определён}"
result_line "Установка" "$INSTALL_ROOT"
result_end

step "IP, домен и порт"
hint "Сначала определим адрес прокси. Эти данные понадобятся при регистрации через @MTProxybot."
read -rp "$(echo -e "${YELLOW}Публичный домен ссылок (Enter = IP сервера): ${NC}")" PUBLIC_DOMAIN
if [[ -n "$PUBLIC_DOMAIN" ]]; then
    [[ "$PUBLIC_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Некорректное доменное имя"
    RESOLVED_DOMAIN=$(getent ahostsv4 "$PUBLIC_DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)
    [[ -n "$RESOLVED_DOMAIN" ]] || warn "DNS A-запись $PUBLIC_DOMAIN пока не разрешается"
    [[ -z "$SERVER_IP" || -z "$RESOLVED_DOMAIN" || "$RESOLVED_DOMAIN" == "$SERVER_IP" ]] || warn "DNS указывает на $RESOLVED_DOMAIN, а IP сервера — $SERVER_IP"
fi
PUBLIC_HOST=${PUBLIC_DOMAIN:-$SERVER_IP}
[[ -n "$PUBLIC_HOST" ]] || die "Укажите домен: публичный IP определить не удалось"
BOT_HOST=${SERVER_IP:-$PUBLIC_HOST}

PORT_REUSED=false
while true; do
    read -rp "$(echo -e "${YELLOW}TCP-порт Telemt [8443]: ${NC}")" PORT
    PORT=${PORT:-8443}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then warn "Введите порт 1–65535"; continue; fi
    if command -v ss >/dev/null && ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
        EXISTING_PORT=""
        for old_config in /opt/telemt/config/config.toml /opt/telemt/config.toml /etc/telemt/config.toml; do
            [[ -f "$old_config" ]] || continue
            EXISTING_PORT=$(awk '/^\[server\]/{inside=1;next} /^\[/{inside=0} inside && /^port[[:space:]]*=/{gsub(/[^0-9]/,""); print; exit}' "$old_config")
            [[ -n "$EXISTING_PORT" ]] && break
        done
        if command -v docker >/dev/null 2>&1 && docker inspect telemt >/dev/null 2>&1 && [[ "$EXISTING_PORT" == "$PORT" ]]; then
            warn "Порт $PORT занят существующим контейнером Telemt; он будет безопасно заменён"
            PORT_REUSED=true
            break
        fi
        warn "Порт $PORT уже занят"; ss -H -ltnp "sport = :$PORT" 2>/dev/null || true; continue
    fi
    break
done
[[ "$PORT_REUSED" == true ]] || ok "Порт $PORT свободен"
result_begin "данные сервера для @MTProxybot"
result_line "Публичный IP" "${SERVER_IP:-не определён}"
result_line "Адрес прокси" "$PUBLIC_HOST"
result_line "Порт" "$PORT"
result_line "DNS" "$([[ -n "$PUBLIC_DOMAIN" ]] && echo "домен выбран" || echo "используется IP")"
result_end

step "Secret и регистрация в боте"
hint "Сейчас создадим ключ. Затем передайте боту адрес, порт и Secret в указанном порядке."
read -rp "$(echo -e "${YELLOW}Версия Telemt [${DEFAULT_VERSION}; можно latest]: ${NC}")" TELEMT_VERSION
TELEMT_VERSION=${TELEMT_VERSION:-$DEFAULT_VERSION}
[[ "$TELEMT_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+|latest)$ ]] || die "Некорректная версия Telemt"
DEFAULT_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
while true; do
    read -rp "$(echo -e "${YELLOW}Proxy Secret (Enter = безопасно сгенерировать): ${NC}")" SECRET
    SECRET=${SECRET:-$DEFAULT_SECRET}
    [[ "$SECRET" =~ ^[0-9A-Fa-f]{32}$ ]] && break
    warn "Secret должен содержать ровно 32 hex-символа"
done
SECRET=${SECRET,,}
result_begin "данные для @MTProxybot"
result_line "1. Команда боту" "/newproxy"
result_line "2. IP и порт" "${BOT_HOST}:${PORT}"
result_line "3. Proxy Secret" "$SECRET"
result_end
hint "Откройте @MTProxybot, отправьте /newproxy и последовательно передайте значения выше."
hint "Бот вернёт ad_tag. Это отдельное значение, оно не совпадает с Proxy Secret."
warn "Ссылку от бота не используйте: рабочую ссылку после запуска сформирует сам Telemt."
while true; do
    read -rp "$(echo -e "${YELLOW}Ad-tag от @MTProxybot (Enter = добавить позднее): ${NC}")" AD_TAG
    [[ -z "$AD_TAG" || "$AD_TAG" =~ ^[0-9A-Fa-f]{32}$ ]] && break
    warn "Ad-tag должен содержать ровно 32 hex-символа"
done
AD_TAG=${AD_TAG,,}
result_begin "ключи приняты"
result_line "Версия Telemt" "$TELEMT_VERSION"
result_line "Proxy Secret" "$SECRET"
result_line "Ad-tag" "${AD_TAG:-не задан}"
result_end

if [[ -n "$AD_TAG" ]]; then
    result_begin "что сделать в @MTProxybot после установки"
    result_line "1. Команда" "/myproxies"
    result_line "2. Выбор" "этот сервер ${BOT_HOST}:${PORT}"
    result_line "3. Кнопка" "Set promotion"
    result_line "4. Канал" "публичная ссылка https://t.me/..."
    result_line "5. Активация" "подождать до 1 часа"
    result_end
    warn "Proxy Sponsor не показывается аккаунту, который уже подписан на выбранный канал."
fi

step "Режим и маскировка"
hint "EE маскируется под HTTPS и рекомендуется для современных Telegram-клиентов; DD оставлен для совместимости и сравнительной проверки."
option 1 "DD / secure" "режим с padding, может фильтроваться отдельными сетями"
option 2 "EE / TLS" "рекомендуется, усиленная HTTPS-маскировка"
option 3 "DD + EE" "обе ссылки для подключения"
read -rp "$(echo -e "${YELLOW}Режим [2]: ${NC}")" MODE_CHOICE; MODE_CHOICE=${MODE_CHOICE:-2}
case "$MODE_CHOICE" in 1) SECURE=true; TLS=false;; 2) SECURE=false; TLS=true;; 3) SECURE=true; TLS=true;; *) die "Неизвестный режим";; esac
MODE_LABEL="DD / secure"
[[ "$SECURE" == false ]] && MODE_LABEL="EE / TLS"
[[ "$SECURE" == true && "$TLS" == true ]] && MODE_LABEL="DD + EE"
read -rp "$(echo -e "${YELLOW}TLS-домен маскировки [petrovich.ru]: ${NC}")" TLS_DOMAIN
TLS_DOMAIN=${TLS_DOMAIN:-petrovich.ru}
[[ "$TLS_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Некорректный TLS-домен"
result_begin "режим подключения"
result_line "Адрес" "${PUBLIC_HOST}:${PORT}"
result_line "Режим" "$MODE_LABEL"
result_line "TLS-домен" "$TLS_DOMAIN"
result_end

step "HTTPS-страница-заглушка"
hint "Обычный браузер увидит сайт, а Telegram с правильным ключом — прокси."
STUB_ENABLE=false; STUB_PORT=9443; STUB_PUBLIC_HTTPS=false; STUB_TEMPLATE=1; STUB_EMAIL=""; STUB_OWNER="root"; STUB_CERT_TYPE=none
if yesno "Установить свою HTML5-страницу-заглушку?" Y; then
    STUB_ENABLE=true
    DEFAULT_STUB_DOMAIN=${PUBLIC_DOMAIN:-$TLS_DOMAIN}
    read -rp "$(echo -e "${YELLOW}Домен заглушки [${DEFAULT_STUB_DOMAIN}]: ${NC}")" STUB_DOMAIN
    STUB_DOMAIN=${STUB_DOMAIN:-$DEFAULT_STUB_DOMAIN}
    [[ "$STUB_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Некорректный домен заглушки"
    TLS_DOMAIN=$STUB_DOMAIN
    read -rp "$(echo -e "${YELLOW}Внутренний HTTPS-порт Nginx [9443]: ${NC}")" STUB_PORT; STUB_PORT=${STUB_PORT:-9443}
    [[ "$STUB_PORT" =~ ^[0-9]+$ ]] && (( STUB_PORT >= 1024 && STUB_PORT <= 65535 )) || die "Внутренний порт должен быть 1024–65535"
    option 1 "Private Cloud" "тёмная premium-страница статуса"
    option 2 "Maison Studio" "светлая журнальная композиция"
    option 3 "Aurora Launch" "атмосферная страница скорого запуска"
    read -rp "$(echo -e "${YELLOW}HTML5-шаблон [1]: ${NC}")" STUB_TEMPLATE; STUB_TEMPLATE=${STUB_TEMPLATE:-1}
    [[ "$STUB_TEMPLATE" =~ ^[1-3]$ ]] || die "Неизвестный HTML5-шаблон"
    read -rp "$(echo -e "${YELLOW}Email для Let's Encrypt (Enter = без email): ${NC}")" STUB_EMAIL
    [[ -z "$STUB_EMAIL" || "$STUB_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die "Некорректный email"
    DEFAULT_STUB_OWNER=${SUDO_USER:-root}; [[ "$DEFAULT_STUB_OWNER" == root ]] && DEFAULT_STUB_OWNER=root
    read -rp "$(echo -e "${YELLOW}Локальный пользователь для замены index.html по SFTP [${DEFAULT_STUB_OWNER}]: ${NC}")" STUB_OWNER
    STUB_OWNER=${STUB_OWNER:-$DEFAULT_STUB_OWNER}
    [[ "$STUB_OWNER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Некорректное имя пользователя"
    getent passwd "$STUB_OWNER" >/dev/null || die "Пользователь $STUB_OWNER не существует"
    if [[ -z "$PUBLIC_DOMAIN" ]]; then warn "Собственный публичный домен не указан: сначала будет создан self-signed сертификат"; fi
    if [[ "$PORT" == 443 ]]; then
        STUB_PUBLIC_HTTPS=true
        info "Telemt уже использует стандартный HTTPS/443: домен будет открываться без указания порта"
    elif yesno "Открывать заглушку также как https://${STUB_DOMAIN}/ без порта через TCP/443?" Y; then
        STUB_PUBLIC_HTTPS=true
    fi
fi
if [[ "$STUB_ENABLE" == true ]]; then
    [[ "$STUB_PORT" != "$PORT" ]] || die "Внутренний порт Nginx и порт Telemt должны различаться"
    check_aux_port "$STUB_PORT" "Внутренний Nginx"
    if [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then check_aux_port 443 "Публичная HTTPS-заглушка"; fi
fi
result_begin "HTTPS-заглушка"
result_line "Состояние" "$([[ "$STUB_ENABLE" == true ]] && echo "включена" || echo "выключена")"
[[ "$STUB_ENABLE" == true ]] && result_line "Маршрут" "${STUB_DOMAIN} → 127.0.0.1:${STUB_PORT}"
[[ "$STUB_ENABLE" == true ]] && result_line "Без порта" "$([[ "$STUB_PUBLIC_HTTPS" == true ]] && echo "https://${STUB_DOMAIN}/" || echo "выключено")"
[[ "$STUB_ENABLE" == true ]] && result_line "HTML-шаблон" "$STUB_TEMPLATE"
[[ "$STUB_ENABLE" == true ]] && result_line "SFTP-владелец" "$STUB_OWNER"
result_end

step "Метрики, GeoIP и Node Exporter"
hint "Каждая служба получает отдельный порт. Внешний доступ ограничивается точным IPv4 сервера Grafana/Prometheus."
METRICS_ENABLE=false; METRICS_REMOTE=false; METRICS_PORT=9090; GRAFANA_IP=""
if yesno "Включить Prometheus-метрики?" Y; then
    METRICS_ENABLE=true
    read -rp "$(echo -e "${YELLOW}Порт метрик [9090]: ${NC}")" METRICS_PORT; METRICS_PORT=${METRICS_PORT:-9090}
    [[ "$METRICS_PORT" =~ ^[0-9]+$ ]] && (( METRICS_PORT >= 1 && METRICS_PORT <= 65535 )) || die "Некорректный порт метрик"
fi
GEO_ENABLE=false
GEO_METRICS_PORT=9095
if yesno "Включить GeoIP-мониторинг клиентов?" Y; then
    GEO_ENABLE=true
    read -rp "$(echo -e "${YELLOW}Порт GeoIP-метрик [9095]: ${NC}")" GEO_METRICS_PORT; GEO_METRICS_PORT=${GEO_METRICS_PORT:-9095}
    [[ "$GEO_METRICS_PORT" =~ ^[0-9]+$ ]] && (( GEO_METRICS_PORT >= 1 && GEO_METRICS_PORT <= 65535 )) || die "Некорректный порт GeoIP-метрик"
fi
NODE_EXPORTER_ENABLE=false
NODE_EXPORTER_VERSION=1.5.0
NODE_EXPORTER_PORT=9100
if yesno "Установить node_exporter v${NODE_EXPORTER_VERSION} для метрик сервера?" Y; then
    NODE_EXPORTER_ENABLE=true
    [[ "$(uname -m)" == x86_64 ]] || die "node_exporter v${NODE_EXPORTER_VERSION} в этой сборке закреплён для linux-amd64 (x86_64)"
    read -rp "$(echo -e "${YELLOW}Порт node_exporter [9100]: ${NC}")" NODE_EXPORTER_PORT; NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT:-9100}
    [[ "$NODE_EXPORTER_PORT" =~ ^[0-9]+$ ]] && (( NODE_EXPORTER_PORT >= 1 && NODE_EXPORTER_PORT <= 65535 )) || die "Некорректный порт node_exporter"
fi
if [[ "$METRICS_ENABLE" == true || "$GEO_ENABLE" == true || "$NODE_EXPORTER_ENABLE" == true ]]; then
    if yesno "Открыть выбранные метрики для удалённого Grafana/Prometheus?" Y; then
        METRICS_REMOTE=true
        while true; do
            read -rp "$(echo -e "${YELLOW}Точный публичный IPv4 Grafana/Prometheus: ${NC}")" GRAFANA_IP
            valid_ipv4 "$GRAFANA_IP" && [[ "$GRAFANA_IP" != 0.0.0.0 ]] && break
            warn "Введите один точный IPv4; доступ 0.0.0.0/0 намеренно запрещён"
        done
    fi
fi
[[ "$METRICS_ENABLE" == false || "$METRICS_PORT" != "$PORT" ]] || die "Порт Telemt и порт метрик должны различаться"
[[ "$GEO_ENABLE" == false || "$GEO_METRICS_PORT" != "$PORT" ]] || die "Порт Telemt и порт GeoIP-метрик должны различаться"
[[ "$NODE_EXPORTER_ENABLE" == false || "$NODE_EXPORTER_PORT" != "$PORT" ]] || die "Порт Telemt и порт node_exporter должны различаться"
[[ "$GEO_ENABLE" == false || "$METRICS_ENABLE" == false || "$GEO_METRICS_PORT" != "$METRICS_PORT" ]] || die "Порты Prometheus и GeoIP-метрик должны различаться"
[[ "$NODE_EXPORTER_ENABLE" == false || "$METRICS_ENABLE" == false || "$NODE_EXPORTER_PORT" != "$METRICS_PORT" ]] || die "Порты Prometheus и node_exporter должны различаться"
[[ "$NODE_EXPORTER_ENABLE" == false || "$GEO_ENABLE" == false || "$NODE_EXPORTER_PORT" != "$GEO_METRICS_PORT" ]] || die "Порты GeoIP и node_exporter должны различаться"
[[ "$STUB_ENABLE" == false || "$METRICS_ENABLE" == false || "$STUB_PORT" != "$METRICS_PORT" ]] || die "Порты Nginx и Prometheus должны различаться"
[[ "$STUB_ENABLE" == false || "$GEO_ENABLE" == false || "$STUB_PORT" != "$GEO_METRICS_PORT" ]] || die "Порты Nginx и GeoIP-метрик должны различаться"
[[ "$STUB_ENABLE" == false || "$NODE_EXPORTER_ENABLE" == false || "$STUB_PORT" != "$NODE_EXPORTER_PORT" ]] || die "Порты Nginx и node_exporter должны различаться"
[[ "$STUB_PUBLIC_HTTPS" == false || "$PORT" == 443 || "$METRICS_ENABLE" == false || "$METRICS_PORT" != 443 ]] || die "TCP/443 используется публичной заглушкой; выберите другой порт Prometheus"
[[ "$STUB_PUBLIC_HTTPS" == false || "$PORT" == 443 || "$GEO_ENABLE" == false || "$GEO_METRICS_PORT" != 443 ]] || die "TCP/443 используется публичной заглушкой; выберите другой порт GeoIP"
[[ "$STUB_PUBLIC_HTTPS" == false || "$PORT" == 443 || "$NODE_EXPORTER_ENABLE" == false || "$NODE_EXPORTER_PORT" != 443 ]] || die "TCP/443 используется публичной заглушкой; выберите другой порт node_exporter"
[[ "$PORT" != 9091 ]] || die "TCP/9091 зарезервирован для локального API Telemt; выберите другой порт прокси"
[[ "$METRICS_ENABLE" == false || "$METRICS_PORT" != 9091 ]] || die "TCP/9091 зарезервирован для локального API; выберите другой порт метрик"
[[ "$GEO_ENABLE" == false || "$GEO_METRICS_PORT" != 9091 ]] || die "TCP/9091 зарезервирован для локального API; выберите другой порт GeoIP-метрик"
[[ "$NODE_EXPORTER_ENABLE" == false || "$NODE_EXPORTER_PORT" != 9091 ]] || die "TCP/9091 зарезервирован для локального API; выберите другой порт node_exporter"
[[ "$STUB_ENABLE" == false || "$STUB_PORT" != 9091 ]] || die "TCP/9091 зарезервирован для локального API; выберите другой внутренний порт Nginx"
[[ "$STUB_ENABLE" == false || "$PORT" != 80 ]] || die "При HTTPS-заглушке TCP/80 резервируется для выпуска и продления Let's Encrypt"
[[ "$STUB_ENABLE" == false || "$METRICS_ENABLE" == false || "$METRICS_PORT" != 80 ]] || die "При HTTPS-заглушке TCP/80 нельзя использовать для Prometheus: он нужен Certbot"
[[ "$STUB_ENABLE" == false || "$GEO_ENABLE" == false || "$GEO_METRICS_PORT" != 80 ]] || die "При HTTPS-заглушке TCP/80 нельзя использовать для GeoIP: он нужен Certbot"
[[ "$STUB_ENABLE" == false || "$NODE_EXPORTER_ENABLE" == false || "$NODE_EXPORTER_PORT" != 80 ]] || die "При HTTPS-заглушке TCP/80 нельзя использовать для node_exporter: он нужен Certbot"
check_aux_port 9091 "Локальный API"
[[ "$METRICS_ENABLE" == false ]] || check_aux_port "$METRICS_PORT" "Prometheus"
[[ "$GEO_ENABLE" == false ]] || check_aux_port "$GEO_METRICS_PORT" "GeoIP exporter"
[[ "$NODE_EXPORTER_ENABLE" == false ]] || check_aux_port "$NODE_EXPORTER_PORT" "node_exporter"
result_begin "мониторинг"
result_line "Prometheus" "$([[ "$METRICS_ENABLE" == true ]] && echo "включён, TCP/$METRICS_PORT" || echo "выключен")"
result_line "Доступ" "$([[ "$METRICS_REMOTE" == true ]] && echo "извне только с $GRAFANA_IP" || echo "только localhost")"
result_line "GeoIP" "$([[ "$GEO_ENABLE" == true ]] && echo "включён, TCP/$GEO_METRICS_PORT" || echo "выключен")"
result_line "node_exporter" "$([[ "$NODE_EXPORTER_ENABLE" == true ]] && echo "v$NODE_EXPORTER_VERSION, TCP/$NODE_EXPORTER_PORT" || echo "выключен")"
result_end

step "Региональная блокировка"
hint "Выберите регионы, откуда подключения к серверу должны отклоняться. SSH защищён исключениями."
option 1 "Северная Америка"
option 2 "Латинская Америка и Карибы"
option 3 "Европа"
option 4 "Азия"
option 5 "Ближний Восток"
option 6 "Африка"
option 7 "Океания"
option 0 "Не блокировать" "безопасный выбор по умолчанию"
read -rp "$(echo -e "${YELLOW}Регионы через запятую [0]: ${NC}")" GEO_CHOICES; GEO_CHOICES=${GEO_CHOICES:-0}
GEO_SCOPE=proxy
if [[ "$GEO_CHOICES" != 0 ]]; then
    option 1 "Только порт Telemt" "рекомендуется"
    option 2 "Все входящие подключения" "SSH-порты останутся исключением"
    read -rp "$(echo -e "${YELLOW}Область [1]: ${NC}")" GEO_SCOPE_CHOICE; GEO_SCOPE_CHOICE=${GEO_SCOPE_CHOICE:-1}
    [[ "$GEO_SCOPE_CHOICE" == 2 ]] && GEO_SCOPE=all
fi

declare -A REGION_CODES REGION_NAMES
REGION_NAMES[1]="Северная Америка"; REGION_CODES[1]="ca us gl pm"
REGION_NAMES[2]="Латинская Америка и Карибы"; REGION_CODES[2]="ag ai ar aw bb bl bm bo bq br bs bz cl co cr cu cw dm do ec fk gd gf gp gt gy hn ht jm kn ky lc mf mq ms mx ni pa pe pr py sr sv sx tc tt uy vc ve vg vi"
REGION_NAMES[3]="Европа"; REGION_CODES[3]="ad al at ax ba be bg by ch cy cz de dk ee es fi fo fr gb gg gi gr hr hu ie im is it je li lt lu lv mc md me mk mt nl no pl pt ro rs ru se si sk sm ua va"
REGION_NAMES[4]="Азия"; REGION_CODES[4]="af az bd bt bn cn ge hk id in jp kg kh kp kr kz la lk mm mn mo mv my np ph pk sg th tj tl tm tw uz vn"
REGION_NAMES[5]="Ближний Восток"; REGION_CODES[5]="ae am bh il iq ir jo kw lb om ps qa sa sy tr ye"
REGION_NAMES[6]="Африка"; REGION_CODES[6]="ao bf bi bj bw cd cf cg ci cm cv dj dz eg er et ga gh gm gn gq gw ke km lr ls ly ma mg ml mr mu mw mz na ne ng re rw sc sd sl sn so ss st sz td tg tn tz ug yt za zm zw"
REGION_NAMES[7]="Океания"; REGION_CODES[7]="as au ck fj fm gu ki mh mp nc nf nr nu nz pf pg pw sb tk to tv vu wf ws"
SELECTED_CODES=""; SELECTED_NAMES=""
if [[ "$GEO_CHOICES" != 0 ]]; then
    IFS=',' read -ra SELECTION <<< "$GEO_CHOICES"
    for choice in "${SELECTION[@]}"; do
        choice=${choice//[[:space:]]/}
        [[ "$choice" =~ ^[1-7]$ ]] || die "Неизвестный регион: $choice"
        SELECTED_CODES+=" ${REGION_CODES[$choice]}"
        SELECTED_NAMES+="${SELECTED_NAMES:+, }${REGION_NAMES[$choice]}"
    done
    SELECTED_CODES=$(tr ' ' '\n' <<< "$SELECTED_CODES" | sed '/^$/d' | sort -u | tr '\n' ' ')
fi

option 1 "Только IPv4" "рекомендуется, если IPv6 не нужен"
option 2 "IPv4 + IPv6" "одинаковая региональная фильтрация"
option 3 "IPv4 + открытый IPv6" "IPv6 без геофильтрации"
read -rp "$(echo -e "${YELLOW}Режим IPv6 [1]: ${NC}")" IPV6_CHOICE; IPV6_CHOICE=${IPV6_CHOICE:-1}
case "$IPV6_CHOICE" in 1) IPV6_MODE=disabled;; 2) IPV6_MODE=filtered;; 3) IPV6_MODE=open; warn "IPv6-клиенты смогут обходить региональную фильтрацию";; *) die "Неизвестный режим IPv6";; esac

SSH_PORTS="22"
if command -v sshd >/dev/null 2>&1; then
    DETECTED_SSH_PORTS=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -nu | tr '\n' ' ' || true)
    SSH_PORTS=$(printf '22\n%s\n' "$DETECTED_SSH_PORTS" | tr ' ' '\n' | sed '/^$/d' | sort -nu | tr '\n' ' ')
fi
ok "Исключения SSH: TCP ${SSH_PORTS}"
[[ -n "$ADMIN_IP" ]] && ok "Текущий адрес администратора исключён из GeoBlock: $ADMIN_IP"
result_begin "региональная защита"
result_line "Регионы" "${SELECTED_NAMES:-не блокируются}"
result_line "Область" "$GEO_SCOPE"
result_line "IPv6" "$IPV6_MODE"
result_line "SSH всегда разрешён" "$SSH_PORTS"
[[ -n "$ADMIN_IP" ]] && result_line "IP администратора" "$ADMIN_IP"
result_end

step "Fail2ban"
hint "Fail2ban автоматически блокирует IP после повторных неудачных входов по SSH."
FAIL2BAN_ENABLE=false
if yesno "Установить Fail2ban для SSH?" Y; then FAIL2BAN_ENABLE=true; fi
result_begin "защита SSH"
result_line "Fail2ban" "$([[ "$FAIL2BAN_ENABLE" == true ]] && echo "будет установлен" || echo "выключен")"
result_line "Контроль" "$([[ "$FAIL2BAN_ENABLE" == true ]] && echo "jail sshd" || echo "не применяется")"
result_end

step "Итоговый план"
hint "Проверьте параметры. До ответа «Y» настройки сервера не изменяются."
echo -e "  Telemt:          ${BOLD}${TELEMT_VERSION}${NC}"
echo -e "  Адрес:           ${BOLD}${PUBLIC_HOST}:${PORT}${NC}"
echo -e "  Proxy Secret:    ${BOLD}${SECRET}${NC}"
echo -e "  Ad-tag:          ${BOLD}${AD_TAG:-не задан}${NC}"
echo -e "  Режимы:          DD=${SECURE}, EE=${TLS}"
echo -e "  API:             только 127.0.0.1, read-only"
echo -e "  Метрики:         ${METRICS_ENABLE} $([[ "$METRICS_REMOTE" == true ]] && echo "(только $GRAFANA_IP)" || echo "(только localhost)")"
echo -e "  GeoIP monitor:   ${GEO_ENABLE}"
echo -e "  node_exporter:   ${NODE_EXPORTER_ENABLE}$([[ "$NODE_EXPORTER_ENABLE" == true ]] && echo " (v${NODE_EXPORTER_VERSION}, TCP/${NODE_EXPORTER_PORT})")"
echo -e "  GeoBlock:        ${SELECTED_NAMES:-выключен}; scope=${GEO_SCOPE}"
echo -e "  IPv6:            ${IPV6_MODE}"
echo -e "  SSH исключения:  ${SSH_PORTS}"
echo -e "  Fail2ban:        ${FAIL2BAN_ENABLE}"
echo -e "  HTTPS-заглушка:  ${STUB_ENABLE}$([[ "$STUB_ENABLE" == true ]] && echo " (${STUB_DOMAIN} → 127.0.0.1:${STUB_PORT}, шаблон ${STUB_TEMPLATE})")"
result_begin "карта портов"
result_line "TCP/$PORT" "публичный порт Telemt — открыть постоянно"
[[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]] && result_line "TCP/443" "публичная HTTPS-заглушка без порта"
result_line "TCP/80" "$([[ "$STUB_ENABLE" == true ]] && echo "публичный — только на время Certbot" || echo "не требуется установщику")"
result_line "TCP/9091" "только 127.0.0.1 — API Telemt"
[[ "$STUB_ENABLE" == true ]] && result_line "TCP/$STUB_PORT" "только 127.0.0.1 — Nginx"
[[ "$METRICS_ENABLE" == true ]] && result_line "TCP/$METRICS_PORT" "$([[ "$METRICS_REMOTE" == true ]] && echo "только $GRAFANA_IP" || echo "только 127.0.0.1")"
[[ "$GEO_ENABLE" == true ]] && result_line "TCP/$GEO_METRICS_PORT" "$([[ "$METRICS_REMOTE" == true ]] && echo "только $GRAFANA_IP" || echo "только 127.0.0.1")"
[[ "$NODE_EXPORTER_ENABLE" == true ]] && result_line "TCP/$NODE_EXPORTER_PORT" "$([[ "$METRICS_REMOTE" == true ]] && echo "node_exporter — только $GRAFANA_IP" || echo "node_exporter — только 127.0.0.1")"
result_line "Исходящий TCP/443" "Docker, ACME, GeoIP/IPdeny и Telegram"
result_line "Исходящий DNS" "UDP/TCP 53"
result_end
echo ""
warn "Внешний firewall/Security Group провайдера скрипт изменить не может. В нём нужно разрешить TCP/$PORT."
[[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]] && warn "Для сайта без порта разрешите входящий TCP/443 во внешнем firewall провайдера."
[[ "$STUB_ENABLE" == true ]] && warn "Для Let's Encrypt DNS должен указывать на сервер, а внешний TCP/80 быть доступен во время проверки."
if [[ "$METRICS_REMOTE" == true ]]; then
    REMOTE_METRIC_PORTS=""
    [[ "$METRICS_ENABLE" == true ]] && REMOTE_METRIC_PORTS+=" $METRICS_PORT"
    [[ "$GEO_ENABLE" == true ]] && REMOTE_METRIC_PORTS+=" $GEO_METRICS_PORT"
    [[ "$NODE_EXPORTER_ENABLE" == true ]] && REMOTE_METRIC_PORTS+=" $NODE_EXPORTER_PORT"
    warn "Во внешнем firewall провайдера разрешите TCP:${REMOTE_METRIC_PORTS} только с IPv4 $GRAFANA_IP."
fi
yesno "Применить этот план?" Y || die "Отменено пользователем"
STEP_HEARTBEAT=true

step "Зависимости"
if [[ "$PKG_FAMILY" == apt ]]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl wget jq iproute2 ipset iptables tar gzip openssl >/dev/null
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
    fi
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        DOCKER_OS=debian; [[ "${ID_LIKE:-$ID}" == *ubuntu* || "$ID" == ubuntu ]] && DOCKER_OS=ubuntu
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${DOCKER_OS}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        DOCKER_CODENAME=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
        [[ -n "$DOCKER_CODENAME" ]] || die "Не удалось определить codename для Docker repository"
        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_OS} ${DOCKER_CODENAME} stable
EOF
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    fi
else
    dnf install -y ca-certificates curl wget jq iproute ipset iptables tar gzip openssl >/dev/null
    dnf install -y docker docker-compose-plugin >/dev/null 2>&1 || true
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        DOCKER_OS=rhel
        [[ "$ID" == fedora ]] && DOCKER_OS=fedora
        [[ "$ID" == centos ]] && DOCKER_OS=centos
        curl -fsSL "https://download.docker.com/linux/${DOCKER_OS}/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    fi
fi
systemctl enable --now docker >/dev/null
docker compose version >/dev/null 2>&1 || die "Требуется Docker Compose v2"
if [[ "$STUB_ENABLE" == true ]]; then
    if [[ "$PKG_FAMILY" == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot >/dev/null
    else dnf install -y certbot >/dev/null; fi
fi
ok "Зависимости установлены"

step "Подготовка и резервная копия"
mkdir -p "$INSTALL_ROOT/backups" "$CONFIG_DIR" "$INSTALL_ROOT/cache" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/logs"
if [[ -d /etc/telemt ]]; then
    LEGACY_ETC="$INSTALL_ROOT/backups/legacy-etc-telemt-$(date +%Y%m%d-%H%M%S)"
    mv /etc/telemt "$LEGACY_ETC"
    chmod -R go-rwx "$LEGACY_ETC"
    ok "Старая конфигурация перенесена из /etc/telemt в $LEGACY_ETC"
fi
if [[ -f "$CONFIG_DIR/config.toml" ]]; then
    BACKUP_FILE="$INSTALL_ROOT/backups/pre-install-$(date +%Y%m%d-%H%M%S).tar.gz"
    BACKUP_ITEMS=()
    for item in opt/telemt/config opt/telemt/.env opt/telemt/docker-compose.yml opt/telemt/bin opt/telemt/node-exporter opt/telemt/install.sh opt/telemt/update.sh opt/telemt/uninstall.sh opt/telemt/doctor.sh opt/telemt/backup.sh opt/telemt/VERSION opt/telemt/INSTALLATION-SUMMARY.txt opt/telemt/README.md opt/telemt/LICENSE opt/telemt/CHANGELOG.md; do [[ -e "/$item" ]] && BACKUP_ITEMS+=("$item"); done
    [[ -d /opt/telemt/stub ]] && BACKUP_ITEMS+=(opt/telemt/stub)
    for unit in etc/systemd/system/telemt-firewall.service etc/systemd/system/telemt-geoblock.service etc/systemd/system/telemt-geoblock.timer etc/systemd/system/telemt-stub-cert.service etc/systemd/system/telemt-stub-cert.timer etc/systemd/system/telemt-node-exporter.service; do [[ -f "/$unit" ]] && BACKUP_ITEMS+=("$unit"); done
    tar -czf "$BACKUP_FILE" -C / "${BACKUP_ITEMS[@]}" 2>/dev/null || true
    ok "Предыдущая установка сохранена: $BACKUP_FILE"
fi
chmod 700 "$INSTALL_ROOT" "$INSTALL_ROOT/backups" "$INSTALL_ROOT/cache" "$INSTALL_ROOT/bin" "$CONFIG_DIR"
printf '%s\n' "$INSTALLER_VERSION" > "$INSTALL_ROOT/VERSION"
chmod 600 "$INSTALL_ROOT/VERSION"
if [[ -r "${BASH_SOURCE[0]}" ]]; then
    SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    if [[ -e "$INSTALL_ROOT/install.sh" && "${BASH_SOURCE[0]}" -ef "$INSTALL_ROOT/install.sh" ]]; then
        safe_install 700 "${BASH_SOURCE[0]}" "$INSTALL_ROOT/install.sh"
        ok "Установщик уже находится в $INSTALL_ROOT — самокопирование пропущено"
    else
        safe_install 700 "${BASH_SOURCE[0]}" "$INSTALL_ROOT/install.sh"
        ok "Установщик сохранён: $INSTALL_ROOT/install.sh"
    fi
    for doc in README.md LICENSE CHANGELOG.md; do [[ -f "$SOURCE_DIR/$doc" ]] && safe_install 600 "$SOURCE_DIR/$doc" "$INSTALL_ROOT/$doc"; done
else
    warn "Не удалось сохранить исходный install.sh; остальные файлы будут установлены штатно"
fi
if [[ -f "$INSTALL_ROOT/config.toml" ]]; then
    LEGACY_CONFIG="$INSTALL_ROOT/backups/legacy-config-$(date +%Y%m%d-%H%M%S).toml"
    mv "$INSTALL_ROOT/config.toml" "$LEGACY_CONFIG"; chmod 600 "$LEGACY_CONFIG"
    ok "Старый конфиг перемещён в $LEGACY_CONFIG"
fi
if [[ -f /opt/mtg/mtproto.sh ]]; then
    LEGACY_MANAGER="$INSTALL_ROOT/backups/legacy-mtproto-$(date +%Y%m%d-%H%M%S).sh"
    mv /opt/mtg/mtproto.sh "$LEGACY_MANAGER"; chmod 600 "$LEGACY_MANAGER"
    ok "Старый управляющий файл с секретом защищён в backups"
fi

info "Загружаю Telemt ${TELEMT_VERSION}..."
TAG_IMAGE="${IMAGE_REPO}:${TELEMT_VERSION}"
docker pull "$TAG_IMAGE"
PINNED_IMAGE=$(docker image inspect "$TAG_IMAGE" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk -v repo="$IMAGE_REPO@" 'index($0,repo)==1 {print; exit}')
[[ -n "$PINNED_IMAGE" ]] || die "Не удалось получить digest образа"
ok "Образ зафиксирован: ${PINNED_IMAGE##*@}"
TELEMT_IMAGE_USER=$(docker image inspect "$TAG_IMAGE" --format '{{.Config.User}}')
case "$TELEMT_IMAGE_USER" in
    nonroot|nonroot:nonroot|65532|65532:65532) TELEMT_RUN_UID=65532; TELEMT_RUN_GID=65532 ;;
    ""|root|0|0:0) TELEMT_RUN_UID=0; TELEMT_RUN_GID=0 ;;
    [0-9]*)
        TELEMT_RUN_UID=${TELEMT_IMAGE_USER%%:*}
        TELEMT_RUN_GID=${TELEMT_IMAGE_USER#*:}
        [[ "$TELEMT_RUN_GID" == "$TELEMT_IMAGE_USER" ]] && TELEMT_RUN_GID=$TELEMT_RUN_UID
        [[ "$TELEMT_RUN_UID" =~ ^[0-9]+$ && "$TELEMT_RUN_GID" =~ ^[0-9]+$ ]] || die "Не удалось определить UID/GID Telemt: $TELEMT_IMAGE_USER"
        ;;
    *) die "Образ Telemt использует неизвестного пользователя '$TELEMT_IMAGE_USER'; безопасная настройка прав невозможна" ;;
esac
ok "Пользователь контейнера Telemt: ${TELEMT_IMAGE_USER:-root} (${TELEMT_RUN_UID}:${TELEMT_RUN_GID})"

cat > "$INSTALL_ROOT/.env" <<EOF
TELEMT_IMAGE=$PINNED_IMAGE
TELEMT_VERSION=$TELEMT_VERSION
EOF
chmod 600 "$INSTALL_ROOT/.env"

METRICS_CONFIG=""
if [[ "$METRICS_ENABLE" == true ]]; then
    if [[ "$METRICS_REMOTE" == true ]]; then
        METRICS_LISTEN="0.0.0.0:${METRICS_PORT}"
        METRICS_WHITELIST="[\"127.0.0.1/32\", \"${GRAFANA_IP}/32\"]"
    else
        METRICS_LISTEN="127.0.0.1:${METRICS_PORT}"
        METRICS_WHITELIST='["127.0.0.1/32", "::1/128"]'
    fi
    METRICS_CONFIG="metrics_listen = \"${METRICS_LISTEN}\"
metrics_whitelist = ${METRICS_WHITELIST}"
fi
AD_TAG_LINE=""; USER_AD_TAG=""
if [[ -n "$AD_TAG" ]]; then AD_TAG_LINE="ad_tag = \"$AD_TAG\""; USER_AD_TAG="[access.user_ad_tags]
proxy = \"$AD_TAG\""; fi
IPV6_LISTENER=""; [[ "$IPV6_MODE" != disabled ]] && IPV6_LISTENER=$'\n[[server.listeners]]\nip = "::"'
MASK_TARGET_CONFIG=""
if [[ "$STUB_ENABLE" == true ]]; then
    MASK_TARGET_CONFIG="mask_host = \"127.0.0.1\"
mask_port = ${STUB_PORT}"
fi

cat > "$CONFIG_DIR/config.toml" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"
${AD_TAG_LINE}

[general.modes]
classic = false
secure = ${SECURE}
tls = ${TLS}

[general.links]
show = ["proxy"]
public_host = "${PUBLIC_HOST}"
public_port = ${PORT}

[server]
port = ${PORT}
${METRICS_CONFIG}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
read_only = true

[[server.listeners]]
ip = "0.0.0.0"
${IPV6_LISTENER}

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
${MASK_TARGET_CONFIG}
tls_emulation = true
tls_front_dir = "/run/telemt/cache/tlsfront"

[access]
replay_check_len = 65536

[access.users]
proxy = "${SECRET}"

${USER_AD_TAG}
EOF
# Каталог /opt/telemt закрыт mode 700, поэтому mode 644 не раскрывает secret
# локальным пользователям, но остаётся совместимым с Docker userns-remap.
chown root:root "$CONFIG_DIR/config.toml"
chmod 644 "$CONFIG_DIR/config.toml"

cat > "$INSTALL_ROOT/docker-compose.yml" <<'COMPOSE'
services:
  telemt:
    image: ${TELEMT_IMAGE}
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    working_dir: /run/telemt
    command: ["/etc/telemt/config.toml"]
    volumes:
      - /opt/telemt/config/config.toml:/etc/telemt/config.toml:ro
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=16m
      - /run/telemt:rw,noexec,nosuid,mode=1777,size=32m
    environment:
      - RUST_LOG=info
    healthcheck:
      test: ["CMD", "/app/telemt", "healthcheck", "/etc/telemt/config.toml", "--mode", "liveness"]
      interval: 20s
      timeout: 5s
      retries: 3
      start_period: 20s
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE"]
    read_only: true
    security_opt: ["no-new-privileges:true"]
    ulimits:
      nofile:
        soft: 65536
        hard: 262144
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
COMPOSE
chmod 600 "$INSTALL_ROOT/docker-compose.yml"

cat > "$CONFIG_DIR/installer.env" <<EOF
PORT=$PORT
METRICS_ENABLE=$METRICS_ENABLE
METRICS_REMOTE=$METRICS_REMOTE
METRICS_PORT=$METRICS_PORT
GRAFANA_IP=$GRAFANA_IP
GEO_SCOPE=$GEO_SCOPE
GEO_COUNTRIES="$SELECTED_CODES"
IPV6_MODE=$IPV6_MODE
SSH_PORTS="$SSH_PORTS"
ADMIN_IP=$ADMIN_IP
GEO_ENABLE=$GEO_ENABLE
GEO_METRICS_PORT=$GEO_METRICS_PORT
NODE_EXPORTER_ENABLE=$NODE_EXPORTER_ENABLE
NODE_EXPORTER_VERSION=$NODE_EXPORTER_VERSION
NODE_EXPORTER_PORT=$NODE_EXPORTER_PORT
PUBLIC_HOST=$PUBLIC_HOST
SERVER_IP=$SERVER_IP
TLS_DOMAIN=$TLS_DOMAIN
STUB_ENABLE=$STUB_ENABLE
STUB_DOMAIN=${STUB_DOMAIN:-}
STUB_PORT=$STUB_PORT
STUB_PUBLIC_HTTPS=$STUB_PUBLIC_HTTPS
STUB_OWNER=$STUB_OWNER
STUB_EMAIL=$STUB_EMAIL
STUB_CERT_TYPE=$STUB_CERT_TYPE
TELEMT_RUN_UID=$TELEMT_RUN_UID
TELEMT_RUN_GID=$TELEMT_RUN_GID
EOF
chmod 600 "$CONFIG_DIR/installer.env"

if [[ "$STUB_ENABLE" == true ]]; then
    step "Nginx и HTML5-заглушка"
    STUB_ROOT=$INSTALL_ROOT/stub/html
    STUB_CONFIG_DIR=$CONFIG_DIR/stub
    mkdir -p "$STUB_ROOT" "$STUB_CONFIG_DIR/certs"
    chmod 755 "$STUB_ROOT"; chmod 700 "$STUB_CONFIG_DIR" "$STUB_CONFIG_DIR/certs"
    case "$STUB_TEMPLATE" in
      1) cat > "$STUB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#071018"><title>Private Cloud</title><style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;overflow:hidden;background:#071018;color:#edf8ff;font:15px/1.6 Inter,ui-sans-serif,system-ui,sans-serif}body:before,body:after{content:"";position:fixed;width:42rem;height:42rem;border-radius:50%;filter:blur(90px);opacity:.22}body:before{background:#00c8ff;left:-18rem;top:-18rem}body:after{background:#775cff;right:-18rem;bottom:-20rem}.shell{position:relative;min-height:100vh;display:grid;grid-template-rows:auto 1fr auto;width:min(1160px,90vw);margin:auto;padding:36px 0}.nav,.foot{display:flex;justify-content:space-between;align-items:center;color:#8da6b6;text-transform:uppercase;letter-spacing:.16em;font-size:.72rem}.brand{color:#fff;font-weight:700}.brand i{display:inline-block;width:8px;height:8px;margin-right:10px;border-radius:50%;background:#4dffba;box-shadow:0 0 22px #4dffba}.hero{align-self:center;display:grid;grid-template-columns:1.25fr .75fr;gap:6vw;align-items:end}.eyebrow{color:#63dcff;text-transform:uppercase;letter-spacing:.2em;font-size:.75rem}h1{margin:.3em 0;font-size:clamp(3.6rem,9vw,8.5rem);line-height:.84;letter-spacing:-.065em}.lead{max-width:620px;color:#9db2c0;font-size:clamp(1rem,2vw,1.25rem)}.glass{padding:28px;border:1px solid #ffffff1c;border-radius:28px;background:linear-gradient(145deg,#ffffff12,#ffffff05);box-shadow:0 30px 80px #0008;backdrop-filter:blur(20px)}.state{display:flex;align-items:center;gap:10px}.pulse{width:10px;height:10px;border-radius:50%;background:#4dffba;box-shadow:0 0 24px #4dffba}.metric{display:flex;justify-content:space-between;padding:15px 0;border-bottom:1px solid #ffffff12}.metric:last-child{border:0}.metric span{color:#8da6b6}.metric b{font-weight:600}@media(max-width:760px){.shell{padding:24px 0}.hero{grid-template-columns:1fr;align-content:center}.nav span:last-child,.foot span:last-child{display:none}h1{font-size:clamp(3.4rem,18vw,6rem)}.glass{padding:22px}}
</style></head><body><main class="shell"><nav class="nav"><span class="brand"><i></i>Private cloud</span><span>Protected infrastructure</span></nav><section class="hero"><div><p class="eyebrow">Secure digital infrastructure</p><h1>Always<br>available.</h1><p class="lead">Закрытая инфраструктура работает в штатном режиме. Доступ к сервисам предоставляется только авторизованным клиентам.</p></div><aside class="glass"><div class="state"><i class="pulse"></i><b>Все системы работают</b></div><div class="metric"><span>Network</span><b>Operational</b></div><div class="metric"><span>Edge</span><b>Protected</b></div><div class="metric"><span>Availability</span><b>99.99%</b></div></aside></section><footer class="foot"><span>Encrypted by design</span><span>Service status · Online</span></footer></main></body></html>
HTML
      ;;
      2) cat > "$STUB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#eee7db"><title>Maison Studio</title><style>
*{box-sizing:border-box}body{margin:0;background:#eee7db;color:#17201c;font:16px/1.6 ui-sans-serif,system-ui,sans-serif}.page{width:min(1240px,92vw);margin:auto;min-height:100vh;display:grid;grid-template-rows:auto 1fr auto}.nav,.footer{padding:30px 0;display:flex;justify-content:space-between;border-bottom:1px solid #17201c2b;text-transform:uppercase;letter-spacing:.16em;font-size:.7rem}.hero{display:grid;grid-template-columns:1.35fr .65fr;gap:7vw;align-items:center;padding:7vh 0}.index{color:#9a6b3a}.title{font:400 clamp(4rem,10vw,9.5rem)/.78 Georgia,serif;letter-spacing:-.07em;margin:.15em 0}.title em{color:#8b5c30;font-weight:400}.copy{max-width:470px;font-size:clamp(1rem,1.8vw,1.25rem)}.card{position:relative;padding:34px;border:1px solid #17201c45;background:#f8f3e9;box-shadow:18px 18px 0 #23352d}.seal{width:82px;height:82px;display:grid;place-items:center;border:1px solid;border-radius:50%;font:italic 1.5rem Georgia;margin-bottom:64px}.card small{display:block;margin-top:25px;text-transform:uppercase;letter-spacing:.14em}.footer{border-top:1px solid #17201c2b;border-bottom:0}@media(max-width:760px){.hero{grid-template-columns:1fr;gap:50px}.title{font-size:clamp(4rem,20vw,7rem)}.card{box-shadow:10px 10px 0 #23352d}.nav span:last-child,.footer span:last-child{display:none}}
</style></head><body><main class="page"><nav class="nav"><b>Maison / Digital</b><span>Independent studio</span></nav><section class="hero"><div><span class="index">01 — Private edition</span><h1 class="title">Ideas<br>with <em>form.</em></h1><p class="copy">Пространство для новых проектов, точных идей и красивых цифровых продуктов. Основная версия сайта появится совсем скоро.</p></div><aside class="card"><div class="seal">M.</div><h2>Сдержанно.<br>Точно. Надолго.</h2><p>Мы готовим новое цифровое пространство и уделяем внимание каждой детали.</p><small>Opening soon</small></aside></section><footer class="footer"><span>Selected digital practice</span><span>Edition MMXXVI</span></footer></main></body></html>
HTML
      ;;
      3) cat > "$STUB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#090713"><title>Aurora — скоро</title><style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;overflow:hidden;background:#090713;color:#f7f3ff;font:16px/1.6 ui-sans-serif,system-ui,sans-serif}.aurora{position:fixed;inset:-35%;background:conic-gradient(from 180deg,#5d45ff00,#5d45ff99,#f451c488,#41e7d599,#5d45ff00);filter:blur(100px);animation:drift 16s ease-in-out infinite alternate;opacity:.6}@keyframes drift{to{transform:translate(16%,8%) rotate(28deg)}}.noise{position:fixed;inset:0;background-image:radial-gradient(#fff3 1px,transparent 1px);background-size:42px 42px;mask-image:linear-gradient(to bottom,#0006,transparent 75%)}.wrap{position:relative;width:min(1080px,90vw);min-height:100vh;margin:auto;display:grid;place-items:center}.card{width:100%;padding:clamp(28px,6vw,72px);border:1px solid #ffffff25;border-radius:40px;background:#0d0b18a8;box-shadow:0 40px 100px #0009;backdrop-filter:blur(28px)}.top{display:flex;justify-content:space-between;color:#bcb3d5;text-transform:uppercase;letter-spacing:.18em;font-size:.7rem}.chip{padding:8px 13px;border:1px solid #ffffff2b;border-radius:999px}.headline{margin:.65em 0 .2em;font-size:clamp(3.8rem,11vw,9rem);line-height:.82;letter-spacing:-.075em}.headline span{background:linear-gradient(90deg,#fff,#cdbdff 45%,#77f5de);-webkit-background-clip:text;background-clip:text;color:transparent}.lead{max-width:590px;color:#bcb3d5;font-size:clamp(1rem,2vw,1.2rem)}.line{height:1px;margin:42px 0 22px;background:linear-gradient(90deg,#ffffff55,transparent)}.bottom{display:flex;justify-content:space-between;color:#9389ac;font-size:.8rem}@media(max-width:600px){.card{border-radius:25px}.top span:last-child,.bottom span:last-child{display:none}.headline{font-size:clamp(3.4rem,20vw,6rem)}}
</style></head><body><div class="aurora"></div><div class="noise"></div><main class="wrap"><section class="card"><header class="top"><span class="chip">Private preview</span><span>Digital experience</span></header><h1 class="headline">Beyond<br><span>the ordinary.</span></h1><p class="lead">Новая цифровая среда готовится к запуску. Спокойная эстетика, продуманные детали и только самое необходимое.</p><div class="line"></div><footer class="bottom"><span>Открытие скоро</span><span>Secure connection · Active</span></footer></section></main></body></html>
HTML
      ;;
    esac
    STUB_GROUP=$(id -gn "$STUB_OWNER")
    chown "$STUB_OWNER:$STUB_GROUP" "$STUB_ROOT" "$STUB_ROOT/index.html"
    chmod 644 "$STUB_ROOT/index.html"

    PUBLIC_HTTPS_LISTEN=""
    if [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then PUBLIC_HTTPS_LISTEN="        listen 0.0.0.0:443 ssl;"; fi
    cat > "$STUB_CONFIG_DIR/nginx.conf" <<EOF
user root;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    server_tokens off;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 127.0.0.1:${STUB_PORT} ssl;
${PUBLIC_HTTPS_LISTEN}
        server_name ${STUB_DOMAIN};
        ssl_certificate /etc/nginx/stub/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/stub/certs/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy no-referrer always;
        root /usr/share/nginx/html;
        index index.html;
        location / { try_files \$uri \$uri/ /index.html; }
    }
}
EOF
    chmod 600 "$STUB_CONFIG_DIR/nginx.conf"

    cat > "$INSTALL_ROOT/bin/stub-cert.sh" <<'CERTSCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/telemt/config/installer.env
STUB_PUBLIC_HTTPS=${STUB_PUBLIC_HTTPS:-false}
CERT_DIR=/opt/telemt/config/stub/certs
save_type() { sed -i "s/^STUB_CERT_TYPE=.*/STUB_CERT_TYPE=$1/" /opt/telemt/config/installer.env; STUB_CERT_TYPE=$1; }
self_signed() {
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 -sha256 -subj "/CN=$STUB_DOMAIN" -addext "subjectAltName=DNS:$STUB_DOMAIN" -keyout "$CERT_DIR/selfsigned-key.pem" -out "$CERT_DIR/selfsigned-cert.pem" >/dev/null 2>&1
    ln -sfn selfsigned-cert.pem "$CERT_DIR/fullchain.pem"; ln -sfn selfsigned-key.pem "$CERT_DIR/privkey.pem"
    chmod 600 "$CERT_DIR/selfsigned-key.pem"; save_type selfsigned
}
port80_free() { ! ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; }
dns_ready() { [[ -n "$SERVER_IP" ]] && getent ahostsv4 "$STUB_DOMAIN" 2>/dev/null | awk '{print $1}' | grep -Fxq "$SERVER_IP"; }
with_http_rule() {
    local added4=false added6=false rc
    iptables -w 5 -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || { iptables -w 5 -I INPUT 1 -p tcp --dport 80 -j ACCEPT; added4=true; }
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -w 5 -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || { ip6tables -w 5 -I INPUT 1 -p tcp --dport 80 -j ACCEPT; added6=true; }
    fi
    echo "Certificate check: TCP/80 temporarily allowed in the local IPv4/IPv6 firewall"
    set +e; "$@"; rc=$?; set -e
    [[ "$added4" == true ]] && iptables -w 5 -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    [[ "$added6" == true ]] && ip6tables -w 5 -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    echo "Certificate check: temporary TCP/80 firewall rules removed"
    return "$rc"
}
issue_letsencrypt() {
    dns_ready || { echo "DNS A-запись $STUB_DOMAIN не указывает на $SERVER_IP" >&2; return 1; }
    port80_free || { echo "TCP/80 занят; standalone HTTP-01 невозможен" >&2; return 1; }
    args=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring --preferred-challenges http --cert-name "$STUB_DOMAIN" -d "$STUB_DOMAIN")
    if [[ -n "$STUB_EMAIL" ]]; then args+=(--email "$STUB_EMAIL"); else args+=(--register-unsafely-without-email); fi
    with_http_rule certbot "${args[@]}" || return 1
    ln -sfn "/etc/letsencrypt/live/$STUB_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
    ln -sfn "/etc/letsencrypt/live/$STUB_DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
    save_type letsencrypt
    docker kill -s HUP telemt-stub >/dev/null 2>&1 || true
}
case "${1:-provision}" in
  provision) issue_letsencrypt || self_signed ;;
  renew)
    if [[ "$STUB_CERT_TYPE" == letsencrypt ]]; then
      port80_free && with_http_rule certbot renew --cert-name "$STUB_DOMAIN" --quiet --deploy-hook 'docker kill -s HUP telemt-stub' || true
    else
      issue_letsencrypt || openssl x509 -checkend 604800 -noout -in "$CERT_DIR/fullchain.pem" >/dev/null || self_signed
    fi
    ;;
  letsencrypt) issue_letsencrypt ;;
  selfsigned) self_signed; docker kill -s HUP telemt-stub >/dev/null 2>&1 || true ;;
  *) echo "Usage: stub-cert.sh {provision|renew|letsencrypt|selfsigned}"; exit 2 ;;
esac
CERTSCRIPT
    chmod 700 "$INSTALL_ROOT/bin/stub-cert.sh"
    "$INSTALL_ROOT/bin/stub-cert.sh" provision
    STUB_CERT_TYPE=$(awk -F= '/^STUB_CERT_TYPE=/{print $2}' "$CONFIG_DIR/installer.env")

    STUB_TAG_IMAGE=nginx:stable-alpine
    docker pull "$STUB_TAG_IMAGE"
    STUB_IMAGE=$(docker image inspect "$STUB_TAG_IMAGE" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk 'index($0,"nginx@") == 1 {print; exit}')
    [[ -n "$STUB_IMAGE" ]] || die "Не удалось зафиксировать digest Nginx"
    printf 'STUB_IMAGE=%s\n' "$STUB_IMAGE" >> "$INSTALL_ROOT/.env"
    printf 'COMPOSE_PROFILES=stub\n' >> "$INSTALL_ROOT/.env"
    STUB_CAP_ADD=""
    if [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then STUB_CAP_ADD='    cap_add: ["NET_BIND_SERVICE"]'; fi
    cat >> "$INSTALL_ROOT/docker-compose.yml" <<EOF
  stub:
    profiles: ["stub"]
    image: \${STUB_IMAGE}
    container_name: telemt-stub
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/telemt/config/stub/nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/telemt/config/stub:/etc/nginx/stub:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /opt/telemt/stub/html:/usr/share/nginx/html:ro
    read_only: true
    tmpfs:
      - "/tmp:rw,noexec,nosuid,size=16m"
${STUB_CAP_ADD}
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD-SHELL", "wget --no-check-certificate -qO- https://127.0.0.1:${STUB_PORT}/ >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF
    cat > /etc/systemd/system/telemt-stub-cert.service <<'UNIT'
[Unit]
Description=Renew or upgrade Telemt stub TLS certificate
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/telemt/bin/stub-cert.sh renew
UNIT
    cat > /etc/systemd/system/telemt-stub-cert.timer <<'UNIT'
[Unit]
Description=Daily Telemt stub certificate check
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now telemt-stub-cert.timer >/dev/null
    ok "HTML5-заглушка подготовлена; сертификат: $STUB_CERT_TYPE"
    ok "Для замены по SFTP: $STUB_OWNER → $STUB_ROOT/index.html"
fi

step "Firewall и GeoBlock"
cat > "$INSTALL_ROOT/bin/firewall.sh" <<'FIREWALL'
#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/telemt/config/installer.env
STUB_PUBLIC_HTTPS=${STUB_PUBLIC_HTTPS:-false}
GEOBLOCK_PAUSE_FILE=/run/telemt-geoblock.paused
remove_chain() {
    local cmd=$1 chain=$2
    command -v "$cmd" >/dev/null 2>&1 || return 0
    "$cmd" -D INPUT -j "$chain" 2>/dev/null || true
    "$cmd" -F "$chain" 2>/dev/null || true
    "$cmd" -X "$chain" 2>/dev/null || true
}
if [[ "${1:-}" == remove ]]; then
    remove_chain iptables TELEMT_GUARD4
    remove_chain ip6tables TELEMT_GUARD6
    ipset destroy telemt_geo4 2>/dev/null || true
    ipset destroy telemt_geo6 2>/dev/null || true
    exit 0
fi
# Удаляем цепочки предыдущих версий установщика после безопасной миграции.
remove_chain iptables TELEMT_GEO
remove_chain iptables TELEMT_PORT
ipset destroy telemt_geo_block 2>/dev/null || true
ipset create telemt_geo4 hash:net family inet hashsize 4096 maxelem 1048576 -exist
[[ "$IPV6_MODE" != disabled ]] && ipset create telemt_geo6 hash:net family inet6 hashsize 4096 maxelem 1048576 -exist

apply_family() {
    local cmd=$1 chain=$2 setname=$3 family=$4
    local -a admin_exclude=()
    "$cmd" -N "$chain" 2>/dev/null || true
    "$cmd" -C INPUT -j "$chain" 2>/dev/null || "$cmd" -I INPUT 1 -j "$chain"
    "$cmd" -F "$chain"
    for ssh_port in $SSH_PORTS; do "$cmd" -A "$chain" -p tcp --dport "$ssh_port" -j RETURN; done
    if [[ -n "$ADMIN_IP" && "$ADMIN_IP" == *.* && "$family" == 4 ]]; then admin_exclude=(! -s "$ADMIN_IP"); fi
    if [[ -n "$ADMIN_IP" && "$ADMIN_IP" == *:* && "$family" == 6 ]]; then admin_exclude=(! -s "$ADMIN_IP"); fi
    # Точный IP мониторинга разрешается до GeoBlock, иначе scope=all мог бы
    # отрезать Grafana, находящуюся в выбранном для блокировки регионе.
    if [[ "$family" == 4 && "$METRICS_REMOTE" == true ]]; then
        [[ "$METRICS_ENABLE" == true ]] && "$cmd" -A "$chain" -p tcp -s "$GRAFANA_IP" --dport "$METRICS_PORT" -j ACCEPT
        [[ "$GEO_ENABLE" == true ]] && "$cmd" -A "$chain" -p tcp -s "$GRAFANA_IP" --dport "$GEO_METRICS_PORT" -j ACCEPT
        [[ "$NODE_EXPORTER_ENABLE" == true ]] && "$cmd" -A "$chain" -p tcp -s "$GRAFANA_IP" --dport "$NODE_EXPORTER_PORT" -j ACCEPT
    fi
    if [[ ! -e "$GEOBLOCK_PAUSE_FILE" && -n "$GEO_COUNTRIES" && ( "$family" == 4 || "$IPV6_MODE" == filtered ) ]]; then
        if [[ "$GEO_SCOPE" == all ]]; then
            "$cmd" -A "$chain" "${admin_exclude[@]}" -m set --match-set "$setname" src -j DROP
        else
            "$cmd" -A "$chain" -p tcp --dport "$PORT" "${admin_exclude[@]}" -m set --match-set "$setname" src -j DROP
        fi
    fi
    "$cmd" -A "$chain" -p tcp --dport "$PORT" -j ACCEPT
    if [[ "$family" == 4 && "$STUB_ENABLE" == true && "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then "$cmd" -A "$chain" -p tcp --dport 443 -j ACCEPT; fi
    if [[ "$family" == 4 && "$METRICS_ENABLE" == true && "$METRICS_REMOTE" == true ]]; then
        "$cmd" -A "$chain" -p tcp --dport "$METRICS_PORT" -j DROP
    fi
    if [[ "$family" == 4 && "$GEO_ENABLE" == true && "$METRICS_REMOTE" == true ]]; then
        "$cmd" -A "$chain" -p tcp --dport "$GEO_METRICS_PORT" -j DROP
    fi
    if [[ "$family" == 4 && "$NODE_EXPORTER_ENABLE" == true && "$METRICS_REMOTE" == true ]]; then
        "$cmd" -A "$chain" -p tcp --dport "$NODE_EXPORTER_PORT" -j DROP
    fi
    "$cmd" -A "$chain" -j RETURN
}
apply_family iptables TELEMT_GUARD4 telemt_geo4 4
if [[ "$IPV6_MODE" != disabled ]]; then apply_family ip6tables TELEMT_GUARD6 telemt_geo6 6; else remove_chain ip6tables TELEMT_GUARD6; fi
FIREWALL
chmod 700 "$INSTALL_ROOT/bin/firewall.sh"

cat > "$INSTALL_ROOT/bin/geoblock-resume.sh" <<'RESUMEGEO'
#!/usr/bin/env bash
set -Eeuo pipefail
PAUSE_FILE=/run/telemt-geoblock.paused
[[ -e "$PAUSE_FILE" ]] && unlink "$PAUSE_FILE"
/opt/telemt/bin/firewall.sh apply
echo "GeoBlock regional rules resumed automatically"
RESUMEGEO
chmod 700 "$INSTALL_ROOT/bin/geoblock-resume.sh"

cat > "$INSTALL_ROOT/bin/geoblock-update.sh" <<'GEOUPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/telemt/config/installer.env
[[ -n "$GEO_COUNTRIES" ]] || exit 0
WORK_DIR=$(mktemp -d)
NEW4="telemt_new4_$$"; NEW6="telemt_new6_$$"; COUNT6=""; FAILED=""; SKIPPED=""
cleanup() {
    ipset destroy "$NEW4" 2>/dev/null || true
    ipset destroy "$NEW6" 2>/dev/null || true
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" && "$WORK_DIR" == /tmp/* ]] && rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
ipset create "$NEW4" hash:net family inet hashsize 4096 maxelem 1048576
[[ "$IPV6_MODE" == filtered ]] && ipset create "$NEW6" hash:net family inet6 hashsize 4096 maxelem 1048576
for country in $GEO_COUNTRIES; do
    file4="$WORK_DIR/${country}4.zone"
    if ! HTTP4=$(curl -sSL --retry 5 --retry-delay 2 --connect-timeout 10 --max-time 120 -w '%{http_code}' "https://www.ipdeny.com/ipblocks/data/aggregated/${country}-aggregated.zone" -o "$file4"); then HTTP4=000; fi
    if [[ "$HTTP4" == 404 ]]; then echo "GeoBlock: no IPv4 allocation list for $country; skipped" >&2; SKIPPED+=" $country/4"; continue; fi
    if [[ "$HTTP4" != 200 ]]; then echo "GeoBlock: IPv4 download failed for $country (HTTP $HTTP4)" >&2; FAILED+=" $country/4"; continue; fi
    if ! grep -Eq '^[0-9.]+/[0-9]+$' "$file4"; then echo "GeoBlock: invalid IPv4 list for $country" >&2; FAILED+=" $country/4"; continue; fi
    while IFS= read -r net; do [[ "$net" =~ ^[0-9.]+/[0-9]+$ ]] && ipset add "$NEW4" "$net" -exist; done < "$file4"
    if [[ "$IPV6_MODE" == filtered ]]; then
        file6="$WORK_DIR/${country}6.zone"
        if ! HTTP6=$(curl -sSL --retry 5 --retry-delay 2 --connect-timeout 10 --max-time 120 -w '%{http_code}' "https://www.ipdeny.com/ipv6/ipaddresses/aggregated/${country}-aggregated.zone" -o "$file6"); then HTTP6=000; fi
        if [[ "$HTTP6" == 404 ]]; then echo "GeoBlock: no IPv6 allocation list for $country; skipped" >&2; SKIPPED+=" $country/6"; continue; fi
        if [[ "$HTTP6" != 200 ]]; then echo "GeoBlock: IPv6 download failed for $country (HTTP $HTTP6)" >&2; FAILED+=" $country/6"; continue; fi
        if ! grep -Eq '^[0-9A-Fa-f:]+/[0-9]+$' "$file6"; then echo "GeoBlock: invalid IPv6 list for $country" >&2; FAILED+=" $country/6"; continue; fi
        while IFS= read -r net; do [[ "$net" =~ ^[0-9A-Fa-f:]+/[0-9]+$ ]] && ipset add "$NEW6" "$net" -exist; done < "$file6"
    fi
done
if [[ -n "$FAILED" ]]; then
    echo "GeoBlock update incomplete; active sets were preserved. Failed:${FAILED}" >&2
    exit 1
fi
COUNT4=$(ipset list "$NEW4" | awk '/Number of entries:/ {print $4}')
(( COUNT4 >= 1 )) || { echo "Empty IPv4 set" >&2; exit 1; }
if [[ "$IPV6_MODE" == filtered ]]; then
    COUNT6=$(ipset list "$NEW6" | awk '/Number of entries:/ {print $4}')
    (( COUNT6 >= 1 )) || { echo "Empty IPv6 set" >&2; exit 1; }
fi
ipset create telemt_geo4 hash:net family inet hashsize 4096 maxelem 1048576 -exist
ipset swap "$NEW4" telemt_geo4
if [[ "$IPV6_MODE" == filtered ]]; then
    ipset create telemt_geo6 hash:net family inet6 hashsize 4096 maxelem 1048576 -exist
    ipset swap "$NEW6" telemt_geo6
fi
/opt/telemt/bin/firewall.sh
echo "GeoBlock updated atomically: IPv4=$COUNT4${COUNT6:+ IPv6=$COUNT6}"
[[ -z "$SKIPPED" ]] || echo "GeoBlock lists without allocations skipped:${SKIPPED}"
GEOUPDATE
chmod 700 "$INSTALL_ROOT/bin/geoblock-update.sh"

cat > /etc/systemd/system/telemt-firewall.service <<'UNIT'
[Unit]
Description=Telemt firewall rules
After=network-online.target docker.service firewalld.service ufw.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/telemt/bin/firewall.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/telemt-geoblock.service <<'UNIT'
[Unit]
Description=Atomic Telemt GeoBlock database update
After=network-online.target telemt-firewall.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/telemt/bin/geoblock-update.sh
TimeoutStartSec=30min
UNIT
cat > /etc/systemd/system/telemt-geoblock.timer <<'UNIT'
[Unit]
Description=Daily Telemt GeoBlock database update
[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/telemt-geoblock-resume.service <<'UNIT'
[Unit]
Description=Resume Telemt regional GeoBlock rules
[Service]
Type=oneshot
ExecStart=/opt/telemt/bin/geoblock-resume.sh
UNIT
cat > /etc/systemd/system/telemt-geoblock-resume.timer <<'UNIT'
[Unit]
Description=Resume Telemt regional GeoBlock rules after five minutes
[Timer]
OnActiveSec=5min
AccuracySec=1s
Unit=telemt-geoblock-resume.service
UNIT
systemctl daemon-reload
systemctl enable telemt-firewall.service >/dev/null
systemctl restart telemt-firewall.service
GEOBLOCK_STATUS=disabled
if [[ -n "$SELECTED_CODES" ]]; then
    if systemctl start telemt-geoblock.service; then
        GEOBLOCK_STATUS=active
        ok "GeoBlock применён атомарно: $SELECTED_NAMES"
    else
        GEOBLOCK_STATUS=deferred
        warn "GeoBlock пока не обновлён; прежний набор сохранён, таймер повторит загрузку автоматически"
        journalctl -u telemt-geoblock.service -n 8 --no-pager || true
    fi
    systemctl enable --now telemt-geoblock.timer >/dev/null
else
    systemctl disable --now telemt-geoblock.timer >/dev/null 2>&1 || true
fi
ok "TCP/$PORT открыт; SSH ${SSH_PORTS} исключены из региональной блокировки"

step "Fail2ban"
if [[ "$FAIL2BAN_ENABLE" == true ]]; then
    if [[ "$PKG_FAMILY" == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
    else dnf install -y epel-release >/dev/null 2>&1 || true; dnf install -y fail2ban >/dev/null; fi
    cat > /etc/fail2ban/jail.d/telemt-sshd.conf <<EOF
[sshd]
enabled = true
port = $(tr ' ' ',' <<< "$SSH_PORTS" | sed 's/,$//')
backend = auto
findtime = 10m
maxretry = 5
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
EOF
    fail2ban-client -t >/dev/null 2>&1 || { fail2ban-client -t; die "Конфигурация Fail2ban содержит ошибку"; }
    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban
    FAIL2BAN_READY=false
    for _ in {1..20}; do
        if fail2ban-client ping >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then FAIL2BAN_READY=true; break; fi
        sleep 1
    done
    if [[ "$FAIL2BAN_READY" != true ]]; then
        systemctl status fail2ban --no-pager -l || true
        journalctl -u fail2ban -n 30 --no-pager || true
        die "Fail2ban не создал управляющий сокет или jail sshd не запустился"
    fi
    ok "Fail2ban проверен, jail sshd активен"
fi

step "GeoIP Exporter"
if [[ "$GEO_ENABLE" == true ]]; then
    mkdir -p "$INSTALL_ROOT/geo-exporter/data"
    chmod 700 "$INSTALL_ROOT/geo-exporter" "$INSTALL_ROOT/geo-exporter/data"
    chown 65534:65534 "$INSTALL_ROOT/geo-exporter/data"
    cat > "$INSTALL_ROOT/geo-exporter/exporter.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys, threading, time, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
import geoip2.database
API=os.getenv("TELEMT_API","http://127.0.0.1:9091"); PORT=int(os.getenv("LISTEN_PORT","9095")); ADDR=os.getenv("LISTEN_ADDR","127.0.0.1")
DB="/data/GeoLite2-City.mmdb"; metrics=""; lock=threading.Lock(); reader=None
def database():
    if os.path.exists(DB) and os.path.getsize(DB)>1000000: return
    tmp=DB+".tmp"; req=urllib.request.Request("https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb",headers={"User-Agent":"telemt-geo/2"})
    with urllib.request.urlopen(req,timeout=90) as src, open(tmp,"wb") as dst:
        while chunk:=src.read(65536): dst.write(chunk)
    if os.path.getsize(tmp)<1000000: raise RuntimeError("GeoLite database too small")
    os.replace(tmp,DB)
def build():
    try: data=json.loads(urllib.request.urlopen(API+"/v1/users",timeout=10).read()).get("data",[])
    except Exception as e: print("API:",e,file=sys.stderr,flush=True); return ""
    rows=[]; countries={}; total=0
    for user in data:
        for ip in user.get("active_unique_ips_list",[]):
            try:
                g=reader.city(ip); cc=g.country.iso_code or "XX"; country=(g.country.name or "Unknown").replace('"',''); city=(g.city.name or "Unknown").replace('"','')
                rows.append(f'telemt_geo_client{{user="{user.get("username","?")}",country="{country}",country_code="{cc}",city="{city}",latitude="{g.location.latitude or 0}",longitude="{g.location.longitude or 0}"}} 1')
                countries[cc]=countries.get(cc,[country,0]); countries[cc][1]+=1; total+=1
            except Exception: pass
    out=["# TYPE telemt_geo_client gauge",*rows,"# TYPE telemt_geo_country_clients gauge"]
    out += [f'telemt_geo_country_clients{{country="{v[0]}",country_code="{k}"}} {v[1]}' for k,v in sorted(countries.items())]
    out += ["# TYPE telemt_geo_resolved gauge",f"telemt_geo_resolved {total}"]
    return "\n".join(out)+"\n"
def poll():
    global metrics
    while True:
        new=build()
        if new:
            with lock: metrics=new
        time.sleep(30)
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path!="/metrics": self.send_response(404); self.end_headers(); return
        with lock: body=metrics.encode()
        self.send_response(200); self.send_header("Content-Type","text/plain"); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass
database(); reader=geoip2.database.Reader(DB); threading.Thread(target=poll,daemon=True).start(); HTTPServer((ADDR,PORT),Handler).serve_forever()
PY
    cat > "$INSTALL_ROOT/geo-exporter/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-slim
RUN pip install --no-cache-dir geoip2
WORKDIR /app
COPY exporter.py /app/exporter.py
USER 65534:65534
ENTRYPOINT ["python3","-u","/app/exporter.py"]
DOCKERFILE
    chmod 755 "$INSTALL_ROOT/geo-exporter/exporter.py"
    docker build -t telemt-geo-exporter:2 "$INSTALL_ROOT/geo-exporter"
    GEO_LISTEN=127.0.0.1; [[ "$METRICS_REMOTE" == true ]] && GEO_LISTEN=0.0.0.0
    cat >> "$INSTALL_ROOT/docker-compose.yml" <<EOF
  geo-exporter:
    image: telemt-geo-exporter:2
    container_name: geo-exporter
    restart: unless-stopped
    network_mode: host
    depends_on: [telemt]
    environment:
      TELEMT_API: http://127.0.0.1:9091
      LISTEN_ADDR: ${GEO_LISTEN}
      LISTEN_PORT: ${GEO_METRICS_PORT}
    volumes:
      - /opt/telemt/geo-exporter/data:/data:rw
    read_only: true
    tmpfs:
      - "/tmp:rw,noexec,nosuid,size=8m"
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
EOF
    chmod 600 "$INSTALL_ROOT/docker-compose.yml"
fi

step "Node Exporter"
if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then
    NODE_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    NODE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_ARCHIVE}"
    NODE_SUMS_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/sha256sums.txt"
    NODE_TMP=$(mktemp -d)
    info "Загружаю официальный node_exporter v${NODE_EXPORTER_VERSION}..."
    wget -q --show-progress --https-only -O "$NODE_TMP/$NODE_ARCHIVE" "$NODE_URL"
    wget -q --https-only -O "$NODE_TMP/sha256sums.txt" "$NODE_SUMS_URL"
    OFFICIAL_NODE_SHA256=$(awk -v file="$NODE_ARCHIVE" '$2 == file {print $1; exit}' "$NODE_TMP/sha256sums.txt")
    [[ "$OFFICIAL_NODE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "В официальном sha256sums.txt отсутствует $NODE_ARCHIVE"
    [[ "$OFFICIAL_NODE_SHA256" == "$NODE_EXPORTER_SHA256" ]] || die "Официальная SHA-256 изменилась: ожидалась $NODE_EXPORTER_SHA256, опубликована $OFFICIAL_NODE_SHA256"
    ACTUAL_NODE_SHA256=$(sha256sum "$NODE_TMP/$NODE_ARCHIVE" | awk '{print $1}')
    if [[ "$ACTUAL_NODE_SHA256" != "$OFFICIAL_NODE_SHA256" ]]; then
        warn "Ожидалась SHA-256: $OFFICIAL_NODE_SHA256"
        warn "Получена SHA-256:  $ACTUAL_NODE_SHA256"
        die "SHA-256 архива node_exporter не совпадает; файл не будет установлен"
    fi
    ok "SHA-256 node_exporter подтверждена официальным sha256sums.txt"
    tar -xzf "$NODE_TMP/$NODE_ARCHIVE" -C "$NODE_TMP"
    mkdir -p "$INSTALL_ROOT/node-exporter"
    install -m 0755 "$NODE_TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "$INSTALL_ROOT/node-exporter/node_exporter"
    rm -rf -- "$NODE_TMP"
    NODE_LISTEN=127.0.0.1; [[ "$METRICS_REMOTE" == true ]] && NODE_LISTEN=0.0.0.0
    cat > /etc/systemd/system/telemt-node-exporter.service <<EOF
[Unit]
Description=Telemt Node Exporter v${NODE_EXPORTER_VERSION}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${INSTALL_ROOT}/node-exporter/node_exporter --web.listen-address=${NODE_LISTEN}:${NODE_EXPORTER_PORT} --web.telemetry-path=/metrics
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/telemt-node-exporter.service
    systemctl daemon-reload
    systemctl enable --now telemt-node-exporter.service >/dev/null
    NODE_READY=false
    for _ in {1..20}; do
        if curl -fsS "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" | grep -q '^node_uname_info'; then NODE_READY=true; break; fi
        sleep 1
    done
    if [[ "$NODE_READY" != true ]]; then
        systemctl status telemt-node-exporter.service --no-pager -l || true
        journalctl -u telemt-node-exporter.service -n 30 --no-pager || true
        die "node_exporter не прошёл проверку /metrics"
    fi
    ok "node_exporter v${NODE_EXPORTER_VERSION} активен на ${NODE_LISTEN}:${NODE_EXPORTER_PORT}"
else
    systemctl disable --now telemt-node-exporter.service >/dev/null 2>&1 || true
    [[ -e /etc/systemd/system/telemt-node-exporter.service ]] && unlink /etc/systemd/system/telemt-node-exporter.service
    [[ -d "$INSTALL_ROOT/node-exporter" ]] && rm -rf -- "$INSTALL_ROOT/node-exporter"
    systemctl daemon-reload
fi

step "Команды управления"
cat > "$INSTALL_ROOT/bin/mtproto" <<'MANAGE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=/opt/telemt; CONFIG=/opt/telemt/config/config.toml; COMPOSE=(docker compose --env-file "$ROOT/.env" -f "$ROOT/docker-compose.yml")
. /opt/telemt/config/installer.env
STUB_PUBLIC_HTTPS=${STUB_PUBLIC_HTTPS:-false}
NODE_EXPORTER_ENABLE=${NODE_EXPORTER_ENABLE:-false}
NODE_EXPORTER_VERSION=${NODE_EXPORTER_VERSION:-1.5.0}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT:-9100}
TLS_DOMAIN=${TLS_DOMAIN:-не задан}
INSTALLER_VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)
api() { curl -fsS "http://127.0.0.1:9091/v1/${1}"; }
raw_links() { api users | jq -r '.data[] | (.links.classic[]? // empty), (.links.secure[]? // empty), (.links.tls[]? // empty), (.links.tls_domains[]?.link? // empty)'; }
telegram_links() {
    local link query secret mode key
    declare -A seen=()
    while IFS= read -r link; do
        case "$link" in tg://proxy\?*|https://t.me/proxy\?*|https://telegram.me/proxy\?*) ;; *) continue ;; esac
        query=${link#*\?}; [[ -n "$query" ]] || continue
        [[ -z "${seen[$query]:-}" ]] || continue; seen[$query]=1
        secret=$(sed -n 's/.*[?&]secret=\([^&]*\).*/\1/p' <<< "?$query")
        case "$secret" in dd*) mode=DD;; ee*) mode=EE;; *) mode=MTProto;; esac
        printf '[%s] tg://proxy?%s\n' "$mode" "$query"
        printf '[%s] https://t.me/proxy?%s\n' "$mode" "$query"
    done < <(raw_links)
}
wait_healthy() {
    local i status
    for i in {1..30}; do status=$(docker inspect -f '{{.State.Health.Status}}' telemt 2>/dev/null || true); [[ "$status" == healthy ]] && return 0; sleep 2; done
    return 1
}
backup() {
    local out=${1:-$ROOT/backups/telemt-$(date +%Y%m%d-%H%M%S).tar.gz}
    local -a items=(opt/telemt/config opt/telemt/.env opt/telemt/docker-compose.yml opt/telemt/bin opt/telemt/install.sh opt/telemt/update.sh opt/telemt/uninstall.sh opt/telemt/doctor.sh opt/telemt/backup.sh opt/telemt/VERSION)
    [[ -f /opt/telemt/INSTALLATION-SUMMARY.txt ]] && items+=(opt/telemt/INSTALLATION-SUMMARY.txt)
    local doc
    for doc in opt/telemt/README.md opt/telemt/LICENSE opt/telemt/CHANGELOG.md; do [[ -f "/$doc" ]] && items+=("$doc"); done
    [[ -d /opt/telemt/stub ]] && items+=(opt/telemt/stub)
    [[ -d /opt/telemt/node-exporter ]] && items+=(opt/telemt/node-exporter)
    local unit
    for unit in etc/systemd/system/telemt-firewall.service etc/systemd/system/telemt-geoblock.service etc/systemd/system/telemt-geoblock.timer etc/systemd/system/telemt-geoblock-resume.service etc/systemd/system/telemt-geoblock-resume.timer etc/systemd/system/telemt-stub-cert.service etc/systemd/system/telemt-stub-cert.timer etc/systemd/system/telemt-node-exporter.service; do [[ -f "/$unit" ]] && items+=("$unit"); done
    mkdir -p "$ROOT/backups"; tar -czf "$out" -C / "${items[@]}"; chmod 600 "$out"; echo "$out"
}
valid_backup() {
    local archive=$1 entry found=false
    while IFS= read -r entry; do
        [[ "$entry" == /* || "$entry" == *".."* ]] && return 1
        case "$entry" in
            opt/telemt/config|opt/telemt/config/*|opt/telemt/.env|opt/telemt/docker-compose.yml|opt/telemt/bin|opt/telemt/bin/*|opt/telemt/node-exporter|opt/telemt/node-exporter/*|opt/telemt/install.sh|opt/telemt/update.sh|opt/telemt/uninstall.sh|opt/telemt/doctor.sh|opt/telemt/backup.sh|opt/telemt/VERSION|opt/telemt/INSTALLATION-SUMMARY.txt|opt/telemt/README.md|opt/telemt/LICENSE|opt/telemt/CHANGELOG.md|opt/telemt/stub|opt/telemt/stub/*|etc/systemd/system/telemt-firewall.service|etc/systemd/system/telemt-geoblock.service|etc/systemd/system/telemt-geoblock.timer|etc/systemd/system/telemt-geoblock-resume.service|etc/systemd/system/telemt-geoblock-resume.timer|etc/systemd/system/telemt-stub-cert.service|etc/systemd/system/telemt-stub-cert.timer|etc/systemd/system/telemt-node-exporter.service) found=true ;;
            *) return 1 ;;
        esac
    done < <(tar -tzf "$archive")
    [[ "$found" == true ]]
}
show_help() {
    cat <<'HELP'
Telemt Installer — команды управления

Подключение и данные:
  mtproto credentials          Полная памятка: ключи, ссылки, сайт, метрики и порты
  mtproto secrets              Алиас команды credentials
  mtproto links                DD/EE ссылки tg://proxy и https://t.me/proxy
  mtproto links-raw            Исходные ссылки из API Telemt
  mtproto sponsor              Проверка локальной настройки Proxy Sponsor

Состояние и диагностика:
  mtproto status               Состояние контейнеров
  mtproto doctor               Полная автоматическая диагностика
  mtproto ports                Порты, сокеты и правила firewall
  mtproto logs [N]             Последние N строк журнала Telemt
  mtproto client-debug [сек]   Живой журнал попытки подключения, 10–600 сек.
  mtproto stats                Статистика Telemt
  mtproto users                Пользователи через локальный API

GeoBlock и firewall:
  mtproto geoblock status      Состояние региональной блокировки
  mtproto geoblock pause       Отключить только GeoBlock ровно на 5 минут
  mtproto geoblock resume      Включить GeoBlock немедленно
  mtproto firewall             Показать цепочки firewall и число сетей

Сервис:
  mtproto start|stop|restart   Управление контейнерами
  mtproto backup [FILE]        Создать резервную копию
  mtproto restore FILE         Восстановить проверенную резервную копию
  mtproto update [VERSION]     Обновить Telemt с автоматическим откатом
  mtproto stub ...             Управление HTTPS-заглушкой
  mtproto uninstall            Полностью удалить установленный стек и файлы
  mtproto help                 Показать эту справку

Важно: GeoBlock pause не отключает SSH-защиту, правила портов или Fail2ban.
HELP
}
case "${1:-}" in
  help|-h|--help|"") show_help ;;
  version) echo "Telemt Installer v$INSTALLER_VERSION" ;;
  start) "${COMPOSE[@]}" up -d; if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then systemctl start telemt-node-exporter.service; fi ;;
  stop) "${COMPOSE[@]}" stop; if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then systemctl stop telemt-node-exporter.service; fi ;;
  restart) "${COMPOSE[@]}" up -d --force-recreate; if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then systemctl restart telemt-node-exporter.service; fi; wait_healthy ;;
  status) "${COMPOSE[@]}" ps; if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then systemctl status telemt-node-exporter.service --no-pager -l; fi ;;
  logs) "${COMPOSE[@]}" logs --tail "${2:-100}" telemt ;;
  link|links) telegram_links ;;
  links-raw) raw_links ;;
  credentials|secrets)
    secret=$(awk '/^\[access.users\]/{inside=1;next} /^\[/{inside=0} inside && /^proxy[[:space:]]*=/{gsub(/[[:space:]\"]/,"",$0); sub(/^proxy=/,""); print; exit}' "$CONFIG")
    adtag=$(awk '/^\[access.user_ad_tags\]/{inside=1;next} /^\[/{inside=0} inside && /^proxy[[:space:]]*=/{gsub(/[[:space:]\"]/,"",$0); sub(/^proxy=/,""); print; exit}' "$CONFIG")
    telemt_version=$(awk -F= '$1=="TELEMT_VERSION"{print $2; exit}' "$ROOT/.env")
    secure_mode=$(awk '/^\[general.modes\]/{inside=1;next} /^\[/{inside=0} inside && /^secure[[:space:]]*=/{gsub(/[[:space:]]/,"",$0); sub(/^secure=/,""); print; exit}' "$CONFIG")
    tls_mode=$(awk '/^\[general.modes\]/{inside=1;next} /^\[/{inside=0} inside && /^tls[[:space:]]*=/{gsub(/[[:space:]]/,"",$0); sub(/^tls=/,""); print; exit}' "$CONFIG")
    site_url=""; site_telemt_url=""
    if [[ "$STUB_ENABLE" == true ]]; then
      if [[ "$STUB_PUBLIC_HTTPS" == true ]]; then site_url="https://${STUB_DOMAIN}/"; else site_url="https://${STUB_DOMAIN}:${PORT}/"; fi
      [[ "$PORT" == 443 ]] || site_telemt_url="https://${STUB_DOMAIN}:${PORT}/"
    fi
    endpoint_host=127.0.0.1; [[ "$METRICS_REMOTE" == true ]] && endpoint_host=${SERVER_IP:-$PUBLIC_HOST}
    echo "== ДАННЫЕ ПОДКЛЮЧЕНИЯ =="
    echo "Telemt: ${telemt_version:-не определена}; Installer: v$INSTALLER_VERSION"
    echo "Сервер: $PUBLIC_HOST"
    echo "Порт Telemt: TCP/$PORT"
    echo "Режимы: DD/secure=$secure_mode; EE/TLS=$tls_mode"
    echo "TLS-домен маскировки: $TLS_DOMAIN"
    echo "Proxy Secret: $secret"
    echo "Ad-tag: ${adtag:-не задан}"
    echo "GeoBlock: $([[ -n "$GEO_COUNTRIES" ]] && echo "активен, scope=$GEO_SCOPE" || echo "выключен")"
    echo "IPv6: $IPV6_MODE; SSH всегда разрешён на TCP: $SSH_PORTS"
    echo
    echo "== ССЫЛКИ ДЛЯ ДОБАВЛЕНИЯ ПРОКСИ В TELEGRAM =="
    telegram_links
    echo
    echo "== САЙТ-ЗАГЛУШКА =="
    if [[ -n "$site_url" ]]; then
      echo "Основной адрес: $site_url"
      [[ -z "$site_telemt_url" || "$site_telemt_url" == "$site_url" ]] || echo "Через порт Telemt: $site_telemt_url"
      echo "HTML по SFTP: /opt/telemt/stub/html/index.html"
      echo "Сертификат: ${STUB_CERT_TYPE:-не определён}"
    else echo "Не установлена"; fi
    echo
    echo "== ДРУГИЕ ПОЛЕЗНЫЕ АДРЕСА =="
    echo "MTProxybot: https://t.me/MTProxybot"
    echo "Локальный API health: http://127.0.0.1:9091/v1/health"
    [[ "$METRICS_ENABLE" == true ]] && echo "Telemt Prometheus: http://${endpoint_host}:${METRICS_PORT}/metrics"
    [[ "$GEO_ENABLE" == true ]] && echo "GeoIP exporter: http://${endpoint_host}:${GEO_METRICS_PORT}/metrics"
    [[ "$NODE_EXPORTER_ENABLE" == true ]] && echo "node_exporter v${NODE_EXPORTER_VERSION}: http://${endpoint_host}:${NODE_EXPORTER_PORT}/metrics"
    if [[ "$METRICS_REMOTE" == true ]]; then echo "Внешние метрики разрешены только с IPv4 $GRAFANA_IP"; else echo "Метрики доступны только с localhost"; fi
    echo
    echo "== ПОРТЫ =="
    echo "TCP/$PORT — Telemt, публичный"
    echo "TCP/9091 — API Telemt, только localhost"
    [[ "$STUB_ENABLE" == true ]] && echo "TCP/$STUB_PORT — Nginx-заглушка, только localhost"
    [[ "$STUB_ENABLE" == true ]] && echo "TCP/80 — ACME/Let's Encrypt, временно при выпуске и продлении"
    [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]] && echo "TCP/443 — публичный сайт без порта"
    [[ "$METRICS_ENABLE" == true ]] && echo "TCP/$METRICS_PORT — Telemt Prometheus"
    [[ "$GEO_ENABLE" == true ]] && echo "TCP/$GEO_METRICS_PORT — GeoIP exporter"
    [[ "$NODE_EXPORTER_ENABLE" == true ]] && echo "TCP/$NODE_EXPORTER_PORT — node_exporter"
    echo
    echo "Команды: mtproto help | links | ports | doctor | status | logs | sponsor | backup"
    ;;
  sponsor)
    middle=$(awk '/^\[general\]/{inside=1;next} /^\[/{inside=0} inside && /^use_middle_proxy[[:space:]]*=/{gsub(/[[:space:]]/,"",$0); sub(/^use_middle_proxy=/,""); print; exit}' "$CONFIG")
    global_tag=$(awk '/^\[general\]/{inside=1;next} /^\[/{inside=0} inside && /^ad_tag[[:space:]]*=/{gsub(/[[:space:]\"]/ ,"",$0); sub(/^ad_tag=/,""); print; exit}' "$CONFIG")
    user_tag=$(awk '/^\[access.user_ad_tags\]/{inside=1;next} /^\[/{inside=0} inside && /^proxy[[:space:]]*=/{gsub(/[[:space:]\"]/ ,"",$0); sub(/^proxy=/,""); print; exit}' "$CONFIG")
    echo "== Локальная проверка Proxy Sponsor =="
    [[ "$middle" == true ]] && echo "OK: use_middle_proxy = true" || echo "FAIL: use_middle_proxy не включён"
    if [[ "$global_tag" =~ ^[0-9a-fA-F]{32}$ ]]; then echo "OK: глобальный ad-tag имеет 32 hex-символа (…${global_tag: -4})"; else echo "FAIL: глобальный ad-tag отсутствует или некорректен"; fi
    if [[ "$user_tag" =~ ^[0-9a-fA-F]{32}$ ]]; then echo "OK: ad-tag пользователя proxy имеет 32 hex-символа (…${user_tag: -4})"; else echo "FAIL: ad-tag пользователя proxy отсутствует или некорректен"; fi
    [[ -n "$global_tag" && "$global_tag" == "$user_tag" ]] && echo "OK: глобальный и пользовательский ad-tag совпадают" || echo "WARN: ad-tag различаются или один отсутствует"
    api health >/dev/null && echo "OK: Telemt API отвечает" || echo "FAIL: Telemt API не отвечает"
    if docker logs --since 30m telemt 2>&1 | grep -Eq 'All ME servers.*failed|middle.proxy.*failed|ME.*failed'; then echo "WARN: в логах есть ошибки Middle Proxy — выполните: mtproto logs 200"; else echo "OK: явных ошибок Middle Proxy за 30 минут не найдено"; fi
    echo
    echo "Проверить регистрацию у Telegram:"
    echo "1. @MTProxybot → /myproxies → выбрать $PUBLIC_HOST:$PORT"
    echo "2. Нажать Set promotion и отправить ссылку на ПУБЛИЧНЫЙ канал"
    echo "3. Подождать до 1 часа"
    echo "4. Проверять с аккаунта, который НЕ подписан на этот канал"
    echo "NOTE: валидность ad-tag на стороне Telegram может подтвердить только @MTProxybot."
    ;;
  client-debug)
    seconds=${2:-120}; [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 10 && "$seconds" -le 600 ]] || { echo "Usage: mtproto client-debug [10..600 seconds]"; exit 2; }
    echo "Удалите старую запись прокси на iPhone, откройте нужную DD/EE-ссылку заново и попробуйте подключиться."
    echo "В течение $seconds секунд ниже будут показаны новые логи Telemt. Ctrl+C завершает раньше."
    set +e; timeout "$seconds" docker logs -f --since 2s telemt; rc=$?; set -e
    [[ "$rc" -eq 0 || "$rc" -eq 124 || "$rc" -eq 130 ]] || exit "$rc"
    echo "Подсказка: отсутствие новых строк означает, что попытка не дошла до Telemt; handshake timeout означает клиент/сеть/DPI; ME errors относятся к соединению Telemt с Telegram."
    ;;
  geoblock)
    case "${2:-status}" in
      pause)
        [[ -n "$GEO_COUNTRIES" ]] || { echo "GeoBlock не настроен — отключать нечего"; exit 0; }
        systemctl stop telemt-geoblock-resume.timer telemt-geoblock-resume.service >/dev/null 2>&1 || true
        systemctl reset-failed telemt-geoblock-resume.service >/dev/null 2>&1 || true
        : > /run/telemt-geoblock.paused
        chmod 600 /run/telemt-geoblock.paused
        /opt/telemt/bin/firewall.sh apply
        systemctl start telemt-geoblock-resume.timer
        echo "GeoBlock временно отключён на 5 минут. SSH, разрешённые порты и Fail2ban продолжают работать."
        systemctl list-timers telemt-geoblock-resume.timer --no-pager
        ;;
      resume)
        systemctl stop telemt-geoblock-resume.timer >/dev/null 2>&1 || true
        /opt/telemt/bin/geoblock-resume.sh
        echo "GeoBlock включён немедленно."
        ;;
      status)
        if [[ ! -n "$GEO_COUNTRIES" ]]; then echo "GeoBlock: не настроен"
        elif [[ -e /run/telemt-geoblock.paused ]]; then echo "GeoBlock: ВРЕМЕННО ОТКЛЮЧЁН"; systemctl list-timers telemt-geoblock-resume.timer --no-pager
        else echo "GeoBlock: активен"; ipset list telemt_geo4 2>/dev/null | awk '/Name:|Number of entries:/'
        fi
        ;;
      *) echo "Usage: mtproto geoblock {status|pause|resume}"; exit 2 ;;
    esac
    ;;
  ports)
    echo "== Configured ports =="
    echo "Telemt public: TCP/$PORT"
    echo "Telemt API: 127.0.0.1:9091"
    [[ "$STUB_ENABLE" == true ]] && { echo "Nginx stub: 127.0.0.1:$STUB_PORT"; echo "Let's Encrypt: public TCP/80 temporarily during issue/renew"; }
    [[ "$STUB_ENABLE" == true && "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]] && echo "Website without port: public TCP/443"
    [[ "$METRICS_ENABLE" == true ]] && echo "Prometheus: $([[ "$METRICS_REMOTE" == true ]] && echo "$GRAFANA_IP → TCP/$METRICS_PORT" || echo "127.0.0.1:$METRICS_PORT")"
    [[ "$GEO_ENABLE" == true ]] && echo "GeoIP: $([[ "$METRICS_REMOTE" == true ]] && echo "$GRAFANA_IP → TCP/$GEO_METRICS_PORT" || echo "127.0.0.1:$GEO_METRICS_PORT")"
    [[ "$NODE_EXPORTER_ENABLE" == true ]] && echo "node_exporter v$NODE_EXPORTER_VERSION: $([[ "$METRICS_REMOTE" == true ]] && echo "$GRAFANA_IP → TCP/$NODE_EXPORTER_PORT" || echo "127.0.0.1:$NODE_EXPORTER_PORT")"
    echo
    echo "== Listening sockets =="
    ss -ltnp | awk -v p1=":$PORT" -v p2=":9091" -v p3=":${STUB_PORT:-0}" -v p4=":${METRICS_PORT:-0}" -v p5=":${GEO_METRICS_PORT:-0}" -v p6=":443" -v p7=":${NODE_EXPORTER_PORT:-0}" 'NR==1 || index($4,p1) || index($4,p2) || index($4,p3) || index($4,p4) || index($4,p5) || index($4,p6) || index($4,p7)'
    echo
    echo "== Installer firewall rules =="
    iptables -S TELEMT_GUARD4 2>/dev/null || echo "TELEMT_GUARD4 is not active"
    ;;
  api) api "${2:-health}" | jq . ;;
  users) api users | jq . ;;
  stats) api stats/summary | jq . ;;
  config) sed -E 's/(proxy = ")[0-9a-f]+/\1***REDACTED***/' "$CONFIG" ;;
  firewall)
    iptables -L TELEMT_GUARD4 -n --line-numbers
    [[ "$IPV6_MODE" != disabled ]] && ip6tables -L TELEMT_GUARD6 -n --line-numbers || true
    ipset list telemt_geo4 | awk '/Name:|Number of entries:/'
    ;;
  stub)
    case "${2:-status}" in
      status)
        [[ "$STUB_ENABLE" == true ]] || { echo "Страница-заглушка выключена"; exit 0; }
        docker ps --filter name=telemt-stub --format 'table {{.Names}}\t{{.Status}}'
        echo | openssl s_client -connect "127.0.0.1:$STUB_PORT" -servername "$STUB_DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates
        echo "Файл: /opt/telemt/stub/html/index.html; владелец: $STUB_OWNER"
        ;;
      check)
        [[ "$STUB_ENABLE" == true ]] || { echo "Страница-заглушка выключена"; exit 1; }
        echo | openssl s_client -connect "127.0.0.1:$STUB_PORT" -servername "$STUB_DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates
        curl -kfsS --resolve "$STUB_DOMAIN:$STUB_PORT:127.0.0.1" "https://$STUB_DOMAIN:$STUB_PORT/" >/dev/null && echo "OK: прямой HTTPS Nginx"
        curl -kfsS --resolve "$STUB_DOMAIN:$PORT:127.0.0.1" "https://$STUB_DOMAIN:$PORT/" >/dev/null && echo "OK: заглушка через Telemt"
        if [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then curl -kfsS --resolve "$STUB_DOMAIN:443:127.0.0.1" "https://$STUB_DOMAIN/" >/dev/null && echo "OK: публичная заглушка HTTPS/443 без порта"; fi
        if [[ "$STUB_CERT_TYPE" == letsencrypt ]]; then curl -fsS --resolve "$STUB_DOMAIN:$STUB_PORT:127.0.0.1" "https://$STUB_DOMAIN:$STUB_PORT/" >/dev/null && echo "OK: цепочка Let's Encrypt валидна"; else echo "WARN: используется self-signed сертификат"; fi
        ;;
      path) echo "/opt/telemt/stub/html/index.html" ;;
      backup) backup "${3:-}" ;;
      renew) /opt/telemt/bin/stub-cert.sh renew; docker kill -s HUP telemt-stub >/dev/null 2>&1 || true ;;
      letsencrypt) /opt/telemt/bin/stub-cert.sh letsencrypt; docker kill -s HUP telemt-stub >/dev/null 2>&1 || true ;;
      selfsigned) /opt/telemt/bin/stub-cert.sh selfsigned ;;
      remove)
        read -rp "Отключить заглушку и убрать mask_host/mask_port? Будет создан backup. [y/N]: " answer
        [[ "$answer" =~ ^[YyДд]$ ]] || exit 0
        archive=$(backup); stamp=$(date +%Y%m%d-%H%M%S); removed="$ROOT/backups/stub-removed-$stamp"; mkdir -p "$removed"
        docker rm -f telemt-stub >/dev/null 2>&1 || true
        systemctl disable --now telemt-stub-cert.timer >/dev/null 2>&1 || true
        for unit in /etc/systemd/system/telemt-stub-cert.service /etc/systemd/system/telemt-stub-cert.timer; do [[ -f "$unit" ]] && unlink "$unit"; done
        systemctl daemon-reload
        [[ -d /opt/telemt/stub ]] && mv /opt/telemt/stub "$removed/site"
        [[ -d /opt/telemt/config/stub ]] && mv /opt/telemt/config/stub "$removed/config"
        sed -i '/^mask_host = /d; /^mask_port = /d' "$CONFIG"
        sed -i 's/^STUB_ENABLE=.*/STUB_ENABLE=false/' /opt/telemt/config/installer.env
        sed -i 's/^STUB_PUBLIC_HTTPS=.*/STUB_PUBLIC_HTTPS=false/' /opt/telemt/config/installer.env
        sed -i '/^COMPOSE_PROFILES=stub$/d' "$ROOT/.env"
        STUB_ENABLE=false; STUB_PUBLIC_HTTPS=false; /opt/telemt/bin/firewall.sh apply
        "${COMPOSE[@]}" up -d --force-recreate telemt; wait_healthy
        echo "Заглушка отключена. Backup: $archive; сохранённые файлы: $removed"
        ;;
      *) echo "Usage: mtproto stub {status|check|path|backup [FILE]|renew|letsencrypt|selfsigned|remove}"; exit 2 ;;
    esac
    ;;
  doctor)
    failures=0
    echo "== Containers =="; "${COMPOSE[@]}" ps
    [[ $(docker inspect -f '{{.State.Health.Status}}' telemt 2>/dev/null) == healthy ]] && echo "OK: Telemt healthy" || { echo "FAIL: Telemt unhealthy"; failures=$((failures+1)); }
    config_owner=$(stat -c '%u:%g' "$CONFIG" 2>/dev/null || echo -1:-1); config_mode=$(stat -c '%a' "$CONFIG" 2>/dev/null || echo 0)
    [[ "$config_owner" == 0:0 && "$config_mode" == 644 ]] && echo "OK: Telemt config permissions (root:root 644 inside protected /opt/telemt)" || { echo "FAIL: config permissions are $config_owner mode=$config_mode; expected root:root 644"; failures=$((failures+1)); }
    docker inspect telemt --format '{{range .Mounts}}{{if eq .Destination "/etc/telemt/config.toml"}}{{.Destination}} rw={{.RW}}{{end}}{{end}}' | grep -q 'rw=false' && echo "OK: config is mounted read-only" || { echo "FAIL: config mount is not read-only"; failures=$((failures+1)); }
    api health >/dev/null && echo "OK: API localhost" || { echo "FAIL: API"; failures=$((failures+1)); }
    generated_links=$(telegram_links 2>/dev/null || true)
    secure_enabled=$(awk '/^\[general.modes\]/{inside=1;next} /^\[/{inside=0} inside && /^secure[[:space:]]*=/{gsub(/[[:space:]]/,"",$0); sub(/^secure=/,""); print; exit}' "$CONFIG")
    tls_enabled=$(awk '/^\[general.modes\]/{inside=1;next} /^\[/{inside=0} inside && /^tls[[:space:]]*=/{gsub(/[[:space:]]/,"",$0); sub(/^tls=/,""); print; exit}' "$CONFIG")
    if [[ "$secure_enabled" == true ]]; then [[ $(grep -c '^\[DD\]' <<< "$generated_links") -eq 2 ]] && echo "OK: API generated tg:// and https:// DD links" || { echo "FAIL: expected two DD links"; failures=$((failures+1)); }; fi
    if [[ "$tls_enabled" == true ]]; then [[ $(grep -c '^\[EE\]' <<< "$generated_links") -eq 2 ]] && echo "OK: API generated tg:// and https:// EE links" || { echo "FAIL: expected two EE links"; failures=$((failures+1)); }; fi
    ss -H -ltn "sport = :$PORT" | grep -q . && echo "OK: TCP/$PORT listening" || { echo "FAIL: port $PORT"; failures=$((failures+1)); }
    if [[ "$METRICS_ENABLE" == true ]]; then curl -fsS "http://127.0.0.1:$METRICS_PORT/metrics" >/dev/null && echo "OK: Prometheus metrics" || { echo "FAIL: metrics"; failures=$((failures+1)); }; fi
    if [[ "$GEO_ENABLE" == true ]]; then curl -fsS "http://127.0.0.1:$GEO_METRICS_PORT/metrics" >/dev/null && echo "OK: GeoIP metrics" || { echo "FAIL: GeoIP exporter"; failures=$((failures+1)); }; fi
    if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then
      systemctl is-active --quiet telemt-node-exporter.service && echo "OK: node_exporter service active" || { echo "FAIL: node_exporter service"; failures=$((failures+1)); }
      curl -fsS "http://127.0.0.1:$NODE_EXPORTER_PORT/metrics" | grep -q '^node_uname_info' && echo "OK: node_exporter metrics" || { echo "FAIL: node_exporter metrics"; failures=$((failures+1)); }
    fi
    if [[ "$STUB_ENABLE" == true ]]; then
      curl -kfsS --resolve "$STUB_DOMAIN:$STUB_PORT:127.0.0.1" "https://$STUB_DOMAIN:$STUB_PORT/" >/dev/null && echo "OK: Nginx stub direct" || { echo "FAIL: Nginx stub"; failures=$((failures+1)); }
      curl -kfsS --resolve "$STUB_DOMAIN:$PORT:127.0.0.1" "https://$STUB_DOMAIN:$PORT/" >/dev/null && echo "OK: stub through Telemt" || { echo "FAIL: mask relay"; failures=$((failures+1)); }
      if [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then curl -kfsS --resolve "$STUB_DOMAIN:443:127.0.0.1" "https://$STUB_DOMAIN/" >/dev/null && echo "OK: public website HTTPS/443" || { echo "FAIL: public website HTTPS/443"; failures=$((failures+1)); }; fi
      openssl x509 -checkend 604800 -noout -in /opt/telemt/config/stub/certs/fullchain.pem >/dev/null && echo "OK: stub certificate lifetime" || echo "WARN: stub certificate expires within 7 days"
    fi
    iptables -C INPUT -j TELEMT_GUARD4 >/dev/null 2>&1 && echo "OK: firewall chain" || { echo "FAIL: firewall chain"; failures=$((failures+1)); }
    iptables -C TELEMT_GUARD4 -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 && echo "OK: firewall allows TCP/$PORT" || { echo "FAIL: firewall does not allow TCP/$PORT"; failures=$((failures+1)); }
    if [[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]]; then iptables -C TELEMT_GUARD4 -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 && echo "OK: firewall allows public HTTPS/443" || { echo "FAIL: firewall does not allow HTTPS/443"; failures=$((failures+1)); }; fi
    if [[ "$METRICS_ENABLE" == true && "$METRICS_REMOTE" == true ]]; then iptables -C TELEMT_GUARD4 -p tcp -s "$GRAFANA_IP" --dport "$METRICS_PORT" -j ACCEPT >/dev/null 2>&1 && echo "OK: metrics allow-list $GRAFANA_IP:$METRICS_PORT" || { echo "FAIL: metrics firewall rule"; failures=$((failures+1)); }; fi
    if [[ "$GEO_ENABLE" == true && "$METRICS_REMOTE" == true ]]; then iptables -C TELEMT_GUARD4 -p tcp -s "$GRAFANA_IP" --dport "$GEO_METRICS_PORT" -j ACCEPT >/dev/null 2>&1 && echo "OK: GeoIP allow-list $GRAFANA_IP:$GEO_METRICS_PORT" || { echo "FAIL: GeoIP firewall rule"; failures=$((failures+1)); }; fi
    if [[ "$NODE_EXPORTER_ENABLE" == true && "$METRICS_REMOTE" == true ]]; then iptables -C TELEMT_GUARD4 -p tcp -s "$GRAFANA_IP" --dport "$NODE_EXPORTER_PORT" -j ACCEPT >/dev/null 2>&1 && echo "OK: node_exporter allow-list $GRAFANA_IP:$NODE_EXPORTER_PORT" || { echo "FAIL: node_exporter firewall rule"; failures=$((failures+1)); }; fi
    if [[ -n "$GEO_COUNTRIES" ]]; then n=$(ipset list telemt_geo4 | awk '/Number of entries:/ {print $4}'); [[ ${n:-0} -gt 0 ]] && echo "OK: GeoBlock IPv4 ($n networks)" || { echo "FAIL: empty GeoBlock"; failures=$((failures+1)); }; fi
    if [[ -n "$GEO_COUNTRIES" && "$IPV6_MODE" == filtered ]]; then n6=$(ipset list telemt_geo6 | awk '/Number of entries:/ {print $4}'); [[ ${n6:-0} -gt 0 ]] && echo "OK: GeoBlock IPv6 ($n6 networks)" || { echo "FAIL: empty IPv6 GeoBlock"; failures=$((failures+1)); }; fi
    if systemctl is-enabled fail2ban >/dev/null 2>&1; then fail2ban-client status sshd >/dev/null && echo "OK: Fail2ban sshd" || { echo "FAIL: Fail2ban"; failures=$((failures+1)); }; fi
    getent ahosts "$PUBLIC_HOST" >/dev/null 2>&1 && echo "OK: DNS/host resolves" || echo "WARN: host does not resolve"
    echo "NOTE: проверьте TCP/$PORT извне и в Security Group провайдера."
    exit "$failures"
    ;;
  backup) backup "${2:-}" ;;
  restore)
    [[ -n "${2:-}" && -f "$2" ]] || { echo "Usage: mtproto restore BACKUP.tar.gz"; exit 2; }
    valid_backup "$2" || { echo "Invalid or unsafe backup"; exit 1; }
    backup >/dev/null; tar -xzf "$2" -C /; . /opt/telemt/config/installer.env
    chown root:root /opt/telemt/config/config.toml; chmod 644 /opt/telemt/config/config.toml
    chmod 600 "$ROOT/.env" "$ROOT/docker-compose.yml"; chmod 700 "$ROOT/bin" "$ROOT/bin/"*
    systemctl daemon-reload; systemctl enable telemt-firewall.service >/dev/null 2>&1 || true
    [[ -n "$GEO_COUNTRIES" ]] && systemctl enable --now telemt-geoblock.timer >/dev/null 2>&1 || true
    [[ "$NODE_EXPORTER_ENABLE" == true ]] && systemctl enable --now telemt-node-exporter.service >/dev/null 2>&1 || true
    if [[ "$STUB_ENABLE" == true ]]; then chown "$STUB_OWNER:$(id -gn "$STUB_OWNER")" /opt/telemt/stub/html /opt/telemt/stub/html/index.html; /opt/telemt/bin/stub-cert.sh provision; systemctl enable --now telemt-stub-cert.timer >/dev/null 2>&1 || true; fi
    "${COMPOSE[@]}" up -d --force-recreate; wait_healthy
    ;;
  update)
    version=${2:-latest}; [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+|latest)$ ]] || { echo "Invalid version"; exit 2; }
    old_env=$(mktemp); trap 'rm -f -- "$old_env"' EXIT; cp "$ROOT/.env" "$old_env"; backup >/dev/null
    ref="ghcr.io/telemt/telemt:$version"; docker pull "$ref"
    digest=$(docker image inspect "$ref" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk 'index($0,"ghcr.io/telemt/telemt@") == 1 {print; exit}')
    [[ -n "$digest" ]] || { echo "Digest not found"; exit 1; }
    sed -i "s|^TELEMT_IMAGE=.*|TELEMT_IMAGE=$digest|" "$ROOT/.env"
    sed -i "s|^TELEMT_VERSION=.*|TELEMT_VERSION=$version|" "$ROOT/.env"
    chmod 600 "$ROOT/.env"
    if "${COMPOSE[@]}" up -d --force-recreate && wait_healthy; then echo "Updated to $version ($digest)"; else echo "Healthcheck failed, rolling back"; cp "$old_env" "$ROOT/.env"; "${COMPOSE[@]}" up -d --force-recreate; wait_healthy; exit 1; fi
    ;;
  uninstall)
    shift
    confirmed=false
    for arg in "$@"; do [[ "$arg" == --yes ]] && confirmed=true; done
    if [[ "$confirmed" == false ]]; then
        echo "Будут безвозвратно удалены контейнеры Telemt, GeoBlock/firewall, node_exporter, unit-файлы, jail Fail2ban, сертификат заглушки, /opt/telemt и legacy-каталоги /opt/mtg, /opt/geo-exporter."
        echo "Общесистемные пакеты Docker, Fail2ban и Certbot останутся, поскольку могут использоваться другими приложениями."
        read -rp "Для полного удаления введите DELETE: " answer
        [[ "$answer" == DELETE ]] || { echo "Удаление отменено"; exit 0; }
    fi
    [[ "$ROOT" == /opt/telemt ]] || { echo "Небезопасный путь ROOT=$ROOT; удаление остановлено" >&2; exit 1; }
    cert_name=${STUB_DOMAIN:-}
    cert_type=${STUB_CERT_TYPE:-none}
    telemt_image=$(awk -F= '$1=="TELEMT_IMAGE"{sub(/^[^=]*=/,""); print; exit}' "$ROOT/.env" 2>/dev/null || true)
    stub_image=$(awk -F= '$1=="STUB_IMAGE"{sub(/^[^=]*=/,""); print; exit}' "$ROOT/.env" 2>/dev/null || true)

    "${COMPOSE[@]}" down --remove-orphans --volumes || true
    docker rm -f telemt telemt-stub geo-exporter mtprotoproxy mtproto-proxy >/dev/null 2>&1 || true
    /opt/telemt/bin/firewall.sh remove || true
    for unit_name in telemt-firewall.service telemt-geoblock.service telemt-geoblock.timer telemt-geoblock-resume.service telemt-geoblock-resume.timer telemt-stub-cert.service telemt-stub-cert.timer telemt-node-exporter.service; do
        systemctl disable --now "$unit_name" >/dev/null 2>&1 || systemctl stop "$unit_name" >/dev/null 2>&1 || true
    done
    for unit in /etc/systemd/system/telemt-firewall.service /etc/systemd/system/telemt-geoblock.service /etc/systemd/system/telemt-geoblock.timer /etc/systemd/system/telemt-geoblock-resume.service /etc/systemd/system/telemt-geoblock-resume.timer /etc/systemd/system/telemt-stub-cert.service /etc/systemd/system/telemt-stub-cert.timer /etc/systemd/system/telemt-node-exporter.service; do [[ -e "$unit" || -L "$unit" ]] && unlink "$unit"; done
    [[ -e /run/telemt-geoblock.paused ]] && unlink /run/telemt-geoblock.paused
    if [[ -f /etc/fail2ban/jail.d/telemt-sshd.conf ]]; then unlink /etc/fail2ban/jail.d/telemt-sshd.conf; systemctl restart fail2ban || true; fi
    [[ -L /usr/local/bin/mtproto || -e /usr/local/bin/mtproto ]] && unlink /usr/local/bin/mtproto
    if [[ "$cert_type" == letsencrypt && -n "$cert_name" ]] && command -v certbot >/dev/null 2>&1; then certbot delete --cert-name "$cert_name" --non-interactive || true; fi
    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true
    [[ -z "$telemt_image" ]] || docker image rm "$telemt_image" >/dev/null 2>&1 || true
    [[ -z "$stub_image" ]] || docker image rm "$stub_image" >/dev/null 2>&1 || true
    docker image rm telemt-geo-exporter:2 >/dev/null 2>&1 || true
    cd /
    rm -rf -- /opt/telemt
    rm -rf -- /opt/mtg
    rm -rf -- /opt/geo-exporter
    echo "Telemt полностью удалён: файлы, секреты, backups, контейнеры, правила и служебные unit-файлы очищены."
    ;;
  *) echo "Неизвестная команда: ${1:-}" >&2; echo "Выполните: mtproto help" >&2; exit 2 ;;
esac
MANAGE
chmod 700 "$INSTALL_ROOT/bin/mtproto"
ln -sfn "$INSTALL_ROOT/bin/mtproto" /usr/local/bin/mtproto

cat > "$INSTALL_ROOT/update.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/telemt/bin/mtproto update "${1:-latest}"
WRAPPER
cat > "$INSTALL_ROOT/uninstall.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/telemt/bin/mtproto uninstall "$@"
WRAPPER
cat > "$INSTALL_ROOT/doctor.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/telemt/bin/mtproto doctor
WRAPPER
cat > "$INSTALL_ROOT/backup.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/telemt/bin/mtproto backup "$@"
WRAPPER
chmod 700 "$INSTALL_ROOT/update.sh" "$INSTALL_ROOT/uninstall.sh" "$INSTALL_ROOT/doctor.sh" "$INSTALL_ROOT/backup.sh"
ok "Сервисные скрипты созданы в $INSTALL_ROOT"

step "Запуск и проверка"
cd "$INSTALL_ROOT"
docker rm -f telemt telemt-stub geo-exporter mtprotoproxy mtproto-proxy >/dev/null 2>&1 || true
docker compose --env-file .env -f docker-compose.yml up -d
STATUS=""
for _ in {1..30}; do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' telemt 2>/dev/null || true)
    [[ "$STATUS" == healthy ]] && break
    sleep 2
done
if [[ "$STATUS" != healthy ]]; then
    docker compose --env-file .env -f docker-compose.yml logs --tail 100 telemt
    die "Telemt не прошёл healthcheck"
fi
ok "Telemt healthy"
if [[ "$FAIL2BAN_ENABLE" == true ]]; then fail2ban-client status sshd >/dev/null && ok "Fail2ban sshd active"; fi
if [[ "$STUB_ENABLE" == true ]]; then
    STUB_STATUS=""
    for _ in {1..20}; do
        STUB_STATUS=$(docker inspect -f '{{.State.Health.Status}}' telemt-stub 2>/dev/null || true)
        [[ "$STUB_STATUS" == healthy ]] && break
        sleep 1
    done
    [[ "$STUB_STATUS" == healthy ]] || die "Nginx-заглушка не прошла healthcheck"
    mtproto stub check
    ok "HTTPS-заглушка проверена через openssl и curl"
fi
mtproto doctor || warn "Doctor обнаружил предупреждения — смотрите вывод выше"

step "Результат"
LINK_OUTPUT=""; PROXY_LINKS=""
for _ in {1..15}; do
    PROXY_LINKS=$(mtproto links 2>/dev/null || true)
    [[ -n "$PROXY_LINKS" ]] && break
    sleep 1
done
[[ -n "$PROXY_LINKS" ]] || die "Telemt API не сформировал ссылку. Проверьте журнал: mtproto logs 100"
if [[ "$SECURE" == true && $(grep -c '^\[DD\]' <<< "$PROXY_LINKS") -ne 2 ]]; then die "Telemt API не сформировал обе DD-ссылки (tg:// и https://t.me)"; fi
if [[ "$TLS" == true && $(grep -c '^\[EE\]' <<< "$PROXY_LINKS") -ne 2 ]]; then die "Telemt API не сформировал обе EE-ссылки (tg:// и https://t.me)"; fi
SITE_URL=""; SITE_TELEMT_URL=""
if [[ "$STUB_ENABLE" == true ]]; then
    if [[ "$STUB_PUBLIC_HTTPS" == true ]]; then SITE_URL="https://${STUB_DOMAIN}/"; else SITE_URL="https://${STUB_DOMAIN}:${PORT}/"; fi
    if [[ "$PORT" != 443 ]]; then SITE_TELEMT_URL="https://${STUB_DOMAIN}:${PORT}/"; fi
fi
METRICS_URL=""; GEO_URL=""; NODE_EXPORTER_URL=""
METRICS_HOST=127.0.0.1; [[ "$METRICS_REMOTE" == true ]] && METRICS_HOST=${SERVER_IP:-$PUBLIC_HOST}
if [[ "$METRICS_ENABLE" == true ]]; then METRICS_URL="http://${METRICS_HOST}:${METRICS_PORT}/metrics"; fi
if [[ "$GEO_ENABLE" == true ]]; then GEO_URL="http://${METRICS_HOST}:${GEO_METRICS_PORT}/metrics"; fi
if [[ "$NODE_EXPORTER_ENABLE" == true ]]; then NODE_EXPORTER_URL="http://${METRICS_HOST}:${NODE_EXPORTER_PORT}/metrics"; fi

SUMMARY_FILE="$INSTALL_ROOT/INSTALLATION-SUMMARY.txt"
{
    echo "Telemt Installer v${INSTALLER_VERSION}"
    echo "Installed: $(date --iso-8601=seconds)"
    echo ""
    echo "Server IP: ${SERVER_IP:-не определён}"
    echo "Public host: $PUBLIC_HOST"
    echo "Port: $PORT"
    echo "Mode: $MODE_LABEL"
    echo "Proxy Secret: $SECRET"
    echo "Ad-tag: ${AD_TAG:-не задан}"
    echo "TLS domain: $TLS_DOMAIN"
    echo ""
    echo "Telegram proxy links:"
    printf '%s\n' "$PROXY_LINKS"
    if [[ -n "$AD_TAG" ]]; then
        echo ""
        echo "Proxy Sponsor: @MTProxybot → /myproxies → выбрать сервер → Set promotion → публичный канал → ждать до 1 часа"
        echo "Проверка: mtproto sponsor (канал не показывается уже подписанному на него аккаунту)"
    fi
    [[ -z "$SITE_URL" ]] || { echo ""; echo "Website: $SITE_URL"; }
    [[ -z "$SITE_TELEMT_URL" || "$SITE_TELEMT_URL" == "$SITE_URL" ]] || echo "Website through Telemt: $SITE_TELEMT_URL"
    echo "MTProxybot: https://t.me/MTProxybot"
    echo "Local API health: http://127.0.0.1:9091/v1/health"
    [[ -z "$METRICS_URL" ]] || echo "Prometheus metrics: $METRICS_URL"
    [[ -z "$GEO_URL" ]] || echo "GeoIP metrics: $GEO_URL"
    [[ -z "$NODE_EXPORTER_URL" ]] || echo "node_exporter v${NODE_EXPORTER_VERSION}: $NODE_EXPORTER_URL"
    [[ "$METRICS_REMOTE" == true ]] && echo "External metrics allow-list: IPv4 $GRAFANA_IP"
    echo ""
    echo "Commands: mtproto help | credentials | secrets | links | sponsor | client-debug 120 | geoblock pause | ports | doctor | status | logs | update | backup"
} > "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

echo -e "${GREEN}${BOLD}  ✔ УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА${NC}"
result_begin "данные подключения"
result_line "Сервер" "$PUBLIC_HOST"
result_line "Порт" "$PORT"
result_line "Режим" "$MODE_LABEL"
result_line "Proxy Secret" "$SECRET"
result_line "Ad-tag" "${AD_TAG:-не задан}"
result_end
result_begin "порты после установки"
result_line "TCP/$PORT" "разрешён локальным firewall; Telemt слушает"
[[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]] && result_line "TCP/443" "публичная заглушка без указания порта"
result_line "TCP/80" "$([[ "$STUB_ENABLE" == true ]] && echo "открывается временно для Certbot" || echo "не используется")"
result_line "TCP/9091" "локальный API, снаружи закрыт"
[[ "$STUB_ENABLE" == true ]] && result_line "TCP/$STUB_PORT" "локальный Nginx, снаружи закрыт"
[[ "$METRICS_ENABLE" == true ]] && result_line "TCP/$METRICS_PORT" "$([[ "$METRICS_REMOTE" == true ]] && echo "доступ только с $GRAFANA_IP" || echo "локально, снаружи закрыт")"
[[ "$GEO_ENABLE" == true ]] && result_line "TCP/$GEO_METRICS_PORT" "$([[ "$METRICS_REMOTE" == true ]] && echo "доступ только с $GRAFANA_IP" || echo "локально, снаружи закрыт")"
[[ "$NODE_EXPORTER_ENABLE" == true ]] && result_line "TCP/$NODE_EXPORTER_PORT" "$([[ "$METRICS_REMOTE" == true ]] && echo "node_exporter, доступ только с $GRAFANA_IP" || echo "node_exporter, локально")"
result_line "GeoBlock" "${GEOBLOCK_STATUS:-не определён}"
result_end
echo -e "${CYAN}${BOLD}  ССЫЛКИ ДЛЯ ДОБАВЛЕНИЯ ПРОКСИ В TELEGRAM:${NC}"
while IFS= read -r proxy_link; do [[ -n "$proxy_link" ]] && echo -e "  ${GREEN}${BOLD}${proxy_link}${NC}"; done <<< "$PROXY_LINKS"
if [[ -n "$SITE_URL" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}  САЙТ-ЗАГЛУШКА:${NC}"
    echo -e "  ${GREEN}${BOLD}${SITE_URL}${NC}"
    [[ -z "$SITE_TELEMT_URL" || "$SITE_TELEMT_URL" == "$SITE_URL" ]] || echo -e "  Через порт Telemt: ${GREEN}${BOLD}${SITE_TELEMT_URL}${NC}"
fi
echo ""
echo -e "${CYAN}${BOLD}  ДРУГИЕ ПОЛЕЗНЫЕ АДРЕСА:${NC}"
echo -e "  MTProxybot:       ${GREEN}https://t.me/MTProxybot${NC}"
echo -e "  API health:       ${GREEN}http://127.0.0.1:9091/v1/health${NC} (только сервер)"
[[ -z "$METRICS_URL" ]] || echo -e "  Prometheus:       ${GREEN}${METRICS_URL}${NC}"
[[ -z "$GEO_URL" ]] || echo -e "  GeoIP:            ${GREEN}${GEO_URL}${NC}"
[[ -z "$NODE_EXPORTER_URL" ]] || echo -e "  node_exporter:    ${GREEN}${NODE_EXPORTER_URL}${NC}"
[[ "$METRICS_REMOTE" == true ]] && echo -e "  Allow-list:       ${GREEN}только IPv4 ${GRAFANA_IP}${NC}"
echo ""
ok "Закрытая памятка сохранена: $SUMMARY_FILE (права 600)"
echo -e "Повторно показать данные: ${CYAN}sudo mtproto credentials${NC}"
echo -e "Только ссылки:           ${CYAN}sudo mtproto links${NC}"
echo -e "Все команды:             ${CYAN}sudo mtproto help${NC}"
[[ -n "$SELECTED_CODES" ]] && echo -e "GeoBlock на 5 минут:     ${CYAN}sudo mtproto geoblock pause${NC}"
[[ -n "$AD_TAG" ]] && echo -e "Проверка Proxy Sponsor:  ${CYAN}sudo mtproto sponsor${NC}"
echo -e "Диагностика iOS/клиента: ${CYAN}sudo mtproto client-debug 120${NC}"
echo -e "Все файлы:               ${CYAN}${INSTALL_ROOT}${NC}"
echo -e "Диагностика:             ${CYAN}sudo mtproto doctor${NC}"
echo -e "Проверка портов:         ${CYAN}sudo mtproto ports${NC}"
if [[ "$STUB_ENABLE" == true ]]; then
    echo -e "HTTPS-заглушка: ${CYAN}${SITE_URL}${NC} (сертификат: ${STUB_CERT_TYPE})"
    echo -e "HTML для SFTP: ${CYAN}/opt/telemt/stub/html/index.html${NC}, пользователь ${STUB_OWNER}"
    echo -e "Управление: ${CYAN}mtproto stub {status|check|path|backup|renew|letsencrypt|selfsigned|remove}${NC}"
fi
warn "Не забудьте разрешить TCP/$PORT во внешнем firewall провайдера."
[[ "$STUB_PUBLIC_HTTPS" == true && "$PORT" != 443 ]] && warn "Для сайта без порта также разрешите внешний TCP/443."
