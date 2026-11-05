#!/bin/sh
# ORBIT-TEMP router installer  (version 1.0.3)  --  temporary management tunnel for NEW OpenWrt 25.12.x routers.
#
# WHAT IT DOES (additive only, nothing else on the router is touched):
#   * asks for the one-time ACTIVATION KEY the admin created in the ORBIT TEMP panel (hidden input, never stored, never on a command line)
#   * installs wireguard-tools + kmod-wireguard with apk (only if missing) BEFORE any configuration is changed
#   * generates the router's WireGuard key pair ON the router (private key stays in /etc/orbit-temp/wg.key, mode 0600; only the public key is sent)
#   * claims the activation key at https://orbit2.netvoid.ru (TLS verified against the router's CA bundle) and receives: router name,
#     management IP, hub endpoint/public key and the hub's SSH management public key
#   * creates ONLY: uci network.orbit_temp + network.orbit_temp_hub (WireGuard, allowed-ips = hub /32), firewall zone 'orbit_temp' with ssh/ping
#     from the hub address only, the hub key (no forwarding options) in /etc/dropbear/authorized_keys, and /etc/orbit-temp/*
#   * waits for the WireGuard handshake and confirms the activation to the hub
# It never touches void_mgmt, rescue, WAN / default route, DNS, WLAN, Forkop/Podkop/sing-box or user VPN configuration.
#
# USAGE (as root, on the router):   sh orbit-temp-install.sh [apply|status|rollback]        (default: apply)
#   apply     install / resume / re-check (idempotent; asks for the activation key only when one is needed)
#   status    show what is installed (no network access to the hub)
#   rollback  remove exactly what 'apply' created (packages stay installed; backups in /etc/orbit-temp/backup-* stay)
# Exit codes: 0 ok | 1 precondition failed / internal | 2 usage | 3 configured but no handshake yet (re-run 'apply') | 4 activation key refused
#             5 rate limited | 6 hub unreachable/unavailable (the key may be claimed: re-run with the SAME key) | 7 TLS verification failed
#             8 hub rejected the confirmation
# Optional tuning (numbers only): ORBIT_TEMP_WAIT_S (handshake wait, default 40), ORBIT_TEMP_RETRY_DELAY (seconds, default 3), ORBIT_TEMP_PROTO_WAIT_S (wait for netifd after its restart, default 60), ORBIT_TEMP_STABLE_S (seconds the tunnel must keep answering before the hub is told 'active', default 20, 0 = off).

case $- in *x*) set +x ;; esac        # never trace: the activation key would show up in the trace
set -u
umask 077

VERSION='1.0.3'
API_BASE='https://orbit2.netvoid.ru'
MGMT_PREFIX='10.241.0.'               # the only management network this installer version accepts
IF='orbit_temp'; PEER='orbit_temp_hub'
STATE_DIR='/etc/orbit-temp'
MARK='orbit-hub-lite-mgmt'            # comment of the hub's SSH key = marker of the line we own in authorized_keys
AK='/etc/dropbear/authorized_keys'
PKGS='wireguard-tools kmod-wireguard'
TMPD=''
CREATED_DIR=0
PHASE=''
KEY=''
WAIT_S="${ORBIT_TEMP_WAIT_S:-40}";        case "$WAIT_S" in ''|*[!0-9]*) WAIT_S=40 ;; esac
RETRY_DELAY="${ORBIT_TEMP_RETRY_DELAY:-3}"; case "$RETRY_DELAY" in ''|*[!0-9]*) RETRY_DELAY=3 ;; esac
PROTO_WAIT_S="${ORBIT_TEMP_PROTO_WAIT_S:-60}"; case "$PROTO_WAIT_S" in ''|*[!0-9]*) PROTO_WAIT_S=60 ;; esac
STABLE_S="${ORBIT_TEMP_STABLE_S:-20}";      case "$STABLE_S" in ''|*[!0-9]*) STABLE_S=20 ;; esac

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { _c=$1; shift; printf 'ABORT: %s\n' "$*" >&2; exit "$_c"; }
LOCKED=0; LOCK=''
cleanup() { KEY=''; [ -n "$TMPD" ] && rm -rf "$TMPD"; [ "$LOCKED" = 1 ] && rm -f "$LOCK"; return 0; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkd() { [ -d "$1" ] || { mkdir -p "$1" && chmod 700 "$1"; }; }   # the busybox of OpenWrt 25.12 has no 'install' applet

# ---------------------------------------------------------------------------------------------------------------- validators
# (every value that comes from the hub is validated before it reaches uci, authorized_keys or a state file)
is_name()   { case "$1" in ''|*[!a-z0-9-]*|-*) return 1 ;; esac; [ "${#1}" -ge 2 ] && [ "${#1}" -le 31 ]; }
is_mgmt_ip() {
  case "$1" in "$MGMT_PREFIX"*) ;; *) return 1 ;; esac
  _o=${1#"$MGMT_PREFIX"}
  case "$_o" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ "${#_o}" -le 3 ] && [ "$_o" -ge 1 ] && [ "$_o" -le 254 ]
}
is_host()   { case "$1" in ''|*[!A-Za-z0-9.-]*|-*|.*) return 1 ;; esac; [ "${#1}" -le 253 ]; }
is_port()   { case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac; [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_wgkey()  { [ "${#1}" -eq 44 ] || return 1; case "$1" in *[!A-Za-z0-9+/=]*) return 1 ;; esac; [ "${1%=}=" = "$1" ] || return 1; case "${1%=}" in *=*) return 1 ;; esac; return 0; }
is_sshblob() { [ "${#1}" -eq 68 ] || return 1; case "$1" in AAAAC3NzaC1lZDI1NTE5AAAAI*) ;; *) return 1 ;; esac; case "$1" in *[!A-Za-z0-9+/]*) return 1 ;; esac; return 0; }
is_token()  { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; [ "${#1}" -ge 32 ] && [ "${#1}" -le 128 ]; }
is_uint()   { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ]; }
san()       { printf '%s' "$1" | tr -cd 'A-Za-z0-9._ :/+-' | cut -c1-64; }

