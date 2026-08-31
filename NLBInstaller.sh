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

echo -e "${B_CYAN}Конфигурация NLB (Not LTE Blocker)${NC}"

S="/usr/local/bin/update-nlb.sh"

# ------------------------------------------------------------------
# mask_key <key> -- маскирует значение ключа для безопасного вывода в терминал
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
# Обнаружение существующей установки: вытаскиваем текущие ключи и режим
# из уже развёрнутого /usr/local/bin/update-nlb.sh, если он есть.
# ------------------------------------------------------------------
EXISTING_API_KEY=""
EXISTING_IPAPI_KEY=""
EXISTING_PROXY=""
EXISTING_MODE=""

if [ -f "$S" ]; then
    echo -e "${B_YELLOW}Обнаружена существующая установка NLB ($S).${NC}"
    EXISTING_API_KEY=$(grep -oP '(?<=^API_KEY=")[^"]*' "$S" 2>/dev/null)
    EXISTING_IPAPI_KEY=$(grep -oP '(?<=^IPAPI_KEY=")[^"]*' "$S" 2>/dev/null)
    EXISTING_PROXY=$(grep -oP '(?<=^PROXY=")[^"]*' "$S" 2>/dev/null)
    EXISTING_MODE=$(grep -oP '(?<=^MODE=")[^"]*' "$S" 2>/dev/null)

    [ -n "$EXISTING_API_KEY" ] && echo -e "  Текущий ключ proxycheck.io: $(mask_key "$EXISTING_API_KEY")"
    [ -n "$EXISTING_IPAPI_KEY" ] && echo -e "  Текущий ключ ip-api.com:    $(mask_key "$EXISTING_IPAPI_KEY")"
    [ -n "$EXISTING_PROXY" ] && echo -e "  Текущий прокси:             $(mask_key "$EXISTING_PROXY")"
    [ -n "$EXISTING_MODE" ] && echo -e "  Текущий режим интеграции:   $EXISTING_MODE"
    echo -e "${B_YELLOW}При обновлении можно оставить значения без изменений (Enter) или задать новые.${NC}"
fi

# --- Запрос API Key для proxycheck.io ---
echo -e "${B_YELLOW}API Key от proxycheck.io (Enter -- оставить текущий, '-' -- очистить, иначе новый ключ):${NC}"
read -p "Ключ proxycheck.io: " API_KEY_INPUT
if [ "$API_KEY_INPUT" = "-" ]; then
    API_KEY=""
else
    API_KEY="${API_KEY_INPUT:-$EXISTING_API_KEY}"
fi

# --- Запрос API Key для ip-api.com (опционально, для Pro-тарифа с HTTPS) ---
echo -e "${B_YELLOW}API Key от ip-api.com Pro (Enter -- оставить текущий, '-' -- очистить, иначе новый ключ):${NC}"
read -p "Ключ ip-api.com: " IPAPI_KEY_INPUT
if [ "$IPAPI_KEY_INPUT" = "-" ]; then
    IPAPI_KEY=""
else
    IPAPI_KEY="${IPAPI_KEY_INPUT:-$EXISTING_IPAPI_KEY}"
fi

# --- Запрос прокси для обхода блокировки proxycheck.io/ip-api.com/GitHub ---
# Поддерживаются схемы curl: socks5h://, socks5://, socks4://, http://, https://
echo -e "${B_YELLOW}Прокси для запросов к proxycheck.io/ip-api.com/GitHub, например socks5h://user:pass@ip:port (Enter -- оставить текущий, '-' -- очистить, иначе новое значение):${NC}"
read -p "Прокси: " PROXY_INPUT
if [ "$PROXY_INPUT" = "-" ]; then
    PROXY=""
else
    PROXY="${PROXY_INPUT:-$EXISTING_PROXY}"
fi

# -----------------------------

echo -e "\nВыберите метод интеграции:"
echo -e "1) UFW (через before.rules + RAW Table)"
echo -e "2) iptables (прямая таблица RAW)"
if [ -n "$EXISTING_MODE" ]; then
    read -p "Ваш выбор [1-2] (Enter -- оставить текущий: $EXISTING_MODE): " FW_CHOICE
    if [ -z "$FW_CHOICE" ]; then
        case "$EXISTING_MODE" in
            ufw) FW_CHOICE=1 ;;
            iptables) FW_CHOICE=2 ;;
        esac
    fi
else
    read -p "Ваш выбор [1-2]: " FW_CHOICE
fi

