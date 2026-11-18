#requires -Version 7
# 量「进入会话详情」这一动作的掉帧情况：重置帧统计 → 点列表第一条 → 等 8 秒 → 读 Janky frames。
# 前置：App 已安装并停在会话列表页。

param(
  [string]$Serial = "",
  [int]$WaitSeconds = 8
)

$pkg = 'love.mikumiku.chatluna_mobile'
if (-not $Serial) {
  $Serial = (@(& adb devices | Select-String 'device$') | ForEach-Object { ($_ -split '\s+')[0] })[0]
}
if (-not $Serial) { throw '没有在线设备' }

& adb -s $Serial shell am force-stop $pkg | Out-Null
& adb -s $Serial shell am start -n "$pkg/.MainActivity" | Out-Null
Start-Sleep -Seconds 6

& adb -s $Serial shell dumpsys gfxinfo $pkg reset | Out-Null
$tap = & adb -s $Serial shell wm size
Write-Host "screen: $tap"
# 列表第一条 tile 的位置（1080x2400 基准），换机型时改这里
& adb -s $Serial shell input tap 540 500 | Out-Null
Start-Sleep -Seconds $WaitSeconds

& adb -s $Serial shell dumpsys gfxinfo $pkg |
  Select-String -Pattern 'Total frames rendered|Janky frames|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number Slow UI thread|Number Slow issue draw commands' |
  ForEach-Object { $_.Line.Trim() }
