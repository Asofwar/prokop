# Распространение форка Asofwar/prokop

Prokop — форк [slayer326/forkop](https://github.com/slayer326/forkop) под
собственным именем (раньше этот репозиторий назывался `Asofwar/forkop`, а
проект — Forkop). Документ описывает, откуда форк берёт свои релизы и
зависимости, почему он не доверяет зеркалам, как на него переходят роутеры с
Forkop и где у этой схемы пределы. Коротко:

- Prokop ставится и обновляется только из релизов форка: статический канал
  `https://asofwar.github.io/prokop` (GitHub Pages), резерв — GitHub Releases
  репозитория `Asofwar/prokop`.
- Зеркало зависимостей выключено по умолчанию и включается только явно.
- Ни при каких настройках роутер не получает APK-ключ зеркала и фид
  `forkop.list`: пакеты Prokop не могут прийти с зеркала.
- Ни slayer326/forkop, ни `fold8.ru`, ни `mirror.infotechtg.ru` для работы форка
  не нужны.
- Роутер с Forkop переходит на Prokop командой установки; встроенное
  обновление Forkop этого не делает.

## Источники

| Что | Без зеркала (по умолчанию) | С включённым зеркалом |
|---|---|---|
| Пакеты Prokop, `install.sh` | канал `https://asofwar.github.io/prokop`, резерв — GitHub Releases `Asofwar/prokop` | так же: зеркало не участвует |
| Пакеты OpenWrt (sing-box, зависимости) | официальные фиды `downloads.openwrt.org` | `<зеркало>/openwrt/releases`, если индекс платформ зеркала знает релиз и архитектуру роутера |
| Списки и наборы правил | исходные репозитории на GitHub (для части списков — резерв через jsDelivr) | `<зеркало>/forkop/lists`, резерв — исходные адреса |
| sing-box-extended | `https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest`, SHA-256 сверяется с `digest` ассета, когда GitHub его отдаёт | копия метаданных релиза на зеркале |
| Zapret-Manager | `https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh`, без `ZAPRET_MANAGER_MIRROR` | кэш Zapret-Manager на зеркале |

Пути вида `<зеркало>/forkop/...` и индекс `<зеркало>/openwrt/forkop-platforms.tsv`
— это раскладка зеркал upstream, общая с ними; переименование проекта её не
меняет. По той же причине старое написание сохраняют `b4geoip-forkop`
(репозиторий наборов правил Greeg0ry) и суффикс резервных копий фидов
`*.pre-forkop-mirror`.

## Канал релизов

### Структура

```text
https://asofwar.github.io/prokop/
├── index.html
├── install.sh                 установщик самого нового релиза
├── LATEST                     X.Y.Z самого нового релиза
├── updates/latest.json        метаданные самого нового релиза
├── updates/releases.json      каталог версий (format 1) для выбора и отката
└── releases/X.Y.Z/
    ├── prokop_X.Y.Z.{ipk,apk}
    ├── luci-app-prokop_X.Y.Z.{ipk,apk}
    ├── luci-i18n-prokop-ru_X.Y.Z.{ipk,apk}
    └── SHA256SUMS
```

Структура и форматы JSON те же, что у прежнего бандла `fold8.ru`:
`latest.json` повторяет ответ GitHub API (`tag_name`, `assets[]` с
`browser_download_url`, `sha256`, `digest`), `releases.json` — каталог
`{"format": 1, "releases": [...]}`. Все ссылки абсолютные и ведут в
`https://asofwar.github.io/prokop/releases/X.Y.Z/`. Поэтому роутеру, установщику
и LuCI не нужен отдельный код для Pages — они просто читают другой адрес.

### Как канал собирается

1. Владелец пушит тег `X.Y.Z`. Workflow **Build packages** прогоняет тесты,
   собирает шесть пакетов и создаёт GitHub Release: пакеты, `install.sh` из того
   же коммита и архив статического бандла `prokop-timeweb-X.Y.Z.tar.gz`.
2. Успешное завершение **Build packages** запускает **Publish release channel**
   (`.github/workflows/pages.yml`, событие `workflow_run`).
3. `ops/pages/build-site.py` читает список релизов через GitHub API, берёт
   опубликованные (не draft и не prerelease) релизы со строгим тегом `X.Y.Z`,
   до 8 самых новых полных по числовому сравнению версий, скачивает их пакеты, сверяет
   с `digest` (SHA-256), который GitHub указывает для ассета, и сам считает
   SHA-256 каждого файла. В `latest.json`, `releases.json` и `SHA256SUMS`
   попадают именно посчитанные суммы. `install.sh` берётся из ассета самого
   нового релиза, а если его нет — из файла репозитория на этом теге.
4. Сайт собирается во временный каталог и появляется целиком. Самый новый
   релиз обязан быть полным и проверенным: если в нём не хватает пакета, не
   совпали размер или сумма, файл не скачался или подходящих релизов нет вовсе,
   сборка падает, и Pages продолжает отдавать предыдущую версию сайта. Более
   старый релиз без какого-то пакета или с несовпавшими размером или суммой
   пропускается с предупреждением `WARNING: skipping …` в логе и не попадает ни
   в `releases/`, ни в `updates/releases.json`; его место среди 8 публикуемых
   занимает следующий полный релиз. Так один испорченный старый релиз не
   блокирует все последующие публикации. Ошибка скачивания роняет сборку при
   любом релизе: она может быть временной.

Сайт пересобирается целиком, потому что публикация на Pages заменяет весь сайт:
дописать файл к уже опубликованному нельзя. Значит, источник правды — GitHub
Releases, а Pages — производная от них витрина.

`workflow_run` всегда выполняется на ветке по умолчанию, и это нужно: окружение
`github-pages` по умолчанию разрешает деплой только с неё. Поэтому деплой не
встроен в **Build packages** — тот запускается на теге и в окружение не
пустил бы.

### Резервные пути

- **Установка.** Основная команда — `wget -qO- https://asofwar.github.io/prokop/install.sh | sh`.
  Если `github.io` недоступен, та же версия установщика есть в релизе:
  `wget -qO- https://github.com/Asofwar/prokop/releases/latest/download/install.sh | sh`.
- **Метаданные.** Установщик и встроенное обновление сначала читают
  `updates/latest.json` канала, а при его недоступности — GitHub API
  `https://api.github.com/repos/Asofwar/prokop/releases/latest`. Имена ассетов в
  релизе совпадают с именами в канале, суммы берутся из `digest` ассетов.
- **Значения по умолчанию** на роутере заданы в
  `prokop/files/usr/lib/core/constants.uc`: `PROKOP_RELEASE_REPO=Asofwar/prokop`,
  `PROKOP_RELEASE_BASE_URL=https://asofwar.github.io/prokop`; одноимённые
  переменные окружения их переопределяют.
- **Выбор версии и откат** работают по `updates/releases.json` канала. Резерва
  через GitHub API у каталога нет: в нём перечислено только то, что реально
  лежит на сайте, и роутер принимает версию, лишь если у всех трёх её пакетов
  есть SHA-256 и ссылка внутрь `releases/X.Y.Z/` канала. Пока Pages недоступен,
  откат на старую версию недоступен, обновление до новой — доступно через
  GitHub API.

## Политика зеркала

### Как определяется зеркало

Везде одинаково: если переменная окружения `PROKOP_MIRROR_BASE_URL` задана
(даже пустой), действует её значение; иначе — `prokop.settings.mirror_base_url`;
пустое или отсутствующее значение означает «зеркало выключено». Завершающие `/`
отбрасываются. Ни один путь кода больше не подставляет зеркало по умолчанию.

Включить зеркало можно только явно:

```sh
# при установке
wget -qO- https://asofwar.github.io/prokop/install.sh | sh -s -- --mirror https://mirror.example.org
# или переменной окружения
wget -qO- https://asofwar.github.io/prokop/install.sh | PROKOP_MIRROR_BASE_URL=https://mirror.example.org sh
# на установленном роутере
uci set prokop.settings.mirror_base_url=https://mirror.example.org
uci commit prokop
/usr/share/prokop/mirror-migration.sh   # привести фиды OpenWrt к настройке
```

Выключение — `uci set prokop.settings.mirror_base_url=''`, `uci commit prokop` и
тот же скрипт: фиды, указывающие на бывшие зеркала upstream, вернутся на
официальные адреса; фиды на своём зеркале скрипт не трогает — их возвращают
вручную (резервная копия лежит рядом в `<файл>.pre-forkop-mirror`).

Установщик сохраняет зеркало в UCI после установки пакетов и ещё раз
запускает `/usr/share/prokop/mirror-migration.sh`, чтобы фиды OpenWrt
соответствовали настройке. Индекс платформ `<зеркало>/openwrt/forkop-platforms.tsv`
запрашивается только при включённом зеркале.

Бывшие зеркала upstream — `mirror.infotechtg.ru` и `mirror.51343.ru` (в том числе
`http://` и с завершающим `/`) — распознаются только для очистки старых
настроек и фидов, никогда как значение по умолчанию.

### Почему нет ключа зеркала и фида forkop.list

Раньше установка Forkop с зеркалом клала `<зеркало>/forkop/forkop-apk.pem` в
`/etc/apk/keys/forkop-mirror.pem` и добавляла фид
`/etc/apk/repositories.d/forkop.list` с пакетами Forkop, собранными на зеркале.
Для форка это недопустимо:

- `apk` доверяет каждому ключу из `/etc/apk/keys` для **любого** репозитория.
  Ключ зеркала позволил бы владельцу зеркала подписать любой пакет — в том
  числе пакет из официального фида OpenWrt.
- Фид `forkop.list` на upstream-зеркале содержит сборки upstream Forkop. Пока
  у форка были те же имена пакетов, обычный `apk upgrade` заменял бы ими пакеты
  форка, и встроенное обновление перестало бы следовать за релизами форка.
  У Prokop имена свои, но фид и ключ по-прежнему чужие и лишние.
- Канал релизов форка уже проверяет каждый пакет по SHA-256 из своих
  метаданных. Второй, подписанный чужим ключом путь доставки только обходил бы
  эту проверку.

Поэтому ни установщик, ни пакеты не скачивают ключ зеркала и не пишут
`forkop.list` — даже при включённом зеркале. Наоборот, и установщик, и
`postinst` пакета удаляют `/etc/apk/keys/forkop-mirror.pem` и
`/etc/apk/repositories.d/forkop.list`, если находят их. Зеркало остаётся
ускорителем для пакетов OpenWrt, списков и сторонних компонентов; сам Prokop
всегда приходит из канала релизов форка.

### Сценарии пакетов не падают из-за зеркала

Цепочка `postinst` пакета `prokop`:

1. `migration.uc migrate` — миграции конфигурации; ошибка, как и раньше,
   прерывает установку;
2. `mirror-migration.sh` — сверка фидов с настройкой зеркала; выполняется
   «по возможности»: при ошибке печатается предупреждение;
3. `prokop package_postinst` — выполняется всегда.

`mirror-migration.sh` сам завершается с кодом 0 во всех ситуациях, связанных с
зеркалом, и только печатает предупреждения. Он:

- всегда удаляет ключ зеркала и `forkop.list`;
- при включённом зеркале переводит официальные фиды OpenWrt на
  `<зеркало>/openwrt/releases`, как и раньше; если индекс платформ недоступен
  или не знает платформу роутера — предупреждает и фиды не трогает;
- при выключенном зеркале возвращает на `https://downloads.openwrt.org/releases/`
  только фиды, которые сейчас указывают на бывшее зеркало upstream (фиды на
  любом другом хосте не трогаются): берёт резервную копию
  `<файл>.pre-forkop-mirror`, если она есть и сама не указывает на зеркало,
  иначе переписывает префикс адреса (с обратной нормализацией раскладки v25);
- никогда не запускает `apk update` / `opkg update` изнутри сценария пакета.

## Переход с Forkop на Prokop

### Что меняется

Prokop — тот же код под новым именем, поэтому меняются все имена, по которым
его находят пакетный менеджер, UCI, procd и LuCI:

| Forkop | Prokop |
|---|---|
| пакеты `forkop`, `luci-app-forkop`, `luci-i18n-forkop-ru` | `prokop`, `luci-app-prokop`, `luci-i18n-prokop-ru` |
| `/etc/config/forkop` | `/etc/config/prokop` |
| `/etc/forkop`, `/etc/forkop-backups` | `/etc/prokop`, `/etc/prokop-backups` |
| `/usr/bin/forkop`, `/usr/lib/forkop`, `/usr/share/forkop` | `/usr/bin/prokop`, `/usr/lib/prokop`, `/usr/share/prokop` |
| службы `forkop`, `forkop-killswitch`, `forkop-torrserver-direct` | `prokop`, `prokop-killswitch`, `prokop-torrserver-direct` |
| таблицы nftables `Forkop*` | `Prokop*` |
| страница LuCI `admin/services/forkop`, группы ACL `luci-app-forkop(-admin)` | `admin/services/prokop`, `luci-app-prokop(-admin)` |
| канал `https://asofwar.github.io/forkop`, репозиторий `Asofwar/forkop` | `https://asofwar.github.io/prokop`, `Asofwar/prokop` |

Пакеты Prokop не объявляют `Conflicts`/`Replaces` с пакетами Forkop: Prokop
ставится, пока Forkop ещё на месте, чтобы ошибка до удаления Forkop
откатывалась полностью. Одновременно они не работают: `prokop start`
отказывается запускаться, пока служба `forkop` работает или существует таблица
`ForkopTable`, и предлагает запустить установщик. Установленный, но
выключенный Forkop запуску не мешает.

Встроенное обновление Forkop на Prokop не переводит: оно ищет в релизе пакеты
`forkop`, а в релизах Prokop их нет.

### Как перейти

На роутере с Forkop (сборка slayer326/forkop или прежние сборки этого форка,
любая версия 1.0.x) выполните установку Prokop:

```sh
wget -qO- https://asofwar.github.io/prokop/install.sh | sh
# без терминала подтверждение даётся флагом
wget -qO- https://asofwar.github.io/prokop/install.sh | sh -s -- --confirm-legacy-migration
```

Без терминала и без флага установщик ничего не меняет и подсказывает флаг.
Параметры обычной установки (`--mirror`, `--sing-box`, `--lang`) работают и
здесь.

### Что делает установщик

1. Проверки и запись состояния Forkop: включён ли он и работает ли.
2. Резервные копии конфигурации, затем подтверждение.
3. Скачивание пакетов Prokop и сверка SHA-256, установка пакета `prokop` без
   запуска службы.
4. `/etc/config/forkop` копируется в `/etc/config/prokop` (только поверх
   нетронутого конфига из пакета, никогда — поверх изменённого), к нему
   применяется `migration.uc migrate` со всеми миграциями, включая
   `fork_mirror_opt_in_v1` и `prokop_state_paths_v1` (значения, указывающие в
   `/etc/forkop/`, переводятся в `/etc/prokop/`).
5. `/etc/forkop/*` копируется в `/etc/prokop/` (кроме `killswitch/`,
   `vpn-guard/` и `opkg-package-set-recovery/`), `/etc/forkop-backups` — в
   `/etc/prokop-backups`; конфигурация Prokop проверяется.
6. **Точка невозврата.** Forkop выключается своим же кодом. Его остановка
   возвращает dnsmasq в исходное состояние; установщик проверяет, что не
   остался сервер `127.0.0.42`, а оставшиеся опции `dhcp.*.forkop_*`
   переводит в `prokop_*` одной транзакцией.
7. Перед удалением пакетов обезвреживаются разрушительные части старого
   `prerm`: строка-метка управляемой службы sing-box в `/etc/init.d/sing-box`
   переписывается на метку Prokop, чтобы старый `prerm` не удалил
   `/etc/init.d/sing-box`, `/usr/bin/sing-box` и `/usr/lib/libcronet.so`.
   Затем удаляются пакеты Forkop (`luci-i18n-forkop-ru`, `luci-app-forkop`,
   `forkop`).
8. Очистка по явному списку путей (никогда — по шаблону имени): init-скрипты и
   ссылки `rc.d`, каталоги и файлы Forkop, LuCI-файлы, строки cron с меткой
   `# forkop-`, строка `105 forkop` в `rt_tables`, таблицы nftables Forkop
   (кроме kill-switch, см. ниже), службы в `ubus`. Группы ACL в
   `/etc/config/rpcd` переписываются на `luci-app-prokop(-admin)`, кэш LuCI
   сбрасывается, rpcd перезагружается. Резервные копии `*.pre-forkop-mirror`
   и файлы Podkop не трогаются.
9. Установка `luci-app-prokop` и, если был установлен русский перевод Forkop
   или язык LuCI русский, `luci-i18n-prokop-ru`; сохранение настройки зеркала;
   sing-box ставится, только если управляемый бинарник пропал.
10. Prokop включается и запускается так же, как был Forkop; резервные копии
    удаляются только после успеха.

Ход перехода записывается в `/etc/prokop/.migrating-from-forkop`: прерванный
запуск продолжается повторным запуском той же команды, и повтор уже сделанных
шагов ничего не ломает.

Ошибка до точки невозврата откатывает всё: пакеты Prokop и
`/etc/config/prokop` удаляются, Forkop возвращается в записанное состояние.
Ошибка после неё оставляет `/etc/config/prokop` и резервные копии, служба
Prokop остаётся выключенной, установщик печатает пути к копиям и следующие
шаги.

### Kill-switch во время перехода

Политика kill-switch остаётся закрытой всё время перехода. Перед удалением
Forkop служба `forkop-killswitch` останавливается и выключается (это снимает
перенаправление DNS клиентов и резервный dnsmasq), цепочка перенаправления DNS
в старой таблице очищается, чтобы клиентов не отправляло на мёртвый порт, но
сама таблица `ForkopKillswitch` и её include
`/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft` остаются, и
старый `prerm` снять их не может.

Kill-switch Prokop при первой успешной синхронизации (политика применена или
защищать нечего) удаляет `ForkopKillswitch`, этот include и
`/lib/upgrade/keep.d/forkop-killswitch`, одним коммитом `dhcp` с одним
перезапуском dnsmasq переключает `dhcp.@dnsmasq[0].serversfile` с
`/etc/forkop/killswitch/dnsmasq.servers` и только после этого удаляет
`/etc/forkop/killswitch`. Пока `serversfile` указывает туда, каталог не
удаляется. `prokop killswitch_disable`, `prokop killswitch_status` и полное
удаление Prokop знают и старые имена, так что старую политику всегда можно
снять.

### Что переносится и что нет

- Настройки, подписки, списки и наборы правил — через конфиг и
  `/etc/prokop`. Кэш подписок Forkop (ключи `__forkop_*`) отбрасывается, и
  подписки скачиваются заново.
- Снимки конфигурации пишут `prokop_version` и читают `forkop_version`;
  архив `/etc/prokop-backups/configuration.tar.gz`, сделанный Forkop
  (`etc/config/forkop` внутри), восстанавливается.
- Зеркало. Своё зеркало сохраняется в `prokop.settings.mirror_base_url`.
  Если `mirror_base_url` указывал на бывшее зеркало upstream, миграция
  `fork_mirror_opt_in_v1` выключает его и переводит адреса списков и наборов
  правил вида `<бывшее-зеркало>/forkop/lists/...` на прямые источники
  (`raw.githubusercontent.com` для `b4geoip-forkop` и `allow-domains`, GitHub
  Releases и репозитории авторов для наборов правил); подписки и локальные
  файлы не трогаются. `mirror-migration.sh` удаляет ключ и `forkop.list`
  upstream-зеркала и возвращает фиды OpenWrt на официальные адреса; сами
  фиды обновятся при следующем `apk update` / `opkg update`.
- Управляемый sing-box и его состояние (`sing-box-variant`,
  `sing-box-version`); Prokop узнаёт и старую метку службы.
- Лаунчеры Zapret-Manager со старой меткой Prokop распознаёт и пересоздаёт.
- Код DNS Prokop принимает резервные опции `forkop_*` и секцию `dhcp.forkop`,
  если они почему-то остались.
- Настройки страниц в браузере (фильтры мониторинга, цели проверки
  связности, время последней диагностики) читаются по старым ключам один раз
  и переносятся под новые.
- Переход с Podkop и Podkop Plus работает как раньше; на роутерах, где Forkop
  никогда не стоял, шаги перехода не выполняются.

### Проверка после перехода

```sh
apk info 2>/dev/null | grep -E 'forkop|prokop'    # apk: только пакеты prokop
opkg list-installed | grep -E 'forkop|prokop'     # opkg: только пакеты prokop
/etc/init.d/prokop status                         # running, если Forkop работал
ls /etc/init.d/forkop /usr/lib/forkop             # файлов нет
nft list tables | grep -i forkop                  # пусто, когда kill-switch Prokop применён
uci -q get prokop.settings.mirror_base_url        # своё зеркало или пусто
ls /etc/apk/keys/forkop-mirror.pem /etc/apk/repositories.d/forkop.list  # файлов нет
```

## Номера версий

Тег релиза форка — строго `X.Y.Z`: так его понимают сборка, канал и роутер.
Первый релиз Prokop — **2.0.0**: он больше любой версии Forkop 1.0.x, поэтому
переход не выглядит для встроенного обновления и каталога версий как откат.
Номер не должен совпадать ни с одним тегом upstream: локальный клон получает
теги upstream (`git fetch upstream`), и повторный номер означал бы разные
пакеты под одной версией. Перед тегом проверьте `git tag -l X.Y.Z` и
`git ls-remote --tags upstream`.

Пушьте только свой тег: `git push origin X.Y.Z`. `git push --tags` отправил бы
в форк все теги upstream, и **Build packages** собрал и опубликовал бы релиз
для каждого из них.

## Выбор версии и откат

- `releases.json` перечисляет до 8 последних стабильных релизов — ровно те,
  чьи пакеты лежат на сайте. Каждая запись содержит SHA-256 всех шести пакетов.
- Версия, вытесненная более новыми, исчезает с Pages, но остаётся в GitHub
  Releases; её можно поставить вручную, скачав пакеты из релиза.
- Неудачный релиз убирается так: удалите GitHub Release (или отметьте его как
  prerelease) и запустите **Actions → Publish release channel → Run workflow**.
  Канал пересчитает `LATEST`, `latest.json`, `install.sh` и каталог по
  оставшимся релизам. Резерв через GitHub API следует за отметкой «Latest»
  релиза на GitHub — проверьте, что она стоит на нужной версии.

## Первоначальная настройка (владелец репозитория)

1. **Actions.** В форке GitHub по умолчанию выключает workflows: вкладка
   **Actions → I understand my workflows, go ahead and enable them**.
2. **Pages.** **Settings → Pages → Build and deployment → Source: GitHub Actions**,
   или одной командой:

   ```sh
   gh api -X POST repos/Asofwar/prokop/pages -f build_type=workflow
   ```

   GitHub создаст окружение `github-pages`, разрешающее деплой с ветки по
   умолчанию.
3. **Первый релиз.** Тег `X.Y.Z` → `git push origin X.Y.Z`. После
   **Build packages** и **Publish release channel** проверьте
   `https://asofwar.github.io/prokop/updates/latest.json`.
4. Канал можно пересобрать в любой момент вручную через `workflow_dispatch`.

**Переименование репозитория.** Репозиторий раньше назывался `Asofwar/forkop`.
GitHub после переименования перенаправляет на новое имя ссылки на
репозиторий, `git` и API, но не адреса Pages проектов: канал отвечает только
на `https://asofwar.github.io/prokop`, а `https://asofwar.github.io/forkop`
перестаёт работать. Роутеры с Forkop этого форка теряют основной канал и
читают только резерв через GitHub API; на Prokop их переводит команда
установки с новым адресом. Новый репозиторий с именем `forkop` не создавайте:
перенаправления со старого имени перестанут работать.

## Ограничения

- **GitHub Pages:** опубликованный сайт — не больше 1 ГБ, мягкий лимит трафика —
  около 100 ГБ в месяц. 8 релизов по шесть пакетов занимают на порядки меньше,
  но при большом числе пользователей трафик стоит отслеживать.
- **Доступность GitHub из России** нестабильна и меняется со временем:
  `github.io`, `github.com`, `api.github.com` и хосты загрузки ассетов
  (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`)
  могут быть недоступны по отдельности. Резерв для установки — команда через
  GitHub Releases; для зависимостей — своё зеркало; для самого канала —
  тот же бандл на любом статическом хостинге (`ops/hosting/README.md`).
- **GitHub API без токена** ограничен 60 запросами в час с одного IP. Роутер
  обращается к нему только как к резерву, когда канал недоступен.
- **Откат** зависит от доступности Pages (см. выше).
