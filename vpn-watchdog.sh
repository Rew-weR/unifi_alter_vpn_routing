#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.9-Stable) - TELEMETRY & WATCHDOG
# ==============================================================================

set -e

# --- Базовые пути и импорт конфигурации ---
CONF_FILE="/data/vpn-router/vpn-routing.conf"
CONTROL_SCRIPT="/data/vpn-router/vpn-routing-control.sh"
STATE_FILE="/tmp/vpn_watchdog_failed.state"

if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "[CRITICAL] Configuration file $CONF_FILE not found in watchdog!"
    exit 1
fi

# Подгружаем локализацию
LANG_FILE="${TOOL_PATH}/languages/${SYSTEM_LANGUAGE}.conf"
if [ -f "$LANG_FILE" ]; then
    . "$LANG_FILE"
fi

# Логирование
log_msg() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v2.8.9-Watchdog) $message"
}

# Асинхронная отправка алертов в Telegram API (с защитой от зависания cURL)
send_telegram_notification() {
    local msg_text="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        # Ограничиваем время выполнения запроса (max-time 8 сек), чтобы скрипт не завис навсегда
        curl -s -X POST "https://telegram.org{TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${msg_text}" \
            -d "parse_mode=HTML" \
            --max-time 8 >/dev/null 2>&1 &
    fi
}

# ==============================================================================
# ДИНАМИЧЕСКИЙ ПЕРЕСЧЕТ ДЛЯ ИСКЛЮЧЕНИЯ ЛОЖНЫХ СРАБАТЫВАНИЙ
# ==============================================================================
# Запрашиваем актуальное имя интерфейса из ядра прямо сейчас
CURRENT_WG_KERNEL=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "$TARGET_WG_KERNEL")

# Проверяем, поднят ли интерфейс физически в системе
if [ ! -d "/sys/class/net/$CURRENT_WG_KERNEL" ]; then
    log_msg "WARNING" "Интерфейс $CURRENT_WG_KERNEL отсутствует в системе. Проверка отложена."
    exit 0
fi

# ==============================================================================
# ВЫПОЛНЕНИЕ ТЕЛЕМЕТРИИ (HEALTH CHECK)
# ==============================================================================
success_hosts=0

for host in "${CHECK_HOSTS[@]}"; do
    # Отправляем 2 ICMP-пакета с таймаутом в 2 секунды, строго привязавшись к интерфейсу
    if ping -I "$CURRENT_WG_KERNEL" -c 2 -W 2 "$host" >/dev/null 2>&1; then
        ((success_hosts++))
        break # Если хотя бы один хост ответил, канал считается рабочим
    fi
done

# ==============================================================================
# АВТОМАТИЧЕСКИЙ СТАТУС-МАШИННЫЙ ФОЛБЭК
# ==============================================================================
if [ "$success_hosts" -eq 0 ]; then
    # Канал УПАЛ
    log_msg "ERROR" "Все хосты проверки недоступны через $CURRENT_WG_KERNEL."

    # Если это первое падение (предотвращаем циклические перезапуски)
    if [ ! -f "$STATE_FILE" ]; then
        touch "$STATE_FILE"
        
        # Формируем и логируем локализованное сообщение об аварии
        ALERT_TXT="${MSG_WD_ALERT:-🚨 [ALERT] VPN interface down! Failing over to WAN.}"
        # Динамически подменяем маркеры, если они есть в строке
        ALERT_TXT=$(echo "$ALERT_TXT" | sed "s/\$TARGET_WG_KERNEL/$CURRENT_WG_KERNEL/g")
        
        log_msg "CRITICAL" "$ALERT_TXT"
        send_telegram_notification "$ALERT_TXT"

        # Демонтируем PBR-таблицы, возвращая клиентов на обычный ISP Интернет
        if [ -f "$CONTROL_SCRIPT" ]; then
            /bin/bash "$CONTROL_SCRIPT" stop || true
        fi
    fi
else
    # Канал ИСПРАВЕН
    if [ -f "$STATE_FILE" ]; then
        # Если до этого канал лежал, фиксируем восстановление
        rm -f "$STATE_FILE"
        
        RECOVERY_TXT="${MSG_WD_RECOVERY:-✅ [RECOVERY] VPN interface connection restored! Normal PBR applied.}"
        RECOVERY_TXT=$(echo "$RECOVERY_TXT" | sed "s/\$TARGET_WG_KERNEL/$CURRENT_WG_KERNEL/g")
        
        log_msg "INFO" "$RECOVERY_TXT"
        send_telegram_notification "$RECOVERY_TXT"

        # Накатываем правила PBR и Site-to-Site обратно в ядро
        if [ -f "$CONTROL_SCRIPT" ]; then
            /bin/bash "$CONTROL_SCRIPT" start || true
        fi
    else
        # Штатный режим работы
        OK_TXT="${MSG_WD_OK:-[HEALTH] VPN routing status is healthy.}"
        log_msg "INFO" "$OK_TXT"
    fi
fi
