#!/usr/bin/env bash
# Packs a Linux release bundle into an AppImage.
#
#   scripts/package_linux_appimage.sh [bundle] [output_dir]
#
#   bundle      what `flutter build linux --release` made
#               (default: build/linux/x64/release/bundle)
#   output_dir  where Icarus-<version>-x86_64.AppImage goes
#               (default: build/appimage)
#
# It only packs: build the bundle first, with the cloud environment the
# AppImage is for. appimagetool and the AppImage runtime are fetched at the
# versions pinned below and checked against their SHA-256.
#
# The AppImage runs on distributions whose glibc is at least the one it was
# built against; the script prints that floor. Build releases on the oldest
# system that should run them.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$(realpath -m "${1:-$repo_root/build/linux/x64/release/bundle}")"
output_dir="$(realpath -m "${2:-$repo_root/build/appimage}")"

# The GTK application id (linux/CMakeLists.txt). The desktop entry, icon and
# MIME definitions are all named after it.
app_id="xyz.icarus-strats"

appimagetool_version="1.9.1"
appimagetool_sha256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
runtime_version="20251108"
runtime_sha256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

if [[ ! -x "$bundle/icarus" ]]; then
  echo "error: no Linux bundle at $bundle (run flutter build linux --release first)" >&2
  exit 1
fi

version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$repo_root/pubspec.yaml")"
if [[ -z "$version" ]]; then
  echo "error: could not read the version from pubspec.yaml" >&2
  exit 1
fi

# Downloads url to dest unless dest already holds the expected bytes.
fetch() {
  local url="$1" sha256="$2" dest="$3"
  if [[ -f "$dest" ]] && echo "$sha256  $dest" | sha256sum --check --status; then
    return
  fi
  curl --fail --location --silent --show-error --output "$dest.part" "$url"
  echo "$sha256  $dest.part" | sha256sum --check --quiet
  mv "$dest.part" "$dest"
}

tools="$output_dir/tools"
mkdir -p "$tools"
appimagetool="$tools/appimagetool-$appimagetool_version-x86_64.AppImage"
runtime="$tools/runtime-$runtime_version-x86_64"
fetch "https://github.com/AppImage/appimagetool/releases/download/$appimagetool_version/appimagetool-x86_64.AppImage" \
  "$appimagetool_sha256" "$appimagetool"
fetch "https://github.com/AppImage/type2-runtime/releases/download/$runtime_version/runtime-x86_64" \
  "$runtime_sha256" "$runtime"
chmod +x "$appimagetool"

# The AppDir: the Flutter bundle as it is under usr/lib/icarus, started
# through AppRun, plus what desktops read to show and open it.
appdir="$output_dir/AppDir"
rm -rf "$appdir"
share="$appdir/usr/share"
mkdir -p "$appdir/usr/lib" "$share/applications" "$share/mime/packages"
cp -a "$bundle" "$appdir/usr/lib/icarus"
ln -s usr/lib/icarus/icarus "$appdir/AppRun"

cp "$repo_root/linux/packaging/$app_id.desktop" "$share/applications/"
ln -s "usr/share/applications/$app_id.desktop" "$appdir/$app_id.desktop"
cp "$repo_root/linux/packaging/$app_id.xml" "$share/mime/packages/"

# The macOS icon set: the same artwork at the sizes hicolor wants.
iconset="$repo_root/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512; do
  mkdir -p "$share/icons/hicolor/${size}x${size}/apps"
  cp "$iconset/app_icon_$size.png" "$share/icons/hicolor/${size}x${size}/apps/$app_id.png"
done
ln -s "usr/share/icons/hicolor/256x256/apps/$app_id.png" "$appdir/$app_id.png"
ln -s "$app_id.png" "$appdir/.DirIcon"

glibc_floor="$(find "$appdir/usr/lib/icarus" -type f \( -name icarus -o -name '*.so' \) \
  -exec objdump -T {} + 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu | tail -1 || true)"

output="$output_dir/Icarus-$version-x86_64.AppImage"
rm -f "$output"
# Extract-and-run, so building needs no FUSE (CI runners, containers).
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$appimagetool" --no-appstream \
  --runtime-file "$runtime" "$appdir" "$output"

echo "AppImage: $output"
echo "Needs ${glibc_floor:-an unknown glibc version} or newer."
