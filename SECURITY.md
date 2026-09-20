# Security policy

ORBIT has a small but privileged surface: it enrolls an OpenWrt router into a
separate management plane. Report suspected vulnerabilities privately. Do not
use a public GitHub issue for security reports, leaked credentials or
router-specific diagnostics.

## Private reporting

Send a report to [VOID Support](https://t.me/voidsupport_bot). Start the
message with `SECURITY` and include the repository revision or released
bootstrap version you tested.

An actionable report contains:

1. affected component and version or commit;
2. preconditions and minimal reproduction steps;
3. observed result and security impact;
4. a redacted log, request or screenshot only when it adds evidence.

We will acknowledge receipt, assess the report privately and coordinate a fix
or disclosure with the reporter. Do not publish a proof of concept before the
affected deployment has been reviewed.

## Scope

In scope:

- `install.sh` and enrollment-data handling;
- enrollment-code validation and response validation;
- management WireGuard routing, firewall interaction and liveness checks;
- per-router identity isolation and support SSH-key handling;
- accidental disclosure of secrets or router data through this repository.

Out of scope for public testing:

- control-plane availability or denial-of-service testing;
- scanning, accessing or modifying routers you do not own or explicitly
  administer;
- social engineering, credential stuffing or attacks on third-party services;
- customer VPN policies selected in Podkop, Forkop or ZeroBlock.

If an out-of-scope issue appears to expose customer data or management access,
still report it privately. Do not attempt further access.

## Data that must stay private

Never place the following in an issue, commit, discussion, paste service,
screenshot or support message without redacting the live value:

- ORBIT enrollment or update code;
- subscription URL, VLESS/WireGuard configuration or QR code;
- OpenWrt password or `/etc/shadow` material;
- private WireGuard key, support private key, refresh token or API token;
- management address, device identifier paired with a live credential, or full
  router diagnostic archive.

If an enrollment code, refresh token or private key may have leaked, treat it
as compromised. Stop sharing it and report the incident privately so the
corresponding access can be revoked and reissued.

## Safe testing expectations

Only test routers and accounts you own or have explicit permission to test.
Prefer a disposable device or isolated configuration. Keep probes reversible:
do not reset a router, change customer routing, exhaust resources, or create
long-lived support access while demonstrating an issue.

The bootstrap is intentionally constrained to a per-device management path. A
valid report may show that this boundary can be crossed; it must not use that
observation to access unrelated devices or customer traffic.

## Security invariants

| Invariant | Expected property |
| --- | --- |
| Per-device isolation | Enrollment and management material from one router cannot authenticate another router. |
| Outbound management | ORBIT does not require a public WAN management port on the router. |
| Separate traffic planes | Management traffic is not a default path for customer LAN traffic. |
| Owner control | ORBIT does not take ownership of the local OpenWrt password, LuCI or VPN-profile selection. |
| Fail closed | Failed compatibility, enrollment or handshake checks do not silently enable a weaker management mode. |

Reports that demonstrate a violation of an invariant are especially useful.
