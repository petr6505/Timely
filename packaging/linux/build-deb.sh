#!/usr/bin/env bash
# Build timely_<version>_amd64.deb from a Flutter linux release bundle + compiled agent.
# usage: packaging/linux/build-deb.sh <version>
set -euo pipefail
VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
AGENT="$ROOT/agent/build/timely-agent"
OUT="$ROOT/dist"
PKG="$(mktemp -d)/timely_${VERSION}_amd64"

[ -d "$BUNDLE" ] || { echo "missing $BUNDLE (run flutter build linux --release)"; exit 1; }
[ -f "$AGENT" ] || { echo "missing $AGENT (run dart compile exe)"; exit 1; }

mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib/timely" "$PKG/usr/bin" "$PKG/usr/share/applications" \
  "$PKG/usr/lib/systemd/user" "$PKG/usr/share/gnome-shell/extensions" "$PKG/usr/share/icons/hicolor/256x256/apps"
cp -r "$BUNDLE/." "$PKG/usr/lib/timely/"
install -m755 "$AGENT" "$PKG/usr/lib/timely/timely-agent"
ln -s /usr/lib/timely/timely "$PKG/usr/bin/timely"
install -m644 "$ROOT/packaging/linux/timely.desktop" "$PKG/usr/share/applications/timely.desktop"
install -m644 "$ROOT/packaging/linux/timely-agent.service" "$PKG/usr/lib/systemd/user/timely-agent.service"
cp -r "$ROOT/linux/gnome-extension/timely-focus@timely.dev" "$PKG/usr/share/gnome-shell/extensions/"
install -m644 "$ROOT/packaging/icon.png" "$PKG/usr/share/icons/hicolor/256x256/apps/timely.png"

cat > "$PKG/DEBIAN/control" <<CTRL
Package: timely
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0 | libgtk-3-0t64, gnome-shell
Maintainer: Timely
Description: Screen time across all your devices
 Tracks focused-app screen time and background listening, syncs to your own
 Cloudflare backend and shows a dashboard of every device.
CTRL

cat > "$PKG/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
systemctl --global enable timely-agent.service >/dev/null 2>&1 || true
command -v update-desktop-database >/dev/null && update-desktop-database -q || true
echo "Timely installed. Log out and back in once so GNOME loads the focus extension."
POST
cat > "$PKG/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
if [ "$1" = remove ]; then systemctl --global disable timely-agent.service >/dev/null 2>&1 || true; fi
PRE
chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/timely_${VERSION}_amd64.deb"
echo "built $OUT/timely_${VERSION}_amd64.deb"
