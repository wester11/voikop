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
readonly CERT_MOUNT=/opt/certbot/certs:/etc/letsencrypt:ro
DOMAIN='' EMAIL='' MODE='' TTY_FD='' BACKUP_DIR='' NGINX_CHANGED=0 NGINX_RELOADED=0 CERTIFICATE_CHANGED=0 COMPOSE_CHANGED=0 RENEWAL_CHANGED=0 RENEWAL_WAS_ACTIVE=0 RENEWAL_WAS_ENABLED=0 NGINX_WAS_ACTIVE=0 ACME_CHECK_PASSED=0
WEB_ROOT=/var/www/remna-node-site

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
    local label=$1 out=$2 answer
    printf '%s' "$label" >&"$TTY_FD"
    IFS= read -e -r -u "$TTY_FD" answer || die 'Не удалось прочитать ввод из /dev/tty.'
    normalize_terminal_input "$answer" answer
    printf -v "$out" '%s' "$answer"
}
ask_value() {
    local label=$1 out=$2 validator=$3 value
    while :; do
        prompt "$label" value
        if [[ $out == DOMAIN ]]; then value=${value,,}; fi
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
    location / { return 404; }
}
EOF
    if ((with_tls)); then cat <<EOF
server {
    listen 127.0.0.1:9443 ssl;
    server_name $1;
    ssl_certificate $CERTS_DIR/live/current/fullchain.pem;
    ssl_certificate_key $CERTS_DIR/live/current/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
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
newline = "\r\n" if "\r\n" in text else "\n"

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
        comment = re.search(r"\s+#.*$", lines[volumes_index].rstrip("\r\n"))
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
    printf '\n[1] Verify / repair\n[2] Reissue certificate\n[3] Show TLS / Selfsteal readiness\n[4] Show Remnawave profile templates\n[5] Exit\nChoice: ' >&"$TTY_FD"
    IFS= read -r -u "$TTY_FD" MODE || die 'Не удалось прочитать выбор.'
    [[ $MODE == 1 || $MODE == 2 || $MODE == 3 || $MODE == 4 || $MODE == 5 ]] || die 'Выберите значение от 1 до 5.'
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

https_backend_ready() {
    local cert=${1:-$CERTS_DIR/live/current/fullchain.pem}
    [[ -r $cert ]] && certificate_has_domain_san "$cert" &&
        curl --noproxy '*' -fsS --max-time 5 --resolve "$DOMAIN:9443:127.0.0.1" --cacert "$cert" "https://$DOMAIN:9443/" >/dev/null
}

container_certificate_ready() {
    docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem &&
        docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem
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
    say 'TLS template (Remnawave Config Profile):'
    cat <<'EOF'
Inbound: VLESS / RAW (TCP)
Security: TLS
Certificate path: /etc/letsencrypt/live/current/fullchain.pem
Private key path: /etc/letsencrypt/live/current/privkey.pem
Fallback: 127.0.0.1:8080
EOF
    say ''
    say 'REALITY SELFSTEAL template (Remnawave Config Profile):'
    cat <<'EOF'
Inbound: VLESS / RAW (TCP)
Security: REALITY
Target: 127.0.0.1:9443
xver: 0
privateKey: <EXISTING_SHARED_REALITY_PRIVATE_KEY>
shortIds: <EXISTING_SHARED_REALITY_SHORT_IDS>
serverNames: <ADD_THIS_NODE_DOMAIN>
EOF
    say ''
    say "IMPORTANT: REALITY serverNames does not support wildcard. Add this Node domain to the shared profile serverNames list: ${DOMAIN:-<DOMAIN>}"
    say 'Shared profile across Nodes: use one shared REALITY private key; include every Node domain in serverNames; set each Host Address/SNI to that Node domain; keep target 127.0.0.1:9443.'
    say 'SECURITY WARNING: a shared privateKey is a shared compromise boundary. If one Node is compromised, rotate the REALITY key for the entire group.'
}

show_readiness() {
    local cert=$CERTS_DIR/live/current/fullchain.pem tls_ready=NO selfsteal_ready=NO hy2_ready=NO cert_valid=NO
    say "DOMAIN: ${DOMAIN:-UNKNOWN}"
    if [[ -n $DOMAIN ]] && certificate_valid && certificate_has_domain_san "$cert"; then cert_valid=YES; fi
    if [[ $cert_valid == YES ]] && container_certificate_ready && http_backend_ready; then tls_ready=YES; fi
    if [[ $cert_valid == YES ]] && https_backend_ready; then selfsteal_ready=YES; fi
    if [[ $cert_valid == YES ]] && container_certificate_ready; then hy2_ready=YES; fi
    say "TLS MODE READY: $tls_ready"
    say "SELFSTEAL MODE READY: $selfsteal_ready"
    say "HY2 READY: $hy2_ready"
    say "ACTIVE MODE: $(detect_active_mode)"
    if [[ -r $cert ]]; then openssl x509 -in "$cert" -noout -enddate | sed 's/^/CERTIFICATE EXPIRES: /'; fi
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
        backup_file "$NGINX_FILE"
        printf '%s\n' "$rendered" >"$NGINX_FILE"
        NGINX_CHANGED=1
        nginx -t || die 'nginx -t failed; изменение будет отменено.'
        if ((NGINX_WAS_ACTIVE)); then systemctl reload nginx; else systemctl enable --now nginx; fi
        NGINX_RELOADED=1
    fi
    if ! systemctl is-active --quiet nginx; then systemctl enable --now nginx; fi
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
        "root $WEBROOT;" \
        'listen 80;'; do
        grep -Fq -- "$marker" <<<"$config" || return 1
    done
    if [[ -r $CERTS_DIR/live/current/fullchain.pem ]]; then
        for marker in 'listen 127.0.0.1:9443 ssl;' "$CERTS_DIR/live/current/fullchain.pem" "$CERTS_DIR/live/current/privkey.pem"; do
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
    mkdir -p "$CERTS_DIR"
    ensure_acme_webroot_permissions
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
    local patch_status=0
    patch_certbot_compose "$f" "$BACKUP_DIR" || patch_status=$?
    case $patch_status in
        0) ;;
        10)
            if ! (cd "$CERTBOT_DIR" && docker compose config >/dev/null); then
                restore_file "$f"
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
    docker top remnanode -eo comm 2>/dev/null | grep -Eiq '^(rw-core|xray)$'
}

