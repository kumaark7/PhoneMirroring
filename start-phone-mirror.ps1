param(
  [switch]$Wireless,
  [switch]$PairWireless,
  [string]$PhoneIp,
  [int]$Port = 5555,
  [int]$PairPort,
  [string]$PairCode,
  [switch]$DimPhoneScreen,
  [ValidateSet("Normal", "Right", "UpsideDown", "Left")]
  [string]$Rotate
)

$ErrorActionPreference = "Stop"
$deviceStorePath = Join-Path $PSScriptRoot "phone-mirror-devices.json"

function Find-ToolPath {
  param(
    [string]$CommandName,
    [string[]]$FallbackPaths
  )

  $command = Get-Command $CommandName -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  foreach ($path in $FallbackPaths) {
    if (Test-Path $path) {
      return $path
    }
  }

  return $null
}

function Get-PortableToolPaths {
  param(
    [string[]]$RelativePaths
  )

  return @($RelativePaths | ForEach-Object { Join-Path $PSScriptRoot $_ })
}

function Get-ReadyDevices {
  param(
    [string]$AdbExecutable
  )

  $deviceLines = & $AdbExecutable devices | Select-Object -Skip 1 | Where-Object { $_.Trim() }
  return @($deviceLines | Where-Object { $_ -match "\sdevice$" })
}

function Get-DeviceSerial {
  param(
    [string[]]$ReadyDevices
  )

  if (-not $ReadyDevices -or $ReadyDevices.Count -eq 0) {
    return $null
  }

  return ($ReadyDevices[0] -split '\s+')[0]
}

function Get-DeviceIp {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial
  )

  $routeArgs = @()
  if ($DeviceSerial) {
    $routeArgs += @("-s", $DeviceSerial)
  }

  $routeArgs += @("shell", "ip", "route")
  $routeInfo = & $AdbExecutable @routeArgs 2>$null
  if (-not $routeInfo) {
    return $null
  }

  foreach ($line in $routeInfo) {
    if ($line -match 'src\s+(\d+\.\d+\.\d+\.\d+)') {
      return $matches[1]
    }
  }

  return $null
}

function Get-WirelessTarget {
  param(
    [string]$AdbExecutable,
    [string]$RequestedIp
  )

  $deviceLines = & $AdbExecutable devices | Select-Object -Skip 1 | Where-Object { $_.Trim() }
  $tcpDevices = @($deviceLines | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+:\d+\s+device$' })

  if ($RequestedIp) {
    $match = $tcpDevices | Where-Object { $_ -match "^$([regex]::Escape($RequestedIp)):" } | Select-Object -First 1
    if ($match) {
      return ($match -split '\s+')[0]
    }

    return $null
  }

  if ($tcpDevices.Count -gt 0) {
    return ($tcpDevices[0] -split '\s+')[0]
  }

  return $null
}

function Invoke-Adb {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string[]]$Arguments
  )

  $adbArgs = @()
  if ($DeviceSerial) {
    $adbArgs += @("-s", $DeviceSerial)
  }

  $adbArgs += $Arguments
  & $AdbExecutable @adbArgs
}

function ConvertTo-CommandLineArgument {
  param(
    [string]$Value
  )

  if ($null -eq $Value) {
    return '""'
  }

  if ($Value -notmatch '[\s"]') {
    return $Value
  }

  return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-AdbWithTimeout {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string[]]$Arguments,
    [int]$TimeoutSeconds = 8
  )

  $adbArgs = @()
  if ($DeviceSerial) {
    $adbArgs += @("-s", $DeviceSerial)
  }

  $adbArgs += $Arguments

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $AdbExecutable
  $startInfo.Arguments = ($adbArgs | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join " "
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo

  try {
    [void]$process.Start()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $completed) {
      try {
        $process.Kill()
      }
      catch {
      }

      return [pscustomobject]@{
        ExitCode = 124
        TimedOut = $true
        Output = @()
        Error = @("ADB command timed out.")
      }
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      TimedOut = $false
      Output = @($stdout -split "`r?`n" | Where-Object { $_ })
      Error = @($stderr -split "`r?`n" | Where-Object { $_ })
    }
  }
  finally {
    $process.Dispose()
  }
}

