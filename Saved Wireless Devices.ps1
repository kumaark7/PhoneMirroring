$ErrorActionPreference = "Stop"

$storagePath = Join-Path $PSScriptRoot "phone-mirror-devices.json"
$mirrorScript = Join-Path $PSScriptRoot "start-phone-mirror.ps1"

if (-not (Test-Path $storagePath)) {
  [pscustomobject]@{
    devices = @()
    lastUpdated = $null
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $storagePath -Encoding UTF8

  Write-Host "No saved wireless devices yet." -ForegroundColor Yellow
  Write-Host "Use USB Mirror or Wireless Mirror once, then this list will fill automatically." -ForegroundColor Yellow
  exit 1
}

try {
  $data = Get-Content -LiteralPath $storagePath -Raw | ConvertFrom-Json
}
catch {
  Write-Host "Could not read saved device data." -ForegroundColor Red
  exit 1
}

$devices = @($data.devices | Where-Object { $_.lastKnownIp })
if ($devices.Count -eq 0) {
  Write-Host "No saved wireless-capable devices found." -ForegroundColor Yellow
  Write-Host "Use USB Mirror or Wireless Mirror once, then this list will fill automatically." -ForegroundColor Yellow
  exit 1
}

while ($true) {
  Clear-Host
  Write-Host "============================" -ForegroundColor Cyan
  Write-Host "  SAVED WIRELESS DEVICES" -ForegroundColor Cyan
  Write-Host "============================" -ForegroundColor Cyan
  Write-Host ""

  for ($i = 0; $i -lt $devices.Count; $i++) {
    $device = $devices[$i]
    $name = if ($device.displayName) { $device.displayName } else { $device.id }
    if ($device.tag) {
      $name = "$name [$($device.tag)]"
    }

    $port = if ($device.lastWirelessPort) { $device.lastWirelessPort } else { 5555 }
    Write-Host "$($i + 1). $name"
    Write-Host "   IP: $($device.lastKnownIp)   Port: $port"
    Write-Host ""
  }

  Write-Host "0. Back"
  Write-Host ""
  $choice = Read-Host "Select device"

  if ($choice -eq "0") {
    exit 0
  }

  $index = 0
  if (-not [int]::TryParse($choice, [ref]$index)) {
    continue
  }

  if ($index -lt 1 -or $index -gt $devices.Count) {
    continue
  }

  $selected = $devices[$index - 1]
  $port = if ($selected.lastWirelessPort) { [int]$selected.lastWirelessPort } else { 5555 }
  $dimChoice = Read-Host "Dim phone screen while mirroring? (Y/N)"
  $dimPhoneScreen = $dimChoice -match '^(y|yes)$'

  Write-Host ""
  Write-Host "Starting wireless mirror for $($selected.displayName)..." -ForegroundColor Green
  $mirrorArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $mirrorScript, "-Wireless", "-PhoneIp", $selected.lastKnownIp, "-Port", $port)
  if ($dimPhoneScreen) {
    $mirrorArgs += "-DimPhoneScreen"
  }

  & powershell.exe @mirrorArgs
  Write-Host ""
  pause
}
