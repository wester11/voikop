# Remnawave Node: локальный TLS bootstrap

Отдельный установщик подготавливает TLS на уже созданной Remnawave Node. Он запускается **на самой Node** и не меняет Panel, Config Profile, базу данных Remnawave или корневой `install.sh` проекта ORBIT.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/wester11/voikop/main/tools/remnawave-node-tls-setup.sh)
```

Поддерживаются Debian и Ubuntu с Docker Compose plugin. Скрипт использует интерактивный терминал через `/dev/tty`; при первоначальной настройке спрашивает домен этой Node и email Let's Encrypt, а при отсутствующем Nginx отдельно просит ввести `APPLY` перед установкой пакета. Безопасное состояние ограничено `/etc/remna-node-bootstrap.conf` и содержит только `DOMAIN` и `WEB_ROOT`.

Меню установщика на русском:

- `[1] Проверить и исправить` — диагностика с возможным изменением файлов, reload Nginx и изменением контейнера Remnanode; при пересоздании/перезапуске VPN-соединения могут оборваться.
- `[2] Перевыпустить сертификат` — принудительный выпуск через Certbot; сертификат меняется, Nginx может перезагрузиться, а Remnanode может перезапуститься, если Xray/HY2 явно использует этот сертификат.
- `[3] Показать статус TLS / Selfsteal` — только чтение: сетевые проверки без изменения файлов и перезапуска сервисов.
- `[4] Шаблоны профилей Remnawave` — только чтение: безопасные примеры Config Profile.
- `[T] Транспорты` — открывает отдельный менеджер статуса и подготовки обезличенных транспортных кандидатов; он не меняет активный профиль.
- `[H] Подробная справка` — только чтение; показывает назначение, риски, файлы и откат для каждого пункта.
- `[5] Выход`.

Перед пунктами 1 и 2 установщик отдельно перечисляет возможные изменения и ждёт явный ответ `ДА`; пустой ввод отменяет действие. Пункт 3 проверяет HTTPS-заглушку и готовность локальных backend-ов, но не выполняет REALITY/VLESS/HY2 handshake и не доказывает передачу VPN-трафика. Результаты помечаются `PASS`, `FAIL`, `WARNING` или `NOT TESTED`.

## Менеджер транспортов

Менеджер открывается клавишей `T`. Он разделяет конфигурацию сервера, настройки клиента и активацию в Remnawave Panel.

| Действие | Результат | Изменения и риск |
|---|---|---|
| Статус транспортов | Читает только runtime JSON, доступность HTTPS target и локальные версии, если их можно определить | Не меняет файлы или сервисы. `ACTIVE` значит inbound найден в конфигурации; это не доказывает listener, handshake или пользовательский трафик. |
| Подготовить inbound-кандидат | Сохраняет новый каталог с обезличенным inbound JSON, клиентским Xray JSON для поддерживаемых вариантов и README | Запись только в `/var/lib/remna-node-transport-manager/candidates/`; каталог `0700`, файлы `0600`. Nginx, Docker, Remnanode, Xray, сертификаты и Panel не меняются. Повторный запуск создаёт новый каталог. |
| Подготовить XHTTP mode matrix | Сохраняет четыре клиентских Xray JSON примера: `auto`, `stream-one`, `stream-up`, `packet-up` | Запись только нового каталога кандидата. Сервисов и пользовательских настроек не касается. |
| План переключения и rollback | Выводит этапы ручной canary-активации и возврата предыдущего профиля | Только чтение. Скрипт не подключается к Panel API, не назначает профиль и не переключает Node. |
| Совместимость Remnawave / Happ | Выводит версию Remnanode и Xray, если доступны безопасные команды чтения; клиентские свойства помечает отдельно | Только чтение. Happ iOS/Android и выдаваемые Panel параметры остаются `NOT TESTED`, пока не проверены на реальном тестовом клиенте. |
| Шаблоны и история | Показывает snippets и созданные каталоги | Только чтение. Каталоги содержат `PREPARED ONLY`; активный профиль там не сохраняется. |

Для подготовки кандидатного каталога требуется явное подтверждение `ДА`. Отмена или пустой ответ ничего не записывает. Кандидаты неизменяемые: вместо перезаписи нового файла создаётся новый каталог, предыдущие версии остаются в истории. Поэтому локальный rollback для них не нужен. Переключение активного профиля и его rollback должны выполняться в Panel: перед canary сохраните текущий профиль, список enabled inbound, назначение Node, Host и затронутые Squads. При неудаче верните Node на сохранённый профиль и прежний набор inbound. Если менялся Host, восстановите и его. Один порт `443` может означать разрыв действующих соединений.

Подробный canary/rollback порядок: [`remnawave-transport-rollback.md`](remnawave-transport-rollback.md). Итоги релиза и открытые ограничения: [`VOID_TRANSPORT_MANAGER_V3_RELEASE_NOTES.md`](VOID_TRANSPORT_MANAGER_V3_RELEASE_NOTES.md).

Текущая версия не имеет включённой авторизации к Panel API. Поэтому никакая операция в этом меню не меняет Node, Host, Squad, пользователей или Config Profile. Если активный inbound уже занимает тот же TCP/443, второй inbound на том же socket нельзя запустить параллельно для canary: нужен отдельный тестовый Node либо отдельно согласованный свободный endpoint. Не открывайте новый публичный порт без согласования. Не копируйте candidate snippet непосредственно в runtime-файлы контейнера: Remnawave управляет конфигурацией Node. Требуется ручная проверка фактического Config Profile и Host в панели.

## Поддерживаемые шаблоны и границы готовности

Файлы в [`docs/remnawave-transport-templates/`](remnawave-transport-templates/) — обезличенные JSON fragments. Это примеры отдельных inbound/outbound объектов, а не полная Config Profile. Они используют строки `__...__` как placeholders и не являются запускаемой конфигурацией до замены значений. JSON parse не подтверждает схему установленной версии Xray.

### VLESS RAW/TCP + TLS

Контрольный TLS вариант использует собственный сертификат в read-only volume Remnanode и fallback `127.0.0.1:8080`, который должен отдавать HTTP. Не отправляйте расшифрованный HTTP на HTTPS backend `9443`. Host должен иметь правильные Address/SNI, а сертификат должен содержать соответствующий SAN. TLS на Node и Nginx HTTPS backend проверяются независимо.

### VLESS RAW/TCP + REALITY SELFSTEAL

REALITY inbound использует свой существующий `privateKey`/`shortIds`, `target: 127.0.0.1:9443`, точный `serverNames` и `xver: 0`, если Nginx не ожидает Proxy Protocol. Ключи и short IDs в кандидате являются только placeholders. Не генерируйте или не меняйте действующие ключи обычным повторным запуском. Проверка HTTPS на `9443` показывает только доступность fallback target, но не REALITY handshake.

### VLESS XHTTP + REALITY

Серверный XHTTP inbound в snippet задаёт путь и намеренно не ограничивает `mode`: согласно документации Project X, клиентский `mode` и серверный режим — разные настройки; сервер без конкретного режима принимает поддерживаемые ядром режимы. Это нужно подтвердить для версии Xray в контейнере. В клиентских образцах отдельно показаны `auto`, `stream-one`, `stream-up`, `packet-up`. Для XHTTP не добавляется Vision flow.

`stream-up` предлагается как кандидат для отдельного iOS сравнения, а не как установленный факт о совместимости Happ. Шаблоны client JSON не являются форматом импорта Happ и не подтверждают, что Remnawave Host/Mapper передаёт `xhttpSettings` или `extra`. Проверяйте фактически выданный клиентский профиль.

В документации Project X `auto` выбирает режим на стороне клиента по условиям TLS/HTTP версии или REALITY; REALITY без отдельного `downloadSettings` обычно использует `stream-one`, TLS/H2 — `stream-up`, а другие условия могут привести к `packet-up`. Это описание Xray-core, а не доказательство поведения Happ или конкретного оператора. Меняйте только клиентский mode и сравнивайте результаты на одном и том же тестовом узле.

Никакие экспериментальные `xmux`, padding, таймауты, `downloadSettings`, `noSSEHeader` или `noGRPCHeader` не устанавливаются автоматически. Сначала проверьте дефолты именно установленного Xray и добавляйте параметры по одному в изолированном тесте.

### VLESS XHTTP + TLS

Кандидат использует loopback endpoint `127.0.0.1:8443` и тот же сертификат volume. Менеджер не создаёт Nginx `location`, `proxy_pass` или `grpc_pass`, не меняет владельца public `443` и не открывает этот внутренний порт. Это важно, потому что выбранный XHTTP mode влияет на тип HTTP/2 маршрутизации; универсальная Nginx схема без проверки конкретного режима и сборки не выдаётся за готовую.

Поэтому XHTTP TLS snippet — только шаблон для тестового reverse-proxy пути. Он не является готовым Selfsteal сайта, пока отдельно не доказаны HTTPS fallback, маршрутизация нужного XHTTP пути, HTTP/2 и выдача Host в Remnawave. Для текущей production ноды не назначайте его на `443` без отдельного согласования.

### VLESS gRPC + TLS

gRPC TLS подготовлен как loopback кандидат `127.0.0.1:8444`, TLS ALPN начинается с `h2`, клиентский `serviceName` должен совпасть с inbound. Официальная документация Xray отмечает, что gRPC не поддерживает обычный fallback на сайт; для разделения трафика нужен проверенный HTTP/2 reverse proxy и path routing. Текущий установщик его не настраивает.

gRPC REALITY не формируется: хотя комбинации transport/security перечислены в документации Xray, рабочая схема selfsteal/fallback и поддержка установленной Node/Happ здесь не валидированы. Оставлено `NOT TESTED`.

## Где находятся настройки

- **VPS:** сертификат и его mount в контейнер; Nginx HTTP/ACME/8080/9443; локальные candidate файлы. Новые кандидаты не применяются к Nginx или Xray.
- **Remnawave Config Profile:** inbound port/network/security, REALITY `target`/`serverNames`, XHTTP path, TLS cert file paths, gRPC `serviceName` и назначение inbound Node.
- **Remnawave Host/Template/Mapper:** внешний Address/SNI, параметры клиентской ссылки и клиентские XHTTP поля, если установленная версия поддерживает их выдачу. Проверяйте реальный результат экспорта.
- **Клиент:** XHTTP mode, фактический fingerprint и пользовательские данные. Не копируйте private keys, UUID либо Shadowsocks credentials в отчёт.

## Совместимость и проверки

Официальные схемы Xray описывают VLESS с RAW, XHTTP и gRPC, а TLS/REALITY — как транспортную защиту. Это не подтверждает наличие функции в конкретном `rw-core`, правильность Remnawave Mapper или поддержку конкретной версии Happ. В статусе отделены `SUPPORTED` (схема по документации), `PREPARED` (файлы кандидата созданы), `ACTIVE` (inbound найден в runtime), `HEALTHY` (прошёл названную сетевую проверку), `DEGRADED`, `FAILED` и `NOT TESTED`.

Для XHTTP проверяйте отдельно TCP connect, TLS/REALITY handshake, VLESS authentication, HTTP transport, первый пользовательский запрос, DNS и путь маршрутизации. Без разрешённого клиента вся VPN end-to-end часть остаётся `NOT TESTED`. Открытие сайта браузером напрямую не считается проверкой туннеля.

Performance, LTE/3G операторы, смена сети, звонки, холодное соединение Happ, iOS 11 и поведение при массовых соединениях не тестировались. Скрипт не включает и не выключает XMUX по предположению, не создаёт нагрузку на production и не создаёт фоновых демонов. До реальных изолированных измерений производительность — `NOT TESTED`.

## Документация по протоколам

- [Xray: транспортная совместимость](https://xtls.github.io/en/config/transport.html)
- [Xray: REALITY](https://xtls.github.io/en/config/transports/reality.html)
- [Xray: TLS](https://xtls.github.io/en/config/transports/tls.html)
- [Project X: XHTTP modes и client/server параметры](https://github.com/XTLS/Xray-core/discussions/4113)
- [Xray: gRPC, HTTP/2 и fallback ограничения](https://xtls.github.io/en/config/transports/grpc.html)
- [Remnawave: Config Profiles, Nodes, Hosts и Squads](https://docs.rw/learn-en/config-profiles/)

## Что проверяется и настраивается

- наличие `/opt/remnanode/docker-compose.yml`, сервиса/контейнера `remnanode`, Docker Compose и валидность текущего Compose;
- текущие listeners и владельцы TCP/80, TCP/443, UDP/443, TCP/8080 и TCP/9443;
- DNS A/AAAA против публичных адресов Node; при расхождении выпуск сертификата не запускается;
- выделенный Nginx config в `/etc/nginx/conf.d/remna-node-tls-setup.conf`: публичный HTTP/80 для ACME HTTP-01, HTTP backend на `127.0.0.1:8080` и HTTPS backend на `127.0.0.1:9443`; оба backend используют один `WEB_ROOT`;
- Certbot Compose в `/opt/certbot/docker-compose.yml` и сертификат, полученный через webroot;
- соответствие SAN домену, валидность private key и совпадение public key сертификата с private key;
- локальный alias `/opt/certbot/certs/live/current -> <домен Node>` и read-only volume `/opt/certbot/certs:/etc/letsencrypt:ro` в сервисе `remnanode`;
- доступность сертификата внутри контейнера, HTTP/HTTPS backend, hostname и SAN, HTTP-01 webroot и ежедневный systemd renewal timer.

Скрипт намеренно завершится без изменений, если TCP/443 или UDP/443 заняты Nginx либо владельцем, которого нельзя подтвердить как процесс Xray/`rw-core` внутри `remnanode`. Владение сверяется по PID из `ss` с PID/именем процесса из `docker top remnanode`. TCP/80, TCP/8080 или TCP/9443, занятые неизвестным процессом, либо DNS, указывающий не на эту Node, останавливают настройку. Если `9443` уже занят управляемым Nginx, Verify / repair проверяет и при необходимости восстанавливает его конфигурацию. Firewall не выключается и его правила не меняются. Если Nginx не установлен, установка пакета требует явного `APPLY`.

Compose-файл Node резервируется до добавления volume. Если Compose validation не проходит, файл восстанавливается. При ошибке после изменения Compose или выделенного Nginx-файла выполняется откат этих изменений. Повторный рендер Nginx не заменяет первоначальную копию. При откате первого запуска восстанавливаются Node/Certbot Compose и Nginx, удаляется созданный этим запуском `live/current` symlink, а renewal timer возвращается к исходному состоянию. Уже выпущенные файлы сертификата не удаляются и не отзываются. Восстановление изменённого Node Compose выполняет `docker compose up -d remnanode` и поэтому может пересоздать контейнер; перед исходной правкой установщик показывает это предупреждение и запрашивает подтверждение. Резервные копии находятся в `/var/backups/remna-node-tls.*`. Пункт Reissue передаёт перевыдачу Certbot с `--force-renewal` и может упереться в Let's Encrypt rate limits.

## Постоянные локальные backend-ы

После bootstrap на Node постоянно доступны:

```text
TCP/80                 Nginx, ACME HTTP-01
TCP 127.0.0.1:8080    HTTP-сайт для VLESS TLS fallback
TCP 127.0.0.1:9443    HTTPS-сайт для REALITY selfsteal
TCP/443                Remnawave rw-core
UDP/443                Remnawave/Hysteria2, если профиль включает HY2
```

Публичный TCP/443 Nginx не слушает. TLS backend на 8080 и Selfsteal backend на 9443 обслуживают один `WEB_ROOT`. Для Selfsteal используется TLS-сертификат Node из `/opt/certbot/certs/live/current/`; `xver: 0`, поэтому Proxy Protocol не включается.

## Контракт Config Profile

Профиль остаётся общим и вручную назначается Node в Remnawave Panel. Установщик не обращается к Panel и не назначает профиль.

TLS entry профиля должен использовать **файловые пути**, а не встроенное содержимое сертификатов:

```json
"certificates": [
  {
    "keyFile": "/etc/letsencrypt/live/current/privkey.pem",
    "certificateFile": "/etc/letsencrypt/live/current/fullchain.pem"
  }
]
```

TLS-режим VLESS RAW/TCP использует эти файловые пути и fallback:

```json
"fallbacks": [
  { "dest": "127.0.0.1:8080" }
]
```

REALITY SELFSTEAL использует `target: 127.0.0.1:9443` и `xver: 0`. `privateKey` и `shortIds` — существующие значения Remnawave, установщик их не генерирует и не сохраняет. Добавьте домен Node в общий список `serverNames`.

Допускается **один общий REALITY-профиль для нескольких Node**, если:

1. Все Node используют один и тот же shared REALITY private key.
2. `serverNames` содержит точный домен каждой Node.
3. У каждого Remnawave Host свои Address/SNI.
4. На каждой Node target остаётся `127.0.0.1:9443`.

Например:

```json
"serverNames": [
  "soundcrate.24alisa.ru",
  "loopframe.24alisa.ru",
  "meshvault.24alisa.ru"
]
```

Wildcard `*.24alisa.ru` для REALITY `serverNames` не использовать: Xray не поддерживает wildcard-имена в этом списке. Общий private key означает общую зону компрометации: если скомпрометирована одна Node, REALITY key нужно ротировать для всей группы.

На каждой машине `/etc/letsencrypt/live/current/` ведёт к сертификату только этой Node. Не помещайте приватные ключи в Config Profile. После назначения профиля TCP/443 и UDP/443 должны принадлежать Xray/`rw-core`; до назначения эти listeners могут отсутствовать. Пункт меню 3 показывает DNS, сертификат и срок его действия, Nginx, HTTP 301, HTTPS/9443, TLS 1.2/1.3, HSTS, владельца TCP/443, состояние процесса `rw-core`/Xray, наличие read-only Docker volume и доступность обоих файлов сертификата в контейнере. Эти состояния разделены: работающий процесс или listener не подтверждает наличие сертификата, успешный VLESS handshake либо передачу VPN-трафика. Проверка volume сверяет source, destination и режим read-only; она ничего не исправляет. Режим профиля определяется только по inbound `streamSettings.security`; секретные поля не выводятся. Готовность сертификата для HY2 не означает, что HY2 запущен или handshake прошёл. Пункт меню 4 печатает безопасные шаблоны.

## Продление

`remna-cert-renew.timer` запускает ежедневную проверку с задержкой до двух часов. Certbot сам обновляет только сертификаты, которым требуется renewal. Скрипт сравнивает SHA-256 `fullchain.pem`; если содержимое не изменилось, Nginx и Remnanode не перезапускаются. После реального изменения проверяются срок, точный SAN и пара ключ/сертификат; затем выполняются `nginx -t`, reload Nginx и HTTPS-проверка backend `9443`. Remnanode перезапускается только если конфигурация Xray/HY2 явно ссылается на этот сертификат; если его уже пересоздал `docker compose up -d` при добавлении volume, второй restart пропускается. Проверка доступности `fullchain.pem` и `privkey.pem` внутри контейнера отделена от проверки процесса `rw-core`/Xray. После изменения Compose установщик отдельно ожидает появления файлов сертификата в контейнере и сообщает, какой файл недоступен. Процесс ищется через `docker top remnanode -eo pid,comm` (Docker требует колонку PID); после restart установщик ждёт его до 30 секунд. Если процесс не появился, установка TLS не объявляет VPN работающим и не откатывает корректный HTTPS: выдаётся `WARNING`, VPN readiness остаётся NOT VERIFIED, нужно проверить статус Node и назначение Config Profile в панели. Если Xray-профиль ещё не назначен, отсутствие `rw-core` само по себе не считается ошибкой настройки TLS. Если определить использование сертификата не удалось, Remnanode не перезапускается, а предупреждение о возможном устаревшем сертификате попадает в журнал `remna-cert-renew.service`; проверьте его через `journalctl -u remna-cert-renew.service` и отдельно выясните использование сертификата.

Ручная проверка после установки:

```sh
nginx -t
curl -fsS http://127.0.0.1:8080/
curl --resolve "$DOMAIN:9443:127.0.0.1" --cacert /opt/certbot/certs/live/current/fullchain.pem "https://$DOMAIN:9443/"
openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" -verify_hostname "$DOMAIN" -verify_return_error -CAfile /opt/certbot/certs/live/current/fullchain.pem
docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem
docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem
docker ps
docker top remnanode
systemctl list-timers remna-cert-renew.timer
ss -lntup
```

Для `openssl s_client` убедитесь, что в сертификате SAN содержит домен и сертификат ещё действителен. Ожидаются Nginx на TCP/80, оба локальных сайта на 8080/9443 и после применения профиля — Xray/`rw-core` на TCP/443 и, если HY2 включён, UDP/443. Установщик не меняет Docker networking, firewall, transport/security выбранного профиля или Reality keys.

## Локальная проверка скрипта

```sh
bash -n tools/remnawave-node-tls-setup.sh
bash tools/remnawave-node-tls-setup.sh --self-test
shellcheck tools/remnawave-node-tls-setup.sh
```

`--self-test` покрывает оба Nginx backend-а, безопасное поведение при чужом listener на 9443, SAN mismatch/pass, неизменившийся/обновлённый сертификат, Compose-миграцию, первый выпуск сертификата, задержанную доступность файлов в контейнере, готовый Xray-профиль и ноду без назначенного профиля. Отдельный regression-сценарий моделирует рабочие Nginx/9443 и `rw-core`/TCP/443 при пустых Docker mounts и отсутствующих внутри контейнера сертификатах: статус показывает каждое состояние отдельно и не объявляет VLESS TLS готовым. Проверяется, что Compose-применение не вызывает второй restart, а откат первого запуска восстанавливает конфиги, symlink и timer. Тест также проверяет меню, справку, пустой/невалидный ввод и read-only обработчики с заглушками. Он использует временные файлы; Docker, systemd и production Node не меняются. Это не заменяет реальный VPN-handshake.
