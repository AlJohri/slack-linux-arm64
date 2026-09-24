# slack-linux-arm64

Build an installable **aarch64 RPM of Slack Desktop** from Slack's official
x86_64 release. Written for Fedora Asahi Remix on Apple Silicon, and usable on
any aarch64 Fedora.

Slack publishes no arm64 Linux client. Its own download path is
`desktop-releases/linux/x64/`, its RPM repository serves an aarch64 directory
whose metadata is empty, and the Flathub package runs on
`org.freedesktop.Platform/x86_64`. Flathub closed the arm64 request as
[not planned](https://github.com/flathub/com.slack.Slack/issues/228).

## Why a repack works

Slack is an Electron app, and it ships **stock Electron**. In Slack 4.50.143,
`resources.pak`, `icudtl.dat` and both `chrome_*_percent.pak` files are
byte-identical to the upstream Electron release. The JS application in
`app.asar` is architecture-independent. Slack even publishes an arm64 build of
its one proprietary native module on its own S3 bucket.

So the arm64 package is Slack's own application on upstream Electron for
arm64. Only three kinds of file change:

| What | Where it comes from |
| --- | --- |
| Electron binaries and V8 snapshots | the official `electron-v<ver>-linux-arm64.zip` |
| `slackdesktoputils.node` | Slack's own arm64 prebuild |
| three other native modules | built from npm source on your machine |

`app.asar` is never modified, and the build fails if its checksum changes.

## Usage

```sh
# Fedora
sudo dnf install rpm-build gcc-c++ make nodejs npm cpio unzip patch \
                 binutils file jq libX11-devel libxkbfile-devel

./build.sh                            # current Slack release
./build.sh --slack-version 4.52.155   # a specific one

sudo dnf install dist/slack-*.aarch64.rpm
```

Run `./build.sh --help` for the rest of the options.

## It also fixes the tray icon

Slack 4.52.155 bundles Electron 44.0.0, which carries a Chromium regression
introduced in 43.4.1. The tray item registers itself by passing its bus name
with the object path concatenated onto the end:

```
RegisterStatusNotifierItem("org.freedesktop.StatusNotifierItem-<pid>-1/StatusNotifierItem/1")
```

The spec says that argument is the bus name and nothing else, so every
conforming StatusNotifierWatcher rejects it and no icon ever appears. This is
[electron/electron#53213][tray], fixed in Electron 44.1.0. A Slack user cannot
do anything about the runtime their package bundles. A repack picks it.

So when the bundled Electron falls inside the broken range `[43.4.1, 44.1.0)`,
the build substitutes the newest release in the same major and says so:

```
==> Slack bundles Electron 44.0.0
==> Electron 44.0.0 has the tray-registration bug; using 44.4.5
```

Three limits keep that conservative. It acts only inside the known-broken
range. It never crosses a major, because swapping the Chromium major under
Slack's own JS is a larger risk than a missing icon — a 43.x stays on 43.x with
a warning. And `--electron-version` overrides the whole thing.

Both versions are recorded in the package, so `rpm -qi slack` reports what was
actually linked. `/usr/lib/slack/version` is Slack's own file and is left
alone, which means it names the Electron Slack intended, not the one in use.

[tray]: https://github.com/electron/electron/issues/53213

## What the build verifies

It refuses to produce a package unless all of these hold:

- The Electron archive matches the SHA-256 published in the release's
  `SHASUMS256.txt`.
- No x86-64 object remains anywhere in the tree.
- Every ELF object is aarch64, and every `LOAD` segment is aligned to at least
  the running kernel's page size. **Asahi kernels use 16K pages**, and a binary
  aligned for 4K pages will not map at all.
- `app.asar` has the same checksum as in the source RPM.
- The built binary runs and reports the expected Slack version.

## The native-module substitutions, and what they cost

**`native-keymap`.** Slack bundles the private fork
`@tinyspeck/native-keymap@2.2.3`. Public npm has no 2.2.3 at all; it goes from
2.2.2 to 2.3.0. This builds public 2.2.2 and applies
`patches/native-keymap-2.2.2-ignore-all-events.patch`, which restores the one
function the fork adds. Slack calls it once, on quit. The Linux implementation
is a no-op because the upstream X11 backend registers no layout-change
listener.

**Four platform modules.** `cf-prefs`, `registry-js`, `windows-focus-assist`
and `macos-notification-state` are macOS-only or Windows-only. Their shipped
x86_64 builds already export no callable symbol on Linux, and the JS that loads
them guards on `process.platform`. They are replaced with an N-API module that
registers nothing.

## Known gaps

- `electron-native-auth` has no `package.json` inside `app.asar`, so its
  version cannot be read and the build takes the current npm release.
- Screen sharing and huddles are untested.
- Slack's daily updater is neutered on purpose: it would point dnf at a
  repository with no aarch64 packages. Re-run `build.sh` to update.
- Rebuilding the same Slack version produces the same NEVRA, so `dnf install`
  is a no-op on it. Use `dnf reinstall` to pick up a runtime change.

## Prior art

The method was worked out in
[hamza72x/slack-linux-arm64](https://github.com/hamza72x/slack-linux-arm64),
and an audit of its 4.50.143 package confirms it works: the input RPM matches
Slack's published download, `app.asar` is byte-identical to the official
package, every Electron file matches the upstream `linux-arm64` release,
`slackdesktoputils.node` matches Slack's own arm64 prebuild, and no x86-64
object survives anywhere in the tree.

The difference that matters is the tray icon. That build uses whichever
Electron version Slack bundles, which for 4.52.155 is 44.0.0 -- one of the
releases that cannot register a StatusNotifierItem, so the icon never appears
on KDE, GNOME or waybar. This build substitutes a fixed release in the same
major, which is the one thing a repack can fix and an ordinary Slack install
cannot.

Three smaller differences. That repository commits its inputs and outputs,
about 300MB per Slack release, for a 485MB history across 2005 files; only
build scripts are committed here. Its `slack-<version>-arm64.tar.xz` ships the
`cron.daily` repository-config script under the name `slack` instead of the
Electron binary, so the documented `./slack` tries to import RPM keys -- its
RPM is unaffected, and this repository builds only the RPM. And it builds
public `native-keymap` 2.5.0 where Slack bundles the private fork 2.2.3, losing
`ignoreAllEvents`; here 2.2.2 is pinned and patched to restore it.

## License

Slack Desktop is proprietary and is covered by Slack's own license. Electron is
MIT, and `native-keymap` is MIT, Copyright (c) Microsoft Corporation. Neither is
redistributed here: every input is downloaded from its vendor at build time.
