# Sources and review method

Last reviewed: 2026-09-06.

The catalog starts from provider-owned suffix domains and is cross-checked
against the maintained `domain-list-community` service datasets.  That project
is a discovery source, not authority for routing policy:

- <https://github.com/v2fly/domain-list-community/tree/master/data>
- Podkop/Forkop upstream regional coverage and the active conservative service
  additions: <https://github.com/itdoginfo/allow-domains>
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
- Wargaming Russia/Belarus business transition: <https://wargaming.com/en/news/business-operations-worldwide/>
- Wargaming account-transfer FAQ: <https://worldoftanks.eu/en/content/account-transfer-faq/>
- Wargaming store-route verification: internal Russian-router test, 2026-08-30.
- Dead by Daylight client endpoint: <https://forums.bhvr.com/dead-by-daylight/discussion/363400/does-anyone-know-where-to-find-a-api-documentation-for-bhvrdbd-com>
- Epic Games provider and exact CDN endpoints: <https://github.com/v2ray/domain-list-community/blob/master/data/epicgames>

For every future change:

1. Prefer a provider-owned root or a provider-published exact endpoint.
2. Check it is not already in `../podkop-full-services.txt` and does not
   belong to an existing Podkop/Forkop community category.
3. Do not copy shared Akamai, AWS, CloudFront, Azure, Fastly, Cloudflare or
   other CDN CIDRs into a service list.
4. Test a proposed profile against the relevant app, launcher and web login on
   a disposable router configuration before enabling it for customers.