renewal_after_change() {
    local before=$1 after=$2
    [[ $before != "$after" ]] || return 0
    certificate_valid || { warn 'Renewal produced an invalid certificate, SAN, expiry, or key pair.'; return 1; }
    nginx -t || { warn 'nginx -t failed after certificate renewal.'; return 1; }
    systemctl reload nginx || { warn 'Nginx reload failed after certificate renewal.'; return 1; }
    https_backend_ready || { warn 'HTTPS backend 127.0.0.1:9443 failed after certificate renewal.'; return 1; }
    docker compose -f "$NODE_COMPOSE" restart remnanode || { warn 'Remnanode restart failed after certificate renewal.'; return 1; }
    sleep 15
    if ! container_certificate_ready || ! remnawave_core_ready; then
        warn 'Remnanode certificate mount or rw-core check failed after restart.'
        return 1
    fi
}

issue_certificate() {
    local cert=$CERTS_DIR/live/$DOMAIN/fullchain.pem key=$CERTS_DIR/live/$DOMAIN/privkey.pem before=''
    [[ -r $cert ]] && before=$(sha256sum "$cert" | awk '{print $1}')
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
    local after
    after=$(sha256sum "$current/fullchain.pem" | awk '{print $1}')
    [[ $before == "$after" ]] || CERTIFICATE_CHANGED=1
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
    local domain=$1
    cat <<'RENEW'
#!/usr/bin/env bash
# Managed by remnawave-node-tls-setup.sh
set -Eeuo pipefail
CERTS_DIR=/opt/certbot/certs
NODE_DIR=/opt/remnanode
NODE_COMPOSE=/opt/remnanode/docker-compose.yml
RENEW
    printf 'DOMAIN=%q\n' "$domain"
    declare -f warn certificate_has_domain_san certificate_valid https_backend_ready container_certificate_ready remnawave_core_ready renewal_after_change
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
    say "NGINX FALLBACK/8080: $(http_backend_ready && printf PASS || printf FAIL)"
    say "NGINX SELFSTEAL/9443: $(https_backend_ready && printf PASS || printf FAIL)"
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
    # The production probe resolves curl by name; this stub intercepts it in the self-test.
    # shellcheck disable=SC2329
    curl() {
        printf 'curl:%s\n' "$1" >>"$MOCK_ACME_PROBE_LOG"
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
    rm -f -- "$acme_probe_log"
    acme_config=$(printf '%s\n' "# configuration file $NGINX_FILE:" 'server { listen 80; }')
    if effective_nginx_config_has_managed_block "$acme_config"; then
        die 'self-test HTTP E: missing managed Nginx server must fail'
    fi
    DOMAIN=$saved_domain
    local rendered tls_rendered tmp bad_cert good_cert renew_log
    rendered=$(render_nginx node.example.com)
    tls_rendered=$(render_nginx node.example.com 1)
    [[ $rendered == *'listen 127.0.0.1:8080;'* && $rendered == *'listen [::]:80;'* && $rendered != *'listen 127.0.0.1:9443 ssl;'* ]] || die 'self-test Nginx 2: old TLS config shape'
    [[ $tls_rendered == *'listen 127.0.0.1:8080;'* && $tls_rendered == *'listen 127.0.0.1:9443 ssl;'* && $tls_rendered != *$'listen 443;\n'* ]] || die 'self-test Nginx 1: fresh dual-backend config'
    [[ $(grep -Fc 'listen 127.0.0.1:9443 ssl;' <<<"$tls_rendered") == 1 ]] || die 'self-test Nginx 3: old TLS Node must gain one 9443 backend'
    [[ $tls_rendered == "$rendered"* ]] || die 'self-test Nginx 2: old managed block changed while adding 9443'
    [[ $(render_nginx node.example.com 1) == "$tls_rendered" ]] || die 'self-test Nginx 4: both managed backends must remain idempotent'
    if managed_nginx_9443_listener '127.0.0.1:9443 users:(("mystery",pid=101,fd=3))' "$tls_rendered"; then die 'self-test Nginx 5: foreign 9443 listener accepted'; fi
    managed_nginx_9443_listener '127.0.0.1:9443 users:(("nginx",pid=101,fd=3))' "$tls_rendered" || die 'self-test Nginx 5: managed Nginx listener rejected'
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' RETURN
    bad_cert=$tmp/bad-san.pem; good_cert=$tmp/good-san.pem
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/bad.key" -out "$bad_cert" -days 2 -subj '/CN=other.example.com' -addext 'subjectAltName=DNS:other.example.com' >/dev/null 2>&1 || die 'self-test Cert 5: could not create mismatched test certificate'
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/good.key" -out "$good_cert" -days 2 -subj '/CN=node.example.com' -addext 'subjectAltName=DNS:node.example.com' >/dev/null 2>&1 || die 'self-test Cert 6: could not create matching test certificate'
    DOMAIN=node.example.com
    certificate_has_domain_san "$bad_cert" && die 'self-test Cert 5: mismatched SAN accepted'
    certificate_has_domain_san "$good_cert" || die 'self-test Cert 6: matching SAN rejected'

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
    https_backend_ready() { printf 'https-backend\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    container_certificate_ready() { printf 'container-certificate\n' >>"$RENEW_TEST_LOG"; }
    # shellcheck disable=SC2329
    remnawave_core_ready() { printf 'rw-core\n' >>"$RENEW_TEST_LOG"; }
    RENEW_TEST_LOG=$renew_log
    renewal_after_change same same || die 'self-test renewal 7: unchanged certificate returned failure'
    [[ ! -s $renew_log ]] || die 'self-test renewal 7: unchanged certificate triggered reload/restart'
    renewal_after_change old new || die 'self-test renewal 8: changed certificate actions failed'
    [[ $(cat "$renew_log") == $'nginx:-t\nsystemctl:reload nginx\nhttps-backend\ndocker:compose -f /opt/remnanode/docker-compose.yml restart remnanode\nsleep:15\ncontainer-certificate\nrw-core' ]] || die "self-test renewal 8: unexpected sequence: $(tr '\n' ',' <"$renew_log")"

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
    say 'self-test: PASS'
}

if [[ ${1:-} == --self-test ]]; then self_test; exit 0; fi
[[ $# -eq 0 ]] || die 'Использование: запуск без аргументов или --self-test.'
exec {TTY_FD}<>/dev/tty || die 'Требуется интерактивный терминал (/dev/tty).'
trap on_exit EXIT
menu
case $MODE in
    5) exit 0 ;;
    3)
        load_state || warn "Не найдено корректное состояние $STATE_FILE; сначала выполните Verify / repair."
        show_readiness
        exit 0
        ;;
    4)
        load_state || warn "Не найдено корректное состояние $STATE_FILE; domain будет показан как placeholder."
        show_profile_templates
        exit 0
        ;;
    1|2) ;;
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
        systemctl reload nginx || die 'Failed to reload Nginx after certificate changed.'
    fi
    docker compose -f "$NODE_COMPOSE" restart remnanode || die 'Failed to restart remnanode after certificate changed.'
    sleep 15
    if ! container_certificate_ready || ! remnawave_core_ready; then die 'Certificate changed but remnanode/rw-core verification failed.'; fi
fi
https_backend_ready || die 'HTTPS Selfsteal backend 127.0.0.1:9443 failed certificate/SAN/site validation.'
install_renewal
save_state
docker ps
docker top remnanode >/dev/null || die 'docker top remnanode failed.'
nginx -t || die 'Final nginx -t failed.'
http_backend_ready || die 'Final HTTP fallback check failed.'
print_summary
