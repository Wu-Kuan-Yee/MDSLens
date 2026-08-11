Name:           mdslens
Version:        %{mdslens_version}
Release:        1%{?dist}
Summary:        MDSplus signal waveform viewer
License:        GPL-3.0-or-later
BuildArch:      %{mdslens_arch}
# Flutter's Linux bundle contains private, unversioned plugin DSOs.  RPM's
# dependency generator otherwise publishes names such as
# libdesktop_drop_plugin.so()(64bit) as external requirements, even though
# those files are shipped inside /usr/lib/mdslens.  Keep versioned SONAME
# requirements for real host libraries; filter only the private unversioned
# DSO form from both Requires and Provides.
%global __requires_exclude ^lib[^/]+\\.so\\(\\)\\([^)]*\\)$
%global __provides_exclude ^lib[^/]+\\.so\\(\\)\\([^)]*\\)$
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
/usr/share/icons/hicolor/512x512/apps/com.mdslens.app.png
/usr/share/mime/packages/com.mdslens.configuration.xml

%changelog
* Thu Jul 23 2026 MDSLens Contributors - %{mdslens_version}-1
- Automated release build
