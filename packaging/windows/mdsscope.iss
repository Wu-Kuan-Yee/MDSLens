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
  #define AppVersion "7.0.0"
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
Name: "{autoprograms}\MdsScope"; Filename: "{app}\mdsscope.exe"
Name: "{autodesktop}\MdsScope"; Filename: "{app}\mdsscope.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\mdsscope.exe"; Description: "Launch MdsScope"; Flags: nowait postinstall skipifsilent
