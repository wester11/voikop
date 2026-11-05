#!/bin/sh
# ORBIT-TEMP router installer  (version 1.0.4)  --  temporary management of NEW OpenWrt 25.12.x routers: WireGuard (primary) + FRP rescue path (backup).
#
# WHAT IT DOES (additive only, nothing else on the router is touched):
#   * asks for the one-time ACTIVATION KEY the admin created in the ORBIT TEMP panel (hidden input, never stored, never on a command line)
#   * installs wireguard-tools + kmod-wireguard with apk (only if missing) BEFORE any configuration is changed
#   * generates the router's WireGuard key pair ON the router (private key stays in /etc/orbit-temp/wg.key, mode 0600; only the public key is sent)
#   * claims the activation key at https://orbit2.netvoid.ru (TLS verified against the router's CA bundle) and receives: router name,
#     management IP, hub endpoint/public key, the hub's SSH management public key and (optional) an FRP identity for the backup path
#   * creates ONLY: uci network.orbit_temp + network.orbit_temp_hub (WireGuard, allowed-ips = hub /32), firewall zone 'orbit_temp' with ssh/ping
#     from the hub address only, the hub key (no forwarding options) in /etc/dropbear/authorized_keys, and /etc/orbit-temp/*
#   * FRP backup path (only when the hub issued an identity and the CPU is aarch64/x86_64): official FRP 0.71.1 client + guard, downloaded from the hub
#     mirror and verified against sha256 values PINNED INSIDE THIS (signed) INSTALLER; a key-only dropbear instance on 127.0.0.1:2022
#     (uci dropbear.orbit_temp_frp); procd service /etc/init.d/orbit-temp-frpc. The router never opens a public port for it.
#   * asks the hub to confirm: the activation counts only when the hub could really log in over SSH (WireGuard and/or FRP)
# It never touches void_mgmt, rescue, WAN / default route, DNS, WLAN, Forkop/Podkop/sing-box or user VPN configuration, and it never changes passwords.
#
# USAGE (as root, on the router):   sh orbit-temp-install.sh [apply|upgrade|status|rollback|rollback-frp]        (default: apply)
#   apply          install / resume / re-check (idempotent; asks for the activation key only when one is needed). On an ACTIVE router with an older
#                  installer version it switches to 'upgrade' by itself.
#   upgrade        ACTIVE router only: add/refresh the FRP backup path with an UPGRADE key (panel: 'Update-Schluessel'); WireGuard, uci objects and
#                  the hub key are not touched
#   status         show what is installed (no network access to the hub)
#   rollback       remove everything this installer created, FRP parts included (packages stay installed; backups in /etc/orbit-temp/backup-* stay)
#   rollback-frp   remove ONLY the FRP parts (service, binaries, config, dropbear.orbit_temp_frp); WireGuard and the rest stay
# Exit codes: 0 ok (also 'DEGRADED / FRP ACTIVE') | 1 precondition failed / internal | 2 usage | 3 installed but no real SSH proof from the hub yet (re-run 'apply')
#             4 key refused | 5 rate limited | 6 hub unreachable/unavailable (the key may be claimed: re-run with the SAME key) | 7 TLS verification failed
#             8 hub rejected the confirmation
# Optional tuning (numbers only): ORBIT_TEMP_WAIT_S (informational WireGuard handshake wait, default 40), ORBIT_TEMP_CONFIRM_WAIT_S (how long a missing SSH proof is retried every
#   5 s, default 90), ORBIT_TEMP_RETRY_DELAY (seconds, default 3), ORBIT_TEMP_PROTO_WAIT_S (wait for netifd after its restart, default 60).
#   ORBIT_TEMP_STABLE_S of earlier versions no longer has any effect: success is decided only by the hub's real SSH proof.

case $- in *x*) set +x ;; esac        # never trace: the activation key would show up in the trace
set -u
umask 077

VERSION='1.0.4'
API_BASE='https://orbit2.netvoid.ru'
MGMT_PREFIX='10.241.0.'               # the only management network this installer version accepts
IF='orbit_temp'; PEER='orbit_temp_hub'
STATE_DIR='/etc/orbit-temp'
MARK='orbit-hub-lite-mgmt'            # comment of the hub's SSH key = marker of the line we own in authorized_keys
AK='/etc/dropbear/authorized_keys'
PKGS='wireguard-tools kmod-wireguard'

# ---- FRP backup path (contract API_V2_FRP.md sections 0, 4, 5)
FRP_RELEASE='0.71.1'                  # frpc client AND hub visitor must be exactly this version
FRP_SERVER='2.26.104.15'              # Rescue VPS2: the only FRP server this installer version accepts (host, TLS serverName)
FRP_PORT='443'
FRP_PROXY='ssh'
FRP_LOCAL_PORT='2022'                 # key-only dropbear instance dropbear.orbit_temp_frp on 127.0.0.1
FRP_LIBDIR='/usr/libexec/orbit-temp'
FRP_ETC="$STATE_DIR/frp"
FRP_INIT='/etc/init.d/orbit-temp-frpc'
FRP_MIRROR="$API_BASE/dl/orbit-temp/frp/$FRP_RELEASE"
# sha256 pins (the mirror is not trusted, this signed installer is). One value per line; each of the five lines below ends with the marker comment (hash sign, space,
# the word PIN): the integrator replaces the placeholders (sha256 of the official frpc 0.71.1 binaries, of the frpc-guard builds and of the Rescue CA PEM file)
# before the release is signed.
FRP_PIN_FRPC_AARCH64='651de3428bdc7f37b4bad76ed3236b221939a989c433cd7daee79d2817519f8b'   # PIN frpc-linux-aarch64
FRP_PIN_FRPC_X86_64='35c6054d4549bbcf2f02875543895fd9e44c2aae2925f61cd8ff5a693703c28b'   # PIN frpc-linux-x86_64
FRP_PIN_GUARD_AARCH64='f8f5b7ccd1188662bb1c579af071bad958b5834fdc705e75cdb001219ab216c8'   # PIN frpc-guard-linux-aarch64
FRP_PIN_GUARD_X86_64='c597f6d2f9dcd66bf6796a10ecb36015420943f7faf3fa48d58bc5c569386845'   # PIN frpc-guard-linux-x86_64
FRP_CA_SHA256='1a33c5a87ddfdc5b440694e8cb9219686fb9b2c8f0b7e2d86db5d098e1f5296a'   # PIN Rescue CA ca.crt (PEM file bytes: LF line ends, ONE trailing newline)