case $FW_CHOICE in
    1)
        MODE="ufw"
        # 1. Устанавливаем UFW, если его нет
        if ! command -v ufw >/dev/null; then
            echo -e "${B_YELLOW}Установка UFW...${NC}"
            apt-get update -qq && apt-get install -y ufw -qq
        fi
        # 2. Удаляем iptables-persistent, чтобы он не перезаписывал правила UFW
        if dpkg -l | grep -q iptables-persistent; then
            echo -e "${B_YELLOW}Удаление конфликтующего iptables-persistent...${NC}"
            apt-get purge -y iptables-persistent -qq
        fi
        ;;
    2)
        MODE="iptables"
        # Для чистого iptables нам как раз нужны утилиты сохранения
        echo -e "${B_YELLOW}Настройка компонентов iptables...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        mkdir -p /etc/iptables
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        apt-get update -qq && apt-get install -y curl iptables jq iptables-persistent -qq
        ;;
    *) echo "Неверный выбор. Выход."; exit 1 ;;
esac

# Устанавливаем общие зависимости
apt-get install -y jq python3 logrotate -qq

# curl-флаг прокси
CURL_PROXY_ARGS=()
[ -n "$PROXY" ] && CURL_PROXY_ARGS=(-x "$PROXY")

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

# Кладём whitelist в целевое место, скачивая его из репозитория.
# Первичная установка -- просто копируем.
# Обновление (файл уже есть) -- пересобираем файл целиком на основе версии
# из репозитория, а все локальные подсети, которых в репозитории нет
# (в т.ч. добавленные вручную), сохраняем отдельным блоком в конце.
WHITELIST_TARGET="/usr/local/etc/nlb_whitelist.txt"
WHITELIST_SOURCE_URL="https://raw.githubusercontent.com/sngvy/NLBInstaller/main/nlb_whitelist.txt"
WHITELIST_REMOTE_TMP=$(mktemp)

mkdir -p /usr/local/etc

if curl -fsSL "${CURL_PROXY_ARGS[@]}" "$WHITELIST_SOURCE_URL" -o "$WHITELIST_REMOTE_TMP"; then
    if [ ! -f "$WHITELIST_TARGET" ]; then
        cp "$WHITELIST_REMOTE_TMP" "$WHITELIST_TARGET"
        echo -e "${B_GREEN}Whitelist загружен из репозитория: $WHITELIST_TARGET${NC}"
    else
        PRESERVED=$(python3 - "$WHITELIST_TARGET" "$WHITELIST_REMOTE_TMP" << 'PYEOF'
import sys

local_path, remote_path = sys.argv[1], sys.argv[2]

with open(remote_path) as f:
    remote_lines = [l.rstrip("\n") for l in f]
remote_set = {l.strip() for l in remote_lines if l.strip()}

try:
    with open(local_path) as f:
        local_lines = [l.rstrip("\n") for l in f]
except FileNotFoundError:
    local_lines = []

def is_entry(line):
    s = line.strip()
    return bool(s) and not s.startswith("#")

seen = set()
local_only = []
for l in local_lines:
    s = l.strip()
    if is_entry(l) and s not in remote_set and s not in seen:
        seen.add(s)
        local_only.append(l)

new_content = list(remote_lines)
if local_only:
    new_content.append("")
    new_content.append("# --- Пользовательские дополнения (сохранены при пересборке) ---")
    new_content.extend(local_only)

with open(local_path, "w") as f:
    f.write("\n".join(new_content) + "\n")

print(len(local_only))
PYEOF
)
        echo -e "${B_GREEN}Whitelist пересобран из репозитория, сохранено пользовательских подсетей: ${PRESERVED:-0}${NC}"
    fi
else
    echo -e "${B_RED}Не удалось скачать whitelist из репозитория (нет сети/файл переименован?).${NC}"
    if [ ! -f "$WHITELIST_TARGET" ]; then
        touch "$WHITELIST_TARGET"
        echo -e "${B_YELLOW}Создан пустой файл вместо него.${NC}"
    else
        echo -e "${B_YELLOW}Оставляю существующий локальный файл без изменений.${NC}"
    fi
fi
rm -f "$WHITELIST_REMOTE_TMP"

# Создаем скрипт с плейсхолдерами для MODE, API_KEY, IPAPI_KEY и PROXY
cat << 'EOF' > "$S"
#!/bin/bash

MODE="__MODE_PLACEHOLDER__"
API_KEY="__API_KEY_PLACEHOLDER__"
IPAPI_KEY="__IPAPI_KEY_PLACEHOLDER__"
PROXY="__PROXY_PLACEHOLDER__"

