#!/bin/sh
# VOID Router bootstrap. POSIX / BusyBox ash only.
# Public code: no customer subscription, activation code or private key lives here.

set -eu
umask 077

API_ORIGIN='https://routersub.netvoid.ru'
MIN_FREE_KB=24576
PODKOP_VERSION='0.7.21'
PODKOP_APK_SHA256='55870987143ff985272f151e36185e5616d2645aec6faae64e0f5a0f121c1e3b'
LUCI_APK_SHA256='aa370b9ba123b570a630bdf408fa2de291a1e0c0bb4cfaecb2350f4d15eebc12'
PODKOP_IPK_SHA256='e67956585f018b460fe3af62029577946a0da6faaac92669dfc0361efe09a0ef'
LUCI_IPK_SHA256='280eac58d6ae43601d4aaa05342d2b47415384ef16f9664a09cf309816667f92'

say() { printf '%s\n' "[VOID] $*"; }
die() { printf '%s\n' "[VOID] ERROR: $*" >&2; exit 1; }

WORK_DIR=''
ACTIVATION_CODE=''
cleanup() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
    ACTIVATION_CODE=''
    unset ACTIVATION_CODE VOID_ENROLLMENT_CODE 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" = '0' ] || die 'Run as root.'
[ -r /etc/openwrt_release ] || die 'This installer supports OpenWrt only.'
command -v uci >/dev/null 2>&1 || die 'uci is required.'

install_base_prerequisites() {
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add curl ca-bundle
    elif command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install curl ca-bundle
    else
        die 'Neither apk nor opkg is available.'
    fi
}

if ! command -v curl >/dev/null 2>&1; then
    say 'Installing HTTPS prerequisite...'
    install_base_prerequisites
fi

RELEASE="$(. /etc/openwrt_release; printf '%s' "${DISTRIB_RELEASE:-}")"
case "$RELEASE" in
    24.10.*|25.*) ;;
    *) die "Unsupported OpenWrt release: ${RELEASE:-unknown}" ;;
esac

FREE_KB="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 {print $4}')"
case "$FREE_KB" in ''|*[!0-9]*) die 'Cannot determine free space on /overlay.' ;; esac
[ "$FREE_KB" -ge "$MIN_FREE_KB" ] || die "At least ${MIN_FREE_KB} KiB free space is required."

BOARD_JSON="$(ubus call system board 2>/dev/null || printf '{}')"
BOARD="$(printf '%s' "$BOARD_JSON" | jsonfilter -e '@.board_name' 2>/dev/null || true)"
MODEL="$(printf '%s' "$BOARD_JSON" | jsonfilter -e '@.model' 2>/dev/null || true)"
[ -n "$BOARD" ] || die 'Cannot determine router board name.'

ACTIVATION_CODE="${VOID_ENROLLMENT_CODE:-}"
if [ -z "$ACTIVATION_CODE" ]; then
    printf 'Activation code: '
    stty -echo 2>/dev/null || true
    IFS= read -r ACTIVATION_CODE || true
    stty echo 2>/dev/null || true
    printf '\n'
fi
[ "${#ACTIVATION_CODE}" -eq 47 ] || die 'Invalid activation code.'
case "$ACTIVATION_CODE" in ve1_*) ;; *) die 'Invalid activation code.' ;; esac
[ -z "$(printf '%s' "$ACTIVATION_CODE" | tr -d 'A-Za-z0-9_-')" ] || die 'Invalid activation code.'

WORK_DIR="$(mktemp -d /tmp/void-router.XXXXXX)"
BOOTSTRAP_RESPONSE="$WORK_DIR/bootstrap.json"
BOOTSTRAP_PAYLOAD="$WORK_DIR/bootstrap-request.json"
printf '{"code":"%s","board":"%s","model":"%s","openwrt":"%s"}' \
    "$ACTIVATION_CODE" "$BOARD" "$MODEL" "$RELEASE" >"$BOOTSTRAP_PAYLOAD"

say 'Checking activation and router compatibility...'
HTTP_CODE="$(curl --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 45 --retry 1 \
    -H 'Content-Type: application/json' -H 'Cache-Control: no-store' \
    --data-binary "@$BOOTSTRAP_PAYLOAD" -o "$BOOTSTRAP_RESPONSE" -w '%{http_code}' \
    "$API_ORIGIN/v1/router/bootstrap" || true)"
