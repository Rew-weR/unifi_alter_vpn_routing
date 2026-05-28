#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v3.1.0-Stable) - MAIN CONTROLLER
# ==============================================================================
# Главный управляющий скрипт ядра Linux. Реализует инверсное PBR-разделение:
# Все ресурсы по умолчанию идут в VPN, а списки исключений — в нативный WAN1.
# ==============================================================================

set -e

# --- Базовые пути и константы ---
CONF_FILE="/data/vpn-router/vpn-routing.conf"
FWMARK_ID="0x99"

# Подгружаем глобальную конфигурацию
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "[CRITICAL] Configuration file $CONF_FILE not found!"
    exit 1
fi

# Подгружаем локализационный пакет для вывода строк
LANG_FILE="${TOOL_PATH}/languages/${SYSTEM_LANGUAGE}.conf"
if [ -f "$LANG_FILE" ]; then
    . "$LANG_FILE"
else
    # Резервные строки на случай сбоя i18n
    MSG_STARTING="Запуск маршрутизации и применение политик PBR/IPSec..."
    MSG_CLEANING="Очистка кастомных правил ядра..."
    MSG_ERROR="[ERROR] Критическая ошибка ядра сети!"
fi

# Единый фреймворк логирования (syslog + stdout)
log_msg() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v3.1.0-Control) $message"
}

