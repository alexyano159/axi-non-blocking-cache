@echo off
REM Double-click entry point: runs run.sh through Git Bash, since
REM Windows has no native association for .sh files.
REM Optional argument: testbench name (default: mshr_tb), e.g.
REM   run.bat cache_tag_array_tb
cd /d "%~dp0"
"C:\Program Files\Git\bin\bash.exe" run.sh %*
pause