# ---------------------------------------------------------------------------------------------------------------- state file
st_get() { [ -f "$STATE_DIR/state" ] && sed -n "s/^$1=//p" "$STATE_DIR/state" | head -n1; return 0; }
write_state() {   # writes the whole state atomically from the current variables
  mkd "$STATE_DIR"
  {
    printf 'phase=%s\n' "$PHASE"
    printf 'version=%s\n' "$VERSION"
    printf 'wg_public_key=%s\n' "${WGPUB:-}"
    printf 'router_name=%s\n' "${R_NAME:-}"
    printf 'mgmt_ip=%s\n' "${R_IP:-}"
    printf 'hub_endpoint=%s\n' "${R_EP:-}"
    printf 'hub_port=%s\n' "${R_PORT:-}"
    printf 'hub_pubkey=%s\n' "${R_HPUB:-}"
    printf 'hub_address=%s\n' "${R_HADDR:-}"
    printf 'ssh_blob=%s\n' "${R_BLOB:-}"
    printf 'confirm_token=%s\n' "${R_TOK:-}"
    printf 'confirm_within_s=%s\n' "${R_WITHIN:-}"
    printf 'backup=%s\n' "${BK:-}"
    printf 'activated=%s\n' "${ACTIVATED:-}"
  } > "$STATE_DIR/state.new" && mv "$STATE_DIR/state.new" "$STATE_DIR/state" || fail 1 "cannot write $STATE_DIR/state"
  chmod 600 "$STATE_DIR/state"
}
load_state() {
  PHASE=$(st_get phase); WGPUB=$(st_get wg_public_key); R_NAME=$(st_get router_name); R_IP=$(st_get mgmt_ip)
  R_EP=$(st_get hub_endpoint); R_PORT=$(st_get hub_port); R_HPUB=$(st_get hub_pubkey); R_HADDR=$(st_get hub_address)
  R_BLOB=$(st_get ssh_blob); R_TOK=$(st_get confirm_token); R_WITHIN=$(st_get confirm_within_s); BK=$(st_get backup); ACTIVATED=$(st_get activated)
}
validate_claim() {   # validates R_* ; prints the reason and returns 1 on the first problem
  is_name "$R_NAME"        || { say "invalid router_name"; return 1; }
  is_mgmt_ip "$R_IP"       || { say "invalid or foreign mgmt_ip"; return 1; }
  is_mgmt_ip "$R_HADDR"    || { say "invalid or foreign hub address"; return 1; }
  [ "$R_IP" != "$R_HADDR" ] || { say "mgmt_ip equals the hub address"; return 1; }
  is_host "$R_EP"          || { say "invalid hub endpoint"; return 1; }
  is_port "$R_PORT"        || { say "invalid hub port"; return 1; }
  is_wgkey "$R_HPUB"       || { say "invalid hub public key"; return 1; }
  [ "$R_HPUB" != "${WGPUB:-}" ] || { say "hub public key equals the router key"; return 1; }
  is_sshblob "$R_BLOB"     || { say "invalid hub ssh public key"; return 1; }
  is_token "$R_TOK"        || { say "invalid confirm_token"; return 1; }
  is_uint "$R_WITHIN"      || { say "invalid confirm_within_s"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------------------------------------------- status / rollback
wg_hs() { command -v wg >/dev/null 2>&1 || return 0; wg show "$IF" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -n1; }

status() {
  say "== ORBIT-TEMP status (installer $VERSION)"
  if [ -f "$STATE_DIR/state" ]; then
    say "state: phase=$(st_get phase) router=$(st_get router_name) mgmt_ip=$(st_get mgmt_ip) hub=$(st_get hub_endpoint):$(st_get hub_port) activated=$(st_get activated)"
    [ -f "$STATE_DIR/version" ] && say "installed version: $(cat "$STATE_DIR/version")"
  else say 'state: none (not installed or rolled back)'; fi
  if uci -q get network.$IF >/dev/null 2>&1; then say "uci: interface $IF present (address $(uci -q get network.$IF.addresses))"; else say "uci: interface $IF ABSENT"; fi
  if command -v wg >/dev/null 2>&1 && wg show "$IF" >/dev/null 2>&1; then
    wg show "$IF" | grep -E 'public key|endpoint|allowed ips|latest handshake|transfer' | sed 's/^ *//'
  else say 'wireguard: interface not up (yet)'; fi
  _hub=$(st_get hub_address)
  if [ -n "$_hub" ]; then ping -c 2 -W 2 "$_hub" 2>/dev/null | tail -n 2 || say "ping to hub $_hub: no answer"; fi
}

# Give back the ORIGINAL bytes of a config file (comments, formatting) when the uci content is semantically identical to the pre-install backup:
# `uci commit` rewrites a stock file in canonical form (found on hardware: /etc/config/firewall lost its comments). Anything the admin changed meanwhile keeps the uci result.
restore_original_file() {   # restore_original_file NAME
  _bk=$(st_get backup); [ -n "$_bk" ] && [ -f "$_bk/$1" ] || return 0
  _d=$(mktemp -d /tmp/orbit-cmp.XXXXXX) || return 0
  cp "$_bk/$1" "$_d/$1" 2>/dev/null || { rm -rf "$_d"; return 0; }
  _a=$(uci -q -c "$_d" export "$1" 2>/dev/null); _b=$(uci -q export "$1" 2>/dev/null)
  if [ -n "$_a" ] && [ "$_a" = "$_b" ] && ! cmp -s "$_bk/$1" "/etc/config/$1"; then cat "$_bk/$1" > "/etc/config/$1" && say "restored the original /etc/config/$1 byte for byte"; fi
  rm -rf "$_d"
}

rollback() {
  say '== rollback of the ORBIT-TEMP installation (only objects created by this installer)'
  ifdown "$IF" >/dev/null 2>&1 || true      # tear the tunnel down through netifd first: removes the kernel device AND the host route netifd added for the hub endpoint
  for s in network.$IF network.$PEER firewall.orbit_temp_zone firewall.orbit_temp_ssh firewall.orbit_temp_ping dropbear.orbit_temp_ssh; do
    uci -q delete "$s" >/dev/null 2>&1 || true
  done
  uci commit network; uci commit firewall; uci commit dropbear
  for _p in network firewall dropbear; do restore_original_file "$_p"; done
  if [ -f "$AK" ]; then
    _t=$(mktemp /tmp/orbit-ak.XXXXXX) || fail 1 'mktemp failed'
    grep -vF "$MARK" "$AK" > "$_t" || true
    cat "$_t" > "$AK"; rm -f "$_t"; chmod 600 "$AK"
    _bk=$(st_get backup)   # the file did not exist before the installation: do not leave an empty one behind
    if [ ! -s "$AK" ] && [ -n "$_bk" ] && [ ! -f "$_bk/authorized_keys" ]; then rm -f "$AK"; fi
  fi
  _ep=$(st_get hub_endpoint)
  ubus call network reload >/dev/null 2>&1 || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true   # NOT reload: fw4 reload keeps the chains of a removed zone loaded (found on hardware); restart rebuilds the ruleset
  /etc/init.d/dropbear reload >/dev/null 2>&1 || true
  # netifd adds a host route for the tunnel endpoint (host dependency) and leaves it behind when the interface is removed while up (found on hardware, netifd of 25.12.5).
  # It is harmless (same gateway as the default route) but it is a leftover: remove exactly that route, and only if it still points via a gateway and device.
  if [ -n "$_ep" ]; then
    sleep 2
    _r=$(ip -4 route show "$_ep" 2>/dev/null | head -n 1)
    case "$_r" in
      "$_ep via "*" dev "*)
        _gw=$(echo "$_r" | awk '{print $3}'); _dv=$(echo "$_r" | awk '{print $5}')
        ip -4 route del "$_ep" via "$_gw" dev "$_dv" >/dev/null 2>&1 && say "removed the stale host route to the hub endpoint $_ep (left behind by netifd)" ;;
    esac
  fi
  rm -f "$STATE_DIR/state" "$STATE_DIR/state.new" "$STATE_DIR/hub.conf" "$STATE_DIR/version" "$STATE_DIR/wg.key" "$STATE_DIR/wg.key.new"
  rmdir "$STATE_DIR" 2>/dev/null || true
  say "rolled back. wireguard-tools/kmod-wireguard stay installed; backups (if any) stay in $STATE_DIR."
  say 'The hub still lists this router: ask the admin to remove it in the ORBIT TEMP panel (or re-run apply with a new activation key).'
}

# ---------------------------------------------------------------------------------------------------------------- mode dispatch
MODE="${1:-apply}"
[ "$#" -le 1 ] || fail 2 "usage: sh $0 [apply|status|rollback]"
case "$MODE" in
  -h|--help|help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  apply|status|rollback) ;;
  *) fail 2 "unknown mode '$MODE' (apply|status|rollback)" ;;
