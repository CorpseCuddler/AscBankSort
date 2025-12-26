@echo off
set "PS1=C:\SET_INSTALL_PATH\Ascension\TSM Patcher\patch-tsm-mover.ps1"
set "LUA=C:\SET_INSTALL_PATH\Ascension\Interface\AddOns\TradeSkillMaster\Core\Mover.lua"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" "%LUA%"

echo.
echo Done. Press any key to close.
pause >nul


