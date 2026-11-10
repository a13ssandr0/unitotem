UniTotem installer for Windows 10/11 (UEFI or legacy BIOS)

Prepares this PC to start the UniTotem OTA environment once. The host then installs UniTotem over the network
and ERASES the whole system disk.

1. Wired network required. Open PowerShell as Administrator (Safe Mode is fine).
2. powershell -ExecutionPolicy Bypass -File .\Install-UniTotem.ps1 -WhatIf
3. powershell -ExecutionPolicy Bypass -File .\Install-UniTotem.ps1 [-AuthorizedKey key.pub]
4. Restart. The screen shows the address. On the host: deploy/remote-deploy.sh recover ADDRESS --parts DIR
Cancel before the install: .\Install-UniTotem.ps1 -Undo
Details: docs/system/windows-installer.md
