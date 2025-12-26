Put "TSM Patcher" folder in:

C:\YOUR-INSTALL-PATH\Ascension\


(or anywhere — paths just need to match inside the .bat)

Edit PatchTSM.bat if needed

Open PatchTSM.bat in Notepad and make sure these paths match your setup:

set "PS1=C:\YOUR-INSTALL-PATH\Ascension\TSM Patcher\patch-tsm-mover.ps1"
set "LUA=C:\YOUR-INSTALL-PATH\Ascension\Interface\AddOns\TradeSkillMaster\Core\Mover.lua"


Run the patch
Double-click PatchTSM.bat.

You should see a message about a backup being created and the file being patched.

Do this again only after TSM updates
TSM updates overwrite Mover.lua, so just re-run PatchTSM.bat when that happens.