case "$HTTP_CODE" in
    200) ;;
    403) die 'Activation code is invalid, expired or already used.' ;;
    409) die 'This router or subscription is already enrolled, or requires review.' ;;
    *) die "Provisioning service returned HTTP ${HTTP_CODE:-unavailable}." ;;
esac

jget() { jsonfilter -i "$BOOTSTRAP_RESPONSE" -e "$1" 2>/dev/null || true; }
DEVICE_ID="$(jget '@.device_id')"
SUBSCRIPTION_NAME="$(jget '@.subscription_name')"
MANAGEMENT_IP="$(jget '@.management_ip')"
WG_PRIVATE="$(jget '@.wg_private_key')"
WG_SERVER_PUBLIC="$(jget '@.wg_server_public_key')"
WG_ENDPOINT_IP="$(jget '@.wg_endpoint_ip')"
WG_ENDPOINT_PORT="$(jget '@.wg_endpoint_port')"
SUPPORT_KEY="$(jget '@.support_ssh_public_key')"
REFRESH_TOKEN="$(jget '@.refresh_token')"

case "$DEVICE_ID" in rtr_[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) die 'Invalid server response.' ;; esac
[ "${#DEVICE_ID}" -eq 36 ] || die 'Invalid server response.'
case "$MANAGEMENT_IP" in 10.240.0.*) ;; *) die 'Invalid management address.' ;; esac
case "$WG_ENDPOINT_IP" in *.*.*.*) ;; *) die 'Invalid management endpoint.' ;; esac
case "$WG_ENDPOINT_PORT" in ''|*[!0-9]*) die 'Invalid management endpoint.' ;; esac
[ "${#WG_PRIVATE}" -eq 44 ] && [ "${#WG_SERVER_PUBLIC}" -eq 44 ] || die 'Invalid WireGuard response.'
case "$SUPPORT_KEY" in 'ssh-ed25519 '*" void-router:$DEVICE_ID") ;; *) die 'Invalid support key.' ;; esac
[ "${#REFRESH_TOKEN}" -eq 47 ] || die 'Invalid refresh credential.'
case "$REFRESH_TOKEN" in vr1_*) ;; *) die 'Invalid refresh credential.' ;; esac

install_management_packages() {
    say 'Installing independent management tunnel packages...'
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add wireguard-tools kmod-wireguard ip-full ca-bundle coreutils-base64
    else
        opkg update
        opkg install wireguard-tools kmod-wireguard ip-full ca-bundle coreutils-base64
    fi
}
command -v wg >/dev/null 2>&1 || install_management_packages
command -v base64 >/dev/null 2>&1 || install_management_packages

verify_sha256() {
    expected="$1"
    file="$2"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || die "Package integrity check failed for $(basename "$file")."
}

install_podkop() {
    say "Installing Podkop ${PODKOP_VERSION} from verified release packages..."
    base="https://github.com/itdoginfo/podkop/releases/download/${PODKOP_VERSION}"
    if command -v apk >/dev/null 2>&1; then
        podkop_pkg="$WORK_DIR/podkop.apk"
        luci_pkg="$WORK_DIR/luci-app-podkop.apk"
        curl -fL --proto '=https' --tlsv1.2 -o "$podkop_pkg" "$base/podkop-${PODKOP_VERSION}-r1.apk"
        curl -fL --proto '=https' --tlsv1.2 -o "$luci_pkg" "$base/luci-app-podkop-${PODKOP_VERSION}-r1.apk"
        verify_sha256 "$PODKOP_APK_SHA256" "$podkop_pkg"
        verify_sha256 "$LUCI_APK_SHA256" "$luci_pkg"
        apk add --allow-untrusted "$podkop_pkg" "$luci_pkg"
    else
        podkop_pkg="$WORK_DIR/podkop.ipk"
        luci_pkg="$WORK_DIR/luci-app-podkop.ipk"
        curl -fL --proto '=https' --tlsv1.2 -o "$podkop_pkg" "$base/podkop-v${PODKOP_VERSION}-r1-all.ipk"
        curl -fL --proto '=https' --tlsv1.2 -o "$luci_pkg" "$base/luci-app-podkop-v${PODKOP_VERSION}-r1-all.ipk"
        verify_sha256 "$PODKOP_IPK_SHA256" "$podkop_pkg"
        verify_sha256 "$LUCI_IPK_SHA256" "$luci_pkg"
        opkg install "$podkop_pkg" "$luci_pkg"
    fi
}
[ -x /etc/init.d/podkop ] || install_podkop
[ -x /etc/init.d/podkop ] || die 'Podkop installation failed.'

