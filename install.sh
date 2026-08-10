#!/bin/sh
# VOID Router bootstrap. POSIX / BusyBox ash only.
# Public code: no customer subscription, activation code or private key lives here.

set -eu
umask 077

API_ORIGIN='https://routersub.netvoid.ru'
MIN_FREE_KB=24576

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

# The owner, not the installer, controls the local OpenWrt root password.
# Password SSH is disabled only after the server verifies key-only support SSH.
ROOT_HASH="$(awk -F: '$1 == "root" {print $2; exit}' /etc/shadow 2>/dev/null || true)"
case "$ROOT_HASH" in
    ''|'!'|'*')
        say 'WARNING: local root password is empty; the router owner must set it in LuCI or with passwd.'
        ;;
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
case "$SUBSCRIPTION_NAME" in ''|*[!A-Za-z0-9._-]*) die 'Invalid subscription identity.' ;; esac
[ "${#SUBSCRIPTION_NAME}" -le 64 ] || die 'Invalid subscription identity.'
case "$MANAGEMENT_IP" in 10.240.0.*) ;; *) die 'Invalid management address.' ;; esac
case "$WG_ENDPOINT_IP" in *.*.*.*) ;; *) die 'Invalid management endpoint.' ;; esac
case "$WG_ENDPOINT_PORT" in ''|*[!0-9]*) die 'Invalid management endpoint.' ;; esac
[ "${#WG_PRIVATE}" -eq 44 ] && [ "${#WG_SERVER_PUBLIC}" -eq 44 ] || die 'Invalid WireGuard response.'
case "$WG_PRIVATE$WG_SERVER_PUBLIC" in *[!A-Za-z0-9+/=]*) die 'Invalid WireGuard response.' ;; esac
case "$SUPPORT_KEY" in 'ssh-ed25519 '*" void-router:$DEVICE_ID") ;; *) die 'Invalid support key.' ;; esac
[ "${#REFRESH_TOKEN}" -eq 47 ] || die 'Invalid refresh credential.'
case "$REFRESH_TOKEN" in vr1_*) ;; *) die 'Invalid refresh credential.' ;; esac

install_management_packages() {
    say 'Installing independent management tunnel packages...'
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add wireguard-tools kmod-wireguard ip-full ca-bundle
    else
        opkg update
        opkg install wireguard-tools kmod-wireguard ip-full ca-bundle
    fi
}
command -v wg >/dev/null 2>&1 || install_management_packages

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
ENDPOINT_IP="$(cat /etc/void-router/wg_endpoint_ip)"
ENDPOINT="$ENDPOINT_IP:$(cat /etc/void-router/wg_endpoint_port)"
SERVER_KEY="$(cat /etc/void-router/wg_server_public.key)"
# The management endpoint is an IPv4 address, not a hostname: an outage of
# dnsmasq or the configured DNS resolvers cannot affect an existing tunnel.
# Keep the encrypted WireGuard UDP transport on physical WAN. Podkop policy
# routes marked traffic through its own table, so the dedicated fwmark plus the
# two higher-priority rules below make this path independent of Podkop.
MGMT_FWMARK='0x564f'
MGMT_ENDPOINT_RULE_PRIORITY=90
MGMT_MARK_RULE_PRIORITY=91
ROUTE="$(ip route get "$ENDPOINT_IP" 2>/dev/null || true)"
WAN_DEV="$(printf '%s\n' "$ROUTE" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
WAN_GW="$(printf '%s\n' "$ROUTE" | sed -n 's/.* via \([0-9.]*\).*/\1/p')"
case "$WAN_DEV" in ''|void_mgmt) WAN_DEV='' ;; esac
if [ -n "$WAN_DEV" ]; then
    if [ -n "$WAN_GW" ]; then
        ip route replace "$ENDPOINT_IP/32" via "$WAN_GW" dev "$WAN_DEV" metric 5
    else
        ip route replace "$ENDPOINT_IP/32" dev "$WAN_DEV" metric 5
    fi
fi
ip link show "$DEVICE" >/dev/null 2>&1 || ip link add dev "$DEVICE" type wireguard
ip address show dev "$DEVICE" | grep -q " $ADDRESS/32" || {
    ip address flush dev "$DEVICE"
    ip address add "$ADDRESS/32" dev "$DEVICE"
}
wg set "$DEVICE" private-key /etc/void-router/wg_private.key \
    fwmark "$MGMT_FWMARK" \
    peer "$SERVER_KEY" endpoint "$ENDPOINT" allowed-ips 10.240.0.1/32 persistent-keepalive 25
