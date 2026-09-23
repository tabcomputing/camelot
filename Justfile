prefix := env_var_or_default("PREFIX", "/usr/local")
bindir := prefix / "bin"
version := `sed -n 's/^version: //p' shard.yml`
# Container runtime for the deb/rpm/arch-container builds (CI sets docker).
container := env_var_or_default("CONTAINER", "podman")

default:
    @just --list

# Generate the gi-crystal Atspi bindings — once after `shards install`.
bindings:
    shards install
    bin/gi-crystal

build: bindings
    shards build --release

build-debug: bindings
    shards build

test:
    crystal spec

run *ARGS:
    crystal run src/cli.cr -- {{ARGS}}

fmt:
    crystal tool format src spec

check:
    crystal tool format --check src spec
    crystal spec

# ---- local install ---------------------------------------------------------

install: build
    install -d {{bindir}}
    install -m 0755 bin/camelot {{bindir}}/camelot
    install -m 0755 bin/camelot-gtk {{bindir}}/camelot-gtk
    @echo "installed: {{bindir}}/camelot {{bindir}}/camelot-gtk"

uninstall:
    rm -f {{bindir}}/camelot

# Register `camelot mcp` with Claude Code at user scope (camelot must be on PATH).
mcp-add:
    claude mcp add --scope user camelot -- camelot mcp

mcp-remove:
    claude mcp remove --scope user camelot

# ---- GNOME Shell extension --------------------------------------------------

# Test the extension in a throwaway headless GNOME Shell (touches nothing live).
extension-test: build-debug
    contrib/gnome-extension/test.sh

# Install the extension for this user and enable it; takes effect at next login.
extension-install:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="$HOME/.local/share/gnome-shell/extensions/camelot@tabcomputing.com"
    mkdir -p "$dest"
    cp contrib/gnome-extension/camelot@tabcomputing.com/* "$dest/"
    gnome-extensions enable camelot@tabcomputing.com 2>/dev/null || \
      gsettings set org.gnome.shell enabled-extensions \
        "$(gsettings get org.gnome.shell enabled-extensions | python3 -c 'import ast,sys; v=sys.stdin.read().strip(); l=[] if v.startswith("@") else ast.literal_eval(v); l.append("camelot@tabcomputing.com") if "camelot@tabcomputing.com" not in l else None; print(l)')"
    echo "installed to $dest — log out and back in to load it (Wayland loads new extensions only at login)"

extension-uninstall:
    gnome-extensions disable camelot@tabcomputing.com 2>/dev/null || true
    rm -rf "$HOME/.local/share/gnome-shell/extensions/camelot@tabcomputing.com"

# ---- release ---------------------------------------------------------------

# Bump the version everywhere: shard.yml and src/camelot/version.cr (the
# sources of truth), PKGBUILD, the RPM spec, and the Debian changelog. A new
# dated changelog stanza is prepended for deb and rpm.
# Usage: just bump-version 0.2.0 "Summary of the release"
bump-version new_version message='New upstream release.':
    #!/usr/bin/env bash
    set -euo pipefail
    ver='{{new_version}}'
    msg='{{message}}'
    maint='Thomas Sawyer <transfire@gmail.com>'

    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: version must be X.Y.Z (got '$ver')" >&2
        exit 1
    fi

    # 1. Sources of truth: shard.yml (read by the just `version` var and the
    #    package jobs) and the VERSION constant behind `camelot --version`.
    sed -i "s/^version: .*/version: $ver/" shard.yml
    sed -i "s/^  VERSION = \".*\"/  VERSION = \"$ver\"/" src/camelot/version.cr

    # 2. Arch PKGBUILD (reset pkgrel to 1 for the new version).
    sed -i "s/^pkgver=.*/pkgver=$ver/" pkg/PKGBUILD
    sed -i "s/^pkgrel=.*/pkgrel=1/" pkg/PKGBUILD

    # 3. RPM spec: version, release, and a new %changelog entry on top.
    sed -i "s/^Version:.*/Version:        $ver/" pkg/camelot.spec
    sed -i "s/^Release:.*/Release:        1%{?dist}/" pkg/camelot.spec
    awk -v e="* $(LC_ALL=C date '+%a %b %d %Y') $maint - $ver-1\n- $msg\n" \
        '/^%changelog/ { print; print e; next } { print }' \
        pkg/camelot.spec > pkg/camelot.spec.tmp && mv pkg/camelot.spec.tmp pkg/camelot.spec

    # 4. Debian changelog: prepend a new stanza.
    { printf 'camelot (%s-1) unstable; urgency=medium\n\n  * %s\n\n -- %s  %s\n\n' \
          "$ver" "$msg" "$maint" "$(LC_ALL=C date -R)"; \
      cat pkg/debian/changelog; } > pkg/debian/changelog.tmp \
      && mv pkg/debian/changelog.tmp pkg/debian/changelog

    echo "bumped camelot to $ver in:"
    echo "  shard.yml  src/camelot/version.cr  pkg/PKGBUILD  pkg/camelot.spec  pkg/debian/changelog"
    echo
    echo "review the changes, then commit and tag:"
    echo "  git commit -am 'Bump version to $ver'"
    echo "  git tag v$ver && git push origin main --tags"
    echo "then publish the v$ver release on GitHub; the Package workflow attaches the packages."