LOG_FILE="/usr/local/x-ui/access.log"
WHITELIST_FILE="/usr/local/etc/nlb_whitelist.txt"
DECISIONS_LOG="/var/log/nlb_decisions.log"
WHITELIST_SOURCE_URL="https://raw.githubusercontent.com/sngvy/NLBInstaller/main/nlb_whitelist.txt"

# curl-флаг прокси
CURL_PROXY_ARGS=()
[ -n "$PROXY" ] && CURL_PROXY_ARGS=(-x "$PROXY")

# ------------------------------------------------------------------
# Пересобираем локальный whitelist на основе версии из репозитория
# при каждом запуске. Все локальные подсети, которых нет в репозитории
# (в т.ч. добавленные вручную), сохраняются отдельным блоком в конце.
# Сеть недоступна/файл не скачался -- работаем с тем whitelist, что уже есть.
# ------------------------------------------------------------------
if [ -f "$WHITELIST_FILE" ]; then
    WHITELIST_REMOTE_TMP=$(mktemp)
    if curl -fsSL --max-time 10 "${CURL_PROXY_ARGS[@]}" "$WHITELIST_SOURCE_URL" -o "$WHITELIST_REMOTE_TMP" 2>/dev/null; then
        PRESERVED=$(python3 - "$WHITELIST_FILE" "$WHITELIST_REMOTE_TMP" << 'PYEOF'
import sys

local_path, remote_path = sys.argv[1], sys.argv[2]

with open(remote_path) as f:
    remote_lines = [l.rstrip("\n") for l in f]
remote_set = {l.strip() for l in remote_lines if l.strip()}

try:
    with open(local_path) as f:
        local_lines = [l.rstrip("\n") for l in f]
except FileNotFoundError:
    local_lines = []

def is_entry(line):
    s = line.strip()
    return bool(s) and not s.startswith("#")

seen = set()
local_only = []
for l in local_lines:
    s = l.strip()
    if is_entry(l) and s not in remote_set and s not in seen:
        seen.add(s)
        local_only.append(l)

new_content = list(remote_lines)
if local_only:
    new_content.append("")
    new_content.append("# --- Пользовательские дополнения (сохранены при пересборке) ---")
    new_content.extend(local_only)

with open(local_path, "w") as f:
    f.write("\n".join(new_content) + "\n")

print(len(local_only))
PYEOF
)
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] Whitelist пересобран из репозитория, сохранено пользовательских подсетей: ${PRESERVED:-0}" >> "$DECISIONS_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Не удалось скачать whitelist из репозитория, работаю с текущим локальным файлом" >> "$DECISIONS_LOG"
    fi
    rm -f "$WHITELIST_REMOTE_TMP"
fi

# --- proxycheck.io ---
BASE_URL="https://proxycheck.io/v2"
[ -n "$API_KEY" ] && PC_QUERY_URL="$BASE_URL/\$ip?key=$API_KEY&vpn=1&asn=1" || PC_QUERY_URL="$BASE_URL/\$ip?vpn=1&asn=1"

# --- ip-api.com ---
# Pro-тариф (ключ задан) работает по HTTPS, бесплатный -- только HTTP.
if [ -n "$IPAPI_KEY" ]; then
    IPAPI_QUERY_URL="https://pro.ip-api.com/json/\$ip?key=$IPAPI_KEY&fields=status,message,mobile,proxy,hosting,query"
else
    IPAPI_QUERY_URL="http://ip-api.com/json/\$ip?fields=status,message,mobile,proxy,hosting,query"
fi

