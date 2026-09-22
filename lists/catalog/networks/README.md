# Published, service-scoped network ranges

Games, social networks and AI products in this catalog use shared CDNs and
elastic cloud infrastructure.  Their observed IP ranges are neither stable nor
exclusive to that product.  Routing such ranges would affect unrelated sites
and can make a router less reliable.

Only add a `*.cidr.txt` file here when the provider itself publishes a current,
service-specific CIDR range with a stable documentation URL. Record that URL,
the source's update time, retrieval date, intended product and any required
protocol/port scope in a comment at the top of the file. Never broaden these
prefixes to the surrounding cloud-provider network. Since published ranges can
change, refresh them from the source before release. Otherwise, route by the
matching suffix domains in the adjacent catalogs.

Current files: Telegram publishes its service ranges; OpenAI publishes the
endpoints used by ChatGPT Voice. The OpenAI file is specifically for outbound
UDP destination port 3478, not all OpenAI traffic.
