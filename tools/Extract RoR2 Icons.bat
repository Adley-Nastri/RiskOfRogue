@echo off
rem Risk of Rogue: extract the item and buff icons from your own Risk of Rain 2 install.
cd /d "%~dp0"
where py >nul 2>nul && (set PY=py) || (set PY=python)
echo Installing UnityPy and Pillow (only needed once)...
%PY% -m pip install --user --quiet -r requirements.txt
if errorlevel 1 (
  echo.
  echo Could not install the Python packages. Is Python 3.10+ installed and on PATH?
  pause
  exit /b 1
)
%PY% extract_ror2_assets.py %*
echo.
pause
