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

# Debian package, built in a Debian container with Crystal from crystal-lang.org's repo.
pkg-deb: pkg-src
    #!/usr/bin/env bash
    set -euo pipefail
    podman run --rm -v "$PWD/pkg:/pkg" docker.io/library/debian:stable bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg >/dev/null
      curl -fsSL https://crystal-lang.org/install.sh | bash >/dev/null
      apt-get install -y -qq --no-install-recommends debhelper git build-essential libgirepository1.0-dev gir1.2-atspi-2.0 libatspi2.0-dev libglib2.0-dev libdbus-1-dev libgc-dev libpcre2-dev libyaml-dev zlib1g-dev >/dev/null
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
    podman run --rm -v "$PWD/pkg:/pkg" registry.fedoraproject.org/fedora:latest bash -euo pipefail -c '
      dnf install -y -q curl >/dev/null
      curl -fsSL https://crystal-lang.org/install.sh | bash >/dev/null
      dnf install -y -q rpm-build gcc git redhat-rpm-config gobject-introspection-devel at-spi2-core-devel glib2-devel dbus-devel gc-devel pcre2-devel libyaml-devel zlib-devel >/dev/null
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

# ---- install tests (fresh containers, runtime deps only) --------------------

test-install-deb:
    #!/usr/bin/env bash
    set -euo pipefail
    ls pkg/camelot_*.deb >/dev/null 2>&1 || { echo "no .deb in pkg/ — run 'just pkg-deb' first"; exit 1; }
    podman run --rm -v "$PWD/pkg:/pkg:ro" docker.io/library/debian:stable bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq /pkg/camelot_{{version}}-1_amd64.deb >/dev/null
      camelot --version
      (camelot apps 2>&1 || true) | grep -q "accessibility bus" && echo "apps: fails cleanly without a bus (ok)"
      ls /usr/share/bash-completion/completions/camelot /usr/share/zsh/vendor-completions/_camelot /usr/share/fish/vendor_completions.d/camelot.fish
      echo "deb install: ok"'

test-install-rpm:
    #!/usr/bin/env bash
    set -euo pipefail
    ls pkg/camelot-[0-9]*.x86_64.rpm >/dev/null 2>&1 || { echo "no .rpm in pkg/ — run 'just pkg-rpm' first"; exit 1; }
    podman run --rm -v "$PWD/pkg:/pkg:ro" registry.fedoraproject.org/fedora:latest bash -euo pipefail -c '
      dnf install -y -q /pkg/camelot-{{version}}-1.*.x86_64.rpm >/dev/null
      camelot --version
      (camelot apps 2>&1 || true) | grep -q "accessibility bus" && echo "apps: fails cleanly without a bus (ok)"
      ls /usr/share/bash-completion/completions/camelot /usr/share/zsh/site-functions/_camelot /usr/share/fish/vendor_completions.d/camelot.fish
      echo "rpm install: ok"'

test-install: test-install-deb test-install-rpm
