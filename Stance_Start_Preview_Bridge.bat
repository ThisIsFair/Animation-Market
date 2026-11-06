@echo off
cd /d "%~dp0"
where py >nul 2>&1
if %errorlevel%==0 (
    py -3 "%~dp0Stance_Preview_Bridge.py"
    goto done
)
where python >nul 2>&1
if %errorlevel%==0 (
    python "%~dp0Stance_Preview_Bridge.py"
    goto done
)
echo Python 3 is required to run the Stance Preview Bridge.
echo Install it from https://www.python.org/downloads/
:done
pause