TMPD=''
CREATED_DIR=0
PHASE=''
KEY=''
FRP_STATE=''; FARCH=''
C_MODE=''; C_WG=''; C_FRP=''
KEY_LABEL='Activation key'; KEY_WORD='activation key'
WAIT_S="${ORBIT_TEMP_WAIT_S:-40}";        case "$WAIT_S" in ''|*[!0-9]*) WAIT_S=40 ;; esac
RETRY_DELAY="${ORBIT_TEMP_RETRY_DELAY:-3}"; case "$RETRY_DELAY" in ''|*[!0-9]*) RETRY_DELAY=3 ;; esac
PROTO_WAIT_S="${ORBIT_TEMP_PROTO_WAIT_S:-60}"; case "$PROTO_WAIT_S" in ''|*[!0-9]*) PROTO_WAIT_S=60 ;; esac
CONFIRM_WAIT_S="${ORBIT_TEMP_CONFIRM_WAIT_S:-90}"; case "$CONFIRM_WAIT_S" in ''|*[!0-9]*) CONFIRM_WAIT_S=90 ;; esac

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
# (every value that comes from the hub is validated before it reaches uci, authorized_keys, a state file or the FRP configuration)
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
is_frpuser() { case "$1" in ''|*[!a-z0-9_-]*|-*|_*) return 1 ;; esac; [ "${#1}" -ge 3 ] && [ "${#1}" -le 48 ]; }
is_secret() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; [ "${#1}" -ge 20 ] && [ "${#1}" -le 128 ]; }
is_sha256() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
is_version() { case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac; [ "${#1}" -le 16 ]; }
san()       { printf '%s' "$1" | tr -cd 'A-Za-z0-9._ :/+-' | cut -c1-64; }
# ver_lt A B: true when version A is strictly older than B (numeric dotted versions, missing fields count as 0)
ver_lt() {
  _a=$1; _b=$2; _i=0
  while [ "$_i" -lt 4 ]; do
    _x=${_a%%.*}; _y=${_b%%.*}
    case "$_x" in ''|*[!0-9]*) _x=0 ;; esac
    case "$_y" in ''|*[!0-9]*) _y=0 ;; esac
    [ "$_x" -lt "$_y" ] && return 0
    [ "$_x" -gt "$_y" ] && return 1
    case "$_a" in *.*) _a=${_a#*.} ;; *) _a=0 ;; esac
    case "$_b" in *.*) _b=${_b#*.} ;; *) _b=0 ;; esac
    _i=$((_i+1))
  done
  return 1
}

# ---------------------------------------------------------------------------------------------------------------- state file
st_get() { [ -f "$STATE_DIR/state" ] && sed -n "s/^$1=//p" "$STATE_DIR/state" | head -n1; return 0; }
installed_version() {
  _v=$(st_get version); [ -n "$_v" ] || _v=$(cat "$STATE_DIR/version" 2>/dev/null | head -n1)
  is_version "${_v:-}" || _v=0.0.0
  printf '%s' "$_v"
}
write_state() {   # writes the whole state atomically from the current variables (the FRP identity/credentials are NEVER stored here)
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
    printf 'frp=%s\n' "${FRP_STATE:-}"
  } > "$STATE_DIR/state.new" && mv "$STATE_DIR/state.new" "$STATE_DIR/state" || fail 1 "cannot write $STATE_DIR/state"
  chmod 600 "$STATE_DIR/state"
}
load_state() {
  PHASE=$(st_get phase); WGPUB=$(st_get wg_public_key); R_NAME=$(st_get router_name); R_IP=$(st_get mgmt_ip)
  R_EP=$(st_get hub_endpoint); R_PORT=$(st_get hub_port); R_HPUB=$(st_get hub_pubkey); R_HADDR=$(st_get hub_address)
  R_BLOB=$(st_get ssh_blob); R_TOK=$(st_get confirm_token); R_WITHIN=$(st_get confirm_within_s); BK=$(st_get backup); ACTIVATED=$(st_get activated)
  FRP_STATE=$(st_get frp)
}
validate_identity() {   # validates R_* (without the confirm token); prints the reason and returns 1 on the first problem
  is_name "$R_NAME"        || { say "invalid router_name"; return 1; }
  is_mgmt_ip "$R_IP"       || { say "invalid or foreign mgmt_ip"; return 1; }
  is_mgmt_ip "$R_HADDR"    || { say "invalid or foreign hub address"; return 1; }
  [ "$R_IP" != "$R_HADDR" ] || { say "mgmt_ip equals the hub address"; return 1; }
  is_host "$R_EP"          || { say "invalid hub endpoint"; return 1; }
  is_port "$R_PORT"        || { say "invalid hub port"; return 1; }
  is_wgkey "$R_HPUB"       || { say "invalid hub public key"; return 1; }
  [ "$R_HPUB" != "${WGPUB:-}" ] || { say "hub public key equals the router key"; return 1; }
  is_sshblob "$R_BLOB"     || { say "invalid hub ssh public key"; return 1; }
  return 0
}
validate_claim() {   # identity + confirm token
  validate_identity || return 1
  is_token "$R_TOK"        || { say "invalid confirm_token"; return 1; }
  is_uint "$R_WITHIN"      || { say "invalid confirm_within_s"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------------------------------------------- FRP parts: detection / removal
frp_arch() {   # sets FARCH from the OpenWrt architecture; returns 1 when the FRP client is not available for it
  FARCH=''
  case "${ARCH:-}" in aarch64_*) FARCH=aarch64 ;; x86_64) FARCH=x86_64 ;; *) return 1 ;; esac
  return 0
}
frp_present() {   # is there anything of the FRP backup path on this router?
  [ -e "$FRP_INIT" ] && return 0
  [ -d "$FRP_ETC" ] && return 0
  [ -e "$FRP_LIBDIR/frpc" ] && return 0
  [ -e "$FRP_LIBDIR/frpc-guard" ] && return 0
  [ -n "$(st_get frp)" ] && return 0
  uci -q get dropbear.orbit_temp_frp >/dev/null 2>&1 && return 0
  return 1
}
frp_kill_leftovers() {   # a stopped procd service leaves no process; this only catches orphans of OUR binaries (matched by their full path)
  command -v ps >/dev/null 2>&1 || return 0
  for _p in $(ps w 2>/dev/null | awk -v d="$FRP_LIBDIR/" 'index($0, d "frpc") > 0 { print $1 }'); do
    case "$_p" in ''|*[!0-9]*|"$$") continue ;; esac
    kill "$_p" >/dev/null 2>&1 || true
  done
  return 0
}
frp_remove() {   # removes the FRP files and the procd service (NOT the uci section, NOT the state flag); silent and idempotent
  if [ -e "$FRP_INIT" ]; then
    "$FRP_INIT" stop >/dev/null 2>&1 || true
    "$FRP_INIT" disable >/dev/null 2>&1 || true
  fi
  rm -f "$FRP_INIT" "$FRP_INIT.new" /etc/rc.d/S??orbit-temp-frpc /etc/rc.d/K??orbit-temp-frpc /var/lock/procd_orbit-temp-frpc.lock
  frp_kill_leftovers
  rm -f "$FRP_LIBDIR/frpc" "$FRP_LIBDIR/frpc-guard" "$FRP_LIBDIR/frpc.new" "$FRP_LIBDIR/frpc-guard.new"
  rmdir "$FRP_LIBDIR" 2>/dev/null || true
  rm -rf "$FRP_ETC"
  return 0
}

