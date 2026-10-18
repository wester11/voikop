#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Local TLS preparation for one Remnawave Node. Panel and ORBIT install.sh are untouched.
readonly NODE_DIR=/opt/remnanode NODE_COMPOSE=/opt/remnanode/docker-compose.yml
readonly CERTBOT_DIR=/opt/certbot CERTS_DIR=/opt/certbot/certs WEBROOT=/opt/certbot/www
readonly NGINX_FILE=/etc/nginx/conf.d/remna-node-tls-setup.conf
readonly RENEW_SCRIPT=/usr/local/sbin/remna-cert-renew
readonly RENEW_SERVICE=/etc/systemd/system/remna-cert-renew.service
readonly RENEW_TIMER=/etc/systemd/system/remna-cert-renew.timer
readonly STATE_FILE=/etc/remna-node-bootstrap.conf
readonly TRANSPORT_STATE_DIR=/var/lib/remna-node-transport-manager
readonly CERT_MOUNT=/opt/certbot/certs:/etc/letsencrypt:ro
DOMAIN='' EMAIL='' MODE='' TTY_FD='' UI_INPUT_FD='' UI_OUTPUT_FD='' BACKUP_DIR='' CANCELLED=0 NGINX_CHANGED=0 NGINX_RELOADED=0 CERTIFICATE_CHANGED=0 CERT_LINK_CHANGED=0 CERTBOT_COMPOSE_CHANGED=0 COMPOSE_CHANGED=0 RENEWAL_CHANGED=0 RENEWAL_WAS_ACTIVE=0 RENEWAL_WAS_ENABLED=0 NGINX_WAS_ACTIVE=0 ACME_CHECK_PASSED=0
WEB_ROOT=/var/www/remna-node-site
TRANSPORT_STATE_OVERRIDE=''

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

ui_output_fd() { printf '%s' "${UI_OUTPUT_FD:-$TTY_FD}"; }
ui_input_fd() { printf '%s' "${UI_INPUT_FD:-$TTY_FD}"; }
ui_print() { local fd; fd=$(ui_output_fd); printf '%s\n' "$*" >&"$fd"; }
ui_wrap() {
    local text=$1 width=${COLUMNS:-80} fd
    fd=$(ui_output_fd)
    [[ $width =~ ^[0-9]+$ ]] || width=80
    ((width > 4)) || width=40
    width=$((width - 2))
    while IFS= read -r line; do printf '  %s\n' "$line" >&"$fd"; done < <(printf '%s\n' "$text" | fold -s -w "$width")
}
ui_read() {
    local out=$1 _ui_answer fd
    fd=$(ui_input_fd)
    if [[ -t $fd ]]; then
        IFS= read -e -r -u "$fd" _ui_answer || { printf -v "$out" '%s' ''; return 1; }
    else
        IFS= read -r -u "$fd" _ui_answer || { printf -v "$out" '%s' ''; return 1; }
    fi
    normalize_terminal_input "$_ui_answer" _ui_answer
    printf -v "$out" '%s' "$_ui_answer"
}
confirm_action() {
    local message=$1 answer fd
    fd=$(ui_output_fd)
    ui_wrap "$message"
    printf '  Для продолжения введите ДА (Enter отменяет): ' >&"$fd"
    ui_read answer || answer=''
    [[ ${answer,,} == да ]]
}
cancel_operation() {
    CANCELLED=1
    ui_print 'Операция отменена; если уже были изменения, будет выполнен rollback.'
    exit 0
}
confirm_or_cancel() {
    confirm_action "$1" || cancel_operation
}

