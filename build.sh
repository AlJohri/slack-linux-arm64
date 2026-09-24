#!/usr/bin/env bash
#
# Repack the official Slack desktop RPM (x86_64) as an installable aarch64 RPM.
#
# Slack is an Electron app. Its JS bundle is architecture-independent, and the
# Electron runtime it ships is stock. Only the Electron binaries, the V8
# snapshots and the native Node modules have to be replaced.
#
# Nothing from Slack is redistributed by this repository. Every input is
# downloaded at build time from its vendor.

set -euo pipefail

# Public native-keymap has no 2.2.3; Slack's fork is private. 2.2.2 is its
# immediate predecessor, and patches/ restores the one function the fork adds.
NATIVE_KEYMAP_VERSION=2.2.2

# Electron 43.4.1 through 44.0.x register the tray item by passing the bus name
# with the object path concatenated onto it, which every spec-conforming
# StatusNotifierWatcher rejects, so no tray icon appears at all. Fixed in 44.1.0
# by electron/electron#53214; electron/electron#53213 has the detail. An ordinary
# Slack user cannot do anything about the runtime their package bundles, but a
# repack picks it, so a bundled version inside the broken range is replaced with
# the newest release in the same major.
ELECTRON_TRAY_BUG_FIRST=43.4.1
ELECTRON_TRAY_BUG_FIXED=44.1.0

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SLACK_API=https://slack.com/api/desktop.latestRelease
ELECTRON_RELEASES=https://github.com/electron/electron/releases/download

slack_version=""
electron_override=""
out_dir="$SELF_DIR/dist"
work_dir=""
keep_work=0

usage() {
  cat <<'EOF'
Usage: build.sh [options]

  --slack-version <ver>  Slack version to repack (default: current release)
  --electron-version <v> Electron to use (default: what Slack bundles, unless
                         that version has the tray-registration bug)
  --out-dir <dir>        Where to write the RPM (default: ./dist)
  --work-dir <dir>       Build directory (default: a temporary directory)
  --keep                 Keep the build directory
  -h, --help             This message

Downloads are cached in ${XDG_CACHE_HOME:-~/.cache}/slack-linux-arm64 and
re-used across runs.
EOF
}

log()  { printf '==> %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --slack-version) slack_version="${2:?}"; shift 2 ;;
    --electron-version) electron_override="${2:?}"; shift 2 ;;
    --out-dir)       out_dir="${2:?}";      shift 2 ;;
    --work-dir)      work_dir="${2:?}";     shift 2 ;;
    --keep)          keep_work=1;           shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage >&2; die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- environment

[ "$(uname -m)" = "aarch64" ] || die "this script builds on aarch64; found $(uname -m)"

