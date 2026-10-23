@echo off
chcp 65001 >nul
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo 请先从 https://www.python.org/downloads/ 安装 Python 3.11 或更新版本。
  echo 安装时勾选 Add Python to PATH，然后重新打开此文件。
  pause
  exit /b 1
)
python tools\configure.py
pause
