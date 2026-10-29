#!/usr/bin/env bash
#
# sysinfo.sh — сбор и вывод информации о хосте и пользователях.
#
# Использование:
#   ./sysinfo.sh --host          информация о хосте
#   ./sysinfo.sh --user          информация о пользователях
#   ./sysinfo.sh --host --user   и то, и другое
#   ./sysinfo.sh --help          справка (то же самое, что запуск без параметров)
#
# Часть данных (имена процессов на портах, счётчики ошибок дисков) полностью
# доступна только при запуске от root: sudo ./sysinfo.sh --host

set -o nounset    # ошибка при обращении к неинициализированной переменной
set -o pipefail   # код возврата конвейера = код первой упавшей команды

SCRIPT_NAME=$(basename "$0")

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Использование: $SCRIPT_NAME [ПАРАМЕТРЫ]

Собирает и выводит информацию о хосте и/или пользователях.

Параметры:
  -H, --host   информация о хосте: ядра CPU, оперативная память, диски,
               load average, текущее время, uptime, сетевые интерфейсы,
               слушающие порты
  -u, --user   информация о пользователях: все пользователи, root-пользователи,
               залогиненные в данный момент
  -h, --help   показать эту справку

Без параметров выводится эта справка.
Параметры можно комбинировать: $SCRIPT_NAME --host --user
EOF
}

# Заголовок раздела
header() {
    printf '\n=== %s ===\n' "$1"
}

# Проверка наличия команды в системе
have() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Информация о хосте
# ---------------------------------------------------------------------------

# Количество ядер CPU: считаем строки "processor" в /proc/cpuinfo.
# Значение возвращаем через echo, а не через return: return передаёт только
# код возврата 0..255, и на машине с 256+ ядрами результат был бы неверным.
get_cpu_cores() {
    grep -c '^processor' /proc/cpuinfo
}

cpu_info() {
    header "CPU"
    echo "Количество ядер (логических): $(get_cpu_cores)"
}

# Память из /proc/meminfo (значения в КиБ).
# Использовано = MemTotal - MemAvailable — так же считает утилита free.
mem_info() {
    header "Оперативная память"
    awk '
        /^MemTotal:/     { total = $2 }
        /^MemAvailable:/ { avail = $2 }
        END {
            used = total - avail
            printf "Всего:        %.1f MiB\n", total / 1024
            printf "Использовано: %.1f MiB (%.1f%%)\n", used / 1024, used * 100 / total
            printf "Доступно:     %.1f MiB\n", avail / 1024
        }' /proc/meminfo
}