say 'Writing per-router management identity...'
mkdir -p /etc/void-router /usr/libexec /etc/hotplug.d/iface /etc/dropbear
chmod 700 /etc/void-router
printf '%s\n' "$DEVICE_ID" > /etc/void-router/device_id
printf '%s\n' "$SUBSCRIPTION_NAME" > /etc/void-router/subscription_name
printf '%s\n' "$MANAGEMENT_IP" > /etc/void-router/management_ip
printf '%s\n' "$WG_PRIVATE" > /etc/void-router/wg_private.key
printf '%s\n' "$WG_SERVER_PUBLIC" > /etc/void-router/wg_server_public.key
printf '%s\n' "$WG_ENDPOINT_IP" > /etc/void-router/wg_endpoint_ip
printf '%s\n' "$WG_ENDPOINT_PORT" > /etc/void-router/wg_endpoint_port
printf '%s\n' "$REFRESH_TOKEN" > /etc/void-router/refresh_token
chmod 600 /etc/void-router/*

AUTH_KEYS=/etc/dropbear/authorized_keys
touch "$AUTH_KEYS"
grep -v ' void-router:rtr_[0-9a-f]\{32\}$' "$AUTH_KEYS" > "$WORK_DIR/authorized_keys" || true
printf '%s\n' "$SUPPORT_KEY" >> "$WORK_DIR/authorized_keys"
mv "$WORK_DIR/authorized_keys" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

cat > /usr/libexec/void-mgmt-up <<'MGMT_UP'
#!/bin/sh
set -eu
DEVICE='void_mgmt'
ADDRESS="$(cat /etc/void-router/management_ip)"
ENDPOINT="$(cat /etc/void-router/wg_endpoint_ip):$(cat /etc/void-router/wg_endpoint_port)"
SERVER_KEY="$(cat /etc/void-router/wg_server_public.key)"
ip link show "$DEVICE" >/dev/null 2>&1 || ip link add dev "$DEVICE" type wireguard
ip address show dev "$DEVICE" | grep -q " $ADDRESS/32" || {
    ip address flush dev "$DEVICE"
    ip address add "$ADDRESS/32" dev "$DEVICE"
}
wg set "$DEVICE" private-key /etc/void-router/wg_private.key \
    peer "$SERVER_KEY" endpoint "$ENDPOINT" allowed-ips 10.240.0.1/32 persistent-keepalive 25
ip link set up dev "$DEVICE"
ip route replace 10.240.0.1/32 dev "$DEVICE"
MGMT_UP
chmod 700 /usr/libexec/void-mgmt-up

cat > /etc/init.d/void-mgmt <<'MGMT_INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
start() { /usr/libexec/void-mgmt-up; }
stop() { ip link del void_mgmt 2>/dev/null || true; }
MGMT_INIT
chmod 700 /etc/init.d/void-mgmt

cat > /etc/hotplug.d/iface/99-void-mgmt <<'MGMT_HOTPLUG'
#!/bin/sh
[ "$ACTION" = ifup ] || exit 0
case "$INTERFACE" in wan|wan6) /usr/libexec/void-mgmt-up >/dev/null 2>&1 || true ;; esac
MGMT_HOTPLUG
chmod 700 /etc/hotplug.d/iface/99-void-mgmt

cat > /usr/libexec/void-router-lockdown <<'LOCKDOWN'
#!/bin/sh
set -eu
DEVICE_ID="$(cat /etc/void-router/device_id)"
grep -q " void-router:$DEVICE_ID$" /etc/dropbear/authorized_keys
for section in $(uci show dropbear | sed -n "s/^dropbear\.\([^.=]*\)=dropbear$/\1/p"); do
    uci set "dropbear.$section.PasswordAuth=off"
    uci set "dropbear.$section.RootPasswordAuth=off"
done
uci commit dropbear
(sleep 1; /etc/init.d/dropbear restart) >/dev/null 2>&1 &
printf '%s\n' locked
LOCKDOWN
chmod 700 /usr/libexec/void-router-lockdown

uci -q delete firewall.void_mgmt
uci set firewall.void_mgmt=zone
uci set firewall.void_mgmt.name='void_mgmt'
uci add_list firewall.void_mgmt.device='void_mgmt'
uci set firewall.void_mgmt.input='ACCEPT'
uci set firewall.void_mgmt.output='ACCEPT'
uci set firewall.void_mgmt.forward='REJECT'
uci set firewall.void_mgmt.masq='0'
uci commit firewall
/etc/init.d/firewall restart
/etc/init.d/void-mgmt enable
/usr/libexec/void-mgmt-up

cat > /usr/bin/void-router-refresh <<'REFRESH'
#!/bin/sh
set -eu
umask 077
API_ORIGIN='https://routersub.netvoid.ru'
LOCK_DIR=/tmp/void-router-refresh.lock
if ! mkdir "$LOCK_DIR" 2>/dev/null; then exit 0; fi
WORK_DIR="$(mktemp -d /tmp/void-refresh.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR" "$LOCK_DIR"; }
trap cleanup EXIT HUP INT TERM
DEVICE_ID="$(cat /etc/void-router/device_id)"
REFRESH_TOKEN="$(cat /etc/void-router/refresh_token)"
REQUEST="$WORK_DIR/request.json"
RESPONSE="$WORK_DIR/response.json"
printf '{"device_id":"%s","refresh_token":"%s"}' "$DEVICE_ID" "$REFRESH_TOKEN" > "$REQUEST"
HTTP_CODE="$(curl --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 60 --retry 1 -H 'Content-Type: application/json' \
    --data-binary "@$REQUEST" -o "$RESPONSE" -w '%{http_code}' "$API_ORIGIN/v1/router/config" || true)"
[ "$HTTP_CODE" = 200 ] || { echo "[VOID] Configuration update failed (HTTP ${HTTP_CODE:-unavailable})." >&2; exit 1; }
YOUTUBE_B64="$(jsonfilter -i "$RESPONSE" -e '@.youtube_b64')"
FOREIGN_B64="$(jsonfilter -i "$RESPONSE" -e '@.foreign_b64')"
[ -n "$YOUTUBE_B64" ] && [ -n "$FOREIGN_B64" ] || { echo '[VOID] Empty router groups.' >&2; exit 1; }
printf '%s' "$YOUTUBE_B64" | base64 -d > "$WORK_DIR/youtube.links"
printf '%s' "$FOREIGN_B64" | base64 -d > "$WORK_DIR/foreign.links"
grep -Eq '^(vless|vmess|trojan|ss|hy2|hysteria2|socks4|socks5)://' "$WORK_DIR/youtube.links"
grep -Eq '^(vless|vmess|trojan|ss|hy2|hysteria2|socks4|socks5)://' "$WORK_DIR/foreign.links"
NEW_HASH="$(cat "$WORK_DIR/youtube.links" "$WORK_DIR/foreign.links" | sha256sum | awk '{print $1}')"
OLD_HASH="$(cat /etc/void-router/config.hash 2>/dev/null || true)"
if [ "$NEW_HASH" = "$OLD_HASH" ]; then
    exit 0
fi
cp /etc/config/podkop "$WORK_DIR/podkop.backup"
uci -q delete podkop.void_youtube
uci -q delete podkop.void_foreign
uci set podkop.void_youtube=section
uci set podkop.void_youtube.connection_type='proxy'
uci set podkop.void_youtube.proxy_config_type='urltest'
uci set podkop.void_youtube.urltest_check_interval='3m'
uci set podkop.void_youtube.urltest_tolerance='50'
uci set podkop.void_youtube.urltest_testing_url='https://www.gstatic.com/generate_204'
uci add_list podkop.void_youtube.community_lists='youtube'
while IFS= read -r link; do
    [ -z "$link" ] || uci add_list podkop.void_youtube.urltest_proxy_links="$link"
done < "$WORK_DIR/youtube.links"
uci set podkop.void_foreign=section
uci set podkop.void_foreign.connection_type='proxy'
uci set podkop.void_foreign.proxy_config_type='urltest'
uci set podkop.void_foreign.urltest_check_interval='3m'
uci set podkop.void_foreign.urltest_tolerance='50'
uci set podkop.void_foreign.urltest_testing_url='https://www.gstatic.com/generate_204'
for list in russia_inside meta discord telegram; do
    uci add_list podkop.void_foreign.community_lists="$list"
done
while IFS= read -r link; do
    [ -z "$link" ] || uci add_list podkop.void_foreign.urltest_proxy_links="$link"
done < "$WORK_DIR/foreign.links"
uci commit podkop
if ! /etc/init.d/podkop restart; then
    cp "$WORK_DIR/podkop.backup" /etc/config/podkop
    /etc/init.d/podkop restart || true
    echo '[VOID] Podkop rejected the update; previous config restored.' >&2
    exit 1
fi
sleep 4
if ! /etc/init.d/podkop status >/dev/null 2>&1; then
    cp "$WORK_DIR/podkop.backup" /etc/config/podkop
    /etc/init.d/podkop restart || true
    echo '[VOID] Podkop failed health check; previous config restored.' >&2
    exit 1
fi
printf '%s\n' "$NEW_HASH" > /etc/void-router/config.hash
jsonfilter -i "$RESPONSE" -e '@.youtube_count' > /etc/void-router/youtube_count
jsonfilter -i "$RESPONSE" -e '@.foreign_count' > /etc/void-router/foreign_count
chmod 600 /etc/void-router/config.hash /etc/void-router/youtube_count /etc/void-router/foreign_count
echo '[VOID] Router subscription updated.'
REFRESH
chmod 700 /usr/bin/void-router-refresh

say 'Downloading and separating the router subscription...'
/usr/bin/void-router-refresh

grep -v '/usr/bin/void-router-refresh' /etc/crontabs/root > "$WORK_DIR/root.cron" || true
printf '17 * * * * /usr/bin/void-router-refresh >/dev/null 2>&1\n' >> "$WORK_DIR/root.cron"
mv "$WORK_DIR/root.cron" /etc/crontabs/root
chmod 600 /etc/crontabs/root
/etc/init.d/cron restart

say 'Waiting for the independent management tunnel...'
HANDSHAKE_OK=0
i=0
while [ "$i" -lt 20 ]; do
    if wg show void_mgmt latest-handshakes 2>/dev/null | awk '$2 > 0 {found=1} END {exit !found}'; then
        HANDSHAKE_OK=1
        break
    fi
    sleep 2
    i=$((i + 1))
done
[ "$HANDSHAKE_OK" = 1 ] || die 'Management tunnel did not establish a handshake.'

COMPLETE_REQUEST="$WORK_DIR/complete-request.json"
COMPLETE_RESPONSE="$WORK_DIR/complete.json"
printf '{"device_id":"%s","refresh_token":"%s"}' "$DEVICE_ID" "$REFRESH_TOKEN" > "$COMPLETE_REQUEST"
HTTP_CODE="$(curl --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 45 -H 'Content-Type: application/json' \
    --data-binary "@$COMPLETE_REQUEST" -o "$COMPLETE_RESPONSE" -w '%{http_code}' \
    "$API_ORIGIN/v1/router/complete" || true)"
[ "$HTTP_CODE" = 200 ] || die "Remote SSH verification failed (HTTP ${HTTP_CODE:-unavailable})."

ACTIVATION_CODE=''
unset ACTIVATION_CODE VOID_ENROLLMENT_CODE 2>/dev/null || true
say "SUCCESS: $SUBSCRIPTION_NAME is configured."
say "YouTube routes: $(cat /etc/void-router/youtube_count); other routes: $(cat /etc/void-router/foreign_count)."
say "Management: key-only SSH over a dedicated WireGuard tunnel is active."
