# Network ranges are intentionally not populated

Games, social networks and AI products in this catalog use shared CDNs and
elastic cloud infrastructure.  Their observed IP ranges are neither stable nor
exclusive to that product.  Routing such ranges would affect unrelated sites
and can make a router less reliable.

Service-specific CIDR ranges now live next to their product, for example
`../social/telegram.cidrs.txt`. Keep a network here only when it cannot belong
to a named service.