# ------------------------------------------------------------------
# classify_ip <ip>
# Запрашивает proxycheck.io и ip-api.com.
# Логика: если хотя бы один сервис считает адрес мобильным
# (proxycheck: Wireless, либо ip-api: mobile=true) -- не блокируем.
# Блокируем только если ни один сервис не подтвердил мобильность,
# и хотя бы один явно подтвердил, что это не мобильный адрес.
# Приоритета между сервисами нет -- решение симметричное.
# Возвращает 0 -- блокировать, 1 -- пропустить (мобильный/неясно).
# ------------------------------------------------------------------
classify_ip() {
    local ip="$1"
    
    # Экранирование IPv6 (замена ':' на '%3A') для безопасного API-запроса через curl
    local safe_ip="${ip//:/%3A}"

    # --- Запрос к proxycheck.io ---
    local pc_url pc_json pc_type
    pc_url=$(echo "$PC_QUERY_URL" | sed "s/\$ip/$safe_ip/")
    pc_json=$(curl -s --max-time 5 "${CURL_PROXY_ARGS[@]}" "$pc_url")
    pc_type=$(echo "$pc_json" | jq -r ".\"$ip\".type // \"Unknown\"")

    local pc_says_mobile="false"
    local pc_says_not_mobile="false"
    [ "$pc_type" = "Wireless" ] && pc_says_mobile="true"
    { [ "$pc_type" = "Business" ] || [ "$pc_type" = "Residential" ]; } && pc_says_not_mobile="true"

    # --- Запрос к ip-api.com ---
    local ipapi_url ipapi_json ipapi_status ipapi_mobile
    ipapi_url=$(echo "$IPAPI_QUERY_URL" | sed "s/\$ip/$safe_ip/")
    ipapi_json=$(curl -s --max-time 5 "${CURL_PROXY_ARGS[@]}" "$ipapi_url")
    ipapi_status=$(echo "$ipapi_json" | jq -r ".status // \"fail\"")
    ipapi_mobile=$(echo "$ipapi_json" | jq -r ".mobile // false")

    local ipapi_says_mobile="false"
    local ipapi_says_not_mobile="false"
    if [ "$ipapi_status" = "success" ]; then
        [ "$ipapi_mobile" = "true" ] && ipapi_says_mobile="true"
        [ "$ipapi_mobile" != "true" ] && ipapi_says_not_mobile="true"
    fi

    # --- Свод решений: OR по "мобильный", без приоритета сервисов ---
    local final_block decision_ru
    if [ "$pc_says_mobile" = "true" ] || [ "$ipapi_says_mobile" = "true" ]; then
        final_block="false"
        decision_ru="не блокировать"
    elif [ "$pc_says_not_mobile" = "true" ] || [ "$ipapi_says_not_mobile" = "true" ]; then
        final_block="true"
        decision_ru="блокировать"
    else
        final_block="false"
        decision_ru="не блокировать"
    fi

    if [ -z "$pc_json" ] && [ "$ipapi_status" = "fail" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $ip proxycheck и ip-api недоступны, решение по умолчанию: $decision_ru" >> "$DECISIONS_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') $ip proxycheck=$pc_type ip-api=$ipapi_mobile → $decision_ru" >> "$DECISIONS_LOG"
    fi

    [ "$final_block" = "true" ] && return 0 || return 1
}

IPS=$(tail -n 500 "$LOG_FILE" 2>/dev/null | tac | awk '{print $4}' | sed -E 's/(tcp:|udp:)//g' | sed -E 's/:[0-9]+$//' | tr -d '[]' | grep -v '127.0.0.1' | awk '!x[$0]++' | head -n 10)

if [ "$MODE" = "ufw" ]; then

    # --- Разблокировка IP из белого списка ---
    if [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ]; then
        ufw status | grep 'NLB-Block' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | python3 -c "
import sys, ipaddress
networks = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            net = line.strip()
            if not net or net.startswith('#'): continue
            try: networks.append(ipaddress.ip_network(net, strict=False))
            except: pass
except: sys.exit(0)
for line in sys.stdin:
    ip_str = line.strip()
    try:
        if any(ipaddress.ip_address(ip_str) in net for net in networks): print(ip_str)
    except: pass
" "$WHITELIST_FILE" 2>/dev/null | while read -r b_ip; do
            ufw delete deny from "$b_ip" 2>/dev/null
        done
    fi
    # -----------------------------------------

    for ip in $IPS; do
        [ -z "$ip" ] && continue

        # --- Проверка белого списка ---
        if [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ]; then
            if python3 -c "
import sys, ipaddress
ip = sys.argv[1]
networks = []
try:
    with open(sys.argv[2]) as f:
        for line in f:
            net = line.strip()
            if not net or net.startswith('#'): continue
            try: networks.append(ipaddress.ip_network(net, strict=False))
            except: pass
except: sys.exit(1)
try:
    if any(ipaddress.ip_address(ip) in net for net in networks): sys.exit(0)
except: pass
sys.exit(1)
" "$ip" "$WHITELIST_FILE" 2>/dev/null; then
                continue
            fi
        fi
        # ------------------------------

        if ! ufw status | grep -q "$ip"; then
            if classify_ip "$ip"; then
                ufw prepend deny from "$ip" comment 'NLB-Block'
            fi
        fi
    done
    ufw reload

else

    # --- Разблокировка IP из белого списка ---
    if [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ]; then
        for CMD in iptables ip6tables; do
            $CMD -t raw -S PREROUTING 2>/dev/null | grep -w DROP | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | python3 -c "
import sys, ipaddress
networks = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            net = line.strip()
            if not net or net.startswith('#'): continue
            try: networks.append(ipaddress.ip_network(net, strict=False))
            except: pass
except: sys.exit(0)
for line in sys.stdin:
    ip_str = line.strip()
    try:
        if any(ipaddress.ip_address(ip_str) in net for net in networks): print(ip_str)
    except: pass
" "$WHITELIST_FILE" 2>/dev/null | while read -r b_ip; do
                $CMD -t raw -D PREROUTING -s "$b_ip" -j DROP 2>/dev/null
            done
        done
    fi
    # -----------------------------------------

    for ip in $IPS; do
        [ -z "$ip" ] && continue

        # --- Проверка белого списка ---
        if [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ]; then
            if python3 -c "
import sys, ipaddress
ip = sys.argv[1]
networks = []
try:
    with open(sys.argv[2]) as f:
        for line in f:
            net = line.strip()
            if not net or net.startswith('#'): continue
            try: networks.append(ipaddress.ip_network(net, strict=False))
            except: pass
except: sys.exit(1)
try:
    if any(ipaddress.ip_address(ip) in net for net in networks): sys.exit(0)
except: pass
sys.exit(1)
" "$ip" "$WHITELIST_FILE" 2>/dev/null; then
                continue
            fi
        fi
        # ------------------------------

        if [[ "$ip" =~ : ]]; then
            CMD="ip6tables"
        else
            CMD="iptables"
        fi

        if ! $CMD -t raw -C PREROUTING -s "$ip" -j DROP &>/dev/null; then
            if classify_ip "$ip"; then
                $CMD -t raw -I PREROUTING -s "$ip" -j DROP 2>/dev/null
            fi
        fi
    done
    [ -d /etc/iptables ] && iptables-save > /etc/iptables/rules.v4
    [ -d /etc/iptables ] && ip6tables-save > /etc/iptables/rules.v6

fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] NLB обновлён через $MODE (ключ proxycheck: ${API_KEY:-нет}, ключ ip-api: ${IPAPI_KEY:-нет}, прокси: ${PROXY:-нет})"
EOF