# ---------------------------------------------------------------------------------------------------------------- status / rollback
wg_hs() { command -v wg >/dev/null 2>&1 || return 0; wg show "$IF" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -n1; }
root_pw_state() {   # empty | locked | set | unknown   (reads /etc/shadow, prints nothing from it)
  [ -r /etc/shadow ] || { printf 'unknown'; return 0; }
  _l=$(awk -F: '$1 == "root" { print "x" $2; exit }' /etc/shadow 2>/dev/null)
  case "$_l" in x) printf 'empty' ;; 'x!'*|'x*'*) printf 'locked' ;; x?*) printf 'set' ;; *) printf 'unknown' ;; esac
}
frp_log_lines() {   # last guard/procd lines of the FRP service; only the guard's fixed event lines and procd messages about the service are shown (no secrets by construction)
  command -v logread >/dev/null 2>&1 || return 0
  logread 2>/dev/null | grep -E '"event":"(ATTEMPT_STARTED|LOGIN_ACCEPTED|CONNECT_FAILED|CONNECT_TIMEOUT|CHILD_EXIT|RETRY_BACKOFF|STOPPED|START_FAILED|PIPE_ERROR)"|orbit-temp-frpc' \
    | tail -n 6 | tr -cd ' -~\n' | cut -c1-200 | sed 's/^/    | /'      # ' -~' = the printable ASCII range (the busybox tr of OpenWrt has no POSIX character classes)
}

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
  # FRP backup path
  if frp_present; then
    _bin=missing; [ -x "$FRP_LIBDIR/frpc" ] && [ -x "$FRP_LIBDIR/frpc-guard" ] && _bin=present
    _cfg=missing; [ -s "$FRP_ETC/frpc.toml" ] && _cfg=present
    _ssh=missing; uci -q get dropbear.orbit_temp_frp >/dev/null 2>&1 && _ssh="present ($(uci -q get dropbear.orbit_temp_frp.Interface):$(uci -q get dropbear.orbit_temp_frp.Port))"
    say "frp: installed-flag=$(st_get frp) release=$FRP_RELEASE binaries=$_bin config=$_cfg ssh-instance(dropbear.orbit_temp_frp)=$_ssh"
    [ -f "$FRP_ETC/frpc.toml.stage" ] && say 'frp: an interrupted FRP installation is staged: re-run apply/upgrade to finish it, or  rollback-frp'
    if [ -x "$FRP_INIT" ]; then
      _en=disabled; "$FRP_INIT" enabled >/dev/null 2>&1 && _en=enabled
      _sv=$("$FRP_INIT" status 2>/dev/null | head -n 1 | tr -cd ' -~' | cut -c1-60)
      say "frpc service (orbit-temp-frpc): ${_sv:-no state reported}, boot start $_en"
    else say 'frpc service (orbit-temp-frpc): init script missing'; fi
    _lg=$(frp_log_lines)
    if [ -n "$_lg" ]; then say 'frpc/guard log (last lines, no secrets):'; say "$_lg"; else say 'frpc/guard log: no lines found (logread empty or not available)'; fi
  else say 'frp: not installed (WireGuard only)'; fi
  case "$(root_pw_state)" in
    empty) say '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
           say 'WARNING: the root account of this router has an EMPTY PASSWORD (anybody who can reach LAN/Wi-Fi telnet, LuCI or console is root).'
           say '         Set one with  passwd  (this installer never changes passwords).'
           say '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' ;;
    set|locked) say 'root password: set (not shown)' ;;
    *) say 'root password: could not be checked' ;;
  esac
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
  say '== rollback of the ORBIT-TEMP installation (only objects created by this installer, FRP parts included)'
  frp_remove       # FRP service first: it must not keep a session to the rescue server while the rest is removed
  ifdown "$IF" >/dev/null 2>&1 || true      # tear the tunnel down through netifd first: removes the kernel device AND the host route netifd added for the hub endpoint
  for s in network.$IF network.$PEER firewall.orbit_temp_zone firewall.orbit_temp_ssh firewall.orbit_temp_ping dropbear.orbit_temp_ssh dropbear.orbit_temp_frp; do
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

