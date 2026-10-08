# Remnawave Node: локальный TLS bootstrap

Отдельный установщик подготавливает TLS на уже созданной Remnawave Node. Он запускается **на самой Node** и не меняет Panel, Config Profile, базу данных Remnawave или корневой `install.sh` проекта ORBIT.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/wester11/voikop/main/tools/remnawave-node-tls-setup.sh)
```

Поддерживаются Debian и Ubuntu с Docker Compose plugin. Скрипт использует интерактивный терминал через `/dev/tty`; при первоначальной настройке спрашивает домен этой Node и email Let's Encrypt, а при отсутствующем Nginx отдельно просит ввести `APPLY` перед установкой пакета. Безопасное состояние ограничено `/etc/remna-node-bootstrap.conf` и содержит только `DOMAIN` и `WEB_ROOT`.

Меню: `[1] Verify / repair`, `[2] Reissue certificate`, `[3] Show TLS / Selfsteal readiness`, `[4] Show Remnawave profile templates`, `[5] Exit`.

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

Compose-файл Node резервируется до добавления volume. Если Compose validation не проходит, файл восстанавливается. При ошибке после изменения Compose или выделенного Nginx-файла выполняется откат этих изменений. Резервные копии находятся в `/var/backups/remna-node-tls.*`. Уже имеющийся сертификат не удаляется; пункт Reissue передаёт перевыдачу Certbot с `--force-renewal` и может упереться в Let's Encrypt rate limits.

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

На каждой машине `/etc/letsencrypt/live/current/` ведёт к сертификату только этой Node. Не помещайте приватные ключи в Config Profile. После назначения профиля TCP/443 и UDP/443 должны принадлежать Xray/`rw-core`; до назначения эти listeners могут отсутствовать. Пункт меню 3 показывает `TLS MODE READY`, `SELFSTEAL MODE READY`, `HY2 READY` и пытается определить активный режим только по inbound `streamSettings.security`; секретные поля не выводятся. Пункт меню 4 печатает безопасные шаблоны.

## Продление

`remna-cert-renew.timer` запускает ежедневную проверку с задержкой до двух часов. Certbot сам обновляет только сертификаты, которым требуется renewal. Скрипт сравнивает SHA-256 `fullchain.pem`; если содержимое не изменилось, Nginx не перезагружается и Node не перезапускается. После реального изменения проверяются срок, точный SAN и пара ключ/сертификат; затем выполняются `nginx -t`, reload Nginx, HTTPS-проверка backend `9443`, restart `remnanode`, проверка сертификата внутри контейнера и процесса `rw-core`/Xray.

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

`--self-test` покрывает оба Nginx backend-а, безопасное поведение при чужом listener на 9443, SAN mismatch/pass, неизменившийся/обновлённый сертификат и прежние Compose-миграции. Он использует временные файлы и заглушки; Docker, systemd и production Node не меняются.
