#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}Конфигурация NLB (Not LTE Blocker, ipset)${NC}"

S="/usr/local/bin/update-nlb.sh"
CONF_DIR="/etc/nlb"
CONF="$CONF_DIR/nlb.conf"
STATE_DIR="/var/lib/nlb"
WHITELIST_TARGET="/usr/local/etc/nlb_whitelist.txt"
OLD_REASSESSED="/usr/local/etc/nlb_reassessed.list"
BACKUP_DIR="$CONF_DIR/backup/$(date +%Y%m%d-%H%M%S)"
CRON_SCHEDULE="*/2 * * * *"
BAN4="nlb_ban_v4"
BAN6="nlb_ban_v6"

IMPORT_FILE=$(mktemp)
trap 'rm -f "$IMPORT_FILE"' EXIT

# ------------------------------------------------------------------
# mask_key <key> — маскирует значение ключа для безопасного вывода в терминал
# ------------------------------------------------------------------
mask_key() {
    local key="$1"
    local len=${#key}
    if [ "$len" -le 8 ]; then
        echo "****"
    else
        echo "${key:0:4}...${key: -4}"
    fi
}

# ------------------------------------------------------------------
# Обнаружение существующей установки: берём ключи, прокси и режим
# из нового конфига или из старого update-nlb.sh (старый формат).
# ------------------------------------------------------------------
EXISTING_API_KEY=""
EXISTING_IPAPI_KEY=""
EXISTING_PROXY=""
EXISTING_MODE=""
LEGACY=0

if [ -f "$CONF" ]; then
    echo -e "${B_YELLOW}Обнаружена установка NLB на ipset ($CONF).${NC}"
    # shellcheck source=/dev/null
    . "$CONF"
    EXISTING_API_KEY="${API_KEY:-}"
    EXISTING_IPAPI_KEY="${IPAPI_KEY:-}"
    EXISTING_PROXY="${PROXY:-}"
    EXISTING_MODE="${MODE:-}"
    unset API_KEY IPAPI_KEY PROXY MODE
elif [ -f "$S" ]; then
    LEGACY=1
    echo -e "${B_YELLOW}Обнаружена старая установка NLB без ipset ($S). Выполню миграцию.${NC}"
    EXISTING_API_KEY=$(grep -oP '(?<=^API_KEY=")[^"]*' "$S" 2>/dev/null)
    EXISTING_IPAPI_KEY=$(grep -oP '(?<=^IPAPI_KEY=")[^"]*' "$S" 2>/dev/null)
    EXISTING_PROXY=$(grep -oP '(?<=^PROXY=")[^"]*' "$S" 2>/dev/null)
    EXISTING_MODE=$(grep -oP '(?<=^MODE=")[^"]*' "$S" 2>/dev/null)
    OLD_LOG=$(grep -oP '(?<=^LOG_FILE=")[^"]*' "$S" 2>/dev/null)
    [ -n "$OLD_LOG" ] && LOG_FILE="$OLD_LOG"
fi

if [ -n "$EXISTING_API_KEY$EXISTING_IPAPI_KEY$EXISTING_PROXY$EXISTING_MODE" ]; then
    [ -n "$EXISTING_API_KEY" ] && echo -e "  Текущий ключ proxycheck.io: $(mask_key "$EXISTING_API_KEY")"
    [ -n "$EXISTING_IPAPI_KEY" ] && echo -e "  Текущий ключ ip-api.com:    $(mask_key "$EXISTING_IPAPI_KEY")"
    [ -n "$EXISTING_PROXY" ] && echo -e "  Текущий прокси:             $(mask_key "$EXISTING_PROXY")"
    [ -n "$EXISTING_MODE" ] && echo -e "  Текущий режим интеграции:   $EXISTING_MODE"
    echo -e "${B_YELLOW}При обновлении можно оставить значения без изменений (Enter) или задать новые.${NC}"
fi

# Значения, которые можно подстроить в $CONF вручную; при повторной установке сохраняются
BAN_TTL="${BAN_TTL:-604800}"
OK_TTL="${OK_TTL:-43200}"
ERR_TTL="${ERR_TTL:-600}"
MAX_CLASSIFY="${MAX_CLASSIFY:-20}"
WL_INTERVAL="${WL_INTERVAL:-3600}"
LOG_FILE="${LOG_FILE:-/usr/local/x-ui/access.log}"

# --- Запрос API Key для proxycheck.io (ввод скрыт) ---
echo -e "${B_YELLOW}API Key от proxycheck.io (Enter — оставить текущий, '-' — очистить, иначе новый ключ):${NC}"
read -r -s -p "Ключ proxycheck.io: " API_KEY_INPUT; echo
if [ "$API_KEY_INPUT" = "-" ]; then
    API_KEY=""
else
    API_KEY="${API_KEY_INPUT:-$EXISTING_API_KEY}"
fi

# --- Запрос API Key для ip-api.com (опционально, для Pro-тарифа с HTTPS) ---
echo -e "${B_YELLOW}API Key от ip-api.com Pro (Enter — оставить текущий, '-' — очистить, иначе новый ключ):${NC}"
read -r -s -p "Ключ ip-api.com: " IPAPI_KEY_INPUT; echo
if [ "$IPAPI_KEY_INPUT" = "-" ]; then
    IPAPI_KEY=""
else
    IPAPI_KEY="${IPAPI_KEY_INPUT:-$EXISTING_IPAPI_KEY}"
fi

# --- Запрос прокси для обхода блокировки proxycheck.io/ip-api.com/GitHub ---
# Поддерживаются схемы curl: socks5h://, socks5://, socks4://, http://, https://
echo -e "${B_YELLOW}Прокси для запросов к proxycheck.io/ip-api.com/GitHub, например socks5h://user:pass@ip:port (Enter — оставить текущий, '-' — очистить, иначе новое значение):${NC}"
read -r -s -p "Прокси: " PROXY_INPUT; echo
if [ "$PROXY_INPUT" = "-" ]; then
    PROXY=""
else
    PROXY="${PROXY_INPUT:-$EXISTING_PROXY}"
fi

# -----------------------------

echo -e "\nВыберите метод интеграции:"
echo -e "1) UFW (правило ipset в before.rules)"
echo -e "2) iptables (правило ipset в таблице raw)"
if [ -n "$EXISTING_MODE" ]; then
    read -r -p "Ваш выбор [1-2] (Enter — оставить текущий: $EXISTING_MODE): " FW_CHOICE
    if [ -z "$FW_CHOICE" ]; then
        case "$EXISTING_MODE" in
            ufw) FW_CHOICE=1 ;;
            iptables) FW_CHOICE=2 ;;
        esac
    fi
