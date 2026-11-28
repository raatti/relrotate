# Built by .github/workflows/release.yml from the release tarball:
#   rpmbuild -ta relrotate-X.Y.Z.tar.gz
# Version must equal RELROTATE_VERSION in ./relrotate (tests/check.sh checks).
Name:           relrotate
Version:        0.4.3
Release:        1%{?dist}
Summary:        Policy-driven application updates with rollback
License:        MIT
URL:            https://github.com/raatti/relrotate
Source0:        %{url}/releases/download/v%{version}/%{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  systemd-rpm-macros
Requires:       bash >= 5.1
Requires:       coreutils
Requires:       curl
Requires:       jq
Requires:       tar
Requires:       util-linux
Recommends:     gnupg2
%{?systemd_requires}

%description
relrotate updates self-hosted applications from their upstream releases on
a systemd timer: it picks the newest release a per-app policy allows,
verifies the download, switches to it, checks the service is healthy and
rolls back when it is not. Layouts: symlinked release directories, single
binaries and podman quadlets.

%prep
%autosetup

%build

%install
install -D -p -m 0755 relrotate %{buildroot}%{_sbindir}/relrotate
install -d -m 0755 %{buildroot}%{_prefix}/lib/relrotate
install -p -m 0644 lib/*.sh %{buildroot}%{_prefix}/lib/relrotate/
install -d -m 0755 %{buildroot}%{_datadir}/relrotate/examples
cp -r examples/. %{buildroot}%{_datadir}/relrotate/examples/
install -p -m 0644 relrotate-keyring.gpg %{buildroot}%{_datadir}/relrotate/relrotate-keyring.gpg
install -d -m 0750 %{buildroot}%{_sysconfdir}/relrotate/apps.d \
    %{buildroot}%{_sysconfdir}/relrotate/keys %{buildroot}%{_sharedstatedir}/relrotate
install -p -m 0640 etc/relrotate.conf %{buildroot}%{_sysconfdir}/relrotate/relrotate.conf
install -d -m 0755 %{buildroot}%{_unitdir}
install -p -m 0644 systemd/*.timer %{buildroot}%{_unitdir}/
# The units in the source name /usr/local/sbin (the install.sh default).
for u in relrotate@.service relrotate-digest.service; do
    sed 's|^ExecStart=/usr/local/sbin/|ExecStart=%{_sbindir}/|' systemd/$u > %{buildroot}%{_unitdir}/$u
    grep -q '^ExecStart=%{_sbindir}/relrotate ' %{buildroot}%{_unitdir}/$u
    chmod 0644 %{buildroot}%{_unitdir}/$u
done

%post
%systemd_post relrotate-digest.timer

%preun
%systemd_preun relrotate-digest.timer

%postun
%systemd_postun relrotate-digest.timer

%files
%license LICENSE
%doc README.md CHANGELOG.md
%{_sbindir}/relrotate
%{_prefix}/lib/relrotate/
%{_datadir}/relrotate/
%{_unitdir}/relrotate@.service
%{_unitdir}/relrotate@.timer
%{_unitdir}/relrotate-digest.service
%{_unitdir}/relrotate-digest.timer
%dir %attr(0750,root,root) %{_sysconfdir}/relrotate
%dir %attr(0750,root,root) %{_sysconfdir}/relrotate/apps.d
%dir %attr(0750,root,root) %{_sysconfdir}/relrotate/keys
%config(noreplace) %attr(0640,root,root) %{_sysconfdir}/relrotate/relrotate.conf
%dir %attr(0750,root,root) %{_sharedstatedir}/relrotate
