# Profile workflow

`profiles.json` is the source of truth for the candidate game profiles.  A
profile may depend on shared launcher or publisher components, while keeping
its own product-specific domains separate.

For review only, print a composed list with:

```text
python compile_game_profile.py the-division-2
```

That output combines `ubisoft-connect` and `the-division-2` in stable order.
It does not install, sync, upload or configure anything.

Before a profile can enter an ORBIT/Forkop/Podkop flow, it needs:

1. A current first-party source or reproducible Russian-network evidence.
2. A capture of the app's required DNS, TCP and UDP endpoints.
3. A test on a disposable router configuration and a rollback test.
4. A decision whether the product belongs in `CONFIRMED`, `INTERMITTENT`, or
   remains `WATCHLIST`.

Do not add an `ips.txt` merely from a one-off DNS lookup.  Shared cloud/CDN
addresses are not service-specific.  Add IP ranges only when the provider
publishes them as a stable, product-scoped range and record that source.
