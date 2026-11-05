# ORBIT TEMP - temporary router enrollment (OpenWrt 25.12.x)

Generic, versioned, signed installer that enrolls a **new OpenWrt 25.12.x router** into the temporary ORBIT management hub
over WireGuard. It is meant for a limited period only; the router can be moved to the regular ORBIT management plane later.

This directory contains **no secrets**: no WireGuard or SSH private keys, no activation keys, no credentials. Everything
router-specific (activation key, tunnel address, hub parameters) is issued by the operator's admin panel at install time, and
the WireGuard key pair is generated **on the router** (the private key never leaves it).

## Layout

```
orbit-temp/
  README.md
  v1.0.2/                       current release
    orbit-temp-install.sh       the installer (POSIX sh / busybox ash)
    orbit-temp-install.sh.sig   usign (Ed25519) signature of the installer
    public.key                  usign public key that verifies the signature
    SHA256SUMS                  sha256 of the installer
    release.json                version, sha256, signature, key number
  v1.0.1/                       superseded by v1.0.2
  v1.0.0/                       first release (kept for the record; superseded)
```

## How it is used

The operator opens the admin panel, tab **ORBIT TEMP**, adds a router (name) and receives

1. a one-time **activation key** (shown once, valid for a limited time, usable for exactly one successful activation), and
2. a **two-line command** for the router, e.g. `rm -f ...; { wget ... && wget ... && sha256sum -c - && usign -V ...; } || { ...; false; }`
   followed by `sh /tmp/orbit-install.sh`.

Line 1 downloads the installer and its signature from this repository (pinned to an exact commit), writes the public key and
verifies **both** the SHA-256 and the signature. It is fail-closed: if anything fails, the downloaded file is deleted and nothing
runs. Line 2 starts the installer, which asks for the activation key with hidden input (the key is never part of the command,
the process list or the shell history).

## What the installer does

* checks OpenWrt version/architecture, installs missing packages with `apk` (`wireguard-tools`, `kmod-wireguard`, ...);
* generates a WireGuard key pair on the router, sends only the **public** key plus basic device info to the hub (TLS-verified);
* creates the interface `orbit_temp`, firewall zone `orbit_temp` (SSH/ping from the hub address only) and a key-only management
  login for the hub; backs up every file it touches;
* waits for a real WireGuard handshake, confirms to the hub and prints the result.

It does **not** touch the WAN/default route, DNS, Wi-Fi, other VPN or proxy setups, or any existing management interface.
Re-running is safe (no duplicates).

```
sh /tmp/orbit-install.sh            # apply (default; resumes an interrupted run)
sh /tmp/orbit-install.sh status     # show state
sh /tmp/orbit-install.sh rollback   # remove only what ORBIT TEMP created (objects named orbit_temp*, its key line, its state files)
```

v1.0.2 (found and verified on a physical Cudy WR3000S, OpenWrt 25.12.5): after installing `wireguard-tools` the network service is restarted ONCE so that netifd loads the WireGuard protocol handler (netifd only scans its protocol directory at start; without this the tunnel interface stays down) - LAN/Wi-Fi/WAN reconnect for about 10-20 s, only when the handler is not yet known; `rollback` now tears the interface down through netifd first, rebuilds the firewall (`fw4 restart`; a reload keeps the chains of a removed zone), removes the host route netifd leaves behind and gives back the original bytes of `/etc/config/{network,firewall,dropbear}` when their content is unchanged.

v1.0.1 retries activation and confirmation also on TLS errors (a connection reset during the TLS handshake used to be reported as a certificate failure).

Exit codes: `0` ok, `1` precondition, `2` usage, `3` configured but no handshake yet (re-run), `4` key refused,
`5` rate limited, `6` hub unreachable (re-run with the same key), `7` TLS failure, `8` confirmation rejected.

## Manual verification

```
wget -q -O /tmp/orbit-install.sh      <raw URL of v1.0.2/orbit-temp-install.sh>
wget -q -O /tmp/orbit-install.sh.sig  <raw URL of v1.0.2/orbit-temp-install.sh.sig>
printf '%s\n' 'untrusted comment: ORBIT-TEMP installer signing key 2026-11' 'RWQwd436XR7+J3D8sygjIOeoPrSeKJD8zpKOa5Bv+zTkkd7ANp+KzkF8' > /tmp/orbit-install.pub
echo 'c287853d2e5efcba26447b6c47e0c7019eb032820b039996396febe9c4534973  /tmp/orbit-install.sh' | sha256sum -c -
usign -V -m /tmp/orbit-install.sh -p /tmp/orbit-install.pub
```

The release signing key number is `30778dfa5d1efe27`.
