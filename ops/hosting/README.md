# Канал релизов Forkop на GitHub Pages

Установщик и встроенное обновление форка читают статический канал
`https://asofwar.github.io/forkop`. Его целиком собирает
`ops/pages/build-site.py` из GitHub Releases репозитория `Asofwar/forkop`,
а публикует workflow `.github/workflows/pages.yml`.

## Как появляется релиз

1. Тег `X.Y.Z` (строго три числа) запускает workflow **Build packages**: тесты,
   сборка пакетов `ipk`/`apk`, GitHub Release с шестью пакетами, `install.sh`
   из того же коммита и архивом `forkop-timeweb-X.Y.Z.tar.gz`.
2. После успешного завершения **Build packages** запускается
   **Publish release channel** (`pages.yml`, событие `workflow_run`). Он
   скачивает пакеты последних 8 стабильных релизов, сверяет их с SHA-256,
   который GitHub указывает для каждого файла, и заново раскладывает весь сайт.
3. Если пакета не хватает или контрольная сумма не совпала в самом новом
   релизе, сборка падает и на Pages остаётся предыдущая версия сайта:
   частичный канал не публикуется. Такой же дефект в более старом релизе
   только исключает этот релиз из канала (с предупреждением в логе), а его
   место занимает следующий полный релиз.

Канал можно пересобрать вручную: **Actions → Publish release channel → Run
workflow** (только с ветки по умолчанию — так требует окружение
`github-pages`).

## Структура канала

```text
https://asofwar.github.io/forkop/
├── index.html               страница с командой установки
├── install.sh               установщик из самого нового релиза
├── LATEST                   номер самой новой версии
├── updates/
│   ├── latest.json          метаданные самой новой версии (sha256 пакетов)
│   └── releases.json        каталог версий для выбора и отката в LuCI
└── releases/
    └── X.Y.Z/
        ├── forkop_X.Y.Z.ipk
        ├── luci-app-forkop_X.Y.Z.ipk
        ├── luci-i18n-forkop-ru_X.Y.Z.ipk
        ├── forkop_X.Y.Z.apk
        ├── luci-app-forkop_X.Y.Z.apk
        ├── luci-i18n-forkop-ru_X.Y.Z.apk
        └── SHA256SUMS
```

`latest.json` и `releases.json` имеют ровно тот формат, который пишут
`prepare-release.sh` и `build-release-catalog.py`; ссылки на пакеты в них
абсолютные и ведут внутрь `releases/X.Y.Z/`. В каталоге перечислены только
версии, которые действительно лежат на сайте, поэтому откатиться можно на
любую из последних 8.

## Проверка после публикации

- `https://asofwar.github.io/forkop/install.sh`
- `https://asofwar.github.io/forkop/updates/latest.json`
- `https://asofwar.github.io/forkop/updates/releases.json`
- `https://asofwar.github.io/forkop/releases/X.Y.Z/SHA256SUMS`

## Локальная сборка сайта

```sh
GITHUB_TOKEN=... python3 ops/pages/build-site.py --output /tmp/forkop-site
```

Параметры по умолчанию: репозиторий `Asofwar/forkop`
(`--repository` или `FORKOP_RELEASE_REPO`), адрес канала
`https://asofwar.github.io/forkop` (`--base-url` или
`FORKOP_RELEASE_BASE_URL`), 8 последних релизов (`--limit`). Для проверки без
сети есть `--releases-json FILE` и `--assets-dir DIR` (файлы
`DIR/X.Y.Z/<имя>`), см. `tests/fork_pages_site.sh`.

## Другой статический хостинг

Тот же канал можно выложить на любой статический хостинг. Каждый релиз
содержит архив `forkop-timeweb-X.Y.Z.tar.gz` (артефакт сборки
`timeweb-files-X.Y.Z`), подготовленный `prepare-release.sh`; в CI он собирается
для адреса `https://asofwar.github.io/forkop`. Для своего адреса подготовьте
архив локально и распакуйте его в корень сайта так, чтобы получился каталог
`forkop/`:

```sh
FORKOP_RELEASE_BASE_URL=https://example.com/forkop \
  ./ops/hosting/prepare-release.sh X.Y.Z filtered-bin/release filtered-bin/hosting
```

Каждый новый архив заменяет `install.sh`, `LATEST` и `updates/*.json`; старые
каталоги `releases/` оставляйте — на них ссылается каталог для отката.
Установщику адрес передаётся переменной окружения:

```sh
wget -qO- https://example.com/forkop/install.sh | FORKOP_RELEASE_BASE_URL=https://example.com/forkop sh
```

Встроенное обновление на роутере читает адрес по умолчанию
`FORKOP_RELEASE_BASE_URL` из `forkop/files/usr/lib/core/constants.uc`; чтобы
оно следовало за другим хостингом, этот адрес меняется в собранных пакетах.
