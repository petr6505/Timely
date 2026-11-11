; Inno Setup script. Per-user install, no admin rights needed.
#define AppVersion GetEnv("TIMELY_VERSION")
#if AppVersion == ""
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{6B7E1C2A-4F7D-4C5B-9E0A-71D3C0A1F00D}
AppName=Timely
AppVersion={#AppVersion}
AppPublisher=Timely
DefaultDirName={localappdata}\Programs\Timely
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=timely-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\timely.exe
CloseApplications=force

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
Source: "..\..\agent\build\timely-agent.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Timely"; Filename: "{app}\timely.exe"
Name: "{userdesktop}\Timely"; Filename: "{app}\timely.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Registry]
; background agent starts invisibly at login
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "TimelyAgent"; ValueData: """{app}\timely-agent.exe"""; Flags: uninsdeletevalue
; timely:// pairing links
Root: HKCU; Subkey: "Software\Classes\timely"; ValueType: string; ValueData: "URL:Timely"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\timely"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\timely\shell\open\command"; ValueType: string; ValueData: """{app}\timely.exe"" ""%1"""

[Run]
Filename: "{app}\timely-agent.exe"; Flags: nowait runhidden
Filename: "{app}\timely.exe"; Description: "Open Timely"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/F /IM timely-agent.exe"; Flags: runhidden; RunOnceId: "KillAgent"