# ---- packages --------------------------------------------------------------

# Source tarball of the tracked files, as every package format consumes it.
pkg-src:
    mkdir -p pkg
    git ls-files -z --cached --others --exclude-standard | tar --null -T - --transform "s,^,camelot-{{version}}/," -czf "pkg/camelot-{{version}}.tar.gz"

pkg-arch: pkg-src
    cd pkg && makepkg -f
    # makepkg's extracted tree holds a second binding.yml that gi-crystal would trip over.
    rm -rf pkg/src pkg/pkg

# Arch package built in a container, for non-Arch hosts and CI.
pkg-arch-container: pkg-src
    #!/usr/bin/env bash
    set -euo pipefail
    {{container}} run --rm -v "$PWD/pkg:/pkg" docker.io/library/archlinux:base-devel bash -euo pipefail -c '
      pacman -Syu --noconfirm --needed crystal shards git libgirepository gobject-introspection-runtime at-spi2-core glib2 gdk-pixbuf2 dbus gc pcre2 libyaml gcc-libs zlib gtk4 libadwaita >/dev/null
      useradd -m builder
      rm -rf /build && mkdir /build && cp /pkg/camelot-{{version}}.tar.gz /pkg/PKGBUILD /pkg/camelot.install /build/
      chown -R builder:builder /build
      su builder -c "cd /build && makepkg -f --noconfirm" >/dev/null
      cp /build/*.pkg.tar.zst /pkg/
      chown "$(stat -c %u /pkg):$(stat -c %g /pkg)" /pkg/*.pkg.tar.zst'

# Debian package, built in a Debian container with Crystal from crystal-lang.org's repo.
pkg-deb: pkg-src
    #!/usr/bin/env bash
    set -euo pipefail
    {{container}} run --rm -v "$PWD/pkg:/pkg" docker.io/library/debian:stable bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg >/dev/null
      curl -fsSL https://crystal-lang.org/install.sh | bash >/dev/null
      apt-get install -y -qq --no-install-recommends debhelper git build-essential libgirepository1.0-dev gir1.2-atspi-2.0 libatspi2.0-dev libglib2.0-dev libgdk-pixbuf-2.0-dev gir1.2-gdkpixbuf-2.0 libdbus-1-dev libgc-dev libpcre2-dev libyaml-dev zlib1g-dev libgtk-4-dev libadwaita-1-dev gir1.2-gtk-4.0 gir1.2-adw-1 >/dev/null
      rm -rf /build && mkdir /build && cd /build
      tar xzf /pkg/camelot-{{version}}.tar.gz
      cd camelot-{{version}} && cp -a pkg/debian debian
      dpkg-buildpackage -us -uc -b
      cp /build/*.deb /pkg/
      chown "$(stat -c %u /pkg):$(stat -c %g /pkg)" /pkg/*.deb'

# RPM package, built in a Fedora container with Crystal from crystal-lang.org's repo.
pkg-rpm: pkg-src
    #!/usr/bin/env bash
    set -euo pipefail
    {{container}} run --rm -v "$PWD/pkg:/pkg" registry.fedoraproject.org/fedora:latest bash -euo pipefail -c '
      dnf install -y -q curl >/dev/null
      curl -fsSL https://crystal-lang.org/install.sh | bash >/dev/null
      dnf install -y -q rpm-build gcc git redhat-rpm-config gobject-introspection-devel at-spi2-core-devel glib2-devel gdk-pixbuf2-devel dbus-devel gc-devel pcre2-devel libyaml-devel zlib-devel gtk4-devel libadwaita-devel >/dev/null
      mkdir -p /rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
      cp /pkg/camelot-{{version}}.tar.gz /rpmbuild/SOURCES/
      cp /pkg/camelot.spec /rpmbuild/SPECS/
      rpmbuild --define "_topdir /rpmbuild" -ba /rpmbuild/SPECS/camelot.spec
      find /rpmbuild/RPMS /rpmbuild/SRPMS -name "*.rpm" -exec cp {} /pkg/ \;
      chown "$(stat -c %u /pkg):$(stat -c %g /pkg)" /pkg/*.rpm'

pkg: pkg-arch pkg-deb pkg-rpm

# Install the Arch packages locally (sudo).
install-pkg: pkg-arch
    sudo pacman -U --noconfirm pkg/camelot-{{version}}-1-x86_64.pkg.tar.zst pkg/camelot-gtk-{{version}}-1-x86_64.pkg.tar.zst

# The development loop on Arch: rebuild, reinstall, restart the daemon.
reinstall: install-pkg
    systemctl --user restart camelot
    @echo "restarted camelot; the panel needs relaunching to pick up a new camelot-gtk"

clean:
    rm -rf bin lib docs/api pkg/build pkg/pkg pkg/src pkg/rpmbuild pkg/*.tar.gz pkg/*.pkg.tar.zst pkg/*.deb pkg/*.buildinfo pkg/*.changes pkg/*.rpm

# ---- install tests (fresh containers, runtime deps only) --------------------

test-install-deb:
    #!/usr/bin/env bash
    set -euo pipefail
    ls pkg/camelot_*.deb >/dev/null 2>&1 || { echo "no .deb in pkg/ — run 'just pkg-deb' first"; exit 1; }
    {{container}} run --rm -v "$PWD/pkg:/pkg:ro" docker.io/library/debian:stable bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq /pkg/camelot_{{version}}-1_amd64.deb /pkg/camelot-gtk_{{version}}-1_amd64.deb >/dev/null
      camelot --version
      ls /usr/bin/camelot-gtk /usr/share/applications/com.tabcomputing.Camelot.desktop
      (camelot apps 2>&1 || true) | grep -q "accessibility bus" && echo "apps: fails cleanly without a bus (ok)"
      ls /usr/share/bash-completion/completions/camelot /usr/share/zsh/vendor-completions/_camelot /usr/share/fish/vendor_completions.d/camelot.fish /usr/lib/systemd/user/camelot.service
      echo "deb install: ok"'

test-install-rpm:
    #!/usr/bin/env bash
    set -euo pipefail
    ls pkg/camelot-[0-9]*.x86_64.rpm >/dev/null 2>&1 || { echo "no .rpm in pkg/ — run 'just pkg-rpm' first"; exit 1; }
    {{container}} run --rm -v "$PWD/pkg:/pkg:ro" registry.fedoraproject.org/fedora:latest bash -euo pipefail -c '
      dnf install -y -q /pkg/camelot-{{version}}-1.*.x86_64.rpm /pkg/camelot-gtk-{{version}}-1.*.x86_64.rpm >/dev/null
      camelot --version
      ls /usr/bin/camelot-gtk /usr/share/applications/com.tabcomputing.Camelot.desktop
      (camelot apps 2>&1 || true) | grep -q "accessibility bus" && echo "apps: fails cleanly without a bus (ok)"
      ls /usr/share/bash-completion/completions/camelot /usr/share/zsh/site-functions/_camelot /usr/share/fish/vendor_completions.d/camelot.fish /usr/lib/systemd/user/camelot.service
      echo "rpm install: ok"'

test-install: test-install-deb test-install-rpm
