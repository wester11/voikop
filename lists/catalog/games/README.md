# Game profiles: composition instead of one giant route

The files here are intentionally isolated.  A future game profile should join
only the product set and its required shared platform set:

| Product | Compose later with |
| --- | --- |
| Rainbow Six Siege | `ubisoft-connect` + `rainbow-six-siege` |
| Tom Clancy's The Division / The Division 2 | `ubisoft-connect` + `tom-clancys-the-division` |
| VALORANT | `riot-platform` + `valorant` |
| League of Legends / TFT | `riot-platform` + `league-of-legends` |
| Apex Legends / Battlefield | `ea-app` + the matching product list |
| The Sims / NFS / Mass Effect / Dragon Age / SWTOR and other EA games | `ea-app` + the matching product list |
| Wargaming / World of Tanks (EU) | `wargaming` |
| DayZ | `steam` + `dayz` |

The presence of a list means that the product has distinct, provider-owned
endpoints worth testing.  It does **not** assert a nationwide RKN block or
mean that all game traffic should be forced through VPN.  Server status,
publisher regional policy, anti-cheat, P2P/UDP and local packet loss must be
checked separately.

For Wargaming, this profile is deliberately for the international Wargaming
services, account and in-game store. It is not the Russian Lesta-operated
"Мир танков" service. Route the profile only for a verified store/login
failure; do not turn it into a default full-device game VPN.

DayZ has a separate `dayz.ports.txt` reference for an opt-in per-device rule.
The port file documents outbound destination ports; it is not a port-forwarding
recipe and is intentionally not enabled by the catalog itself. Use the domain
profile for launcher/account endpoints and keep gameplay routing scoped to the
affected device.
