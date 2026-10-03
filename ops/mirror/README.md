# Optional dependency mirror

Prokop does not need a mirror. Releases come from the fork's own channel
(`https://asofwar.github.io/prokop`, falling back to the GitHub releases of
`Asofwar/prokop`), and without a mirror every router uses the official OpenWrt
feeds and the original list, rule-set, sing-box-extended and Zapret-Manager
sources. The scripts here let the fork owner (or anyone) run a self-hosted
accelerator for those dependencies, for networks where the original hosts are
slow or unreachable.

A router uses a mirror only after an explicit opt-in:

```sh
wget -qO- https://asofwar.github.io/prokop/install.sh | sh -s -- --mirror https://mirror.example.org
# or, on an installed router:
uci set prokop.settings.mirror_base_url=https://mirror.example.org && uci commit prokop
/usr/share/prokop/mirror-migration.sh
```

`router-bootstrap.sh MIRROR_URL` is a wrapper around the first command. There
is no default mirror: an empty `mirror_base_url` means "disabled", and the
installer and packages never substitute a host. The legacy upstream mirrors
(`mirror.infotechtg.ru`, `mirror.51343.ru`) are recognised only to clean them
out of existing configurations and package feeds.

The router does not trust anything signed by a mirror. Neither the installer
nor the packages download `<mirror>/forkop/forkop-apk.pem` into
`/etc/apk/keys` or write `/etc/apk/repositories.d/forkop.list`, and both remove
`/etc/apk/keys/forkop-mirror.pem` and that feed when they find them: apk trusts
every key in `/etc/apk/keys` for every repository, and a mirror's Prokop feed
would replace the fork's packages with whatever the mirror builds. A mirror
only ever serves OpenWrt packages, lists and third-party components; Prokop
packages always come from the release channel, verified against its SHA-256
metadata.

## URL layout keeps the upstream `forkop` names

Prokop is the renamed Forkop, but a mirror keeps the URL layout of the
upstream Forkop mirrors, because routers and those mirrors share it as a
protocol: lists under `<mirror>/forkop/lists/...` (including `b4geoip-forkop`),
sing-box-extended metadata under `<mirror>/forkop/sing-box-extended/...`, the
release copies under `<mirror>/forkop/...` and the platform index
`<mirror>/openwrt/forkop-platforms.tsv`. That is why the default `MIRROR_ROOT`
of the sync scripts still ends in `/public/forkop`. Do not rename these public
paths: Prokop routers request exactly them.

## Upgrading a mirror host set up before the rename

The public URLs stay the same, but the host-side names of the scripts and
services changed from `forkop` to `prokop`. When you deploy the renamed
scripts on an existing host, move the host configuration with them:

| Before | After |
|---|---|
| `forkop-*.service`, `forkop-*.timer` | `prokop-*.service`, `prokop-*.timer` (disable the old units first) |
| `sync-forkop.sh`, `sync-forkop-release.py`, `publish-forkop-feed.sh`, `update-forkop-from-git.sh`, `/usr/local/sbin/sync-forkop-mirror` | `sync-prokop.sh`, `sync-prokop-release.py`, `publish-prokop-feed.sh`, `update-prokop-from-git.sh`, `/usr/local/sbin/sync-prokop-mirror` |
| `/etc/default/forkop-openwrt-mirror` | `/etc/default/prokop-openwrt-mirror` |
| `/etc/forkop-mirror/platforms.conf` | `/etc/prokop-mirror/platforms.conf` |
| `/mnt/storage/forkop-mirror`, user and group `forkop-mirror` | `/mnt/storage/prokop-mirror`, user and group `prokop-mirror` |
| compose project and container `forkop-zapret-cache` | `prokop-zapret-cache` (also in the Caddyfile `reverse_proxy`) |
| `FORKOP_*` environment variables (`FORKOP_GITHUB_REPOSITORY`, `FORKOP_APK_PRIVATE_KEY`, ...) | `PROKOP_*` with the same suffix |

Move the platform list before the first run of the renamed `sync-openwrt.sh`:
without `/etc/prokop-mirror/platforms.conf` (or `OPENWRT_PLATFORMS_FILE`) it
falls back to the single-platform default and publishes an index that lists
only that platform, so routers on the other platforms would leave their feeds
alone. The default release repository is now `Asofwar/prokop`; GitHub
redirects API requests for `Asofwar/forkop`, but set the new name explicitly.

## OpenWrt feeds

`sync-openwrt.sh` mirrors the OpenWrt target, kernel, and package feeds needed by
Prokop. Supported platforms are configured with one target/architecture pair per
line. Blank lines, full-line comments, and trailing comments are accepted:

```text
mediatek/filogic aarch64_cortex-a53
rockchip/armv8 aarch64_generic
# Optional examples:
x86/64 x86_64
ramips/mt7621 mipsel_24kc
```