esac
[ "$(id -u)" = 0 ] || fail 1 'run as root'
command -v uci >/dev/null 2>&1 || fail 1 'this installer is for OpenWrt (uci not found)'
command -v ubus >/dev/null 2>&1 || fail 1 'ubus not found'
[ "$MODE" = status ] && { status; exit 0; }
# one mutating instance at a time (a second one would race on uci and on the one-time key)
LOCK='/tmp/orbit-temp-install.lock'; LOCKED=0
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { exec 9>&-; fail 1 'another orbit-temp-install.sh is already running on this router'; }
  LOCKED=1
fi
[ "$MODE" = rollback ] && { rollback; exit 0; }

# ---------------------------------------------------------------------------------------------------------------- compatibility checks (nothing is changed before all of them pass)
[ -r /etc/openwrt_release ] || fail 1 '/etc/openwrt_release missing: not OpenWrt?'
. /etc/openwrt_release
REL="${DISTRIB_RELEASE:-unknown}"; TARGET="${DISTRIB_TARGET:-}"; ARCH="${DISTRIB_ARCH:-}"
case "$REL" in
  25.12.*) ;;
  25.*) warn "OpenWrt $REL: this installer is tested on 25.12.x only" ;;
  *) fail 1 "unsupported OpenWrt release '$REL' (this installer needs 25.x with apk, fw4 and netifd)" ;;
esac
[ -n "$TARGET" ] && [ -n "$ARCH" ] || fail 1 "DISTRIB_TARGET/DISTRIB_ARCH missing in /etc/openwrt_release"
for t in apk fw4 jsonfilter uclient-fetch mktemp sed awk grep tr cut sort tail head sleep date cp mv rm chmod mkdir wc; do
  command -v "$t" >/dev/null 2>&1 || fail 1 "required tool '$t' not found"