else
    read -r -p "Ваш выбор [1-2]: " FW_CHOICE
fi

case $FW_CHOICE in
    1) MODE="ufw" ;;
    2) MODE="iptables" ;;
    *) echo "Неверный выбор. Выход."; exit 1 ;;
esac

# ------------------------------------------------------------
# Установка пакетов
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

if [ "$MODE" = "ufw" ]; then
    if ! command -v ufw >/dev/null; then
        echo -e "${B_YELLOW}Установка UFW...${NC}"
        apt-get update -qq && apt-get install -y ufw -qq
    fi
    # iptables-persistent перезаписывал бы правила UFW
    if dpkg -l | grep -q iptables-persistent; then
        echo -e "${B_YELLOW}Удаление конфликтующего iptables-persistent...${NC}"
        apt-get purge -y iptables-persistent -qq
    fi
else
    echo -e "${B_YELLOW}Настройка компонентов iptables...${NC}"
    mkdir -p /etc/iptables
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    apt-get update -qq && apt-get install -y iptables iptables-persistent -qq
fi

echo -e "${B_YELLOW}Установка ipset, curl, jq, logrotate...${NC}"
apt-get update -qq && apt-get install -y ipset curl jq logrotate -qq
if ! command -v ipset >/dev/null || ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
    echo -e "${B_RED}Не удалось установить ipset, curl или jq. Выход, старые правила не тронуты.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# Резервные копии всего, что будем менять (в папке права 700: там могут быть ключи)
# ------------------------------------------------------------
install -d -m 700 "$CONF_DIR" "$STATE_DIR" "$BACKUP_DIR"

backup_file() {
    [ -e "$1" ] || return 0
    cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}

for f in "$S" "$CONF" "$WHITELIST_TARGET" "$OLD_REASSESSED" \
         /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/before.rules /etc/ufw/before6.rules \
         /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    backup_file "$f"
done
crontab -l > "$BACKUP_DIR/crontab" 2>/dev/null
command -v iptables-save >/dev/null && iptables-save > "$BACKUP_DIR/iptables-save.v4" 2>/dev/null
command -v ip6tables-save >/dev/null && ip6tables-save > "$BACKUP_DIR/ip6tables-save.v6" 2>/dev/null
echo -e "${B_YELLOW}Резервные копии на время миграции: $BACKUP_DIR (удалятся после успешной проверки)${NC}"

# ------------------------------------------------------------
# Конфиг с секретами: права 600, значения записываются через printf %q
# ------------------------------------------------------------
{
    echo "# Конфигурация NLB. Файл содержит ключи, права 600."
    echo "# BAN_TTL: срок бана, секунды. OK_TTL: срок кэша мобильных адресов."
    echo "# ERR_TTL: срок кэша при недоступности сервисов. MAX_CLASSIFY: проверок за один запуск."
    printf 'MODE=%q\n' "$MODE"
    printf 'API_KEY=%q\n' "$API_KEY"
    printf 'IPAPI_KEY=%q\n' "$IPAPI_KEY"
    printf 'PROXY=%q\n' "$PROXY"
    printf 'BAN_TTL=%q\n' "$BAN_TTL"
    printf 'OK_TTL=%q\n' "$OK_TTL"
    printf 'ERR_TTL=%q\n' "$ERR_TTL"
    printf 'MAX_CLASSIFY=%q\n' "$MAX_CLASSIFY"
    printf 'WL_INTERVAL=%q\n' "$WL_INTERVAL"
    printf 'LOG_FILE=%q\n' "$LOG_FILE"
} > "$CONF.new"
chmod 600 "$CONF.new"
mv "$CONF.new" "$CONF"

# --- Ротация логов: храним только последние 7 дней, чтобы не раздувать диск ---
cat << 'LOGROTATE_EOF' > /etc/logrotate.d/nlb
/var/log/nlb_update.log /var/log/nlb_decisions.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE_EOF

# ------------------------------------------------------------------
# Обновлятор. Секретов внутри нет: всё читается из /etc/nlb/nlb.conf
# Подкоманды: update (по умолчанию) | restore | whitelist | ensure-rules | import-bans
# ------------------------------------------------------------------
cat << 'UPDATER_EOF' > "$S"
#!/bin/bash

