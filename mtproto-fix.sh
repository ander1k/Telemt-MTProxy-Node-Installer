#!/usr/bin/env bash
set -Eeuo pipefail

# V3 algorithm adapted from MTPROTO_FIX_By_MEKO (c) 2026 MEKO.
# The original license is installed in /opt/telemt/licenses/MTPROTO_FIX_By_MEKO-LICENSE.txt.
ROOT=/opt/telemt
ENV_FILE=$ROOT/config/installer.env
FILTER_CHAIN=TELEMT_MTPROTO_FIX
MANGLE_CHAIN=TELEMT_MTPROTO_MARK
U32_PATTERN='32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000'

[[ $(id -u) -eq 0 ]] || { echo "Запустите от root: sudo mtproto fix" >&2; exit 1; }
. "$ENV_FILE"
MTPROTO_FIX_ENABLE=${MTPROTO_FIX_ENABLE:-false}
MTPROTO_FIX_TYPE=${MTPROTO_FIX_TYPE:-v3}
MTPROTO_FIX_PORTS=${MTPROTO_FIX_PORTS:-${PORT:-443}}

validate_ports() {
    local raw=${1//[[:space:]]/} item normalized=""
    local -a values=()
    local -A seen=()
    IFS=',' read -ra values <<< "$raw"
    [[ ${#values[@]} -gt 0 ]] || return 1
    for item in "${values[@]}"; do
        [[ "$item" =~ ^[0-9]+$ ]] && (( item >= 1 && item <= 65535 )) || return 1
        [[ -n "${seen[$item]:-}" ]] && continue
        seen[$item]=1
        normalized+="${normalized:+,}${item}"
    done
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

save_setting() {
    local enabled=$1 ports=$2
    sed -i "s/^MTPROTO_FIX_ENABLE=.*/MTPROTO_FIX_ENABLE=$enabled/" "$ENV_FILE"
    sed -i 's/^MTPROTO_FIX_TYPE=.*/MTPROTO_FIX_TYPE=v3/' "$ENV_FILE"
    sed -i "s/^MTPROTO_FIX_PORTS=.*/MTPROTO_FIX_PORTS=\"$ports\"/" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

delete_hooks() {
    while iptables -w 5 -C INPUT -j "$FILTER_CHAIN" 2>/dev/null; do iptables -w 5 -D INPUT -j "$FILTER_CHAIN"; done
    while iptables -w 5 -t mangle -C PREROUTING -j "$MANGLE_CHAIN" 2>/dev/null; do iptables -w 5 -t mangle -D PREROUTING -j "$MANGLE_CHAIN"; done
}

remove_rules() {
    delete_hooks
    if iptables -w 5 -L "$FILTER_CHAIN" -n >/dev/null 2>&1; then
        iptables -w 5 -F "$FILTER_CHAIN"
        iptables -w 5 -X "$FILTER_CHAIN"
    fi
    if iptables -w 5 -t mangle -L "$MANGLE_CHAIN" -n >/dev/null 2>&1; then
        iptables -w 5 -t mangle -F "$MANGLE_CHAIN"
        iptables -w 5 -t mangle -X "$MANGLE_CHAIN"
    fi
}

apply_rules() {
    local ports item
    ports=$(validate_ports "${1:-$MTPROTO_FIX_PORTS}") || { echo "Порты должны быть в диапазоне 1–65535 и разделены запятыми" >&2; return 2; }
    command -v iptables >/dev/null 2>&1 || { echo "iptables не установлен" >&2; return 1; }
    if iptables -w 5 -C INPUT -j MTPR_SYNFIX 2>/dev/null; then
        echo "Обнаружен уже подключённый внешний MTPR_SYNFIX. Сначала удалите его через mekopr, чтобы два FIX не конфликтовали." >&2
        return 1
    fi
    command -v modprobe >/dev/null 2>&1 && modprobe xt_u32 2>/dev/null || true
    iptables -m u32 -h >/dev/null 2>&1 || { echo "Ядро/iptables не поддерживает xt_u32, необходимый для V3" >&2; return 1; }
    iptables -m hashlimit -h >/dev/null 2>&1 || { echo "Ядро/iptables не поддерживает hashlimit" >&2; return 1; }

    delete_hooks
    iptables -w 5 -N "$FILTER_CHAIN" 2>/dev/null || true
    iptables -w 5 -F "$FILTER_CHAIN"
    iptables -w 5 -t mangle -N "$MANGLE_CHAIN" 2>/dev/null || true
    iptables -w 5 -t mangle -F "$MANGLE_CHAIN"

    IFS=',' read -ra values <<< "$ports"
    for item in "${values[@]}"; do
        # V3: сигнатура u32 маркирует только SYN выбранного TCP-порта.
        iptables -w 5 -t mangle -A "$MANGLE_CHAIN" -p tcp --syn --dport "$item" \
            -m u32 --u32 "$U32_PATTERN" -j MARK --set-mark 0x400
        # RETURN передаёт разрешённый SYN основной защите Telemt/GeoBlock.
        iptables -w 5 -A "$FILTER_CHAIN" -p tcp --syn --dport "$item" -m mark --mark 0x400 -j RETURN
        iptables -w 5 -A "$FILTER_CHAIN" -p tcp --syn --dport "$item" \
            -m hashlimit --hashlimit-name "mtproto_$item" --hashlimit-mode srcip \
            --hashlimit-upto 54/minute --hashlimit-burst 1 \
            --hashlimit-htable-expire 60000 --hashlimit-htable-size 32768 -j RETURN
        iptables -w 5 -A "$FILTER_CHAIN" -p tcp --syn --dport "$item" -j REJECT --reject-with tcp-reset
    done
    iptables -w 5 -A "$FILTER_CHAIN" -j RETURN
    iptables -w 5 -t mangle -A "$MANGLE_CHAIN" -j RETURN
    iptables -w 5 -t mangle -I PREROUTING 1 -j "$MANGLE_CHAIN"
    iptables -w 5 -I INPUT 1 -j "$FILTER_CHAIN"
    echo "MTProto FIX V3 применён к TCP: $ports"
}

show_status() {
    echo "MTProto FIX: $([[ "$MTPROTO_FIX_ENABLE" == true ]] && echo "включён" || echo "выключен")"
    echo "Тип: V3 iptables/u32"
    echo "Порты: ${MTPROTO_FIX_PORTS:-не заданы}"
    systemctl is-enabled --quiet telemt-mtproto-fix.service 2>/dev/null && echo "Автозапуск: включён" || echo "Автозапуск: выключен"
    systemctl is-active --quiet telemt-mtproto-fix.service 2>/dev/null && echo "Сервис: active" || echo "Сервис: inactive"
    if iptables -w 5 -C INPUT -j "$FILTER_CHAIN" 2>/dev/null && iptables -w 5 -t mangle -C PREROUTING -j "$MANGLE_CHAIN" 2>/dev/null; then
        echo "Правила: активны"
        iptables -w 5 -L "$FILTER_CHAIN" -n -v --line-numbers
    else
        echo "Правила: не активны"
        return 1
    fi
}

install_fix() {
    local ports
    ports=$(validate_ports "${1:-$MTPROTO_FIX_PORTS}") || { echo "Некорректный список портов" >&2; return 2; }
    apply_rules "$ports"
    save_setting true "$ports"
    systemctl enable telemt-mtproto-fix.service >/dev/null
    systemctl restart telemt-mtproto-fix.service
    MTPROTO_FIX_ENABLE=true; MTPROTO_FIX_PORTS=$ports
    echo "Автозапуск MTProto FIX V3 включён"
}

uninstall_fix() {
    systemctl disable --now telemt-mtproto-fix.service >/dev/null 2>&1 || true
    remove_rules
    save_setting false "${MTPROTO_FIX_PORTS:-${PORT:-443}}"
    MTPROTO_FIX_ENABLE=false
    echo "MTProto FIX удалён; Telemt и основной firewall не изменены"
}

menu() {
    local choice ports answer
    echo ""
    echo "MTProto FIX V3 iptables"
    echo "  1) Статус"
    echo "  2) Установить или применить повторно"
    echo "  3) Удалить FIX"
    echo "  0) Выход"
    read -rp "Выбор [1]: " choice; choice=${choice:-1}
    case "$choice" in
        1) show_status ;;
        2)
            read -rp "Порт или порты через запятую [${MTPROTO_FIX_PORTS:-${PORT:-443}}]: " ports
            ports=${ports:-${MTPROTO_FIX_PORTS:-${PORT:-443}}}
            ports=$(validate_ports "$ports") || { echo "Некорректный список портов" >&2; return 2; }
            echo "Будут созданы V3 u32/hashlimit правила для TCP: $ports"
            read -rp "Продолжить? [Y/n]: " answer; answer=${answer:-Y}
            [[ "$answer" =~ ^[YyДд]$ ]] && install_fix "$ports" || echo "Отменено"
            ;;
        3)
            read -rp "Удалить только MTProto FIX? [y/N]: " answer
            [[ "$answer" =~ ^[YyДд]$ ]] && uninstall_fix || echo "Отменено"
            ;;
        0) return 0 ;;
        *) echo "Неизвестный пункт" >&2; return 2 ;;
    esac
}

case "${1:-menu}" in
    menu) menu ;;
    status) show_status ;;
    install) install_fix "${2:-$MTPROTO_FIX_PORTS}" ;;
    apply|reapply) apply_rules "${2:-$MTPROTO_FIX_PORTS}" ;;
    remove|uninstall) uninstall_fix ;;
    *) echo "Usage: mtproto fix [status|install [PORTS]|apply [PORTS]|remove]" >&2; exit 2 ;;
esac
