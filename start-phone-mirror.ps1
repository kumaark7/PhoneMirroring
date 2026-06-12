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
$unlockStorePath = Join-Path $PSScriptRoot "phone-mirror-unlock.json"

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

function Get-ConnectedDeviceName {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial
  )

  $manufacturer = Get-DeviceProperty -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -PropertyName "ro.product.manufacturer"
  $model = Get-DeviceProperty -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -PropertyName "ro.product.model"
  $friendlyName = Get-FriendlyDeviceName -Manufacturer $manufacturer -Model $model
  if ($friendlyName) {
    return $friendlyName
  }

  return $DeviceSerial
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

function Read-PlainTextSecret {
  param(
    [string]$Prompt
  )

  $secureValue = Read-Host $Prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Read-UnlockStore {
  if (-not (Test-Path $unlockStorePath)) {
    return [pscustomobject]@{
      credentials = @()
      lastUpdated = $null
    }
  }

  try {
    $store = Get-Content -LiteralPath $unlockStorePath -Raw | ConvertFrom-Json
  }
  catch {
    Write-Host "Saved unlock data is damaged, so saved unlocks are unavailable." -ForegroundColor Yellow
    return $null
  }

  if (-not $store.credentials) {
    $store | Add-Member -MemberType NoteProperty -Name credentials -Value @()
  }

  return $store
}

function Save-UnlockStore {
  param(
    [pscustomobject]$Store
  )

  $Store.lastUpdated = Get-Date -Format "s"
  $Store | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unlockStorePath -Encoding UTF8
}

function Save-UnlockCredential {
  param(
    [string]$DeviceKey,
    [string]$DeviceName,
    [string]$Kind,
    [string]$Value,
    [int]$GridSize
  )

  $saveChoice = Read-Host "Save this $Kind for next time? (Y/N)"
  if ($saveChoice -notmatch '^(y|yes)$') {
    return
  }

  $store = Read-UnlockStore
  if (-not $store) {
    return
  }

  $label = Read-Host "Name for this saved unlock"
  if (-not $label) {
    $label = "$DeviceName - $Kind"
  }

  $credentials = @($store.credentials)
  $credentials += [pscustomobject]@{
    id = [guid]::NewGuid().ToString()
    deviceKey = $DeviceKey
    deviceName = $DeviceName
    label = $label
    kind = $Kind
    value = $Value
    gridSize = $GridSize
    createdAt = Get-Date -Format "s"
  }

  $store.credentials = $credentials
  Save-UnlockStore -Store $store
  Write-Host "Saved unlock credential." -ForegroundColor Green
}

function Get-SavedUnlockCredentials {
  param(
    [string]$DeviceKey
  )

  $store = Read-UnlockStore
  if (-not $store) {
    return @()
  }

  return @($store.credentials | Where-Object { $_.deviceKey -eq $DeviceKey })
}

function Invoke-WakeAndSwipeUnlock {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial
  )

  Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "keyevent", "WAKEUP") -TimeoutSeconds 3 | Out-Null
  Start-Sleep -Milliseconds 300
  Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "swipe", "500", "1800", "500", "600", "250") -TimeoutSeconds 3 | Out-Null
  Start-Sleep -Milliseconds 300
}

function ConvertTo-AdbInputText {
  param(
    [string]$Text
  )

  return ($Text -replace ' ', '%s')
}

function Invoke-TextUnlock {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$Text
  )

  Invoke-WakeAndSwipeUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial
  $adbText = ConvertTo-AdbInputText -Text $Text
  Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "text", $adbText) -TimeoutSeconds 5 | Out-Null
  Start-Sleep -Milliseconds 200
  Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "keyevent", "ENTER") -TimeoutSeconds 3 | Out-Null
}

function Get-DeviceScreenSize {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial
  )

  $result = Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "wm", "size") -TimeoutSeconds 3
  $line = ($result.Output | Select-Object -First 1)
  if ($line -match '(\d+)x(\d+)') {
    return [pscustomobject]@{
      Width = [int]$matches[1]
      Height = [int]$matches[2]
    }
  }

  return [pscustomobject]@{
    Width = 1080
    Height = 2400
  }
}