rollback_frp() {   # ONLY the FRP parts; idempotent; WireGuard, the other uci objects, authorized_keys and the state (except the frp flag) are not touched
  say '== rollback-frp: removing ONLY the FRP backup path (service, binaries, /etc/orbit-temp/frp, dropbear.orbit_temp_frp); WireGuard and the hub key stay'
  _had=0; frp_present && _had=1
  frp_remove
  if uci -q get dropbear.orbit_temp_frp >/dev/null 2>&1; then
    uci -q delete dropbear.orbit_temp_frp >/dev/null 2>&1 || true
    uci commit dropbear
    /etc/init.d/dropbear reload >/dev/null 2>&1 || true
  fi
  if [ -n "$(st_get frp)" ]; then load_state; FRP_STATE=''; write_state; fi
  if [ "$_had" = 1 ]; then say 'FRP backup path removed. The hub still has the FRP identity assigned: ask the admin if it should be revoked.'; else say 'no FRP parts found: nothing to do'; fi
}

# ---------------------------------------------------------------------------------------------------------------- mode dispatch
MODE="${1:-apply}"
[ "$#" -le 1 ] || fail 2 "usage: sh $0 [apply|upgrade|status|rollback|rollback-frp]"
case "$MODE" in
  -h|--help|help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  apply|upgrade|status|rollback|rollback-frp) ;;
  *) fail 2 "unknown mode '$MODE' (apply|upgrade|status|rollback|rollback-frp)" ;;
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
[ "$MODE" = rollback-frp ] && { rollback_frp; exit 0; }

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
  ''|pending|claimed|applied|upgrading|active) ;;
  *) fail 1 "unknown phase '$PHASE' in $STATE_DIR/state: run 'sh $0 rollback' first" ;;
esac
if [ "$MODE" = upgrade ]; then
  case "$PHASE" in
    active|upgrading) ;;
    *) fail 1 "nothing to upgrade: this router has no ACTIVE ORBIT-TEMP installation (state: '${PHASE:-none}'). A new installation is  sh $0 apply" ;;
  esac
fi
if uci -q get network.$IF >/dev/null 2>&1; then
  _cur=$(uci -q get network.$IF.addresses || true)
  case "$PHASE" in
    claimed|applied|upgrading|active)
      [ "$_cur" = "$R_IP/32" ] || fail 1 "network.$IF exists with address '$_cur' but this router's ORBIT-TEMP identity is '$R_NAME' ($R_IP). Remove the old setup first:  sh $0 rollback" ;;
    *) fail 1 "network.$IF already exists (address '$_cur') and was not created by this installer. Nothing was changed. To replace it run:  sh $0 rollback   and then apply again" ;;
  esac
elif [ "$PHASE" = active ] || [ "$PHASE" = upgrading ]; then
  fail 1 "state says $PHASE ($R_NAME) but network.$IF is missing. Run  sh $0 rollback  and apply again with a new activation key"
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
# api_post_retry PATH TIMEOUT -> like api_post, up to 4 attempts on network/TLS errors (same body, so the hub's answer is idempotent)
api_post_retry() {
  _n=0
  while :; do
    _n=$((_n+1))
    api_post "$1" "$2"
    # 4 = network error, 5 = TLS error. A connection that is reset DURING the TLS handshake (flaky uplink, middlebox) also ends as 5, so both are retried;
    # a genuinely untrusted certificate fails the same way every time and ends as exit 7 after the last attempt (nothing was ever sent).
    [ "$FRC" -eq 4 ] || [ "$FRC" -eq 5 ] || break
    [ "$_n" -lt 4 ] || break
    warn "network or TLS error while talking to the hub (attempt $_n/4); retrying in $((RETRY_DELAY*_n)) s"
    sleep "$((RETRY_DELAY*_n))"
  done
}
fetch_err_tail() { tail -n 3 "$ERR" 2>/dev/null | tr -cd ' -~\n' | sed 's/^/    | /'; }   # printable ASCII only (the busybox tr of OpenWrt has no POSIX character classes)
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
      command -v stty >/dev/null 2>&1 || fail 1 "this shell cannot read hidden input (no read -s, no stty): refusing to show the $KEY_WORD on screen"
      printf '%s (input hidden): ' "$KEY_LABEL" >&2
      stty -echo </dev/tty 2>/dev/null || fail 1 'stty -echo failed'
      IFS= read -r KEY_RAW </dev/tty; _rc=$?
      stty echo </dev/tty 2>/dev/null; printf '\n' >&2
      return $_rc
    fi
    if [ -t 0 ]; then
      printf '%s (input hidden): ' "$KEY_LABEL" >&2
      IFS= read -r -s KEY_RAW; _rc=$?
    else
      printf '%s (input hidden): ' "$KEY_LABEL" >/dev/tty
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
    read_hidden || { KEY_RAW=''; fail 1 "no $KEY_WORD entered"; }
    if normalize_key "$KEY_RAW"; then KEY_RAW=''; return 0; fi
    KEY_RAW=''
    warn "that is not a valid $KEY_WORD (expected OTK- followed by 25 characters, e.g. OTK-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)"
    [ -t 0 ] || [ -r /dev/tty ] || break
  done
  fail 4 "no valid $KEY_WORD entered. Nothing was changed."
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
  PHASE=pending; R_NAME=''; R_IP=''; R_EP=''; R_PORT=''; R_HPUB=''; R_HADDR=''; R_BLOB=''; R_TOK=''; R_WITHIN=''; BK=''; ACTIVATED=''; FRP_STATE=''
  write_state
}
drop_pending() {   # a refused/never-processed activation leaves no trace
  rm -f "$STATE_DIR/wg.key" "$STATE_DIR/wg.key.new" "$STATE_DIR/state" "$STATE_DIR/state.new"
  rmdir "$STATE_DIR" 2>/dev/null     # only succeeds when nothing else lives there
  return 0
}

