# 🚀 Селективная маршрутизация через AmneziaWG + WARP на Padavan

![Версия](https://img.shields.io/badge/version-3.13.0--beta-blue)
![Платформа](https://img.shields.io/badge/platform-Padavan-orange)
![Лицензия](https://img.shields.io/badge/license-MIT-green)

**Автоматическая система, которая направляет трафик к заб*ным сайтам через защищённый туннель Cloudflare WARP, сохраняя прямой доступ к российским ресурсам.**

## ⚠️ Дисклеймер

Данное программное обеспечение создано в исследовательских и образовательных целях, а также для **обеспечения стабильности и конфиденциальности сетевых соединений** в рамках, разрешённых действующим законодательством.

Любое практическое использование этого ПО, выходящее за рамки изучения сетевых технологий и защиты персональных данных, находится под вашу личную ответственность.

**Авторы не одобряют и не поощряют использование данного скрипта для нарушения законодательства Российской Федерации или любой другой страны.**

## 📌 Что делает система (v3.10)

- Использует **готовые, ежедневно обновляемые CIDR-списки** (подсети) от 13+ источников (IPv4) и 4 источников (IPv6).
- Охватывает **более 66 000 подсетей IPv4** и **75+ подсетей IPv6** (Telegram, Google, Cloudflare, Meta, Amazon, Microsoft и реестр РКН).
- **Мгновенное восстановление** после перезагрузки (5–10 секунд) благодаря локальному CIDR-кэшу.
- **Умное ожидание** готовности WAN и VPN (двойная проверка: ping + wget).
- **Watchdog** восстанавливает правила после смены конфига WARP. Пополнение `bypass_nets` — через **dnsmasq-ipset** (v3.13+): IP доменов из блок-листа попадают в сет автоматически при DNS-резолве (нагрузка на роутер ~0).
- **Полная автоматизация**: установка одной командой, обновление списков каждые 6 часов.

## 🛠️ Требования

- Роутер с прошивкой **Padavan** (ядро Linux 3.4 или новее).
- **Настроенный** и **работающий** VPN-клиент **AmneziaWG или WireGuard** с конфигурацией **Cloudflare WARP** (https://warp-generator.github.io/).
- Включённый доступ по SSH.

### 🔍 Проверка совместимости перед установкой

Перед установкой системы вы можете быстро проверить, поддерживает ли ваш роутер и прошивка все необходимые компоненты. Для этого выполните одну команду:

curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.11.0-beta/hardware_check.sh | sh

## 📥 Установка (одной командой)

> ⚠️ **Устанавливайте по ТЕГУ, а не по ветке** — так вы получаете зафиксированную,
> проверенную версию, которую нельзя изменить посторонним коммитом.

Текущая стабильная — **v3.11.0-beta**:

```sh
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.11.0-beta/install.sh | sh
```

После завершения (2–3 минуты) роутер можно перезагрузить: `reboot`.

> 🔜 **v3.13.0-beta** (dnsmasq-ipset: доменный блок-лист вместо автообучения; `selftest.sh`, `rollback.sh`, снапшот) проходит
> закрытый тест. Публичная ссылка появится после выпуска тега `v3.13.0-beta`.

### ✅ Проверка после установки

Быстрая проверка ключевых элементов:

```sh
ip link show wg0
ipset list bypass_nets | grep 'Number of entries'
ip rule show | grep 'fwmark 0xca6c'
ip route show table 51 | grep wg0
```

Полная диагностика (рекомендуется):

```sh
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.13.0-beta/diagnostic.sh | sh
```

> 💡 В **v3.12+** для быстрой проверки есть `selftest.sh`. Он устанавливается в
> `/etc/storage/selftest.sh` и запускается локально, без сети:
> `sh /etc/storage/selftest.sh` (FAIL=0 → «Система в строю»).
> Оба скрипта (`selftest.sh`, `diagnostic.sh`) можно также запустить потоково:
> `curl -sL .../<tag>/<script>.sh | sh`.

## ✅ Проверка работы

- Откройте YouTube – видео должно воспроизводиться.
- Зайдите в Discord – каналы и картинки должны грузиться.
- Проверьте мессенджеры – отправка сообщений и медиа работает.

*Если какой-то сервис не открывается, подождите 20–60 секунд и обновите страницу.*

## ⚙️ Как это устроено (кратко)

- Источники CIDR (IPv4) + (IPv6) → скачивание → фильтрация → ipset restore → bypass_nets / bypass_nets6.
- Policy routing: метка 0xca6c → таблица 51 → шлюз wg0 (для IPv4 и IPv6).
- iptables: MARK + CONNMARK для сохранения метки в соединениях (IPv4 и IPv6).

Watchdog: каждые 15 секунд проверяет и восстанавливает правила (MARK/CONNMARK, policy routing, rp_filter).

dnsmasq: при DNS-резолве добавляет IP доменов из блок-листа (`itdoginfo/allow-domains`) в `bypass_nets`.

Cron: каждые 6 часов полное обновление CIDR-списков и доменного блок-листа.

## ⚠️ Известные ограничения

Сервисы Meta (Instagram, Facebook) могут работать нестабильно или требовать включения встроенного DPI-обхода (zapret) в веб-интерфейсе роутера.

Приложение Telegram может испытывать задержки.

Некоторые сайты (например, torproject.org) могут быть недоступны через WARP независимо от настроек.

## 🔧 Ручное добавление/удаление источников CIDR

Для IPv4

Добавить новый источник:

- sed -i '/^CIDR_SOURCES="/a https://example.com/new_ipv4_list.txt' /etc/storage/ipset_update.sh
- sh /etc/storage/ipset_update.sh

Удалить источник:

- sed -i '\|https://example.com/old_ipv4_list.txt|d' /etc/storage/ipset_update.sh
- sh /etc/storage/ipset_update.sh

Для IPv6

Добавить новый источник:

- sed -i '/^CIDR6_SOURCES="/a https://example.com/new_ipv6_list.txt' /etc/storage/ipset_update.sh
- sh /etc/storage/ipset_update.sh

Удалить источник:

- sed -i '\|https://example.com/old_ipv6_list.txt|d' /etc/storage/ipset_update.sh
- sh /etc/storage/ipset_update.sh

## 🗑 Удаление

```sh
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.11.0-beta/uninstall.sh | sh
```

После выполнения роутер автоматически перезагрузится и вернётся к стандартной маршрутизации.

## ↩️ Откат, если что-то пошло не так

Связь сохраняется потому, что установщик **не трогает VPN-конфиг и таблицу 51**.

**v3.11 (текущая стабильная):** отдельного `rollback.sh` нет — установка идемпотентна,
повторный запуск безопасно вернёт штатные скрипты:

```sh
# переустановить ту же версию поверх
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.11.0-beta/install.sh | sh
# проверить
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.11.0-beta/diagnostic.sh | sh
```

Крайняя мера — полный возврат к штатной маршрутизации (с автоперезагрузкой):

```sh
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.11.0-beta/uninstall.sh | sh
```

**v3.12+ (закрытый тест):** офлайн-откат из снапшота и само-проверка (без сети):

```sh
sh /etc/storage/rollback.sh      # вернуть скрипты из /etc/storage/pwb-backup-<ts>
sh /etc/storage/selftest.sh      # проверка (FAIL=0 → «Система в строю»)
```

> 🛡️ Снапшот содержит `route_watchdog.sh`, `ipset_update.sh`, `started_script.sh`,
> `diagnostic.sh` и crontab на момент установки.

## 📄 Лицензия
MIT License – вы можете свободно использовать, модифицировать и распространять этот код при условии сохранения авторских прав и дисклеймера.

## 🤝 Благодарности
- itdoginfo/allow-domains – за актуальные списки доменов.
- you-oops-dev/resolving-public – за готовые CIDR-списки.
- lord-alfred/ipranges – за точечные списки по сервисам.
- Сообществу Padavan за отличную прошивку.

## Разработано с ❤️ для удобства пользователей.
