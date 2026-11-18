$ErrorActionPreference = 'SilentlyContinue'
Write-Output '=== [1] present devices with a problem (Status != OK) ==='
Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' } | ForEach-Object {
  '{0,-8} {1,-14} {2} | {3}' -f $_.Status, $_.Class, $_.InstanceId, $_.FriendlyName
}
Write-Output ''
Write-Output '=== [2] all present Ports (COM/LPT) ==='
Get-PnpDevice -Class Ports -PresentOnly | ForEach-Object {
  '{0,-8} {1} | {2}' -f $_.Status, $_.InstanceId, $_.FriendlyName
}
Write-Output ''
Write-Output '=== [3] every registered VID_12D1 / VID_18D1 node, present or not ==='
Get-PnpDevice | Where-Object { $_.InstanceId -match 'VID_12D1|VID_18D1' } | ForEach-Object {
  '{0,-8} problem={1,-4} {2} | {3}' -f $_.Status, $_.Problem, $_.InstanceId, $_.FriendlyName
}
Write-Output ''
Write-Output '=== [4] all present USB-class nodes (hubs included) ==='
Get-PnpDevice -Class USB -PresentOnly | ForEach-Object {
  '{0,-8} {1} | {2}' -f $_.Status, $_.InstanceId, $_.FriendlyName
}
Write-Output ''
Write-Output '=== [5] anything at the phone hub location 1CF9034C ==='
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like '*1CF9034C*' } | ForEach-Object {
  '{0,-8} {1,-14} {2} | {3}' -f $_.Status, $_.Class, $_.InstanceId, $_.FriendlyName
}
Write-Output ''
Write-Output '=== [6] unknown / descriptor-failed USB devices ==='
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0000|UNKNOWN|FAILED' } | ForEach-Object {
  '{0,-8} {1} | {2}' -f $_.Status, $_.InstanceId, $_.FriendlyName
}