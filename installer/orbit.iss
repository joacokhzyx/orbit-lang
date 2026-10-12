; Orbit Windows installer.
;
; Built by CI on tag (see .github/workflows/release.yml); the Setup Wizard
; it produces is what installs Orbit "to perfection": binary on PATH,
; .orb association + icon, and std/ + runtime/ beside the binary so the
; resolver and the C step work outside a source checkout (the install trap
; in docs/RELEASES.md). There is no `orbit install` command by design:
; day-to-day work uses the compiler directly, releases use this wizard,
; and ovm (Orbit Version Manager) will own upgrades later.
;
; Local validation (no tag needed, per-user install, no admin):
;   iscc /DOrbitVersion=0.0.0-dev /DOrbitDist=dist installer\orbit.iss
;
; {#OrbitDist} must hold orbit-windows-x86_64.exe (the release asset name).
; {#OrbitVersion} comes from the tag (v stripped) or defaults to dev.

#define OrbitAppName "Orbit"
#ifndef OrbitVersion
  #define OrbitVersion "0.0.0-dev"
#endif
#ifndef OrbitDist
  #define OrbitDist SourcePath + "\\..\\dist"
#endif

[Setup]
AppName={#OrbitAppName}
AppVersion={#OrbitVersion}
AppPublisher=orbit-lang
AppPublisherURL=https://github.com/joacokhzyx/orbit-lang
DefaultDirName={autopf}\Orbit
DefaultGroupName=Orbit
PrivilegesRequired=lowest
ChangesAssociations=yes
OutputDir={#SourcePath}\..\dist
OutputBaseFilename=Orbit-Setup-{#OrbitVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Orbit {#OrbitVersion}
UninstallDisplayIcon={app}\orbit.ico
VersionInfoDescription=Orbit programming language installer
; No VersionInfoVersion: tags carry -rc suffixes, which are not numeric.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The release compiler, renamed to the command name.
Source: "{#OrbitDist}\orbit-windows-x86_64.exe"; DestDir: "{app}"; DestName: "orbit.exe"; Flags: ignoreversion
; New mark (assets/orbit.ico): the .orb tile and the uninstaller icon.
Source: "{#SourcePath}\..\assets\orbit.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
; std/ beside the binary: the resolver checks the binary's directory first,
; so installed users can `import "std/..."` with no checkout around.
Source: "{#SourcePath}\..\std\*"; DestDir: "{app}\std"; Flags: ignoreversion recursesubdirs createallsubdirs
; runtime/ beside the binary: compilerRuntimeDir() finds it there, so
; `orbit build` works outside the repo. Test programs ship nothing and are
; never #included by generated C, so they stay out of the installer.
Source: "{#SourcePath}\..\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "test_*.c"

[Icons]
Name: "{group}\Uninstall Orbit"; Filename: "{uninstallexe}"

[Registry]
; .orb association, per user (PrivilegesRequired=lowest forbids HKLM).
Root: HKCU; Subkey: "Software\Classes\.orb"; ValueType: string; ValueName: ""; ValueData: "OrbitLangFile"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\OrbitLangFile"; ValueType: string; ValueName: ""; ValueData: "Orbit source file"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\OrbitLangFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\orbit.ico,0"; Flags: uninsdeletekey
; Double-click checks the file: read-only, honest, never executes on open.
Root: HKCU; Subkey: "Software\Classes\OrbitLangFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\orbit.exe"" check ""%1"""; Flags: uninsdeletekey
; User PATH entry; removal on uninstall happens in [Code] below because
; uninsdeletevalue would drop PATH edits made after the install.
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Check: NeedsAddPath; Flags: preservestringtype

[Code]
function NeedsAddPath(): Boolean;
var
  Path: string;
begin
  Result := True;
  if RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    Result := Pos(';' + ExpandConstant('{app}') + ';', ';' + Path + ';') = 0;
end;

procedure RemoveAppFromPath();
var
  Path, AppDir: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    Exit;
  AppDir := ExpandConstant('{app}');
  P := Pos(';' + AppDir + ';', ';' + Path + ';');
  while P > 0 do
  begin
    Delete(Path, P, Length(AppDir) + 1);
    P := Pos(';' + AppDir + ';', ';' + Path + ';');
  end;
  if (Length(Path) > 0) and (Path[1] = ';') then
    Delete(Path, 1, 1);
  RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Path);
end;

const
  WM_WININICHANGE = 26;
  SMTO_ABORTIFHUNG = 2;

function SendMessageTimeout(hWnd: Longint; Msg: Longint; wParam: Longint; lParam: string; fuFlags: Longint; uTimeout: Longint; var lpdwResult: Longint): Longint;
  external 'SendMessageTimeoutA@user32.dll stdcall';

procedure RefreshEnvironment();
var
  Res: Longint;
begin
  SendMessageTimeout(HWND_BROADCAST, WM_WININICHANGE, 0, 'Environment', SMTO_ABORTIFHUNG, 5000, Res);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveAppFromPath();
    RefreshEnvironment();
  end;
end;