function Write-AdbResult {
  param(
    [pscustomobject]$Result
  )

  foreach ($line in $Result.Output) {
    Write-Host $line
  }

  foreach ($line in $Result.Error) {
    Write-Host $line -ForegroundColor Yellow
  }
}

function Get-DeviceProperty {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$PropertyName
  )

  $value = Invoke-Adb -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "getprop", $PropertyName) 2>$null
  if (-not $value) {
    return $null
  }

  return ($value | Select-Object -First 1).Trim()
}

function Get-FriendlyDeviceName {
  param(
    [string]$Manufacturer,
    [string]$Model
  )

  $parts = @($Manufacturer, $Model) | Where-Object { $_ }
  if ($parts.Count -eq 0) {
    return $null
  }

  return ($parts -join " ")
}

function Read-DeviceStore {
  if (-not (Test-Path $deviceStorePath)) {
    $store = [pscustomobject]@{
      devices = @()
      lastUpdated = $null
    }
    $store | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $deviceStorePath -Encoding UTF8
    return $store
  }

  try {
    $store = Get-Content -LiteralPath $deviceStorePath -Raw | ConvertFrom-Json
  }
  catch {
    Write-Host "Saved device data is damaged, so this run will not update it." -ForegroundColor Yellow
    return $null
  }

  if (-not $store.devices) {
    $store | Add-Member -MemberType NoteProperty -Name devices -Value @()
  }

  return $store
}

function Save-DeviceRecord {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$ConnectionMode,
    [string]$PhoneIp,
    [int]$WirelessPort,
    [string]$WirelessTarget,
    [int]$PairingPort
  )

  $store = Read-DeviceStore
  if (-not $store) {
    return
  }

  $now = Get-Date -Format "s"
  $manufacturer = Get-DeviceProperty -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -PropertyName "ro.product.manufacturer"
  $model = Get-DeviceProperty -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -PropertyName "ro.product.model"
  $deviceName = Get-DeviceProperty -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -PropertyName "ro.product.device"
  $friendlyName = Get-FriendlyDeviceName -Manufacturer $manufacturer -Model $model
  $baseSerial = if ($DeviceSerial -and -not $DeviceSerial.Contains(":")) { $DeviceSerial } else { $null }
  $recordId = if ($baseSerial) { $baseSerial } elseif ($WirelessTarget) { $WirelessTarget } elseif ($PhoneIp) { $PhoneIp } else { return }

  $devices = @($store.devices)
  $existing = $devices | Where-Object {
    $_.id -eq $recordId -or
    ($baseSerial -and $_.baseSerial -eq $baseSerial) -or
    ($PhoneIp -and $_.lastKnownIp -eq $PhoneIp)
  } | Select-Object -First 1

  if ($existing) {
    $recordId = $existing.id
  }
  else {
    $existing = [pscustomobject]@{
      id = $recordId
      createdAt = $now
    }
    $devices += $existing
  }

  $updates = @{
    id = $recordId
    baseSerial = $baseSerial
    lastUsbSerial = if ($DeviceSerial -and -not $DeviceSerial.Contains(":")) { $DeviceSerial } else { $null }
    manufacturer = $manufacturer
    model = $model
    deviceName = $deviceName
    displayName = $friendlyName
    effectiveName = $friendlyName
    lastKnownIp = $PhoneIp
    lastWirelessPort = $WirelessPort
    lastWirelessTarget = $WirelessTarget
    lastPairPort = $PairingPort
    lastConnectionMode = $ConnectionMode
    lastSeenAt = $now
  }

  foreach ($key in $updates.Keys) {
    $value = $updates[$key]
    if ($null -eq $value -or $value -eq "" -or $value -eq 0) {
      continue
    }

    if ($existing.PSObject.Properties.Name -contains $key) {
      $existing.$key = $value
    }
    else {
      $existing | Add-Member -MemberType NoteProperty -Name $key -Value $value
    }
  }

  $store.devices = @($devices | Sort-Object -Property lastSeenAt -Descending)
  $store.lastUpdated = $now
  $store | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $deviceStorePath -Encoding UTF8
}

