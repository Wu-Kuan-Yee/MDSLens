#ifndef BundleDir
  #error BundleDir must point to the complete Flutter Windows bundle
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\dist"
#endif
#ifndef OutputBase
  #define OutputBase "mdslens-windows-x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.1"
#endif

[Setup]
AppId={{B9EA2350-BC49-4C8A-B91C-DB57C721A999}
AppName=MDSLens
AppVersion={#AppVersion}
AppPublisher=MDSLens Contributors
DefaultDirName={autopf}\MDSLens
DefaultGroupName=MDSLens
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\mdslens.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
PrivilegesRequired=admin

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MDSLens"; Filename: "{app}\mdslens.exe"; AppUserModelID: "MDSLens.MDSLens"
Name: "{autodesktop}\MDSLens"; Filename: "{app}\mdslens.exe"; Tasks: desktopicon

[Registry]
Root: HKCR; Subkey: "MDSLens.Configuration"; ValueType: string; ValueName: ""; ValueData: "MDSLens configuration"; Flags: uninsdeletekey
Root: HKCR; Subkey: "MDSLens.Configuration\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\mdslens.exe"",0"
Root: HKCR; Subkey: "MDSLens.Configuration\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\mdslens.exe"" ""%1"""
Root: HKCR; Subkey: ".toml\OpenWithProgids"; ValueType: string; ValueName: "MDSLens.Configuration"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: ".webscp"; ValueType: string; ValueName: ""; ValueData: "MDSLens.Configuration"; Flags: uninsdeletevalue
Root: HKCR; Subkey: "mdslens"; ValueType: string; ValueName: ""; ValueData: "URL:MDSLens protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "mdslens"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCR; Subkey: "mdslens\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\mdslens.exe"",0"
Root: HKCR; Subkey: "mdslens\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\mdslens.exe"" ""%1"""

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\mdslens.exe"; Description: "Launch MDSLens"; Flags: nowait postinstall skipifsilent
