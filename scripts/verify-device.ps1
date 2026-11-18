#requires -Version 7
# 把 debug APK 装到已连接的设备并拉起 App，顺带截一张图到 tmp/。
# 用法：pwsh -File scripts/verify-device.ps1 [-Serial 192.168.0.102:43045]

param([string]$Serial = "")

$root = Split-Path -Parent $PSScriptRoot
$apk = Join-Path $root 'build/app/outputs/flutter-apk/app-debug.apk'
if (-not (Test-Path $apk)) {
  throw "APK 不存在：$apk（先跑 flutter build apk --debug）"
}

$device = @(& adb devices | Select-String 'device$') | ForEach-Object { ($_ -split '\s+')[0] }
if (-not $device) { throw '没有在线设备，先 adb connect <ip>:<port>' }
if (-not $Serial) { $Serial = $device[0] }

& adb -s $Serial install -r $apk | Out-Host
& adb -s $Serial shell am start -n love.mikumiku.chatluna_mobile/.MainActivity | Out-Host
Start-Sleep -Seconds 3

$shot = Join-Path $root 'tmp/screen.png'
New-Item -ItemType Directory -Force -Path (Split-Path $shot) | Out-Null
& adb -s $Serial exec-out screencap -p > $shot
Write-Host "screenshot: $shot"
