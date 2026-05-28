#!/bin/sh

# ===================================================================
# PLUGIN VERSION: v2.7.1-Stable (Enterprise IPSet Core Integration)
# DESCRIPTION: Интеграция высокоскоростных хэш-таблиц IPSet в ip rule
# ===================================================================

SET_NAME="bypass_list"
BYPASS_DIR="/data/vpn-router/bypass-parts"

[ "$ENABLE_BYPASS_MODULE" != "true" ] && return 0

case "$1" in
    start)
        log_msg "INFO" "$MSG_BYPASS_ON"
        
        # 1. Создаем хэш-таблицу в памяти ядра, если она отсутствует
        if ! ipset list "$SET_NAME" >/dev/null 2>&1; then
            ipset create "$SET_NAME" hash:net maxelem 65536
        fi
        
        # 2. Потоковая загрузка порционных файлов в IPSet через механизм restore
        if [ -d "$BYPASS_DIR" ]; then
            (
                echo "flush $SET_NAME"
                for file in "$BYPASS_DIR"/part_*.txt; do
                    [ ! -f "$file" ] && continue
                    while IFS= read -r subnet || [ -n "$subnet" ]; do
                        case "$subnet" in
                            ""|#*) continue ;;
                        esac
                        echo "add $SET_NAME $subnet"
                    done < "$file"
                done
            ) | ipset restore >/dev/null 2>&1
        fi
        
        # 3. Применение ЕДИНСТВЕННОГО правила в ip rule для каждой сети клиента
        # Используется нативный, проверенный синтаксис: set SET_NAME dst
        bypass_pref=900
        for client_net in $INTERNET_FORWARD_NETS; do
            [ -z "$net" ] && continue
            ip rule add from "$client_net" set "$SET_NAME" dst pref $bypass_pref table main
            bypass_pref=$((bypass_pref + 1))
        done
        ;;
        
    stop|clean)
        # Чистая очистка диапазона правил 900-999
        for p in $(seq 900 999); do
            while ip rule del pref $p 2>/dev/null; do :; done
        done
        
        # Сброс содержимого хэш-таблицы без удаления её структуры
        if ipset list "$SET_NAME" >/dev/null 2>&1; then
            ipset flush "$SET_NAME"
        fi
        log_msg "INFO" "$MSG_BYPASS_CLEAN"
        ;;
esac

