; Opticon - almindelig Windows-installer (Inno Setup)
; Bygges af GitHub Actions:  iscc /DArch=x64 /DSrc=<mappe> /DAppVer=0.1.0 Opticon.iss
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVer
  #define AppVer "0.1.0"
#endif
#ifndef Src
  #define Src "..\..\out\win-x64"
#endif

[Setup]
AppId={{6F1C2B7E-4A3D-4C8E-9B5F-0D2E7A1C9F42}
AppName=Opticon
AppVersion={#AppVer}
AppVerName=Opticon {#AppVer}
AppPublisher=Opticon
AppPublisherURL=https://github.com/Ixtland-templex/pc-tjek
AppSupportURL=https://github.com/Ixtland-templex/pc-tjek
; Installeres kun for dig selv: kræver ikke administrator
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\Opticon
DefaultGroupName=Opticon
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\Opticon.exe
UninstallDisplayName=Opticon
OutputBaseFilename=Opticon-Setup-{#AppVer}-{#Arch}
SetupIconFile=..\Opticon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "danish"; MessagesFile: "compiler:Languages\Danish.isl"

[Tasks]
Name: "desktopicon"; Description: "Lav en genvej på skrivebordet"; GroupDescription: "Genveje:"

[Files]
Source: "{#Src}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Opticon"; Filename: "{app}\Opticon.exe"
Name: "{autodesktop}\Opticon"; Filename: "{app}\Opticon.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Opticon.exe"; Description: "Start Opticon nu"; Flags: nowait postinstall skipifsilent
; Ved automatisk opdatering (stille installation) startes den nye version igen
Filename: "{app}\Opticon.exe"; Flags: nowait; Check: WizardSilent
