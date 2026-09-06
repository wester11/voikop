# VOIKOP profiles and delivery

The plain lists in this directory are reviewed compositions of isolated
catalog sets. They are intentionally outside `catalog/`: a catalog entry stays
small and specific, while a profile may combine several entries.

There are three opt-in, future-use profiles rather than a long menu of tiny
ones:

- `ai-all.domains.txt` — AI web applications, accounts, APIs and their exact
  delivery hostnames.
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

`../podkop-full-services.txt` is the active, conservative list for the ORBIT
**Full** profile. Podkop downloads it through `remote_domain_lists`; Forkop
downloads the same file through `domain_ip_lists`. Each ORBIT release pins an
immutable revision of this file, so a new list revision becomes available only
after that release pin is advanced and deployed; a router refresh never
silently changes the reviewed revision.

ZeroBlock works differently: its **Full** profile routes the selected local
network as a whole and does not read per-service domain lists. Adding a domain
here cannot change ZeroBlock behaviour. A domain-based ZeroBlock profile would
need its own implementation and router test before it can be offered.

Exact service CDN hostnames belong in the relevant service list. Do not add
CDN or cloud-provider CIDRs: service domains follow DNS changes, while shared
IP ranges can accidentally route unrelated websites and devices.
