@echo off
REM ---------------------------------------------------------------------------
REM run_daily_load.bat - daily pipeline: Scryfall prices, Card Kingdom buylist,
REM ManaBox import, analytics refresh, Tableau export. Everything goes to one log.
REM Windows Task Scheduler calls this once a day.
REM ---------------------------------------------------------------------------

REM Always run from the project folder (where this .bat lives), whatever
REM folder Task Scheduler starts in.
cd /d "%~dp0"
if not exist logs mkdir logs

REM Full path to Python, because Task Scheduler may not see your PATH.
REM %LOCALAPPDATA% is the current user's AppData\Local folder (default Python install
REM location). Update Python313 if you upgrade Python.
set PYTHON=%LOCALAPPDATA%\Programs\Python\Python313\python.exe
set PYTHONIOENCODING=utf-8

echo. >> logs\daily_load.log
echo ==== Run started %date% %time% ==== >> logs\daily_load.log
"%PYTHON%" ETL\load_scryfall.py >> logs\daily_load.log 2>&1
set RESULT=%ERRORLEVEL%

REM Card Kingdom buylist (what CK pays), from MTGJSON's daily price file.
"%PYTHON%" ETL\load_buylist.py >> logs\daily_load.log 2>&1
if %ERRORLEVEL% NEQ 0 set RESULT=%ERRORLEVEL%

REM Pack contents for the "which pack should I open?" views (refreshes every 14 days;
REM usually exits at once).
"%PYTHON%" ETL\load_boosters.py >> logs\daily_load.log 2>&1
if %ERRORLEVEL% NEQ 0 set RESULT=%ERRORLEVEL%

REM Then refresh the collection and deck lists from the Google Drive exports.
REM Runs even if the price load failed, so one problem doesn't hide the other.
"%PYTHON%" ETL\import_manabox.py >> logs\daily_load.log 2>&1
if %ERRORLEVEL% NEQ 0 set RESULT=%ERRORLEVEL%

REM Finally, rebuild the analysis layer (price trend metrics) from today's data.
"%PYTHON%" ETL\refresh_analytics.py >> logs\daily_load.log 2>&1
if %ERRORLEVEL% NEQ 0 set RESULT=%ERRORLEVEL%

REM Write the dashboard datasets to CSV for Tableau Public.
"%PYTHON%" ETL\export_tableau.py >> logs\daily_load.log 2>&1
if %ERRORLEVEL% NEQ 0 set RESULT=%ERRORLEVEL%
echo ==== Run finished %date% %time% (exit code %RESULT%) ==== >> logs\daily_load.log

exit /b %RESULT%
