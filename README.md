# VOID / ORBIT

Public bootstrap for the **ORBIT management plane** on supported OpenWrt routers.

<p>
  <img alt="OpenWrt 24.10 and 25.x" src="https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.x-00c8a0?style=flat-square&logo=openwrt&logoColor=white">
  <img alt="Management transport WireGuard" src="https://img.shields.io/badge/management-WireGuard-88171a?style=flat-square&logo=wireguard&logoColor=white">
  <img alt="Per-router identity" src="https://img.shields.io/badge/identity-per--router-6657d8?style=flat-square">
  <img alt="No public management port" src="https://img.shields.io/badge/inbound_management-none-24202a?style=flat-square">
</p>

ORBIT enrolls a router into a separate management plane. It is **not** a VPN
installer, a replacement for Podkop/Forkop/ZeroBlock, or a controller for a
customer's home traffic.

## System boundary

| ORBIT owns | ORBIT does not own |
| --- | --- |
| Per-router device identity | Customer VPN subscription or routing policy |
| Outbound WireGuard management tunnel | OpenWrt root password or LuCI access |
| Support SSH key inside the management plane | Podkop, Forkop, sing-box or ZeroBlock configuration |
| Enrollment, liveness and revocation state | General-purpose remote access to a LAN |

The management tunnel and customer traffic are separate paths. ORBIT pins its
WireGuard endpoint to the physical WAN and uses dedicated policy-routing rules,
so a local proxy profile cannot route management traffic through the customer's
VPN by accident.

```text
short-lived enrollment code
          │
          ▼
OpenWrt router ── outbound WireGuard ──► ORBIT control plane
     │                                          │
     └── unique device identity + support key ──┘

customer LAN traffic ──► selected Podkop / Forkop / ZeroBlock policy
```

## Bootstrap contract

`install.sh` is POSIX shell for BusyBox `ash`:

```sh
sh install.sh --enroll-stdin
```

The enrollment code is read from standard input with terminal echo disabled; it
is not accepted through argv or environment variables.

Before changing the router, the bootstrap verifies:

- execution as `root` on OpenWrt 24.10 or 25.x;
- `uci`, a detectable board name, HTTPS connectivity and at least 24 MiB free
  space on `/overlay`;
- a short-lived, single-use enrollment code and control-plane response;
- management address, WireGuard material and the per-device support SSH key.

It then writes management-plane material under `/etc/void-router`, creates
`void_mgmt`, installs a health check and restricts support SSH to the individual
router identity. Invalid enrollment, unsupported hardware or incomplete
provisioning fails closed instead of falling back to a weaker mode.

## Traffic and routing

The bootstrap does not create a customer subscription and does not select a
routing profile. Podkop, Forkop and ZeroBlock remain independent local router
components controlled by the owner.

ORBIT's tunnel carries only enrollment, authenticated liveness and support
management. It is not a transparent gateway and is never a default route for
LAN clients.

## Service lists

| Path | Status | Meaning |
| --- | --- | --- |
| `lists/podkop-full-services.txt` | Active | Conservative service list used by the ORBIT **Full** profile. Releases pin a reviewed revision; a router refresh does not silently consume a moving branch. |
| `lists/catalog/` | Research only | Isolated service candidates. These files are not read by the installer or a router action. |
| `lists/profiles/` | Research only | Future opt-in compositions built from the catalog. They are not enabled automatically. |

The catalog is deliberately **not a claim to contain every service blocked or
degraded in Russia**. There is no stable authoritative set: reachability varies
by ISP, protocol, region, CDN and time. A service enters the catalog only with
scoped domains and evidence; it becomes active only after a router test.
Podkop/Forkop community coverage is not copied into the catalog. See
[`lists/catalog/README.md`](lists/catalog/README.md) and
[`lists/catalog/SOURCES.md`](lists/catalog/SOURCES.md).

## Trust model

- One router has one management identity; keys and enrollment state are never
  shared across the fleet.
- The router initiates the management connection. ORBIT opens no public WAN
  management port.
- This checkout contains no live enrollment code, subscription URL, private
  WireGuard key, support private key, router inventory or control-plane secret.
- The router owner retains the OpenWrt password, LuCI and VPN-profile choices.
- Revocation is scoped to one device identity and does not require changing
  other routers.

## Repository layout

| Path | Purpose |
| --- | --- |
| `install.sh` | Auditable OpenWrt enrollment bootstrap. |
| `lists/` | Pinned active list plus reviewed research catalog. |
| `SECURITY.md` | Vulnerability-reporting and secret-handling policy. |

Operational configuration, customer data and control-plane credentials are not
stored here.

## Release discipline

A production enrollment command is issued by the ORBIT control plane for one
router and one release; copying it between routers is unsupported. Before a
release, changes pass shell syntax checks, list validation and secret review:

```sh
python3 lists/catalog/validate_catalog.py
```

## Security

Do not open a public issue with an activation code, subscription URL, router
configuration, private key, refresh token, management IP or full diagnostic
dump. Use the private process in [SECURITY.md](SECURITY.md).
