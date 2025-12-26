param(
  [Parameter(Mandatory=$true)]
  [string]$MoverLuaPath
)

if (!(Test-Path $MoverLuaPath)) {
  Write-Error "File not found: $MoverLuaPath"
  exit 1
}

$src = Get-Content -Raw -Encoding UTF8 $MoverLuaPath

# Backup once per run (timestamped)
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$MoverLuaPath.bak.$stamp"
Copy-Item $MoverLuaPath $backup -Force
Write-Host "Backup created: $backup"

$changed = 0

# -------------------------
# Patch 1: Reverse slot scan order (affects GetEmptySlots + findExistingStack loops)
# From: for slot = 1, TSM.getContainerNumSlotsDest(bag) do
#   To: for slot = TSM.getContainerNumSlotsDest(bag), 1, -1 do
# -------------------------
$patternLoop = 'for\s+slot\s*=\s*1\s*,\s*TSM\.getContainerNumSlotsDest\(bag\)\s+do'
$replLoop    = 'for slot = TSM.getContainerNumSlotsDest(bag), 1, -1 do'
$before = $src
$src = [regex]::Replace($src, $patternLoop, $replLoop)
$diff = ([regex]::Matches($before, $patternLoop)).Count - ([regex]::Matches($src, $patternLoop)).Count
if ($diff -gt 0) { $changed += $diff; Write-Host "Patched $diff slot loop(s) to iterate backwards." }

# -------------------------
# Patch 2: Replace AutoStore in TSM.moveItem() (bags -> bank/guildbank)
# This forces manual placement into exact dest slots (so "last slot first" actually happens).
# -------------------------

# A) bags->guildbank, existing stack branch
$patGbankStack = @'
if findExistingStack\(itemLink, bankType, need, true\) then\s*\r?\n\s*TSM\.autoStoreItem\(fullMoves\[i\]\.bag, fullMoves\[i\]\.slot\)
'@
$repGbankStack = @'
if findExistingStack(itemLink, bankType, need, true) then
						local destBag, destSlot = findExistingStack(itemLink, bankType, need, true)
						if destBag and destSlot then
							TSM.pickupContainerItemSrc(fullMoves[i].bag, fullMoves[i].slot)
							if GetCurrentGuildBankTab() ~= destBag then
								SetCurrentGuildBankTab(destBag)
							end
							TSM.pickupContainerItemDest(destBag, destSlot)
						end
'@
$before = $src
$src = [regex]::Replace($src, $patGbankStack, $repGbankStack)
if ($src -ne $before) { $changed++; Write-Host "Patched guildbank existing-stack deposit to manual placement." }

# B) bags->guildbank, empty slot branch
$patGbankEmpty = @'
elseif GetEmptySlotCount\(GetCurrentGuildBankTab\(\)\) then\s*\r?\n\s*TSM\.autoStoreItem\(fullMoves\[i\]\.bag, fullMoves\[i\]\.slot\)
'@
$repGbankEmpty = @'
elseif GetEmptySlotCount(GetCurrentGuildBankTab()) then
						local empties = GetEmptySlots(bankType)
						local destBag = GetCurrentGuildBankTab()
						local destSlot = empties[destBag] and empties[destBag][1]
						if destSlot then
							TSM.pickupContainerItemSrc(fullMoves[i].bag, fullMoves[i].slot)
							TSM.pickupContainerItemDest(destBag, destSlot)
						end
'@
$before = $src
$src = [regex]::Replace($src, $patGbankEmpty, $repGbankEmpty)
if ($src -ne $before) { $changed++; Write-Host "Patched guildbank empty-slot deposit to manual placement." }

# C) bags->bank, existing stack branch
$patBankStack = @'
if findExistingStack\(itemLink, bankType, need\) then\s*\r?\n\s*TSM\.autoStoreItem\(fullMoves\[i\]\.bag, fullMoves\[i\]\.slot\)
'@
$repBankStack = @'
if findExistingStack(itemLink, bankType, need) then
						local destBag, destSlot = findExistingStack(itemLink, bankType, need)
						if destBag and destSlot then
							TSM.pickupContainerItemSrc(fullMoves[i].bag, fullMoves[i].slot)
							TSM.pickupContainerItemDest(destBag, destSlot)
						end
'@
$before = $src
$src = [regex]::Replace($src, $patBankStack, $repBankStack)
if ($src -ne $before) { $changed++; Write-Host "Patched bank existing-stack deposit to manual placement." }

# D) bags->bank, empty slot branch
$patBankEmpty = @'
elseif next\(GetEmptySlots\(bankType\)\) ~= nil and canGoInBag\(itemString, getContainerTable\(bankType\)\) then\s*\r?\n\s*TSM\.autoStoreItem\(fullMoves\[i\]\.bag, fullMoves\[i\]\.slot\)
'@
$repBankEmpty = @'
elseif next(GetEmptySlots(bankType)) ~= nil and canGoInBag(itemString, getContainerTable(bankType)) then
						local destBag = canGoInBag(itemString, getContainerTable(bankType))
						local empties = GetEmptySlots(bankType)
						local destSlot = destBag and empties[destBag] and empties[destBag][1]
						if destBag and destSlot then
							TSM.pickupContainerItemSrc(fullMoves[i].bag, fullMoves[i].slot)
							TSM.pickupContainerItemDest(destBag, destSlot)
						end
'@
$before = $src
$src = [regex]::Replace($src, $patBankEmpty, $repBankEmpty)
if ($src -ne $before) { $changed++; Write-Host "Patched bank empty-slot deposit to manual placement." }

# -------------------------
# Patch 3: Speed up delays (0.4s -> 0.25s)
# Adjust these values if your server/client gets desyncy.
# -------------------------
$before = $src
$src = $src -replace 'TSMAPI:CreateTimeDelay\("moveItem",\s*0\.4\s*,', 'TSMAPI:CreateTimeDelay("moveItem", 0.25,'
$src = $src -replace 'TSMAPI:CreateTimeDelay\("generateMoves",\s*0\.4\s*,', 'TSMAPI:CreateTimeDelay("generateMoves", 0.25,'
if ($src -ne $before) { $changed++; Write-Host "Patched CreateTimeDelay from 0.4s to 0.25s (where matched)." }

if ($changed -eq 0) {
  Write-Warning "No changes were applied. This usually means your file differs from the expected patterns or is already patched."
  Write-Host "No file was written."
  exit 0
}

Set-Content -Encoding UTF8 -NoNewline -Path $MoverLuaPath -Value $src
Write-Host "Done. Patched: $MoverLuaPath"
