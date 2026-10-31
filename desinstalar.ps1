# SISVET Web - desinstalar (PowerShell como administrador):
#   irm https://raw.githubusercontent.com/jefersonrte/sisvet-instalador/main/desinstalar.ps1 | iex
# Faz um ultimo backup do banco e remove servicos, tarefa, atalho, regra de firewall e C:\sisvet, MENOS C:\sisvet\backup.
& {
$ErrorActionPreference = 'Stop'; $Raiz = 'C:\sisvet'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'abra o PowerShell como administrador.' }
if ((Get-Service SISVET-Banco -ErrorAction SilentlyContinue) -and (Test-Path "$Raiz\backup.ps1")) {
  Write-Host '>> Ultimo backup do banco'; Start-Service SISVET-Banco; Start-Sleep 3
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\backup.ps1"
}
foreach ($s in 'SISVET-Web', 'SISVET-Banco') {
  if (Get-Service $s -ErrorAction SilentlyContinue) { Stop-Service $s -Force -ErrorAction SilentlyContinue; & sc.exe delete $s | Out-Null; Write-Host ">> servico $s removido" }
}
Unregister-ScheduledTask -TaskName 'SISVET - Backup' -Confirm:$false -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'SISVET Web*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Remove-Item "$env:PUBLIC\Desktop\SISVET.url" -ErrorAction SilentlyContinue
Start-Sleep 2
if (Test-Path $Raiz) { Get-ChildItem $Raiz -Force | Where-Object Name -ne 'backup' | Remove-Item -Recurse -Force }
Write-Host "SISVET removido. Os backups ficaram em $Raiz\backup (apague a pasta se nao precisar mais)." -ForegroundColor Green
}