ip link set up dev "$DEVICE"
ip route replace 10.240.0.1/32 dev "$DEVICE"
# These rules are intentionally before Podkop's policy-routing priority (105).
# Delete only matching old rules so repeated hotplug/cron executions are safe.
while ip rule del pref "$MGMT_ENDPOINT_RULE_PRIORITY" to "$ENDPOINT_IP/32" lookup main 2>/dev/null; do :; done
while ip rule del pref "$MGMT_MARK_RULE_PRIORITY" fwmark "$MGMT_FWMARK/0xffffffff" lookup main 2>/dev/null; do :; done
ip rule add pref "$MGMT_ENDPOINT_RULE_PRIORITY" to "$ENDPOINT_IP/32" lookup main
ip rule add pref "$MGMT_MARK_RULE_PRIORITY" fwmark "$MGMT_FWMARK/0xffffffff" lookup main
MGMT_UP
chmod 700 /usr/libexec/void-mgmt-up

cat > /usr/libexec/void-mgmt-heartbeat <<'MGMT_HEARTBEAT'
#!/bin/sh
set -eu
DEVICE_ID="$(cat /etc/void-router/device_id)"
REFRESH_TOKEN="$(cat /etc/void-router/refresh_token)"
ENDPOINT_IP="$(cat /etc/void-router/wg_endpoint_ip)"
# Do not claim a router is online merely because it can reach the internet.
# The liveness signal is sent only after the dedicated management WireGuard
# tunnel has a fresh handshake. --resolve keeps this request on the physical
# WAN endpoint and makes it independent from local DNS and Podkop routing.
NOW="$(date +%s)"
LAST="$(wg show void_mgmt latest-handshakes 2>/dev/null | awk '$2 > 0 { print $2; exit }')"
case "$LAST" in ''|*[!0-9]*) exit 0 ;; esac
[ $((NOW - LAST)) -le 180 ] || exit 0
PAYLOAD="{\"device_id\":\"$DEVICE_ID\",\"refresh_token\":\"$REFRESH_TOKEN\"}"
curl --silent --show-error --fail --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 25 --retry 1 \
    --resolve "routersub.netvoid.ru:443:$ENDPOINT_IP" \
    -H 'Content-Type: application/json' -H 'Cache-Control: no-store' \
    --data-binary "$PAYLOAD" 'https://routersub.netvoid.ru/v1/router/heartbeat' >/dev/null
MGMT_HEARTBEAT
chmod 700 /usr/libexec/void-mgmt-heartbeat

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
    # The owner chooses the local root password themselves. SSH from WAN is
    # explicitly blocked below; support uses the dedicated WireGuard interface
    # and an individual key, never the owner's password.
    uci set "dropbear.$section.PasswordAuth=on"
    uci set "dropbear.$section.RootPasswordAuth=on"
done
uci commit dropbear
(sleep 1; /etc/init.d/dropbear restart) >/dev/null 2>&1 &
printf '%s\n' locked
LOCKDOWN
chmod 700 /usr/libexec/void-router-lockdown

uci -q delete firewall.void_mgmt || true
uci set firewall.void_mgmt=zone
uci set firewall.void_mgmt.name='void_mgmt'
uci add_list firewall.void_mgmt.device='void_mgmt'
uci set firewall.void_mgmt.input='ACCEPT'
uci set firewall.void_mgmt.output='ACCEPT'
uci set firewall.void_mgmt.forward='REJECT'
uci set firewall.void_mgmt.masq='0'
uci -q delete firewall.void_block_wan_ssh || true
uci set firewall.void_block_wan_ssh=rule
uci set firewall.void_block_wan_ssh.name='VOID: deny SSH from WAN'
uci set firewall.void_block_wan_ssh.src='wan'
uci set firewall.void_block_wan_ssh.proto='tcp'
uci set firewall.void_block_wan_ssh.dest_port='22'
uci set firewall.void_block_wan_ssh.target='REJECT'
uci commit firewall
/etc/init.d/firewall restart
/etc/init.d/void-mgmt enable
/usr/libexec/void-mgmt-up

grep -Ev '/usr/bin/void-router-refresh|/usr/libexec/void-mgmt-up|/usr/libexec/void-mgmt-heartbeat' /etc/crontabs/root > "$WORK_DIR/root.cron" || true
printf '*/5 * * * * /usr/libexec/void-mgmt-up >/dev/null 2>&1\n' >> "$WORK_DIR/root.cron"
printf '*/5 * * * * /usr/libexec/void-mgmt-heartbeat >/dev/null 2>&1\n' >> "$WORK_DIR/root.cron"
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
say "SUCCESS: $SUBSCRIPTION_NAME is connected to UROBOROS."
say 'Your existing Podkop and VPN configuration were not changed.'
say 'Management: key-only SSH over a dedicated WireGuard tunnel is active.'
