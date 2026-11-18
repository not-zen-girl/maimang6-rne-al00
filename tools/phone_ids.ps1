$ErrorActionPreference = 'SilentlyContinue'
# 桌上另一台华为设备(不是这台手机),按序列号/子节点排除掉
$other = @('2MM0223B14022394', '7&1DDC215E&3&0000')
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_12D1|VID_18D1' } | ForEach-Object {
  $id = $_.InstanceId
  $skip = $false
  foreach ($o in $other) { if ($id -like "*$o*") { $skip = $true } }
  if (-not $skip) { Write-Output ($id -replace '^USB\\', '') }
}