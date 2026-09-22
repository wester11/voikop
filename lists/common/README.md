# Shared service lists

Service lists are package-neutral source data. Podkop, Forkop and other
consumers should use adapters to generate their own configuration format
instead of maintaining package-specific copies of the same domains.

`full-services.domains.txt` is the reviewed aggregate currently consumed by
the ORBIT Full profile. ORBIT release metadata pins an immutable revision;
changing this file alone does not update deployed routers.

Individual service source lists live under `../catalog/`. A service list may
overlap this aggregate intentionally. Keep provider-published CIDRs separate
from domain lists and honor any protocol/port scope documented in the CIDR
file.