# Безопасное экранирование спецсимволов (/ и &), чтобы не сломать sed
SAFE_MODE="${MODE//\//\\/}"
SAFE_MODE="${SAFE_MODE//&/\\&}"
SAFE_API="${API_KEY//\//\\/}"
SAFE_API="${SAFE_API//&/\\&}"
SAFE_IPAPI="${IPAPI_KEY//\//\\/}"
SAFE_IPAPI="${SAFE_IPAPI//&/\\&}"
SAFE_PROXY="${PROXY//\//\\/}"
SAFE_PROXY="${SAFE_PROXY//&/\\&}"

sed -i "s/__MODE_PLACEHOLDER__/$SAFE_MODE/" "$S"
sed -i "s/__API_KEY_PLACEHOLDER__/$SAFE_API/" "$S"
sed -i "s/__IPAPI_KEY_PLACEHOLDER__/$SAFE_IPAPI/" "$S"
sed -i "s/__PROXY_PLACEHOLDER__/$SAFE_PROXY/" "$S"
chmod +x "$S"

$S

C_JOB="*/15 * * * * $S >> /var/log/nlb_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

read -p $'\033[1;33mСоздать/обновить службу systemd для обновления при старте системы? [y/N]: \033[0m' SYSTEMD_CHOICE
if [[ "$SYSTEMD_CHOICE" =~ ^[Yy]$ ]]; then
cat << EOF > /etc/systemd/system/nlb-update.service
[Unit]
Description=Update NLB (Not LTE Blocker) on Boot
After=network.target

[Service]
Type=oneshot
ExecStart=$S
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nlb-update.service
    echo -e "${B_YELLOW}Служба systemd создана и включена.${NC}"
fi

echo -e "${B_GREEN}NLB успешно настроен через $MODE!${NC}"
echo -e "${B_CYAN}Полезные пути:${NC}"
echo -e "  Белый список (исключения):        $WHITELIST_TARGET"
echo -e "  Скрипт обновления:                $S"
echo -e "  Лог решений (proxycheck/ip-api):  /var/log/nlb_decisions.log"
echo -e "  Лог запусков по cron:              /var/log/nlb_update.log"