CONF="/etc/nlb/nlb.conf"
if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

MODE="${MODE:-iptables}"
API_KEY="${API_KEY:-}"
IPAPI_KEY="${IPAPI_KEY:-}"
PROXY="${PROXY:-}"
BAN_TTL="${BAN_TTL:-604800}"
OK_TTL="${OK_TTL:-43200}"
ERR_TTL="${ERR_TTL:-600}"
MAX_CLASSIFY="${MAX_CLASSIFY:-20}"
WL_INTERVAL="${WL_INTERVAL:-3600}"
LOG_FILE="${LOG_FILE:-/usr/local/x-ui/access.log}"

WHITELIST_FILE="/usr/local/etc/nlb_whitelist.txt"
WHITELIST_URL="https://raw.githubusercontent.com/sngvy/NLBInstaller/main/nlb_whitelist.txt"
STATE_DIR="/var/lib/nlb"
SAVE_FILE="$STATE_DIR/ipsets.save"
LOG_STATE="$STATE_DIR/log.state"
PENDING="$STATE_DIR/pending.list"
WL_STAMP="$STATE_DIR/wl.checked"
DECISIONS_LOG="/var/log/nlb_decisions.log"
MAX_LOG_BYTES=20971520
FIRST_RUN_BYTES=131072

BAN4="nlb_ban_v4"; BAN6="nlb_ban_v6"
OK4="nlb_ok_v4";   OK6="nlb_ok_v6"
WL4="nlb_wl_v4";   WL6="nlb_wl_v6"
ALL_SETS="$BAN4 $BAN6 $OK4 $OK6 $WL4 $WL6"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
dlog() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$DECISIONS_LOG"; }

CMD="${1:-update}"
DIRTY=0

mkdir -p "$STATE_DIR"
if ! command -v ipset >/dev/null; then
    log "[ERROR] ipset не найден"
    exit 1
fi

# Не даём запускаться параллельно с предыдущей ещё не завершившейся копией
exec 200>/var/lock/update-nlb.lock
if [ "$CMD" = "update" ]; then
    flock -n 200 || exit 0
else
    flock -w 120 200 || { log "[ERROR] Не удалось получить блокировку"; exit 1; }
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ------------------------------------------------------------------
# Наборы ipset. Таймаут задаётся для каждой записи при добавлении,
# поэтому параметры наборов не зависят от значений в конфиге.
# ------------------------------------------------------------------
create_sets() {
    ipset create -exist "$BAN4" hash:ip family inet  timeout 0 maxelem 262144
    ipset create -exist "$BAN6" hash:ip family inet6 timeout 0 maxelem 262144
    ipset create -exist "$OK4"  hash:ip family inet  timeout 0 maxelem 262144
    ipset create -exist "$OK6"  hash:ip family inet6 timeout 0 maxelem 262144
    ipset create -exist "$WL4"  hash:net family inet  maxelem 65536
    ipset create -exist "$WL6"  hash:net family inet6 maxelem 65536
}

restore_sets() {
    if [ -s "$SAVE_FILE" ]; then
        ipset restore -exist < "$SAVE_FILE" || log "[WARN] Не удалось полностью восстановить $SAVE_FILE"
    fi
}

save_sets() {
    local s
    {
        for s in $ALL_SETS; do ipset save "$s"; done
    } > "$SAVE_FILE.tmp" && mv "$SAVE_FILE.tmp" "$SAVE_FILE"
    chmod 600 "$SAVE_FILE"
}

# sets_for <ip>: выбирает наборы по семейству адреса
sets_for() {
    if [[ "$1" == *:* ]]; then
        S_BAN="$BAN6"; S_OK="$OK6"; S_WL="$WL6"
    else
        S_BAN="$BAN4"; S_OK="$OK4"; S_WL="$WL4"
    fi
}

# Атомарная замена содержимого набора hash:net: наполняем временный и меняем местами
load_set() {
    local set="$1" fam="$2" file="$3" tmp="${1}_tmp" net
    ipset destroy "$tmp" 2>/dev/null
    ipset create "$tmp" hash:net family "$fam" maxelem 65536 || return 1
    if [ -s "$file" ]; then
        if ! sed "s/^/add $tmp /" "$file" | ipset restore -exist 2>/dev/null; then
            log "[WARN] Пакетная загрузка в $set не прошла, добавляю записи по одной"
            ipset flush "$tmp"
            while IFS= read -r net; do
                ipset add -exist "$tmp" "$net" 2>/dev/null || log "[WARN] Пропущена запись: $net"
            done < "$file"
        fi
    fi
    if ! ipset swap "$tmp" "$set"; then
        ipset destroy "$tmp" 2>/dev/null
        return 1
    fi
    ipset destroy "$tmp"
}

# ------------------------------------------------------------------
# curl: адрес и прокси передаются через stdin (-K -), чтобы ключи
# и пароль прокси не были видны в списке процессов
# ------------------------------------------------------------------
cfg_esc() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

curl_get() {
    {
        printf 'url = "%s"\n' "$(cfg_esc "$1")"
        [ -n "$PROXY" ] && printf 'proxy = "%s"\n' "$(cfg_esc "$PROXY")"
        true
    } | curl -fs --max-time "$2" -K -
}

