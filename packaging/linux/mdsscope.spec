Name:           mdsscope
Version:        %{mdsscope_version}
Release:        1%{?dist}
Summary:        MDSplus signal waveform viewer
License:        GPL-3.0-or-later
BuildArch:      %{mdsscope_arch}
Requires:       gtk3, glibc, libsecret, libstdc++

%description
MdsScope loads, plots, and compares MDSplus experiment signal waveforms.

%install
mkdir -p %{buildroot}
cp -a %{_sourcedir}/root/. %{buildroot}/

%files
/usr/bin/mdsscope
/usr/lib/mdsscope
/usr/share/applications/com.mdsscope.app.desktop
/usr/share/icons/hicolor/scalable/apps/com.mdsscope.app.svg
/usr/share/mime/packages/com.mdsscope.configuration.xml

%changelog
* Thu Jul 23 2026 MdsScope Contributors - %{mdsscope_version}-1
- Automated release build
