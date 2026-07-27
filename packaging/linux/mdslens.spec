Name:           mdslens
Version:        %{mdslens_version}
Release:        1%{?dist}
Summary:        MDSplus signal waveform viewer
License:        GPL-3.0-or-later
BuildArch:      %{mdslens_arch}
Requires:       gtk3, glibc, libglvnd-egl, libglvnd-gles, libsecret, libstdc++

%description
MDSLens loads, plots, and compares MDSplus experiment signal waveforms.

%install
mkdir -p %{buildroot}
cp -a %{_sourcedir}/root/. %{buildroot}/

%files
/usr/bin/mdslens
/usr/lib/mdslens
/usr/share/applications/com.mdslens.app.desktop
/usr/share/icons/hicolor/scalable/apps/com.mdslens.app.svg
/usr/share/mime/packages/com.mdslens.configuration.xml

%changelog
* Thu Jul 23 2026 MDSLens Contributors - %{mdslens_version}-1
- Automated release build
