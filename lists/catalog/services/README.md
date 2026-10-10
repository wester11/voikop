# Service candidates

These files are inactive routing candidates for media and platform services.
They are not loaded by the installer or applied to any router automatically.

`netflix.domains.txt` is useful for testing regional availability and access
from a Russian ISP. Netflix's own support page currently lists Russia among
the countries where the service is unavailable, so this should remain an
opt-in profile rather than a default route.

`spotify.domains.txt` covers the Spotify web/API and delivery endpoints. The
official availability list currently omits Russia; that is a geo-availability
signal, not proof of DPI blocking. Test the client and account region before
enabling it.

The lists deliberately omit shared cloud/CDN ranges and Netflix DNS-test
hosts. If a client still fails, capture the concrete hostname first and add
only a provider-owned or provider-published exact endpoint.
