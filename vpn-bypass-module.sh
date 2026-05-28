#!/usr/bin/env bash
# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.9) - BYPASS CORE MODULE
# ==============================================================================
set -e

CONF_FILE="/data/vpn-router/vpn-routing.conf"
if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; else exit 1; fi

FWMARK_ID="0x99"
PREF_BYPASS_RULE=1500

log_msg() {
    logger -t "$LOG_TAG" "[$1] (v2.8.9-BypassCore) $2"
}

if [ -z "$TARGET_PURE_TABLE_ID" ]; then TARGET_PURE_TABLE_ID="178"; fi

get_set_name() {
    local base_name=$(basename "$1" | tr -cd 'a-zA-Z0-9_-')
    echo "vpn_${base_name:0:27}"
}

start_bypass_file() {
    local file_in="$1"
    if [ ! -f "$file_in" ] || [ ! -s "$file_in" ]; then return 0; fi
    local set_name=$(get_set_name "$file_in")

    if ! ipset list "$set_name" >/dev/null 2>&1; then
        ipset create "$set_name" hash:net hashsize 4096 maxelem 65536
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed -e 's/#.*//' -e 's/[[:space:]]//g')
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            ipset add "$set_name" "$line" -exist >/dev/null 2>&1 || true
        fi
    done < "$file_in"

    if ! iptables -t mangle -C PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1; then
        iptables -t mangle -A PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff"
    fi

    if ! ip rule list | grep -F "fwmark $FWMARK_ID pref $PREF_BYPASS_RULE table $TARGET_PURE_TABLE_ID" >/dev/null 2>&1; then
        ip rule add fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID"
    fi
}

stop_bypass_file() {
    local file_in="$1"
    if [ ! -f "$file_in" ]; then return 0; fi
    local set_name=$(get_set_name "$file_in")
    iptables -t mangle -D PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
    ipset destroy "$set_name" >/dev/null 2>&1 || true
}

global_clean() {
    while ip rule del fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID" 2>/dev/null; do :; done
    local active_sets=$(ipset list -n | grep "^vpn_" || true)
    for set in $active_sets; do
        iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
        ipset destroy "$set" >/dev/null 2>&1 || true
    done
}

case "$1" in
    start) start_bypass_file "$2" ;;
    stop) stop_bypass_file "$2" ;;
    clean) global_clean ;;
    *) echo "Usage: $0 {start <file>|stop <file>|clean}"; exit 1 ;;
esac