done
[ -d /etc/ssl/certs ] && [ -n "$(ls /etc/ssl/certs 2>/dev/null)" ] || fail 1 'no CA certificates in /etc/ssl/certs (install the ca-bundle package): TLS to the hub cannot be verified'
ip -4 route show default 2>/dev/null | grep -q . || warn 'no IPv4 default route yet: the router needs an Internet uplink to reach the hub'

# ---------------------------------------------------------------------------------------------------------------- existing installation?
load_state
case "$PHASE" in
  ''|pending|claimed|applied|active) ;;
  *) fail 1 "unknown phase '$PHASE' in $STATE_DIR/state: run 'sh $0 rollback' first" ;;
esac
if uci -q get network.$IF >/dev/null 2>&1; then
  _cur=$(uci -q get network.$IF.addresses || true)
  case "$PHASE" in
    claimed|applied|active)
      [ "$_cur" = "$R_IP/32" ] || fail 1 "network.$IF exists with address '$_cur' but this router's ORBIT-TEMP identity is '$R_NAME' ($R_IP). Remove the old setup first:  sh $0 rollback" ;;
    *) fail 1 "network.$IF already exists (address '$_cur') and was not created by this installer. Nothing was changed. To replace it run:  sh $0 rollback   and then apply again" ;;
  esac
elif [ "$PHASE" = active ]; then
  fail 1 "state says active ($R_NAME) but network.$IF is missing. Run  sh $0 rollback  and apply again with a new activation key"
fi

TMPD=$(mktemp -d /tmp/orbit-temp.XXXXXX) || fail 1 'cannot create a temporary directory'
chmod 700 "$TMPD"
REQ="$TMPD/req.json"; RESP="$TMPD/resp.json"; ERR="$TMPD/fetch.err"

# ---------------------------------------------------------------------------------------------------------------- helpers: hub API
# api_post PATH TIMEOUT  -> POSTs $REQ, response body in $RESP. Sets FRC (uclient-fetch exit code) and HTTP (0 = no HTTP answer).
# uclient-fetch discards the body of HTTP errors, so the HTTP status (printed on stderr) is the only signal: 400/403/409/429/5xx.
api_post() {
  rm -f "$RESP" "$ERR"
  uclient-fetch -O "$RESP" --header='Content-Type: application/json' --header='Accept: application/json' \
      --post-file="$REQ" --timeout="$2" "$API_BASE$1" >/dev/null 2>"$ERR"
  FRC=$?
  if [ "$FRC" -eq 0 ]; then HTTP=200
  else HTTP=$(sed -n 's/.*HTTP error \([0-9][0-9]*\).*/\1/p' "$ERR" | tail -n 1); HTTP=${HTTP:-0}; fi
}
fetch_err_tail() { tail -n 3 "$ERR" 2>/dev/null | tr -cd '[:print:]\n' | sed 's/^/    | /'; }
jv() {   # one JSON value as a single line; a value that is multi-line (injection attempt) or an array becomes EMPTY and fails validation
  _jv=$(jsonfilter -i "$RESP" -e "$1" 2>/dev/null)
  case "$_jv" in *"
"*) _jv='' ;; esac
  printf '%s' "$_jv"
}

