# Remnawave Node: локальный TLS bootstrap

Отдельный установщик подготавливает TLS на уже созданной Remnawave Node. Он запускается **на самой Node** и не меняет Panel, Config Profile, базу данных Remnawave или корневой `install.sh` проекта ORBIT.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/wester11/voikop/main/tools/remnawave-node-tls-setup.sh)
```

Поддерживаются Debian и Ubuntu с Docker Compose plugin. Скрипт использует интерактивный терминал через `/dev/tty`; в обычном режиме спрашивает домен этой Node и email Let's Encrypt, а при отсутствующем Nginx отдельно просит ввести `APPLY` перед установкой пакета и настройкой. Перед запуском выберите `1` для проверки/ремонта, `2` только для явной перевыдачи сертификата или `3` для выхода.

## Что проверяется и настраивается

- наличие `/opt/remnanode/docker-compose.yml`, сервиса/контейнера `remnanode`, Docker Compose и валидность текущего Compose;
- текущие listeners и владельцы TCP/80, TCP/443, UDP/443 и TCP/8080;
- DNS A/AAAA против публичных адресов Node; при расхождении выпуск сертификата не запускается;
- выделенный Nginx config в `/etc/nginx/conf.d/remna-node-tls-setup.conf`: публичный HTTP/80 для ACME HTTP-01 и локальный `127.0.0.1:8080` для fallback Hello World; этот config не открывает Nginx на 443;
- Certbot Compose в `/opt/certbot/docker-compose.yml` и сертификат, полученный через webroot;
- соответствие SAN домену, валидность private key и совпадение public key сертификата с private key;
- локальный alias `/opt/certbot/certs/live/current -> <домен Node>` и read-only volume `/opt/certbot/certs:/etc/letsencrypt:ro` в сервисе `remnanode`;
- доступность сертификата внутри контейнера, Nginx fallback, HTTP-01 webroot и ежедневный systemd renewal timer.

Скрипт намеренно завершится без изменений, если TCP/443 или UDP/443 заняты Nginx либо владельцем, которого нельзя подтвердить как процесс Xray/`rw-core` внутри `remnanode`. Владение сверяется по PID из `ss` с PID/именем процесса из `docker top remnanode`. Свободные порты и подтверждённые Remnawave/Xray listeners проходят проверку, поэтому Verify / repair можно запускать после назначения профиля. TCP/80 или TCP/8080, занятые неизвестным процессом, активная конфигурация Nginx с listener 443, либо DNS, указывающий не на эту Node, останавливают установку. Firewall не выключается и его правила не меняются. Если Nginx не установлен, установка пакета требует явного `APPLY`.

Compose-файл Node резервируется до добавления volume. Если Compose validation не проходит, файл восстанавливается. При ошибке после изменения Compose или выделенного Nginx-файла выполняется откат этих изменений. Резервные копии находятся в `/var/backups/remna-node-tls.*`. Уже имеющийся сертификат не удаляется; пункт Reissue передаёт перевыдачу Certbot с `--force-renewal` и может упереться в Let's Encrypt rate limits.

## Контракт общего Config Profile

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

Для VLESS fallback используйте локальный адрес:

```json
"fallbacks": [
  { "dest": "127.0.0.1:8080" }
]
```

Не фиксируйте домен Node или его `serverName` в общем server-side профиле. Для каждой Node её Remnawave Host должен иметь собственные Address/SNI. На каждой машине один и тот же путь `/etc/letsencrypt/live/current/` ведёт к **сертификату только этой Node**. Не помещайте приватные ключи в Config Profile: общий профиль, содержащий сами ключи или несколько ключей, может раскрыть их всем Node, которым назначен профиль. После назначения профиля TCP/443 и UDP/443 должны принадлежать Xray/`rw-core`; до его назначения эти listeners могут отсутствовать.

## Продление

`remna-cert-renew.timer` запускает ежедневную проверку с задержкой до двух часов. Certbot сам обновляет только сертификаты, которым уже требуется renewal. Скрипт сравнивает SHA-256 `fullchain.pem`; если содержимое не изменилось, Node не перезапускается. При изменении проверяется SAN, затем перезапускается только сервис `remnanode` и проверяется доступность сертификата в контейнере.

Ручная проверка после установки:

```sh
nginx -t
curl -fsS http://127.0.0.1:8080/
docker exec remnanode test -r /etc/letsencrypt/live/current/fullchain.pem
docker exec remnanode test -r /etc/letsencrypt/live/current/privkey.pem
docker ps
docker top remnanode
systemctl list-timers remna-cert-renew.timer
ss -lntup
```

Ожидаются Nginx на TCP/80, Nginx fallback только на `127.0.0.1:8080`, и после применения общего профиля — Xray/`rw-core` на TCP/443 и UDP/443. Установщик не меняет Docker networking, firewall, транспорт/security inbound, ключи профиля или Nginx TLS-сертификаты.

## Локальная проверка скрипта

```sh
bash -n tools/remnawave-node-tls-setup.sh
bash tools/remnawave-node-tls-setup.sh --self-test
shellcheck tools/remnawave-node-tls-setup.sh
```

`--self-test` проверяет валидатор домена/email, Nginx template и идемпотентное добавление volume к временному Compose-файлу. Он не обращается к Docker, системе, сертификатам или production Node.
