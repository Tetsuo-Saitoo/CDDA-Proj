@echo off
rem Starts the VR view (docs/BUILD.md step 6). Prefers SteamVR's OpenXR runtime when SteamVR is installed and
rem no runtime was picked by hand (XR_RUNTIME_JSON); otherwise Windows' active OpenXR runtime (e.g. Meta's).
rem   tools\vr\play_vr.cmd [client options, e.g. --live --vr-turn=smooth]
rem Godot: %GODOT%, else Godot_v4.7.2-stable_win64.exe on the PATH.
setlocal
if "%GODOT%"=="" set "GODOT=Godot_v4.7.2-stable_win64.exe"
if not "%XR_RUNTIME_JSON%"=="" goto run
set "STEAM="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| find "SteamPath"') do set "STEAM=%%b"
if "%STEAM%"=="" set "STEAM=%ProgramFiles(x86)%\Steam"
if exist "%STEAM%\steamapps\common\SteamVR\steamxr_win64.json" set "XR_RUNTIME_JSON=%STEAM%\steamapps\common\SteamVR\steamxr_win64.json"
:run
if "%XR_RUNTIME_JSON%"=="" (echo OpenXR runtime: Windows' active runtime) else (echo OpenXR runtime: %XR_RUNTIME_JSON%)
"%GODOT%" --xr-mode on --path "%~dp0..\..\client" -- --vr %*
