# Sources and review method

Last reviewed: 2026-09-20.

The catalog starts from provider-owned suffix domains and is cross-checked
against the maintained `domain-list-community` service datasets.  That project
is a discovery source, not authority for routing policy:

- <https://github.com/v2fly/domain-list-community/tree/master/data>
- Podkop/Forkop upstream regional coverage and the active conservative service
  additions: <https://github.com/itdoginfo/allow-domains>
- ZeroBlock 0.8.5-r31 package feed for RouteRich (used to inspect its current
  v1/v2 community-list contract):
  <https://packages.routerich.ru/24.10/mediatek/filogic/routerich/Packages.gz>
- AI category cross-check, reviewed 2026-09-20:
  <https://iplist.my-handbook.ru/?format=json>. Only provider-owned roots and
  exact service endpoints are imported; shared delivery, analytics and
  third-party domains are deliberately excluded.
- Telegram service domains: <https://github.com/itdoginfo/allow-domains/blob/main/Services/telegram.lst>
- Telegram service CIDRs: <https://core.telegram.org/resources/cidr.txt>
- Microsoft Store endpoint requirements: <https://learn.microsoft.com/en-us/intune/fundamentals/endpoints>
- Ubisoft connectivity help: <https://www.ubisoft.com/en-us/help/connectivity-and-performance>
- The Division status: <https://www.ubisoft.com/en-us/game/the-division/the-division-2/status>
- Dead by Daylight support: <https://support.deadbydaylight.com/hc/en-us>
- Behaviour Interactive support: <https://www.bhvr.com/contact-us-2/>
- Darktide Russian connectivity notice: <https://support.fatshark.se/hc/en-us/articles/28867379991069-Playing-From-Russia-and-Experiencing-Errors-on-Loading-in-to-the-Mourningstar>
- Mortal Kombat 1 Russia/Belarus availability: <https://mortalkombatgamessupport.wbgames.com/hc/en-us/articles/20811633624851-Mortal-Kombat-1-Russia-and-Belarus-Release-Clarification>
- Cloudflare Russia network interference report: <https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/>
- Riot connection support: <https://support.riotgames.com/hc/en-us/categories/115001239008-Technical-Help>
- EA server status: <https://help.ea.com/en/server-status/>
- EA regional availability: <https://help.ea.com/ru/articles/orders-and-rewards/unavailable-ea-games/>
- EA provider/domain discovery set: <https://github.com/v2fly/domain-list-community/blob/master/data/ea>
- Bungie network guide: <https://help.bungie.net/hc/en-us/articles/360049496531-Network-Troubleshooting-Guide>
- Steam required ports: <https://help.steampowered.com/en/faqs/view/2EA8-4D75-DA21-31EB>
- DayZ server/query port guidance: <https://forums.dayz.com/topic/243927-server-not-showing-in-server-browser/>
- Netflix regional availability: <https://help.netflix.com/ru/node/14164>
- Spotify regional availability: <https://support.spotify.com/li/article/where-spotify-is-available/>
- Spotify provider domains and exact delivery hosts: <https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/spotify>
- Pirate Face service root, verified from a Russian router: <https://pirateface.co/>
- Netflix provider domains and exact delivery host: <https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/netflix>
- Wargaming Russia/Belarus business transition: <https://wargaming.com/en/news/business-operations-worldwide/>
- Wargaming account-transfer FAQ: <https://worldoftanks.eu/en/content/account-transfer-faq/>
- Wargaming store-route verification: internal Russian-router test, 2026-08-30.
- Dead by Daylight client endpoint: <https://forums.bhvr.com/dead-by-daylight/discussion/363400/does-anyone-know-where-to-find-a-api-documentation-for-bhvrdbd-com>
- Epic Games provider and exact CDN endpoints: <https://github.com/v2ray/domain-list-community/blob/master/data/epicgames>
- Script Hook V official distribution page: <https://www.dev-c.com/gtav/scripthookv/>
- Rockstar Games provider and exact CDN endpoints: <https://github.com/v2fly/domain-list-community/blob/master/data/rockstar>
- Blizzard and Battle.net exact delivery endpoints: <https://github.com/v2fly/domain-list-community/blob/master/data/blizzard>
- Ubisoft Connect exact delivery and cloud-save endpoints: <https://github.com/v2fly/domain-list-community/blob/master/data/ubisoft>

For every future change:

1. Prefer a provider-owned root or a provider-published exact endpoint.
2. Check it is not already in `../podkop-full-services.txt` and does not
   belong to an existing Podkop/Forkop community category.
3. Do not copy shared Akamai, AWS, CloudFront, Azure, Fastly, Cloudflare,
   shared-hosting or other provider CIDRs into a service list. Use a verified
   provider-owned domain instead, unless the service publishes a dedicated
   service-scoped network range.
4. Test a proposed profile against the relevant app, launcher and web login on
   a disposable router configuration before enabling it for customers.