# ------------------------------------------------------------------
# Whitelist: скачиваем не чаще WL_INTERVAL, пересобираем файл как раньше
# (версия из репозитория + локальные подсети, которых там нет),
# при изменениях загружаем в ipset и снимаем баны с попавших в whitelist.
# ------------------------------------------------------------------
split_cidrs() {  # файл, файл v4, файл v6, минимальный префикс v4, v6
    awk -v f4="$2" -v f6="$3" -v m4="$4" -v m6="$5" '
    {
        gsub(/\r/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
        if ($0 == "" || $0 ~ /^#/) next
        s = $0; p = ""
        i = index(s, "/")
        if (i) { p = substr(s, i + 1); s = substr(s, 1, i - 1); if (p !~ /^[0-9]+$/) next }
        if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            n = split(s, a, ".")
            for (k = 1; k <= n; k++) if (a[k] + 0 > 255) next
            if (p == "") p = 32
            if (p + 0 < m4 || p + 0 > 32) next
            print s "/" p >> f4
        } else if (s ~ /^[0-9a-fA-F:]+$/ && s ~ /:.*:/) {
            if (p == "") p = 128
            if (p + 0 < m6 || p + 0 > 128) next
            print s "/" p >> f6
        }
    }' "$1"
}

load_whitelist_sets() {
    local v4="$TMP_DIR/wl4" v6="$TMP_DIR/wl6"
    : > "$v4"; : > "$v6"
    [ -f "$WHITELIST_FILE" ] && split_cidrs "$WHITELIST_FILE" "$v4" "$v6" 8 16
    load_set "$WL4" inet "$v4" && load_set "$WL6" inet6 "$v6"
}

prune_whitelisted_bans() {
    local pair ban wl ip
    for pair in "$BAN4:$WL4" "$BAN6:$WL6"; do
        ban="${pair%%:*}"; wl="${pair##*:}"
        ipset save "$ban" 2>/dev/null | awk '$1 == "add" {print $3}' | while read -r ip; do
            if ipset test "$wl" "$ip" &>/dev/null; then
                ipset del "$ban" "$ip" 2>/dev/null && dlog "$ip в whitelist, бан снят"
            fi
        done
    done
}

build_whitelist() {  # файл с версией из репозитория; возвращает 0, если локальный файл изменился
    local remote="$1" newf="$TMP_DIR/wl.new" local_only=""
    cp "$remote" "$newf"
    [ -n "$(tail -c 1 "$newf")" ] && echo >> "$newf"
    if [ -f "$WHITELIST_FILE" ]; then
        local_only=$(awk '
            function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
            NR == FNR { r[trim($0)] = 1; next }
            { s = trim($0); if (s != "" && s !~ /^#/ && !(s in r) && !(s in seen)) { seen[s] = 1; print s } }
        ' "$remote" "$WHITELIST_FILE")
    fi
    if [ -n "$local_only" ]; then
        {
            echo
            echo "# --- Пользовательские дополнения (сохранены при пересборке) ---"
            echo "$local_only"
        } >> "$newf"
    fi
    if [ -f "$WHITELIST_FILE" ] && cmp -s "$newf" "$WHITELIST_FILE"; then
        return 1
    fi
    mkdir -p "$(dirname "$WHITELIST_FILE")"
    cat "$newf" > "$WHITELIST_FILE"
    PRESERVED=$(echo -n "$local_only" | grep -c .)
    return 0
}

refresh_whitelist() {  # аргумент force — игнорировать интервал
    local now remote changed=0 empty=0
    now=$(date +%s)
    if [ "$1" != "force" ] && [ -f "$WHITELIST_FILE" ] && [ -f "$WL_STAMP" ] \
       && [ $((now - $(stat -c %Y "$WL_STAMP"))) -lt "$WL_INTERVAL" ]; then
        return 0
    fi
    remote="$TMP_DIR/wl.remote"
    if curl_get "$WHITELIST_URL" 20 > "$remote" 2>/dev/null && [ -s "$remote" ]; then
        touch "$WL_STAMP"
        PRESERVED=0
        if build_whitelist "$remote"; then
            changed=1
            log "[SUCCESS] Whitelist пересобран из репозитория, сохранено пользовательских подсетей: ${PRESERVED:-0}"
        fi
    else
        log "[WARN] Не удалось скачать whitelist из репозитория, работаю с текущим локальным файлом"
        # повторная попытка через 10 минут
        touch -d "@$((now - WL_INTERVAL + 600))" "$WL_STAMP"
        [ -f "$WHITELIST_FILE" ] || { mkdir -p "$(dirname "$WHITELIST_FILE")"; : > "$WHITELIST_FILE"; }
    fi
    # Загружаем в ipset при изменении файла, при принудительном запуске и если наборы пусты
    if [ "$changed" -eq 1 ] || [ "$1" = "force" ]; then
        load_whitelist_sets && prune_whitelisted_bans
        DIRTY=1
    elif [ -s "$WHITELIST_FILE" ]; then
        empty=$(ipset list -t "$WL4" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
        if [ "${empty:-0}" -eq 0 ]; then
            load_whitelist_sets
            DIRTY=1
        fi
    fi
}

# ------------------------------------------------------------------
# classify_ip <ip>
# Запрашивает proxycheck.io и ip-api.com одновременно.
# Логика прежняя: если хотя бы один сервис считает адрес мобильным
# (proxycheck: Wireless, либо ip-api: mobile=true) — не блокируем.
# Блокируем, только если ни один не подтвердил мобильность и хотя бы
# один явно подтвердил, что адрес не мобильный. Приоритета сервисов нет.
# Результат в переменной VERDICT: block | mobile | unknown
# ------------------------------------------------------------------
if [ -n "$API_KEY" ]; then
    PC_URL_TPL="https://proxycheck.io/v2/@IP@?key=$API_KEY&vpn=1&asn=1"
else
    PC_URL_TPL="https://proxycheck.io/v2/@IP@?vpn=1&asn=1"
fi
# Pro-тариф (ключ задан) работает по HTTPS, бесплатный — только HTTP.
if [ -n "$IPAPI_KEY" ]; then
    IPAPI_URL_TPL="https://pro.ip-api.com/json/@IP@?key=$IPAPI_KEY&fields=status,message,mobile,proxy,hosting,query"
else
    IPAPI_URL_TPL="http://ip-api.com/json/@IP@?fields=status,message,mobile,proxy,hosting,query"
fi

classify_ip() {
    local ip="$1" safe_ip="${1//:/%3A}" d pc_json ipapi_json pc_type ipapi_status ipapi_mobile
    local pc_says_mobile="false" pc_says_not_mobile="false"
    local ipapi_says_mobile="false" ipapi_says_not_mobile="false" decision_ru
    d=$(mktemp -d "$TMP_DIR/c.XXXXXX")

    curl_get "${PC_URL_TPL//@IP@/$safe_ip}" 5 > "$d/pc" 2>/dev/null &
    curl_get "${IPAPI_URL_TPL//@IP@/$safe_ip}" 5 > "$d/ia" 2>/dev/null &
    wait

    pc_json=$(cat "$d/pc"); ipapi_json=$(cat "$d/ia")
    rm -rf "$d"

    pc_type=$(echo "$pc_json" | jq -r --arg ip "$ip" '.[$ip].type // "Unknown"' 2>/dev/null)
    pc_type="${pc_type:-Unknown}"
    [ "$pc_type" = "Wireless" ] && pc_says_mobile="true"
    { [ "$pc_type" = "Business" ] || [ "$pc_type" = "Residential" ]; } && pc_says_not_mobile="true"

    ipapi_status=$(echo "$ipapi_json" | jq -r '.status // "fail"' 2>/dev/null)
    ipapi_status="${ipapi_status:-fail}"
    ipapi_mobile=$(echo "$ipapi_json" | jq -r '.mobile // false' 2>/dev/null)
    ipapi_mobile="${ipapi_mobile:-false}"
    if [ "$ipapi_status" = "success" ]; then
        [ "$ipapi_mobile" = "true" ] && ipapi_says_mobile="true"
        [ "$ipapi_mobile" != "true" ] && ipapi_says_not_mobile="true"
    fi

    # Свод решений: OR по "мобильный", без приоритета сервисов
    if [ "$pc_says_mobile" = "true" ] || [ "$ipapi_says_mobile" = "true" ]; then
        VERDICT="mobile"; decision_ru="не блокировать"
    elif [ "$pc_says_not_mobile" = "true" ] || [ "$ipapi_says_not_mobile" = "true" ]; then
        VERDICT="block"; decision_ru="блокировать"
    else
        VERDICT="unknown"; decision_ru="не блокировать"
    fi

    if [ -z "$pc_json" ] && [ "$ipapi_status" = "fail" ]; then
        dlog "[ERROR] $ip proxycheck и ip-api недоступны, решение по умолчанию: $decision_ru"
    else
        dlog "$ip proxycheck=$pc_type ip-api=$ipapi_mobile → $decision_ru"
    fi
}

# ------------------------------------------------------------------
# Чтение только новых строк лога: запоминаем inode и позицию.
# Ротация или усечение файла — читаем с начала. Неполная последняя
# строка остаётся до следующего запуска.
# ------------------------------------------------------------------
read_new_log() {  # $1 — файл для новых строк; результат: NEW_STATE
    local out="$1" inode size off prev_inode="" n lastline
    : > "$out"
    NEW_STATE=""
    [ -r "$LOG_FILE" ] || return 0
    inode=$(stat -c %i "$LOG_FILE"); size=$(stat -c %s "$LOG_FILE")
    off=""
    [ -f "$LOG_STATE" ] && read -r prev_inode off < "$LOG_STATE"

    if [ -z "$prev_inode" ]; then
        # первый запуск: смотрим только хвост лога
        off=$((size > FIRST_RUN_BYTES ? size - FIRST_RUN_BYTES : 0))
    elif [ "$prev_inode" != "$inode" ] || [ "${off:-0}" -gt "$size" ]; then
        off=0
    fi
    off="${off:-0}"
    [ $((size - off)) -gt "$MAX_LOG_BYTES" ] && off=$((size - MAX_LOG_BYTES))

    n=$((size - off))
    if [ "$n" -le 0 ]; then
        NEW_STATE="$inode $off"
        return 0
    fi
    tail -c +$((off + 1)) "$LOG_FILE" | head -c "$n" > "$out"
    if [ -n "$(tail -c 1 "$out")" ]; then
        lastline=$(tail -n 1 "$out" | wc -c)
        head -c $((n - lastline)) "$out" > "$out.t" && mv "$out.t" "$out"
        n=$((n - lastline))
    fi
    NEW_STATE="$inode $((off + n))"
}

# Из строк лога достаём уникальные публичные адреса клиентов
extract_ips() {
    awk '{print $4}' | sed -E 's/^(tcp|udp)://; s/:[0-9]+$//; s/^::[fF]{4}://' | tr -d '[]' | awk '
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            split($0, o, ".")
            for (i = 1; i <= 4; i++) if (o[i] + 0 > 255) next
            if (o[1] == 0 || o[1] == 10 || o[1] == 127 || o[1] >= 224) next
            if (o[1] == 169 && o[2] == 254) next
            if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) next
            if (o[1] == 192 && o[2] == 168) next
            if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) next
            if (!seen[$0]++) print
            next
        }
        /^[0-9a-fA-F:]+$/ && /:.*:/ {
            l = tolower($0)
            if (l == "::1" || l == "::") next
            if (l ~ /^fe[89ab][0-9a-f]:/ || l ~ /^f[cd][0-9a-f][0-9a-f]:/) next
            if (!seen[l]++) print l
        }'
}

# ------------------------------------------------------------------
# Правила iptables (только режим iptables). В режиме ufw правила лежат
# в before.rules и ссылаются на наборы по имени.
# ------------------------------------------------------------------
ensure_iptables_rules() {
    iptables -t raw -C PREROUTING -m set --match-set "$BAN4" src -j DROP 2>/dev/null || \
        iptables -t raw -I PREROUTING 1 -m set --match-set "$BAN4" src -j DROP
    ip6tables -t raw -C PREROUTING -m set --match-set "$BAN6" src -j DROP 2>/dev/null || \
        ip6tables -t raw -I PREROUTING 1 -m set --match-set "$BAN6" src -j DROP 2>/dev/null
    return 0
}

# ------------------------------------------------------------------
# Подкоманды
# ------------------------------------------------------------------
cmd_import_bans() {  # stdin: адреса старых банов, по одному в строке
    local n=0 ip
    create_sets
    while read -r ip; do
        ip="${ip%/32}"; ip="${ip%/128}"
        # Старый скрипт банил только одиночные адреса; сети (с другим префиксом) не переносим
        [ -z "$ip" ] || [[ "$ip" == */* ]] && continue
        sets_for "$ip"
        ipset test "$S_WL" "$ip" &>/dev/null && continue
        ipset add -exist "$S_BAN" "$ip" timeout "$BAN_TTL" 2>/dev/null && n=$((n + 1))
    done
    save_sets
    echo "$n"
}

cmd_update() {
    local chunk="$TMP_DIR/chunk" cand="$TMP_DIR/cand" pend_new="$TMP_DIR/pend.new"
    local ip processed=0 banned=0 total=0

    create_sets
    refresh_whitelist
    [ "$MODE" = "iptables" ] && ensure_iptables_rules

    read_new_log "$chunk"
    { [ -s "$PENDING" ] && cat "$PENDING"; extract_ips < "$chunk"; } | awk 'NF && !s[$0]++' > "$cand"
    : > "$pend_new"

    while read -r ip <&3; do
        sets_for "$ip"
        ipset test "$S_WL"  "$ip" &>/dev/null && continue
        ipset test "$S_BAN" "$ip" &>/dev/null && continue
        ipset test "$S_OK"  "$ip" &>/dev/null && continue
        total=$((total + 1))
        if [ "$processed" -ge "$MAX_CLASSIFY" ]; then
            echo "$ip" >> "$pend_new"
            continue
        fi
        processed=$((processed + 1))
        classify_ip "$ip"
        case "$VERDICT" in
            block)  ipset add -exist "$S_BAN" "$ip" timeout "$BAN_TTL"; banned=$((banned + 1)) ;;
            mobile) ipset add -exist "$S_OK"  "$ip" timeout "$OK_TTL" ;;
            *)      ipset add -exist "$S_OK"  "$ip" timeout "$ERR_TTL" ;;
        esac
        DIRTY=1
    done 3< "$cand"

    cat "$pend_new" > "$PENDING"
    [ -n "$NEW_STATE" ] && echo "$NEW_STATE" > "$LOG_STATE"
    if [ ! -s "$SAVE_FILE" ]; then DIRTY=1; fi
    [ "$DIRTY" -eq 1 ] && save_sets
    [ "$processed" -gt 0 ] && dlog "[INFO] проверено адресов: $processed, забанено: $banned, в очереди: $(wc -l < "$PENDING")"
    return 0
}

case "$CMD" in
    update)       cmd_update ;;
    restore)      create_sets; restore_sets ;;
    whitelist)    create_sets; refresh_whitelist force; save_sets ;;
    ensure-rules) create_sets; ensure_iptables_rules ;;
    import-bans)  cmd_import_bans ;;
    *) echo "Использование: $0 [update|restore|whitelist|ensure-rules|import-bans]"; exit 1 ;;
esac
UPDATER_EOF

chmod 700 "$S"

# ------------------------------------------------------------
# Служба, которая создаёт наборы до загрузки файрвола. Без неё правила
# с --match-set не загрузятся после ребута (iptables-restore падает
# целиком, если набора ещё нет).
# ------------------------------------------------------------
cat << EOF > /etc/systemd/system/nlb-ipset.service
[Unit]
Description=Create and restore NLB ipsets before firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ufw.service netfilter-persistent.service iptables.service ip6tables.service
Wants=network-pre.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$S restore

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nlb-ipset.service >/dev/null 2>&1

# ------------------------------------------------------------
# Первый запуск: наборы, whitelist, перенос старых банов.
# Старые правила пока не трогаем.
# ------------------------------------------------------------
"$S" restore
echo -e "${B_YELLOW}Загрузка whitelist...${NC}"
"$S" whitelist

collect_legacy_bans() {
    local plain="NLB-Block" hex f cmd
    hex=$(printf '%s' "$plain" | od -An -tx1 | tr -d ' \n')
    # UFW: правила с комментарием NLB-Block (в user.rules он хранится в hex-виде)
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        [ -f "$f" ] || continue
        awk -v plain="$plain" -v hex="$hex" '
            $1 == "###" && $2 == "tuple" && (index(tolower($0), hex) || index($0, plain)) {
                for (i = 7; i <= NF; i++)
                    if ($i ~ /^[0-9a-fA-F.:]+(\/[0-9]+)?$/ && $i != "0.0.0.0/0" && $i != "::/0") { print $i; break }
            }' "$f" >> "$IMPORT_FILE"
    done
    # iptables: простые правила "-A PREROUTING -s <адрес> -j DROP" в таблице raw
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null || continue
        $cmd -t raw -S PREROUTING 2>/dev/null | awk '$1 == "-A" && $3 == "-s" && $5 == "-j" && $6 == "DROP" && NF == 6 {print $4}' >> "$IMPORT_FILE"
    done
}

remove_legacy_ufw_nlb() {
    local plain="NLB-Block" hex f before after
    hex=$(printf '%s' "$plain" | od -An -tx1 | tr -d ' \n')
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        [ -f "$f" ] || continue
        before=$(grep -c '^### tuple ###' "$f")
        awk -v plain="$plain" -v hex="$hex" '
            /^### tuple ###/ { skip = (index(tolower($0), hex) || index($0, plain)) ? 1 : 0 }
            /^$/ { if (skip) { skip = 0; next } }
            { if (!skip) print }
        ' "$f" > "$f.new" && cat "$f.new" > "$f"
        rm -f "$f.new"
        after=$(grep -c '^### tuple ###' "$f")
        [ "$before" != "$after" ] && echo -e "${B_YELLOW}$f: удалено старых правил NLB: $((before - after))${NC}"
    done
}

remove_legacy_raw_rules() {
    local cmd src
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null || continue
        $cmd -t raw -S PREROUTING 2>/dev/null | awk '$1 == "-A" && $3 == "-s" && $5 == "-j" && $6 == "DROP" && NF == 6 {print $4}' | while read -r src; do
            $cmd -t raw -D PREROUTING -s "$src" -j DROP 2>/dev/null
        done
    done
}

remove_set_raw_rules() {
    iptables -t raw -D PREROUTING -m set --match-set "$BAN4" src -j DROP 2>/dev/null
    ip6tables -t raw -D PREROUTING -m set --match-set "$BAN6" src -j DROP 2>/dev/null
    return 0
}

collect_legacy_bans
IMPORTED=$("$S" import-bans < "$IMPORT_FILE")
[ "${IMPORTED:-0}" -gt 0 ] && echo -e "${B_YELLOW}Перенесено старых банов в ipset: $IMPORTED (срок бана: $((BAN_TTL / 86400)) сут.)${NC}"

echo -e "${B_YELLOW}Первая проверка новых подключений...${NC}"
"$S" update

# ------------------------------------------------------------
# UFW: before.rules
# ------------------------------------------------------------
setup_ipset_block_ufw() {
    echo -e "${B_YELLOW}Подключение набора NLB к UFW (before.rules)...${NC}"
    local f chain set tmp
    for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        [ -f "$f" ] || continue
        if [[ "$f" == *before6.rules ]]; then
            chain="ufw6-before-input"; set="nlb_ban_v6"
        else
            chain="ufw-before-input"; set="nlb_ban_v4"
        fi

        # Убираем прошлую версию блока, чтобы повторный запуск не плодил дубли
        sed -i '/# --- NLB-IPSet: begin ---/,/# --- NLB-IPSet: end ---/d' "$f"

        tmp=$(mktemp)
        if grep -q '^# End required lines' "$f"; then
            awk -v chain="$chain" -v set="$set" '
                { print }
                /^# End required lines/ && !done {
                    print "# --- NLB-IPSet: begin ---"
                    print "-A " chain " -m set --match-set " set " src -j DROP"
                    print "# --- NLB-IPSet: end ---"
                    done = 1
                }
            ' "$f" > "$tmp"
        else
            echo -e "${B_YELLOW}В $f нет маркера '# End required lines', вставляю перед COMMIT (проверьте порядок правил).${NC}"
            awk -v chain="$chain" -v set="$set" '
                /^COMMIT/ && !done {
                    print "# --- NLB-IPSet: begin ---"
                    print "-A " chain " -m set --match-set " set " src -j DROP"
                    print "# --- NLB-IPSet: end ---"
                    done = 1
                }
                { print }
            ' "$f" > "$tmp"
        fi
        cat "$tmp" > "$f"
        rm -f "$tmp"
    done
}

remove_ipset_block_ufw() {
    local f
    for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        [ -f "$f" ] || continue
        sed -i '/# --- NLB-IPSet: begin ---/,/# --- NLB-IPSet: end ---/d' "$f"
    done
}

restore_ufw_backups() {
    local f
    for f in user.rules user6.rules before.rules before6.rules; do
        [ -e "$BACKUP_DIR/_etc_ufw_$f" ] && cat "$BACKUP_DIR/_etc_ufw_$f" > "/etc/ufw/$f"
    done
}

ufw_is_active() {
    ufw status 2>/dev/null | grep -q "^Status: active"
}

if [ "$MODE" = "ufw" ]; then
    remove_legacy_ufw_nlb
    setup_ipset_block_ufw

    if ufw_is_active; then
        if ! ufw reload; then
            echo -e "${B_RED}ufw reload не прошёл, возвращаю прежние файлы правил из $BACKUP_DIR${NC}"
            restore_ufw_backups
            ufw reload
            exit 1
        fi
    else
        echo -e "${B_RED}ВНИМАНИЕ: UFW сейчас не включён, правила применятся только после 'ufw enable'.${NC}"
        echo -e "${B_YELLOW}Сначала убедитесь, что разрешён SSH (ufw allow <порт>/tcp), иначе потеряете доступ.${NC}"
    fi

    # Блокировку теперь делает UFW: убираем старые правила и правило из raw
    remove_legacy_raw_rules
    remove_set_raw_rules

    systemctl enable ufw 2>/dev/null
    if systemctl is-enabled ufw &>/dev/null; then
        echo -e "${B_GREEN}UFW включён в автозагрузку, before.rules применится при ребуте.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: ufw не в автозагрузке. Выполните: ufw enable${NC}"
    fi
else
    "$S" ensure-rules
    remove_legacy_raw_rules

    # Переход с UFW на iptables: убираем наши правила из UFW
    remove_legacy_ufw_nlb
    remove_ipset_block_ufw
    command -v ufw >/dev/null && ufw_is_active && ufw reload

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

    systemctl enable netfilter-persistent 2>/dev/null || systemctl enable iptables-persistent 2>/dev/null
    systemctl restart netfilter-persistent 2>/dev/null

    if systemctl is-enabled netfilter-persistent &>/dev/null; then
        echo -e "${B_GREEN}netfilter-persistent включён, правила переживут перезагрузку.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: не удалось включить netfilter-persistent. После ребута правила iptables могут слететь!${NC}"
    fi
fi

# ------------------------------------------------------------
# Cron. Большинство запусков обходятся без сетевых запросов,
# поэтому интервал короткий. Отдельная служба на старт системы больше
# не нужна: наборы поднимает nlb-ipset.service, а cron сработает в течение пары минут.
# ------------------------------------------------------------
C_JOB="$CRON_SCHEDULE $S >> /var/log/nlb_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

if [ -f /etc/systemd/system/nlb-update.service ]; then
    systemctl disable nlb-update.service >/dev/null 2>&1
    rm -f /etc/systemd/system/nlb-update.service
    systemctl daemon-reload
    echo -e "${B_YELLOW}Старая служба nlb-update удалена: теперь её роль выполняют nlb-ipset и cron.${NC}"
fi

echo -e "${B_GREEN}NLB успешно настроен через $MODE (ipset).${NC}"
echo -e "${B_CYAN}Полезные пути:${NC}"
echo -e "  Конфиг (ключи, сроки):            $CONF"
echo -e "  Белый список (исключения):        $WHITELIST_TARGET"
echo -e "  Скрипт обновления:                $S"
echo -e "  Лог решений (proxycheck/ip-api):  /var/log/nlb_decisions.log"
echo -e "  Лог запусков по cron:             /var/log/nlb_update.log"
echo -e "  Проверка:                         ipset list -t $BAN4 | grep 'Number of entries'"

# ------------------------------------------------------------
# Проверка результата. Бэкап удаляется только если всё реально работает,
# иначе он остаётся для ручного отката.
# ------------------------------------------------------------
verify_migration() {
    local n
    ipset list -n 2>/dev/null | grep -qx "$BAN4" || { echo "нет набора $BAN4"; return 1; }
    ipset list -n 2>/dev/null | grep -qx "$BAN6" || { echo "нет набора $BAN6"; return 1; }
    if [ -s "$WHITELIST_TARGET" ]; then
        n=$(ipset list -t nlb_wl_v4 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
        [ "${n:-0}" -gt 0 ] || { echo "whitelist не загружен в ipset"; return 1; }
    fi
    if [ "${IMPORTED:-0}" -gt 0 ]; then
        n=$(ipset list -t "$BAN4" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
        m=$(ipset list -t "$BAN6" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
        [ $((${n:-0} + ${m:-0})) -gt 0 ] || { echo "старые баны не перенесены"; return 1; }
    fi
    if [ "$MODE" = "ufw" ]; then
        iptables -S ufw-before-input 2>/dev/null | grep -q "match-set $BAN4" \
            || { echo "правило ipset не найдено в ufw-before-input (UFW выключен?)"; return 1; }
    else
        iptables -t raw -C PREROUTING -m set --match-set "$BAN4" src -j DROP 2>/dev/null \
            || { echo "правило ipset не найдено в таблице raw"; return 1; }
    fi
    systemctl is-enabled nlb-ipset.service &>/dev/null \
        || { echo "nlb-ipset.service не включён"; return 1; }
    crontab -l 2>/dev/null | grep -qF "$S" || { echo "нет задания cron"; return 1; }
    return 0
}

if [ -d "$BACKUP_DIR" ]; then
    if REASON=$(verify_migration); then
        rm -rf "$BACKUP_DIR"
        rmdir "$CONF_DIR/backup" 2>/dev/null
        rm -f "$OLD_REASSESSED"
        echo -e "${B_GREEN}Миграция проверена, резервные копии удалены.${NC}"
    else
        echo -e "${B_YELLOW}Проверка не пройдена ($REASON), резервные копии оставлены: $BACKUP_DIR${NC}"
    fi
fi
