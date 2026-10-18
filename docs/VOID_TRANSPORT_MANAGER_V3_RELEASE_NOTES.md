# VOID Transport Manager V3 — release notes

## Изменения

- Добавлен русскоязычный пункт `[T] Транспорты` с отдельным меню статуса, подготовки, совместимости, шаблонов, истории и плана отката.
- Сохранены TLS bootstrap, Certbot webroot migration, HTTP 301 с URI/query, ACME exception, HSTS, разделение проверки сертификата и `rw-core`, условное обновление Remnanode и существующий rollback.
- Добавлена безопасная подготовка обезличенных кандидатов VLESS RAW/TCP TLS, RAW/TCP REALITY, XHTTP REALITY, XHTTP TLS и gRPC TLS.
- XHTTP клиентские варианты `auto`, `stream-one`, `stream-up`, `packet-up` отделены от серверного inbound. Серверный шаблон не ограничивает один mode.
- Candidate files создаются отдельными каталогами с режимами `0700`/`0600`; существующие кандидаты не перезаписываются.
- Подготовлены JSON примеры, документация о TLS/REALITY/XHTTP/gRPC, границах Panel и процедура ручного rollback.
- Статусы не выдают процесс, HTTPS target или JSON parse за реальный VPN handshake.

## За пределами автоматизации

- Поддерживаемый Panel API write flow не подключён; переключение Node/Host выполняется вручную после review dependencies.
- XHTTP TLS и gRPC TLS — loopback snippets без автоматически настраиваемого Nginx reverse proxy; они не готовы как сайт-сохраняющий Selfsteal на production `443`.
- gRPC REALITY не подготавливается без валидированной схемы сайта/fallback и клиентского теста.
- Xray runtime schema, выдача Remnawave Host/Mapper, Happ iOS/Android, LTE/3G и производительность требуют изолированного тестового окружения; до этого `NOT TESTED`.
- Ни одна действующая Node или production Config Profile этим релизом не меняется.
