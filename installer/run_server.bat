@echo off
REM AutoCadController - run FastAPI server
REM Requires Python in PATH and dependencies installed (pip install -r requirements.txt)
cd /d "%~dp0"
python -m uvicorn main:app --host 127.0.0.1 --port 5000 --reload
pause
