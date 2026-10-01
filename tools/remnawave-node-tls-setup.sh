#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Local TLS preparation for one Remnawave Node. Panel and ORBIT install.sh are untouched.
readonly NODE_DIR=/opt/remnanode NODE_COMPOSE=/opt/remnanode/docker-compose.yml
readonly CERTBOT_DIR=/opt/certbot CERTS_DIR=/opt/certbot/certs WEBROOT=/opt/certbot/www
readonly NGINX_FILE=/etc/nginx/conf.d/remna-node-tls-setup.conf
readonly FALLBACK_DIR=/var/www/remna-node-site
readonly RENEW_SCRIPT=/usr/local/sbin/remna-cert-renew
readonly RENEW_SERVICE=/etc/systemd/system/remna-cert-renew.service
readonly RENEW_TIMER=/etc/systemd/system/remna-cert-renew.timer
readonly CERT_MOUNT=/opt/certbot/certs:/etc/letsencrypt:ro
DOMAIN='' EMAIL='' MODE='' TTY_FD='' BACKUP_DIR='' NGINX_CHANGED=0 COMPOSE_CHANGED=0 RENEWAL_CHANGED=0 RENEWAL_WAS_ACTIVE=0 RENEWAL_WAS_ENABLED=0 NGINX_WAS_ACTIVE=0

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

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