function Get-PatternPoint {
  param(
    [int]$Number,
    [int]$GridSize,
    [int]$Width,
    [int]$Height
  )

  $index = $Number - 1
  $row = [math]::Floor($index / $GridSize)
  $col = $index % $GridSize
  $left = [int]($Width * 0.20)
  $right = [int]($Width * 0.80)
  $top = [int]($Height * 0.34)
  $bottom = [int]($Height * 0.74)
  $xStep = if ($GridSize -gt 1) { ($right - $left) / ($GridSize - 1) } else { 0 }
  $yStep = if ($GridSize -gt 1) { ($bottom - $top) / ($GridSize - 1) } else { 0 }

  return [pscustomobject]@{
    X = [int]($left + ($col * $xStep))
    Y = [int]($top + ($row * $yStep))
  }
}

function Invoke-PatternUnlock {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [int]$GridSize,
    [string]$Pattern
  )

  $numbers = @($Pattern -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
  if ($numbers.Count -lt 2) {
    Write-Host "Pattern needs at least two points." -ForegroundColor Yellow
    return
  }

  $max = $GridSize * $GridSize
  foreach ($number in $numbers) {
    if ($number -lt 1 -or $number -gt $max) {
      Write-Host "Pattern point $number is outside a $GridSize x $GridSize grid." -ForegroundColor Red
      return
    }
  }

  Invoke-WakeAndSwipeUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial
  $size = Get-DeviceScreenSize -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial
  $points = @($numbers | ForEach-Object { Get-PatternPoint -Number $_ -GridSize $GridSize -Width $size.Width -Height $size.Height })

  $first = $points[0]
  Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "motionevent", "DOWN", "$($first.X)", "$($first.Y)") -TimeoutSeconds 3 | Out-Null
  Start-Sleep -Milliseconds 120

  for ($i = 1; $i -lt $points.Count; $i++) {
    $point = $points[$i]
    Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "motionevent", "MOVE", "$($point.X)", "$($point.Y)") -TimeoutSeconds 3 | Out-Null
    Start-Sleep -Milliseconds 120
  }

  $last = $points[-1]
  Invoke-AdbWithTimeout -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Arguments @("shell", "input", "motionevent", "UP", "$($last.X)", "$($last.Y)") -TimeoutSeconds 3 | Out-Null
}

function Invoke-UnlockCredential {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [pscustomobject]$Credential
  )

  switch ($Credential.kind) {
    "PIN" { Invoke-TextUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Text $Credential.value }
    "Password" { Invoke-TextUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Text $Credential.value }
    "Pattern" { Invoke-PatternUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -GridSize ([int]$Credential.gridSize) -Pattern $Credential.value }
  }
}

function Show-SavedUnlockMenu {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$DeviceKey
  )

  $credentials = Get-SavedUnlockCredentials -DeviceKey $DeviceKey
  if ($credentials.Count -eq 0) {
    Write-Host "No saved unlock credentials for this device." -ForegroundColor Yellow
    return
  }

  Write-Host ""
  Write-Host "Saved Unlock Credentials" -ForegroundColor Cyan
  for ($i = 0; $i -lt $credentials.Count; $i++) {
    $credential = $credentials[$i]
    Write-Host "$($i + 1). $($credential.label) [$($credential.kind)]"
  }
  Write-Host "0. Back"
  $choice = Read-Host "Select saved unlock"
  if ($choice -eq "0") {
    return
  }

  $index = 0
  if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $credentials.Count) {
    return
  }

  Invoke-UnlockCredential -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Credential $credentials[$index - 1]
}

