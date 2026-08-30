<div align="center">

# ⚡ Telemt Toolkit

### Telemt-прокси и MTProto FIX V3 — из одного понятного мастера

[![Release](https://img.shields.io/badge/release-v1.0-22c55e?style=for-the-badge)](../../releases)
[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu%20%7C%20RHEL-0ea5e9?style=for-the-badge&logo=linux&logoColor=white)](#требования)
[![Docker](https://img.shields.io/badge/Docker-hardened-2563eb?style=for-the-badge&logo=docker&logoColor=white)](#безопасность)
[![License](https://img.shields.io/badge/installer-MIT-f59e0b?style=for-the-badge)](LICENSE)

**Разверните полный MTProto-стек или установите только FIX для уже работающего прокси.  
Мастер сначала показывает план и меняет сервер только после подтверждения.**

[Быстрый старт](#быстрый-старт) · [Два режима](#два-режима-установки) · [Управление](#управление) · [Диагностика](#если-что-то-не-работает)

</div>

---

## Что умеет Toolkit

| Компонент | Что получает администратор |
|---|---|
| Telemt | EE/TLS, DD/secure или оба режима, собственный Secret и ad-tag |
| MTProto FIX V3 | Опциональные iptables/u32-правила для одного или нескольких портов |
| Firewall и GeoBlock | Открытие нужных портов, IPv4/IPv6-фильтрация, сохранение SSH-доступа |
| HTTPS-заглушка | Nginx, три HTML-шаблона, Let's Encrypt и self-signed fallback |
| Мониторинг | Метрики Telemt, GeoIP exporter и node_exporter |
| Обслуживание | Doctor, логи, backup/restore, обновление с откатом и полное удаление |
| Плановый restart | 30 минут по умолчанию либо 1/3/6/12/24 часа; можно отключить |

После полной установки всё управляется одной командой:

```bash
sudo mtproto help
```

## Два режима установки

При первом запуске появляется простой выбор:

```text
Что установить?

1) Полная система Telemt
   Прокси, firewall, MTProto FIX, мониторинг и команды управления

2) Только MTProto FIX V3
   Для уже установленного MTProto-прокси

0) Выход
   Сервер не изменяется
```

### Какой режим выбрать

| Ситуация | Выбор |
|---|---|
| На чистом VPS нужен готовый прокси | **1 — Полная система Telemt** |
| Telemt или другой MTProto-прокси уже работает | **2 — Только MTProto FIX V3** |
| Нужны ссылка, Secret, GeoBlock, мониторинг и backup | **1 — Полная система** |
| Нужно применить FIX к существующему порту без изменения прокси | **2 — Только FIX** |

> [!IMPORTANT]
> Режим «только FIX» не устанавливает и не изменяет Telemt, Docker, Nginx, GeoBlock, Fail2ban, мониторинг, Proxy Secret, ad-tag или Telegram-ссылку.

## Быстрый старт

### 1. Распакуйте релиз

ZIP:

```bash
unzip telemt-installer-v1.0.zip
cd telemt-installer-v1.0
```

или TAR.GZ:

```bash
tar -xzf telemt-installer-v1.0.tar.gz
cd telemt-installer-v1.0
```

### 2. Запустите мастер

```bash
sudo bash install.sh
```

### 3. Выберите режим

Для нового сервера выберите **1**. Для существующего прокси, которому нужен только V3 FIX, выберите **2**.

Интерфейс разделён на четыре понятных этапа:

```text
НАСТРОЙКА → УСТАНОВКА → ПРОВЕРКА → ГОТОВО
```

Пример:

```text
━━━━━━━━━━━━━━━━  НАСТРОЙКА FIX  ━━━━━━━━━━━━━━━━
  Только V3 iptables: Telemt, Docker и Proxy Secret не изменяются.

╭─ НАСТРОЙКА FIX · ШАГ 01 ─────────────────────────
│ Порт MTProto-прокси
╰──────────────────────────────────────────────────
```

## Полная установка Telemt

Мастер последовательно запросит:

1. публичный домен или IP;
2. TCP-порт Telemt;
3. версию Telemt;
4. Proxy Secret — можно безопасно сгенерировать;
5. ad-tag от `@MTProxybot` — можно добавить позже;
6. режим DD, EE/TLS или оба;
7. HTTPS-заглушку;
8. мониторинг и адрес Grafana/Prometheus;
9. GeoBlock и режим IPv6;
10. Fail2ban;
11. интервал планового перезапуска;
12. MTProto FIX V3 и его порты.

После этого показывается единый план. До ответа **Y** сервер не изменяется.

### Регистрация в @MTProxybot

Мастер показывает данные в нужном порядке:

```text
1. Команда:       /newproxy
2. Сервер:        203.0.113.10:8443
3. Proxy Secret:  0123456789abcdef0123456789abcdef
```

Secret и ad-tag — разные значения. После установки рабочие DD/EE-ссылки формирует API Telemt:

```bash
sudo mtproto links
```

Если используется Proxy Sponsor:

1. откройте `@MTProxybot`;
2. отправьте `/myproxies`;
3. выберите сервер;
4. нажмите **Set promotion**;
5. укажите публичный канал;
6. подождите до одного часа.

Проверка локальной конфигурации:

```bash
sudo mtproto sponsor
```

## Только MTProto FIX V3

Этот режим предназначен для уже работающего MTProto-прокси.

Мастер:

- показывает TCP-порты, которые слушает сервер;
- спрашивает порт прокси или список через запятую;
- проверяет диапазон и удаляет дубликаты;
- проверяет поддержку `xt_u32` и `hashlimit`;
- создаёт отдельные идемпотентные iptables-цепочки;
- включает восстановление правил после перезагрузки.

Пример ввода:

```text
Порт или порты FIX [443]: 443,8443
```

Устанавливаются только:

- `iptables`, `kmod` и необходимые служебные пакеты;
- `/opt/telemt/bin/mtproto-fix.sh`;
- `telemt-mtproto-fix.service`;
- команда `/usr/local/bin/mtproto-fix`;
- минимальный закрытый файл состояния;
- оригинальная лицензия MEKO.

Управление автономной установкой:

```bash
sudo mtproto-fix
sudo mtproto-fix status
sudo mtproto-fix install 443,8443
sudo mtproto-fix apply
sudo mtproto-fix remove
```

Если уже подключён внешний `MTPR_SYNFIX`, мастер останавливается до внесения изменений. Сначала удалите прежний FIX через исходный `mekopr`, чтобы два набора правил не фильтровали один трафик одновременно.

### Что делает V3

V3 использует сигнатуру `u32` для входящих SYN-пакетов:

- совпавшая iOS-сигнатура проходит без дополнительного лимита FIX;
- остальные клиенты получают лимит 54 SYN/минуту с одного IP;
- превышение получает немедленный TCP reset;
- разрешённые пакеты продолжают проходить через основной firewall и GeoBlock.

FIX предназначен для характерных зависаний начального TCP-подключения и двухминутной блокировки клиента. Он не может восстановить уже заблокированный IP или порт и не меняет Telegram-ссылку.

Интеграция основана на [MTPROTO_FIX_By_MEKO](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO). Авторство и полный текст лицензии сохранены в [THIRD_PARTY_LICENSES/MTPROTO_FIX_By_MEKO-LICENSE.txt](THIRD_PARTY_LICENSES/MTPROTO_FIX_By_MEKO-LICENSE.txt).

## Управление

### Подключение и состояние

```bash
sudo mtproto credentials       # все ключи, ссылки и адреса
sudo mtproto links             # готовые tg:// и https://t.me ссылки
sudo mtproto status            # контейнеры и systemd-модули
sudo mtproto doctor            # полная диагностика
sudo mtproto ports             # порты, сокеты и firewall
sudo mtproto logs 200          # последние 200 строк Telemt
sudo mtproto client-debug 120  # живой журнал подключения клиента
```

### MTProto FIX

```bash
sudo mtproto fix
sudo mtproto fix status
sudo mtproto fix install 443,8443
sudo mtproto fix apply
sudo mtproto fix remove
```

### GeoBlock

```bash
sudo mtproto geoblock status
sudo mtproto geoblock pause    # отключить только региональные DROP на 5 минут
sudo mtproto geoblock resume   # включить немедленно
```

Пауза GeoBlock не отключает Fail2ban, SSH-исключения или остальные правила firewall. Возврат выполняется отдельным systemd timer даже при разрыве SSH.

### Сервис и обслуживание

```bash
sudo mtproto start
sudo mtproto stop
sudo mtproto restart
sudo mtproto restart-schedule
sudo mtproto backup
sudo mtproto update 3.4.25
sudo mtproto help
```

## HTTPS-заглушка

Обычный браузер видит сайт, а Telegram с правильным Secret — MTProto-прокси.

Доступны три шаблона:

1. Private Cloud;
2. Maison Studio;
3. Aurora Launch.

HTML-файл:

```text
/opt/telemt/stub/html/index.html
```

Управление:

```bash
sudo mtproto stub status
sudo mtproto stub check
sudo mtproto stub path
sudo mtproto stub backup
sudo mtproto stub renew
sudo mtproto stub letsencrypt
sudo mtproto stub selfsigned
sudo mtproto stub remove
```

Если DNS указывает на сервер и TCP/80 доступен, Certbot выпускает Let's Encrypt. Иначе используется self-signed сертификат, а ежедневная проверка позволяет перейти на Let's Encrypt позднее.

## Мониторинг

Можно включить:

- метрики Telemt — порт `9090`;
- GeoIP exporter — порт `9095`;
- node_exporter — порт `9100`.

Удалённый доступ разрешается только с одного точного IPv4 Grafana/Prometheus. Значение `0.0.0.0/0` мастер не принимает.

node_exporter:

- версия `1.5.0`;
- проверка официальной SHA-256;
- отдельный непривилегированный пользователь;
- unit `node_exporter.service`;
- бинарник `/usr/bin/node_exporter`.

## Порты и внешний firewall

Установщик управляет firewall внутри Linux, но не может изменить Security Group или firewall панели VPS-провайдера.

| Порт | Назначение | Внешний доступ |
|---|---|---|
| Выбранный порт Telemt | Telegram-прокси | Открыть постоянно |
| `443/tcp` | Сайт без номера порта | Если включён отдельный публичный HTTPS |
| `80/tcp` | Let's Encrypt | Открыть на время выпуска/продления |
| `9091/tcp` | API Telemt | Только localhost |
| Внутренний порт Nginx | Маскировка Telemt | Только localhost |
| `9090/tcp` | Telemt Prometheus | Localhost или IP мониторинга |
| `9095/tcp` | GeoIP exporter | Localhost или IP мониторинга |
| `9100/tcp` | node_exporter | Localhost или IP мониторинга |

Для исходящих соединений требуются DNS и TCP/443 для Docker registry, ACME, IPdeny и работы Telemt.

## GeoBlock и SSH

GeoBlock сначала загружает новый список во временный `ipset`, проверяет его и только затем атомарно заменяет активный набор. При сетевой ошибке рабочий набор сохраняется.

Первое обновление запускается неблокирующим systemd-вызовом. Мастер ожидает быстрый результат до минуты; если загрузка продолжается дольше, установка переходит к следующему шагу, а GeoBlock завершает работу в фоне.

Из блокировки всегда исключаются:

- TCP/22;
- фактические порты `sshd`;
- IP текущей SSH-сессии администратора;
- loopback и локальные healthcheck.

## Безопасность

- API Telemt — только `127.0.0.1:9091`, режим read-only;
- секреты и итоговая памятка — права `600`;
- каталог `/opt/telemt` — права `700`;
- контейнеры — read-only filesystem и `no-new-privileges`;
- capabilities сброшены;
- образы фиксируются по content digest;
- логи ограничены по размеру;
- метрики снаружи доступны только точному IP мониторинга;
- архив restore проверяется на абсолютные пути и `..`;
- update автоматически откатывается при неуспешном healthcheck;
- SSH исключается из региональной блокировки.

При порте ниже 1024 контейнер Telemt запускается с UID 0 только для `bind(2)`, сохраняя read-only filesystem, `no-new-privileges` и единственную capability `NET_BIND_SERVICE`. На портах 1024+ используется непривилегированный пользователь образа.

## Backup, обновление и перенос

### Backup и restore

```bash
sudo mtproto backup
sudo mtproto backup /root/telemt-backup.tar.gz
sudo mtproto restore /root/telemt-backup.tar.gz
```

Backup включает конфигурацию, управляющие сценарии, HTTPS-заглушку, node_exporter, MTProto FIX и systemd units.

### Обновление с откатом

```bash
sudo mtproto update 3.4.25
```

Перед обновлением создаётся backup. Новый образ должен пройти healthcheck; иначе автоматически возвращается предыдущий digest.

### Перенос без изменения доменной ссылки

1. Сохраните домен, порт, Proxy Secret, ad-tag и TLS-домен.
2. Создайте backup.
3. Запустите полную установку на новом сервере с теми же параметрами.
4. Проверьте `sudo mtproto doctor`.
5. Переключите DNS A-запись на новый IP.

Если в ссылке указан IP или меняется порт/Secret, сохранить прежнюю ссылку невозможно.

## Если что-то не работает

### APT ждёт слишком долго

Установщик ждёт только процессы, действительно удерживающие lock-файлы. Постоянный `unattended-upgrade-shutdown --wait-for-sig` не считается обновлением.

Увеличить лимит ожидания:

```bash
sudo APT_LOCK_WAIT_SECONDS=1800 bash install.sh
```

Не удаляйте `/var/lib/dpkg/lock*` вручную.

### GeoBlock ещё загружается

```bash
sudo systemctl status telemt-geoblock.service --no-pager -l
sudo journalctl -u telemt-geoblock.service -n 50 --no-pager
sudo mtproto geoblock status
```

Telemt продолжает работать, пока GeoBlock завершает атомарное обновление в фоне.

### Клиент не подключается

```bash
sudo mtproto doctor
sudo mtproto ports
sudo mtproto client-debug 120
sudo mtproto logs 200
```

Если во время попытки нет новых строк Telemt, соединение не дошло до сервера: проверьте внешний firewall, IP, порт и сеть клиента. Ping сам по себе не подтверждает доступность MTProto.

### FIX не устанавливается

Проверьте:

```bash
sudo modprobe xt_u32
sudo iptables -m u32 -h
sudo iptables -m hashlimit -h
sudo iptables -C INPUT -j MTPR_SYNFIX
```

Последняя команда не должна находить старую внешнюю цепочку.

## Требования

- Debian, Ubuntu, RHEL, Fedora или CentOS;
- Linux с systemd;
- root или `sudo`;
- минимум 1 ГБ свободного места для полной установки;
- DNS A-запись для собственного домена и Let's Encrypt;
- открытый TCP-порт прокси во внешнем firewall провайдера.

Docker Compose v2, Certbot, Fail2ban и остальные зависимости полной установки устанавливаются автоматически.

## Структура полной установки

```text
/opt/telemt/
├── install.sh
├── update.sh
├── uninstall.sh
├── doctor.sh
├── backup.sh
├── INSTALLATION-SUMMARY.txt
├── docker-compose.yml
├── config/
│   ├── config.toml
│   ├── installer.env
│   └── stub/
├── bin/
│   ├── mtproto
│   ├── mtproto-fix.sh
│   ├── firewall.sh
│   └── geoblock-update.sh
├── licenses/
├── stub/html/index.html
├── node-exporter/
├── cache/
├── logs/
└── backups/
```

## Удаление

Перед полным удалением при необходимости создайте backup:

```bash
sudo mtproto backup
sudo mtproto uninstall
```

Требуется вручную ввести `DELETE`. Удаляются контейнеры и файлы проекта, MTProto FIX, firewall/ipset, systemd units, jail Fail2ban, сертификаты, секреты и backups. Общесистемные пакеты Docker, Fail2ban и Certbot сохраняются, поскольку могут использоваться другими приложениями.

Чтобы отключить автономный FIX и удалить его iptables-правила:

```bash
sudo mtproto-fix remove
```

## Проект и лицензии

Установщик и управляющие сценарии: **© 2026 ander1k**, лицензия MIT — [LICENSE](LICENSE).

Telemt, Docker, Nginx, Certbot, Fail2ban, node_exporter, GeoLite, IPdeny и другие независимые компоненты сохраняют собственные названия, авторство и лицензии.

MTProto FIX V3 интегрирован с сохранением авторства MEKO и оригинальной лицензии: [THIRD_PARTY_LICENSES/MTPROTO_FIX_By_MEKO-LICENSE.txt](THIRD_PARTY_LICENSES/MTPROTO_FIX_By_MEKO-LICENSE.txt).

---

<div align="center">

**Telemt Toolkit · один мастер, два режима, полный контроль**

</div>
