# Changelog

## 1.0 — monitoring refresh

- три страницы-заглушки полностью переработаны в premium-стиле и не содержат персональных имён;
- добавлен node_exporter v1.5.0 с проверкой SHA-256, отдельным systemd unit и портом 9100;
- Telemt, GeoIP и node_exporter доступны удалённой Grafana только по точному IPv4 allow-list;
- `mtproto credentials` теперь повторяет полный итог установки: ключи, Telegram-ссылки, сайт, endpoints и карту портов;
- backup, restore, doctor, ports и uninstall учитывают node_exporter.

## 1.0 — Initial release

- цветной пошаговый мастер установки;
- каждый шаг показывает итоговое время, а после подтверждения установки — живой счётчик каждые 5 секунд;
- добавлены `mtproto help`, алиас `mtproto secrets` и безопасный `mtproto geoblock pause` с автоматическим возвратом через 5 минут;
- деинсталлятор полностью очищает runtime, секреты, backups, сертификат, контейнеры, правила, units и legacy-каталоги проекта;
- EE/TLS выбран рекомендуемым режимом по умолчанию; DD оставлен для совместимости и сравнительной проверки;
- добавлены `mtproto sponsor` и `mtproto client-debug` для проверки ad-tag, Middle Proxy и попыток подключения iOS;
- мастер теперь объясняет обязательный шаг `Set promotion` и условия отображения Proxy Sponsor;
- опциональная публичная HTTPS-заглушка на TCP/443: сайт открывается как `https://домен/`, а также через порт Telemt;
- безопасный повторный запуск непосредственно из `/opt/telemt` без самокопирования;
- проверка конфликтов всех портов, временное открытие TCP/80 для Certbot и команда `mtproto ports`;
- исправлено преждевременное отображение итогов портов до настройки заглушки и мониторинга;
- исправлена YAML-запись `tmpfs` для Nginx и GeoIP exporter в Docker Compose;
- Fail2ban теперь проходит проверку конфигурации и ожидание управляющего сокета;
- права `config.toml` и cache автоматически согласуются с non-root UID/GID официального образа Telemt;
- runtime/cache Telemt перенесён в tmpfs без UID-зависимого bind mount; конфигурация совместима с Docker userns-remap;
- итог выдаёт сайт, парные `tg://proxy` и `https://t.me/proxy` ссылки для каждого режима и локальные URL мониторинга/API;
- пропуск территорий без IPdeny-файла и безопасный повтор GeoBlock после сетевых ошибок;
- порядок регистрации: IP/домен и порт → Proxy Secret → ad-tag;
- видимый результат каждого этапа и готовые Telegram proxy-ссылки;
- закрытая памятка `/opt/telemt/INSTALLATION-SUMMARY.txt` и команда `mtproto credentials`;
- установка всего runtime в `/opt/telemt`;
- hardened Telemt в Docker Compose;
- DD/EE, закрытые API и метрики;
- IPv4/IPv6 GeoBlock и Fail2ban;
- Nginx HTTPS-заглушка с тремя HTML5-шаблонами;
- Let's Encrypt и self-signed fallback;
- диагностика, backup/restore, update с откатом и uninstall;
- отдельные сервисные сценарии внутри `/opt/telemt`.
- документированный перенос на другой сервер с сохранением домена, порта и секрета.