function Get-ScreenIsOn {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial
  )

  $powerInfo = Invoke-Adb -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "dumpsys", "power") 2>$null
  if (-not $powerInfo) {
    return $null
  }

  foreach ($line in $powerInfo) {
    if ($line -match 'mWakefulness=(Awake|Dreaming)') {
      return $true
    }
  }

  foreach ($line in $powerInfo) {
    if ($line -match 'Display State=ON' -or $line -match 'mScreenState=ON') {
      return $true
    }
  }

  return $false
}

function Set-ScreenPowerState {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [bool]$TurnOn
  )

  $currentState = Get-ScreenIsOn -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial
  if ($null -eq $currentState) {
    return
  }

  if ($TurnOn -and -not $currentState) {
    Invoke-Adb -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "keyevent", "POWER") | Out-Null
  }

  if (-not $TurnOn -and $currentState) {
    Invoke-Adb -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "keyevent", "POWER") | Out-Null
  }
}

function Get-SystemSetting {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$SettingName
  )

  $result = Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "settings", "get", "system", $SettingName) -TimeoutSeconds 3
  if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not $result.Output) {
    return $null
  }

  $value = ($result.Output | Select-Object -First 1).Trim()
  if ($value -eq "null") {
    return $null
  }

  return $value
}

function Set-SystemSetting {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$SettingName,
    [string]$Value
  )

  return Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "settings", "put", "system", $SettingName, $Value) -TimeoutSeconds 3
}

function Enable-DimPhoneScreen {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial
  )

  if (-not $DimPhoneScreen) {
    return $null
  }

  $state = [pscustomobject]@{
    BrightnessMode = Get-SystemSetting -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -SettingName "screen_brightness_mode"
    Brightness = Get-SystemSetting -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -SettingName "screen_brightness"
  }

  Write-Host "Dimming phone screen while mirroring..." -ForegroundColor Yellow
  Set-SystemSetting -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -SettingName "screen_brightness_mode" -Value "0" | Out-Null
  Set-SystemSetting -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -SettingName "screen_brightness" -Value "1" | Out-Null

  return $state
}

function Restore-DimPhoneScreen {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [pscustomobject]$State
  )

  if (-not $DimPhoneScreen -or -not $State) {
    return
  }

  Write-Host "Restoring phone brightness..." -ForegroundColor Yellow

  if ($State.Brightness) {
    Set-SystemSetting -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -SettingName "screen_brightness" -Value $State.Brightness | Out-Null
  }

  if ($State.BrightnessMode) {
    Set-SystemSetting -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -SettingName "screen_brightness_mode" -Value $State.BrightnessMode | Out-Null
  }
}

function Disconnect-WirelessAdb {
  param(
    [string]$AdbExecutable,
    [string]$WirelessTarget
  )

  Write-Host "Mirror window closed. Ending wireless connection..." -ForegroundColor Yellow

  if ($WirelessTarget) {
    $targetDisconnect = Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -Arguments @("disconnect", $WirelessTarget) -TimeoutSeconds 5
    Write-AdbResult -Result $targetDisconnect
  }

  $allDisconnect = Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -Arguments @("disconnect") -TimeoutSeconds 5
  Write-AdbResult -Result $allDisconnect
}

function Get-RotationValue {
  param(
    [string]$RotateOption
  )

  if (-not $RotateOption) {
    return $null
  }

  $rotationMap = @{
    Normal = "0"
    Right = "90"
    UpsideDown = "180"
    Left = "270"
  }

  return $rotationMap[$RotateOption]
}

