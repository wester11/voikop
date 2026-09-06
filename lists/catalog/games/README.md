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

The presence of a list means that the product has distinct, provider-owned
endpoints worth testing.  It does **not** assert a nationwide RKN block or
mean that all game traffic should be forced through VPN.  Server status,
publisher regional policy, anti-cheat, P2P/UDP and local packet loss must be
checked separately.

For Wargaming, this profile is deliberately for the international Wargaming
services, account and in-game store. It is not the Russian Lesta-operated
"Мир танков" service. Route the profile only for a verified store/login
failure; do not turn it into a default full-device game VPN.
