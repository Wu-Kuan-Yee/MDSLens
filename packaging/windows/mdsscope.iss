#ifndef BundleDir
  #error BundleDir must point to the complete Flutter Windows bundle
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\dist"
#endif
#ifndef OutputBase
  #define OutputBase "mdsscope-windows-x64"
#endif
#ifndef AppVersion
  #define AppVersion "7.0"
#endif

[Setup]
AppId={{B9EA2350-BC49-4C8A-B91C-DB57C721A999}
AppName=MdsScope
AppVersion={#AppVersion}
AppPublisher=MdsScope Contributors
DefaultDirName={autopf}\MdsScope
DefaultGroupName=MdsScope
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\mdsscope.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
PrivilegesRequired=admin

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MdsScope"; Filename: "{app}\mdsscope.exe"; AppUserModelID: "MdsScope.MdsScope"
Name: "{autodesktop}\MdsScope"; Filename: "{app}\mdsscope.exe"; Tasks: desktopicon

[Registry]
Root: HKCR; Subkey: "MdsScope.Configuration"; ValueType: string; ValueName: ""; ValueData: "MdsScope configuration"; Flags: uninsdeletekey
Root: HKCR; Subkey: "MdsScope.Configuration\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\mdsscope.exe"",0"
Root: HKCR; Subkey: "MdsScope.Configuration\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\mdsscope.exe"" ""%1"""
Root: HKCR; Subkey: ".toml\OpenWithProgids"; ValueType: string; ValueName: "MdsScope.Configuration"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: ".webscp"; ValueType: string; ValueName: ""; ValueData: "MdsScope.Configuration"; Flags: uninsdeletevalue
Root: HKCR; Subkey: "mdsscope"; ValueType: string; ValueName: ""; ValueData: "URL:MdsScope protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "mdsscope"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCR; Subkey: "mdsscope\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\mdsscope.exe"",0"
Root: HKCR; Subkey: "mdsscope\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\mdsscope.exe"" ""%1"""

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\mdsscope.exe"; Description: "Launch MdsScope"; Flags: nowait postinstall skipifsilent
