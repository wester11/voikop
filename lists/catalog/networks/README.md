# Network ranges are intentionally not populated

Games, social networks and AI products in this catalog use shared CDNs and
elastic cloud infrastructure.  Their observed IP ranges are neither stable nor
exclusive to that product.  Routing such ranges would affect unrelated sites
and can make a router less reliable.

Only add a `*.cidr.txt` file here when the provider itself publishes a current,
service-specific CIDR range with a stable documentation URL.  Record that URL,
the retrieval date and the intended product in a comment at the top of the
file.  Until then, route by the matching suffix domains in the adjacent
catalogs.