prompt() {
    local label=$1 out=$2 answer
    printf '%s' "$label" >&"$TTY_FD"
    IFS= read -r -u "$TTY_FD" answer || die 'Не удалось прочитать ввод из /dev/tty.'
    printf -v "$out" '%s' "$answer"
}
ask_value() {
    local label=$1 out=$2 validator=$3 value
    while :; do
        prompt "$label" value
        if "$validator" "$value"; then printf -v "$out" '%s' "$value"; return 0; fi
        say 'Некорректное значение. Повторите ввод.' >&"$TTY_FD"
    done
}
backup_file() {
    local path=$1 name=${1#/}
    name=${name//\//__}
    if [[ -e $path || -L $path ]]; then cp -a -- "$path" "$BACKUP_DIR/$name"; else : >"$BACKUP_DIR/$name.absent"; fi
}
restore_file() {
    local path=$1 name=${1#/}
    name=${name//\//__}
    if [[ -e $BACKUP_DIR/$name || -L $BACKUP_DIR/$name ]]; then mkdir -p "$(dirname "$path")"; cp -a -- "$BACKUP_DIR/$name" "$path"
    elif [[ -e $BACKUP_DIR/$name.absent ]]; then rm -f -- "$path"; fi
}
rollback() {
    if ((NGINX_CHANGED)); then
        restore_file "$NGINX_FILE" || warn 'Could not restore Nginx config.'
        if ((NGINX_WAS_ACTIVE)); then
            if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || warn 'Could not reload Nginx after rollback.'
            else warn 'Restored Nginx config did not validate; reload was skipped.'; fi
        fi
    fi
    if ((COMPOSE_CHANGED)); then
        restore_file "$NODE_COMPOSE" || warn 'Could not restore Node Compose.'
        (cd "$NODE_DIR" && docker compose up -d remnanode) >/dev/null 2>&1 || warn 'Could not restore remnanode after rollback.'
    fi
    if ((RENEWAL_CHANGED)); then
        restore_file "$RENEW_SCRIPT" || warn 'Could not restore renewal script.'
        restore_file "$RENEW_SERVICE" || warn 'Could not restore renewal service.'
        restore_file "$RENEW_TIMER" || warn 'Could not restore renewal timer.'
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
    ((status == 0)) || rollback
    [[ -z $TTY_FD ]] || exec {TTY_FD}<&- || true
    exit "$status"
}

render_nginx() {
    cat <<EOF
# Managed by remnawave-node-tls-setup.sh
server {
    listen 127.0.0.1:8080;
    server_name _;
    root $FALLBACK_DIR;
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
    location / { return 404; }
}
EOF
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

menu() {
    printf '\n[1] Verify / repair\n[2] Reissue certificate\n[3] Exit\nChoice: ' >&"$TTY_FD"
    IFS= read -r -u "$TTY_FD" MODE || die 'Не удалось прочитать выбор.'
    [[ $MODE == 1 || $MODE == 2 || $MODE == 3 ]] || die 'Выберите 1, 2 или 3.'
}

port_is_listening() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
port_owner() { ss -lntp "sport = :$1" 2>/dev/null || true; }

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
    if [[ -e $NGINX_FILE ]] && ! grep -Fq 'Managed by remnawave-node-tls-setup.sh' "$NGINX_FILE"; then
        die "$NGINX_FILE существует и не помечен как файл этого установщика; перезапись запрещена."
    fi
    mkdir -p "$FALLBACK_DIR" "$WEBROOT/.well-known/acme-challenge"
    if [[ -e $FALLBACK_DIR/index.html ]] && ! grep -Fq '<h1>Hello World</h1>' "$FALLBACK_DIR/index.html"; then
        die "$FALLBACK_DIR/index.html already contains other content; refusing to overwrite it."
    fi
    if [[ ! -e $FALLBACK_DIR/index.html ]]; then cat >"$FALLBACK_DIR/index.html" <<'HTML'
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
    rendered=$(render_nginx "$DOMAIN")
    if [[ ! -f $NGINX_FILE || $(cat "$NGINX_FILE") != "$rendered" ]]; then
        backup_file "$NGINX_FILE"
        printf '%s\n' "$rendered" >"$NGINX_FILE"
        NGINX_CHANGED=1
        nginx -t || die 'nginx -t failed; изменение будет отменено.'
        if ((NGINX_WAS_ACTIVE)); then systemctl reload nginx; else systemctl enable --now nginx; fi
    fi
    if ! systemctl is-active --quiet nginx; then systemctl enable --now nginx; fi
    nginx -t || die 'nginx -t failed.'
    curl -fsS --max-time 5 http://127.0.0.1:8080/ | grep -q 'Hello World' || die 'Fallback 127.0.0.1:8080 не вернул Hello World.'
    check_http_acme || die 'Nginx HTTP-01 webroot validation failed.'
}

check_http_acme() {
    local token challenge response
    token="remna-check-${RANDOM}${RANDOM}"
    challenge="$WEBROOT/.well-known/acme-challenge/$token"
    printf '%s' "$token" >"$challenge"
    response=$(curl -fsS --max-time 5 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/.well-known/acme-challenge/$token" || true)
    rm -f -- "$challenge"
    [[ $response == "$token" ]]
}

ensure_certbot_compose() {
    mkdir -p "$CERTS_DIR" "$WEBROOT"
    local f=$CERTBOT_DIR/docker-compose.yml
    if [[ ! -f $f ]]; then
        backup_file "$f"
        cat >"$f" <<'YAML'
services:
  certbot:
    image: certbot/certbot:latest
    volumes:
      - ./certs:/etc/letsencrypt
      - ./www:/var/www/certbot
YAML
    fi
    grep -Eq '^  certbot:' "$f" || die 'Existing Certbot Compose must define the certbot service.'
    grep -Fq './certs:/etc/letsencrypt' "$f" || die 'Existing Certbot Compose lacks the expected ./certs mount.'
    grep -Fq './www:/var/www/certbot' "$f" || die 'Existing Certbot Compose lacks the expected ./www mount.'
    docker compose -f "$f" config >/dev/null || die 'Certbot Compose config invalid.'
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
    [[ $pubc == "$pubk" ]]
}

issue_certificate() {
    local cert=$CERTS_DIR/live/$DOMAIN/fullchain.pem key=$CERTS_DIR/live/$DOMAIN/privkey.pem
    if [[ -e $cert || -e $key ]]; then
        if ((MODE == 1)) && certificate_valid; then
            say 'Существующий сертификат валиден; сохраняю его.'
        elif ((MODE == 2)); then
            (cd "$CERTBOT_DIR" && docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot --non-interactive --agree-tos --email "$EMAIL" --force-renewal -d "$DOMAIN") || die 'Certificate issuance failed; existing files retained.'
        else
            die 'Существующий сертификат не прошёл проверку. Для перевыдачи запустите снова и выберите пункт 2.'
        fi
    else
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
        ln -s "$DOMAIN" "$current"
    fi
    [[ -r $current/fullchain.pem && -r $current/privkey.pem ]] || die 'current certificate link unreadable.'
}

ensure_node_volume() {
    if grep -Fq "$CERT_MOUNT" "$NODE_COMPOSE"; then
        say 'Remnanode certificate volume already exists.'
        if ! docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true; then
            (cd "$NODE_DIR" && docker compose up -d remnanode) || die 'Не удалось запустить remnanode.'
        fi
        docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem || die 'fullchain.pem недоступен внутри remnanode.'
        docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem || die 'privkey.pem недоступен внутри remnanode.'
        return 0
    fi
    backup_file "$NODE_COMPOSE"
    patch_node_compose || die 'Безопасная правка Compose невозможна; исходный файл сохранён.'
    COMPOSE_CHANGED=1
    if ! docker compose -f "$NODE_COMPOSE" config >/dev/null; then
        restore_file "$NODE_COMPOSE"; COMPOSE_CHANGED=0
        die 'docker compose config failed; прежний файл восстановлен.'
    fi
    (cd "$NODE_DIR" && docker compose up -d remnanode) || die 'Не удалось применить volume к remnanode.'
    sleep 15
    if ! docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true || ! docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem || ! docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem; then
        docker logs --tail 100 remnanode || true
        die 'Контейнер не запустился или сертификат недоступен после добавления volume.'
    fi
}

render_renew_script() {
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\n# Managed by remnawave-node-tls-setup.sh\nset -Eeuo pipefail\nCERT=/opt/certbot/certs/live/current/fullchain.pem\nKEY=/opt/certbot/certs/live/current/privkey.pem\nDOMAIN=%s\nbefore=$(sha256sum "$CERT" | awk '\''{print $1}'\'')\n(cd /opt/certbot && docker compose run --rm certbot renew --quiet)\nafter=$(sha256sum "$CERT" | awk '\''{print $1}'\'')\n[[ $before != "$after" ]] || exit 0\nopenssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" -checkend 0\nopenssl x509 -in "$CERT" -noout -dates\ncert_pub=$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '\''{print $1}'\'')\nkey_pub=$(openssl pkey -in "$KEY" -pubout -outform DER | sha256sum | awk '\''{print $1}'\'')\n[[ $cert_pub == "$key_pub" ]]\n(cd /opt/remnanode && docker compose restart remnanode)\nsleep 15\ndocker inspect -f '\''{{.State.Running}}'\'' remnanode | grep -qx true\ndocker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem\ndocker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem\ndocker logs --since 30s remnanode\n' "$1"
}

install_renewal() {
    systemctl is-active --quiet remna-cert-renew.timer && RENEWAL_WAS_ACTIVE=1 || RENEWAL_WAS_ACTIVE=0
    systemctl is-enabled --quiet remna-cert-renew.timer && RENEWAL_WAS_ENABLED=1 || RENEWAL_WAS_ENABLED=0
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
    say "NGINX HTTP/80: $(check_http_acme && printf PASS || printf FAIL)"
    say "NGINX FALLBACK/8080: $(curl -fsS --max-time 5 http://127.0.0.1:8080/ | grep -q 'Hello World' && printf PASS || printf FAIL)"
    say "REMNANODE CERT VOLUME: $(grep -Fq "$CERT_MOUNT" "$NODE_COMPOSE" && printf PASS || printf FAIL)"
    say "CERT INSIDE CONTAINER: $(docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem && docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem && printf PASS || printf FAIL)"
    say "RENEW TIMER: $(systemctl is-active --quiet remna-cert-renew.timer && printf PASS || printf FAIL)"
    [[ $tcp == NOT_YET_LISTENING ]] && tcp='NOT YET LISTENING'
    [[ $udp == NOT_YET_LISTENING ]] && udp='NOT YET LISTENING'
    say "TCP 443: $tcp"
    say "UDP 443: $udp"
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
    local rendered tmp
    rendered=$(render_nginx node.example.com)
    [[ $rendered == *'listen 127.0.0.1:8080;'* && $rendered == *'listen [::]:80;'* && $rendered != *'listen 443'* ]] || die 'self-test: Nginx template'
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' RETURN
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
    render_renew_script node.example.com >"$tmp/remna-cert-renew"
    bash -n "$tmp/remna-cert-renew" || die 'self-test: generated renewal script syntax'
    grep -Fq 'DOMAIN=node.example.com' "$tmp/remna-cert-renew" || die 'self-test: renewal domain'
    say 'self-test: PASS'
}

if [[ ${1:-} == --self-test ]]; then self_test; exit 0; fi
[[ $# -eq 0 ]] || die 'Использование: запуск без аргументов или --self-test.'
exec {TTY_FD}<>/dev/tty || die 'Требуется интерактивный терминал (/dev/tty).'
trap on_exit EXIT
menu
[[ $MODE != 3 ]] || exit 0
ask_value 'Домен этой Node: ' DOMAIN valid_domain
ask_value "Email Let's Encrypt: " EMAIL valid_email
check_prerequisites
check_dns
BACKUP_DIR=$(mktemp -d /var/backups/remna-node-tls.XXXXXX)
ensure_nginx
ensure_certbot_compose
issue_certificate
ensure_node_volume
install_renewal
docker ps
docker top remnanode || die 'docker top remnanode failed.'
nginx -t || die 'Final nginx -t failed.'
curl -fsS http://127.0.0.1:8080/ | grep -q 'Hello World' || die 'Final fallback check failed.'
print_summary