# ==============================================================================
# УНИВЕРСАЛЬНЫЙ И БЕЗОПАСНЫЙ ДИНАМИЧЕСКИЙ ДЕТЕКТ ПАРАМЕТРОВ ЯДРА
# ==============================================================================
detect_unifi_parameters() {
    log_msg "INFO" "Выполнение динамического сканирования сетевого стека UniFi OS..."

    # 1. Поиск активного интерфейса WireGuard клиента в выводе таблиц ядра
    local unifi_route_line
    unifi_route_line=$(ip route show table all | grep -E "wgclt[0-9]+" | head -n 1 || true)

    local detected_table_id=""
    local detected_kernel_iface=""

    if [ -n "$unifi_route_line" ]; then
        local raw_table_cell
        raw_table_cell=$(echo "$unifi_route_line" | awk '{print $3}')
        if [[ "$raw_table_cell" == *"."* ]]; then
            detected_table_id=$(echo "$raw_table_cell" | cut -d'.' -f1)
            detected_kernel_iface=$(echo "$raw_table_cell" | cut -d'.' -f2)
        fi
    fi

    # Фолбэки из vpn-routing.conf на случай, если интерфейс временно переинициализируется
    TARGET_WG_KERNEL="${detected_kernel_iface:-${TARGET_WG_KERNEL_DEFAULT:-wgclt4}}"
    TARGET_PURE_TABLE_ID="${detected_table_id:-${TARGET_PURE_TABLE_ID_DEFAULT:-178}}"

    # Жесткая валидация: ID таблицы обязан быть строго числом
    if ! [[ "$TARGET_PURE_TABLE_ID" =~ ^[0-9]+$ ]]; then 
        TARGET_PURE_TABLE_ID="178" 
    fi

    # 2. Определение актуального IP адреса интерфейса WireGuard
    local detected_ip
    detected_ip=$(ip addr show "$TARGET_WG_KERNEL" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' || true)
    TARGET_WG_STATIC_IP="${detected_ip:-${TARGET_WG_STATIC_IP_DEFAULT:-10.151.0.3}}"

    # 3. Динамическое определение нативной таблицы провайдера WAN1 (DefaultGateway)
    TARGET_WAN_TABLE=$(ip route show table all | grep "proto DefaultGateway" | awk '{print $7}' | cut -d'.' -f1 | head -n 1 || true)
    if ! [[ "$TARGET_WAN_TABLE" =~ ^[0-9]+$ ]]; then 
        TARGET_WAN_TABLE="201" 
    fi

    log_msg "INFO" "Параметры успешно согласованы: Дефолтный VPN туннель=$TARGET_WG_KERNEL (Таблица $TARGET_PURE_TABLE_ID), Исключения в WAN1=Таблица $TARGET_WAN_TABLE"
}

# --- Создание атомарных резервных копий состояния ядра перед изменениями ---
backup_kernel_state() {
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    mkdir -p "$BACKUP_DIR"
    
    ip rule list > "${BACKUP_DIR}/rules_${timestamp}.bak"
    ip route show table main > "${BACKUP_DIR}/routes_main_${timestamp}.bak"
    
    # Автоматическая ротация (храним только последние 10 снимков)
    ls -t "${BACKUP_DIR}"/rules_*.bak 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true
    ls -t "${BACKUP_DIR}"/routes_main_*.bak 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true
}

# ==============================================================================
# ПРОТОКОЛ ЗАПУСКА МАРШРУТИЗАЦИИ (START)
# ==============================================================================
start_routing() {
    log_msg "INFO" "$MSG_STARTING"
    detect_unifi_parameters
    backup_kernel_state

    # ЗАЩИТА 1: Изоляция локального трафика хоста самого UDM SE
    # Все процессы самого роутера (DNS, curl, обновления) всегда идут по нативным таблицам
    if ! ip rule list | grep -F "from all iif lo pref 999 table main" >/dev/null 2>&1; then
        ip rule add from all iif lo pref 999 table main
    fi

    # ЗАЩИТА 2: Изоляция локальных LAN и VLAN подсетей (Local Traffic Isolation Bug)
    # Предотвращает потерю связи VPN-клиентов с локальными сетевыми принтерами, шарами и панелью UDM
    for subnet in "${LOCAL_SUPERNETS[@]}"; do
        if ! ip rule list | grep -F "from all to $subnet pref $PREF_LOCAL_ISOLATION table main" >/dev/null 2>&1; then
            ip rule add to "$subnet" pref "$PREF_LOCAL_ISOLATION" table main
        fi
    done

    # ПРАВИЛО 1: Перехват трафика выборочного Site-to-Site IPSec Datacenter (PBR_AND_DC)
    # Пакеты в подсети ДЦ уходят в таблицу main, откуда их шифрует нативный XFRM IPSec
    for net_info in "${SRC_NETWORKS[@]}"; do
        IFS=':' read -r iface subnet type <<< "$net_info"
        
        if [ "$type" == "PBR_AND_DC" ]; then
            for dc_subnet in "${DC_REMOTE_SUBNETS[@]}"; do
                if ! ip rule list | grep -F "from $subnet to $dc_subnet pref $PREF_IPSEC_INTERCEPT table main" >/dev/null 2>&1; then
                    ip rule add from "$subnet" to "$dc_subnet" pref "$PREF_IPSEC_INTERCEPT" table main
                fi
            done
        fi
    done

    # ПРАВИЛО 2: Глобальный селективный PBR (Policy-Based Routing) для VPN-клиентов
    local current_pref="$PREF_VPN_PBR_BASE"
    for net_info in "${SRC_NETWORKS[@]}"; do
        IFS=':' read -r iface subnet type <<< "$net_info"
        
        # ЭТАП А: Перехват ресурсов-исключений.
        # Если пакет от VPN-клиента совпал со списками ipset (ИМЕЕТ fwmark 0x99),
        # мы принудительно отправляем его напрямую через провайдера в нативный WAN1 (TARGET_WAN_TABLE).
        if ! ip rule list | grep -F "from $subnet fwmark $FWMARK_ID pref $current_pref table $TARGET_WAN_TABLE" >/dev/null 2>&1; then
            ip rule add from "$subnet" fwmark "$FWMARK_ID" pref "$current_pref" table "$TARGET_WAN_TABLE"
        fi
        ((current_pref++))

        # ЭТАП Б: Весь остальной трафик по умолчанию.
        # Пакеты, у которых нет маркера исключений, пролетают верхнее правило 
        # и безраздельно направляются в защищенный туннель WireGuard (TARGET_PURE_TABLE_ID).
        if ! ip rule list | grep -F "from $subnet pref $current_pref table $TARGET_PURE_TABLE_ID" >/dev/null 2>&1; then
            ip rule add from "$subnet" pref "$current_pref" table "$TARGET_PURE_TABLE_ID"
        fi
        ((current_pref++))
    done

    # Гарантируем наличие маршрута по умолчанию в кастомной таблице WireGuard туннеля
    if ! ip route show table "$TARGET_PURE_TABLE_ID" | grep -q "default"; then
        ip route add default dev "$TARGET_WG_KERNEL" table "$TARGET_PURE_TABLE_ID" || true
    fi

    # Активация подсистемы динамических списков обхода блокировок (Bypass Loader)
    if [ -f "${TOOL_PATH}/vpn-bypass-loader.sh" ]; then
        /bin/bash "${TOOL_PATH}/vpn-bypass-loader.sh" start || log_msg "WARNING" "Bypass подсистема завершилась со статусом alert."
    fi

    log_msg "INFO" "Политики инверсной PBR маршрутизации успешно применены к ядру Linux."
}

# ==============================================================================
# ПРОТОКОЛ ОЧИСТКИ ЯДРА (CLEAN / STOP)
# ==============================================================================
clean_routing() {
    log_msg "INFO" "$MSG_CLEANING"
    
    # 1. Сначала полностью гасим и демонтируем списки обхода ipset и iptables
    if [ -f "${TOOL_PATH}/vpn-bypass-loader.sh" ]; then
        /bin/bash "${TOOL_PATH}/vpn-bypass-loader.sh" stop || true
    fi

    # 2. Удаление правила локальной петли хоста UDM
    while ip rule del pref 999 table main 2>/dev/null; do :; done

    # 3. Удаление правил локальной LAN/VLAN изоляции
    for subnet in "${LOCAL_SUPERNETS[@]}"; do
        while ip rule del to "$subnet" pref "$PREF_LOCAL_ISOLATION" table main 2>/dev/null; do :; done
    done

    # 4. Удаление правил IPSec датацентра
    for dc_subnet in "${DC_REMOTE_SUBNETS[@]}"; do
        while ip rule del to "$dc_subnet" pref "$PREF_IPSEC_INTERCEPT" table main 2>/dev/null; do :; done
    done

    # 5. Каскадная тотальная зачистка динамического диапазона PBR правил (fwmark и table ID)
    local current_pref
    local max_pref_cleanup=$((PREF_VPN_PBR_BASE + (${#SRC_NETWORKS[@]} * 2) + 20))
    for ((current_pref=PREF_VPN_PBR_BASE; current_pref<max_pref_cleanup; current_pref++)); do
        while ip rule del pref "$current_pref" 2>/dev/null; do :; done
    done

    log_msg "INFO" "Очистка конфигураций сетевого ядра успешно завершена."
}

# --- Обработка аргументов командной строки ---
case "$1" in
    start)
        start_routing
        ;;
    stop|clean)
        clean_routing
        ;;
    restart)
        clean_routing
        start_routing
        ;;
    *)
        echo "Usage: $0 {start|stop|clean|restart}"
        exit 1
        ;;
esac
