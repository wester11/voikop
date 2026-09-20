# ZeroBlock upstream snapshot

This directory is an auditable import layer, not an ORBIT routing profile.
Nothing below is consumed by an installer, a router action, or
`podkop-full-services.txt` automatically.

## Layout

- `v1/` is a pinned, complete snapshot of the public ZeroBlock v1 community
  sources: regional, category and service domain lists, plus the IPv4/IPv6
  CIDRs which exist for a v1 service.
- `v1/all.*` is a de-duplicated union for analysis. It must not be enabled as
  one rule: it mixes regional, adult-content, media, social and broad provider
  data.
- `v2/catalog.json` records every category that the current ZeroBlock package
  exposes. Its v2 contents are intentionally not faked or scraped: the API
  requires a verified RouteRich device token.

The current ZeroBlock package uses v2 where its device is verified. It falls
back to the public v1 data from `itdoginfo/allow-domains` otherwise. The v1
snapshot is pinned to commit `24c3137ef5cec388d9964fbe6661c32082a17b9e` and
can be refreshed with:

```sh
python3 lists/upstreams/zeroblock/sync_v1.py
```

## Import policy

`v1` is kept intact so its provenance remains reviewable. It does not make
every entry appropriate for VOID routing. Before any entry is copied into an
active profile, review it against `../../catalog/SOURCES.md`:

1. keep product-owned domains and dedicated endpoints;
2. keep customer-visible services in a named profile;
3. do not activate a regional catch-all list or a shared CDN/CIDR set without
   a specifically scoped router test.

The ZeroBlock AI category was separately compared with the AI profile and the
safe missing provider endpoints were added to `podkop-full-services.txt` in
commit `9a78510`.
