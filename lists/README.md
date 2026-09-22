# Shared routing data

This directory contains package-neutral service data and profiles. Package
specific outputs belong in adapters: Podkop, Forkop and ZeroBlock should not
each maintain divergent copies of the same service lists.

- `common/full-services.domains.txt` — conservative shared aggregate used by
  the current ORBIT Full profile.
- `podkop-full-services.txt` — compatibility export for already-pinned ORBIT
  installers. It must stay byte-for-byte equivalent to the common source until
  those consumers migrate to the package-neutral path.
- `catalog/<category>/<service>.*` — service-level domain and provider-published
  network source lists.
- `profiles/` — opt-in aggregate domain profiles composed from the catalog.
- `upstreams/zeroblock/` — pinned upstream ZeroBlock snapshots and conversion
  tooling. These snapshots are source material, not proof that ORBIT ZeroBlock
  currently consumes domain profiles.

Lists are UTF-8. Domains and CIDR prefixes remain separate inputs. New list
revisions are not automatically deployed to routers; ORBIT releases pin
reviewed immutable revisions.
