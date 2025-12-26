@echo off
set "PS1=E:\Games\Ascension\patch-tsm-mover.ps1"
set "LUA=E:\Games\Ascension\Interface\AddOns\TradeSkillMaster\Core\Mover.lua"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" "%LUA%"

echo.
echo Done. Press any key to close.
pause >nul