The `rockchip/armv8 aarch64_generic` mapping is published by OpenWrt in the
[`24.10.6`](https://downloads.openwrt.org/releases/24.10.6/targets/rockchip/armv8/profiles.json)
and [`25.12.3`](https://downloads.openwrt.org/releases/25.12.3/targets/rockchip/armv8/profiles.json)
target profiles.

Copy `openwrt-platforms.conf.example` to
`/etc/prokop-mirror/platforms.conf`, copy `openwrt-mirror.env.example` to
`/etc/default/prokop-openwrt-mirror`, and run the systemd service. The
environment file is optional. Without a configured file, the script retains the
legacy single-platform default (`mediatek/filogic aarch64_cortex-a53`). Existing
`OPENWRT_TARGET` and `OPENWRT_ARCH` variables also retain their single-platform
behavior.

After every completely successful run, the script atomically publishes
`/openwrt/forkop-platforms.tsv`. Each row contains:

```text
target<TAB>architecture<TAB>release<TAB>format
```

When a mirror is enabled, the installer and the package scripts read this index
before they change any package feed, and leave the feeds untouched when the
index is unreachable or does not list the router's release and architecture.
The exact release and kernel ABI in an existing feed URL are preserved, and
third-party firmware feeds are not replaced. When the mirror is disabled again,
feeds that point at a legacy upstream mirror are restored to
`https://downloads.openwrt.org`; feeds on any other host are left alone.

The synchronization configuration in this directory includes OpenWrt
**24.10.0, 24.10.1, 24.10.5 and 25.12.5** for Filogic and Rockchip. These are
planned combinations, not a promise that all files have already finished
downloading; consult the live platform index before pointing routers at it.

Adding a line can require substantial storage: every target has its own package
and kernel ABI trees, while package feeds are downloaded once per unique
architecture. A merged code change does not enable a platform on a mirror; the
mirror operator must update the production configuration and finish a full
successful synchronization first.

## Prokop release copies

`sync-prokop.sh` and `sync-prokop-release.py` copy the latest stable release of
`PROKOP_GITHUB_REPOSITORY` (default `Asofwar/prokop`); the latter verifies the
declared size and SHA-256 digest of every asset and calls
`publish-prokop-feed.sh` to build a signed APK repository under
`/forkop/mirror/current/`. `update-prokop-from-git.sh` rebuilds a tag from Git
and refuses sources that do not follow releases of that repository. These
copies are for browsing or manual use only: Prokop routers never add that feed
or its key (see above), and the release channel is not served from a mirror.
Run the release service with `prokop-release-sync.service` after placing the
OpenWrt host `apk` tool at the configured path; it does not build packages on
the mirror host.

## Zapret-Manager cache (home mirror)

`home/zapret-compose.yml` runs a separate, non-root Python service with no published
host ports, 128 MiB RAM, 0.25 CPU and 32 PIDs. Its cache is limited to 2 GiB/512
entries, downloads to 128 MiB, and request workers to eight. Only the repositories
listed in `zapret-manager-cache.py` and the two Routerich feed directories are
accepted. Redirect destinations and resolved public IP addresses are checked;
TLS still verifies the original hostname. No credentials or request URLs are logged.
The cache container uses its own public DNS resolvers (1.1.1.1/8.8.8.8), since
the home LAN resolver can return Fake-IP addresses. Host and other containers'
DNS settings are not changed.

The entry script served from Screamshow/Zapret-Manager is adapted to default to
the mirror's own public URL, including after it recreates its own launchers.
Set it in `ZAPRET_MANAGER_MIRROR` (for example in an `.env` file next to the
compose file); the service refuses to start without it. Routers without a
configured mirror run Zapret-Manager directly from GitHub and never see this
cache. This is a download cache, not validation or endorsement of every
optional action in the third-party manager. Some optional tools still use their
original external URLs; do not claim the manager is completely offline or
install it unattended.

On a home deployment, use the pinned, locally available Python image
in `home/zapret-compose.yml`. Install the script/config under
`/mnt/storage/prokop-mirror/config/` and create only
`/mnt/storage/prokop-mirror/data/cache/zapret-manager` owned by 65534:65534.
Start the separate compose project, warm the manager endpoint, and validate
`home/web-with-zapret.Caddyfile` before applying it to the mirror's own web service.
Back up its old Caddyfile first. Never restart a shared edge Caddy or other
projects. Rollback: restore that Caddyfile, restart only
`prokop-mirror-web.service`, then stop only the cache compose project.

## Releases

Releases are not published through a mirror. Release branches `codex/release-*`
build downloadable candidate artifacts without publishing; a strict `X.Y.Z` tag
builds and publishes a GitHub release, and the Pages workflow republishes the
channel (see `ops/hosting/README.md`). Tag publication is gated by backend and
frontend tests. A real OpenWrt router smoke test (upgrade, arbitrary HTTPS
subscription, URLTest/Priority, latency, reload and reboot recovery) is still
required before tagging a stable release.