function Show-ManualUnlockMenu {
  param(
    [string]$AdbExecutable,
    [string]$DeviceSerial,
    [string]$DeviceKey,
    [string]$DeviceName
  )

  while ($true) {
    Write-Host ""
    Write-Host "Unlock Phone" -ForegroundColor Cyan
    Write-Host "1. PIN"
    Write-Host "2. Password"
    Write-Host "3. Pattern 3x3"
    Write-Host "4. Pattern 4x4"
    Write-Host "5. Pattern 5x5"
    Write-Host "0. Back"
    $choice = Read-Host "Select unlock type"

    if ($choice -eq "0") {
      return
    }

    if ($choice -eq "1") {
      $pin = Read-PlainTextSecret -Prompt "Enter PIN"
      Invoke-TextUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Text $pin
      Save-UnlockCredential -DeviceKey $DeviceKey -DeviceName $DeviceName -Kind "PIN" -Value $pin -GridSize 0
      return
    }

    if ($choice -eq "2") {
      $password = Read-PlainTextSecret -Prompt "Enter password"
      Invoke-TextUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -Text $password
      Save-UnlockCredential -DeviceKey $DeviceKey -DeviceName $DeviceName -Kind "Password" -Value $password -GridSize 0
      return
    }

    if ($choice -in @("3", "4", "5")) {
      $gridSize = [int]$choice
      Write-Host "Use numbers 1 to $($gridSize * $gridSize), left-to-right and top-to-bottom." -ForegroundColor Yellow
      $pattern = Read-Host "Enter pattern numbers"
      Invoke-PatternUnlock -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -GridSize $gridSize -Pattern $pattern
      Save-UnlockCredential -DeviceKey $DeviceKey -DeviceName $DeviceName -Kind "Pattern" -Value $pattern -GridSize $gridSize
      return
    }
  }
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
    [string]$DeviceName,
    [string]$DeviceKey,
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
  $process = $null

  try {
    $process = Start-Process -FilePath $ScrcpyExecutable -ArgumentList $scrcpyArgs -PassThru

    while (-not $process.HasExited) {
      Write-Host ""
      Write-Host "Mirror Session - $DeviceName" -ForegroundColor Cyan
      Write-Host "1. Unlock Phone"
      Write-Host "2. Unlock with Saved Credential"
      Write-Host "3. Close Mirror"
      Write-Host "0. Refresh"
      $choice = Read-Host "Select option"

      if ($process.HasExited) {
        break
      }

      if ($choice -eq "1") {
        Show-ManualUnlockMenu -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -DeviceKey $DeviceKey -DeviceName $DeviceName
      }
      elseif ($choice -eq "2") {
        Show-SavedUnlockMenu -AdbExecutable $AdbExecutable -DeviceSerial $DeviceSerial -DeviceKey $DeviceKey
      }
      elseif ($choice -eq "3") {
        Write-Host "Closing mirror..." -ForegroundColor Yellow
        try {
          if (-not $process.CloseMainWindow()) {
            Stop-Process -Id $process.Id -Force
          }
          else {
            Start-Sleep -Seconds 2
            if (-not $process.HasExited) {
              Stop-Process -Id $process.Id -Force
            }
          }
        }
        catch {
          Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        break
      }
    }

    if ($process) {
      $process.WaitForExit()
      $scrcpyExitCode = $process.ExitCode
    }
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

  $wirelessDeviceName = Get-ConnectedDeviceName -AdbExecutable $adbPath -DeviceSerial $wirelessReady
  Start-ScrcpySession -AdbExecutable $adbPath -ScrcpyExecutable $scrcpyPath -DeviceSerial $wirelessReady -DeviceName $wirelessDeviceName -DeviceKey $wirelessDeviceName -ConnectionArguments @() -OnSessionClosed {
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

  $wirelessDeviceName = Get-ConnectedDeviceName -AdbExecutable $adbPath -DeviceSerial $wirelessTarget
  Start-ScrcpySession -AdbExecutable $adbPath -ScrcpyExecutable $scrcpyPath -DeviceSerial $wirelessTarget -DeviceName $wirelessDeviceName -DeviceKey $wirelessDeviceName -ConnectionArguments @() -OnSessionClosed {
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
$usbDeviceName = Get-ConnectedDeviceName -AdbExecutable $adbPath -DeviceSerial $deviceSerial
Start-ScrcpySession -AdbExecutable $adbPath -ScrcpyExecutable $scrcpyPath -DeviceSerial $deviceSerial -DeviceName $usbDeviceName -DeviceKey $usbDeviceName -ConnectionArguments @()
