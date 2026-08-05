@echo off
REM Double-click entry point: runs run.sh through Git Bash, since
REM Windows has no native association for .sh files.
cd /d "%~dp0"
"C:\Users\dmitr\scoop\apps\git\2.55.0.3\usr\bin\bash.exe" run.sh
pause
