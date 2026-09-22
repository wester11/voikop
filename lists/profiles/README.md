# VOIKOP profiles and delivery

The plain lists in this directory are reviewed compositions of isolated
catalog sets. They are intentionally outside `catalog/`: a catalog entry stays
small and specific, while a profile may combine several entries.

There are three opt-in, future-use profiles rather than a long menu of tiny
ones:

- `ai-all.domains.txt` — generated union of one-file-per-product sets in
  `../catalog/ai/`: ChatGPT, Claude, Gemini and the other reviewed AI
  services, accounts, APIs and exact delivery hostnames.
- `games-all.domains.txt` — game launchers, publishers, account services,
  games and their exact documented CDN hostnames.
- `work-and-privacy.domains.txt` — work tools, code platforms, collaboration,
  private mail/VPN services and selected software delivery endpoints.

They are review material only and are not enabled on a router automatically.
`profiles.json` is the small registry a future ORBIT interface can use instead
of hard-coding those profile names.

Use a broad profile as a future opt-in route or as a starting point for a
smaller service-specific route. For games, the matching single-game profile is
usually the best first choice for latency and troubleshooting.

## What receives the active full-services list

`../all-services.domains.txt` is the broad, package-neutral aggregate of the
previous ORBIT Full list plus every catalogued service domain. It is not
automatically enabled on a router. ORBIT releases pin reviewed immutable
revisions; updating this repository alone does not change deployed routers.

ZeroBlock works differently: its **Full** profile routes the selected local
network as a whole and does not read per-service domain lists. Adding a domain
here cannot change ZeroBlock behaviour. A domain-based ZeroBlock profile would
need its own implementation and router test before it can be offered.

Exact service CDN hostnames belong in the relevant service list. Do not add
CDN or cloud-provider CIDRs: service domains follow DNS changes, while shared
IP ranges can accidentally route unrelated websites and devices.