missing=()
for c in curl jq gcc g++ make node npm npx rpmbuild rpm2cpio cpio unzip tar patch pkg-config readelf file; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[ ${#missing[@]} -eq 0 ] || die "missing commands: ${missing[*]} (dnf install rpm-build gcc-c++ make nodejs npm cpio unzip patch binutils file jq)"

pkg-config --exists x11 xkbfile \
  || die "missing X11 headers: dnf install libX11-devel libxkbfile-devel"

if [ -n "$work_dir" ]; then
  mkdir -p "$work_dir"
  work_dir=$(cd "$work_dir" && pwd)
else
  # Not /tmp: it is tmpfs on most systems, so this build would run in RAM and
  # can hit a per-user quota. /var/tmp is disk-backed and is where the FHS puts
  # large temporary data. TMPDIR still wins if the caller set it.
  work_dir=$(mktemp -d -p "${TMPDIR:-/var/tmp}" slack-arm64-XXXXXX)
  [ "$keep_work" -eq 1 ] || trap 'rm -rf "$work_dir"' EXIT
fi
log "build directory: $work_dir"

# The Slack tree is extracted twice -- once to modify, once into the RPM
# buildroot -- alongside the unpacked Electron archive and the finished package.
# Checking up front turns "no space left on device" halfway through an extract
# into a sentence that names the directory to fix.
required_mb=3072
avail_mb=$(df -Pm "$work_dir" | awk 'NR==2 {print $4}')
if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$required_mb" ]; then
  die "need ~${required_mb}MB free for the build, $work_dir has ${avail_mb}MB (use --work-dir or set TMPDIR)"
fi

# Outside the build directory, which is temporary: the Slack RPM and the Electron
# archive are ~230MB together and neither changes once published.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/slack-linux-arm64"
mkdir -p "$cache"

# Re-uses a cached file when it is already complete. curl -C - resumes a partial
# download and exits 33 on a server that refuses a range request, which for a
# complete file means there is nothing left to fetch.
fetch() {
  local url=$1 dest=$2
  [ -s "$dest" ] && { log "cached: $(basename "$dest")"; return 0; }
  log "downloading $(basename "$dest")"
  curl -fSL --retry 3 --progress-bar "$url" -o "$dest"
}

# ------------------------------------------------------- 1. resolve the inputs

step "Resolving the Slack release"
if [ -z "$slack_version" ]; then
  release=$(curl -fsS "$SLACK_API?arch=x64&variant=rpm")
  [ "$(jq -r .ok <<<"$release")" = "true" ] || die "Slack release API returned: $release"
  slack_version=$(jq -r .version <<<"$release")
  slack_url=$(jq -r .download_url <<<"$release")
else
  slack_url="https://downloads.slack-edge.com/desktop-releases/linux/x64/${slack_version}/slack-${slack_version}-0.1.el8.x86_64.rpm"
fi
log "Slack $slack_version"

src_rpm="$cache/slack-${slack_version}-0.1.el8.x86_64.rpm"
fetch "$slack_url" "$src_rpm"

step "Extracting the x86_64 RPM"
root="$work_dir/root"
rm -rf "$root"; mkdir -p "$root"
(cd "$root" && rpm2cpio "$src_rpm" | cpio -idm --quiet)

slack_lib="$root/usr/lib/slack"
[ -d "$slack_lib" ] || die "unexpected RPM layout: no usr/lib/slack"

bundled_electron=$(cat "$slack_lib/version")
electron_version="$bundled_electron"
log "Slack bundles Electron $bundled_electron"

# True when $1 sorts strictly before $2.
ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

newest_in_major() {
  curl -fsS "https://api.github.com/repos/electron/electron/releases?per_page=100" 2>/dev/null \
    | jq -r --arg m "$1" '.[].tag_name | select(test("^v" + $m + "\\.[0-9]+\\.[0-9]+$"))' \
    | sed 's/^v//' | sort -V | tail -1
}

if [ -n "$electron_override" ]; then
  electron_version="$electron_override"
  log "Electron pinned to $electron_version by --electron-version"
elif ! ver_lt "$bundled_electron" "$ELECTRON_TRAY_BUG_FIRST" \
     && ver_lt "$bundled_electron" "$ELECTRON_TRAY_BUG_FIXED"; then
  major=${bundled_electron%%.*}
  if [ "$major" = "${ELECTRON_TRAY_BUG_FIXED%%.*}" ]; then
    newest=$(newest_in_major "$major")
    if [ -n "$newest" ] && ! ver_lt "$newest" "$ELECTRON_TRAY_BUG_FIXED"; then
      electron_version="$newest"
      log "Electron $bundled_electron has the tray-registration bug; using $electron_version"
    else
      log "WARNING: could not resolve a fixed Electron $major.x; keeping $bundled_electron (no tray icon)"
    fi
  else
    # Crossing a major to dodge the bug is a bigger change than a missing icon.
    log "WARNING: Electron $bundled_electron has the tray-registration bug and the fix"
    log "         is in ${ELECTRON_TRAY_BUG_FIXED%%.*}.x; keeping it. Expect no tray icon."
  fi
fi
log "Building against Electron $electron_version"

# app.asar is the whole JS application. It is never modified, and the
# verification step below proves it.
asar_before=$(sha256sum "$slack_lib/resources/app.asar" | cut -d' ' -f1)

step "Reading the bundled native module versions"
asar_dir="$work_dir/asar"
rm -rf "$asar_dir"
npx --yes @electron/asar extract "$slack_lib/resources/app.asar" "$asar_dir"

module_version() { jq -r '.version' "$asar_dir/node_modules/$1/package.json"; }
sdu_version=$(module_version @tinyspeck/slack-desktop-utils)
napi_version=$(jq -r '.binary.napi_versions[0]' "$asar_dir/node_modules/@tinyspeck/slack-desktop-utils/package.json")
sdu_host=$(jq -r '.binary.production_host' "$asar_dir/node_modules/@tinyspeck/slack-desktop-utils/package.json")
fhi_version=$(module_version file-handler-info)
keymap_shipped=$(module_version @tinyspeck/native-keymap)
log "slack-desktop-utils $sdu_version (napi-v$napi_version), file-handler-info $fhi_version"
log "native-keymap: Slack ships $keymap_shipped (private fork), building public $NATIVE_KEYMAP_VERSION + patch"

# ------------------------------------------------- 2. swap the Electron runtime

step "Fetching Electron $electron_version for linux-arm64"
electron_zip="$cache/electron-v${electron_version}-linux-arm64.zip"
fetch "$ELECTRON_RELEASES/v${electron_version}/electron-v${electron_version}-linux-arm64.zip" "$electron_zip"
fetch "$ELECTRON_RELEASES/v${electron_version}/SHASUMS256.txt" "$cache/SHASUMS256-${electron_version}.txt"

log "verifying the Electron archive against the published checksums"
expected=$(awk -v f="*electron-v${electron_version}-linux-arm64.zip" '$2==f{print $1}' \
  "$cache/SHASUMS256-${electron_version}.txt")
[ -n "$expected" ] || die "no checksum published for electron-v${electron_version}-linux-arm64.zip"
actual=$(sha256sum "$electron_zip" | cut -d' ' -f1)
[ "$expected" = "$actual" ] || die "Electron checksum mismatch: expected $expected, got $actual"
log "checksum ok"

electron_dir="$work_dir/electron"
rm -rf "$electron_dir"; mkdir -p "$electron_dir"
unzip -q "$electron_zip" -d "$electron_dir"

step "Replacing the architecture-specific Electron files"
# The main binary ships as `electron` and Slack renames it.
install -m 0755 "$electron_dir/electron" "$slack_lib/slack"

# The rest of the set moves between Electron majors -- 44 dropped libEGL.so and
# libGLESv2.so when ANGLE stopped shipping as separate libraries -- so it is
# discovered rather than listed: every ELF object Electron ships beside the
# binary, plus the two V8 snapshots, which are architecture-specific blobs
# rather than ELF.
#
# Everything skipped here is architecture-independent. locales/*.pak stay
# because Slack's carry its own strings; resources.pak, icudtl.dat and the
# chrome_*_percent.pak files stay because Slack ships Electron's own copies
# unchanged, so replacing them is a no-op.
replaced=0
for src in "$electron_dir"/*; do
  [ -f "$src" ] || continue
  name=$(basename "$src")
  case "$name" in electron|version|LICENSE*) continue ;; esac
  [ -e "$slack_lib/$name" ] || continue
  case "$name" in
    snapshot_blob.bin|v8_context_snapshot.bin) ;;
    *) file -b "$src" | grep -q '^ELF' || continue ;;
  esac
  cp -f "$src" "$slack_lib/$name"
  replaced=$((replaced + 1))
  log "replaced $name"
done
[ "$replaced" -gt 0 ] || die "no architecture-specific file matched; Electron layout changed"

[ -e "$slack_lib/chrome-sandbox" ] && chmod 4755 "$slack_lib/chrome-sandbox"

# ------------------------------------------------- 3. rebuild the native modules

unpacked="$slack_lib/resources/app.asar.unpacked/node_modules"

step "Building native modules from source"
ws="$work_dir/native"
rm -rf "$ws"; mkdir -p "$ws"

# electron-native-auth is not declared in the asar, so its version cannot be
# read. file-handler-info is, and is pinned to what Slack ships.
cat > "$ws/package.json" <<EOF
{
  "name": "slack-arm64-native",
  "version": "0.0.0",
  "private": true,
  "dependencies": {
    "electron-native-auth": "*",
    "file-handler-info": "$fhi_version"
  }
}
EOF
(cd "$ws" && npm install --build-from-source --no-audit --no-fund --loglevel=error)

install -m 0755 "$ws/node_modules/electron-native-auth/build/Release/electron_native_auth.node" \
  "$unpacked/electron-native-auth/build/Release/electron_native_auth.node"
install -m 0755 "$ws/node_modules/file-handler-info/build/Release/file_handler_info.node" \
  "$unpacked/file-handler-info/build/Release/file_handler_info.node"

step "Building native-keymap $NATIVE_KEYMAP_VERSION with the ignoreAllEvents patch"
km="$work_dir/native-keymap"
rm -rf "$km"; mkdir -p "$km"
(cd "$km" && npm pack "native-keymap@$NATIVE_KEYMAP_VERSION" --silent >/dev/null)
tar xzf "$km/native-keymap-$NATIVE_KEYMAP_VERSION.tgz" -C "$km"
patch -p2 -d "$km/package" --no-backup-if-mismatch \
  < "$SELF_DIR/patches/native-keymap-$NATIVE_KEYMAP_VERSION-ignore-all-events.patch"
(cd "$km/package" && npx --yes node-gyp rebuild --release)
install -m 0755 "$km/package/build/Release/keymapping.node" \
  "$unpacked/@tinyspeck/native-keymap/build/Release/keymapping.node"

step "Fetching Slack's own arm64 build of slack-desktop-utils"
sdu_tgz="$cache/slackdesktoputils-v${sdu_version}-napi-v${napi_version}-linux-arm64.tar.gz"
fetch "$sdu_host/slackdesktoputils-v${sdu_version}-napi-v${napi_version}-linux-arm64.tar.gz" "$sdu_tgz"
sdu_dir="$work_dir/sdu"
rm -rf "$sdu_dir"; mkdir -p "$sdu_dir"
tar xzf "$sdu_tgz" -C "$sdu_dir"
sdu_node=$(find "$sdu_dir" -name 'slackdesktoputils.node' -print -quit)
[ -n "$sdu_node" ] || die "no slackdesktoputils.node in the prebuild archive"
install -m 0755 "$sdu_node" \
  "$unpacked/@tinyspeck/slack-desktop-utils/lib/binding/napi-v${napi_version}/slackdesktoputils.node"

step "Compiling the platform stubs"
stub="$work_dir/empty_module.node"
gcc -shared -fPIC -O2 -o "$stub" "$SELF_DIR/stubs/empty_napi_module.c"
for p in cf-prefs/build/Release/cf-prefs.node \
         registry-js/build/Release/registry.node \
         windows-focus-assist/build/Release/focusassist.node \
         macos-notification-state/build/Release/notificationstate.node; do
  [ -f "$unpacked/$p" ] || die "expected bundled module is absent: $p"
  install -m 0755 "$stub" "$unpacked/$p"
done

# ------------------------------------------------------- 4. fix packaging bits

step "Adjusting the packaged scripts"
cron="$root/etc/cron.daily/slack"
if [ -f "$cron" ]; then
  # Slack publishes no aarch64 packages, so the repo it would add to dnf serves
  # nothing and every run reports an error.
  sed -i \
    -e 's/^DEFAULT_ARCH="x86_64"/DEFAULT_ARCH="aarch64"/' \
    -e 's/^\( *\)DEFAULT_ARCH="x86_64"/\1DEFAULT_ARCH="aarch64"/' \
    -e 's|^REPOCONFIG=.*|REPOCONFIG=""|' \
    -e 's/\[ "\$DEFAULT_ARCH" = "x86_64" \]/[ "$DEFAULT_ARCH" = "x86_64" ] || [ "$DEFAULT_ARCH" = "aarch64" ]/' \
    "$cron"
  grep -q 'DEFAULT_ARCH="x86_64"' "$cron" && die "cron.daily/slack still names x86_64"
fi

# Build-ids index the original x86_64 objects and match nothing now.
rm -rf "$root/usr/lib/.build-id"

# ------------------------------------------------------------- 5. verification

step "Verifying the result"
fail=0

log "checking that no x86-64 object survived"
if leftover=$(find "$root" -type f -exec file -b --mime-type {} \; -print \
    | paste - - | grep -E '^application/x-(executable|sharedlib|pie-executable)' \
    | cut -f2 | xargs -r file | grep 'x86-64'); then
  printf '%s\n' "$leftover" >&2
  fail=1
fi

log "checking that every ELF object is aarch64 and maps on a 16K-page kernel"
page_size=$(getconf PAGESIZE)
while IFS= read -r f; do
  case $(file -b "$f") in
    *"ARM aarch64"*) ;;
    *) printf 'not aarch64: %s\n' "$f" >&2; fail=1; continue ;;
  esac
  align=$(readelf -lW "$f" 2>/dev/null | awk '/LOAD/{print strtonum($NF)}' | sort -n | head -1)
  if [ -n "$align" ] && [ "$align" -lt "$page_size" ]; then
    printf 'segment alignment %s is below the %s page size: %s\n' "$align" "$page_size" "$f" >&2
    fail=1
  fi
done < <(find "$root" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \
           -o -name slack -o -name 'chrome*' \) -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print)

log "checking that app.asar is untouched"
asar_after=$(sha256sum "$slack_lib/resources/app.asar" | cut -d' ' -f1)
[ "$asar_before" = "$asar_after" ] || { printf 'app.asar changed\n' >&2; fail=1; }

log "checking that the app starts and reports its version"
reported=$("$slack_lib/slack" --version 2>/dev/null | tr -d '[:space:]' || true)
[ "$reported" = "$slack_version" ] \
  || { printf 'binary reported "%s", expected "%s"\n' "$reported" "$slack_version" >&2; fail=1; }

[ "$fail" -eq 0 ] || die "verification failed"
log "all checks passed"

# -------------------------------------------------------------- 6. build an RPM

step "Building the aarch64 RPM"
topdir="$work_dir/rpmbuild"
rm -rf "$topdir"; mkdir -p "$topdir"/{BUILD,RPMS,SOURCES,SPECS}
ln -sfn "$root" "$topdir/SOURCES/root"

cat > "$topdir/SPECS/slack.spec" <<EOF
%global __os_install_post %{nil}
%global __spec_install_post %{nil}
%global debug_package %{nil}
%define _build_id_links none

Name:           slack
Version:        ${slack_version}
Release:        0.1.el8
Summary:        Slack Desktop
License:        Proprietary
URL:            https://slack.com/downloads/linux
BuildArch:      aarch64
Requires:       libXScrnSaver
Requires:       libappindicator-gtk3
Requires:       libsecret
AutoReqProv:    no

%description
Slack Desktop, repacked for aarch64 from the official x86_64 release.
Built against Electron ${electron_version} (Slack bundles ${bundled_electron}).

%install
mkdir -p %{buildroot}
cp -a %{_sourcedir}/root/* %{buildroot}/

# defattr keeps each file's own mode, which cp -a carried over from the source
# RPM, and forces root ownership -- rpmbuild runs unprivileged. Listing the
# executables one by one would pin a file set that moves between Electron
# majors. chrome-sandbox is the exception: it needs the setuid bit.
%files
%defattr(-, root, root, -)
/usr/bin/slack
/usr/lib/slack
%attr(4755, root, root) /usr/lib/slack/chrome-sandbox
/usr/share/applications/slack.desktop
/usr/share/metainfo/slack.metainfo.xml
/usr/share/pixmaps/slack.png
/etc/cron.daily/slack

%changelog
EOF

rpmbuild -bb \
  --define "_topdir $topdir" \
  --define "_sourcedir $topdir/SOURCES" \
  --define "__spec_install_post %{nil}" \
  --define "__os_install_post %{nil}" \
  --define "debug_package %{nil}" \
  --define "_build_id_links none" \
  --target aarch64 \
  "$topdir/SPECS/slack.spec" > "$work_dir/rpmbuild.log" 2>&1 \
  || { tail -40 "$work_dir/rpmbuild.log" >&2; die "rpmbuild failed; full log at $work_dir/rpmbuild.log"; }

mkdir -p "$out_dir"
built=$(find "$topdir/RPMS" -name '*.rpm' -print -quit)
[ -n "$built" ] || die "rpmbuild produced no package"
cp -f "$built" "$out_dir/"

printf '\n==> Done\n'
printf '    Electron %s (Slack bundles %s)\n' "$electron_version" "$bundled_electron"
printf '    %s\n' "$out_dir/$(basename "$built")"
printf '\n    sudo dnf install %s\n\n' "$out_dir/$(basename "$built")"
