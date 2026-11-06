@echo off
rem Starts the VR view (docs/BUILD.md step 6). Prefers SteamVR's OpenXR runtime when SteamVR is installed and
rem no runtime was picked by hand (XR_RUNTIME_JSON); otherwise Windows' active OpenXR runtime (e.g. Meta's).
rem With SteamVR it starts SteamVR first and waits for it: the game can't open a VR session before SteamVR's
rem compositor runs.
rem   tools\vr\play_vr.cmd [client options, e.g. --live --vr-turn=smooth]
rem Godot: %GODOT%, else Godot_v4.7.2-stable_win64.exe on the PATH.
setlocal
if "%GODOT%"=="" set "GODOT=Godot_v4.7.2-stable_win64.exe"
if not "%XR_RUNTIME_JSON%"=="" goto steamvr
set "STEAM="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| find "SteamPath"') do set "STEAM=%%b"
if "%STEAM%"=="" set "STEAM=%ProgramFiles(x86)%\Steam"
if exist "%STEAM%\steamapps\common\SteamVR\steamxr_win64.json" set "XR_RUNTIME_JSON=%STEAM%\steamapps\common\SteamVR\steamxr_win64.json"
:steamvr
if "%XR_RUNTIME_JSON%"=="" goto run
echo %XR_RUNTIME_JSON% | find /i "steamxr" >nul || goto run
tasklist /FI "IMAGENAME eq vrcompositor.exe" 2>nul | find /i "vrcompositor" >nul && goto run
for %%f in ("%XR_RUNTIME_JSON%") do set "SVR=%%~dpf"
if not exist "%SVR%bin\win64\vrstartup.exe" goto run
echo Starting SteamVR...
start "" "%SVR%bin\win64\vrstartup.exe"
set /a n=0
:wait
tasklist /FI "IMAGENAME eq vrcompositor.exe" 2>nul | find /i "vrcompositor" >nul && goto ready
set /a n+=1
if %n% geq 60 goto late
ping -n 2 127.0.0.1 >nul
goto wait
:late
echo SteamVR didn't start within 60 s; trying anyway
goto run
:ready
rem The compositor needs a few more seconds before it takes sessions.
ping -n 6 127.0.0.1 >nul
:run
rem No parenthesized blocks with the path in them: "Program Files (x86)" would end the block.
set "RT=%XR_RUNTIME_JSON%"
if "%RT%"=="" set "RT=Windows' active runtime"
echo OpenXR runtime: %RT%
"%GODOT%" --xr-mode on --path "%~dp0..\..\client" -- --vr %*