# Диски: список физических дисков (lsblk), размер, свободное место
# по смонтированным на диске файловым системам (df), счётчик ошибок ввода-вывода.
#
# В /proc/diskstats счётчика ошибок нет (там только операции чтения/записи,
# секторы и время), поэтому ошибки берём из /sys/block/<диск>/device/ioerr_cnt.
# Этот счётчик есть у SCSI/SATA-дисков; у NVMe и виртуальных дисков его нет —
# тогда выводим "n/a" (для них ошибки смотрят через smartctl).
disk_info() {
    header "Диски"

    if ! have lsblk; then
        echo "lsblk не найден, информация о дисках недоступна"
        return
    fi

    printf '%-12s %-10s %-10s %s\n' "DISK" "SIZE" "FREE" "IO_ERRORS"

    local name size dev err free
    while read -r name size; do
        dev="/dev/$name"

        # Ошибки ввода-вывода (значение хранится в hex, например 0x0)
        if [[ -r /sys/block/$name/device/ioerr_cnt ]]; then
            err=$(( $(< "/sys/block/$name/device/ioerr_cnt") ))
        else
            err="n/a"
        fi

        # Свободное место: берём точки монтирования всех разделов/томов диска,
        # получаем по ним размер и свободное место из df, убираем дубли
        # (одна ФС может быть смонтирована несколько раз) и считаем процент.
        free=$(lsblk -lnpo MOUNTPOINT "$dev" 2>/dev/null \
            | grep -v -e '^$' -e '^\[SWAP\]$' \
            | xargs -r -d '\n' df -P -B1 --output=source,size,avail 2>/dev/null \
            | awk 'NR > 1 && !seen[$1]++ { size += $2; avail += $3 }
                   END { if (size > 0) printf "%.1f%%", avail * 100 / size; else print "-" }')

        printf '%-12s %-10s %-10s %s\n' "$name" "$size" "$free" "$err"
    done < <(lsblk -dno NAME,SIZE,TYPE | awk '$3 == "disk" { print $1, $2 }')

    echo "FREE — свободно на смонтированных ФС диска; '-' — ФС с диска не смонтированы"
}

# Средняя загрузка за 1, 5 и 15 минут — первые три поля /proc/loadavg
load_info() {
    header "Load average"
    local l1 l5 l15
    read -r l1 l5 l15 _ < /proc/loadavg
    echo "1 мин: $l1   5 мин: $l5   15 мин: $l15"
}

time_info() {
    header "Текущее время"
    date '+%Y-%m-%d %H:%M:%S %Z'
}

# Uptime: первое поле /proc/uptime — секунды с момента загрузки
uptime_info() {
    header "Uptime"
    local up days hours mins
    read -r up _ < /proc/uptime
    up=${up%.*}                      # отбрасываем дробную часть
    days=$(( up / 86400 ))
    hours=$(( up % 86400 / 3600 ))
    mins=$(( up % 3600 / 60 ))
    echo "Система работает: ${days} д. ${hours} ч. ${mins} мин."
}

# Сетевые интерфейсы.
# Формат /proc/net/dev (после двух строк заголовка):
#   iface: rx_bytes rx_packets rx_errs rx_drop rx_fifo rx_frame rx_compressed rx_multicast
#          tx_bytes tx_packets tx_errs ...
# Статус — из /sys/class/net/<iface>/operstate, IP-адреса — из `ip addr`.
net_info() {
    header "Сетевые интерфейсы"
    printf '%-14s %-9s %12s %8s %12s %8s  %s\n' \
        "IFACE" "STATE" "RX_PACKETS" "RX_ERR" "TX_PACKETS" "TX_ERR" "IP"

    local ifc rxp rxe txp txe state ips
    # sed заменяет ':' после имени на пробел (у больших счётчиков пробела может не быть)
    tail -n +3 /proc/net/dev | sed 's/:/ /' |
    while read -r ifc _ rxp rxe _ _ _ _ _ _ txp txe _; do
        state=$(cat "/sys/class/net/$ifc/operstate" 2>/dev/null || echo "unknown")

        if have ip; then
            ips=$(ip -o addr show dev "$ifc" 2>/dev/null | awk '{ print $4 }' | paste -sd, -)
        fi
        [[ -z ${ips:-} ]] && ips="-"

        printf '%-14s %-9s %12s %8s %12s %8s  %s\n' \
            "$ifc" "$state" "$rxp" "$rxe" "$txp" "$txe" "$ips"
        ips=""
    done
    echo "Примечание: у loopback (lo) статус 'unknown' — это нормально."
}

# Слушающие порты (TCP и UDP). Используем ss, при его отсутствии — netstat,
# затем lsof. Имена процессов видны только при запуске от root.
ports_info() {
    header "Слушающие порты"

    if [[ $EUID -ne 0 ]]; then
        echo "(скрипт запущен не от root — имена процессов могут не отображаться)"
    fi

    if have ss; then
        ss -tulnp
    elif have netstat; then
        netstat -tulnp
    elif have lsof; then
        lsof -i -P -n | grep -E 'LISTEN|UDP'
    else
        echo "Не найдено ни ss, ни netstat, ни lsof"
    fi
}

host_info() {
    cpu_info
    mem_info
    disk_info
    load_info
    time_info
    uptime_info
    net_info
    ports_info
}

# ---------------------------------------------------------------------------
# Информация о пользователях
# ---------------------------------------------------------------------------

# Все пользователи. getent passwd, а не cat /etc/passwd, — чтобы учитывать
# и пользователей из LDAP/SSSD. Тип определяем по UID: граница между системными
# и обычными пользователями задаётся UID_MIN в /etc/login.defs (обычно 1000).
all_users() {
    header "Пользователи системы"

    local uid_min
    uid_min=$(awk '/^UID_MIN/ { print $2 }' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}

    printf '%-20s %-7s %-25s %s\n' "NAME" "UID" "SHELL" "TYPE"
    getent passwd | awk -F: -v min="$uid_min" '{
        if ($3 == 0)                        type = "root"
        else if ($3 >= min && $3 != 65534)  type = "обычный"     # 65534 — nobody
        else                                type = "системный"
        printf "%-20s %-7s %-25s %s\n", $1, $3, $7, type
    }'
}

