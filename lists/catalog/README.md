# VOIKOP service catalog

This directory is an **inactive research catalog**.  Nothing below is read by
`install.sh`, Podkop, Forkop, ZeroBlock, or any router action.  Adding a file
here cannot change a user's routing.

Each `*.domains.txt` file is a suffix-domain set for one product or one shared
platform.  It is deliberately split by service so a future profile can compose
only the required sets (for example, `ubisoft-connect` plus
`rainbow-six-siege`) rather than turning every game and service into one large
route.

## Safety rules

- Entries are provider-owned domains or specific, observed provider CDN
  hostnames only. Exact CDN names such as a game's own
  `download.example.akamaized.net` endpoint are allowed when a source ties
  them to that game; they are not the same thing as routing all of Akamai.
- Do not add broad CDN, cloud, hosting, search, or IP-address ranges just
  because a service happens to use one today. Those networks are shared and
  change often.
- `networks/` contains only provider-published, service-scoped CIDR ranges.
  Telegram is currently the sole entry with an official CIDR document; shared
  CDN ranges remain excluded. A domain route can follow DNS changes; hard-coded
  CDN ranges cannot.
- The catalog must not duplicate the currently active
  `../podkop-full-services.txt` list. It intentionally excludes the existing
  Podkop/Forkop community categories except for the explicitly documented
  Telegram catalog entry: YouTube, Meta,
  Discord, X/Twitter, TikTok, Google AI, Google Play, Roblox, Cloudflare,
  CloudFront, DigitalOcean, Hetzner, OVH, and the regional lists.
- An entry is not a claim that a service is officially blocked in Russia.  It
  is a routing candidate for a reported connectivity problem and must be
  tested with that service before it is ever enabled.

## Layout

- `games/` — launcher, publisher, game and platform endpoint sets.
- `games/profiles.json` — routing profile registry.  It records a product's
  status, likely cause, required shared components and evidence level without
  enabling anything on a router.
- `social/` — social networks and messengers not already routed by the current
  profiles.
- `ai/` — AI products not already in the active full-services list.
- `services/` — narrowly scoped productivity, media and platform endpoints.
- `networks/` — policy for future published, service-specific network ranges.
- `SOURCES.md` — provenance and review method.

`../profiles/games-all.domains.txt` is a generated, future-use composition of
every catalogued game endpoint, including the exact CDN hostnames listed above.
It deliberately is not a default route: a single game profile is usually a
better choice for latency and troubleshooting.

Run `python validate_catalog.py` before any future integration.  It rejects
duplicates inside a list, malformed domains, and overlaps with the active
VOIKOP full-services list.

## Game-profile states

- `CONFIRMED` — a first-party publisher has documented the Russian access
  problem and a routing workaround can be tested.
- `EXTERNAL_GEO` — availability is restricted by the publisher, not presented
  as an RKN block.
- `INTERMITTENT` — known connectivity reports or a distinct service status,
  but no safe default route yet.
- `WATCHLIST` — candidate reported by users or a specialist blocklist; needs
  first-party endpoints and a Russian-network capture before use.
- `EXISTING_COMMUNITY_LIST` — intentionally not duplicated here because
  Podkop/Forkop already owns the category (for example Roblox).
