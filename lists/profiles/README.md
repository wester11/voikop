# VOIKOP profiles and delivery

The plain lists in this directory are reviewed compositions of isolated
catalog sets. They are intentionally outside `catalog/`: a catalog entry stays
small and specific, while a profile may combine several entries.

`ai-all.domains.txt` is a profile for AI web applications, accounts and APIs.
It is review material only and is not enabled on a router automatically.

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

Do not add CDN or cloud-provider CIDRs to any of these lists. Service domains
follow DNS changes; shared IP ranges can accidentally route unrelated websites
and devices.
