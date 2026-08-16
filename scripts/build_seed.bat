@echo off
rem build_seed.bat - Build the C bootstrap seed (Phase S1, SOVER-0).
rem
rem   dist/orbit_bootstrap.c  self-contained C source (compiler + runtime)
rem   orbit_seed.exe          the resulting bootstrap compiler
rem
rem Compiler detection order:
rem   1. %%ORBIT_CC%%  environment override (e.g. set ORBIT_CC=gcc)
rem   2. gcc
rem   3. clang
rem   4. cl  (MSVC)
rem   5. zig cc  (bundled clang)
setlocal

set ROOT=%~dp0..
set SEED_SRC=%ROOT%\dist\orbit_bootstrap.c
set SEED_OUT=%ROOT%\dist\orbit_seed.exe

if not exist "%SEED_SRC%" (
  echo [seed] dist\orbit_bootstrap.c not found; running amalgamation...
  where python >nul 2>nul
  if errorlevel 1 (
    echo error: python is required to regenerate the amalgamation. >&2
    exit /b 1
  )
  python "%ROOT%\scripts\amalgamate.py" || exit /b 1
)

set CC=
if defined ORBIT_CC (
  set CC=%ORBIT_CC%
) else (
  where gcc >nul 2>nul && set CC=gcc
  if not defined CC ( where clang >nul 2>nul && set CC=clang )
  if not defined CC ( where cl >nul 2>nul && set CC=cl )
  if not defined CC ( where zig >nul 2>nul && set CC=zig)
)

if not defined CC (
  echo error: no C compiler found. Install gcc/clang/cl or set ORBIT_CC. >&2
  exit /b 1
)

echo [seed] compiler: %CC%
if "%CC%"=="zig" (
  zig cc -O2 -w -Wno-int-conversion -Wno-incompatible-pointer-types -o "%SEED_OUT%" "%SEED_SRC%" || exit /b 1
) else if "%CC%"=="cl" (
  cl /nologo /O2 /W0 /Fe"%SEED_OUT%" "%SEED_SRC%" || exit /b 1
) else (
  %CC% -O2 -w -Wno-int-conversion -Wno-incompatible-pointer-types -o "%SEED_OUT%" "%SEED_SRC%" || exit /b 1
)

echo [seed] built: %SEED_OUT%
endlocal