function Start-ScrcpySession {
  param(
    [string]$AdbExecutable,
    [string]$ScrcpyExecutable,
    [string]$DeviceSerial,
    [string[]]$ConnectionArguments,
    [scriptblock]$OnSessionClosed
  )

  $scrcpyArgs = @("--stay-awake")

  if ($DeviceSerial) {
    $scrcpyArgs += "--serial=$DeviceSerial"
  }

  $rotationValue = Get-RotationValue -RotateOption $Rotate
  if ($rotationValue) {
    $scrcpyArgs += "--display-orientation=$rotationValue"
  }

  if ($ConnectionArguments) {
    $scrcpyArgs += $ConnectionArguments
  }

  $scrcpyExitCode = 0
  $dimState = Enable-DimPhoneScreen -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial

  try {
    & $ScrcpyExecutable @scrcpyArgs
    $scrcpyExitCode = $LASTEXITCODE
  }
  finally {
    Restore-DimPhoneScreen -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -State $dimState

    if ($OnSessionClosed) {
      & $OnSessionClosed
    }
  }

  exit $scrcpyExitCode
}

$portableAdbPaths = Get-PortableToolPaths @(
  "adb.exe",
  "platform-tools\adb.exe",
  "tools\adb.exe",
  "tools\platform-tools\adb.exe"
)

$adbFallbackPaths = @($portableAdbPaths) + @("C:\adb\adb.exe")
$adbPath = Find-ToolPath -CommandName "adb" -FallbackPaths $adbFallbackPaths

if (-not $adbPath) {
  Write-Host "ADB was not found. Install Android platform-tools first." -ForegroundColor Red
  exit 1
}

$portableScrcpyPaths = Get-PortableToolPaths @(
  "scrcpy.exe",
  "scrcpy-win64\scrcpy.exe",
  "scrcpy-win32\scrcpy.exe",
  "tools\scrcpy.exe",
  "tools\scrcpy-win64\scrcpy.exe",
  "tools\scrcpy-win32\scrcpy.exe"
)

$scrcpyFallbackPaths = @($portableScrcpyPaths) + @(
  "C:\ProgramData\chocolatey\bin\scrcpy.exe",
  "C:\ProgramData\chocolatey\lib\scrcpy\tools\scrcpy.exe",
  "C:\scrcpy\scrcpy.exe"
)
$scrcpyPath = Find-ToolPath -CommandName "scrcpy" -FallbackPaths $scrcpyFallbackPaths

if (-not $scrcpyPath) {
  Write-Host "scrcpy is not installed yet." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Install it with one of these commands, then run this script again:" -ForegroundColor Yellow
  Write-Host "  choco install scrcpy -y"
  Write-Host "  winget install Genymobile.scrcpy"
  exit 1
}

