<div align="center">

# ⚡ Telemt Installer

### Защищённый MTProto-прокси с красивым интерактивным мастером

[![Release](https://img.shields.io/badge/release-v1.0-22c55e?style=for-the-badge)](../../releases)
[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu%20%7C%20RHEL-0ea5e9?style=for-the-badge&logo=linux&logoColor=white)](#системные-требования)
[![Docker](https://img.shields.io/badge/Docker-hardened-2563eb?style=for-the-badge&logo=docker&logoColor=white)](#безопасность)
[![License](https://img.shields.io/badge/installer-MIT-f59e0b?style=for-the-badge)](LICENSE)

**Установите Telemt, firewall, Fail2ban, GeoIP, node_exporter и настоящую HTTPS-заглушку в одном понятном мастере.**

[Установка](#быстрый-старт) · [Возможности](#возможности) · [Команды](#управление) · [Заглушка](#https-заглушка) · [Обновление](#обновление-и-откат)

</div>

---

## Зачем нужен этот установщик

Ручная настройка MTProto-прокси затрагивает Docker, TLS, firewall, сертификаты, мониторинг и системные службы. `Telemt Installer` собирает всё это в один цветной мастер и объясняет каждый выбор простым языком.

После установки проект целиком находится в:

```text
/opt/telemt
```

Запуск установщика из `/root`, `/tmp`, домашнего каталога или другой папки не меняет место установки.
Повторный запуск `/opt/telemt/install.sh` поддерживается: мастер создаст backup и не будет пытаться копировать файл поверх самого себя.

> [!IMPORTANT]
> Это самостоятельный установщик и набор средств управления. Сам сервер Telemt является отдельным upstream-проектом и загружается как готовый контейнерный образ.

## Быстрый старт

### Вариант 1 — скачать релиз

Скачайте `telemt-installer-v1.0.tar.gz` со страницы [Releases](../../releases), затем выполните:

```bash
tar -xzf /tmp/telemt-installer.tar.gz -C /tmp
sudo bash /tmp/telemt-installer-v1.0/install.sh
```

### Вариант 2 — клонировать репозиторий

```bash
git clone <адрес-этого-репозитория> telemt
cd telemt
sudo bash install.sh
```

Мастер сначала соберёт ответы, затем покажет полный план. Сервер изменяется только после подтверждения.

## Возможности

| Модуль | Что делает |
|---|---|
| 🎨 Цветной мастер | Нумерованные шаги, подсказки, результат каждого этапа и итоговая сводка |
| 🔐 Telemt | EE/TLS по умолчанию, DD/secure или оба режима, собственный secret и ad-tag |
| 🧱 Firewall | Открывает порт прокси, поддерживает IPv4/IPv6 и не блокирует SSH |
| 🌍 GeoBlock | Блокирует крупные регионы, атомарно обновляет IP-наборы раз в сутки |
| 🛡️ Fail2ban | Защищает фактические SSH-порты от перебора паролей |
| 📊 Мониторинг | Telemt/GeoIP-метрики и node_exporter v1.5.0 с allow-list для удалённой Grafana |
| 🌐 HTTPS-заглушка | Внутренний Nginx, три premium HTML5-шаблона, SFTP-редактирование |
| 🔏 Сертификаты | Let's Encrypt с автопродлением и self-signed fallback |
| 🩺 Диагностика | Проверяет контейнеры, API, порты, firewall, DNS, метрики и сертификат |
| ♻️ Обновления | Фиксирует image digest, проверяет healthcheck и откатывается при ошибке |
| 💾 Backups | Сохраняет конфигурацию, сайт, скрипты и systemd units |

## Как выглядит мастер

```text
╔══════════════════════════════════════════════════╗
║  ● TELEMT INSTALLER                              ║
║    Secure MTProto stack · release v1.0           ║
╚══════════════════════════════════════════════════╝
  ✔ Безопасные значения по умолчанию
  → Каждый выбор сопровождается подсказкой
  ⚠ Изменения применятся после итогового подтверждения

  ◷ ШАГ 12 выполняется: 35 сек. — Firewall и GeoBlock
  ✔ ШАГ 12 завершён за 48 сек.

╭──────────────────────────────────────────────────╮
│ ШАГ 03  HTTPS-страница-заглушка                  │
╰──────────────────────────────────────────────────╯
  ℹ Обычный браузер увидит сайт, а Telegram с
    правильным ключом — прокси.
```

Мастер сначала показывает IP, домен и свободный порт. Затем генерирует `Proxy Secret` и выводит данные в том порядке, в котором их нужно передать `@MTProxybot`:

```text
╭─ РЕЗУЛЬТАТ: данные для @MTProxybot
│ 1. Команда боту     /newproxy
│ 2. IP и порт        203.0.113.10:8443
│ 3. Proxy Secret     0123456789abcdef0123456789abcdef
╰────────────────────────────────────────────────
```

`Proxy Secret` и `ad_tag` — разные значения. После регистрации бот выдаёт `ad_tag`, который можно сразу вставить в мастер. Ссылку, которую показывает бот на этапе регистрации, использовать не нужно. По завершении установки мастер получает из API Telemt готовую ссылку `tg://proxy?...` или `https://t.me/proxy?...` для добавления прокси в Telegram.

## Системные требования

- Debian, Ubuntu, RHEL, Fedora или CentOS;
- systemd;
- root или `sudo`;
- минимум 1 ГБ свободного места;
- DNS A-запись — для собственного домена и Let's Encrypt;
- открытый TCP-порт прокси во внешнем firewall провайдера.

Docker и Compose v2 устанавливаются автоматически из системного или официального Docker-репозитория.

## Структура `/opt/telemt`

```text
/opt/telemt/
├── install.sh             # сохранённый мастер установки
├── update.sh              # обновление Telemt
├── uninstall.sh           # безопасное удаление
├── doctor.sh              # полная диагностика
├── backup.sh              # создание backup
├── VERSION                # версия установщика
├── INSTALLATION-SUMMARY.txt # закрытая памятка с данными подключения
├── docker-compose.yml     # hardened-контейнеры
├── config/
│   ├── config.toml        # конфигурация Telemt и секрет
│   ├── installer.env      # параметры модулей
│   └── stub/              # Nginx и сертификаты заглушки
├── bin/                   # firewall, GeoBlock, cert и mtproto
├── stub/html/index.html   # ваша HTML5-страница
├── geo-exporter/          # GeoIP exporter и его данные
├── node-exporter/         # Закреплённый бинарник node_exporter v1.5.0
├── cache/
├── logs/
└── backups/
```

Системная интеграция создаёт только unit-файлы в `/etc/systemd/system`, jail Fail2ban и ссылку `/usr/local/bin/mtproto`.

## Управление

Основная команда доступна из любой папки:

```bash
mtproto status
mtproto links
mtproto links-raw
mtproto credentials
mtproto secrets
mtproto sponsor
mtproto client-debug 120
mtproto geoblock status
mtproto geoblock pause
mtproto geoblock resume
mtproto ports
mtproto logs 200
mtproto doctor
mtproto firewall
mtproto users
mtproto stats
mtproto backup
mtproto update 3.4.25
mtproto help
mtproto uninstall
```

Те же операции доступны отдельными файлами:

```bash
sudo /opt/telemt/doctor.sh
sudo /opt/telemt/backup.sh
sudo /opt/telemt/update.sh 3.4.25
sudo /opt/telemt/uninstall.sh
```

Команда `mtproto links` показывает для каждого активного режима две эквивалентные ссылки: `tg://proxy?...` и `https://t.me/proxy?...`. При DD + EE итог содержит четыре ссылки. `mtproto links-raw` выводит исходные ссылки API Telemt.

Команды `mtproto credentials` и `mtproto secrets` повторно показывают полный итог установки: сервер, все порты, Proxy Secret, ad-tag, DD/EE-ссылки, адрес сайта-заглушки, API и endpoints Telemt, GeoIP и node_exporter. Эти данные также сохраняются в `/opt/telemt/INSTALLATION-SUMMARY.txt` с правами `600`; читать файл должен только `root`.

Команда `mtproto sponsor` проверяет `use_middle_proxy`, формат и согласованность глобального и пользовательского ad-tag, доступность API и недавние ошибки Middle Proxy. Она не может подтвердить регистрацию тега на стороне Telegram — это доступно только через `@MTProxybot`.

Команда `mtproto client-debug 120` в течение двух минут показывает новые логи Telemt. В это время удалите старую запись прокси на iPhone, снова откройте нужную DD- или EE-ссылку и попробуйте подключиться. Если новых строк нет, соединение не дошло до Telemt; `Telegram handshake timeout` обычно указывает на клиент, сеть или DPI; ошибки `ME` относятся к соединению Telemt с Telegram.

Команда `mtproto ports` показывает назначение всех портов, активные listening sockets и правила firewall, созданные установщиком.

Команда `mtproto help` выводит сгруппированный список команд с краткими пояснениями.

## Proxy Sponsor и ad-tag

Ad-tag активирует серверную часть статистики и продвижения, но сам по себе не назначает канал. После установки:

1. откройте `@MTProxybot` и отправьте `/myproxies`;
2. выберите зарегистрированный IP и порт;
3. нажмите `Set promotion`;
4. отправьте ссылку на публичный канал — приватный канал не подходит;
5. подождите до одного часа;
6. проверяйте с аккаунта, который ещё не подписан на этот канал.

На iOS перед повторной проверкой обновите официальный Telegram, удалите старую запись прокси целиком и добавьте её заново из свежей ссылки `mtproto links`. Наличие ping подтверждает только доступность IP по ICMP и ничего не говорит об MTProto-handshake. Если EE работает на том же адресе и порту, а DD нет, DNS, входной порт и базовый secret уже подтверждены; сравните Wi-Fi и мобильную сеть и одновременно запустите `sudo mtproto client-debug 120`.

## HTTPS-заглушка

Telemt принимает Telegram на публичном порту, а обычные HTTPS-запросы пересылает во внутренний Nginx:

```toml
[censorship]
tls_domain = "telemt.example.com"
mask = true
mask_host = "127.0.0.1"
mask_port = 9443
```

Nginx всегда слушает внутренний loopback-порт для маскировки Telemt и показывает одну из трёх страниц:

1. статус технологического сервиса;
2. персональное портфолио;
3. «Скоро открытие».

Если Telemt работает не на `443`, мастер может дополнительно открыть Nginx на стандартном HTTPS-порту `443`. Тогда одновременно работают:

- `https://example.com/` — обычный сайт без порта;
- `https://example.com:8443/` — та же заглушка через маскирующий порт Telemt;
- Telegram-прокси — на выбранном порту Telemt.

Если Telemt сразу установлен на `443`, отдельный публичный listener Nginx не создаётся: Telemt сам отличает Telegram от браузера и направляет браузер в Nginx. Произвольный порт, явно введённый в адресной строке, должен быть отдельно открыт и прослушиваться; установщик намеренно не перенаправляет все порты сервера.

Заменить страницу по SFTP можно здесь:

```text
/opt/telemt/stub/html/index.html
```

Команды управления:

```bash
mtproto stub status
mtproto stub check
mtproto stub path
mtproto stub backup
mtproto stub renew
mtproto stub letsencrypt
mtproto stub selfsigned
mtproto stub remove
```

Если DNS указывает на сервер и TCP/80 доступен, Certbot выпускает Let's Encrypt. Иначе создаётся временный self-signed сертификат, а ежедневный timer продолжает проверять возможность перехода на Let's Encrypt.

## GeoBlock и SSH

Доступны Северная Америка, Латинская Америка, Европа, Азия, Ближний Восток, Африка и Океания. Наборы IPv4/IPv6 сначала полностью загружаются во временный `ipset`, проверяются и только затем атомарно заменяют рабочий набор.

Территории, для которых IPdeny не публикует отдельный файл адресов, безопасно пропускаются. При временной сетевой ошибке действующий набор не заменяется, установка продолжается, а systemd timer повторяет загрузку позднее.

Из региональной блокировки всегда исключены:

- TCP/22;
- фактические порты `sshd`;
- IP текущей SSH-сессии администратора.

Для временной диагностики можно отключить только региональные `DROP`-правила ровно на пять минут:

```bash
sudo mtproto geoblock pause
sudo mtproto geoblock status
sudo mtproto geoblock resume   # включить раньше пяти минут
```

Возврат создаётся как отдельный systemd timer, поэтому GeoBlock включится автоматически даже при разрыве SSH. Команда не отключает Fail2ban, SSH-исключения, разрешения портов или остальные правила firewall.

## Безопасность

- API Telemt слушает только `127.0.0.1:9091` и работает в `read_only`;
- внешний доступ к метрикам включается только для точного IPv4 удалённого Grafana/Prometheus; вариант `0.0.0.0/0` установщик не принимает;
- node_exporter v1.5.0 слушает отдельный порт `9100` по умолчанию и проверяется по `/metrics`;
- закрытая памятка и служебные секреты имеют права `600`; `config.toml` — `644 root:root` внутри недоступного другим пользователям каталога `/opt/telemt` (`700`), что совместимо с non-root контейнером и Docker user namespace remapping;
- контейнеры запускаются с read-only root filesystem;
- capabilities сброшены, включён `no-new-privileges`;
- Docker-образы фиксируются по content digest;
- логи контейнеров ограничены по размеру;
- архив восстановления проверяется на безопасные пути;
- обновление автоматически откатывается при неуспешном healthcheck.

## Обновление и откат

```bash
sudo /opt/telemt/update.sh 3.4.25
```

Можно указать `latest`, но стабильная версия предпочтительнее. Перед обновлением создаётся backup. Новый образ запускается по digest и должен пройти healthcheck; иначе возвращается предыдущий образ.

## Backup и восстановление

```bash
mtproto backup
mtproto backup /root/telemt-backup.tar.gz
mtproto restore /root/telemt-backup.tar.gz
```

Backup включает конфигурацию, runtime-скрипты, HTML-заглушку, node_exporter и systemd units проекта.

## Миграция на другой сервер

Чтобы существующие клиенты переключились без изменения ссылки:

1. Уменьшите TTL DNS заранее, если это возможно.
2. Создайте backup на старом сервере или сохраните публичный домен, порт, Proxy Secret, ad-tag и TLS-домен.
3. Запустите установщик на новом сервере.
4. Укажите тот же публичный домен, тот же порт и прежний Proxy Secret.
5. Для TLS-ссылок сохраните тот же TLS-домен; ad-tag также рекомендуется перенести.
6. Проверьте новый сервер командой `mtproto doctor`.
7. Смените A-запись домена на новый IP и дождитесь обновления DNS-кэша.

Клиенты, подключённые по доменному имени, продолжат использовать прежнюю ссылку. Если в ссылке указан старый IP или изменился порт, автоматического переключения не будет.

## Удаление

```bash
sudo /opt/telemt/uninstall.sh
```

Деинсталлятор требует ввести `DELETE`, после чего полностью удаляет контейнеры проекта, образы при отсутствии других потребителей, firewall/ipset, systemd units, jail Fail2ban, сертификат заглушки, ссылку `mtproto`, `/opt/telemt` вместе с секретами и backups, а также legacy-каталоги `/opt/mtg` и `/opt/geo-exporter`. Операция необратима — заранее выполните `mtproto backup`, если данные нужны.

Общесистемные пакеты Docker, Fail2ban и Certbot не удаляются: они могут использоваться другими приложениями.

## Внешний firewall

Скрипт управляет firewall внутри Linux, но не может изменить Security Group, Network ACL или firewall панели VPS. Разрешите выбранный TCP-порт Telemt у провайдера. Для выпуска Let's Encrypt временно требуется входящий TCP/80.

| Порт | Доступ |
|---|---|
| Выбранный порт Telemt | Постоянно открыт публично в локальном firewall |
| `443/tcp` | Постоянно открыт, если включён сайт без указания порта и Telemt использует другой порт |
| `80/tcp` | Временно открывается для выпуска и продления Let's Encrypt |
| `9091/tcp` | Только `127.0.0.1`, API Telemt |
| Внутренний порт Nginx | Только `127.0.0.1`, снаружи не открывается |
| `9090/tcp` | Telemt Prometheus; localhost либо точный IPv4 сервера мониторинга |
| `9095/tcp` | GeoIP exporter; localhost либо точный IPv4 сервера мониторинга |
| `9100/tcp` | node_exporter; localhost либо точный IPv4 сервера мониторинга |

Установщик проверяет конфликты между этими портами. Внешний firewall провайдера необходимо проверить отдельно.

Для исходящих соединений серверу требуются DNS (`53/udp`, при необходимости `53/tcp`) и `443/tcp` для Docker registry, Let's Encrypt/ACME, IPdeny, GeoIP и соединений Telemt с внешней инфраструктурой. Если у провайдера исходящий трафик фильтруется, проще разрешить established/related и не ограничивать egress для контейнера Telemt.

## Проект и лицензии

Установщик, мастер и управляющие сценарии: **© 2026 ander1k**, лицензия MIT — см. [LICENSE](LICENSE).

Используемые независимые компоненты (Telemt, Docker, Nginx, Certbot, Fail2ban, Prometheus node_exporter, GeoLite и IPdeny) сохраняют собственные названия, авторство и лицензии. Репозиторий не заявляет авторство над ними.

---

<div align="center">

**[Telemt Installer](../../) · release v1.0**

</div>