# ---------------------------------------------------------------------------------------------------------------- activation key (hidden input)
normalize_key() {   # $1 raw input -> KEY in canonical form, or return 1
  _k=$(printf '%s' "$1" | tr -d ' \t\r\n-' | tr 'a-z' 'A-Z')
  case "$_k" in OTK*) _k=${_k#OTK} ;; esac
  case "$_k" in *[!0-9A-HJKMNP-TV-Z]*) return 1 ;; esac
  [ "${#_k}" -eq 25 ] || return 1
  KEY="OTK-$(printf '%s' "$_k" | cut -c1-5)-$(printf '%s' "$_k" | cut -c6-10)-$(printf '%s' "$_k" | cut -c11-15)-$(printf '%s' "$_k" | cut -c16-20)-$(printf '%s' "$_k" | cut -c21-25)"
  return 0
}
read_hidden() {   # reads one line into KEY_RAW without echo; the key is never an argument or an environment variable
  KEY_RAW=''
  if [ -t 0 ] || { [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; }; then
    # busybox ash 'read -s' (verified on OpenWrt 25.12.4: no stty applet exists there); rc 2 = option not supported
    ( read -r -s _probe </dev/null ) >/dev/null 2>&1; _rc=$?
    if [ "$_rc" -eq 2 ]; then
      command -v stty >/dev/null 2>&1 || fail 1 'this shell cannot read hidden input (no read -s, no stty): refusing to show the activation key on screen'
      printf 'Activation key (input hidden): ' >&2
      stty -echo </dev/tty 2>/dev/null || fail 1 'stty -echo failed'
      IFS= read -r KEY_RAW </dev/tty; _rc=$?
      stty echo </dev/tty 2>/dev/null; printf '\n' >&2
      return $_rc
    fi
    if [ -t 0 ]; then
      printf 'Activation key (input hidden): ' >&2
      IFS= read -r -s KEY_RAW; _rc=$?
    else
      printf 'Activation key (input hidden): ' >/dev/tty
      IFS= read -r -s KEY_RAW </dev/tty; _rc=$?
    fi
    printf '\n' >&2
    return $_rc
  fi
  # no terminal at all: the key comes from a pipe/file on stdin (nothing can be echoed)
  IFS= read -r KEY_RAW
}
get_key() {
  _try=0
  while [ "$_try" -lt 3 ]; do
    _try=$((_try+1))
    read_hidden || { KEY_RAW=''; fail 1 'no activation key entered'; }
    if normalize_key "$KEY_RAW"; then KEY_RAW=''; return 0; fi
    KEY_RAW=''
    warn 'that is not a valid activation key (expected OTK- followed by 25 characters, e.g. OTK-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)'
    [ -t 0 ] || [ -r /dev/tty ] || break
  done
  fail 4 'no valid activation key entered. Nothing was changed.'
}

# ---------------------------------------------------------------------------------------------------------------- packages (before any configuration change)
have_wg()   { command -v wg >/dev/null 2>&1 && [ -e /lib/netifd/proto/wireguard.sh ]; }
kernel_wg() { [ -d /sys/module/wireguard ] || { ip link add orbit_probe type wireguard >/dev/null 2>&1 && ip link del orbit_probe >/dev/null 2>&1; }; }
ensure_packages() {
  if have_wg && kernel_wg; then return 0; fi
  say "installing WireGuard components with apk ($PKGS)"
  apk update >"$TMPD/apk.out" 2>&1 || { tail -n 4 "$TMPD/apk.out" | sed 's/^/    | /' >&2; fail 1 'apk update failed (is there an Internet uplink?). Nothing was changed.'; }
  # shellcheck disable=SC2086
  apk add $PKGS >"$TMPD/apk.out" 2>&1 || { tail -n 4 "$TMPD/apk.out" | sed 's/^/    | /' >&2; fail 1 "apk could not install $PKGS. Nothing was changed."; }
  have_wg || fail 1 'wireguard-tools or the netifd wireguard protocol handler is still missing after apk add'
  kernel_wg || { modprobe wireguard 2>/dev/null || true; kernel_wg || fail 1 'the kernel cannot create WireGuard interfaces (kmod-wireguard does not match the running kernel? a reboot may be needed)'; }
}
# netifd reads /lib/netifd/proto/*.sh ONLY when it starts. wireguard-tools installed by apk on a running router puts wireguard.sh there, but netifd does not know it
# (found on a physical Cudy WR3000S, OpenWrt 25.12.5: interface proto "none", NO_DEVICE, no handshake until netifd was restarted). Restart the network service ONCE,
# before anything is configured and before the activation key is used. Skipped when netifd already knows the handler (normal case after a reboot / preinstalled package).
netifd_knows_wg() { ubus call network get_proto_handlers 2>/dev/null | jsonfilter -e '@.wireguard' >/dev/null 2>&1; }
ensure_proto_handler() {
  netifd_knows_wg && return 0
  say 'netifd has not loaded the WireGuard protocol handler yet (the package was installed while the network service was running).'
  say 'Restarting the network service ONCE to load it: LAN, Wi-Fi and WAN reconnect for about 10-20 seconds (an SSH session over LAN normally survives).'
  /etc/init.d/network restart >/dev/null 2>&1 || true
  _w=0
  while [ "$_w" -lt "$PROTO_WAIT_S" ]; do
    netifd_knows_wg && { say 'OK: netifd now knows the WireGuard protocol handler'; sleep 3; return 0; }
    _w=$((_w+1)); sleep 1
  done
  fail 1 'netifd still does not know the WireGuard protocol handler after restarting the network service. Nothing was configured; reboot the router and run the installer again.'
}

# ---------------------------------------------------------------------------------------------------------------- router WireGuard key (generated here, never transmitted)
ensure_wg_key() {
  [ -d "$STATE_DIR" ] || CREATED_DIR=1
  mkd "$STATE_DIR"
  if [ "$PHASE" = pending ] && [ -s "$STATE_DIR/wg.key" ]; then
    say 'reusing the router key of the earlier (interrupted) activation attempt'
  else
    wg genkey > "$STATE_DIR/wg.key.new" 2>/dev/null && [ -s "$STATE_DIR/wg.key.new" ] || { rm -f "$STATE_DIR/wg.key.new"; fail 1 'wg genkey failed'; }
    chmod 600 "$STATE_DIR/wg.key.new"; mv "$STATE_DIR/wg.key.new" "$STATE_DIR/wg.key"
  fi
  chmod 600 "$STATE_DIR/wg.key"
  WGPUB=$(wg pubkey < "$STATE_DIR/wg.key" 2>/dev/null) || fail 1 'wg pubkey failed'
  is_wgkey "$WGPUB" || fail 1 'wg pubkey returned something that is not a WireGuard public key'
  PHASE=pending; R_NAME=''; R_IP=''; R_EP=''; R_PORT=''; R_HPUB=''; R_HADDR=''; R_BLOB=''; R_TOK=''; R_WITHIN=''; BK=''; ACTIVATED=''
  write_state
}
drop_pending() {   # a refused/never-processed activation leaves no trace
  rm -f "$STATE_DIR/wg.key" "$STATE_DIR/wg.key.new" "$STATE_DIR/state" "$STATE_DIR/state.new"
  rmdir "$STATE_DIR" 2>/dev/null     # only succeeds when nothing else lives there
  return 0
}

# ---------------------------------------------------------------------------------------------------------------- activation
device_info() {
  _hn=$(cat /proc/sys/kernel/hostname 2>/dev/null); [ -n "$_hn" ] || _hn=$(uci -q get 'system.@system[0].hostname' 2>/dev/null)
  _bd=$(cat /tmp/sysinfo/board_name 2>/dev/null); [ -n "$_bd" ] || _bd=$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null | head -n 1)
  D_REL=$(san "$REL"); D_TGT=$(san "$TARGET"); D_ARCH=$(san "$ARCH"); D_BOARD=$(san "${_bd:-unknown}"); D_HN=$(san "${_hn:-unknown}")
}
activate() {
  device_info
  printf '{"v":1,"key":"%s","wg_public_key":"%s","device":{"release":"%s","target":"%s","arch":"%s","board":"%s","hostname":"%s","installer":"%s"}}' \
      "$KEY" "$WGPUB" "$D_REL" "$D_TGT" "$D_ARCH" "$D_BOARD" "$D_HN" "$VERSION" > "$REQ" || fail 1 'cannot write the request file'
  KEY=''
  say "contacting the hub at $API_BASE ..."
  _n=0
  while :; do
    _n=$((_n+1))
    api_post /v1/activate 20
    # 4 = network error, 5 = TLS error. A connection that is reset DURING the TLS handshake (flaky uplink, middlebox) also ends as 5, so both are retried;
    # a genuinely untrusted certificate fails the same way every time and ends as exit 7 after the last attempt (nothing was ever sent).
    [ "$FRC" -eq 4 ] || [ "$FRC" -eq 5 ] || break
    [ "$_n" -lt 4 ] || break
    warn "network or TLS error while talking to the hub (attempt $_n/4); retrying in $((RETRY_DELAY*_n)) s"
    sleep "$((RETRY_DELAY*_n))"
  done
  rm -f "$REQ"
  case "$FRC" in
    0) ;;
    5) drop_pending
       fail 7 "TLS verification of $API_BASE failed, so nothing was sent. Check the router clock ('date' must be correct; TLS certificates are time limited), the ca-bundle package, and that no proxy intercepts HTTPS." ;;
    4) fail 6 "the hub is not reachable (network error after 4 attempts). The activation key may already be claimed: run the installer again with the SAME key (the router key is kept: $STATE_DIR/wg.key)." ;;
    8) case "$HTTP" in
         400) drop_pending; fail 4 'the hub rejected the request as malformed (HTTP 400). Update the installer from the panel and try again. Nothing was changed.' ;;
         403) drop_pending; fail 4 'the activation key is not valid: unknown, expired, revoked, already used, or claimed by another device (HTTP 403). Ask the admin for a new key in the ORBIT TEMP panel. Nothing was changed.' ;;
         429) drop_pending; fail 5 'too many attempts, the hub is rate limiting (HTTP 429). Wait several minutes and try again. Nothing was changed.' ;;
         5??) fail 6 "the hub is temporarily unavailable (HTTP $HTTP). The activation key may already be claimed: wait a few minutes and run the installer again with the SAME key." ;;
         *)   drop_pending; fail 6 "unexpected answer from the hub (HTTP $HTTP). Nothing was changed." ;;
       esac ;;
    *) fetch_err_tail; drop_pending; fail 1 "uclient-fetch failed (exit $FRC): HTTPS support missing? (libustream-mbedtls + ca-bundle). Nothing was changed." ;;
  esac
  [ "$(jv '@.v')" = 1 ] || { drop_pending; fail 6 'the hub answered with an unknown protocol version'; }
  R_NAME=$(jv '@.router_name'); R_IP=$(jv '@.mgmt_ip'); R_EP=$(jv '@.hub.endpoint'); R_PORT=$(jv '@.hub.port'); R_HPUB=$(jv '@.hub.public_key')
  R_HADDR=$(jv '@.hub.address'); R_TOK=$(jv '@.confirm_token'); R_WITHIN=$(jv '@.confirm_within_s')
  _ssh=$(jv '@.ssh_public_key')
  # ssh_public_key must be exactly:  ssh-ed25519 <68-char blob> orbit-hub-lite-mgmt   (no options, no extra fields)
  set -f; set -- $_ssh; set +f
  if [ "$#" -eq 3 ] && [ "$1" = ssh-ed25519 ] && [ "$3" = "$MARK" ]; then R_BLOB=$2; else R_BLOB=''; fi
  _why=$(validate_claim) || { drop_pending; fail 6 "the hub's answer failed validation ($_why). Nothing was changed on the router; the activation key may be claimed: ask the admin to issue a new one."; }
  PHASE=claimed
  write_state
  say "activation accepted: router '$R_NAME', management address $R_IP"
}

