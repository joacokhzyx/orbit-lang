; Inno Setup Script for Orbit Language Compiler
; To compile this installer, use the Inno Setup Compiler (ISCC)

[Setup]
AppName=Orbit Programming Language
AppVersion=0.1.0-rc.1
AppPublisher=JoacoKhzyx
DefaultDirName={localappdata}\Orbit
DefaultGroupName=Orbit
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=orbit-windows-setup
SetupIconFile=..\orbit.ico
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ChangesEnvironment=yes

[Files]
Source: "..\zig-out\bin\orbit.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\orbit.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\runtime\*"; DestDir: "{app}\src\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\src\lib\sqlite\*"; DestDir: "{app}\src\lib\sqlite"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
; Register .orb file extension
Root: HKCU; Subkey: "Software\Classes\.orb"; ValueType: string; ValueName: ""; ValueData: "OrbitSourceFile"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\OrbitSourceFile"; ValueType: string; ValueName: ""; ValueData: "Orbit Source File"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\OrbitSourceFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\orbit.ico"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\OrbitSourceFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\orbit.exe"" run ""%1"""; Flags: uninsdeletekey

[Code]
const
  EnvironmentKey = 'Environment';

procedure AddToPath();
var
  Path: string;
  NewPath: string;
begin
  if RegQueryStringValue(HKEY_CURRENT_USER, EnvironmentKey, 'PATH', Path) then
  begin
    if Pos(ExpandConstant('{app}\bin'), Path) = 0 then
    begin
      NewPath := Path + ';' + ExpandConstant('{app}\bin');
      RegWriteStringValue(HKEY_CURRENT_USER, EnvironmentKey, 'PATH', NewPath);
    end;
  end;
end;

procedure RemoveFromPath();
var
  Path: string;
  NewPath: string;
  BinDir: string;
  Index: Integer;
begin
  BinDir := ExpandConstant('{app}\bin');
  if RegQueryStringValue(HKEY_CURRENT_USER, EnvironmentKey, 'PATH', Path) then
  begin
    Index := Pos(BinDir, Path);
    if Index > 0 then
    begin
      Delete(Path, Index, Length(BinDir) + 1);
      RegWriteStringValue(HKEY_CURRENT_USER, EnvironmentKey, 'PATH', Path);
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    AddToPath();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RemoveFromPath();
  end;
end;
