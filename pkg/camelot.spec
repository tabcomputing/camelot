%global debug_package %{nil}

Name:           camelot
Version:        0.3.1
Release:        1%{?dist}
Summary:        Context bridge between the Linux desktop and AI

License:        MIT
URL:            https://github.com/tabcomputing/camelot
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  crystal
BuildRequires:  gcc
BuildRequires:  git
BuildRequires:  redhat-rpm-config
BuildRequires:  gobject-introspection-devel
BuildRequires:  at-spi2-core-devel
BuildRequires:  glib2-devel
BuildRequires:  gdk-pixbuf2-devel
BuildRequires:  dbus-devel
BuildRequires:  gc-devel
BuildRequires:  pcre2-devel
BuildRequires:  libyaml-devel
BuildRequires:  zlib-devel
BuildRequires:  systemd-rpm-macros
BuildRequires:  gtk4-devel
BuildRequires:  libadwaita-devel

Requires:       at-spi2-core

%description
camelot lets an AI see what you are doing on your desktop. It reads the
AT-SPI2 accessibility tree and reports the active application, window,
focused widget and its text as text, JSON or YAML; streams accessibility
events; and serves all of it as MCP tools for Claude Code and other clients.

%package gtk
Summary:        Control panel for camelot
Requires:       %{name} = %{version}-%{release}

%description gtk
Control panel for camelot: recent activity, the recording switch, and
settings, over the daemon's socket.

%prep
%autosetup

%build
shards install --production
bin/gi-crystal > gi-crystal.log 2>&1 || { cat gi-crystal.log; exit 1; }
crystal build --release --no-debug src/cli.cr -o bin/camelot
crystal build --release --no-debug src/gtk.cr -o bin/camelot-gtk
for sh in bash zsh fish; do bin/camelot --completions $sh > completions.$sh; done

%install
install -Dpm0755 bin/camelot %{buildroot}%{_bindir}/camelot
install -Dpm0644 completions.bash %{buildroot}%{_datadir}/bash-completion/completions/camelot
install -Dpm0644 completions.zsh  %{buildroot}%{_datadir}/zsh/site-functions/_camelot
install -Dpm0644 completions.fish %{buildroot}%{_datadir}/fish/vendor_completions.d/camelot.fish
install -Dpm0644 contrib/camelot.service %{buildroot}%{_userunitdir}/camelot.service
install -Dpm0755 bin/camelot-gtk %{buildroot}%{_bindir}/camelot-gtk
install -Dpm0644 contrib/com.tabcomputing.Camelot.desktop %{buildroot}%{_datadir}/applications/com.tabcomputing.Camelot.desktop
install -Dpm0644 README.md %{buildroot}%{_docdir}/%{name}/README.md
install -Dpm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
%doc %{_docdir}/%{name}/README.md
%{_bindir}/camelot
%{_datadir}/bash-completion/completions/camelot
%{_datadir}/zsh/site-functions/_camelot
%{_datadir}/fish/vendor_completions.d/camelot.fish
%{_userunitdir}/camelot.service

%files gtk
%{_bindir}/camelot-gtk
%{_datadir}/applications/com.tabcomputing.Camelot.desktop

%changelog
* Tue Sep 22 2026 Thomas Sawyer <transfire@gmail.com> - 0.3.1-1
- Fix a daemon that spun a core when left running: the GLib pump now always yields, bounds dispatch, and retires watchers for dead connections

* Mon Sep 21 2026 Thomas Sawyer <transfire@gmail.com> - 0.3.0-1
- Control panel (camelot-gtk): switchboard, activity log, ignore list; push protocol (subscribe); incremental digest; event resolution off the dispatch path; per-source cache

* Mon Sep 21 2026 Thomas Sawyer <transfire@gmail.com> - 0.2.0-1
- Daemon with activity history (recent), pause/resume/reload, ignore list, retention, durable log; accessibility on by default

* Mon Sep 21 2026 Thomas Sawyer <transfire@gmail.com> - 0.1.0-1
- Initial packaging: AT-SPI snapshots (apps, windows, tree, focus, at, context),
  event stream (watch), MCP server (mcp), shell completions.