# Root-пользователи — все учётные записи с UID 0 (не только "root").
# Дополнительно показываем тех, кто может получить root через sudo:
# участников групп sudo (Debian/Ubuntu), wheel (RHEL/CentOS), admin (старые Ubuntu).
root_users() {
    header "Root-пользователи (UID 0)"
    getent passwd | awk -F: '$3 == 0 { print $1 }'

    header "Пользователи с правом sudo (группы sudo/wheel/admin)"
    local group members found=0
    for group in sudo wheel admin; do
        members=$(getent group "$group" | cut -d: -f4)
        if [[ -n $members ]]; then
            echo "$group: $members"
            found=1
        fi
    done
    (( found )) || echo "нет"
}

# Залогиненные пользователи: имя, терминал, время входа, откуда подключение
logged_users() {
    header "Залогиненные пользователи"
    local out
    out=$(who)
    if [[ -n $out ]]; then
        echo "$out"
    else
        echo "нет залогиненных пользователей"
    fi
}

user_info() {
    all_users
    root_users
    logged_users
}

# ---------------------------------------------------------------------------
# Разбор аргументов (GNU getopt)
# ---------------------------------------------------------------------------

# GNU getopt (из util-linux) на `getopt -T` возвращает код 4.
# Старая/BSD-версия этого не делает и не поддерживает длинные опции.
getopt -T >/dev/null 2>&1
if [[ $? -ne 4 ]]; then
    echo "$SCRIPT_NAME: требуется GNU getopt (пакет util-linux)" >&2
    exit 1
fi

# -o — короткие опции, --long — длинные, -n — имя для сообщений об ошибках.
# getopt нормализует аргументы (например, -Hu → -H -u) и добавляет '--' в конец.
if ! OPTS=$(getopt -o Huh --long host,user,help -n "$SCRIPT_NAME" -- "$@"); then
    # getopt уже вывел сообщение о неизвестном параметре
    usage >&2
    exit 2
fi

# Подставляем нормализованные аргументы вместо исходных
eval set -- "$OPTS"

show_host=0
show_user=0
show_help=0

while true; do
    case "$1" in
        -H|--host) show_host=1; shift ;;
        -u|--user) show_user=1; shift ;;
        -h|--help) show_help=1; shift ;;
        --)        shift; break ;;
        *)         echo "$SCRIPT_NAME: внутренняя ошибка разбора аргументов" >&2; exit 3 ;;
    esac
done

# Позиционные аргументы скрипт не принимает
if [[ $# -gt 0 ]]; then
    echo "$SCRIPT_NAME: лишние аргументы: $*" >&2
    usage >&2
    exit 2
fi

# --help или запуск без параметров — выводим справку
if (( show_help )) || (( !show_host && !show_user )); then
    usage
    exit 0
fi

if (( show_host )); then
    host_info
fi

if (( show_user )); then
    user_info
fi

exit 0