# ---------------------------------------------------------------------------------------------------------------- FRP backup path: accept (validate + stage), install
frp_skip() {   # the FRP backup is optional: any problem skips it, the WireGuard installation continues
  warn "the FRP backup path is NOT being installed: $*"
  warn "WireGuard-only operation continues. It can be added later with an UPGRADE key (ORBIT TEMP panel: 'Update-Schluessel', then on the router:  sh $0 upgrade)."
}
frp_abort() {   # drop everything that was staged/downloaded in this run (an earlier complete FRP installation is not touched)
  rm -f "$FRP_ETC/frpc.toml.stage" "$FRP_ETC/ca.crt.stage" "$FRP_LIBDIR/frpc.new" "$FRP_LIBDIR/frpc-guard.new"
  rmdir "$FRP_ETC" 2>/dev/null || true
  rmdir "$FRP_LIBDIR" 2>/dev/null || true
  frp_skip "$*"
}
# frp_accept: reads the hub answer in $RESP. When it carries a valid FRP identity the private client configuration is STAGED (0600 / dir 0700) so that an interrupted
# installation can be resumed without the key; nothing becomes active here. The credential and the STCP key live only in shell variables (never exported, never
# in an argument list) and in that one file. Never fails the installation.
frp_accept() {
  _ft=$(jsonfilter -i "$RESP" -t '@.frp' 2>/dev/null)
  if [ "$_ft" != object ]; then
    say 'NOTE: the hub did not issue an FRP identity for this router (frp: null): WireGuard-only operation. The FRP backup path can be added later with an UPGRADE key.'
    return 0
  fi
  frp_arch || { frp_skip "the architecture '$ARCH' is not supported (only aarch64_* and x86_64)"; return 0; }
  command -v sha256sum >/dev/null 2>&1 || { frp_skip "sha256sum is not available"; return 0; }
  [ "$(jv '@.frp.server')" = "$FRP_SERVER" ] && [ "$(jv '@.frp.port')" = "$FRP_PORT" ] || { frp_skip 'the hub named an FRP server other than the rescue server this installer is pinned to'; return 0; }
  [ "$(jv '@.frp.proxy')" = "$FRP_PROXY" ] && [ "$(jv '@.frp.local_port')" = "$FRP_LOCAL_PORT" ] && [ "$(jv '@.frp.release')" = "$FRP_RELEASE" ] \
    || { frp_skip "the hub's FRP parameters (proxy/local_port/release) do not match this installer (ssh / $FRP_LOCAL_PORT / $FRP_RELEASE)"; return 0; }
  _fu=$(jv '@.frp.user'); _fc=$(jv '@.frp.credential'); _fk=$(jv '@.frp.stcp_key'); _fs=$(jv '@.frp.ca_sha256')
  if ! { is_frpuser "$_fu" && is_secret "$_fc" && is_secret "$_fk" && is_sha256 "$_fs"; }; then
    _fc=''; _fk=''; frp_skip 'the FRP identity in the hub answer failed validation'; return 0
  fi
  # the Rescue CA: the PEM text from the answer must hash to the value pinned in this installer AND to the hash the hub announced. The canonical form is LF
  # line ends with exactly ONE trailing newline (jsonfilter / command substitution drop trailing newlines; one is added back).
  _pem=$(jsonfilter -i "$RESP" -e '@.frp.ca_pem' 2>/dev/null)
  if [ "${#_pem}" -lt 100 ] || [ "${#_pem}" -gt 8192 ]; then _fc=''; _fk=''; frp_skip 'the CA certificate in the hub answer has an implausible size'; return 0; fi
  printf '%s\n' "$_pem" > "$TMPD/ca.pem"
  _ch=$(sha256sum "$TMPD/ca.pem" | cut -d' ' -f1)
  if [ "$_ch" != "$FRP_CA_SHA256" ] || [ "$_ch" != "$_fs" ]; then
    _fc=''; _fk=''; frp_skip 'the CA certificate in the hub answer does not match the sha256 pinned in this installer (or the one the hub announced)'; return 0
  fi
  mkd "$STATE_DIR"; mkd "$FRP_ETC"
  cat "$TMPD/ca.pem" > "$FRP_ETC/ca.crt.stage" && chmod 644 "$FRP_ETC/ca.crt.stage" || { _fc=''; _fk=''; frp_abort 'cannot write the CA file'; return 0; }
  {
    printf 'serverAddr = "%s"\n' "$FRP_SERVER"
    printf 'serverPort = %s\n' "$FRP_PORT"
    printf 'user = "%s"\n' "$_fu"
    printf 'loginFailExit = false\n'
    printf 'transport.protocol = "wss"\n'
    printf 'transport.tls.enable = true\n'
    printf 'transport.tls.trustedCaFile = "%s/ca.crt"\n' "$FRP_ETC"
    printf 'transport.tls.serverName = "%s"\n' "$FRP_SERVER"
    printf 'transport.tcpMux = true\n'
    printf 'transport.poolCount = 1\n'
    printf 'transport.heartbeatInterval = 10\n'
    printf 'transport.heartbeatTimeout = 30\n'
    printf 'auth.method = "token"\n'
    printf 'auth.token = ""\n'
    printf 'auth.additionalScopes = ["HeartBeats", "NewWorkConns"]\n'
    printf 'metadatas.credential = "%s"\n' "$_fc"
    printf 'log.to = "console"\n'
    printf 'log.level = "info"\n'
    printf 'log.disablePrintColor = true\n'
    printf '\n[[proxies]]\n'
    printf 'name = "%s"\n' "$FRP_PROXY"
    printf 'type = "stcp"\n'
    printf 'localIP = "127.0.0.1"\n'
    printf 'localPort = %s\n' "$FRP_LOCAL_PORT"
    printf 'secretKey = "%s"\n' "$_fk"
  } > "$FRP_ETC/frpc.toml.stage" || { _fc=''; _fk=''; frp_abort 'cannot write the FRP client configuration'; return 0; }
  chmod 600 "$FRP_ETC/frpc.toml.stage"
  _fc=''; _fk=''; _pem=''
  say "FRP backup path: identity received and staged (config 0600 in $FRP_ETC)"
  return 0
}

