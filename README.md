# 3AX-UI: установка одной командой

Неинтерактивный установщик [3AX-UI](https://github.com/coinman-dev/3ax-ui) с поддержкой AmneziaWG и импорта конфигураций в AmneziaVPN.

## Установка

Подключитесь к новому VPS по SSH под `root` и выполните:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yavasilek/3ax-ui-installer/main/install.sh)
```

В конце команда выведет:

```text
URL: https://IP-АДРЕС.sslip.io:ПОРТ/СЕКРЕТНЫЙ-ПУТЬ/
Username: admin_...
Password: ...
```

Реквизиты также сохраняются в `/root/3ax-ui-credentials.txt` с правами `600`. Повторный запуск команды просто покажет их ещё раз.

## Что делает скрипт

- ставит последнюю стабильную версию официального 3AX-UI;
- проверяет наличие утилиты и модуля ядра AmneziaWG;
- создаёт случайные логин, пароль, порт и секретный URL-путь;
- формирует домен вида `185-105-226-75.sslip.io` без ручной настройки DNS;
- получает доверенный сертификат Let's Encrypt и включает его автопродление;
- открывает нужные TCP-порты в активном UFW или firewalld;
- проверяет службу и HTTPS перед показом реквизитов.

Если выпуск сертификата сорвётся, панель останется доступна только локально. После устранения причины достаточно повторить ту же команду — установка продолжится.

## Требования

- чистый VPS с Debian 11+ или Ubuntu 22.04+;
- `root`, systemd, архитектура amd64 или arm64;
- ядро Linux 5.6+ и желательно не менее 1 ГБ RAM;
- свободный и доступный из интернета TCP-порт `80` для Let's Encrypt;
- во внешнем файрволе хостинга должен быть разрешён выбранный TCP-порт панели.

Скрипт намеренно не перезаписывает чужую установку `x-ui`/`3AX-UI` и останавливается, если порт 80 уже занят.

## Необязательные параметры

Задать порт панели заранее:

```bash
PANEL_PORT=50409 bash <(curl -fsSL https://raw.githubusercontent.com/yavasilek/3ax-ui-installer/main/install.sh)
```

Использовать свой домен, который уже указывает на VPS:

```bash
PANEL_DOMAIN=vpn.example.com bash <(curl -fsSL https://raw.githubusercontent.com/yavasilek/3ax-ui-installer/main/install.sh)
```

Зафиксировать конкретную версию 3AX-UI:

```bash
THREE_AX_VERSION=v2.3.5 bash <(curl -fsSL https://raw.githubusercontent.com/yavasilek/3ax-ui-installer/main/install.sh)
```

## AmneziaVPN

После входа откройте **AWG Settings**, проверьте параметры AmneziaWG 2.0, затем создайте inbound с протоколом `amneziawg`. Клиентский QR-код или `.conf` можно импортировать как в отдельный клиент AmneziaWG, так и в приложение AmneziaVPN.

> Выполнение удалённого скрипта от `root` всегда требует доверия к репозиторию. Для предварительной проверки скачайте `install.sh`, прочитайте его и только затем запустите `bash install.sh`.