valid_domain() {
    local d=$1 label
    [[ ${#d} -le 253 && $d == *.* && $d != *..* && $d =~ ^[A-Za-z0-9.-]+$ && $d != .* && $d != *. ]] || return 1
    local -a labels=()
    IFS='.' read -r -a labels <<<"$d"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}
valid_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; }

normalize_terminal_input() {
    local value=$1 out=$2
    value=${value//$'\e[200~'/}
    value=${value//$'\e[201~'/}
    while [[ $value == *$'\r' ]]; do value=${value%$'\r'}; done
    value="${value#"${value%%[!$' \t']*}"}"
    value="${value%"${value##*[!$' \t']}"}"
    printf -v "$out" '%s' "$value"
}

prompt() {
    local label=$1 out=$2 answer fd
    fd=$(ui_output_fd)
    printf '%s' "$label" >&"$fd"
    ui_read answer || die 'Не удалось прочитать ввод из /dev/tty.'
    printf -v "$out" '%s' "$answer"
}
ask_value() {
    local label=$1 out=$2 validator=$3 value
    while :; do
        prompt "$label" value
        if [[ $out == DOMAIN ]]; then value=${value,,}; fi
        if "$validator" "$value"; then printf -v "$out" '%s' "$value"; return 0; fi
        local fd
        fd=$(ui_output_fd)
        say 'Некорректное значение. Повторите ввод.' >&"$fd"
    done
}
backup_file() {
    local path=$1 name=${1#/}
    name=${name//\//__}
    if [[ -e $BACKUP_DIR/$name || -L $BACKUP_DIR/$name || -e $BACKUP_DIR/$name.absent ]]; then return 0; fi
    if [[ -e $path || -L $path ]]; then cp -a -- "$path" "$BACKUP_DIR/$name"; else : >"$BACKUP_DIR/$name.absent"; fi
}
restore_file() {
    local path=$1 name=${1#/}
    name=${name//\//__}
    if [[ -e $BACKUP_DIR/$name || -L $BACKUP_DIR/$name ]]; then mkdir -p "$(dirname "$path")"; cp -a -- "$BACKUP_DIR/$name" "$path"
    elif [[ -e $BACKUP_DIR/$name.absent ]]; then rm -f -- "$path"; fi
}
rollback() {
    # Optional root is used only by --self-test to exercise rollback in a temp tree.
    local test_root=${1:-} nginx_file=$NGINX_FILE node_compose=$NODE_COMPOSE node_dir=$NODE_DIR
    local certbot_compose=$CERTBOT_DIR/docker-compose.yml current_link=$CERTS_DIR/live/current
    local renew_script=$RENEW_SCRIPT renew_service=$RENEW_SERVICE renew_timer=$RENEW_TIMER
    if [[ -n $test_root ]]; then
        test_root=${test_root%/}
        nginx_file=$test_root/etc/nginx/conf.d/remna-node-tls-setup.conf
        node_dir=$test_root/opt/remnanode
        node_compose=$node_dir/docker-compose.yml
        certbot_compose=$test_root/opt/certbot/docker-compose.yml
        current_link=$test_root/opt/certbot/certs/live/current
        renew_script=$test_root/usr/local/sbin/remna-cert-renew
        renew_service=$test_root/etc/systemd/system/remna-cert-renew.service
        renew_timer=$test_root/etc/systemd/system/remna-cert-renew.timer
    fi
    if ((NGINX_CHANGED)); then
        restore_file "$nginx_file" || warn 'Could not restore Nginx config.'
        if ((NGINX_WAS_ACTIVE)); then
            if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || warn 'Could not reload Nginx after rollback.'
            else warn 'Restored Nginx config did not validate; reload was skipped.'; fi
        fi
    fi
    if ((COMPOSE_CHANGED)); then
        restore_file "$node_compose" || warn 'Could not restore Node Compose.'
        (cd "$node_dir" && docker compose up -d remnanode) >/dev/null 2>&1 || warn 'Could not restore remnanode after rollback.'
    fi
    if ((CERTBOT_COMPOSE_CHANGED)); then
        restore_file "$certbot_compose" || warn 'Could not restore Certbot Compose.'
    fi
    if ((CERT_LINK_CHANGED)); then
        if [[ -L $current_link && $(readlink "$current_link" 2>/dev/null || true) == "$DOMAIN" ]]; then
            rm -f -- "$current_link" || warn 'Could not remove the certificate symlink created by this run.'
        fi
    fi
    if ((RENEWAL_CHANGED)); then
        restore_file "$renew_script" || warn 'Could not restore renewal script.'
        restore_file "$renew_service" || warn 'Could not restore renewal service.'
        restore_file "$renew_timer" || warn 'Could not restore renewal timer.'
        systemctl daemon-reload >/dev/null 2>&1 || warn 'Could not reload systemd after rollback.'
        if ((!RENEWAL_WAS_ACTIVE)); then
            systemctl stop remna-cert-renew.timer >/dev/null 2>&1 || true
            if ((RENEWAL_WAS_ENABLED)); then systemctl enable remna-cert-renew.timer >/dev/null 2>&1 || true
            else systemctl disable remna-cert-renew.timer >/dev/null 2>&1 || true; fi
        fi
    fi
}
on_exit() {
    local status=$?
    if ((status != 0 || CANCELLED)); then rollback; fi
    [[ -z $TTY_FD ]] || exec {TTY_FD}<&- || true
    exit "$status"
}

render_nginx() {
    local with_tls=${2:-0}
    cat <<EOF
# Managed by remnawave-node-tls-setup.sh
server {
    listen 127.0.0.1:8080;
    server_name _;
    root $WEB_ROOT;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
server {
    listen 80;
    listen [::]:80;
    server_name $1;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    if ((with_tls)); then cat <<EOF
server {
    listen 127.0.0.1:9443 ssl;
    server_name $1;
    ssl_certificate $CERTS_DIR/live/current/fullchain.pem;
    ssl_certificate_key $CERTS_DIR/live/current/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=300" always;
    root $WEB_ROOT;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
    fi
}

# Conservative text edit: handles normal block-style Compose without reserializing the file.
patch_node_compose() {
    local compose_path=${1:-$NODE_COMPOSE}
    if has cygpath; then compose_path=$(cygpath -w "$compose_path"); fi
    MSYS_NO_PATHCONV=1 COMPOSE_CERT_MOUNT="$CERT_MOUNT" python3 - "$compose_path" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); mount = __import__("os").environ["COMPOSE_CERT_MOUNT"]
lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
if any(mount in line for line in lines): raise SystemExit(0)
if re.search(r"/etc/letsencrypt(?=[:\s]|$)", "".join(lines)):
    print("Conflicting mount at /etc/letsencrypt; refusing edit.", file=sys.stderr); raise SystemExit(3)
services = None
for i, line in enumerate(lines):
    m = re.match(r"^( *)services:\s*(?:#.*)?(?:\r?\n)?$", line)
    if m:
        services = (i, len(m.group(1)))
        break
if services is None: print("No safe services section found.", file=sys.stderr); raise SystemExit(3)
si, sind = services; start = None; ind = None
for i in range(si + 1, len(lines)):
    m = re.match(r"^( *)remnanode:\s*(?:#.*)?(?:\r?\n)?$", lines[i])
    if m and len(m.group(1)) > sind: start, ind = i, len(m.group(1)); break
    s = lines[i].strip(); n = len(lines[i]) - len(lines[i].lstrip(" "))
    if s and not s.startswith("#") and n <= sind: break
if start is None: print("Service remnanode not found.", file=sys.stderr); raise SystemExit(3)
end = len(lines)
for i in range(start + 1, len(lines)):
    s = lines[i].strip(); n = len(lines[i]) - len(lines[i].lstrip(" "))
    if s and not s.startswith("#") and n <= ind: end = i; break
fi = ind + 2; vi = None
for i in range(start + 1, end):
    m = re.match(r"^( *)volumes:\s*(.*?)\s*(?:#.*)?(?:\r?\n)?$", lines[i])
    if m and len(m.group(1)) == fi:
        vi = i; inline = m.group(2)
        if inline == "[]": lines[i] = " " * fi + "volumes:\n"
        elif inline: print("Inline volumes syntax unsupported; refusing edit.", file=sys.stderr); raise SystemExit(3)
        break
if vi is not None:
    at = vi + 1
    while at < end:
        s = lines[at].strip(); n = len(lines[at]) - len(lines[at].lstrip(" "))
        if s and not s.startswith("#") and n <= fi: break
        at += 1
    lines.insert(at, " " * (fi + 2) + "- '" + mount + "'\n")
else:
    lines[end:end] = [" " * fi + "volumes:\n", " " * (fi + 2) + "- '" + mount + "'\n"]
p.write_text("".join(lines), encoding="utf-8")
PY
}

# Patch only the certbot service's block-style volumes list. Return 0 when the
# webroot mount already exists and 10 when a change was written. Any uncertain
# YAML shape is rejected instead of being reserialized or guessed at.
patch_certbot_compose() {
    local compose_path=$1 backup_dir=$2
    if has cygpath; then
        compose_path=$(cygpath -w "$compose_path")
        backup_dir=$(cygpath -w "$backup_dir")
    fi
    MSYS_NO_PATHCONV=1 COMPOSE_BACKUP_DIR="$backup_dir" python3 - "$compose_path" <<'PY'
import os, pathlib, re, shlex, shutil, sys

path = pathlib.Path(sys.argv[1])
backup_dir = pathlib.Path(os.environ["COMPOSE_BACKUP_DIR"])
raw = path.read_bytes()
text = raw.decode("utf-8")
lines = text.splitlines(keepends=True)
newline = "\n" if "\n" in text else "\n"

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(3)

def service_bounds(name):
    services = None
    for i, line in enumerate(lines):
        match = re.match(r"^( *)(?:services):\s*(?:#.*)?(?:\r?\n)?$", line)
        if match and len(match.group(1)) == 0:
            services = i
            break
    if services is None:
        fail("No safe top-level services section found; refusing edit.")
    start = None
    for i in range(services + 1, len(lines)):
        match = re.match(r"^( +)([^ #][^:]*):\s*(?:#.*)?(?:\r?\n)?$", lines[i])
        if match and len(match.group(1)) > 0 and match.group(2) == name:
            start = i
            break
        stripped = lines[i].strip()
        indent = len(lines[i]) - len(lines[i].lstrip(" "))
        if stripped and not stripped.startswith("#") and indent == 0:
            break
    if start is None:
        fail("Service certbot not found; refusing edit.")
    service_indent = len(lines[start]) - len(lines[start].lstrip(" "))
    end = len(lines)
    for i in range(start + 1, len(lines)):
        stripped = lines[i].strip()
        indent = len(lines[i]) - len(lines[i].lstrip(" "))
        if stripped and not stripped.startswith("#") and indent <= service_indent:
            end = i
            break
    return start, end, service_indent

def parse_short(value):
    try:
        fields = shlex.split(value, comments=True, posix=True)
    except ValueError:
        return None
    if len(fields) != 1:
        return None
    parts = fields[0].split(":")
    if len(parts) < 2:
        return None
    return parts[0], parts[1], parts[2:]

start, end, service_indent = service_bounds("certbot")
field_indent = service_indent + 2
volumes_index = None
inline = None
for i in range(start + 1, end):
    match = re.match(r"^( *)(volumes):\s*(.*?)(?:\s+#.*)?(?:\r?\n)?$", lines[i])
    if match and len(match.group(1)) == field_indent:
        volumes_index = i
        inline = match.group(3).strip()
        break

empty_volumes = False
if volumes_index is not None and inline:
    if inline != "[]" and not inline.startswith("#"):
        # Surface a target collision even in compact syntax, then stop safely.
        if "/var/www/certbot" in inline:
            compact = inline.strip("[] \t\"'")
            parsed = parse_short(compact.lstrip("- "))
            if parsed and parsed[1] == "/var/www/certbot" and parsed[0] != "./www":
                print("CERTBOT WEBROOT MOUNT CONFLICT", file=sys.stderr)
                raise SystemExit(4)
        fail("Inline volumes syntax unsupported; refusing edit.")
    if inline == "[]":
        empty_volumes = True
        comment = re.search(r"\s+#.*$", lines[volumes_index].rstrip("\n"))
        suffix = (" " + comment.group(0).strip()) if comment else ""
        lines[volumes_index] = " " * field_indent + "volumes:" + suffix + newline

if volumes_index is None:
    fail("Service certbot has no block-style volumes list; refusing edit.")
else:
    volumes_indent = field_indent
    at = volumes_index + 1
    list_indent = None
    records = []
    while at < end:
        line = lines[at]
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if stripped and not stripped.startswith("#") and indent <= volumes_indent:
            break
        item = re.match(r"^( +)-\s*(.*?)(?:\s+#.*)?(?:\r?\n)?$", line)
        if item and len(item.group(1)) > volumes_indent:
            if list_indent is None:
                list_indent = len(item.group(1))
            elif len(item.group(1)) != list_indent:
                fail("Irregular volumes list indentation; refusing edit.")
            value = item.group(2).strip()
            if re.match(r"^(?:type|source|target|read_only|consistency|bind|volume|tmpfs):(?:\s|$)", value):
                value = ""
            record_end = at + 1
            while record_end < end:
                next_line = lines[record_end]
                next_text = next_line.strip()
                next_indent = len(next_line) - len(next_line.lstrip(" "))
                if next_text and not next_text.startswith("#") and next_indent <= list_indent and re.match(r"^\s*-", next_line):
                    break
                if next_text and not next_text.startswith("#") and next_indent <= volumes_indent:
                    break
                record_end += 1
            records.append((at, record_end, value))
            at = record_end
            continue
        at += 1

    has_certs = False
    has_webroot = False
    for item_start, item_end, value in records:
        if not value:
            # Long-form mount: recognize its source/target without rewriting it.
            item_text = "".join(lines[item_start:item_end])
            source_match = re.search(r"(?m)^\s+source:\s*['\"]?([^'\"#\s]+)", item_text)
            target_match = re.search(r"(?m)^\s+target:\s*['\"]?([^'\"#\s]+)", item_text)
            if target_match and target_match.group(1) == "/var/www/certbot":
                if source_match and source_match.group(1) == "./www":
                    has_webroot = True
                else:
                    print("CERTBOT WEBROOT MOUNT CONFLICT", file=sys.stderr)
                    raise SystemExit(4)
            if target_match and target_match.group(1) == "/etc/letsencrypt" and source_match and source_match.group(1) == "./certs":
                has_certs = True
            continue
        parsed = parse_short(value)
        if parsed is None:
            if "/var/www/certbot" in value:
                print("CERTBOT WEBROOT MOUNT CONFLICT", file=sys.stderr)
                raise SystemExit(4)
            continue
        source, target, options = parsed
        if target == "/var/www/certbot":
            if source != "./www" or options:
                print("CERTBOT WEBROOT MOUNT CONFLICT", file=sys.stderr)
                raise SystemExit(4)
            has_webroot = True
        if target == "/etc/letsencrypt" and source == "./certs" and not options:
            has_certs = True

    if has_webroot and has_certs:
        raise SystemExit(0)
    if not has_certs and not empty_volumes:
        fail("Existing Certbot Compose lacks the expected ./certs mount.")
    if list_indent is None:
        list_indent = volumes_indent + 2
    entries = []
    if not has_certs:
        entries.append(" " * list_indent + "- './certs:/etc/letsencrypt'" + newline)
    if not has_webroot:
        entries.append(" " * list_indent + "- './www:/var/www/certbot'" + newline)
    additions = entries
    changed = bool(entries) or empty_volumes

    # Insert after the last list item so all existing service fields and mounts
    # retain their original bytes and relative order.
    if records:
        at = records[-1][1]
    else:
        at = volumes_index + 1
        while at < end:
            stripped = lines[at].strip()
            indent = len(lines[at]) - len(lines[at].lstrip(" "))
            if stripped and not stripped.startswith("#") and indent <= volumes_indent:
                break
            at += 1

if not changed:
    raise SystemExit(0)
lines[at:at] = additions
patched = "".join(lines).encode("utf-8")
backup_dir.mkdir(parents=True, exist_ok=True)
shutil.copy2(path, backup_dir / "opt__certbot__docker-compose.yml")
path.write_bytes(patched)
raise SystemExit(10)
PY
}

menu() {
    local choice fd
    fd=$(ui_output_fd)
    while :; do
        printf '\nУстановщик TLS для Remnawave Node\n' >&"$fd"
        ui_print '[1] Проверить и исправить'
        ui_wrap 'Проверки и нужные исправления; возможны изменения конфигов, reload Nginx и restart Remnanode с разрывом VPN.'
        ui_print '[2] Перевыпустить сертификат'
        ui_wrap 'Принудительный выпуск сертификата; возможны reload Nginx и restart Remnanode с разрывом VPN.'
        ui_print '[3] Показать статус TLS / Selfsteal'
        ui_wrap 'Только чтение: проверки без правки файлов и без перезапуска сервисов.'
        ui_print '[4] Шаблоны профилей Remnawave'
        ui_wrap 'Только чтение: TLS и REALITY шаблоны. Для дополнительных транспортов откройте менеджер.'
        ui_print '[T] Транспорты'
        ui_wrap 'Статус, проверка совместимости и подготовка обезличенного кандидата. Активация профиля остаётся в Remnawave.'
        ui_print '[H] Подробная справка'
        ui_wrap 'Только чтение: действия, файлы, риски и откат.'
        ui_print '[5] Выход'
        printf 'Выберите пункт: ' >&"$fd"
        if ! ui_read choice; then MODE=5; return 0; fi
        case ${choice,,} in
            1|2|3|4|5) MODE=$choice; return 0 ;;
            t) MODE=6; return 0 ;;
            h)
                show_detailed_help
                printf 'Нажмите Enter, чтобы вернуться в меню: ' >&"$fd"
                if ! ui_read choice; then MODE=5; return 0; fi
                ;;
            *) ui_print 'Неизвестный пункт. Введите 1–5, T или H.' ;;
        esac
    done
}

show_detailed_help() {
    ui_print ''
    ui_print 'ПОДРОБНАЯ СПРАВКА · только чтение'
    ui_print ''
    ui_wrap '1. Проверить и исправить. Когда использовать: первичная настройка или восстановление. Проверяет ОС, Docker Compose, занятость портов, DNS, ACME, сертификат, Nginx и volume Remnanode. Может изменить /etc/nginx/conf.d/remna-node-tls-setup.conf, /opt/certbot/docker-compose.yml, /opt/remnanode/docker-compose.yml, сертификаты в /opt/certbot/certs, /var/www/remna-node-site, /etc/remna-node-bootstrap.conf и renewal-файлы systemd. Может перезагрузить Nginx; если нужен volume или сертификат используется Xray/HY2 — может запустить/перезапустить Remnanode и оборвать VPN. Риск: краткий простой сайта или VPN. Откат: trap on_exit восстанавливает конфиги из /var/backups/remna-node-tls.*; если Compose был изменён, восстановление может снова применить контейнер. Изменение выпущенного сертификата автоматически не откатывается.'
    ui_print ''
    ui_wrap "2. Перевыпустить сертификат. Когда использовать: сертификат истёк, повреждён или его нужно заменить. Проверяет DNS и HTTP-01, затем запускает Certbot с --force-renewal. Может изменить сертификаты в /opt/certbot/certs, конфигурацию Nginx и renewal-службу/таймер. Возможен reload Nginx; Remnanode перезапускается только когда конфигурация Xray/HY2 явно ссылается на эти сертификаты. В этом случае VPN-подключения могут оборваться. Риск: лимиты выпуска Let's Encrypt и краткое прерывание VPN. При ошибке trap on_exit восстанавливает конфигурации из /var/backups/remna-node-tls.*; сертификат автоматически не откатывается."
    ui_print ''
    ui_wrap '3. Статус TLS / Selfsteal. Когда использовать: диагностика без исправлений. Проверяет DNS, срок и SAN сертификата, Nginx, HTTP 301, HTTPS на 9443, TLS 1.2/1.3, HSTS, состояние Remnanode, доступ сертификата из контейнера и таймер продления. REALITY/VLESS handshake и передача VPN-трафика не проверяются. Файлы не меняет; сервисы не перезапускает. Риск: только короткие локальные сетевые запросы. Откат не нужен.'
    ui_print ''
    ui_wrap '4. Шаблоны профилей Remnawave. Когда использовать: при ручном создании Config Profile. Только показывает примеры TLS и REALITY SELFSTEAL. Никакие файлы и профили не меняет, сервисы не перезапускает. Риск отсутствует; откат не нужен.'
    ui_print ''
    ui_wrap 'T. Менеджер транспортов. Статус, совместимость, шаблоны TCP TLS / TCP REALITY / XHTTP REALITY / XHTTP TLS / gRPC TLS и план ручной активации. Подготовка записывает только новые файлы кандидата в /var/lib/remna-node-transport-manager; Nginx, Docker, сертификаты, Xray и Remnawave не меняет, сервисы не перезапускает. Каждый кандидат уникален, предыдущие сохраняются в истории. Активация через API не выполняется; профиль и Host меняются вручную в панели после проверки зависимостей и отдельного согласования. Откат уже активного профиля выполняется возвратом предыдущего профиля и Host в панели.'
    ui_print ''
    ui_wrap 'XHTTP режим auto/stream-one/stream-up/packet-up относится к клиентскому профилю; серверный inbound без явного mode сохраняет стандартную поддержку режимов. Наборы Xray-клиентов — только шаблоны, не импорт Happ и не подтверждение совместимости iOS/Android.'
    ui_print ''
    ui_wrap '5. Выход. Завершает установщик. Проверок, изменений файлов и перезапуска сервисов нет. Откат не нужен.'
    ui_print ''
    ui_wrap 'Подтверждение опасных действий: требуется ввести ДА. Пустой ввод или любой другой ответ отменяет действие.'
}

show_operation_warning() {
    case $1 in
        1)
            ui_print ''
            ui_print 'ВНИМАНИЕ · Проверить и исправить'
            ui_wrap 'Могут измениться Nginx, Certbot Compose, Node Compose, сертификаты, сайт-заглушка, сохранённый домен и таймер продления.'
            ui_wrap 'При изменении конфигурации может перезагрузиться Nginx. Если понадобится добавить certificate volume, Remnanode может быть пересоздан; при использовании сертификата Xray/HY2 он может быть перезапущен. VPN-подключения могут оборваться.'
            ui_wrap 'Перед каждой правкой или перезапуском будет отдельное подтверждение. Копии конфигураций сохраняются в backup-каталоге.'
            ;;
        2)
            ui_print ''
            ui_print 'ВНИМАНИЕ · Перевыпустить сертификат'
            ui_wrap 'Certbot выполнит принудительный выпуск и изменит файлы сертификата. Nginx может быть перезагружен. Remnanode перезапускается только при обнаруженной ссылке Xray/HY2 на сертификат; тогда VPN-подключения могут оборваться.'
            ui_wrap 'Конфигурации сохраняются в backup-каталоге. Изменённый сертификат автоматически не откатывается.'
            ;;
    esac
}

confirm_menu_action() {
    show_operation_warning "$1"
    confirm_action 'Продолжить выбранную операцию?'
}

run_readonly_action() {
    case $1 in
        3)
            load_state || warn "Не найдено корректное состояние $STATE_FILE; домен будет показан как UNKNOWN."
            show_readiness
            ;;
        4)
            load_state || warn "Не найдено корректное состояние $STATE_FILE; domain будет показан как placeholder."
            show_profile_templates
            ;;
        *) return 1 ;;
    esac
}

port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
port_owner() { ss -lntp "sport = :$1" 2>/dev/null || true; }

load_state() {
    local key value
    [[ -f $STATE_FILE ]] || return 1
    while IFS='=' read -r key value; do
        case $key in
            DOMAIN) valid_domain "$value" && DOMAIN=${value,,} || return 1 ;;
            WEB_ROOT)
                [[ $value == /* && $value != *$'\n'* && $value != *'..'* && $value =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
                WEB_ROOT=$value
                ;;
        esac
    done <"$STATE_FILE"
    [[ -n $DOMAIN && -n $WEB_ROOT ]]
}

save_state() {
    local tmp
    valid_domain "$DOMAIN" || die 'Не удалось сохранить некорректный DOMAIN.'
    [[ $WEB_ROOT == /* && $WEB_ROOT != *'..'* && $WEB_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'WEB_ROOT должен быть безопасным абсолютным путём.'
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    printf 'DOMAIN=%s\nWEB_ROOT=%s\n' "$DOMAIN" "$WEB_ROOT" >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

certificate_has_domain_san() {
    local cert=${1:-$CERTS_DIR/live/current/fullchain.pem} san
    [[ -r $cert ]] || return 1
    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || return 1
    printf '%s\n' "$san" | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -Fxq "DNS:$DOMAIN"
}

http_backend_ready() {
    curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:8080/ >/dev/null
}

http_redirect_ready() {
    local headers
    headers=$(curl --noproxy '*' -sS --max-time 5 -D - -o /dev/null -H "Host: $DOMAIN" \
        'http://127.0.0.1/remna-301-check?source=installer') || return 1
    grep -Eiq '^HTTP/[0-9.]+ 301([[:space:]]|$)' <<<"$headers" &&
        grep -Fqi "Location: https://$DOMAIN/remna-301-check?source=installer" <<<"$headers"
}

https_backend_ready() {
    local headers
    headers=$(https_backend_headers "${1:-$CERTS_DIR/live/current/fullchain.pem}") || return 1
    grep -Eiq '^Strict-Transport-Security:[[:space:]]*max-age=300([;[:space:]]|$)' <<<"$headers"
}

https_backend_headers() {
    local cert=${1:-$CERTS_DIR/live/current/fullchain.pem} headers
    [[ -r $cert ]] && certificate_has_domain_san "$cert" || return 1
    headers=$(curl --noproxy '*' -fsS --max-time 5 -D - -o /dev/null --resolve "$DOMAIN:9443:127.0.0.1" \
        --cacert "$cert" "https://$DOMAIN:9443/") || return 1
    printf '%s\n' "$headers"
}

https_protocol_ready() {
    local version=$1 cert=${2:-$CERTS_DIR/live/current/fullchain.pem} output options
    [[ -r $cert ]] && certificate_has_domain_san "$cert" || return 2
    case $version in
        1.2) options=$(curl --help all 2>/dev/null) || return 2; [[ $options == *--tls-max* ]] || return 2
            output=$(curl --noproxy '*' -sS --max-time 5 --tlsv1.2 --tls-max 1.2 --resolve "$DOMAIN:9443:127.0.0.1" --cacert "$cert" -o /dev/null -w '%{http_code}' "https://$DOMAIN:9443/") || return 1 ;;
        1.3) options=$(curl --help all 2>/dev/null) || return 2; [[ $options == *--tlsv1.3* && $options == *--tls-max* ]] || return 2
            output=$(curl --noproxy '*' -sS --max-time 5 --tlsv1.3 --tls-max 1.3 --resolve "$DOMAIN:9443:127.0.0.1" --cacert "$cert" -o /dev/null -w '%{http_code}' "https://$DOMAIN:9443/") || return 1 ;;
        *) return 2 ;;
    esac
    [[ $output =~ ^2[0-9][0-9]$ ]]
}

https_protocol_status() {
    local version=$1 cert=$2 result
    if https_protocol_ready "$version" "$cert"; then printf 'PASS\n'; return 0
    else result=$?; fi
    if ((result == 2)); then printf 'NOT TESTED\n'; else printf 'FAIL\n'; fi
}

status_row() {
    local label=$1 state=$2 detail=$3 fd
    fd=$(ui_output_fd)
    printf '  %s | %s\n' "$label" "$state" >&"$fd"
    ui_wrap "$detail"
}

# shellcheck disable=SC2329 # Called through run_readonly_action.
show_readiness() {
    local cert=$CERTS_DIR/live/current/fullchain.pem active_mode='UNKNOWN'
    local dns4='' dns6='' dns_state='FAIL' cert_state='FAIL' expiry='не определён' expiry_state='NOT TESTED'
    local domain_state='NOT TESTED' nginx_state='FAIL' redirect_state='NOT TESTED' https_state='NOT TESTED' tls12='NOT TESTED' tls13='NOT TESTED'
    local hsts_state='NOT TESTED' reality_state='NOT TESTED' vless_state='NOT TESTED'
    local hy2_state='FAIL' remna_state='FAIL' core_state='FAIL' listener_state='NOT TESTED'
    local mount_state='NOT TESTED' inside_state='FAIL' timer_state='FAIL' headers='' listener_owner='unknown'

    ui_print ''
    ui_print 'СТАТУС TLS / SELFSTEAL · только чтение'
    ui_wrap 'Проверка HTTPS-заглушки не подтверждает VPN-handshake или передачу трафика.'
    ui_print ''
    ui_print '  Проверка | Статус'

    if [[ -n $DOMAIN ]]; then
        domain_state=PASS
        dns4=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)
        dns6=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | filter_aaaa_records | paste -sd, - || true)
        [[ -n $dns4 || -n $dns6 ]] && dns_state=PASS
        redirect_state=FAIL
    fi
    if [[ -n $DOMAIN ]] && certificate_valid && certificate_has_domain_san "$cert"; then
        cert_state=PASS
        expiry_state=PASS
        expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
        if [[ -n $expiry ]]; then expiry_state=PASS; else expiry='дата не прочитана'; expiry_state=WARNING; fi
    fi
    if systemctl is-active --quiet nginx && nginx -t >/dev/null 2>&1; then nginx_state=PASS; fi
    http_redirect_ready && redirect_state=PASS || true
    if headers=$(https_backend_headers "$cert"); then
        https_state=PASS
        grep -Eiq '^Strict-Transport-Security:[[:space:]]*max-age=300([;[:space:]]|$)' <<<"$headers" && hsts_state=PASS || hsts_state=FAIL
        tls12=$(https_protocol_status 1.2 "$cert")
        tls13=$(https_protocol_status 1.3 "$cert")
    elif [[ $cert_state == PASS ]]; then
        https_state=FAIL
        hsts_state=NOT TESTED
        tls12=FAIL
        tls13=FAIL
    fi
    active_mode=$(detect_active_mode)
    if docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null | grep -qx running; then remna_state=PASS; fi
    remnawave_core_ready && core_state=PASS || true
    listener_owner=$(classify_443_owner tcp)
    case $listener_owner in
        remnawave) listener_state=PASS ;;
        free) listener_state=FAIL ;;
        nginx|unknown) listener_state=WARNING ;;
    esac
    mount_state=$(node_certificate_mount_status)
    if container_certificate_ready; then
        inside_state=PASS
        [[ $cert_state == PASS ]] && hy2_state=PASS
    fi
    if [[ $https_state == PASS && $active_mode == 'REALITY SELFSTEAL' ]]; then
        reality_state=WARNING
    elif [[ $active_mode == 'REALITY SELFSTEAL' ]]; then
        reality_state=FAIL
    fi
    if [[ $active_mode == TLS ]]; then
        if [[ $cert_state == PASS && $inside_state == PASS ]]; then vless_state=WARNING; else vless_state=FAIL; fi
    fi
    if systemctl is-active --quiet remna-cert-renew.timer && systemctl is-enabled --quiet remna-cert-renew.timer; then timer_state=PASS; fi

    status_row 'Домен' "$domain_state" "${DOMAIN:-не задан}"
    status_row 'DNS' "$dns_state" "A: ${dns4:-нет}; AAAA: ${dns6:-нет}"
    status_row 'Сертификат' "$cert_state" "$([[ $cert_state == PASS ]] && printf 'валиден для %s' "$DOMAIN" || printf 'нет или проверка не пройдена')"
    status_row 'Окончание сертификата' "$expiry_state" "$expiry"
    status_row 'Nginx' "$nginx_state" 'проверялись состояние службы и nginx -t'
    status_row 'HTTP 301' "$redirect_state" 'проверка сохраняет тестовый URI и query'
    status_row 'HTTPS 9443' "$https_state" 'сертификат проверяется с правильным SNI'
    status_row 'TLS 1.2' "$tls12" 'отдельный запрос к HTTPS backend'
    status_row 'TLS 1.3' "$tls13" 'отдельный запрос к HTTPS backend'
    status_row 'HSTS' "$hsts_state" 'ожидается Strict-Transport-Security max-age=300'
    status_row 'TCP/443' "$listener_state" "владелец listener: $listener_owner; TLS не подтверждает VLESS handshake"
    status_row 'rw-core/Xray' "$core_state" 'процесс в контейнере; это не подтверждает VPN handshake или трафик'
    status_row 'Docker volume' "$mount_state" "ожидается read-only $CERTS_DIR:/etc/letsencrypt"
    case $reality_state in
        WARNING) status_row 'REALITY SELFSTEAL' "$reality_state" 'HTTPS backend доступен; VPN-handshake и трафик NOT TESTED' ;;
        FAIL) status_row 'REALITY SELFSTEAL' "$reality_state" 'режим обнаружен, но HTTPS backend не прошёл проверку; VPN-handshake NOT TESTED' ;;
        *) status_row 'REALITY SELFSTEAL' "$reality_state" 'REALITY inbound не обнаружен или не проверен' ;;
    esac
    case $vless_state in
        WARNING) status_row 'VLESS TLS' "$vless_state" 'TLS inbound и сертификат обнаружены; клиентский handshake NOT TESTED' ;;
        FAIL) status_row 'VLESS TLS' "$vless_state" 'TLS inbound обнаружен, но сертификат не готов' ;;
        *) status_row 'VLESS TLS' "$vless_state" 'TLS inbound не обнаружен или не проверен' ;;
    esac
    if [[ $hy2_state == PASS ]]; then
        status_row 'HY2 certificate' "$hy2_state" 'сертификат доступен в контейнере; это не подтверждает работу HY2, handshake NOT TESTED'
    else
        status_row 'HY2 certificate' "$hy2_state" 'сертификат не прошёл проверку или недоступен в контейнере'
    fi
    status_row 'Remnanode' "$remna_state" 'состояние контейнера'
    status_row 'Сертификат в контейнере' "$inside_state" 'fullchain.pem и privkey.pem доступны для чтения'
    status_row 'Таймер продления' "$timer_state" 'systemd timer active и enabled'
    ui_print ''
    ui_wrap 'Метки: PASS — проверено; FAIL — проверка не пройдена; WARNING — частичная готовность; NOT TESTED — не проверялось.'
}

container_certificate_ready() {
    docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem &&
        docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem
}

node_certificate_mount_status() {
    local mounts
    mounts=$(docker inspect -f '{{json .Mounts}}' remnanode 2>/dev/null) || { printf 'NOT TESTED\n'; return 0; }
    python3 - "$CERTS_DIR" "$mounts" <<'PY'
import json, os, sys
try:
    mounts = json.loads(sys.argv[2])
except (TypeError, ValueError):
    print("NOT TESTED")
    raise SystemExit(0)
expected = os.path.realpath(sys.argv[1])
for mount in mounts:
    if mount.get("Destination") == "/etc/letsencrypt":
        source = os.path.realpath(mount.get("Source", ""))
        print("PASS" if source == expected and not mount.get("RW", True) else "FAIL")
        raise SystemExit(0)
print("FAIL")
PY
}

managed_nginx_9443_listener() {
    local owner=$1 config=$2
    [[ $owner == *127.0.0.1:9443* && $owner == *nginx* && $config == *'listen 127.0.0.1:9443 ssl;'* ]]
}

detect_active_mode() {
    local security has_tls=0 has_reality=0
    docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true || { printf 'UNKNOWN\n'; return 0; }
    # Only extract the non-secret inbound security field. Never print config files,
    # keys, UUIDs, tokens, or the container's full command line.
    security=$(docker exec remnanode sh -c 'find /etc /usr/local/etc /opt/remnanode -type f -name "*.json" -exec cat {} \; 2>/dev/null' 2>/dev/null | python3 -c 'import json,sys; s=sys.stdin.read(); d=json.JSONDecoder(); out=[]
def walk(v):
    if isinstance(v,dict):
        for inbound in v.get("inbounds",[]):
            if isinstance(inbound,dict):
                mode=inbound.get("streamSettings",{}).get("security") if isinstance(inbound.get("streamSettings",{}),dict) else None
                if isinstance(mode,str): out.append(mode)
        for child in v.values(): walk(child)
    elif isinstance(v,list):
        for child in v: walk(child)
i=0
while i<len(s):
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    try: value,end=d.raw_decode(s,i)
    except json.JSONDecodeError: break
    walk(value); i=end
print("\\n".join(out))' 2>/dev/null || true)
    grep -Fxq reality <<<"$security" && has_reality=1 || true
    grep -Fxq tls <<<"$security" && has_tls=1 || true
    if ((has_reality && !has_tls)); then printf 'REALITY SELFSTEAL\n'
    elif ((has_tls && !has_reality)); then printf 'TLS\n'
    else printf 'UNKNOWN\n'; fi
}

show_profile_templates() {
    ui_wrap 'Шаблон TLS (Config Profile Remnawave):'
    ui_print 'Входящий протокол: VLESS / RAW (TCP)'
    ui_print 'Защита: TLS'
    ui_wrap 'Путь к сертификату: /etc/letsencrypt/live/current/fullchain.pem'
    ui_wrap 'Путь к ключу: /etc/letsencrypt/live/current/privkey.pem'
    ui_wrap 'Резервный сайт (fallback): 127.0.0.1:8080'
    ui_print ''
    ui_wrap 'Шаблон REALITY SELFSTEAL (Config Profile Remnawave):'
    ui_print 'Входящий протокол: VLESS / RAW (TCP)'
    ui_print 'Защита: REALITY'
    ui_print 'Цель: 127.0.0.1:9443'
    ui_print 'xver: 0'
    ui_wrap 'privateKey: <EXISTING_SHARED_REALITY_PRIVATE_KEY>'
    ui_wrap 'shortIds: <EXISTING_SHARED_REALITY_SHORT_IDS>'
    ui_wrap 'serverNames: <ADD_THIS_NODE_DOMAIN>'
    ui_print ''
    ui_wrap "REALITY serverNames не поддерживает wildcard. Добавьте домен этой Node в общий список serverNames: ${DOMAIN:-<DOMAIN>}"
    ui_wrap 'Для общего профиля используйте общий REALITY privateKey; укажите все домены Nodes в serverNames и Host Address/SNI; target оставьте 127.0.0.1:9443.'
    ui_wrap 'Риск общего privateKey: компрометация одной Node требует ротации ключа для всей группы.'
    ui_print ''
    ui_wrap 'Другие обезличенные inbound snippets и XHTTP client mode варианты формируются через T → Менеджер транспортов → Подготовить. Это JSON-фрагменты, а не полные профили и не готовая активация.'
    ui_wrap 'XHTTP TLS и gRPC TLS создаются как loopback-кандидаты на 8443/8444; без отдельной проверенной Nginx HTTP/2 маршрутизации они не обслуживают сайт и не готовы к активации. gRPC не имеет обычного fallback.'
}

transport_state_root() {
    printf '%s\n' "${TRANSPORT_STATE_OVERRIDE:-$TRANSPORT_STATE_DIR}"
}

transport_slug() {
    case $1 in
        tcp_tls) printf 'tcp-tls\n' ;;
        tcp_reality) printf 'tcp-reality\n' ;;
        xhttp_reality) printf 'xhttp-reality\n' ;;
        xhttp_tls) printf 'xhttp-tls\n' ;;
        grpc_tls) printf 'grpc-tls\n' ;;
        xhttp_modes) printf 'xhttp-client-modes\n' ;;
        *) return 1 ;;
    esac
}

transport_label() {
    case $1 in
        tcp_tls) printf 'VLESS RAW/TCP + TLS\n' ;;
        tcp_reality) printf 'VLESS RAW/TCP + REALITY SELFSTEAL\n' ;;
        xhttp_reality) printf 'VLESS XHTTP + REALITY SELFSTEAL\n' ;;
        xhttp_tls) printf 'VLESS XHTTP + TLS\n' ;;
        grpc_tls) printf 'VLESS gRPC + TLS\n' ;;
        *) return 1 ;;
    esac
}

render_transport_inbound() {
    local transport=$1 domain=$2
    valid_domain "$domain" || return 2
    case $transport in
        tcp_tls)
            cat <<EOF
{
  "tag": "__SET_UNIQUE_INBOUND_TAG__",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none",
    "fallbacks": [{"dest": "127.0.0.1:8080"}]
  },
  "streamSettings": {
    "network": "raw",
    "security": "tls",
    "tlsSettings": {
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "certificates": [{
        "certificateFile": "/etc/letsencrypt/live/current/fullchain.pem",
        "keyFile": "/etc/letsencrypt/live/current/privkey.pem"
      }]
    }
  }
}
EOF
            ;;
        tcp_reality)
            cat <<EOF
{
  "tag": "__SET_UNIQUE_INBOUND_TAG__",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "target": "127.0.0.1:9443",
      "xver": 0,
      "serverNames": ["$domain"],
      "privateKey": "__REUSE_EXISTING_NODE_PRIVATE_KEY__",
      "shortIds": ["__REUSE_EXISTING_NODE_SHORT_ID__"]
    }
  }
}
EOF
            ;;
        xhttp_reality)
            cat <<EOF
{
  "tag": "__SET_UNIQUE_INBOUND_TAG__",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "target": "127.0.0.1:9443",
      "xver": 0,
      "serverNames": ["$domain"],
      "privateKey": "__REUSE_EXISTING_NODE_PRIVATE_KEY__",
      "shortIds": ["__REUSE_EXISTING_NODE_SHORT_ID__"]
    },
    "xhttpSettings": {"path": "/__SET_SHARED_XHTTP_PATH__"}
  }
}
EOF
            ;;
        xhttp_tls)
            cat <<EOF
{
  "tag": "__SET_UNIQUE_INBOUND_TAG__",
  "listen": "127.0.0.1",
  "port": 8443,
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "serverName": "$domain",
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "alpn": ["h2", "http/1.1"],
      "certificates": [{
        "certificateFile": "/etc/letsencrypt/live/current/fullchain.pem",
        "keyFile": "/etc/letsencrypt/live/current/privkey.pem"
      }]
    },
    "xhttpSettings": {"path": "/__SET_SHARED_XHTTP_PATH__"}
  }
}
EOF
            ;;
        grpc_tls)
            cat <<EOF
{
  "tag": "__SET_UNIQUE_INBOUND_TAG__",
  "listen": "127.0.0.1",
  "port": 8444,
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "streamSettings": {
    "network": "grpc",
    "security": "tls",
    "tlsSettings": {
      "serverName": "$domain",
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "alpn": ["h2", "http/1.1"],
      "certificates": [{
        "certificateFile": "/etc/letsencrypt/live/current/fullchain.pem",
        "keyFile": "/etc/letsencrypt/live/current/privkey.pem"
      }]
    },
    "grpcSettings": {"serviceName": "__SET_UNIQUE_SERVICE_NAME__"}
  }
}
EOF
            ;;
        *) return 2 ;;
    esac
}

render_xhttp_client_mode() {
    local domain=$1 mode=$2
    valid_domain "$domain" || return 2
    case $mode in auto|stream-one|stream-up|packet-up) ;; *) return 2 ;; esac
    cat <<EOF
{
  "tag": "__SET_OUTBOUND_TAG__",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$domain",
      "port": 443,
      "users": [{"id": "__SET_USER_UUID__", "encryption": "none"}]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$domain",
      "fingerprint": "__SELECT_SUPPORTED_CLIENT_FINGERPRINT__",
      "publicKey": "__SET_PUBLIC_KEY_FROM_PANEL__",
      "shortId": "__SET_EXISTING_SHORT_ID__",
      "spiderX": "/"
    },
    "xhttpSettings": {
      "path": "/__SET_SHARED_XHTTP_PATH__",
      "mode": "$mode"
    }
  }
}
EOF
}

render_transport_client() {
    local transport=$1 domain=$2
    valid_domain "$domain" || return 2
    case $transport in
        tcp_tls)
            cat <<EOF
{
  "tag": "__SET_OUTBOUND_TAG__",
  "protocol": "vless",
  "settings": {"vnext": [{"address": "$domain", "port": 443, "users": [{"id": "__SET_USER_UUID__", "encryption": "none"}]}]},
  "streamSettings": {
    "network": "raw",
    "security": "tls",
    "tlsSettings": {"serverName": "$domain", "fingerprint": "__SELECT_SUPPORTED_CLIENT_FINGERPRINT__", "alpn": ["h2", "http/1.1"]}
  }
}
EOF
            ;;
        tcp_reality)
            cat <<EOF
{
  "tag": "__SET_OUTBOUND_TAG__",
  "protocol": "vless",
  "settings": {"vnext": [{"address": "$domain", "port": 443, "users": [{"id": "__SET_USER_UUID__", "encryption": "none"}]}]},
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {"serverName": "$domain", "fingerprint": "__SELECT_SUPPORTED_CLIENT_FINGERPRINT__", "publicKey": "__SET_PUBLIC_KEY_FROM_PANEL__", "shortId": "__SET_EXISTING_SHORT_ID__", "spiderX": "/"}
  }
}
EOF
            ;;
        xhttp_tls)
            cat <<EOF
{
  "tag": "__SET_OUTBOUND_TAG__",
  "protocol": "vless",
  "settings": {"vnext": [{"address": "$domain", "port": 443, "users": [{"id": "__SET_USER_UUID__", "encryption": "none"}]}]},
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {"serverName": "$domain", "fingerprint": "__SELECT_SUPPORTED_CLIENT_FINGERPRINT__", "alpn": ["h2", "http/1.1"]},
    "xhttpSettings": {"path": "/__SET_SHARED_XHTTP_PATH__", "mode": "auto"}
  }
}
EOF
            ;;
        grpc_tls)
            cat <<EOF
{
  "tag": "__SET_OUTBOUND_TAG__",
  "protocol": "vless",
  "settings": {"vnext": [{"address": "$domain", "port": 443, "users": [{"id": "__SET_USER_UUID__", "encryption": "none"}]}]},
  "streamSettings": {
    "network": "grpc",
    "security": "tls",
    "tlsSettings": {"serverName": "$domain", "fingerprint": "__SELECT_SUPPORTED_CLIENT_FINGERPRINT__", "alpn": ["h2"]},
    "grpcSettings": {"serviceName": "__SET_UNIQUE_SERVICE_NAME__"}
  }
}
EOF
            ;;
        *) return 2 ;;
    esac
}

extract_transport_pairs() {
    python3 -c 'import json,sys
s=sys.stdin.read(); d=json.JSONDecoder(); pairs=set()
def walk(v):
    if isinstance(v,dict):
        for inbound in v.get("inbounds",[]):
            if not isinstance(inbound,dict): continue
            ss=inbound.get("streamSettings") or {}
            if not isinstance(ss,dict): continue
            network=ss.get("network") or "raw"
            security=ss.get("security") or "none"
            if isinstance(network,str) and isinstance(security,str): pairs.add(network+"|"+security)
        for child in v.values(): walk(child)
    elif isinstance(v,list):
        for child in v: walk(child)
i=0
while i<len(s):
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    try: value,end=d.raw_decode(s,i)
    except json.JSONDecodeError: break
    walk(value); i=end
for pair in sorted(pairs): print(pair)'
}

runtime_transport_pairs() {
    local config
    docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true || return 1
    config=$(docker exec remnanode sh -c 'find /etc /usr/local/etc /opt/remnanode -type f -name "*.json" -exec cat {} \; 2>/dev/null' 2>/dev/null) || return 1
    printf '%s' "$config" | extract_transport_pairs
}

transport_pair_label() {
    case $1 in
        raw\|tls) printf 'VLESS RAW/TCP + TLS\n' ;;
        raw\|reality) printf 'VLESS RAW/TCP + REALITY\n' ;;
        xhttp\|reality) printf 'VLESS XHTTP + REALITY\n' ;;
        xhttp\|tls) printf 'VLESS XHTTP + TLS\n' ;;
        grpc\|tls) printf 'VLESS gRPC + TLS\n' ;;
        grpc\|reality) printf 'VLESS gRPC + REALITY\n' ;;
        *) printf 'другой транспорт (%s)\n' "$1" ;;
    esac
}

transport_pair_active() {
    local pairs=$1 pair=$2
    grep -Fxq "$pair" <<<"$pairs"
}

transport_pair_slug() {
    case $1 in
        raw\|tls) printf 'tcp-tls\n' ;;
        raw\|reality) printf 'tcp-reality\n' ;;
        xhttp\|reality) printf 'xhttp-reality\n' ;;
        xhttp\|tls) printf 'xhttp-tls\n' ;;
        grpc\|tls) printf 'grpc-tls\n' ;;
        *) return 1 ;;
    esac
}

transport_candidate_prepared() {
    local slug=$1 root path
    root=$(transport_state_root)
    [[ -d $root/candidates ]] || return 1
    for path in "$root"/candidates/*-"$slug".*; do
        [[ -d $path && -s $path/inbound.json && -s $path/README.md && ! -e $path/FAILED ]] && return 0
    done
    return 1
}

show_transport_status() {
    local pairs pair label state slug backend_state='NOT TESTED'
    pairs=$(runtime_transport_pairs 2>/dev/null) || pairs=''
    ui_print ''
    ui_print 'ТРАНСПОРТЫ · runtime и сетевые проверки разделены'
    if [[ -z $pairs ]]; then
        ui_print 'Runtime транспорта: NOT TESTED (rw-core config не прочитан или inbound не найден).'
    else
        while IFS= read -r pair; do
            [[ -n $pair ]] || continue
            label=$(transport_pair_label "$pair")
            ui_wrap "ACTIVE · $label (найден в runtime-конфигурации; listener и клиентский handshake отдельно не подтверждены)"
        done <<<"$pairs"
    fi
    ui_print ''
    ui_print '  Транспорт | Схема | Runtime'
    for pair in 'raw|tls' 'raw|reality' 'xhttp|reality' 'xhttp|tls' 'grpc|tls'; do
        label=$(transport_pair_label "$pair")
        slug=$(transport_pair_slug "$pair")
        if [[ -n $pairs ]] && transport_pair_active "$pairs" "$pair"; then state=ACTIVE
        elif transport_candidate_prepared "$slug"; then state=PREPARED
        elif [[ -z $pairs ]]; then state='NOT TESTED'
        else state=SUPPORTED; fi
        ui_wrap "$label | $state | Xray schema supported; installed-core validation is separate"
    done
    if [[ -n $DOMAIN ]]; then
        if https_backend_ready; then backend_state=HEALTHY; else backend_state=FAILED; fi
    fi
    status_row 'HTTPS target 127.0.0.1:9443' "$backend_state" 'Проверка настоящего HTTPS-ответа сайта; не является проверкой VPN'
    status_row 'VLESS / пользовательский трафик' 'NOT TESTED' 'Нужна разрешённая клиентская конфигурация и end-to-end запрос'
    status_row 'Happ iOS / Android' 'NOT TESTED' 'Версия приложения и поддержка режимов не получены'
    status_row 'Node / Panel dependencies' 'NOT TESTED' 'Требуется проверка Node, Hosts, Squads и пользователей в панели'
    ui_print ''
    ui_wrap 'SUPPORTED описывает схему Xray в официальной документации, а не текущую сборку Node или Happ. ACTIVE означает найденный inbound в файлах runtime, а не успешный listener или VPN.'
}

new_transport_candidate_dir() {
    local slug=$1 root stamp canonical
    root=$(transport_state_root)
    [[ $root == /* && ! -L $root ]] || return 1
    canonical=$(realpath -m -- "$root") || return 1
    [[ $canonical == "$root" ]] || return 1
    [[ ! -e $root || -d $root ]] || return 1
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    command mkdir -p "$root/candidates" || return 1
    [[ ! -L $root/candidates && -d $root/candidates ]] || return 1
    command chmod 0700 "$root" "$root/candidates" || return 1
    command mktemp -d "$root/candidates/${stamp}-${slug}.XXXXXX"
}

write_transport_manifest() {
    local path=$1 kind=$2 domain=$3
    cat >"$path/README.md" <<EOF
# Подготовленный кандидат транспорта

- Тип: $kind
- Домен Node: $domain
- Состояние: PREPARED ONLY
- Профиль Remnawave создан/назначен: нет
- Node, Host, Squad или пользователь изменены: нет
- Xray, Remnanode, Nginx, Docker, firewall или сертификаты изменены: нет
- Перезапуск сервиса: нет
- VPN end-to-end: NOT TESTED

inbound.json — только обезличенный фрагмент для ручной проверки. JSON синтаксис проверен, но фрагмент не является полной Config Profile и не прошёл валидацию установленной версии Xray.

Перед активацией в панели сохраните текущий Config Profile, список активных inbound, привязки Node/Host и затронутые Squads. Сохраните все действующие inbound и routing. Новый транспорт требует согласованного Host и отдельной проверки выдаваемого клиентского профиля.

Не применяйте фрагмент напрямую в runtime-контейнере. Если API панели не настроен и не прошёл проверку, дальнейшая активация выполняется вручную в Remnawave после отдельного согласования.
EOF
    command chmod 0600 "$path/README.md"
}

prepare_transport_candidate() {
    local transport=$1 slug label path mode
    [[ $EUID -eq 0 || -n $TRANSPORT_STATE_OVERRIDE ]] || { ui_print 'Для записи кандидата нужны права root.'; return 1; }
    valid_domain "$DOMAIN" || { ui_print 'Сначала задайте корректный домен Node.'; return 1; }
    slug=$(transport_slug "$transport") || return 2
    label=$(transport_label "$transport") || return 2
    path=$(new_transport_candidate_dir "$slug") || { ui_print 'Не удалось создать изолированный каталог кандидата.'; return 1; }
    command chmod 0700 "$path" || return 1
    render_transport_inbound "$transport" "$DOMAIN" >"$path/inbound.json" || return 1
    if ! python3 -m json.tool "$path/inbound.json" >/dev/null; then
        printf '%s\n' 'inbound JSON validation failed' >"$path/FAILED"
        command chmod 0600 "$path/FAILED"
        ui_print 'Сгенерированный фрагмент JSON не прошёл проверку; каталог помечен FAILED.'
        return 1
    fi
    command chmod 0600 "$path/inbound.json" || return 1
    if [[ $transport != xhttp_reality ]]; then
        render_transport_client "$transport" "$DOMAIN" >"$path/client-xray.json" || return 1
        python3 -m json.tool "$path/client-xray.json" >/dev/null || return 1
        command chmod 0600 "$path/client-xray.json" || return 1
    fi
    write_transport_manifest "$path" "$label" "$DOMAIN" || return 1
    if [[ $transport == xhttp_reality ]]; then
        for mode in auto stream-one stream-up packet-up; do
            render_xhttp_client_mode "$DOMAIN" "$mode" >"$path/client-$mode.json" || return 1
            if ! python3 -m json.tool "$path/client-$mode.json" >/dev/null; then
                printf '%s\n' "client JSON validation failed: $mode" >"$path/FAILED"
                command chmod 0600 "$path/FAILED"
                return 1
            fi
            command chmod 0600 "$path/client-$mode.json" || return 1
        done
        {
            printf '%s\n' '# XHTTP mode matrix: client-side Xray JSON, not Happ import'
            printf '%s\n' 'Test one mode at a time. Server inbound intentionally omits mode and keeps the core default.'
            printf '%s\n' 'iOS stream-up is a test hypothesis only; no client test was run.'
        } >"$path/xhttp-client-modes.txt"
        command chmod 0600 "$path/xhttp-client-modes.txt" || return 1
    fi
    ui_print "Кандидат сохранён: $path"
    ui_wrap 'Создан только новый каталог с обезличенным фрагментом и инструкцией. Настройки активных сервисов и панели не менялись.'
    ui_wrap 'Для полноценной валидации замените placeholders, соберите полный профиль и проверьте его на изолированном узле с той же версией Xray.'
}

prepare_xhttp_modes() {
    local path mode
    [[ $EUID -eq 0 || -n $TRANSPORT_STATE_OVERRIDE ]] || { ui_print 'Для записи кандидата нужны права root.'; return 1; }
    valid_domain "$DOMAIN" || { ui_print 'Сначала задайте корректный домен Node.'; return 1; }
    path=$(new_transport_candidate_dir xhttp-client-modes) || { ui_print 'Не удалось создать изолированный каталог кандидата.'; return 1; }
    command chmod 0700 "$path" || return 1
    for mode in auto stream-one stream-up packet-up; do
        render_xhttp_client_mode "$DOMAIN" "$mode" >"$path/client-$mode.json" || return 1
        if ! python3 -m json.tool "$path/client-$mode.json" >/dev/null; then
            printf '%s\n' "client JSON validation failed: $mode" >"$path/FAILED"
            command chmod 0600 "$path/FAILED"
            return 1
        fi
        command chmod 0600 "$path/client-$mode.json" || return 1
    done
    write_transport_manifest "$path" 'XHTTP REALITY client mode matrix' "$DOMAIN" || return 1
    ui_print "XHTTP-кандидаты сохранены: $path"
    ui_wrap 'Подготовлены auto, stream-one, stream-up и packet-up. Это клиентские Xray JSON шаблоны; совместимость Happ iOS/Android не проверена.'
}

show_transport_activation_plan() {
    local root latest
    root=$(transport_state_root)
    latest=$(printf '%s\n' "$root"/candidates/* 2>/dev/null | sort -r | head -n1)
    ui_print ''
    ui_print 'ПЕРЕКЛЮЧЕНИЕ · ПЛАН, БЕЗ ИЗМЕНЕНИЙ'
    ui_wrap "Последний локальный кандидат: ${latest:-не найден}"
    ui_wrap 'Текущий Config Profile, другие Nodes, inbound, Hosts, Squads и число пользователей из панели не прочитаны: API не настроен. Не переключайте Node до проверки зависимостей.'
    ui_wrap '1. Экспортируйте текущий профиль и зафиксируйте назначение Node и активные inbound.'
    ui_wrap '2. Проверьте Hosts, Squads и пользователей, которые получают текущий inbound.'
    ui_wrap '3. Создайте отдельный профиль. Сохраните действующие inbound и routing; новый фрагмент добавляйте только как кандидат.'
    ui_wrap '4. Сначала обновите тестовый Host/клиент и проверьте выданный Remnawave профиль.'
    ui_wrap '5. Переключайте только согласованную canary Node после backup и окна работ.'
    ui_wrap '6. При сбое верните Node на сохранённый профиль и прежний набор enabled inbounds; восстановите Host только если он менялся.'
    ui_wrap 'Если текущий inbound уже занимает тот же TCP/443, второй inbound нельзя считать параллельным canary на том же socket. Нужна отдельная тестовая Node или явно согласованный свободный endpoint.'
    ui_wrap 'Автоматическая активация и rollback через панель не выполняются. Смена единственного inbound на 443 может оборвать подключения.'
}

show_transport_compatibility() {
    local image core_version
    image=$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null) || image='NOT TESTED'
    core_version=$(docker exec remnanode sh -c 'command -v xray >/dev/null 2>&1 && xray version' 2>/dev/null | head -n1) || core_version=''
    [[ -n $core_version ]] || core_version='NOT TESTED (binary/version command unavailable)'
    ui_print ''
    ui_print 'СОВМЕСТИМОСТЬ · локальные факты и внешние ограничения'
    status_row 'Remnanode image' "$([[ $image == NOT\ TESTED ]] && printf 'NOT TESTED' || printf 'PASS')" "$image"
    status_row 'Xray version' "$([[ $core_version == NOT\ TESTED* ]] && printf 'NOT TESTED' || printf 'PASS')" "$core_version"
    status_row 'XHTTP schema' 'SUPPORTED' 'Официальная Xray схема включает VLESS over XHTTP с TLS и REALITY; installed-core validation is separate'
    status_row 'gRPC TLS schema' 'SUPPORTED' 'Официальная Xray схема включает gRPC over TLS; HTTP/2 и ALPN h2 проверяются отдельно'
    status_row 'gRPC REALITY candidate' 'NOT TESTED' 'не подготавливается: нет проверенного сайта/fallback и клиентского сценария'
    status_row 'Happ iOS / Android' 'NOT TESTED' 'нет подтверждённых версий Happ и разрешённого тестового клиента'
    status_row 'XHTTP mode / extra в Host' 'NOT TESTED' 'нужна проверка фактически выданного профиля через панель'
    ui_wrap 'gRPC не является SELFSTEAL с обычным HTTPS fallback: Xray предупреждает, что gRPC не поддерживает fallback. Не включайте его на единственном production 443 без отдельной проверенной reverse-proxy схемы.'
}

show_transport_history() {
    local root item found=0
    root=$(transport_state_root)
    ui_print ''
    ui_print 'ИСТОРИЯ ПОДГОТОВЛЕННЫХ КАНДИДАТОВ'
    if [[ -d $root/candidates ]]; then
        while IFS= read -r item; do
            [[ -d $item ]] || continue
            found=1
            if [[ -e $item/FAILED ]]; then
                ui_wrap "FAILED · $(basename "$item")"
            elif [[ -s $item/README.md && ( -s $item/inbound.json || -s $item/client-auto.json ) ]]; then
                ui_wrap "PREPARED ONLY · $(basename "$item")"
            else
                ui_wrap "INCOMPLETE · $(basename "$item")"
            fi
        done < <(printf '%s\n' "$root"/candidates/* | sort -r)
    fi
    ((found)) || ui_print 'Кандидатов пока нет.'
    ui_wrap 'Эта история содержит только экспортированные файлы. Она не подтверждает активный профиль и не может сама откатить панель.'
}

transport_manager_help() {
    ui_print ''
    ui_print 'СПРАВКА · МЕНЕДЖЕР ТРАНСПОРТОВ'
    ui_wrap '1 Статус — только чтение runtime transport и HTTPS backend. Не запускает handshake и не меняет файлы/сервисы.'
    ui_wrap '2 Подготовить inbound — после подтверждения создаёт новый каталог кандидата с JSON-фрагментом и README. Не меняет Nginx, Docker, Xray, Remnawave или сертификаты.'
    ui_wrap '3 XHTTP mode matrix — после подтверждения сохраняет клиентские Xray JSON примеры auto, stream-one, stream-up и packet-up. Не является импортом Happ.'
    ui_wrap '4 План активации/rollback — только чтение; вручную проверяются зависимости панели и возврат предыдущего профиля.'
    ui_wrap '5 Совместимость — только чтение; версия Happ и реальные клиентские проверки останутся NOT TESTED без теста.'
    ui_wrap '6 Шаблоны — только чтение; показывает базовые TLS и REALITY параметры.'
    ui_wrap '7 История — только чтение; список локальных кандидатов. Они не означают, что профиль активирован.'
}

transport_manager_menu() {
    local choice transport
    while :; do
        ui_print ''
        ui_print 'VOID · ТРАНСПОРТЫ'
        ui_print '[1] Статус транспортов'
        ui_wrap 'Только чтение: runtime inbound и HTTPS backend; VPN-handshake отдельно NOT TESTED.'
        ui_print '[2] Подготовить inbound-кандидат'
        ui_wrap 'Создаёт отдельные локальные JSON/README файлы после подтверждения; активные сервисы не затрагивает.'
        ui_print '[3] Подготовить XHTTP mode matrix'
        ui_wrap 'Сохраняет клиентские примеры auto, stream-one, stream-up и packet-up; Happ не меняет.'
        ui_print '[4] План переключения и rollback'
        ui_wrap 'Только чтение: зависимости панели не получены, ручной canary и возврат профиля.'
        ui_print '[5] Совместимость Remnawave / Happ'
        ui_wrap 'Только чтение; версия ядра и реальные клиентские проверки разделяются.'
        ui_print '[6] Шаблоны профиля'
        ui_wrap 'Только чтение: текущие безопасные TLS и REALITY параметры.'
        ui_print '[7] История кандидатов'
        ui_wrap 'Только чтение: записи PREPARED, без предположений об активном транспорте.'
        ui_print '[H] Справка по операциям'
        ui_print '[0] Назад'
        printf 'Выберите пункт: ' >&"$(ui_output_fd)"
        if ! ui_read choice; then return 0; fi
        case ${choice,,} in
            1) load_state || true; show_transport_status ;;
            2)
                ui_print 'Кандидат: [1] TCP TLS  [2] TCP REALITY  [3] XHTTP REALITY  [4] XHTTP TLS  [5] gRPC TLS  [0] Назад'
                prompt 'Тип транспорта: ' transport
                case $transport in
                    1) transport=tcp_tls ;;
                    2) transport=tcp_reality ;;
                    3) transport=xhttp_reality ;;
                    4) transport=xhttp_tls ;;
                    5) transport=grpc_tls ;;
                    0) continue ;;
                    *) ui_print 'Неизвестный тип транспорта.'; continue ;;
                esac
                load_state || ask_value 'Домен этой Node: ' DOMAIN valid_domain
                ui_wrap "Будет создан только новый каталог кандидата для $(transport_label "$transport"). Профиль, Host, Nginx, Docker, Xray, сертификаты и сервисы не изменятся."
                if confirm_action 'Сохранить подготовленный шаблон?'; then prepare_transport_candidate "$transport" || warn 'Кандидат не создан.'
                else ui_print 'Подготовка отменена; файлы не менялись.'; fi
                ;;
            3)
                load_state || ask_value 'Домен этой Node: ' DOMAIN valid_domain
                ui_wrap 'Будет создан новый каталог с четырьмя XHTTP-клиентскими JSON шаблонами. Panel, Host, Xray и сервисы не меняются.'
                if confirm_action 'Сохранить XHTTP mode matrix?'; then prepare_xhttp_modes || warn 'XHTTP шаблоны не созданы.'
                else ui_print 'Подготовка отменена; файлы не менялись.'; fi
                ;;
            4) show_transport_activation_plan ;;
            5) show_transport_compatibility ;;
            6) load_state || true; show_profile_templates ;;
            7) show_transport_history ;;
            h) transport_manager_help ;;
            0) return 0 ;;
            *) ui_print 'Неизвестный пункт. Введите 0–7 или H.' ;;
        esac
    done
}

# Return free, remnawave, nginx, or unknown. Xray ownership is confirmed by
# matching the socket PID to docker top remnanode and its comm name.
classify_443_owner() {
    local proto=$1 sockets top host_processes rows pids pid comm container_comm found
    if (($# >= 2)); then sockets=$2; else sockets=$(ss -H -lntup 2>/dev/null || true); fi
    if (($# >= 3)); then top=$3; else top=$(docker top remnanode -eo pid,comm,args 2>/dev/null || true); fi
    if (($# >= 4)); then host_processes=$4; else host_processes=$(ps -e -o pid=,comm= 2>/dev/null || true); fi
    rows=$(printf '%s\n' "$sockets" | awk -v proto="$proto" '$1 == proto && $5 ~ /:443$/')
    [[ -n $rows ]] || { printf 'free\n'; return 0; }
    if printf '%s\n' "$rows" | grep -Ev 'users:.*pid=[0-9]+' | grep -q .; then printf 'unknown\n'; return 0; fi
    pids=$(printf '%s\n' "$rows" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
    [[ -n $pids ]] || { printf 'unknown\n'; return 0; }
    found=0
    while IFS= read -r pid; do
        [[ -n $pid ]] || continue
        comm=$(printf '%s\n' "$host_processes" | awk -v pid="$pid" '$1 == pid {print $2; exit}')
        case ${comm,,} in nginx|nginx:* ) printf 'nginx\n'; return 0 ;; esac
        container_comm=$(printf '%s\n' "$top" | awk -v pid="$pid" '$1 == pid {print $2; exit}')
        case ${container_comm,,} in xray|rw-core|remnanode|xray-*|rw-core-* ) found=$((found + 1)) ;; *) printf 'unknown\n'; return 0 ;; esac
    done <<<"$pids"
    [[ $found -gt 0 ]] && printf 'remnawave\n' || printf 'unknown\n'
}

check_443_ports() {
    local proto owner socket_info
    for proto in tcp udp; do
        owner=$(classify_443_owner "$proto")
        case $owner in
            free) say "${proto^^}/443 PASS: free." ;;
            remnawave) say "${proto^^}/443 already owned by Remnawave/Xray." ;;
            nginx)
                say "${proto^^}/443 FAIL: Nginx must not own port 443."
                ss -lntup 2>/dev/null | awk -v proto="$proto" '$1 == proto && $5 ~ /:443$/ {print}'
                die "${proto^^}/443 is owned by Nginx. No changes made."
                ;;
            *)
                say "${proto^^}/443 FAIL: unknown owner."
                socket_info=$(ss -lntup 2>/dev/null | awk -v proto="$proto" '$1 == proto && $5 ~ /:443$/')
                [[ -z $socket_info ]] || printf '%s\n' "$socket_info"
                die "Cannot verify the ${proto^^}/443 owner; no changes made."
                ;;
        esac
    done
}

check_prerequisites() {
    [[ $EUID -eq 0 ]] || die 'Запустите скрипт от root.'
    [[ -r /etc/os-release ]] || die 'Не удалось определить ОС.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || die 'Поддерживаются только Debian и Ubuntu.'
    if ! has docker || ! docker compose version >/dev/null 2>&1; then die 'Docker и Docker Compose plugin обязательны.'; fi
    if ! has ss || ! has python3 || ! has openssl || ! has curl; then die 'Необходимы ss, python3, openssl и curl.'; fi
    [[ -f $NODE_COMPOSE ]] || die "Не найден $NODE_COMPOSE; сначала установите Node обычным способом."
    docker ps || die 'docker ps завершился ошибкой.'
    docker compose -f "$NODE_COMPOSE" config >/dev/null || die 'Текущий Compose не проходит проверку; изменений нет.'
    docker inspect remnanode >/dev/null 2>&1 || die 'Контейнер remnanode не найден.'
    say 'Listeners сейчас:'; ss -lntup
    check_443_ports
    if port_is_listening 80 && ! port_owner 80 | grep -q nginx; then
        say 'TCP/80 занят не Nginx:'; port_owner 80
        die 'Отказ от изменения неизвестного сервиса на TCP/80.'
    fi
    if port_is_listening 8080 && ! port_owner 8080 | grep -q nginx; then
        say 'TCP/8080 занят не Nginx:'; port_owner 8080
        die 'Отказ от конфликта fallback listener на TCP/8080.'
    fi
    if port_is_listening 8080 && ! grep -Fq 'listen 127.0.0.1:8080;' "$NGINX_FILE" 2>/dev/null; then
        say 'TCP/8080 уже обслуживается другой конфигурацией Nginx:'; port_owner 8080
        die 'Отказ от дублирования Nginx fallback listener.'
    fi
    if port_is_listening 9443; then
        local owner config
        owner=$(port_owner 9443); config=$(cat "$NGINX_FILE" 2>/dev/null || true)
        if ! managed_nginx_9443_listener "$owner" "$config"; then
            say 'TCP/9443 занят неизвестным процессом:'; printf '%s\n' "$owner"
            die 'Отказ от перезаписи неизвестного listener на TCP/9443.'
        fi
    fi
}

filter_aaaa_records() {
    awk 'NF && tolower($1) !~ /^::ffff:/ {print $1}' | sort -u
}

check_dns_record_match() {
    local a_records=$1 aaaa_records=$2 public4=$3 public6=$4
    if [[ -n $a_records ]]; then
        if [[ -z $public4 ]] || [[ $(printf '%s\n' "$a_records" | grep -Fxvc "$public4") != 0 ]]; then return 1; fi
    fi
    if [[ -n $aaaa_records ]]; then
        if [[ -z $public6 ]] || [[ $(printf '%s\n' "$aaaa_records" | grep -Fxvc "$public6") != 0 ]]; then return 2; fi
    fi
    return 0
}

check_dns() {
    local a_records aaaa_records public4 public6 result
    a_records=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)
    aaaa_records=$(getent ahostsv6 "$DOMAIN" | filter_aaaa_records || true)
    [[ -n $a_records || -n $aaaa_records ]] || { say 'DNS CHECK: FAIL'; die "Для $DOMAIN не найдены A/AAAA записи."; }
    public4=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    public6=$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)
    say "A records: ${a_records:-none}; detected IPv4: ${public4:-unavailable}"
    say "AAAA records: ${aaaa_records:-none}; detected IPv6: ${public6:-unavailable}"
    if check_dns_record_match "$a_records" "$aaaa_records" "$public4" "$public6"; then :
    else
        result=$?
        say 'DNS CHECK: FAIL'
        case $result in
            1) die 'A-записи должны указывать только на IPv4 этой Node; сертификат не запрашивался.' ;;
            2) die 'AAAA-записи должны указывать только на IPv6 этой Node; сертификат не запрашивался.' ;;
            *) die 'DNS records could not be validated.' ;;
        esac
    fi
    say 'DNS CHECK: PASS'
}

ensure_nginx() {
    if ! has nginx; then
        confirm_or_cancel 'Пакет Nginx отсутствует. Будут установлены Nginx и его зависимости; после настройки Nginx может быть запущен.'
        printf 'Nginx отсутствует. Для установки через apt и изменений введите APPLY: ' >&"$TTY_FD"
        local answer
        IFS= read -r -u "$TTY_FD" answer || die 'Не удалось прочитать подтверждение.'
        [[ $answer == APPLY ]] || die 'Подготовка отменена; изменений нет.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
    fi
    systemctl is-active --quiet nginx && NGINX_WAS_ACTIVE=1 || NGINX_WAS_ACTIVE=0
    local file existing_domain=0
    while IFS= read -r file; do
        [[ $file == "$NGINX_FILE" ]] && continue
        if grep -Eq "server_name[^;]*[[:space:]]${DOMAIN//./\\.}([[:space:];]|$)" "$file"; then existing_domain=1; break; fi
    done < <(grep -RIl 'server_name' /etc/nginx 2>/dev/null || true)
    ((existing_domain == 0)) || die "В Nginx уже задан server_name $DOMAIN; отказ от дублирующего блока."
    confirm_or_cancel "При необходимости будут созданы webroot/ACME-каталоги и стартовая страница в $WEB_ROOT. Nginx-конфигурация будет изменена только после отдельного подтверждения."
    if [[ -e $NGINX_FILE ]] && ! grep -Fq 'Managed by remnawave-node-tls-setup.sh' "$NGINX_FILE"; then
        die "$NGINX_FILE существует и не помечен как файл этого установщика; перезапись запрещена."
    fi
    mkdir -p "$WEB_ROOT"
    ensure_acme_webroot_permissions
    if [[ -e $WEB_ROOT/index.html ]] && ! grep -Fq '<h1>Hello World</h1>' "$WEB_ROOT/index.html"; then
        say "Using existing website in $WEB_ROOT."
    fi
    if [[ ! -e $WEB_ROOT/index.html ]]; then cat >"$WEB_ROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Hello World</title>
</head>
<body>
    <h1>Hello World</h1>
</body>
</html>
HTML
    fi
    local rendered
    if [[ -r $CERTS_DIR/live/current/fullchain.pem && -r $CERTS_DIR/live/current/privkey.pem ]]; then rendered=$(render_nginx "$DOMAIN" 1)
    else rendered=$(render_nginx "$DOMAIN")
    fi
    if [[ ! -f $NGINX_FILE || $(cat "$NGINX_FILE") != "$rendered" ]]; then
        confirm_or_cancel "Будет изменён файл $NGINX_FILE. После nginx -t потребуется применить конфигурацию через reload или запуск Nginx."
        backup_file "$NGINX_FILE"
        printf '%s\n' "$rendered" >"$NGINX_FILE"
        NGINX_CHANGED=1
        nginx -t || die 'nginx -t failed; изменение будет отменено.'
        if ((NGINX_WAS_ACTIVE)); then
            confirm_or_cancel 'Подтвердите reload Nginx для применения новой конфигурации.'
            systemctl reload nginx
        else
            confirm_or_cancel 'Nginx не запущен. Подтвердите его включение и запуск.'
            systemctl enable --now nginx
        fi
        NGINX_RELOADED=1
    fi
    if ! systemctl is-active --quiet nginx; then
        confirm_or_cancel 'Nginx остановлен. Подтвердите его включение и запуск.'
        systemctl enable --now nginx
    fi
    nginx -t || die 'nginx -t failed.'
    verify_managed_nginx_config
    http_backend_ready || die 'Fallback 127.0.0.1:8080 is not serving the configured website.'
    check_http_acme || die 'Nginx HTTP-01 webroot validation failed.'
}

ensure_acme_webroot_permissions() {
    install -d -m 0755 "$CERTBOT_DIR" "$WEBROOT" "$WEBROOT/.well-known" "$WEBROOT/.well-known/acme-challenge"
    chmod 0755 "$CERTBOT_DIR" "$WEBROOT" "$WEBROOT/.well-known" "$WEBROOT/.well-known/acme-challenge"
}

effective_nginx_config_has_managed_block() {
    local config=$1 marker
    for marker in \
        "# configuration file $NGINX_FILE:" \
        "server_name $DOMAIN;" \
        'location ^~ /.well-known/acme-challenge/' \
        "location / { return 301 https://\$host\$request_uri; }" \
        "root $WEBROOT;" \
        'listen 80;'; do
        grep -Fq -- "$marker" <<<"$config" || return 1
    done
    if [[ -r $CERTS_DIR/live/current/fullchain.pem ]]; then
        for marker in 'listen 127.0.0.1:9443 ssl;' 'add_header Strict-Transport-Security "max-age=300" always;' "$CERTS_DIR/live/current/fullchain.pem" "$CERTS_DIR/live/current/privkey.pem"; do
            grep -Fq -- "$marker" <<<"$config" || return 1
        done
    fi
}

verify_managed_nginx_config() {
    local config
    config=$(nginx -T 2>&1) || die 'Не удалось прочитать effective Nginx config через nginx -T.'
    effective_nginx_config_has_managed_block "$config" || die "Managed Nginx server block для $DOMAIN не загружен в effective config (nginx -T)."
}

http_acme_probe_once() {
    local token=$1
    curl --noproxy '*' -fsS --max-time 5 -H "Host: $DOMAIN" \
        "http://127.0.0.1/.well-known/acme-challenge/$token"
}

sleep_half_second() { sleep 0.5; }

retry_http_acme_probe() {
    local token=$1 probe_fn=${2:-http_acme_probe_once} pause_fn=${3:-sleep_half_second}
    local response attempt
    for ((attempt = 1; attempt <= 10; attempt++)); do
        response=$("$probe_fn" "$token" "$attempt" 2>/dev/null || true)
        [[ $response == "$token" ]] && return 0
        ((attempt == 10)) || "$pause_fn" "$attempt"
    done
    return 1
}

mock_acme_probe_retry() {
    printf 'probe:%s\n' "$2" >>"$MOCK_ACME_PROBE_LOG"
    (( ${2:-0} >= 2 )) && printf '%s' "$1"
}
mock_acme_probe_missing() { printf 'probe:%s\n' "$2" >>"$MOCK_ACME_PROBE_LOG"; printf 'not-the-token'; }
mock_acme_pause() { printf 'pause:%s\n' "$1" >>"$MOCK_ACME_PROBE_LOG"; }

diagnose_http_acme_failure() {
    local token=$1 challenge=$2 url="http://127.0.0.1/.well-known/acme-challenge/$1"
    say 'ACME LOCAL CHECK: FAIL' >&2
    say "DOMAIN: $DOMAIN" >&2
    say "CHALLENGE FILE: $challenge" >&2
    ls -ld -- /opt /opt/certbot /opt/certbot/www /opt/certbot/www/.well-known /opt/certbot/www/.well-known/acme-challenge 2>&1 >&2 || true
    ls -l -- "$challenge" 2>&1 >&2 || true
    curl -v --noproxy '*' --max-time 5 -H "Host: $DOMAIN" "$url" 2>&1 >&2 || true
    if [[ -r /var/log/nginx/error.log ]]; then
        say 'Relevant recent Nginx error.log lines:' >&2
        grep -Ei 'acme-challenge|permission denied|open\(.*failed|connect\(.*failed|404' /var/log/nginx/error.log | tail -n 30 >&2 || true
    else
        say 'Nginx error.log is not readable at /var/log/nginx/error.log.' >&2
    fi
}

check_http_acme() {
    local token challenge
    token="remna-check-${RANDOM}${RANDOM}"
    challenge="$WEBROOT/.well-known/acme-challenge/$token"
    ensure_acme_webroot_permissions
    install -m 0644 /dev/null "$challenge"
    printf '%s' "$token" >"$challenge"
    chmod 0644 "$challenge"
    if retry_http_acme_probe "$token"; then
        rm -f -- "$challenge"
        ACME_CHECK_PASSED=1
        return 0
    fi
    diagnose_http_acme_failure "$token" "$challenge"
    rm -f -- "$challenge"
    return 1
}

ensure_certbot_compose() {
    confirm_or_cancel 'При необходимости будут созданы каталоги сертификатов/ACME и изменён /opt/certbot/docker-compose.yml только для требуемых mounts; перед правкой будет backup.'
    mkdir -p "$CERTS_DIR"
    ensure_acme_webroot_permissions
    local f=$CERTBOT_DIR/docker-compose.yml
    if [[ ! -f $f ]]; then
        backup_file "$f"
        CERTBOT_COMPOSE_CHANGED=1
        cat >"$f" <<'YAML'
services:
  certbot:
    image: certbot/certbot:latest
    volumes:
      - ./certs:/etc/letsencrypt
      - ./www:/var/www/certbot
YAML
    fi
    local patch_status=0
    patch_certbot_compose "$f" "$BACKUP_DIR" || patch_status=$?
    case $patch_status in
        0) ;;
        10)
            CERTBOT_COMPOSE_CHANGED=1
            if ! (cd "$CERTBOT_DIR" && docker compose config >/dev/null); then
                restore_file "$f"
                CERTBOT_COMPOSE_CHANGED=0
                die 'Certbot Compose config invalid; backup restored and installer stopped.'
            fi
            ;;
        4) die 'CERTBOT WEBROOT MOUNT CONFLICT' ;;
        *) die 'Existing Certbot Compose cannot be safely migrated.' ;;
    esac
    (cd "$CERTBOT_DIR" && docker compose config >/dev/null) || die 'Certbot Compose config invalid.'
}

certificate_valid() {
    local cert=$CERTS_DIR/live/$DOMAIN/fullchain.pem key=$CERTS_DIR/live/$DOMAIN/privkey.pem
    [[ -r $cert && -r $key ]] || return 1
    openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || return 1
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    local pubc pubk
    pubc=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    pubk=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    [[ $pubc == "$pubk" ]] && certificate_has_domain_san "$cert"
}

remnawave_core_ready() {
    docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true || return 1
    docker top remnanode -eo pid,comm 2>/dev/null | grep -Eiq '^[[:space:]]*[0-9]+[[:space:]]+(rw-core|xray)([[:space:]]|$)'
}

verify_container_certificate() {
    if ! docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true; then
        warn 'Remnanode container is not running; certificate visibility inside the container cannot be checked.'
        return 1
    fi
    if ! docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem; then
        warn 'Certificate fullchain.pem is not readable inside Remnanode.'
        return 1
    fi
    if ! docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem; then
        warn 'Certificate privkey.pem is not readable inside Remnanode.'
        return 1
    fi
    say 'Certificate files inside Remnanode: PASS'
}

wait_for_remnawave_core() {
    local attempts=${1:-15} delay=${2:-2} attempt
    for ((attempt=1; attempt<=attempts; attempt++)); do
        remnawave_core_ready && return 0
        ((attempt == attempts)) || sleep "$delay"
    done
    return 1
}

# shellcheck disable=SC2329 # Called from ensure_node_volume.
wait_for_container_certificate() {
    local attempts=${1:-15} delay=${2:-2} attempt
    for ((attempt=1; attempt<=attempts; attempt++)); do
        if container_certificate_ready; then
            verify_container_certificate
            return $?
        fi
        ((attempt == attempts)) || sleep "$delay"
    done
    verify_container_certificate
}

node_certificate_usage() {
    docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true || { printf 'UNKNOWN\n'; return 0; }
    local usage
    usage=$(docker exec remnanode sh -c 'for dir in /etc /usr/local/etc /opt/remnanode; do if [ -d "$dir" ]; then find "$dir" -type f -name "*.json" -exec cat {} \; 2>/dev/null; fi; done; exit 0' 2>/dev/null | python3 -c 'import json,sys
s=sys.stdin.read(); d=json.JSONDecoder(); found=0; used=False; i=0
def walk(v):
    global used
    if isinstance(v,str) and "/etc/letsencrypt/" in v: used=True
    elif isinstance(v,dict):
        for x in v.values(): walk(x)
    elif isinstance(v,list):
        for x in v: walk(x)
while i<len(s):
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    try: value,end=d.raw_decode(s,i)
    except json.JSONDecodeError: i+=1; continue
    found+=1; walk(value); i=end
print("USED" if used else "NOT_USED" if found else "UNKNOWN")' 2>/dev/null) || { printf 'UNKNOWN\n'; return 0; }
    case $usage in USED|NOT_USED) printf '%s\n' "$usage" ;; *) printf 'UNKNOWN\n' ;; esac
}

refresh_node_certificate_if_used() {
    local usage interactive=${1:-0} compose_changed=${COMPOSE_CHANGED:-0}
    usage=$(node_certificate_usage)
    case $usage in
        USED)
            if ((compose_changed)); then
                say 'Compose up -d уже пересоздал Remnanode после добавления certificate volume; дополнительный restart пропущен.'
            else
                if ((interactive)); then
                    confirm_or_cancel 'Xray/HY2 использует этот сертификат. Подтвердите restart Remnanode после обновления; VPN-подключения будут прерваны на время запуска.'
                fi
                docker compose -f "$NODE_COMPOSE" restart remnanode || return 1
            fi
            verify_container_certificate || return 1
            if wait_for_remnawave_core; then
                say 'rw-core/Xray process: PASS (VPN handshake and traffic are not tested).'
            else
                warn 'Certificate is available, but rw-core/Xray was not visible after 30 seconds. TLS setup remains valid; VPN readiness is NOT VERIFIED. Check Node status and Config Profile assignment in Remnawave.'
            fi
            ;;
        NOT_USED)
            say 'No Xray/Hysteria2 config references /etc/letsencrypt; Nginx was reloaded without restarting Remnanode.'
            if remnawave_core_ready; then say 'rw-core/Xray process is running; VPN handshake and traffic are not tested.'
            else warn 'No rw-core/Xray process is visible; VPN readiness is NOT VERIFIED. Check Node status and Config Profile assignment. TLS setup does not claim VPN readiness.'; fi
            ;;
        *)
            if ((compose_changed)); then say 'Compose up -d already applied the certificate volume; no additional Remnanode restart will be made.'; fi
            warn 'Could not determine whether Xray/HY2 uses the renewed certificate; Remnanode was not restarted to preserve VPN uptime. If it does use this certificate, its process may retain the previous certificate until a separately approved restart. Check Node status, Config Profile assignment, and the container configuration.'
            if remnawave_core_ready; then say 'rw-core/Xray process is running; VPN handshake and traffic are not tested.'
            else warn 'No rw-core/Xray process is visible; VPN readiness is NOT VERIFIED. Check Node status and Config Profile assignment. TLS setup does not claim VPN readiness.'; fi
            ;;
    esac
}

renewal_after_change() {
    local before=$1 after=$2
    [[ $before != "$after" ]] || return 0
    certificate_valid || { warn 'Renewal produced an invalid certificate, SAN, expiry, or key pair.'; return 1; }
    nginx -t || { warn 'nginx -t failed after certificate renewal.'; return 1; }
    systemctl reload nginx || { warn 'Nginx reload failed after certificate renewal.'; return 1; }
    http_redirect_ready || { warn 'HTTP 301 path/query check failed after certificate renewal.'; return 1; }
    https_backend_ready || { warn 'HTTPS backend 127.0.0.1:9443 failed after certificate renewal.'; return 1; }
    refresh_node_certificate_if_used || { warn 'Remnanode refresh failed after certificate renewal.'; return 1; }
}

issue_certificate() {
    local cert=$CERTS_DIR/live/$DOMAIN/fullchain.pem key=$CERTS_DIR/live/$DOMAIN/privkey.pem before=''
    [[ -r $cert ]] && before=$(sha256sum "$cert" | awk '{print $1}')
    if [[ -e $cert || -e $key ]]; then
        if ((MODE == 1)) && certificate_valid; then
            say 'Существующий сертификат валиден; сохраняю его.'
        elif ((MODE == 2)); then
            confirm_or_cancel 'Certbot выполнит --force-renewal для домена и обновит файлы сертификата в /opt/certbot/certs.'
            (cd "$CERTBOT_DIR" && docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot --non-interactive --agree-tos --email "$EMAIL" --force-renewal -d "$DOMAIN") || die 'Certificate issuance failed; existing files retained.'
        else
            die 'Существующий сертификат не прошёл проверку. Для перевыдачи запустите снова и выберите пункт 2.'
        fi
    else
        confirm_or_cancel 'Certbot запросит новый сертификат и создаст файлы в /opt/certbot/certs.'
        (cd "$CERTBOT_DIR" && docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN") || die 'Certificate issuance failed.'
    fi
    certificate_valid || die 'Сертификат, SAN или соответствие ключа не прошли проверку.'
    openssl x509 -in "$cert" -noout -subject -issuer -dates -ext subjectAltName
    local current=$CERTS_DIR/live/current target=$CERTS_DIR/live/$DOMAIN
    if [[ -L $current ]]; then
        [[ $(readlink -f "$current" 2>/dev/null || true) == $(readlink -f "$target") ]] || die "$current уже указывает на другой или недоступный сертификат; отказ от замены."
    elif [[ -e $current ]]; then
        die "$current существует и не является symlink; отказ от замены."
    else
        confirm_or_cancel "Будет создан symlink $current → $DOMAIN для выбора сертификата."
        ln -s "$DOMAIN" "$current"
        CERT_LINK_CHANGED=1
    fi
    [[ -r $current/fullchain.pem && -r $current/privkey.pem ]] || die 'current certificate link unreadable.'
    local after
    after=$(sha256sum "$current/fullchain.pem" | awk '{print $1}')
    [[ $before == "$after" ]] || CERTIFICATE_CHANGED=1
}

ensure_node_volume() {
    if grep -Fq "$CERT_MOUNT" "$NODE_COMPOSE"; then
        say 'Remnanode certificate volume already exists.'
        if ! docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true; then
            confirm_or_cancel 'Remnanode остановлен. Подтвердите его запуск; действующие VPN-подключения могут быть затронуты.'
            (cd "$NODE_DIR" && docker compose up -d remnanode) || die 'Не удалось запустить remnanode.'
        fi
        docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem || die 'fullchain.pem недоступен внутри remnanode.'
        docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem || die 'privkey.pem недоступен внутри remnanode.'
        return 0
    fi
    confirm_or_cancel 'Будет добавлен certificate volume в /opt/remnanode/docker-compose.yml и выполнен docker compose up -d remnanode. Контейнер может пересоздаться, VPN-подключения могут оборваться.'
    backup_file "$NODE_COMPOSE"
    patch_node_compose || die 'Безопасная правка Compose невозможна; исходный файл сохранён.'
    COMPOSE_CHANGED=1
    if ! docker compose -f "$NODE_COMPOSE" config >/dev/null; then
        restore_file "$NODE_COMPOSE"; COMPOSE_CHANGED=0
        die 'docker compose config failed; прежний файл восстановлен.'
    fi
    (cd "$NODE_DIR" && docker compose up -d remnanode) || die 'Не удалось применить volume к remnanode.'
    if ! wait_for_container_certificate; then
        docker logs --tail 100 remnanode || true
        die 'Не удалось подтвердить доступность сертификата внутри Remnanode после добавления volume.'
    fi
}

render_renew_script() {
    local domain=$1
    cat <<'RENEW'
#!/usr/bin/env bash
# Managed by remnawave-node-tls-setup.sh
set -Eeuo pipefail
CERTS_DIR=/opt/certbot/certs
NODE_COMPOSE=/opt/remnanode/docker-compose.yml
RENEW
    printf 'DOMAIN=%q\n' "$domain"
    declare -f say warn certificate_has_domain_san certificate_valid http_redirect_ready https_backend_ready container_certificate_ready remnawave_core_ready verify_container_certificate wait_for_container_certificate wait_for_remnawave_core node_certificate_usage refresh_node_certificate_if_used renewal_after_change
    cat <<'RENEW'
before=$(sha256sum "$CERTS_DIR/live/current/fullchain.pem" | awk '{print $1}')
(cd /opt/certbot && docker compose run --rm certbot renew --quiet)
after=$(sha256sum "$CERTS_DIR/live/current/fullchain.pem" | awk '{print $1}')
renewal_after_change "$before" "$after"
RENEW
}

install_renewal() {
    systemctl is-active --quiet remna-cert-renew.timer && RENEWAL_WAS_ACTIVE=1 || RENEWAL_WAS_ACTIVE=0
    systemctl is-enabled --quiet remna-cert-renew.timer && RENEWAL_WAS_ENABLED=1 || RENEWAL_WAS_ENABLED=0
    confirm_or_cancel 'Будут записаны renewal script/service/timer и сохранённое состояние домена; затем systemctl daemon-reload и включение таймера.'
    RENEWAL_CHANGED=1
    backup_file "$RENEW_SCRIPT"
    backup_file "$RENEW_SERVICE"
    backup_file "$RENEW_TIMER"
    for file in "$RENEW_SCRIPT" "$RENEW_SERVICE" "$RENEW_TIMER"; do
        if [[ -e $file ]] && ! grep -Fq 'Managed by remnawave-node-tls-setup.sh' "$file"; then
            die "$file exists and is not managed by this installer; refusing to replace it."
        fi
    done
    render_renew_script "$DOMAIN" >"$RENEW_SCRIPT"
    chmod 0750 "$RENEW_SCRIPT"
    printf '%s\n' '# Managed by remnawave-node-tls-setup.sh' '[Unit]' 'Description=Renew Remnawave Node TLS certificate' 'After=docker.service' 'Requires=docker.service' '' '[Service]' 'Type=oneshot' 'ExecStart=/usr/local/sbin/remna-cert-renew' >"$RENEW_SERVICE"
    printf '%s\n' '# Managed by remnawave-node-tls-setup.sh' '[Unit]' 'Description=Daily Remnawave Node TLS renewal check' '' '[Timer]' 'OnCalendar=daily' 'RandomizedDelaySec=2h' 'Persistent=true' '' '[Install]' 'WantedBy=timers.target' >"$RENEW_TIMER"
    systemctl daemon-reload
    systemctl enable --now remna-cert-renew.timer
}

firewall_check() {
    if has ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        local rules
        rules=$(ufw status)
        say 'UFW active (правила не менялись):'; printf '%s\n' "$rules"
        printf '%s\n' "$rules" | grep -Eq '(^|[[:space:]])(80|80/tcp|Nginx Full)[[:space:]]+ALLOW' || warn 'UFW may block TCP/80.'
        printf '%s\n' "$rules" | grep -Eq '(^|[[:space:]])(443/tcp|Nginx Full)[[:space:]]+ALLOW' || warn 'UFW may block TCP/443.'
        printf '%s\n' "$rules" | grep -Eq '(^|[[:space:]])443/udp[[:space:]]+ALLOW' || warn 'UFW may block UDP/443.'
    elif has nft || has iptables; then
        say 'Firewall правила не менялись; проверьте TCP 80/443 и UDP 443 вручную.'
    else
        say 'Отдельный firewall-инструмент не обнаружен.'
    fi
}

print_summary() {
    local cert=$CERTS_DIR/live/current/fullchain.pem tcp=NOT_YET_LISTENING udp=NOT_YET_LISTENING
    port_is_listening 443 && tcp=LISTENING
    ss -H -lnu 'sport = :443' 2>/dev/null | grep -q . && udp=LISTENING || true
    say '========================================'
    say 'REMNAWAVE NODE TLS SETUP'
    say '========================================'
    say "DOMAIN: $DOMAIN"
    say 'DNS: PASS'
    say 'CERTIFICATE: PASS'
    openssl x509 -in "$cert" -noout -enddate | sed 's/^/EXPIRES: /'
    say "CURRENT CERT PATH: $([[ -r $cert ]] && printf PASS || printf FAIL)"
    say "NGINX HTTP/80: $([[ $ACME_CHECK_PASSED == 1 ]] && printf PASS || printf FAIL)"
    say "NGINX HTTP/301 URI+QUERY: $(http_redirect_ready && printf PASS || printf FAIL)"
    say "NGINX FALLBACK/8080: $(http_backend_ready && printf PASS || printf FAIL)"
    say "NGINX HTTPS/9443 + HSTS: $(https_backend_ready && printf PASS || printf FAIL)"
    say "REMNANODE CERT VOLUME: $(grep -Fq "$CERT_MOUNT" "$NODE_COMPOSE" && printf PASS || printf FAIL)"
    say "CERT INSIDE CONTAINER: $(docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem && docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem && printf PASS || printf FAIL)"
    say "RENEW TIMER: $(systemctl is-active --quiet remna-cert-renew.timer && printf PASS || printf FAIL)"
    [[ $tcp == NOT_YET_LISTENING ]] && tcp='NOT YET LISTENING'
    [[ $udp == NOT_YET_LISTENING ]] && udp='NOT YET LISTENING'
    say "TCP 443: $tcp"
    say "UDP 443: $udp"
    show_readiness
    say 'NOTE: 443 listeners appear only after the appropriate Remnawave Config Profile is assigned to the Node.'
    systemctl list-timers remna-cert-renew.timer --no-pager || true
    say 'Listeners:'; ss -lntup
    firewall_check
}

self_test() {
    valid_domain node.example.com || die 'self-test: valid hostname rejected'
    valid_domain https://node.example.com && die 'self-test: scheme accepted'
    valid_domain '*.example.com' && die 'self-test: wildcard accepted'
    valid_domain node.example.com/path && die 'self-test: path accepted'
    valid_email admin@example.com || die 'self-test: valid email rejected'
    valid_email invalid && die 'self-test: invalid email accepted'
    local normalized_domain
    normalized_domain=dowload.24alisa.ru
    valid_domain "$normalized_domain" || die 'self-test input 1: plain hostname rejected'
    normalized_domain=' dowload.24alisa.ru '
    normalize_terminal_input "$normalized_domain" normalized_domain
    if [[ $normalized_domain != dowload.24alisa.ru ]] || ! valid_domain "$normalized_domain"; then die 'self-test input 2: surrounding spaces were not normalized'; fi
    normalized_domain=$'dowload.24alisa.ru\r'
    normalize_terminal_input "$normalized_domain" normalized_domain
    if [[ $normalized_domain != dowload.24alisa.ru ]] || ! valid_domain "$normalized_domain"; then die 'self-test input 3: trailing CR was not removed'; fi
    normalized_domain=$'\e[200~dowload.24alisa.ru\e[201~'
    normalize_terminal_input "$normalized_domain" normalized_domain
    if [[ $normalized_domain != dowload.24alisa.ru ]] || ! valid_domain "$normalized_domain"; then die 'self-test input 4: bracketed-paste markers were not removed'; fi
    normalized_domain='dow load.24alisa.ru'
    normalize_terminal_input "$normalized_domain" normalized_domain
    valid_domain "$normalized_domain" && die 'self-test input 5: internal whitespace was accepted'
    normalized_domain=https://dowload.24alisa.ru
    normalize_terminal_input "$normalized_domain" normalized_domain
    valid_domain "$normalized_domain" && die 'self-test input 6: URL scheme was accepted'
    local socket tcp_rw udp_rw nginx_owner unknown_owner mapped_only mixed_aaaa result
    socket=''
    [[ $(classify_443_owner tcp "$socket" '' '') == free ]] || die 'self-test A: free port'
    tcp_rw='tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("rw-core",pid=101,fd=7))'
    [[ $(classify_443_owner tcp "$tcp_rw" '101 rw-core /usr/bin/rw-core' '101 rw-core') == remnawave ]] || die 'self-test B: TCP rw-core'
    udp_rw='udp UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=102,fd=8))'
    [[ $(classify_443_owner udp "$udp_rw" '102 xray /usr/bin/xray run' '102 xray') == remnawave ]] || die 'self-test C: UDP rw-core/Xray'
    nginx_owner='tcp LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=201,fd=6))'
    [[ $(classify_443_owner tcp "$nginx_owner" '' '201 nginx') == nginx ]] || die 'self-test D: reject Nginx'
    unknown_owner='tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("mystery",pid=202,fd=3))'
    [[ $(classify_443_owner tcp "$unknown_owner" '' '202 mystery') == unknown ]] || die 'self-test E: reject unknown owner'
    mapped_only=$(printf '%s\n' '::ffff:192.0.2.10' | filter_aaaa_records)
    [[ -z $mapped_only ]] || die 'self-test DNS 1: mapped IPv4 is not a real AAAA'
    check_dns_record_match '192.0.2.10' "$mapped_only" '192.0.2.10' '2001:db8::10' || die 'self-test DNS 1: A plus mapped AAAA must pass'
    check_dns_record_match '192.0.2.10' '2001:db8::10' '192.0.2.10' '2001:db8::10' || die 'self-test DNS 2: matching A and AAAA'
    if check_dns_record_match '192.0.2.10' '2001:db8::11' '192.0.2.10' '2001:db8::10'; then
        die 'self-test DNS 3: mismatched real AAAA accepted'
    else
        result=$?
        [[ $result == 2 ]] || die 'self-test DNS 3: wrong failure class'
    fi
    mixed_aaaa=$(printf '%s\n' '::ffff:192.0.2.10' '2001:db8::10' | filter_aaaa_records)
    [[ $mixed_aaaa == '2001:db8::10' ]] || die 'self-test DNS 4: mapped entry was not filtered alone'
    check_dns_record_match '192.0.2.10' "$mixed_aaaa" '192.0.2.10' '2001:db8::10' || die 'self-test DNS 4: real AAAA should validate'
    check_dns_record_match '192.0.2.10' '' '192.0.2.10' '' || die 'self-test DNS 5: IPv4-only Node should pass'
    if check_dns_record_match '192.0.2.11' '' '192.0.2.10' ''; then die 'self-test DNS: mismatched A accepted'; fi
    local saved_domain=$DOMAIN acme_config acme_token acme_probe_log
    DOMAIN=node.example.com
    acme_token=self-test-token
    acme_probe_log=$(mktemp)
    MOCK_ACME_PROBE_LOG=$acme_probe_log
    MOCK_ACME_TOKEN=$acme_token
    MOCK_REQUIRE_PROXY=0
    MOCK_REDIRECT_STATUS='301 Moved Permanently'
    MOCK_REDIRECT_LOCATION="https://$DOMAIN/remna-301-check?source=installer"
    # The production probe resolves curl by name; this stub intercepts it in the self-test.
    # shellcheck disable=SC2329
    curl() {
        printf 'curl:%s\n' "$1" >>"$MOCK_ACME_PROBE_LOG"
        if [[ $* == *'http://127.0.0.1/remna-301-check?source=installer'* ]]; then
            printf 'HTTP/1.1 %s\nLocation: %s\n' "$MOCK_REDIRECT_STATUS" "$MOCK_REDIRECT_LOCATION"
            return 0
        fi
        [[ $# == 8 && $1 == --noproxy && $2 == '*' && $3 == -fsS && $4 == --max-time && $5 == 5 && $6 == -H && $7 == "Host: $DOMAIN" && $8 == "http://127.0.0.1/.well-known/acme-challenge/$MOCK_ACME_TOKEN" ]] || return 1
        if [[ $MOCK_REQUIRE_PROXY == 1 ]]; then
            [[ ${HTTP_PROXY:-} == http://proxy.invalid && ${HTTPS_PROXY:-} == http://proxy.invalid && ${ALL_PROXY:-} == http://proxy.invalid ]] || return 1
        fi
        printf '%s' "$MOCK_ACME_TOKEN"
    }
    retry_http_acme_probe "$acme_token" '' mock_acme_pause || die 'self-test HTTP A: production probe must ignore retry number and use curl'
    [[ $(grep -c '^curl:--noproxy$' "$acme_probe_log") == 1 ]] || die 'self-test HTTP A: curl was not called exactly once'
    : >"$acme_probe_log"
    retry_http_acme_probe "$acme_token" mock_acme_probe_retry mock_acme_pause || die 'self-test HTTP B: retry response must pass'
    [[ $(grep -c '^probe:' "$acme_probe_log") == 2 && $(grep -c '^pause:' "$acme_probe_log") == 1 ]] || die 'self-test HTTP B: expected success on second attempt'
    : >"$acme_probe_log"
    if retry_http_acme_probe "$acme_token" mock_acme_probe_missing mock_acme_pause; then
        die 'self-test HTTP C: ten missing responses must fail'
    fi
    [[ $(grep -c '^probe:' "$acme_probe_log") == 10 && $(grep -c '^pause:' "$acme_probe_log") == 9 ]] || die 'self-test HTTP C: expected ten attempts and nine pauses'
    : >"$acme_probe_log"
    HTTP_PROXY=http://proxy.invalid HTTPS_PROXY=http://proxy.invalid ALL_PROXY=http://proxy.invalid
    MOCK_REQUIRE_PROXY=1
    export HTTP_PROXY HTTPS_PROXY ALL_PROXY
    retry_http_acme_probe "$acme_token" http_acme_probe_once mock_acme_pause || die 'self-test HTTP D: proxy variables must not affect direct localhost check'
    [[ $(grep -c '^curl:--noproxy$' "$acme_probe_log") == 1 ]] || die 'self-test HTTP D: production probe did not call curl with --noproxy'
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
    http_redirect_ready || die 'self-test HTTP F: correct 301 Location was rejected'
    MOCK_REDIRECT_STATUS='302 Found'
    if http_redirect_ready; then die 'self-test HTTP F: non-301 response accepted'; fi
    MOCK_REDIRECT_STATUS='301 Moved Permanently'
    MOCK_REDIRECT_LOCATION="https://$DOMAIN/wrong-path"
    if http_redirect_ready; then die 'self-test HTTP F: redirect that loses URI/query accepted'; fi
    rm -f -- "$acme_probe_log"
    acme_config=$(printf '%s\n' "# configuration file $NGINX_FILE:" 'server { listen 80; }')
    if effective_nginx_config_has_managed_block "$acme_config"; then
        die 'self-test HTTP E: missing managed Nginx server must fail'
    fi
    DOMAIN=$saved_domain
    local rendered tls_rendered tmp bad_cert good_cert renew_log candidate_path transport mode transport_pairs
    rendered=$(render_nginx node.example.com)
    tls_rendered=$(render_nginx node.example.com 1)
    [[ $rendered == *'listen 127.0.0.1:8080;'* && $rendered == *'listen [::]:80;'* && $rendered != *'listen 127.0.0.1:9443 ssl;'* ]] || die 'self-test Nginx 2: old TLS config shape'
    [[ $rendered == *'location ^~ /.well-known/acme-challenge/'* && $rendered == *"location / { return 301 https://\$host\$request_uri; }"* ]] || die 'self-test Nginx 6: HTTP 301 or ACME exception missing'
    [[ $tls_rendered == *'listen 127.0.0.1:8080;'* && $tls_rendered == *'listen 127.0.0.1:9443 ssl;'* && $tls_rendered != *$'listen 443;\n'* ]] || die 'self-test Nginx 1: fresh dual-backend config'
    [[ $tls_rendered == *'add_header Strict-Transport-Security "max-age=300" always;'* ]] || die 'self-test Nginx 7: HSTS header missing'
    [[ $(grep -Fc 'listen 127.0.0.1:9443 ssl;' <<<"$tls_rendered") == 1 ]] || die 'self-test Nginx 3: old TLS Node must gain one 9443 backend'
    [[ $tls_rendered == "$rendered"* ]] || die 'self-test Nginx 2: old managed block changed while adding 9443'
    [[ $(render_nginx node.example.com 1) == "$tls_rendered" ]] || die 'self-test Nginx 4: both managed backends must remain idempotent'
    if managed_nginx_9443_listener '127.0.0.1:9443 users:(("mystery",pid=101,fd=3))' "$tls_rendered"; then die 'self-test Nginx 5: foreign 9443 listener accepted'; fi
    managed_nginx_9443_listener '127.0.0.1:9443 users:(("nginx",pid=101,fd=3))' "$tls_rendered" || die 'self-test Nginx 5: managed Nginx listener rejected'
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' RETURN
    DOMAIN=node.example.com
    for transport in tcp_tls tcp_reality xhttp_reality xhttp_tls grpc_tls; do
        render_transport_inbound "$transport" "$DOMAIN" >"$tmp/$transport.json" || die "self-test transport: failed to render $transport"
        python3 -m json.tool "$tmp/$transport.json" >/dev/null || die "self-test transport: invalid JSON for $transport"
    done
    for transport in tcp_tls tcp_reality xhttp_tls grpc_tls; do
        render_transport_client "$transport" "$DOMAIN" >"$tmp/client-$transport.json" || die "self-test transport: failed to render client example for $transport"
        python3 -m json.tool "$tmp/client-$transport.json" >/dev/null || die "self-test transport: invalid client JSON for $transport"
    done
    [[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["streamSettings"]["network"]+"|"+d["streamSettings"]["security"])' "$tmp/tcp_tls.json") == 'raw|tls' ]] || die 'self-test transport: TCP TLS contract'
    grep -Fq '127.0.0.1:8080' "$tmp/tcp_tls.json" || die 'self-test transport: TCP TLS HTTP fallback missing'
    for transport in tcp_reality xhttp_reality; do
        grep -Fq '127.0.0.1:9443' "$tmp/$transport.json" || die "self-test transport: REALITY target missing for $transport"
        grep -Fq '"xver": 0' "$tmp/$transport.json" || die "self-test transport: xver missing for $transport"
        grep -Fq '__REUSE_EXISTING_NODE_PRIVATE_KEY__' "$tmp/$transport.json" || die "self-test transport: REALITY key placeholder missing for $transport"
    done
    if grep -Fq '"mode"' "$tmp/xhttp_reality.json" || grep -Fq 'Vision' "$tmp/xhttp_reality.json"; then
        die 'self-test transport: server XHTTP must not be restricted to one client mode or use Vision'
    fi
    for mode in auto stream-one stream-up packet-up; do
        render_xhttp_client_mode "$DOMAIN" "$mode" >"$tmp/client-$mode.json" || die "self-test XHTTP: could not render client mode $mode"
        python3 -m json.tool "$tmp/client-$mode.json" >/dev/null || die "self-test XHTTP: invalid client JSON for $mode"
        grep -Fq "\"mode\": \"$mode\"" "$tmp/client-$mode.json" || die "self-test XHTTP: client mode mismatch for $mode"
        grep -Fq '__SET_PUBLIC_KEY_FROM_PANEL__' "$tmp/client-$mode.json" || die "self-test XHTTP: public key placeholder missing for $mode"
    done
    transport_pairs=$(printf '%s' '{"inbounds":[{"streamSettings":{"network":"xhttp","security":"reality"}},{"streamSettings":{"security":"tls"}}]}' | extract_transport_pairs) || die 'self-test transport parser: failed'
    [[ $transport_pairs == $'raw|tls\nxhttp|reality' ]] || die 'self-test transport parser: network/security pair detection'
    TRANSPORT_STATE_OVERRIDE=$tmp/transport-state
    UI_OUTPUT_FD=1
    prepare_transport_candidate xhttp_reality >"$tmp/transport-candidate.out" || die 'self-test transport: candidate preparation failed'
    candidate_path=$(find "$tmp/transport-state/candidates" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [[ -n $candidate_path && -f $candidate_path/inbound.json && -f $candidate_path/README.md ]] || die 'self-test transport: candidate bundle is incomplete'
    for mode in auto stream-one stream-up packet-up; do [[ -f $candidate_path/client-$mode.json ]] || die "self-test transport: client mode file missing: $mode"; done
    [[ $(stat -c '%a' "$candidate_path") == 700 && $(stat -c '%a' "$candidate_path/inbound.json") == 600 ]] || die 'self-test transport: candidate permissions are not private'
    grep -Fq 'PREPARED ONLY' "$candidate_path/README.md" || die 'self-test transport: candidate incorrectly claims activation'
    command ln -s "$tmp/transport-state" "$tmp/transport-state-link" || die 'self-test transport: could not prepare symlink guard test'
    TRANSPORT_STATE_OVERRIDE=$tmp/transport-state-link
    if new_transport_candidate_dir tcp-tls >/dev/null 2>&1; then die 'self-test transport: symlinked candidate root was accepted'; fi
    TRANSPORT_STATE_OVERRIDE=''
    bad_cert=$tmp/bad-san.pem; good_cert=$tmp/good-san.pem
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/bad.key" -out "$bad_cert" -days 2 -subj '/CN=other.example.com' -addext 'subjectAltName=DNS:other.example.com' >/dev/null 2>&1 || die 'self-test Cert 5: could not create mismatched test certificate'
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/good.key" -out "$good_cert" -days 2 -subj '/CN=node.example.com' -addext 'subjectAltName=DNS:node.example.com' >/dev/null 2>&1 || die 'self-test Cert 6: could not create matching test certificate'
    DOMAIN=node.example.com
    certificate_has_domain_san "$bad_cert" && die 'self-test Cert 5: mismatched SAN accepted'
    certificate_has_domain_san "$good_cert" || die 'self-test Cert 6: matching SAN rejected'
    # shellcheck disable=SC2329
    certificate_has_domain_san() { return 0; }
    # shellcheck disable=SC2329
    curl() { printf '%s\n' "$MOCK_TLS_HEADERS"; }
    MOCK_TLS_HEADERS=$'HTTP/1.1 200 OK\nStrict-Transport-Security: max-age=300\n'
    https_backend_ready /dev/null || die 'self-test HTTPS A: valid HTTPS/HSTS response rejected'
    MOCK_TLS_HEADERS=$'HTTP/1.1 200 OK\n'
    if https_backend_ready /dev/null; then die 'self-test HTTPS A: missing HSTS header accepted'; fi

    (
        docker() {
            local IFS=' '
            case "$*" in
                'inspect -f {{.State.Running}} remnanode') printf 'true\n' ;;
                'top remnanode -eo pid,comm') printf 'PID COMMAND\n123 rw-core\n' ;;
                *) return 1 ;;
            esac
        }
        remnawave_core_ready || exit 1
        docker() {
            local IFS=' '
            case "$*" in
                'inspect -f {{.State.Running}} remnanode') printf 'true\n' ;;
                'top remnanode -eo pid,comm') printf 'PID COMMAND\n' ;;
                *) return 1 ;;
            esac
        }
        if remnawave_core_ready; then exit 1; fi
    ) || die 'self-test Node A: docker top must include PID and detect rw-core'
    (
        CORE_CHECK_COUNT=0
        remnawave_core_ready() { CORE_CHECK_COUNT=$((CORE_CHECK_COUNT + 1)); ((CORE_CHECK_COUNT >= 9)); }
        sleep() { :; }
        wait_for_remnawave_core 10 2 || exit 1
        [[ $CORE_CHECK_COUNT == 9 ]]
    ) || die 'self-test Node B: core startup after the first 15 seconds must be accepted'
    (
        CERT_CHECK_COUNT=0
        container_certificate_ready() { CERT_CHECK_COUNT=$((CERT_CHECK_COUNT + 1)); ((CERT_CHECK_COUNT >= 9)); }
        verify_container_certificate() { [[ $CERT_CHECK_COUNT == 9 ]]; }
        sleep() { :; }
        wait_for_container_certificate 10 2 || exit 1
        [[ $CERT_CHECK_COUNT == 9 ]]
    ) || die 'self-test Node B2: delayed container certificate must be checked separately from core startup'

    renew_log=$tmp/renew.log
    : >"$renew_log"
    # These command stubs verify the renewal sequence without touching a live Node.
    # shellcheck disable=SC2329
    nginx() { local IFS=' '; printf 'nginx:%s\n' "$*" >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    systemctl() { local IFS=' '; printf 'systemctl:%s\n' "$*" >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    docker() { local IFS=' '; printf 'docker:%s\n' "$*" >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    sleep() { printf 'sleep:%s\n' "$*" >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    certificate_valid() { return 0; }
    # shellcheck disable=SC2329
    http_redirect_ready() { printf 'http-redirect\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    https_backend_ready() { printf 'https-backend\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    container_certificate_ready() { printf 'container-certificate\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    remnawave_core_ready() { printf 'rw-core\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    verify_container_certificate() { printf 'container-certificate\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    wait_for_remnawave_core() { printf 'rw-core\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    node_certificate_usage() { printf '%s\n' "$RENEW_TEST_CERT_USAGE"; }
    RENEW_TEST_LOG=$renew_log
    RENEW_TEST_CERT_USAGE=NOT_USED
    renewal_after_change same same || die 'self-test renewal 7: unchanged certificate returned failure'
    [[ ! -s $renew_log ]] || die 'self-test renewal 7: unchanged certificate triggered reload/restart'
    renewal_after_change old new || die 'self-test renewal 8: changed certificate actions failed'
    [[ $(cat "$renew_log") == $'nginx:-t\nsystemctl:reload nginx\nhttp-redirect\nhttps-backend\nrw-core' ]] || die "self-test renewal 8: Nginx-only renewal must not restart Remnanode: $(tr '\n' ',' <"$renew_log")"
    : >"$renew_log"
    RENEW_TEST_CERT_USAGE=USED
    renewal_after_change old new || die 'self-test renewal 9: certificate consumer refresh failed'
    [[ $(cat "$renew_log") == $'nginx:-t\nsystemctl:reload nginx\nhttp-redirect\nhttps-backend\ndocker:compose -f /opt/remnanode/docker-compose.yml restart remnanode\ncontainer-certificate\nrw-core' ]] || die "self-test renewal 9: Xray/Hysteria2 certificate use must refresh Remnanode: $(tr '\n' ',' <"$renew_log")"
    : >"$renew_log"
    RENEW_TEST_CERT_USAGE=UNKNOWN
    renewal_after_change old new || die 'self-test renewal 10: unknown certificate use must not fail renewal'
    [[ $(cat "$renew_log") == $'nginx:-t\nsystemctl:reload nginx\nhttp-redirect\nhttps-backend\nrw-core' ]] || die "self-test renewal 10: unknown use must skip restart: $(tr '\n' ',' <"$renew_log")"

    : >"$renew_log"
    COMPOSE_CHANGED=1
    RENEW_TEST_CERT_USAGE=USED
    refresh_output=$(refresh_node_certificate_if_used 0 2>&1) || die 'self-test Node C: initial Compose apply should verify readiness'
    [[ $(cat "$renew_log") == $'container-certificate\nrw-core' ]] || die "self-test Node C: Compose apply must not trigger a second restart: $(tr '\n' ',' <"$renew_log")"
    [[ $refresh_output == *'дополнительный restart пропущен'* ]] || die 'self-test Node C: duplicate restart was not clearly skipped'
    COMPOSE_CHANGED=0

    : >"$renew_log"
    COMPOSE_CHANGED=1
    RENEW_TEST_CERT_USAGE=UNKNOWN
    remnawave_core_ready() { return 1; }
    refresh_output=$(refresh_node_certificate_if_used 0 2>&1) || die 'self-test Node C2: first install without assigned Xray profile must not fail TLS setup'
    [[ ! -s $renew_log ]] || die "self-test Node C2: an unassigned profile must not cause restart: $(tr '\n' ',' <"$renew_log")"
    [[ $refresh_output == *'VPN readiness'* && $refresh_output == *'NOT VERIFIED'* ]] || die 'self-test Node C2: missing Xray process must be reported as unverified VPN readiness'
    COMPOSE_CHANGED=0
    remnawave_core_ready() { printf 'rw-core\n' >>"$RENEW_TEST_LOG"; }

    : >"$renew_log"
    RENEW_TEST_CERT_USAGE=UNKNOWN
    refresh_output=$(refresh_node_certificate_if_used 0 2>&1) || die 'self-test Node D: unknown use must not fail TLS setup'
    [[ $(cat "$renew_log") == 'rw-core' ]] || die "self-test Node D: unknown use must not restart Remnanode: $(tr '\n' ',' <"$renew_log")"
    [[ $refresh_output == *'previous certificate'* && $refresh_output == *'was not restarted'* ]] || die 'self-test Node D: unknown certificate-use stale risk was hidden'

    (
        BACKUP_DIR=$tmp/rollback-backup
        test_root=$tmp/rollback-root
        test_nginx=$test_root/etc/nginx/conf.d/remna-node-tls-setup.conf
        test_node_dir=$test_root/opt/remnanode
        test_node_compose=$test_node_dir/docker-compose.yml
        test_certbot_dir=$test_root/opt/certbot
        test_certbot_compose=$test_certbot_dir/docker-compose.yml
        test_certs_dir=$test_certbot_dir/certs
        test_current_link=$test_certs_dir/live/current
        test_renew_script=$test_root/usr/local/sbin/remna-cert-renew
        test_renew_service=$test_root/etc/systemd/system/remna-cert-renew.service
        test_renew_timer=$test_root/etc/systemd/system/remna-cert-renew.timer
        mkdir -p "$BACKUP_DIR" "$test_root/etc/nginx/conf.d" "$test_root/usr/local/sbin" "$test_root/etc/systemd/system" "$test_node_dir" "$test_certbot_dir" "$test_certs_dir/live/node.example.com"
        DOMAIN=node.example.com
        : >"$tmp/rollback-actions.log"

        backup_file "$test_nginx"
        printf 'temporary nginx stage\n' >"$test_nginx"
        backup_file "$test_nginx"
        printf 'original node compose\n' >"$test_node_compose"
        backup_file "$test_node_compose"
        printf 'compose with new cert mount\n' >"$test_node_compose"
        backup_file "$test_node_compose"
        backup_file "$test_certbot_compose"
        printf 'temporary certbot compose\n' >"$test_certbot_compose"
        for file in "$test_renew_script" "$test_renew_service" "$test_renew_timer"; do backup_file "$file"; printf 'temporary renewal file\n' >"$file"; done
        printf 'certificate material retained after rollback test\n' >"$test_certs_dir/live/node.example.com/fullchain.pem"
        ln -s node.example.com "$test_current_link"

        NGINX_CHANGED=1 NGINX_WAS_ACTIVE=1 COMPOSE_CHANGED=1 CERTBOT_COMPOSE_CHANGED=1 CERT_LINK_CHANGED=1 RENEWAL_CHANGED=1 RENEWAL_WAS_ACTIVE=0 RENEWAL_WAS_ENABLED=0
        nginx() { [[ $* == -t ]]; }
        systemctl() { local IFS=' '; printf 'systemctl:%s\n' "$*" >>"$tmp/rollback-actions.log"; }
        docker() { local IFS=' '; printf 'docker:%s\n' "$*" >>"$tmp/rollback-actions.log"; }
        warn() { printf 'warning:%s\n' "$*" >>"$tmp/rollback-actions.log"; }
        rollback "$test_root"

        [[ ! -e $test_nginx && ! -L $test_nginx ]] || exit 1
        [[ $(cat "$test_node_compose") == 'original node compose' ]] || exit 1
        [[ ! -e $test_certbot_compose && ! -L $test_certbot_compose ]] || exit 1
        [[ ! -e $test_current_link && ! -L $test_current_link ]] || exit 1
        [[ -r $test_certs_dir/live/node.example.com/fullchain.pem ]] || exit 1
        [[ ! -e $test_renew_script && ! -e $test_renew_service && ! -e $test_renew_timer ]] || exit 1
        grep -Fq 'docker:compose up -d remnanode' "$tmp/rollback-actions.log" || exit 1
        grep -Fq 'systemctl:daemon-reload' "$tmp/rollback-actions.log" || exit 1
        grep -Fq 'systemctl:disable remna-cert-renew.timer' "$tmp/rollback-actions.log" || exit 1
    ) || die 'self-test rollback A: first-install files, Compose, symlink, or timer were not restored safely'

    cat >"$tmp/compose.yml" <<'YAML'
services:
  remnanode:
    image: remnawave/node:2.8.0
    volumes:
      - ./data:/data
  other:
    image: alpine
YAML
    patch_node_compose "$tmp/compose.yml"
    patch_node_compose "$tmp/compose.yml"
    [[ $(grep -Fc "$CERT_MOUNT" "$tmp/compose.yml") == 1 ]] || die 'self-test: idempotency'
    cat >"$tmp/compose-empty.yml" <<'YAML'
services:
  remnanode:
    image: remnawave/node:2.8.0
    volumes: []
YAML
    patch_node_compose "$tmp/compose-empty.yml"
    [[ $(grep -Fc "$CERT_MOUNT" "$tmp/compose-empty.yml") == 1 ]] || die 'self-test: empty volumes list'
    cat >"$tmp/compose-conflict.yml" <<'YAML'
services:
  remnanode:
    volumes:
      - /other/certs:/etc/letsencrypt:ro
YAML
    if patch_node_compose "$tmp/compose-conflict.yml" 2>/dev/null; then die 'self-test: conflicting mount accepted'; fi

    cat >"$tmp/certbot-old.yml" <<'YAML'
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    environment:
      - TZ=UTC
    volumes:
      - ./certs:/etc/letsencrypt
    restart: unless-stopped
YAML
    cp "$tmp/certbot-old.yml" "$tmp/certbot-old.expected-backup.yml"
    if patch_certbot_compose "$tmp/certbot-old.yml" "$tmp/backup-a"; then
        die 'self-test Certbot A: expected old Compose to be patched'
    else
        result=$?
        [[ $result == 10 ]] || die 'self-test Certbot A: patch failed'
    fi
    [[ $(grep -Fc './www:/var/www/certbot' "$tmp/certbot-old.yml") == 1 ]] || die 'self-test Certbot A: webroot mount missing or duplicated'
    cmp -s "$tmp/certbot-old.expected-backup.yml" "$tmp/backup-a/opt__certbot__docker-compose.yml" || die 'self-test Certbot A: original Compose backup missing or changed'
    cat >"$tmp/certbot-old.expected.yml" <<'YAML'
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    environment:
      - TZ=UTC
    volumes:
      - ./certs:/etc/letsencrypt
      - './www:/var/www/certbot'
    restart: unless-stopped
YAML
    cmp -s "$tmp/certbot-old.expected.yml" "$tmp/certbot-old.yml" || die 'self-test Certbot E: unrelated service fields changed'

    before=$(sha256sum "$tmp/certbot-old.yml" | awk '{print $1}')
    patch_certbot_compose "$tmp/certbot-old.yml" "$tmp/backup-b" || die 'self-test Certbot B: existing mounts should pass unchanged'
    after=$(sha256sum "$tmp/certbot-old.yml" | awk '{print $1}')
    [[ $before == "$after" ]] || die 'self-test Certbot B: already migrated file changed'

    cat >"$tmp/certbot-conflict.yml" <<'YAML'
services:
  certbot:
    volumes:
      - ./certs:/etc/letsencrypt
      - /srv/acme:/var/www/certbot
YAML
    if output=$(patch_certbot_compose "$tmp/certbot-conflict.yml" "$tmp/backup-c" 2>&1); then
        die 'self-test Certbot C: conflicting mount accepted'
    else
        result=$?
        [[ $result == 4 && $output == *'CERTBOT WEBROOT MOUNT CONFLICT'* ]] || die 'self-test Certbot C: conflict diagnostic missing'
    fi

    cat >"$tmp/certbot-empty.yml" <<'YAML'
services:
  certbot:
    container_name: certbot
    volumes: []
YAML
    if patch_certbot_compose "$tmp/certbot-empty.yml" "$tmp/backup-d"; then
        die 'self-test Certbot D: empty volumes should be patched'
    else
        result=$?
        [[ $result == 10 ]] || die 'self-test Certbot D: empty volumes patch failed'
    fi
    [[ $(grep -Fc './certs:/etc/letsencrypt' "$tmp/certbot-empty.yml") == 1 && $(grep -Fc './www:/var/www/certbot' "$tmp/certbot-empty.yml") == 1 ]] || die 'self-test Certbot D: both required mounts must exist once'

    render_renew_script node.example.com >"$tmp/remna-cert-renew"
    bash -n "$tmp/remna-cert-renew" || die 'self-test: generated renewal script syntax'
    grep -Fq 'DOMAIN=node.example.com' "$tmp/remna-cert-renew" || die 'self-test: renewal domain'
    if ! grep -Fq 'nginx -t' "$tmp/remna-cert-renew" || ! grep -Fq 'systemctl reload nginx' "$tmp/remna-cert-renew" || ! grep -Fq 'https_backend_ready' "$tmp/remna-cert-renew"; then
        die 'self-test: renewal safety sequence missing'
    fi
    grep -Fq 'node_certificate_usage' "$tmp/remna-cert-renew" || die 'self-test: renewal must include the Xray/Hysteria2 certificate-use check'
    grep -Fq 'http_redirect_ready' "$tmp/remna-cert-renew" || die 'self-test: renewal must verify HTTP 301'

    local ui_input_path=$tmp/menu.input ui_output_path=$tmp/menu.output menu_expected readonly_log readonly_hash readonly_source candidate_hash candidate_count_before
    run_menu_case() {
        local input=$1 expected=$2 input_fd output_fd
        printf '%s' "$input" >"$ui_input_path"
        : >"$ui_output_path"
        exec {input_fd}<"$ui_input_path"
        exec {output_fd}>"$ui_output_path"
        UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd COLUMNS=${MENU_TEST_COLUMNS:-80}
        MODE=''
        menu || die 'self-test menu: menu returned failure'
        [[ $MODE == "$expected" ]] || die "self-test menu: expected $expected, got $MODE"
        exec {input_fd}<&-
        exec {output_fd}>&-
    }
    for menu_expected in 1 2 3 4 5; do run_menu_case "$menu_expected"$'\n' "$menu_expected"; done
    run_menu_case $'T\n' 6
    MENU_TEST_COLUMNS=40
    run_menu_case $'x\n\n5\n' 5
    grep -Fq 'Неизвестный пункт' "$ui_output_path" || die 'self-test menu: invalid input was not explained'
    run_menu_case $'h\n\n5\n' 5
    grep -Fq 'ПОДРОБНАЯ СПРАВКА' "$ui_output_path" || die 'self-test menu: H did not open help'
    grep -Fq '1. Проверить и исправить' "$ui_output_path" || die 'self-test menu: help content missing'
    python3 - "$ui_output_path" 40 <<'PY' || die 'self-test menu: narrow-terminal layout exceeds width'
import sys, unicodedata
path, limit = sys.argv[1], int(sys.argv[2])
def width(text):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)
with open(path, encoding="utf-8") as stream:
    bad = [(i, width(line.rstrip("\n"))) for i, line in enumerate(stream, 1) if width(line.rstrip("\n")) > limit]
if bad:
    print(bad, file=sys.stderr)
    raise SystemExit(1)
PY
    MENU_TEST_COLUMNS=80
    run_menu_case $'\n5\n' 5
    grep -Fq 'Введите 1–5, T или H' "$ui_output_path" || die 'self-test menu: empty input did not reprompt'

    run_transport_menu_case() {
        local input=$1 input_fd output_fd
        printf '%s' "$input" >"$ui_input_path"
        : >"$ui_output_path"
        exec {input_fd}<"$ui_input_path"
        exec {output_fd}>"$ui_output_path"
        UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd COLUMNS=${MENU_TEST_COLUMNS:-80}
        transport_manager_menu || die 'self-test transport menu: returned failure'
        exec {input_fd}<&-
        exec {output_fd}>&-
    }
    MENU_TEST_COLUMNS=40
    run_transport_menu_case $'x\n\n0\n'
    grep -Fq 'Неизвестный пункт' "$ui_output_path" || die 'self-test transport menu: invalid/empty input did not reprompt'
    run_transport_menu_case $'h\n0\n'
    grep -Fq 'СПРАВКА · МЕНЕДЖЕР ТРАНСПОРТОВ' "$ui_output_path" || die 'self-test transport menu: help did not open'
    python3 - "$ui_output_path" 40 <<'PY' || die 'self-test transport menu: narrow-terminal layout exceeds width'
import sys, unicodedata
path, limit = sys.argv[1], int(sys.argv[2])
def width(text):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)
with open(path, encoding="utf-8") as stream:
    bad = [(i, width(line.rstrip("\n"))) for i, line in enumerate(stream, 1) if width(line.rstrip("\n")) > limit]
if bad:
    print(bad, file=sys.stderr)
    raise SystemExit(1)
PY
    MENU_TEST_COLUMNS=80

    run_menu_case $'h\n\n5\n' 5
    UI_OUTPUT_FD=1
    show_operation_warning 1 >"$ui_output_path"
    if ! grep -Fq 'VPN' "$ui_output_path" || ! grep -Fq 'оборваться' "$ui_output_path"; then die 'self-test menu: option 1 VPN warning missing'; fi
    show_operation_warning 2 >"$ui_output_path"
    if ! grep -Fq 'VPN' "$ui_output_path" || ! grep -Fq 'оборваться' "$ui_output_path"; then die 'self-test menu: option 2 VPN warning missing'; fi
    printf '\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    if confirm_menu_action 1; then die 'self-test confirmation: empty input was accepted for option 1'; fi
    grep -Fq 'VPN-подключения' "$ui_output_path" || grep -Fq 'VPN' "$ui_output_path" || die 'self-test confirmation: option 1 warning missing'
    exec {input_fd}<&-
    exec {output_fd}>&-
    printf '\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    if confirm_menu_action 2; then die 'self-test confirmation: empty input was accepted for option 2'; fi
    grep -Fq 'force' "$ui_output_path" || grep -Fq 'Certbot' "$ui_output_path" || die 'self-test confirmation: option 2 warning missing'
    exec {input_fd}<&-
    exec {output_fd}>&-
    printf 'ДА\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    confirm_action 'test confirmation' || die 'self-test confirmation: explicit ДА was rejected'
    exec {input_fd}<&-
    exec {output_fd}>&-

    readonly_log=$tmp/read-only-actions.log
    : >"$readonly_log"
    READONLY_ACTION_LOG=$readonly_log
    MOCK_EMPTY_MOUNT=0 MOCK_CORE_READY=1 MOCK_443_OWNER=remnawave MOCK_HOST_CERT=1 MOCK_CONTAINER_CERT=1 MOCK_ACTIVE_MODE='REALITY SELFSTEAL'
    # The read-only menu tests reject all service/configuration mutation commands.
    # shellcheck disable=SC2329
    load_state() { DOMAIN=node.example.com; WEB_ROOT=/var/www/remna-node-site; return 0; }
    # shellcheck disable=SC2329
    certificate_valid() { ((MOCK_HOST_CERT)); }
    # shellcheck disable=SC2329
    certificate_has_domain_san() { ((MOCK_HOST_CERT)); }
    # shellcheck disable=SC2329
    container_certificate_ready() { ((MOCK_CONTAINER_CERT)); }
    # shellcheck disable=SC2329
    remnawave_core_ready() { ((MOCK_CORE_READY)); }
    # shellcheck disable=SC2329
    classify_443_owner() { printf '%s\n' "$MOCK_443_OWNER"; }
    # shellcheck disable=SC2329
    http_redirect_ready() { return 0; }
    # shellcheck disable=SC2329
    https_backend_headers() { printf 'HTTP/1.1 200 OK\nStrict-Transport-Security: max-age=300\n'; }
    # shellcheck disable=SC2329
    https_protocol_ready() { return 0; }
    # shellcheck disable=SC2329
    detect_active_mode() { printf '%s\n' "$MOCK_ACTIVE_MODE"; }
    # shellcheck disable=SC2329
    getent() { [[ $1 == ahostsv4 ]] && printf '192.0.2.20 STREAM test\n' || printf '2001:db8::20 STREAM test\n'; }
    # shellcheck disable=SC2329
    openssl() { printf 'notAfter=Dec 31 23:59:59 2027 GMT\n'; }
    # shellcheck disable=SC2329
    systemctl() {
        local IFS=' '
        case "$*" in
            'is-active --quiet nginx'|'is-active --quiet remna-cert-renew.timer'|'is-enabled --quiet remna-cert-renew.timer') return 0 ;;
            *) printf 'systemctl %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1 ;;
        esac
    }
    # shellcheck disable=SC2329
    nginx() { local IFS=' '; [[ $* == -t ]] || { printf 'nginx %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }; }
    # shellcheck disable=SC2329
    docker() {
        local IFS=' '
        case "$*" in
            "inspect -f {{.State.Status}} remnanode") printf 'running\n' ;;
            "inspect -f {{.State.Running}} remnanode") printf 'true\n' ;;
            "inspect -f {{.Config.Image}} remnanode") printf 'remnawave/node:test\n' ;;
            "inspect -f {{json .Mounts}} remnanode")
                if ((MOCK_EMPTY_MOUNT)); then printf '[]\n'
                else printf '[{"Source":"/opt/certbot/certs","Destination":"/etc/letsencrypt","RW":false}]\n'; fi ;;
            'exec remnanode sh -c command -v xray'*) return 1 ;;
            'exec remnanode test -r '*) return 0 ;;
            'exec remnanode sh -c '*) printf '{"inbounds":[{"streamSettings":{"network":"raw","security":"reality"}}]}\n' ;;
            *) printf 'docker %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1 ;;
        esac
    }
    # shellcheck disable=SC2329
    mkdir() { printf 'mkdir %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }
    # shellcheck disable=SC2329
    install() { printf 'install %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }
    # shellcheck disable=SC2329
    chmod() { printf 'chmod %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }
    # shellcheck disable=SC2329
    cp() { printf 'cp %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }
    # shellcheck disable=SC2329
    mv() { printf 'mv %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }
    # shellcheck disable=SC2329
    rm() {
        local IFS=' '
        if [[ $* == "-rf -- $tmp" ]]; then command rm -rf -- "$tmp"; return $?; fi
        printf 'rm %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1
    }
    # shellcheck disable=SC2329
    ln() { printf 'ln %s\n' "$*" >>"$READONLY_ACTION_LOG"; return 1; }
    readonly_source=${MENU_TEST_SOURCE:-${BASH_SOURCE[0]}}
    if [[ ! -f $readonly_source ]]; then
        readonly_source=$tmp/read-only-sentinel
        printf 'read-only sentinel\n' >"$readonly_source"
    fi
    readonly_hash=$(sha256sum "$readonly_source" | awk '{print $1}')
    TRANSPORT_STATE_OVERRIDE=$tmp/transport-state
    runtime_transport_pairs() { printf 'raw|reality\nxhttp|reality\n'; }
    https_backend_ready() { return 0; }
    : >"$ui_input_path"
    printf '1\n4\n5\n6\n7\n0\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd COLUMNS=40
    candidate_hash=$(sha256sum "$candidate_path/inbound.json" "$candidate_path/README.md" | sha256sum | awk '{print $1}')
    transport_manager_menu || die 'self-test transport menu: read-only path failed'
    exec {input_fd}<&-
    exec {output_fd}>&-
    grep -Fq 'VLESS XHTTP + REALITY' "$ui_output_path" || die 'self-test transport menu: runtime XHTTP status missing'
    grep -Fq 'ПЕРЕКЛЮЧЕНИЕ · ПЛАН' "$ui_output_path" || die 'self-test transport menu: activation plan missing'
    grep -Fq 'СОВМЕСТИМОСТЬ' "$ui_output_path" || die 'self-test transport menu: compatibility screen missing'
    grep -Fq 'Шаблон TLS' "$ui_output_path" || die 'self-test transport menu: profile templates missing'
    grep -Fq 'ИСТОРИЯ ПОДГОТОВЛЕННЫХ КАНДИДАТОВ' "$ui_output_path" || die 'self-test transport menu: history missing'
    [[ $(sha256sum "$candidate_path/inbound.json" "$candidate_path/README.md" | sha256sum | awk '{print $1}') == "$candidate_hash" ]] || die 'self-test transport menu: read-only screens modified candidate files'
    [[ ! -s $READONLY_ACTION_LOG ]] || die "self-test transport menu: read-only actions invoked mutations: $(cat "$READONLY_ACTION_LOG")"

    candidate_count_before=$(find "$TRANSPORT_STATE_OVERRIDE/candidates" -mindepth 1 -maxdepth 1 -type d | wc -l)
    printf '2\n1\n\n0\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    transport_manager_menu || die 'self-test transport menu: cancellation flow failed'
    exec {input_fd}<&-
    exec {output_fd}>&-
    grep -Fq 'Подготовка отменена; файлы не менялись.' "$ui_output_path" || die 'self-test transport menu: empty confirmation did not cancel'
    [[ $(find "$TRANSPORT_STATE_OVERRIDE/candidates" -mindepth 1 -maxdepth 1 -type d | wc -l) == "$candidate_count_before" ]] || die 'self-test transport menu: cancelled candidate changed files'
    printf '3\n\n0\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    transport_manager_menu || die 'self-test transport menu: XHTTP cancellation flow failed'
    exec {input_fd}<&-
    exec {output_fd}>&-
    grep -Fq 'Подготовка отменена; файлы не менялись.' "$ui_output_path" || die 'self-test transport menu: XHTTP empty confirmation did not cancel'
    [[ $(find "$TRANSPORT_STATE_OVERRIDE/candidates" -mindepth 1 -maxdepth 1 -type d | wc -l) == "$candidate_count_before" ]] || die 'self-test transport menu: cancelled XHTTP preparation changed files'
    printf '2\n3\nДА\n0\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    transport_manager_menu || die 'self-test transport menu: confirmed candidate flow failed'
    exec {input_fd}<&-
    exec {output_fd}>&-
    grep -Fq 'Кандидат сохранён:' "$ui_output_path" || die 'self-test transport menu: explicit confirmation did not create candidate'
    [[ $(find "$TRANSPORT_STATE_OVERRIDE/candidates" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq $((candidate_count_before + 1)) ]] || die 'self-test transport menu: confirmed inbound candidate missing'
    printf '3\nДА\n0\n' >"$ui_input_path"
    exec {input_fd}<"$ui_input_path"
    exec {output_fd}>"$ui_output_path"
    UI_INPUT_FD=$input_fd UI_OUTPUT_FD=$output_fd
    transport_manager_menu || die 'self-test transport menu: confirmed XHTTP mode flow failed'
    exec {input_fd}<&-
    exec {output_fd}>&-
    grep -Fq 'XHTTP-кандидаты сохранены:' "$ui_output_path" || die 'self-test transport menu: explicit XHTTP confirmation did not create mode matrix'
    [[ $(find "$TRANSPORT_STATE_OVERRIDE/candidates" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq $((candidate_count_before + 2)) ]] || die 'self-test transport menu: XHTTP mode candidate missing'
    [[ ! -s $READONLY_ACTION_LOG ]] || die 'self-test transport menu: cancelled preparation ran a mutating command'

    TRANSPORT_STATE_OVERRIDE=''
    : >"$ui_output_path"
    exec {output_fd}>"$ui_output_path"
    UI_OUTPUT_FD=$output_fd
    COLUMNS=40
    run_readonly_action 3 || die 'self-test read-only: status action failed'
    exec {output_fd}>&-
    grep -Fq 'HTTP 301' "$ui_output_path" || die 'self-test read-only: status table missing HTTP 301'
    if ! grep -Fq 'REALITY SELFSTEAL' "$ui_output_path" || ! grep -Fq '| WARNING' "$ui_output_path"; then die 'self-test read-only: handshake disclaimer missing'; fi
    if ! grep -Fq 'HY2 certificate' "$ui_output_path" || ! grep -Fq '| PASS' "$ui_output_path"; then die 'self-test read-only: HY2 certificate qualification missing'; fi
    for menu_expected in 'Домен' 'DNS' 'Сертификат' 'Окончание сертификата' 'Nginx' 'HTTP 301' 'HTTPS 9443' 'TLS 1.2' 'TLS 1.3' 'HSTS' 'TCP/443' 'rw-core/Xray' 'Docker volume' 'REALITY SELFSTEAL' 'VLESS TLS' 'HY2 certificate' 'Remnanode' 'Сертификат в контейнере' 'Таймер продления'; do
        grep -Fq "$menu_expected" "$ui_output_path" || die "self-test read-only: status field missing: $menu_expected"
    done
    python3 - "$ui_output_path" 40 <<'PY' || die 'self-test read-only: narrow status layout exceeds width'
import sys, unicodedata
path, limit = sys.argv[1], int(sys.argv[2])
def width(text):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)
with open(path, encoding="utf-8") as stream:
    bad = [(i, width(line.rstrip("\n"))) for i, line in enumerate(stream, 1) if width(line.rstrip("\n")) > limit]
if bad:
    print(bad, file=sys.stderr)
    raise SystemExit(1)
PY
    [[ ! -s $READONLY_ACTION_LOG ]] || die "self-test read-only: status invoked a service/configuration mutation: $(cat "$READONLY_ACTION_LOG")"

    # Regression: Nginx/9443 and rw-core/443 can be healthy while the Xray
    # certificate path and Docker mount are absent. Report each state separately.
    MOCK_EMPTY_MOUNT=1 MOCK_HOST_CERT=0 MOCK_CONTAINER_CERT=0 MOCK_ACTIVE_MODE=TLS
    : >"$ui_output_path"
    exec {output_fd}>"$ui_output_path"
    UI_OUTPUT_FD=$output_fd
    run_readonly_action 3 || die 'self-test certificate visibility: status action failed'
    exec {output_fd}>&-
    grep -Fq 'HTTPS 9443 | PASS' "$ui_output_path" || die 'self-test certificate visibility: healthy Nginx backend was misreported'
    grep -Fq 'Сертификат | FAIL' "$ui_output_path" || die 'self-test certificate visibility: missing expected host certificate was hidden'
    grep -Fq 'TCP/443 | PASS' "$ui_output_path" || die 'self-test certificate visibility: active TCP/443 listener was misreported'
    grep -Fq 'rw-core/Xray | PASS' "$ui_output_path" || die 'self-test certificate visibility: active rw-core was misreported'
    grep -Fq 'Docker volume | FAIL' "$ui_output_path" || die 'self-test certificate visibility: missing Docker mount was hidden'
    grep -Fq 'Сертификат в контейнере | FAIL' "$ui_output_path" || die 'self-test certificate visibility: missing in-container certificate was hidden'
    grep -Fq 'VLESS TLS | FAIL' "$ui_output_path" || die 'self-test certificate visibility: TLS readiness was inferred from rw-core alone'
    [[ ! -s $READONLY_ACTION_LOG ]] || die 'self-test certificate visibility: read-only status invoked a mutation'

    : >"$ui_output_path"
    exec {output_fd}>"$ui_output_path"
    UI_OUTPUT_FD=$output_fd
    run_readonly_action 4 || die 'self-test read-only: profile templates action failed'
    exec {output_fd}>&-
    grep -Fq 'Шаблон TLS' "$ui_output_path" || die 'self-test read-only: profile templates missing'
    [[ ! -s $READONLY_ACTION_LOG ]] || die "self-test read-only: templates invoked a service/configuration mutation: $(cat "$READONLY_ACTION_LOG")"
    [[ $(sha256sum "$readonly_source" | awk '{print $1}') == "$readonly_hash" ]] || die 'self-test read-only: source/sentinel file changed'

    say 'self-test: PASS'
}

if [[ ${1:-} == --self-test ]]; then self_test; exit 0; fi
[[ $# -eq 0 ]] || die 'Использование: запуск без аргументов или --self-test.'
exec {TTY_FD}<>/dev/tty || die 'Требуется интерактивный терминал (/dev/tty).'
trap on_exit EXIT
menu
case $MODE in
    5) exit 0 ;;
    3|4) run_readonly_action "$MODE"; exit 0 ;;
    6) transport_manager_menu; exit 0 ;;
    1|2)
        confirm_menu_action "$MODE" || cancel_operation
        ;;
    *) die 'Недопустимый пункт меню.' ;;
esac
if [[ $MODE == 2 ]]; then
    load_state || die "Для перевыдачи требуется корректный $STATE_FILE. Сначала выполните Verify / repair."
    ask_value "Email Let's Encrypt: " EMAIL valid_email
else
    load_state || true
    ask_value 'Домен этой Node: ' DOMAIN valid_domain
    ask_value "Email Let's Encrypt: " EMAIL valid_email
fi
check_prerequisites
check_dns
BACKUP_DIR=$(mktemp -d /var/backups/remna-node-tls.XXXXXX)
ensure_nginx
ensure_certbot_compose
issue_certificate
ensure_node_volume
NGINX_RELOADED=0
ensure_nginx
if ((CERTIFICATE_CHANGED)); then
    if ((!NGINX_RELOADED)); then
        nginx -t || die 'nginx -t failed after certificate changed.'
        confirm_or_cancel 'Сертификат изменился. Подтвердите reload Nginx, чтобы применить его на HTTPS backend.'
        systemctl reload nginx || die 'Failed to reload Nginx after certificate changed.'
    fi
    refresh_node_certificate_if_used 1 || die 'Remnanode certificate refresh failed after certificate changed.'
fi
https_backend_ready || die 'HTTPS Selfsteal backend 127.0.0.1:9443 failed certificate/SAN/site/HSTS validation.'
install_renewal
save_state
docker ps
docker top remnanode >/dev/null || die 'docker top remnanode failed.'
nginx -t || die 'Final nginx -t failed.'
http_backend_ready || die 'Final HTTP fallback check failed.'
http_redirect_ready || die 'HTTP listener failed the 301 URI/query validation.'
https_backend_ready || die 'HTTPS Selfsteal backend 127.0.0.1:9443 failed certificate/SAN/site/HSTS validation.'
print_summary