frp_fetch() {   # frp_fetch LOCALNAME REMOTENAME PINNED_SHA256 -> $FRP_LIBDIR/LOCALNAME.new (0755) verified against the pin, or return 1 with the file deleted
  _f="$FRP_LIBDIR/$1.new"; _try=0
  while :; do
    _try=$((_try+1)); rm -f "$_f" "$ERR"
    uclient-fetch -O "$_f" --timeout=60 "$FRP_MIRROR/$2" >/dev/null 2>"$ERR"; _rc=$?
    [ "$_rc" -eq 0 ] && break
    if { [ "$_rc" -eq 4 ] || [ "$_rc" -eq 5 ]; } && [ "$_try" -lt 3 ]; then sleep "$((RETRY_DELAY*_try))"; continue; fi
    _h=$(sed -n 's/.*HTTP error \([0-9][0-9]*\).*/\1/p' "$ERR" | tail -n 1)
    rm -f "$_f"; warn "download of $2 from the hub mirror failed (uclient-fetch exit $_rc${_h:+, HTTP $_h})"; return 1
  done
  _got=$(sha256sum "$_f" 2>/dev/null | cut -d' ' -f1)
  if [ "$_got" != "$3" ]; then rm -f "$_f"; warn "$2 does NOT match the sha256 pinned in this installer: the file was deleted and is not used"; return 1; fi
  chmod 755 "$_f"
  return 0
}
frp_write_init() {
  cat > "$FRP_INIT.new" <<'INIT_EOF'
#!/bin/sh /etc/rc.common
# ORBIT-TEMP FRP backup client (created by orbit-temp-install.sh; removed by its 'rollback' / 'rollback-frp'). Independent of WireGuard.
START=95
USE_PROCD=1

start_service() {
	[ -x /usr/libexec/orbit-temp/frpc-guard ] && [ -x /usr/libexec/orbit-temp/frpc ] && [ -s /etc/orbit-temp/frp/frpc.toml ] || return 1
	procd_open_instance
	procd_set_param command /usr/libexec/orbit-temp/frpc-guard -frpc /usr/libexec/orbit-temp/frpc -config /etc/orbit-temp/frp/frpc.toml
	procd_set_param env GOGC=50 GOMAXPROCS=1 GOMEMLIMIT=40MiB
	procd_set_param respawn 3600 5 0
	procd_set_param nice 10
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
INIT_EOF
  [ $? -eq 0 ] || return 1
  chmod 755 "$FRP_INIT.new" && mv "$FRP_INIT.new" "$FRP_INIT"
}
frp_uci() {   # the key-only dropbear instance (own section, deleted exactly by rollback): one uci batch, committed only if every command succeeds
  _b="$TMPD/uci.frp"
  {
    printf 'set dropbear.orbit_temp_frp=dropbear\n'
    printf "set dropbear.orbit_temp_frp.Interface='loopback'\n"
    printf "set dropbear.orbit_temp_frp.Port='%s'\n" "$FRP_LOCAL_PORT"
    printf "set dropbear.orbit_temp_frp.PasswordAuth='off'\n"
    printf "set dropbear.orbit_temp_frp.RootPasswordAuth='off'\n"
  } > "$_b"
  uci -q delete dropbear.orbit_temp_frp >/dev/null 2>&1 || true
  if ! uci -q batch < "$_b"; then uci -q revert dropbear; rm -f "$_b"; return 1; fi
  rm -f "$_b"
  uci commit dropbear
}
frp_port_busy() {   # something else already listens on the FRP SSH port (and it is not our own instance)
  uci -q get dropbear.orbit_temp_frp >/dev/null 2>&1 && return 1
  command -v netstat >/dev/null 2>&1 || return 1
  netstat -ln 2>/dev/null | grep -q "[:.]$FRP_LOCAL_PORT[[:space:]]"
}
# frp_install: runs after the WireGuard configuration (or, in 'upgrade', after the hub answer). Only acts when an identity is staged.
frp_install() {
  [ -f "$FRP_ETC/frpc.toml.stage" ] || return 0
  frp_arch || { frp_abort "the architecture '$ARCH' is not supported"; return 0; }
  [ -s "$FRP_ETC/ca.crt.stage" ] || { frp_abort 'the staged CA file is missing'; return 0; }
  case "$FARCH" in
    aarch64) _pf=$FRP_PIN_FRPC_AARCH64; _pg=$FRP_PIN_GUARD_AARCH64 ;;
    *)       _pf=$FRP_PIN_FRPC_X86_64;  _pg=$FRP_PIN_GUARD_X86_64 ;;
  esac
  if frp_port_busy; then frp_abort "TCP port $FRP_LOCAL_PORT on this router is already in use by another program"; return 0; fi
  say "installing the FRP $FRP_RELEASE backup client ($FARCH): downloading from the hub mirror, verifying against the pinned sha256 ..."
  mkdir -p "$FRP_LIBDIR" && chmod 755 "$FRP_LIBDIR" || { frp_abort "cannot create $FRP_LIBDIR"; return 0; }
  if ! frp_fetch frpc "frpc-linux-$FARCH" "$_pf" || ! frp_fetch frpc-guard "frpc-guard-linux-$FARCH" "$_pg"; then
    frp_abort 'download or sha256 verification of the FRP binaries failed'; return 0
  fi
  if ! { mv "$FRP_LIBDIR/frpc.new" "$FRP_LIBDIR/frpc" && mv "$FRP_LIBDIR/frpc-guard.new" "$FRP_LIBDIR/frpc-guard" \
         && mv "$FRP_ETC/ca.crt.stage" "$FRP_ETC/ca.crt" && mv "$FRP_ETC/frpc.toml.stage" "$FRP_ETC/frpc.toml" && frp_write_init; }; then
    frp_remove; FRP_STATE=''; write_state; frp_skip 'cannot install the FRP files (disk full?)'; return 0
  fi
  if ! frp_uci; then
    frp_remove; FRP_STATE=''; write_state; frp_skip 'uci rejected the dropbear.orbit_temp_frp instance (nothing was committed)'; return 0
  fi
  /etc/init.d/dropbear reload >/dev/null 2>&1 || true
  "$FRP_INIT" enable >/dev/null 2>&1 || warn "could not enable $FRP_INIT at boot"
  "$FRP_INIT" restart >/dev/null 2>&1 || warn "could not start $FRP_INIT (see: logread | grep orbit-temp-frpc)"
  grep -qF "$MARK" "$AK" 2>/dev/null || warn "the hub management key ($MARK) is missing from $AK: the hub cannot log in over the FRP path"
  FRP_STATE=installed
  write_state
  say "OK: FRP backup client installed and started (service orbit-temp-frpc; SSH target 127.0.0.1:$FRP_LOCAL_PORT, key-only). The hub tests the path itself."
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
  api_post_retry /v1/activate 20
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
  frp_accept
  rm -f "$RESP"      # the answer may hold the FRP credential
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
# confirm: the hub decides. It logs in over SSH with its management key (WireGuard and/or FRP) and answers 200 {status:active, mode:primary|degraded, wg, frp}
# only when at least one login really worked; 409 no_ssh otherwise (retried every 5 s for CONFIRM_WAIT_S, then exit 3: nothing is confirmed, the configuration is kept).
confirm() {
  printf '{"v":1,"confirm_token":"%s","wg_public_key":"%s","version":"%s","release":"%s"}' "$R_TOK" "$WGPUB" "$VERSION" "$(san "$REL")" > "$REQ" || fail 1 'cannot write the request file'
  _n=0; _neterr=0; _t0=$(date +%s)
  say "asking the hub for its SSH proof (it logs in over WireGuard and over FRP; this can take up to $CONFIRM_WAIT_S s) ..."
  while :; do
    _n=$((_n+1))
    api_post /v1/confirm 40
    if [ "$FRC" -eq 0 ]; then
      if [ "$(jv '@.status')" = active ]; then
        C_MODE=$(jv '@.mode'); C_WG=$(jv '@.wg'); C_FRP=$(jv '@.frp')
        rm -f "$REQ"
        case "$C_MODE" in
          primary|degraded) ;;
          '') warn 'the hub did not report a transport mode (older hub?): treating the activation as WireGuard primary'; C_MODE=primary ;;
          *) fail 8 'the hub answered the confirmation with an unknown transport mode' ;;
        esac
        return 0
      fi
      rm -f "$REQ"; fail 8 'the hub answered the confirmation with an unexpected body'
    fi
    case "$FRC:$HTTP" in
      8:409)
        _el=$(( $(date +%s) - _t0 ))
        if [ "$_el" -ge "$CONFIRM_WAIT_S" ]; then
          rm -f "$REQ"
          warn "no real SSH proof from the hub after $_el s: it could not log in over WireGuard NOR over FRP (HTTP 409 no_ssh). NOTHING was confirmed; the configuration is kept."
          warn "Check the uplink (UDP $R_PORT for WireGuard, TCP 443 to ${FRP_SERVER} for FRP), the router clock and  sh $0 status ; then re-run  sh $0 apply  (no new key is needed while the hub still waits for the confirmation)."
          exit 3
        fi ;;
      8:403) rm -f "$REQ"; fail 8 "the hub rejected the confirmation token (it expired or the hub rolled the activation back). Run  sh $0 rollback  and ask the admin for a new activation key." ;;
      4:*|5:*|8:5??) _neterr=$((_neterr+1)); [ "$_neterr" -lt 6 ] || { rm -f "$REQ"; fail 6 'the hub is not reachable for the confirmation (network or TLS error; if it persists check the router clock). The configuration is kept; run apply again later.'; } ;;
      *) rm -f "$REQ"; fetch_err_tail; fail 8 "unexpected answer to the confirmation (uclient-fetch exit $FRC, HTTP $HTTP)" ;;
    esac
    [ "$FRC" -eq 8 ] && [ "$HTTP" -eq 409 ] && say "the hub has no SSH proof yet (try $_n); retrying in 5 s ..."
    sleep 5
  done
}
conclude() {   # the hub confirmed: record it and tell the operator
  PHASE=active; [ -n "${ACTIVATED:-}" ] || ACTIVATED=$(date -u +%Y-%m-%dT%H:%M:%SZ); R_TOK=''; write_state
  if [ "$FRP_STATE" = installed ]; then
    if [ "$C_FRP" = true ]; then _fb='verified by the hub'; else _fb='installed, not (yet) verified by the hub'; fi
  else _fb='not installed'; fi
  if [ "$C_MODE" = degraded ]; then
    say "DEGRADED / FRP ACTIVE: router '$R_NAME' is confirmed; the hub reaches it over the FRP rescue path (WSS 443) only."
    say "WireGuard SSH from the hub does not work right now (does the uplink block UDP $R_PORT?  see: sh $0 status). This is not a failure of the installation."
  else
    say "OK: router '$R_NAME' is ACTIVE (WireGuard primary, FRP backup $_fb); management address $R_IP, installer $VERSION."
  fi
  say "Admin: use the ORBIT TEMP panel, or on the hub:  orbit-hub-lite ssh $R_NAME"
  say "Remove everything this installer changed with:  sh $0 rollback      (only the FRP backup:  sh $0 rollback-frp)"
}
finish() {
  say "checking the WireGuard handshake (max $WAIT_S s; informational - the hub's SSH proof decides) ..."
  if wait_handshake; then
    say 'OK: handshake with the hub established'
    ping -c 2 -W 2 "$R_HADDR" >/dev/null 2>&1 && say "OK: hub $R_HADDR answers ping" || warn "handshake ok but no ping answer from $R_HADDR"
  else
    warn 'no WireGuard handshake yet (continuing: the FRP backup path may still give the hub SSH access). Likely causes of a missing handshake: no Internet uplink at this site, UDP '"$R_PORT"' blocked, wrong clock.'
  fi
  confirm
  conclude
}

