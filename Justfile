prefix := env_var_or_default("PREFIX", "/usr/local")
bindir := prefix / "bin"
version := `sed -n 's/^version: //p' shard.yml`

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
    @echo "installed: {{bindir}}/camelot"

uninstall:
    rm -f {{bindir}}/camelot

# Register `camelot mcp` with Claude Code at user scope (camelot must be on PATH).
mcp-add:
    claude mcp add --scope user camelot -- camelot mcp

mcp-remove:
    claude mcp remove --scope user camelot

# ---- packages --------------------------------------------------------------

# Source tarball of the tracked files, as every package format consumes it.
pkg-src:
    mkdir -p pkg
    git ls-files -z --cached --others --exclude-standard | tar --null -T - --transform "s,^,camelot-{{version}}/," -czf "pkg/camelot-{{version}}.tar.gz"

pkg-arch: pkg-src
    cd pkg && makepkg -f

# Debian package, built in a container (crystal's official image is Ubuntu-based).
pkg-deb: pkg-src
    podman run --rm -v "$PWD/pkg:/pkg" docker.io/crystallang/crystal:latest bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends debhelper devscripts libgirepository1.0-dev gir1.2-atspi-2.0 libatspi2.0-dev libglib2.0-dev libdbus-1-dev libgc-dev libpcre2-dev libyaml-dev zlib1g-dev >/dev/null
        rm -rf /build && mkdir /build && cd /build
        tar xzf /pkg/camelot-{{version}}.tar.gz
        cd camelot-{{version}} && cp -a pkg/debian debian
        dpkg-buildpackage -us -uc -b
        cp /build/*.deb /pkg/
        chown "$(stat -c %u /pkg):$(stat -c %g /pkg)" /pkg/*.deb'

# RPM package, built in a Fedora container (Fedora ships crystal).
pkg-rpm: pkg-src
    podman run --rm -v "$PWD/pkg:/pkg" registry.fedoraproject.org/fedora:latest bash -c '
        set -euo pipefail
        dnf install -y -q rpm-build crystal shards gcc redhat-rpm-config gobject-introspection-devel at-spi2-core-devel glib2-devel dbus-devel gc-devel pcre2-devel libyaml-devel zlib-devel >/dev/null
        mkdir -p /rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
        cp /pkg/camelot-{{version}}.tar.gz /rpmbuild/SOURCES/
        cp /pkg/camelot.spec /rpmbuild/SPECS/
        rpmbuild --define "_topdir /rpmbuild" -ba /rpmbuild/SPECS/camelot.spec
        find /rpmbuild/RPMS /rpmbuild/SRPMS -name "*.rpm" -exec cp {} /pkg/ \;
        chown "$(stat -c %u /pkg):$(stat -c %g /pkg)" /pkg/*.rpm'

pkg: pkg-arch pkg-deb pkg-rpm

# Install the Arch package locally (sudo).
install-pkg: pkg-arch
    sudo pacman -U --noconfirm pkg/camelot-[0-9]*-x86_64.pkg.tar.zst

clean:
    rm -rf bin lib docs/api pkg/build pkg/pkg pkg/src pkg/rpmbuild pkg/*.tar.gz pkg/*.pkg.tar.zst pkg/*.deb pkg/*.buildinfo pkg/*.changes pkg/*.rpm
