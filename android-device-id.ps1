$ErrorActionPreference = "Stop"
$raw = & flutter devices --machine 2>$null | Out-String
if ([string]::IsNullOrWhiteSpace($raw)) { exit 1 }

$devices = $raw | ConvertFrom-Json
$phone = @($devices) | Where-Object {
  $_.targetPlatform -like "android*" -and $_.isSupported
} | Select-Object -First 1

if (-not $phone -or -not $phone.id) { exit 1 }
Write-Output $phone.id
