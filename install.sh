#!/bin/sh
# VOID Router bootstrap. POSIX / BusyBox ash only.
# Public code: this file never contains a subscription URL, token or key.

set -eu
umask 077

API_ORIGIN='https://routersub.netvoid.ru'
API_PATH='/v1/router/bootstrap'
MIN_FREE_KB=24576

say() { printf '%s\n' "[VOID] $*"; }
die() { printf '%s\n' "[VOID] ERROR: $*" >&2; exit 1; }

cleanup() {
    ACTIVATION_CODE=''
    unset ACTIVATION_CODE 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" = '0' ] || die 'Run as root.'
[ -r /etc/openwrt_release ] || die 'This installer supports OpenWrt only.'
command -v curl >/dev/null 2>&1 || die 'curl is required.'
command -v uci >/dev/null 2>&1 || die 'uci is required.'

RELEASE="$(. /etc/openwrt_release; printf '%s' "${DISTRIB_RELEASE:-}")"
case "$RELEASE" in
    24.10.*|25.*) ;;
    *) die "Unsupported OpenWrt release: ${RELEASE:-unknown}" ;;
esac

FREE_KB="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 {print $4}')"
case "$FREE_KB" in ''|*[!0-9]*) die 'Cannot determine free space on /overlay.' ;; esac
[ "$FREE_KB" -ge "$MIN_FREE_KB" ] || die "At least ${MIN_FREE_KB} KiB free space is required."

BOARD_JSON="$(ubus call system board 2>/dev/null || printf '{}')"
if command -v jsonfilter >/dev/null 2>&1; then
    BOARD="$(printf '%s' "$BOARD_JSON" | jsonfilter -e '@.board_name' 2>/dev/null || true)"
    MODEL="$(printf '%s' "$BOARD_JSON" | jsonfilter -e '@.model' 2>/dev/null || true)"
else
    BOARD=''
    MODEL=''
fi
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

PAYLOAD="$(printf '{\"code\":\"%s\",\"board\":\"%s\",\"model\":\"%s\",\"openwrt\":\"%s\"}' \
    "$ACTIVATION_CODE" "$BOARD" "$MODEL" "$RELEASE")"
RESPONSE_FILE="$(mktemp /tmp/void-bootstrap.XXXXXX)"
trap 'rm -f "$RESPONSE_FILE"; cleanup' EXIT HUP INT TERM

say 'Checking the activation code and router compatibility…'
HTTP_CODE="$(printf '%s' "$PAYLOAD" | curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 45 --retry 1 \
    -H 'Content-Type: application/json' -H 'Cache-Control: no-store' \
    --data-binary @- -o "$RESPONSE_FILE" -w '%{http_code}' \
    "${API_ORIGIN}${API_PATH}" 2>/dev/null || true)"

# The response is intentionally not interpreted until a signed, versioned
# configuration format is deployed. A failed/unknown response never changes
# router state or consumes the code a second time client-side.
case "$HTTP_CODE" in
    200) die 'Server response format is not enabled yet; no router changes were made.' ;;
    401|403|404) die 'Activation code is invalid, expired or already used.' ;;
    409) die 'This router requires a manual compatibility review.' ;;
    *) die 'Cannot reach the provisioning service. No changes were made.' ;;
esac
