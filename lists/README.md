# Shared routing data

This directory contains service data, one master list, individual service
lists and ready-made category groups. The same source lists are package-neutral;
Podkop, Forkop and other consumers must not maintain separate copies.

- `all-services.domains.txt` — one deduplicated union of the previous Full
  list and all catalogued service domains. It is broad candidate data, not an
  automatic router configuration.
- `catalog/<category>/<service>.*` — service-level domain and provider-published
  network source lists.
- `profiles/` — opt-in aggregate domain profiles composed from the catalog.

Lists are UTF-8. Domains and CIDR prefixes remain separate inputs. New list
revisions are not automatically deployed to routers. Start with one specific
service list for diagnosis; use the aggregate only when you intentionally want
the whole service set routed together.
