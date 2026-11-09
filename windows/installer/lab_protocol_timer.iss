; Installer of lab_protocol_timer for Windows (Inno Setup 6).
; Built by .github/workflows/release-windows.yml after `flutter build windows`:
;   iscc /DAppVersion=1.4.1 windows/installer/lab_protocol_timer.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B0C7C2E-4E52-4E3A-9D0B-5A3B2F7D1C41}
AppName=lab_protocol_timer
AppVersion={#AppVersion}
AppPublisher=PROFITH, Universidad de Granada
DefaultDirName={autopf}\lab_protocol_timer
DefaultGroupName=lab_protocol_timer
UninstallDisplayIcon={app}\lab_protocol_timer.exe
OutputDir=..\..\build\installer
OutputBaseFilename=lab_protocol_timer_setup_{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\lab_protocol_timer"; Filename: "{app}\lab_protocol_timer.exe"
Name: "{autodesktop}\lab_protocol_timer"; Filename: "{app}\lab_protocol_timer.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lab_protocol_timer.exe"; Description: "{cm:LaunchProgram,lab_protocol_timer}"; Flags: nowait postinstall skipifsilent
