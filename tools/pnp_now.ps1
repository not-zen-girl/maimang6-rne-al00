$ErrorActionPreference = 'SilentlyContinue'
Write-Output "===== PRESENT nodes (VID_18D1 / VID_12D1) ====="
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_18D1|VID_12D1' } | ForEach-Object {
  Write-Output ("{0,-9} {1}" -f $_.Status, $_.InstanceId)
  Write-Output ("          friendly={0}  class={1}" -f $_.FriendlyName, $_.Class)
}
Write-Output ""
Write-Output "===== ALL registered D00D / 3609 instances ====="
Get-PnpDevice | Where-Object { $_.InstanceId -match 'PID_D00D|PID_3609' } | ForEach-Object {
  Write-Output ("{0,-9} present={1}  {2}" -f $_.Status, $_.Present, $_.InstanceId)
}
Write-Output ""
Write-Output "===== properties of present D00D node ====="
$d = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'PID_D00D' }
foreach ($x in $d) {
  Write-Output ("--- {0}" -f $x.InstanceId)
  Get-PnpDeviceProperty -DeviceID $x.InstanceId | Where-Object { $_.KeyName -match 'Serial|BusReported|Location|Container|Install|Driver|Desc' } | ForEach-Object {
    Write-Output ("    {0} = {1}" -f $_.KeyName, $_.Data)
  }
}