# ---------------------------------------------------------------------------------------------------------------- upgrade (ACTIVE router: FRP backup path only)
upgrade_request() {
  device_info
  _ov=$(installed_version)
  printf '{"v":1,"key":"%s","wg_public_key":"%s","version":"%s","device":{"release":"%s","target":"%s","arch":"%s","board":"%s","hostname":"%s","installer":"%s"}}' \
      "$KEY" "$WGPUB" "$_ov" "$D_REL" "$D_TGT" "$D_ARCH" "$D_BOARD" "$D_HN" "$VERSION" > "$REQ" || fail 1 'cannot write the request file'
  KEY=''
  say "contacting the hub at $API_BASE (upgrade) ..."
  api_post_retry /v1/upgrade 20
  rm -f "$REQ"
  case "$FRC" in
    0) ;;
    5) fail 7 "TLS verification of $API_BASE failed, so nothing was sent. Check the router clock ('date' must be correct), the ca-bundle package, and that no proxy intercepts HTTPS. Nothing was changed." ;;
    4) fail 6 "the hub is not reachable (network error after 4 attempts). Nothing was changed on the router; run  sh $0 upgrade  again (the same upgrade key still works)." ;;
    8) case "$HTTP" in
         400) fail 4 'the hub rejected the request as malformed (HTTP 400). Update the installer from the panel and try again. Nothing was changed.' ;;
         403) fail 4 'the upgrade key is not valid: unknown, expired, revoked, already used, not an UPGRADE key, or issued for a different router (HTTP 403). Ask the admin for an "Update-Schluessel" for THIS router in the ORBIT TEMP panel. Nothing was changed.' ;;
         429) fail 5 'too many attempts, the hub is rate limiting (HTTP 429). Wait several minutes and try again. Nothing was changed.' ;;
         5??) fail 6 "the hub is temporarily unavailable (HTTP $HTTP). Nothing was changed on the router; wait a few minutes and run  sh $0 upgrade  again with the same key." ;;
         *)   fail 6 "unexpected answer from the hub (HTTP $HTTP). Nothing was changed." ;;
       esac ;;
    *) fetch_err_tail; fail 1 "uclient-fetch failed (exit $FRC): HTTPS support missing? Nothing was changed." ;;
  esac
  [ "$(jv '@.v')" = 1 ] || fail 6 'the hub answered with an unknown protocol version. Nothing was changed.'
  # the answer must be about THIS router: a different identity is never adopted
  if [ "$(jv '@.router_name')" != "$R_NAME" ] || [ "$(jv '@.mgmt_ip')" != "$R_IP" ]; then
    fail 6 "the hub's upgrade answer names a different router identity than this router's ($R_NAME, $R_IP). Nothing was changed."
  fi
  R_TOK=$(jv '@.confirm_token'); R_WITHIN=$(jv '@.confirm_within_s')
  is_token "$R_TOK" && is_uint "$R_WITHIN" || { R_TOK=''; fail 6 "the hub's upgrade answer failed validation (confirm token). Nothing was changed."; }
}
do_upgrade() {
  _why=$(validate_identity) || fail 1 "the stored state is invalid ($_why). Run  sh $0 rollback  and start again."
  [ -s "$STATE_DIR/wg.key" ] || fail 1 "the router key $STATE_DIR/wg.key is missing. Run  sh $0 rollback  and start again."
  if [ "$PHASE" = upgrading ]; then
    say "resuming the interrupted upgrade of router '$R_NAME': no key is needed"
    why=$(validate_claim) || fail 1 "the stored state is invalid ($why). Run  sh $0 rollback  and start again."
  else
    frp_arch || fail 1 "the FRP backup path is not available for the architecture '$ARCH' (only aarch64_* and x86_64): nothing to upgrade. Nothing was changed."
    say "upgrading router '$R_NAME' ($R_IP): adds/refreshes the FRP backup path only; WireGuard, uci objects and the hub key are not touched"
    KEY_LABEL='Upgrade key'; KEY_WORD='upgrade key'
    get_key
    upgrade_request
    PHASE=upgrading; write_state            # the confirm token is stored: an interruption from here on resumes without a key
    frp_accept
    rm -f "$RESP"      # the answer may hold the FRP credential
  fi
  frp_install
  printf '%s\n' "$VERSION" > "$STATE_DIR/version"      # version stamp
  write_state
  confirm
  conclude
}