if ($PairWireless) {
  Write-Host "Preparing direct wireless pairing..." -ForegroundColor Cyan
  Write-Host "On the phone open Developer options > Wireless debugging > Pair device with pairing code." -ForegroundColor Yellow

  if (-not $PhoneIp) {
    $PhoneIp = Read-Host "Enter the phone IP address shown on the phone"
  }

  if (-not $PairPort) {
    $pairPortInput = Read-Host "Enter the pairing port shown on the phone"
    if (-not [int]::TryParse($pairPortInput, [ref]$PairPort)) {
      Write-Host "The pairing port must be a number." -ForegroundColor Red
      exit 1
    }
  }

  if (-not $PairCode) {
    $PairCode = Read-Host "Enter the pairing code shown on the phone"
  }

  if (-not $PhoneIp -or -not $PairPort -or -not $PairCode) {
    Write-Host "Phone IP, pairing port, and pairing code are all required." -ForegroundColor Red
    exit 1
  }

  $pairResult = Invoke-AdbWithTimeout -AdbExecutable $adbPath -Arguments @("pair", "${PhoneIp}:$PairPort", $PairCode) -TimeoutSeconds 20
  Write-AdbResult -Result $pairResult
  if ($pairResult.TimedOut) {
    Write-Host "Wireless pairing timed out. Make sure the phone is nearby, unlocked, and still showing the pairing code." -ForegroundColor Red
    exit 1
  }

  if ($pairResult.ExitCode -ne 0) {
    Write-Host "Wireless pairing failed." -ForegroundColor Red
    exit $pairResult.ExitCode
  }

  Start-Sleep -Seconds 2
  $wirelessTarget = Get-WirelessTarget -AdbExecutable $adbPath -RequestedIp $PhoneIp
  if (-not $wirelessTarget) {
    $wirelessTarget = Read-Host "Enter the wireless debugging address shown on the phone (example: 192.168.1.5:37639)"
  }

  if (-not $wirelessTarget) {
    Write-Host "A wireless debugging address is required after pairing." -ForegroundColor Red
    exit 1
  }

  $connectResult = Invoke-AdbWithTimeout -AdbExecutable $adbPath -Arguments @("connect", $wirelessTarget) -TimeoutSeconds 10
  Write-AdbResult -Result $connectResult
  if ($connectResult.TimedOut) {
    Write-Host "The device is not available over Wi-Fi right now. Check Wireless debugging and Wi-Fi, then try again." -ForegroundColor Red
    exit 1
  }

  Start-Sleep -Seconds 2

  $wirelessReady = Get-WirelessTarget -AdbExecutable $adbPath -RequestedIp $PhoneIp
  if (-not $wirelessReady) {
    Write-Host "The phone did not come online over Wi-Fi." -ForegroundColor Yellow
    Write-Host "Make sure the phone and PC are on the same Wi-Fi network and Wireless debugging stays enabled."
    exit 1
  }

  $readyTargetParts = $wirelessReady -split ":"
  $readyIp = $readyTargetParts[0]
  $readyPort = if ($readyTargetParts.Count -gt 1) { [int]$readyTargetParts[1] } else { 0 }
  Save-DeviceRecord -AdbExecutable $adbPath -DeviceSerial $wirelessReady -ConnectionMode "PairedWireless" -PhoneIp $readyIp -WirelessPort $readyPort -WirelessTarget $wirelessReady -PairingPort $PairPort

  Write-Host "Starting wireless phone mirror and control..." -ForegroundColor Green
  if ($DimPhoneScreen) {
    Write-Host "The phone screen will stay on but very dim." -ForegroundColor Green
  }
  Write-Host "Clipboard sync is handled by scrcpy, so copy and paste should work while connected." -ForegroundColor Green

  Start-ScrcpySession -AdbExecutable $adbPath -ScrcpyExecutable $scrcpyPath -DeviceSerial $wirelessReady -ConnectionArguments @() -OnSessionClosed {
    Disconnect-WirelessAdb -AdbExecutable $adbPath -WirelessTarget $wirelessReady
  }
}

