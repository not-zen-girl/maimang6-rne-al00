$ErrorActionPreference = 'SilentlyContinue'
$logs = @('Microsoft-Windows-Kernel-PnP/Configuration','System')
foreach ($lg in $logs) {
  $ev = Get-WinEvent -LogName $lg -MaxEvents 1500
  if (-not $ev) { continue }
  $hit = $ev | Where-Object { $_.Message -match 'PID_3609|PID_D00D|1CF9034C' }
  if (-not $hit) { continue }
  Write-Output "===== $lg ====="
  $hit | Select-Object -First 60 | ForEach-Object {
    $m = ($_.Message -split [Environment]::NewLine)[0]
    if ($m.Length -gt 150) { $m = $m.Substring(0,150) }
    Write-Output ("{0:MM-dd HH:mm:ss}  id={1}  {2}" -f $_.TimeCreated, $_.Id, $m)
  }
}