# ---------------------------------------------------------------------------------------------------------------- main
if [ "$MODE" = upgrade ]; then do_upgrade; exit 0; fi
case "$PHASE" in
  active)
    if ver_lt "$(installed_version)" "$VERSION"; then
      if frp_arch; then
        say "the installed ORBIT-TEMP version ($(installed_version)) is older than this installer ($VERSION): switching to 'upgrade' (adds the FRP backup path; WireGuard stays untouched)"
        do_upgrade; exit 0
      fi
      say "NOTE: the installed version ($(installed_version)) is older than $VERSION, but the FRP backup path is not available for the architecture '$ARCH': nothing to upgrade."
    fi
    say "ORBIT-TEMP is already installed and active for router '$R_NAME' ($R_IP). Nothing to change."
    [ "$FRP_STATE" = installed ] && say 'FRP backup path: installed (details: sh '"$0"' status)'
    WAIT_S=6; R_PORT=${R_PORT:-}
    if wait_handshake; then say 'OK: handshake with the hub present'; else warn 'no handshake right now (uplink down?). Run: sh '"$0"' status'; fi
    exit 0 ;;
  upgrading)
    do_upgrade; exit 0 ;;
  claimed|applied)
    say "resuming the interrupted installation of router '$R_NAME' (phase $PHASE): no activation key is needed"
    why=$(validate_claim) || fail 1 "the stored state is invalid ($why). Run  sh $0 rollback  and start again."
    [ -s "$STATE_DIR/wg.key" ] || fail 1 "the router key $STATE_DIR/wg.key is missing. Run  sh $0 rollback  and start again."
    ensure_packages
    ensure_proto_handler
    apply_config
    frp_install
    finish ;;
  *)
    get_key
    ensure_packages
    ensure_proto_handler
    ensure_wg_key
    activate
    apply_config
    frp_install
    finish ;;
esac
exit 0