if ($Wireless) {
  Write-Host "Preparing wireless Android mirroring..." -ForegroundColor Cyan

  $readyDevices = Get-ReadyDevices -AdbExecutable $adbPath
  $usbReadyDevices = @($readyDevices | Where-Object { $_ -notmatch '^\d+\.\d+\.\d+\.\d+:\d+\s+device$' })
  $usbSerial = Get-DeviceSerial -ReadyDevices $usbReadyDevices

  if (-not $PhoneIp) {
    if (-not $usbSerial) {
      Write-Host "No ready USB-connected phone was found for wireless setup." -ForegroundColor Yellow
      Write-Host ""
      Write-Host "For the first wireless setup, connect the phone with USB, unlock it, and allow USB debugging."
      exit 1
    }

    $PhoneIp = Get-DeviceIp -AdbExecutable $adbPath -DeviceSerial $usbSerial
  }

  if (-not $PhoneIp) {
    Write-Host "Could not detect the phone IP address automatically." -ForegroundColor Yellow
    Write-Host "Reconnect with USB and keep the phone unlocked, or run with -PhoneIp 192.168.x.x"
    exit 1
  }

  Write-Host "Using phone IP $PhoneIp on port $Port" -ForegroundColor Green

  if ($usbSerial) {
    $tcpipResult = Invoke-AdbWithTimeout -AdbExecutable $adbPath -DeviceSerial $usbSerial -Arguments @("tcpip", "$Port") -TimeoutSeconds 8
    Write-AdbResult -Result $tcpipResult
    if ($tcpipResult.TimedOut) {
      Write-Host "The USB-connected device did not respond while switching to wireless mode." -ForegroundColor Red
      Write-Host "Unplug/replug USB, unlock the phone, allow debugging, then try again." -ForegroundColor Yellow
      exit 1
    }

    if ($tcpipResult.ExitCode -ne 0) {
      Write-Host "Could not switch the phone to wireless ADB mode." -ForegroundColor Red
      exit $tcpipResult.ExitCode
    }

    Start-Sleep -Seconds 2
  }

  $connectResult = Invoke-AdbWithTimeout -AdbExecutable $adbPath -Arguments @("connect", "${PhoneIp}:$Port") -TimeoutSeconds 10
  Write-AdbResult -Result $connectResult
  if ($connectResult.TimedOut) {
    Write-Host "The saved wireless device is not available right now." -ForegroundColor Red
    Write-Host "Make sure the phone is on the same Wi-Fi network and Wireless debugging is enabled." -ForegroundColor Yellow
    exit 1
  }

  Start-Sleep -Seconds 2

  $wirelessTarget = "${PhoneIp}:$Port"
  $wirelessReady = @((& $adbPath devices | Select-Object -Skip 1 | Where-Object { $_.Trim() }) | Where-Object { $_ -match "^$([regex]::Escape($wirelessTarget))\s+device$" })
  if ($wirelessReady.Count -eq 0) {
    Write-Host "Wireless ADB did not come online yet." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Make sure the phone and PC are on the same Wi-Fi network, then try again."
    exit 1
  }

  Save-DeviceRecord -AdbExecutable $adbPath -DeviceSerial $wirelessTarget -ConnectionMode "Wireless" -PhoneIp $PhoneIp -WirelessPort $Port -WirelessTarget $wirelessTarget

  Write-Host "Starting wireless phone mirror and control..." -ForegroundColor Green
  if ($DimPhoneScreen) {
    Write-Host "The phone screen will stay on but very dim." -ForegroundColor Green
  }
  Write-Host "Clipboard sync is handled by scrcpy, so copy and paste should work while connected." -ForegroundColor Green

  Start-ScrcpySession -AdbExecutable $adbPath -ScrcpyExecutable $scrcpyPath -DeviceSerial $wirelessTarget -ConnectionArguments @() -OnSessionClosed {
    Disconnect-WirelessAdb -AdbExecutable $adbPath -WirelessTarget $wirelessTarget
  }
}

Write-Host "Checking for a connected Android phone..." -ForegroundColor Cyan
$readyDevices = Get-ReadyDevices -AdbExecutable $adbPath

if ($readyDevices.Count -eq 0) {
  Write-Host "No ready phone was found." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Do this on your phone, then run the script again:"
  Write-Host "  1. Enable Developer options"
  Write-Host "  2. Turn on USB debugging"
  Write-Host "  3. Connect the phone with a USB cable"
  Write-Host "  4. Tap Allow on the USB debugging prompt"
  exit 1
}

Write-Host "Starting phone mirror and control..." -ForegroundColor Green
if ($DimPhoneScreen) {
  Write-Host "The phone screen will stay on but very dim." -ForegroundColor Green
}
Write-Host "Clipboard sync is handled by scrcpy, so copy and paste should work while connected." -ForegroundColor Green

$deviceSerial = Get-DeviceSerial -ReadyDevices $readyDevices
Save-DeviceRecord -AdbExecutable $adbPath -DeviceSerial $deviceSerial -ConnectionMode "USB" -PhoneIp (Get-DeviceIp -AdbExecutable $adbPath -DeviceSerial $deviceSerial)
Start-ScrcpySession -AdbExecutable $adbPath -ScrcpyExecutable $scrcpyPath -DeviceSerial $deviceSerial -ConnectionArguments @()