# ---------------------------------------------------------------------------------------------------------------- configuration (UCI / netifd / firewall4 / dropbear)
apply_config() {
  # conflicts: management address (or hub address) already present on this router
  _used=$(ip -4 addr show 2>/dev/null | grep -E " ($R_IP|$R_HADDR)/" || true)
  if [ -n "$_used" ] && ! ip -4 addr show dev "$IF" 2>/dev/null | grep -q " $R_IP/"; then
    fail 1 "address $R_IP or $R_HADDR is already in use on this router. Nothing was changed on the router (the hub rolls the claim back after $R_WITHIN s); ask the admin for a new key."
  fi
  uci -q get network.void_mgmt >/dev/null 2>&1 && say 'NOTE: network.void_mgmt exists and is left untouched'
  umask 077
  mkd "$STATE_DIR"
  if [ -z "$BK" ] || [ ! -d "$BK" ]; then
    BK="$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S)"; mkd "$BK"
    for f in /etc/config/network /etc/config/firewall /etc/config/dropbear "$AK"; do [ -f "$f" ] && cp -p "$f" "$BK/"; done
    say "backup of the files to be changed: $BK"
  fi
  # one batch: nothing is committed unless every command succeeds
  for s in network.$IF network.$PEER firewall.orbit_temp_zone firewall.orbit_temp_ssh firewall.orbit_temp_ping dropbear.orbit_temp_ssh; do uci -q delete "$s" >/dev/null 2>&1 || true; done
  _b="$TMPD/uci.batch"
  {
    printf 'set network.%s=interface\n' "$IF"
    printf "set network.%s.proto='wireguard'\n" "$IF"
    printf "set network.%s.private_key='%s'\n" "$IF" "$(cat "$STATE_DIR/wg.key")"
    printf "set network.%s.auto='1'\n" "$IF"
    printf "add_list network.%s.addresses='%s/32'\n" "$IF" "$R_IP"
    printf 'set network.%s=wireguard_%s\n' "$PEER" "$IF"
    printf "set network.%s.description='ORBIT temporary management hub'\n" "$PEER"
    printf "set network.%s.public_key='%s'\n" "$PEER" "$R_HPUB"
    printf "set network.%s.endpoint_host='%s'\n" "$PEER" "$R_EP"
    printf "set network.%s.endpoint_port='%s'\n" "$PEER" "$R_PORT"
    printf "add_list network.%s.allowed_ips='%s/32'\n" "$PEER" "$R_HADDR"
    printf "set network.%s.route_allowed_ips='1'\n" "$PEER"
    printf "set network.%s.persistent_keepalive='25'\n" "$PEER"
    printf 'set firewall.orbit_temp_zone=zone\n'
    printf "set firewall.orbit_temp_zone.name='orbit_temp'\n"
    printf "add_list firewall.orbit_temp_zone.network='%s'\n" "$IF"
    printf "set firewall.orbit_temp_zone.input='REJECT'\n"
    printf "set firewall.orbit_temp_zone.output='ACCEPT'\n"
    printf "set firewall.orbit_temp_zone.forward='REJECT'\n"
    printf "set firewall.orbit_temp_zone.masq='0'\n"
    printf 'set firewall.orbit_temp_ssh=rule\n'
    printf "set firewall.orbit_temp_ssh.name='ORBIT-TEMP-SSH'\n"
    printf "set firewall.orbit_temp_ssh.src='orbit_temp'\n"
    printf "set firewall.orbit_temp_ssh.src_ip='%s'\n" "$R_HADDR"
    printf "set firewall.orbit_temp_ssh.proto='tcp'\n"
    printf "set firewall.orbit_temp_ssh.dest_port='22'\n"
    printf "set firewall.orbit_temp_ssh.family='ipv4'\n"
    printf "set firewall.orbit_temp_ssh.target='ACCEPT'\n"
    printf 'set firewall.orbit_temp_ping=rule\n'
    printf "set firewall.orbit_temp_ping.name='ORBIT-TEMP-PING'\n"
    printf "set firewall.orbit_temp_ping.src='orbit_temp'\n"
    printf "set firewall.orbit_temp_ping.src_ip='%s'\n" "$R_HADDR"
    printf "set firewall.orbit_temp_ping.proto='icmp'\n"
    printf "set firewall.orbit_temp_ping.icmp_type='echo-request'\n"
    printf "set firewall.orbit_temp_ping.family='ipv4'\n"
    printf "set firewall.orbit_temp_ping.target='ACCEPT'\n"
    # dropbear: only if the main instance is bound to specific interfaces, add a key-only instance on orbit_temp
    _bound=$(uci -q get 'dropbear.@dropbear[0].Interface' || true)
    if [ -n "$_bound" ] && [ "$_bound" != "$IF" ]; then
      printf 'set dropbear.orbit_temp_ssh=dropbear\n'
      printf "set dropbear.orbit_temp_ssh.Interface='%s'\n" "$IF"
      printf "set dropbear.orbit_temp_ssh.Port='22'\n"
      printf "set dropbear.orbit_temp_ssh.PasswordAuth='off'\n"
      printf "set dropbear.orbit_temp_ssh.RootPasswordAuth='off'\n"
    fi
  } > "$_b"
  if ! uci -q batch < "$_b"; then
    uci -q revert network; uci -q revert firewall; uci -q revert dropbear
    rm -f "$_b"; fail 1 'uci rejected the configuration; nothing was committed'
  fi
  rm -f "$_b"
  # hub management key: our own line is replaced, all other lines stay byte-identical
  mkd /etc/dropbear
  touch "$AK"; chmod 600 "$AK"
  _t="$TMPD/ak.new"
  grep -vF "$MARK" "$AK" > "$_t" || true
  [ -s "$_t" ] && [ "$(tail -c 1 "$_t" | wc -l)" = 0 ] && printf '\n' >> "$_t"
  printf 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 %s %s\n' "$R_BLOB" "$MARK" >> "$_t"
  cat "$_t" > "$AK"; rm -f "$_t"; chmod 600 "$AK"
  uci commit network; uci commit firewall; uci commit dropbear
  printf '%s\n' "$VERSION" > "$STATE_DIR/version"
  printf '%s %s %s %s\n' "$R_NAME" "$R_IP" "$R_EP:$R_PORT" "$R_HPUB" > "$STATE_DIR/hub.conf"
  PHASE=applied
  write_state
  # apply only the delta (no full network restart)
  ubus call network reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
  /etc/init.d/firewall reload >/dev/null 2>&1 || true
  /etc/init.d/dropbear reload >/dev/null 2>&1 || true
  ifup "$IF" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------------------------- verification + confirmation
wait_handshake() {
  _i=0; _max=$(( (WAIT_S + 1) / 2 ))
  while [ "$_i" -le "$_max" ]; do
    _hs=$(wg_hs); case "$_hs" in ''|*[!0-9]*) _hs=0 ;; esac
    [ "$_hs" -gt 0 ] && return 0
    _i=$((_i+1)); [ "$_i" -le "$_max" ] && sleep 2
  done
  return 1
}
confirm() {
  printf '{"v":1,"confirm_token":"%s","wg_public_key":"%s","version":"%s","release":"%s"}' "$R_TOK" "$WGPUB" "$VERSION" "$(san "$REL")" > "$REQ" || fail 1 'cannot write the request file'
  _n=0
  while :; do
    _n=$((_n+1))
    api_post /v1/confirm 20
    if [ "$FRC" -eq 0 ]; then
      if [ "$(jv '@.status')" = active ]; then rm -f "$REQ"; return 0; fi
      rm -f "$REQ"; fail 8 'the hub answered the confirmation with an unexpected body'
    fi
    case "$FRC:$HTTP" in
      8:409) [ "$_n" -lt 12 ] || { rm -f "$REQ"; warn 'the hub does not see the WireGuard handshake yet. The configuration is kept; re-run apply to retry the confirmation.'; exit 3; } ;;
      8:403) rm -f "$REQ"; fail 8 "the hub rejected the confirmation token (it expired or the hub rolled the activation back). Run  sh $0 rollback  and ask the admin for a new activation key." ;;
      4:*|5:*|8:5??) [ "$_n" -lt 6 ] || { rm -f "$REQ"; fail 6 'the hub is not reachable for the confirmation (network or TLS error; if it persists check the router clock). The configuration is kept; run apply again later.'; } ;;
      *) rm -f "$REQ"; fetch_err_tail; fail 8 "unexpected answer to the confirmation (uclient-fetch exit $FRC, HTTP $HTTP)" ;;
    esac
    sleep 5
  done
}
# A handshake alone proves little: found on a physical router that some uplinks let the handshake through and cut the UDP flow a few seconds later.
# Keep pinging the hub for STABLE_S seconds; at least 60 % of the pings must be answered and the LAST one must be answered.
stable_tunnel() {
  [ "$STABLE_S" -gt 0 ] || return 0
  say "checking that the tunnel stays up ($STABLE_S s) ..."
  _n=0; _ok=0; _tail=0; _max=$((STABLE_S / 2)); [ "$_max" -ge 1 ] || _max=1
  while [ "$_n" -lt "$_max" ]; do
    sleep 2; _n=$((_n+1))
    if ping -c 1 -W 1 "$R_HADDR" >/dev/null 2>&1; then _ok=$((_ok+1)); _tail=0; else _tail=$((_tail+1)); fi
  done
  [ "$_ok" -ge $(( (_max * 6 + 9) / 10 )) ] && [ "$_tail" -eq 0 ] && { say "OK: the tunnel stayed up ($_ok/$_max pings answered)"; return 0; }
  warn "only $_ok of $_max pings were answered"; return 1
}
finish() {
  say "waiting for the WireGuard handshake (max $WAIT_S s) ..."
  if ! wait_handshake; then
    warn 'no handshake with the hub yet. The configuration is kept. Likely causes: no Internet uplink at this site, UDP '"$R_PORT"' blocked, wrong clock.'
    warn "Check with:  sh $0 status    and re-run  sh $0 apply  to retry (no new key is needed while the hub still waits for the confirmation)."
    exit 3
  fi
  say 'OK: handshake with the hub established'
  ping -c 2 -W 2 "$R_HADDR" >/dev/null 2>&1 && say "OK: hub $R_HADDR answers ping" || warn "handshake ok but no ping answer from $R_HADDR"
  if ! stable_tunnel; then
    warn "the handshake works but the tunnel does NOT stay up for $STABLE_S s (the hub's answers stop after the first packets). The uplink of this site probably cuts UDP $R_PORT flows to the hub."
    warn 'The configuration is kept; the hub was NOT told that the router is active. Try another uplink/site, or re-run  sh '"$0"'  apply  later (no new key is needed while the hub still waits for the confirmation).'
    exit 3
  fi
  confirm
  PHASE=active; ACTIVATED=$(date -u +%Y-%m-%dT%H:%M:%SZ); R_TOK=''; write_state
  say "OK: router '$R_NAME' is ACTIVE (management address $R_IP, installer $VERSION)."
  say "Admin: use the ORBIT TEMP panel, or on the hub:  orbit-hub-lite ssh $R_NAME"
  say "Remove everything this installer changed with:  sh $0 rollback"
}

# ---------------------------------------------------------------------------------------------------------------- main
case "$PHASE" in
  active)
    say "ORBIT-TEMP is already installed and active for router '$R_NAME' ($R_IP). Nothing to change."
    WAIT_S=6; R_PORT=${R_PORT:-}
    if wait_handshake; then say 'OK: handshake with the hub present'; else warn 'no handshake right now (uplink down?). Run: sh '"$0"' status'; fi
    exit 0 ;;
  claimed|applied)
    say "resuming the interrupted installation of router '$R_NAME' (phase $PHASE): no activation key is needed"
    why=$(validate_claim) || fail 1 "the stored state is invalid ($why). Run  sh $0 rollback  and start again."
    [ -s "$STATE_DIR/wg.key" ] || fail 1 "the router key $STATE_DIR/wg.key is missing. Run  sh $0 rollback  and start again."
    ensure_packages
    ensure_proto_handler
    apply_config
    finish ;;
  *)
    get_key
    ensure_packages
    ensure_proto_handler
    ensure_wg_key
    activate
    apply_config
    finish ;;
esac
exit 0
