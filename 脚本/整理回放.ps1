<#
  CS2 比赛回放自动整理工具（核心脚本）

  作用：
    把 Steam 个人资料页下载的回放压缩包（.dem.bz2）自动解压、放入 CS2 回放文件夹，
    并与游戏内下载的 .info 配置文件对齐文件名，让这一局比赛可以在游戏内观战。

  原则：
    * 非常驻：只在双击运行时工作，不装服务、不设开机启动、不需要管理员。
    * 不碰游戏：只读写「下载文件夹」和游戏回放文件夹（游戏自己也会写的位置）。
    * .info 永远只读：只把 .dem 改成和它同名，绝不改名 / 移动 / 删除 .info。

  参数（平时不用管，供调试和自动测试使用）：
    -Paths          拖到入口上的文件或文件夹（由 .cmd 自动传入）
    -DownloadPath   覆盖「下载文件夹」
    -ReplaysPath    覆盖「回放文件夹」
    -WaitMinutes    覆盖等待分钟数（0 = 不等待）
    -TestMode       测试模式：不弹窗、不回收压缩包（用于自动测试）
    -DryRun         演示模式：只检查，不写入任何文件
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Paths = @(),
  [string]$DownloadPath = '',
  [string]$ReplaysPath = '',
  [int]$WaitMinutes = -1,
  [switch]$TestMode,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ================= 基础路径 =================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ToolDir)) { $ToolDir = $ScriptDir }
$ConfigPath = Join-Path $ToolDir '设置.txt'
$LogPath = Join-Path $ToolDir '整理日志.txt'
$StatePath = Join-Path $ToolDir '已处理记录.txt'
$TempRoot = Join-Path $ToolDir '临时'

$Summary = New-Object System.Collections.ArrayList
$Pending = New-Object System.Collections.ArrayList

# ================= 通用工具 =================
function Write-Log {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  if (-not $DryRun) {
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  }
}

function Show-Popup {
  param(
    [string]$Text,
    [string]$Title = 'CS2 回放整理',
    [string]$Icon = 'Information'
  )
  if ($TestMode -or $DryRun) {
    Write-Host ''
    Write-Host '【弹窗内容】'
    Write-Host $Text
    Write-Host ''
    return
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $iconEnum = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($Icon -eq 'Warning') { $iconEnum = [System.Windows.Forms.MessageBoxIcon]::Warning }
    if ($Icon -eq 'Error') { $iconEnum = [System.Windows.Forms.MessageBoxIcon]::Error }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $iconEnum)
  } catch {
    Write-Host $Text
  }
}

function Play-DoneSound {
  if ($TestMode -or $DryRun) { return }
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
  try { [Console]::Beep(880, 150); [Console]::Beep(1180, 200) } catch { }
}

function Write-Utf8File {
  param([string]$PathToFile, [string]$Content)
  $enc = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($PathToFile, $Content, $enc)
}

function Test-PathSafe {
  # 某些路径可能因为权限等原因无法访问，这里一律当成“不存在”，不让脚本崩掉
  param([string]$PathToCheck)
  if ([string]::IsNullOrWhiteSpace($PathToCheck)) { return $false }
  try {
    $item = Get-Item -LiteralPath $PathToCheck -Force -ErrorAction SilentlyContinue
    return ($null -ne $item)
  } catch {
    return $false
  }
}

function Get-MatchKey {
  # 从文件名中取出「比赛编号_回放编号」，例如 003846488827438825618_0573902478
  param([string]$Name)
  $m = [regex]::Match($Name, '(?<!\d)(\d{15,25})[_-](\d{6,12})(?!\d)')
  if ($m.Success) { return ($m.Groups[1].Value + '_' + $m.Groups[2].Value) }
  return $null
}

function Test-FileReady {
  # 能独占打开说明下载已完成（浏览器已释放文件）
  param([string]$PathToFile)
  try {
    $fs = [System.IO.File]::Open($PathToFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    $fs.Close()
    return $true
  } catch {
    return $false
  }
}

function Test-Bz2Complete {
  # bz2 流结尾有固定的 48 位结束标记（按位对齐），缺失说明压缩包没下载完整
  param([string]$PathToFile)
  try {
    $fi = Get-Item -LiteralPath $PathToFile
    if ($fi.Length -lt 32) { return $false }
    $take = [int][Math]::Min(16, $fi.Length)
    $fs = [System.IO.File]::Open($PathToFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek(-$take, [System.IO.SeekOrigin]::End) | Out-Null
      $buf = New-Object byte[] $take
      [void]$fs.Read($buf, 0, $take)
    } finally {
      $fs.Close()
    }
    $bits = New-Object System.Collections.ArrayList
    foreach ($byte in $buf) {
      for ($k = 7; $k -ge 0; $k--) { [void]$bits.Add((($byte -shr $k) -band 1)) }
    }
    $pat = @(0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 1,
             0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0)
    for ($i = 0; $i -le ($bits.Count - 48); $i++) {
      $ok = $true
      for ($j = 0; $j -lt 48; $j++) {
        if ($bits[$i + $j] -ne $pat[$j]) { $ok = $false; break }
      }
      if ($ok) { return $true }
    }
    # 没找到结束标记时，若有 7-Zip 就让它做一次完整校验（有些压缩工具写法特殊）
    if ($SevenZip -and (Test-PathSafe $SevenZip)) {
      & $SevenZip t -- $PathToFile | Out-Null
      if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
  } catch {
    return $false
  }
}

# ================= 设置文件 =================
function Get-DefaultConfig {
  $cfg = [ordered]@{
    '等待分钟'   = '3'
    '压缩包处理' = '回收站'
    '下载文件夹' = ''
    '回放文件夹' = ''
    '解压方式'   = '自动'
    '7Zip路径'   = ''
  }
  return $cfg
}

function Read-Config {
  $cfg = Get-DefaultConfig
  if (Test-PathSafe $ConfigPath) {
    foreach ($raw in [System.IO.File]::ReadAllLines($ConfigPath, [System.Text.Encoding]::UTF8)) {
      $line = $raw.Trim()
      if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
      $idx = $line.IndexOf('=')
      if ($idx -lt 1) { continue }
      $key = $line.Substring(0, $idx).Trim()
      $val = $line.Substring($idx + 1).Trim()
      if ($cfg.Contains($key)) { $cfg[$key] = $val }
    }
  }
  return $cfg
}

function Save-Config {
  param($Cfg)
  if ($DryRun) { return }
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add('# CS2 回放整理工具 —— 设置文件')
  [void]$lines.Add('# 修改后保存，下次双击工具生效。以 # 开头的行是说明，可以不管。')
  [void]$lines.Add('')
  [void]$lines.Add('# 等待分钟：录像放好后，脚本等你完成「游戏内点击下载」的时长；0 = 不等待（稍后再双击一次收尾）。')
  [void]$lines.Add('等待分钟=' + $Cfg['等待分钟'])
  [void]$lines.Add('')
  [void]$lines.Add('# 压缩包处理：整理成功后压缩包的归宿。可选：回收站 / 保留')
  [void]$lines.Add('压缩包处理=' + $Cfg['压缩包处理'])
  [void]$lines.Add('')
  [void]$lines.Add('# 下载文件夹：Steam 里下载的回放压缩包存放位置；留空 = 自动探测。')
  [void]$lines.Add('下载文件夹=' + $Cfg['下载文件夹'])
  [void]$lines.Add('')
  [void]$lines.Add('# 回放文件夹：CS2 的 replays 文件夹（结尾是 game\csgo\replays）；留空 = 自动探测。')
  [void]$lines.Add('回放文件夹=' + $Cfg['回放文件夹'])
  [void]$lines.Add('')
  [void]$lines.Add('# 解压方式：自动 = 优先 Windows 自带解压（同右键「全部解压缩」），失败时用 7-Zip；可选：自动 / 系统 / 7-Zip')
  [void]$lines.Add('解压方式=' + $Cfg['解压方式'])
  [void]$lines.Add('')
  [void]$lines.Add('# 7Zip路径：7z.exe 的完整路径；留空 = 自动探测。')
  [void]$lines.Add('7Zip路径=' + $Cfg['7Zip路径'])
  Write-Utf8File $ConfigPath (($lines -join "`r`n") + "`r`n")
}

# ================= 已处理记录 =================
function Read-State {
  $state = @{}
  if (Test-PathSafe $StatePath) {
    foreach ($raw in [System.IO.File]::ReadAllLines($StatePath, [System.Text.Encoding]::UTF8)) {
      $line = $raw.Trim()
      if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
      $parts = $line.Split('|')
      if ($parts.Count -lt 5) { continue }
      $key = $parts[1].ToLower()
      $state[$key] = @{ Path = $parts[1]; Size = $parts[2]; Status = $parts[3]; Key = $parts[4] }
    }
  }
  return $state
}

function Save-State {
  param($State)
  if ($DryRun) { return }
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add('# CS2 回放整理工具 内部记录（可以删除，删除后只是会重新检查一遍文件）')
  [void]$lines.Add('# 类型|路径|大小|状态|比赛钥匙')
  foreach ($k in ($State.Keys | Sort-Object)) {
    $e = $State[$k]
    [void]$lines.Add(('压缩包|{0}|{1}|{2}|{3}' -f $e.Path, $e.Size, $e.Status, $e.Key))
  }
  Write-Utf8File $StatePath (($lines -join "`r`n") + "`r`n")
}

# ================= 路径探测 =================
function Get-DownloadsDir {
  try {
    $sf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    if ($sf) {
      $d = $sf.'{374DE290-123F-4565-9164-39C4925E467B}'
      if ($d) {
        $d = [Environment]::ExpandEnvironmentVariables($d)
        if (Test-PathSafe $d) { return $d }
      }
    }
  } catch { }
  return (Join-Path $env:USERPROFILE 'Downloads')
}

function Get-SteamRoots {
  # 找出 Steam 安装位置：注册表（不同安装方式位置不同）+ 常见默认位置
  $roots = New-Object System.Collections.ArrayList
  foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
    try {
      $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
      if ($p) {
        foreach ($n in @('SteamPath', 'InstallPath')) {
          $v = [string]$p.$n
          if ($v -and -not $roots.Contains($v)) { [void]$roots.Add($v) }
        }
      }
    } catch { }
  }
  $defaults = New-Object System.Collections.ArrayList
  if ($env:ProgramFiles) { [void]$defaults.Add((Join-Path $env:ProgramFiles 'Steam')) }
  if (${env:ProgramFiles(x86)}) { [void]$defaults.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
  [void]$defaults.Add('C:\steam')
  foreach ($d in $defaults) {
    if ($d -and -not $roots.Contains($d)) { [void]$roots.Add($d) }
  }
  return $roots
}

function Get-ReplaysCandidates {
  $list = New-Object System.Collections.ArrayList
  foreach ($steamPath in (Get-SteamRoots)) {
    $steamApps = Join-Path $steamPath 'steamapps'
    [void]$list.Add((Join-Path $steamApps 'common\Counter-Strike Global Offensive\game\csgo\replays'))
    $lf = Join-Path $steamApps 'libraryfolders.vdf'
    if (Test-PathSafe $lf) {
      try {
        $txt = [System.IO.File]::ReadAllText($lf)
        foreach ($m in [regex]::Matches($txt, '"path"\s+"(?<p>[^"]+)"')) {
          $libPath = $m.Groups['p'].Value -replace '\\\\', '\'
          [void]$list.Add((Join-Path $libPath 'steamapps\common\Counter-Strike Global Offensive\game\csgo\replays'))
        }
      } catch { }
    }
  }
  return $list
}

function Find-ReplaysDir {
  foreach ($c in (Get-ReplaysCandidates)) {
    if ($c -and (Test-PathSafe $c)) { return $c }
  }
  return $null
}

function Find-7Zip {
  $cands = New-Object System.Collections.ArrayList
  foreach ($key in @('HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip')) {
    try {
      $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
      if ($p) {
        foreach ($n in @('Path64', 'Path')) {
          if ($p.$n) { [void]$cands.Add((Join-Path ([string]$p.$n) '7z.exe')) }
        }
      }
    } catch { }
  }
  if ($env:ProgramFiles) { [void]$cands.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe')) }
  if (${env:ProgramFiles(x86)}) { [void]$cands.Add((Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')) }
  foreach ($c in $cands) {
    if ($c -and (Test-PathSafe $c)) { return $c }
  }
  return $null
}

# ================= 解压 =================
function Expand-ViaShell {
  # 静默调用 Windows 自带解压引擎（与右键「全部解压缩」相同）
  param([string]$Archive, [string]$Dest)
  $sh = New-Object -ComObject Shell.Application
  $srcNs = $sh.Namespace($Archive)
  if ($null -eq $srcNs) { throw '系统解压引擎没有识别这个压缩包' }
  $destNs = $sh.Namespace($Dest)
  if ($null -eq $destNs) { throw '打不开临时解压文件夹' }
  $items = @($srcNs.Items())
  if ($items.Count -eq 0) { throw '压缩包里没有找到文件' }
  foreach ($it in $items) { $destNs.CopyHere($it, 532) }
  # 等待解压结束：出现大于 1MB 的文件，且大小连续稳定
  $deadline = (Get-Date).AddSeconds(600)
  $lastSize = -1
  $stable = 0
  while ((Get-Date) -lt $deadline) {
    $f = Get-ChildItem -LiteralPath $Dest -File -Recurse -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
    if ($f) {
      if ($f.Length -eq $lastSize) { $stable++ } else { $stable = 0; $lastSize = $f.Length }
      if ($stable -ge 3 -and $lastSize -gt 1048576) { return }
    }
    Start-Sleep -Milliseconds 700
  }
  throw '等待系统解压超时'
}

function Expand-Via7Zip {
  param([string]$Archive, [string]$Dest, [string]$SevenZipPath)
  & $SevenZipPath x -y ("-o" + $Dest) -- $Archive | Out-Null
  if ($LASTEXITCODE -ne 0) { throw ('7-Zip 解压失败（代码 ' + $LASTEXITCODE + '）') }
}

function Expand-RecordingArchive {
  # 解压压缩包到临时目录，返回 @{ Dest = 临时目录; Dems = .dem 文件列表 }
  param([string]$Archive, [string]$Mode, [string]$SevenZipPath)
  $dest = Join-Path $TempRoot ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [System.IO.Path]::GetRandomFileName().Substring(0, 6))
  if (-not (Test-PathSafe $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
  $ext = [System.IO.Path]::GetExtension($Archive).ToLower()
  if ($ext -eq '.zip') {
    Expand-Archive -LiteralPath $Archive -DestinationPath $dest -Force
  } else {
    $done = $false
    if ($Mode -ne '7-Zip') {
      try {
        Expand-ViaShell -Archive $Archive -Dest $dest
        $done = $true
      } catch {
        Write-Log ('Windows 自带解压没能完成：' + $_.Exception.Message)
      }
    }
    if (-not $done) {
      if ($Mode -eq '系统') { throw '设置里限定只用系统解压，但系统解压失败了。' }
      if (-not $SevenZipPath) {
        throw '需要备用解压程序，但没有找到 7z.exe。请右键压缩包选择「全部解压缩」，再把解压出的 .dem 拖到本工具上。'
      }
      Expand-Via7Zip -Archive $Archive -Dest $dest -SevenZipPath $SevenZipPath
    }
  }
  $dems = @(Get-ChildItem -LiteralPath $dest -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.dem$' })
  if ($dems.Count -eq 0) { throw '解压完成，但没有找到 .dem 录像文件（压缩包可能没下载完整）。' }
  return @{ Dest = $dest; Dems = $dems }
}

function Remove-TempDir {
  param([string]$Dir)
  if ($DryRun) { return }
  if (-not $Dir) { return }
  try {
    $resolved = (Resolve-Path -LiteralPath $Dir -ErrorAction SilentlyContinue)
    if ($resolved -and $resolved.Path.StartsWith($TempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolved.Path -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Recycle-File {
  param([string]$PathToFile)
  Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($PathToFile, 'OnlyErrorDialogs', 'SendToRecycleBin')
}

# ================= 配对与放置 =================
function Get-InfoMap {
  param([string]$ReplaysDir)
  $map = @{}
  Get-ChildItem -LiteralPath $ReplaysDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.dem\.info$' } | ForEach-Object {
    $key = Get-MatchKey $_.Name
    if ($key) {
      if (-not $map.ContainsKey($key)) { $map[$key] = @() }
      $map[$key] += $_
    }
  }
  return $map
}

function Get-StagedDems {
  param([string]$ReplaysDir)
  $list = New-Object System.Collections.ArrayList
  Get-ChildItem -LiteralPath $ReplaysDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.dem$' } | ForEach-Object {
    $baseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    if ($baseNoExt -match '\.new') { return }  # 已是保留副本，不再处理
    $key = Get-MatchKey $_.Name
    if ($key) { [void]$list.Add(@{ Key = $key; Path = $_.FullName; Name = $_.Name }) }
  }
  return $list
}

function Place-DemToReplays {
  param([string]$SourcePath, [string]$Key, [string]$CanonicalName, [string]$ReplaysDir)
  $srcSize = (Get-Item -LiteralPath $SourcePath).Length
  if ([string]::IsNullOrWhiteSpace($CanonicalName)) { $CanonicalName = 'match730_' + $Key + '.dem' }
  $target = Join-Path $ReplaysDir $CanonicalName
  if (Test-PathSafe $target) {
    $tSize = (Get-Item -LiteralPath $target).Length
    if ($tSize -eq $srcSize) { return @{ Path = $target; Kind = 'exists'; Note = '' } }
    $baseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($CanonicalName)
    $alt = Join-Path $ReplaysDir ($baseNoExt + '.new.dem')
    if (Test-PathSafe $alt) { $alt = Join-Path $ReplaysDir ($baseNoExt + '.new-' + (Get-Date -Format 'HHmmss') + '.dem') }
    Copy-Item -LiteralPath $SourcePath -Destination $alt
    return @{ Path = $alt; Kind = 'collision'; Note = ('回放文件夹里已有一个同名但大小不同的文件，新的这份保留为 ' + [System.IO.Path]::GetFileName($alt)) }
  }
  Copy-Item -LiteralPath $SourcePath -Destination $target
  if ((Get-Item -LiteralPath $target).Length -ne $srcSize) { throw ('复制到回放文件夹后大小对不上：' + $target) }
  return @{ Path = $target; Kind = 'placed'; Note = '' }
}

function Resolve-PairForKey {
  # 把某局等待中的 .dem 改成与 .info 同名
  param([string]$Key, [string]$BaseName, [string]$ReplaysDir)
  $target = Join-Path $ReplaysDir $BaseName
  $baseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($BaseName)
  $srcPath = $null
  foreach ($p in $Pending) {
    if ($p.Key -eq $Key -and $p.Path -and (Test-PathSafe $p.Path)) { $srcPath = $p.Path; break }
  }
  if (-not $srcPath) {
    $cands = @(Get-ChildItem -LiteralPath $ReplaysDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '\.dem$' -and $_.Name -ne $BaseName -and $_.Name -notmatch ('^' + [regex]::Escape($baseNoExt) + '\.new')
      })
    foreach ($c in $cands) {
      if ((Get-MatchKey $c.Name) -eq $Key) { $srcPath = $c.FullName; break }
    }
  }
  if (-not $srcPath) {
    if (Test-PathSafe $target) { return @{ Ok = $true; Action = '已经对齐，无需处理'; Path = $target } }
    return @{ Ok = $false; Action = '没有找到这一局等待配对的 .dem 文件'; Path = $null }
  }
  if (Test-PathSafe $target) {
    $s1 = (Get-Item -LiteralPath $srcPath).Length
    $s2 = (Get-Item -LiteralPath $target).Length
    if ($s1 -eq $s2) {
      Remove-Item -LiteralPath $srcPath -Force
      return @{ Ok = $true; Action = '已经对齐（顺手清理了一份重复文件）'; Path = $target }
    }
    $alt = Join-Path $ReplaysDir ($baseNoExt + '.new.dem')
    if (Test-PathSafe $alt) { $alt = Join-Path $ReplaysDir ($baseNoExt + '.new-' + (Get-Date -Format 'HHmmss') + '.dem') }
    Move-Item -LiteralPath $srcPath -Destination $alt
    return @{ Ok = $false; Action = ('回放文件夹里已有同名但不同的文件，新的一份保留为 ' + [System.IO.Path]::GetFileName($alt)); Path = $alt }
  }
  Move-Item -LiteralPath $srcPath -Destination $target
  return @{ Ok = $true; Action = '已把 .dem 改成和 .info 同名'; Path = $target }
}

function Add-Summary {
  param([string]$Key, [string]$State, [string]$Text)
  $matchId = $Key
  if ($Key -and $Key.Contains('_')) { $matchId = $Key.Split('_')[0] }
  [void]$Summary.Add(@{ Key = $Key; State = $State; Text = $Text; MatchId = $matchId })
}

function Complete-MatchArchives {
  # 某局已经可观看后：按设置回收它对应的压缩包，并更新记录
  param([string]$Key, $State)
  $recycled = 0
  $kept = 0
  foreach ($k in @($State.Keys)) {
    $e = $State[$k]
    if ($e.Key -ne $Key -or $e.Status -ne '等待info') { continue }
    if (Test-PathSafe $e.Path) {
      if ($RecyclePolicy -eq '回收站' -and -not $TestMode -and -not $DryRun) {
        try {
          Recycle-File -PathToFile $e.Path
          $recycled++
          Write-Log ('压缩包已移入回收站：' + $e.Path)
        } catch {
          $kept++
          Write-Log ('回收压缩包失败（已保留）：' + $e.Path + ' —— ' + $_.Exception.Message)
        }
      } else {
        $kept++
        Write-Log ('压缩包按设置保留：' + $e.Path)
      }
    }
    $e.Status = '完成'
  }
  return @{ Recycled = $recycled; Kept = $kept }
}

function Invoke-Sweep {
  # 开局先对齐一下历史遗留文件：有 .info 却没有对应 .dem 的，把等待中的 .dem 改名
  param([string]$ReplaysDir, $State)
  $infos = Get-InfoMap -ReplaysDir $ReplaysDir
  if ($infos.Count -eq 0) { return }
  $dems = @(Get-ChildItem -LiteralPath $ReplaysDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.dem$' })
  foreach ($d in $dems) {
    $baseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($d.Name)
    if ($baseNoExt -match '\.new') { continue }
    $key = Get-MatchKey $d.Name
    if (-not $key) { continue }
    if (-not $infos.ContainsKey($key)) { continue }
    $infoFile = $infos[$key][0]
    $wantBase = $infoFile.Name.Substring(0, $infoFile.Name.Length - 5)
    if ($d.Name -eq $wantBase) { continue }
    $res = Resolve-PairForKey -Key $key -BaseName $wantBase -ReplaysDir $ReplaysDir
    if ($res.Ok) {
      $extra = Complete-MatchArchives -Key $key -State $State
      $note = '已自动对齐文件名'
      if ($extra.Recycled -gt 0) { $note += '，压缩包已移入回收站' }
      Write-Log ('[' + $key + '] ' + $res.Action + ' → ' + [System.IO.Path]::GetFileName([string]$res.Path))
      Add-Summary -Key $key -State 'ready' -Text $note
    } else {
      Write-Log ('[' + $key + '] ' + $res.Action)
      Add-Summary -Key $key -State 'warn' -Text $res.Action
    }
  }
}

function Get-CandidateFiles {
  param([string]$DownloadsDir, [string]$ToolDirPath)
  $result = New-Object System.Collections.ArrayList
  $dirs = New-Object System.Collections.ArrayList
  if ($DownloadsDir) { [void]$dirs.Add($DownloadsDir) }
  if ($ToolDirPath) {
    [void]$dirs.Add($ToolDirPath)
    $parent = Split-Path -Parent $ToolDirPath
    if ($parent) { [void]$dirs.Add($parent) }
  }
  foreach ($d in $dirs) {
    if (-not (Test-PathSafe $d)) { continue }
    Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)\.(bz2|zip|dem)$' } | ForEach-Object { [void]$result.Add($_.FullName) }
  }
  if ($DownloadsDir -and (Test-PathSafe $DownloadsDir)) {
    Get-ChildItem -LiteralPath $DownloadsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)\.dem$' } | ForEach-Object { [void]$result.Add($_.FullName) }
    }
  }
  $seen = @{}
  $unique = New-Object System.Collections.ArrayList
  foreach ($f in $result) {
    $k = $f.ToLower()
    if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$unique.Add($f) }
  }
  $objs = foreach ($f in $unique) { Get-Item -LiteralPath $f -ErrorAction SilentlyContinue }
  return @($objs | Where-Object { $_ } | Sort-Object LastWriteTime -Descending)
}

function Invoke-WaitForInfos {
  param([string]$ReplaysDir, [int]$Minutes, $State)
  $end = (Get-Date).AddMinutes($Minutes)
  Write-Host ''
  Write-Host '==================== 现在请回到游戏 ===================='
  Write-Host '  观战(Watch) → 你的比赛 → 找到这一局 → 点「下载」'
  Write-Host ('  脚本会在这里等你最多 {0} 分钟，检测到配置文件后自动改好名字。' -f $Minutes)
  Write-Host '======================================================='
  $keyboard = $true
  while ((Get-Date) -lt $end) {
    $infos = Get-InfoMap -ReplaysDir $ReplaysDir
    foreach ($p in @($Pending)) {
      if ($p.Done) { continue }
      if ($infos.ContainsKey($p.Key)) {
        $infoFile = $infos[$p.Key][0]
        $wantBase = $infoFile.Name.Substring(0, $infoFile.Name.Length - 5)
        $res = Resolve-PairForKey -Key $p.Key -BaseName $wantBase -ReplaysDir $ReplaysDir
        $p.Done = $true
        if ($res.Ok) {
          $extra = Complete-MatchArchives -Key $p.Key -State $State
          $note = '已完成，可以看了'
          if ($extra.Recycled -gt 0) { $note += '（压缩包已移入回收站）' }
          Write-Log ('[' + $p.Key + '] ' + $res.Action + ' → ' + [System.IO.Path]::GetFileName([string]$res.Path))
          Add-Summary -Key $p.Key -State 'ready' -Text $note
        } else {
          Write-Log ('[' + $p.Key + '] ' + $res.Action)
          Add-Summary -Key $p.Key -State 'warn' -Text $res.Action
        }
      }
    }
    $remain = [int]((($end - (Get-Date)).TotalSeconds))
    if ($remain -lt 0) { $remain = 0 }
    $line = ('等待中… 还剩 {0} 秒（在窗口里按任意键可跳过等待）' -f $remain)
    try { [Console]::Write("`r" + $line.PadRight(58)) } catch { }
    $allDone = $true
    foreach ($p in @($Pending)) { if (-not $p.Done) { $allDone = $false } }
    if ($allDone) { try { [Console]::WriteLine('') } catch { }; break }
    if ($keyboard) {
      try {
        if ([Console]::KeyAvailable) {
          $null = [Console]::ReadKey($true)
          $keyboard = $false
          try { [Console]::WriteLine('') } catch { }
          Write-Log '已跳过等待（稍后可再次双击工具收尾）'
          break
        }
      } catch { $keyboard = $false }
    }
    Start-Sleep -Milliseconds 3000
  }
  try { [Console]::WriteLine('') } catch { }
}

# ================= 主流程 =================
Write-Log '=========================================='
Write-Log 'CS2 回放整理 工具启动'
if ($DryRun) { Write-Log '（演示模式：只检查，不会写入任何文件）' }

$cfg = Read-Config

if ($DownloadPath) { $Downloads = $DownloadPath } elseif ($cfg['下载文件夹'] -and (Test-PathSafe $cfg['下载文件夹'])) { $Downloads = $cfg['下载文件夹'] } else { $Downloads = Get-DownloadsDir }
if (-not (Test-PathSafe $Downloads)) { $Downloads = Get-DownloadsDir }
$cfg['下载文件夹'] = $Downloads

if ($ReplaysPath) { $Replays = $ReplaysPath } elseif ($cfg['回放文件夹'] -and (Test-PathSafe $cfg['回放文件夹'])) { $Replays = $cfg['回放文件夹'] } else { $Replays = Find-ReplaysDir }
if (-not $Replays -or -not (Test-PathSafe $Replays)) {
  Write-Log '找不到 CS2 回放文件夹'
  Show-Popup ("没有找到 CS2 的回放文件夹。`n`n请确认游戏安装位置，或在「设置.txt」里把「回放文件夹」填成类似：`n<你的Steam库文件夹>\steamapps\common\Counter-Strike Global Offensive\game\csgo\replays") 'CS2 回放整理' 'Warning'
  exit 2
}
$cfg['回放文件夹'] = $Replays

$SevenZip = ''
if ($cfg['7Zip路径'] -and (Test-PathSafe $cfg['7Zip路径'])) {
  $SevenZip = $cfg['7Zip路径']
} else {
  $SevenZip = Find-7Zip
  if ($SevenZip) { $cfg['7Zip路径'] = $SevenZip }
}

$Wait = 3
if ($cfg['等待分钟']) { try { $Wait = [int]$cfg['等待分钟'] } catch { $Wait = 3 } }
if ($WaitMinutes -ge 0) { $Wait = $WaitMinutes }
$RecyclePolicy = [string]$cfg['压缩包处理']
$ExtractMode = [string]$cfg['解压方式']
if (-not $ExtractMode) { $ExtractMode = '自动' }

Save-Config $cfg

$State = @{}
if (-not $DryRun) { $State = Read-State }

Write-Log ('下载文件夹：' + $Downloads)
Write-Log ('回放文件夹：' + $Replays)
if ($SevenZip) { Write-Log ('备用解压程序：' + $SevenZip) } else { Write-Log '备用解压程序：未找到 7-Zip（只有系统解压失败时才会用到）' }

if ($DryRun) {
  Write-Log '（演示模式：跳过自动对齐和写盘操作）'
} else {
  Invoke-Sweep -ReplaysDir $Replays -State $State
}

$candidatePaths = New-Object System.Collections.ArrayList
if ($Paths -and @($Paths).Count -gt 0) {
  Write-Log ('来自拖拽的文件：' + (@($Paths) -join '；'))
  foreach ($p in @($Paths)) {
    if (-not (Test-PathSafe $p)) { continue }
    $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    if ($item.PSIsContainer) {
      Get-ChildItem -LiteralPath $item.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)\.(bz2|zip|dem)$' } | ForEach-Object { [void]$candidatePaths.Add($_.FullName) }
    } else {
      [void]$candidatePaths.Add($item.FullName)
    }
  }
} else {
  foreach ($f in (Get-CandidateFiles -DownloadsDir $Downloads -ToolDirPath $ToolDir)) { [void]$candidatePaths.Add($f.FullName) }
}

$candidates = @()
if ($candidatePaths.Count -gt 0) {
  $candidates = @(Get-Item -LiteralPath $candidatePaths -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}
Write-Log ('本次待检查的文件：' + $candidates.Count + ' 个')

foreach ($cand in $candidates) {
  $candPath = $cand.FullName
  try {
    $name = $cand.Name
    $key = Get-MatchKey $name

    # 已处理过、且录像还在（等 info）或已完成 → 跳过重复整理
    if (-not $DryRun -and $State.ContainsKey($candPath.ToLower())) {
      $e = $State[$candPath.ToLower()]
      if ($e.Size -eq [string]$cand.Length) {
        if ($e.Status -eq '完成') { continue }
        if ($e.Status -eq '等待info') {
          $stillThere = $false
          foreach ($d in (Get-StagedDems -ReplaysDir $Replays)) { if ($d.Key -eq $e.Key) { $stillThere = $true } }
          if ($stillThere -or (Get-InfoMap -ReplaysDir $Replays).ContainsKey($e.Key)) { continue }
        }
      }
    }

    if (-not $key) {
      Write-Log ('跳过（文件名里找不到比赛编号）：' + $name)
      continue
    }
    if (-not (Test-FileReady -PathToFile $candPath)) {
      Write-Log ('跳过（可能还在下载中）：' + $name)
      continue
    }

    $ext = $cand.Extension.ToLower()
    if ($ext -eq '.bz2' -and -not (Test-Bz2Complete -PathToFile $candPath)) {
      Write-Log ('跳过（压缩包结尾不完整，可能还没下载完）：' + $name)
      Add-Summary -Key $key -State 'warn' -Text ('压缩包可能还没下载完：' + $name + '（等下载完成后再双击一次即可）')
      continue
    }

    if ($DryRun) {
      Write-Log ('演示：发现可处理的文件 ' + $name + '（' + [Math]::Round($cand.Length / 1MB) + ' MB），正式运行时会自动整理')
      Add-Summary -Key $key -State 'demo' -Text ('演示模式：正式运行时会自动整理这份录像（' + $name + '）')
      continue
    }

    $infoMap = Get-InfoMap -ReplaysDir $Replays
    $canonical = ''
    if ($infoMap.ContainsKey($key)) {
      $infoFile = $infoMap[$key][0]
      $canonical = $infoFile.Name.Substring(0, $infoFile.Name.Length - 5)
    }

    $dems = @()
    $tempDir = ''
    $candIsInReplays = ([System.IO.Path]::GetDirectoryName($candPath).TrimEnd('\') -eq $Replays.TrimEnd('\'))
    if ($ext -eq '.dem') {
      $dems = @($cand)
      Write-Log ('发现已解压的录像：' + $name + '（' + [Math]::Round($cand.Length / 1MB) + ' MB）')
    } else {
      Write-Log ('正在解压：' + $name + '（' + [Math]::Round($cand.Length / 1MB) + ' MB）')
      $exp = Expand-RecordingArchive -Archive $candPath -Mode $ExtractMode -SevenZipPath $SevenZip
      $tempDir = $exp.Dest
      $dems = @($exp.Dems)
      $picked = @($dems | Where-Object { (Get-MatchKey $_.Name) -eq $key })
      if ($picked.Count -eq 0 -and $dems.Count -eq 1) { $picked = @($dems) }
      $dems = @($picked)
      if ($dems.Count -eq 0) { throw '解压出来的 .dem 和压缩包对不上（比赛编号不一致）' }
    }

    foreach ($dem in $dems) {
      $demKey = Get-MatchKey $dem.Name
      if (-not $demKey) { $demKey = $key }
      if ((Get-Item -LiteralPath $dem.FullName).Length -lt 1048576) { throw ('解压出来的录像太小，可能没下载完整：' + $dem.Name) }

      $infoMapNow = Get-InfoMap -ReplaysDir $Replays
      $canonicalNow = ''
      if ($infoMapNow.ContainsKey($demKey)) {
        $infoFile = $infoMapNow[$demKey][0]
        $canonicalNow = $infoFile.Name.Substring(0, $infoFile.Name.Length - 5)
      }

      if ($candIsInReplays -and $ext -eq '.dem') {
        $placed = @{ Path = $dem.FullName; Kind = 'exists'; Note = '' }
      } else {
        $placed = Place-DemToReplays -SourcePath $dem.FullName -Key $demKey -CanonicalName $canonicalNow -ReplaysDir $Replays
      }
      if ($placed.Kind -eq 'collision') {
        Write-Log ('[' + $demKey + '] ' + $placed.Note)
        Add-Summary -Key $demKey -State 'warn' -Text $placed.Note
        continue
      }

      if ($placed.Kind -eq 'exists') {
        Write-Log ('[' + $demKey + '] 回放文件夹里已经有这份录像（大小一致），直接用。')
      } else {
        Write-Log ('[' + $demKey + '] 已放入回放文件夹：' + [System.IO.Path]::GetFileName([string]$placed.Path))
      }

      if ($canonicalNow) {
        $res = Resolve-PairForKey -Key $demKey -BaseName $canonicalNow -ReplaysDir $Replays
        if ($res.Ok) {
          $State[$candPath.ToLower()] = @{ Path = $candPath; Size = [string]$cand.Length; Status = '等待info'; Key = $demKey }
          $extra = Complete-MatchArchives -Key $demKey -State $State
          $note = '已完成，可以看了'
          if ($extra.Recycled -gt 0) { $note += '（压缩包已移入回收站）' }
          Write-Log ('[' + $demKey + '] ' + $res.Action)
          Add-Summary -Key $demKey -State 'ready' -Text $note
        } else {
          Write-Log ('[' + $demKey + '] ' + $res.Action)
          Add-Summary -Key $demKey -State 'warn' -Text $res.Action
        }
      } else {
        $State[$candPath.ToLower()] = @{ Path = $candPath; Size = [string]$cand.Length; Status = '等待info'; Key = $demKey }
        $already = $false
        foreach ($p in @($Pending)) { if ($p.Key -eq $demKey) { $already = $true; $p.Path = $placed.Path } }
        if (-not $already) { [void]$Pending.Add(@{ Key = $demKey; Path = $placed.Path; Done = $false }) }
        Write-Log ('[' + $demKey + '] 录像已放好，等你在游戏内点这一局的「下载」')
      }
    }

    if ($ext -eq '.dem' -and -not $candIsInReplays) {
      # 用户右键解压出来的 .dem：成功放进回放文件夹后，把原位置的这份移走（与手动流程一致）
      try {
        Remove-Item -LiteralPath $candPath -Force
        Write-Log ('已把原位置的录像移走：' + $candPath)
      } catch {
        Write-Log ('原位置的录像没能删除（不影响安装结果）：' + $candPath)
      }
    }

    if ($tempDir) { Remove-TempDir -Dir $tempDir }
  } catch {
    Write-Log ('处理失败：' + $candPath + ' —— ' + $_.Exception.Message)
    $k2 = Get-MatchKey $cand.Name
    if (-not $k2) { $k2 = '(未知)' }
    Add-Summary -Key $k2 -State 'warn' -Text ('这个文件没能自动处理：' + $cand.Name + '（' + $_.Exception.Message + '）')
  }
}

# 有等待中的录像 → 弹窗提醒并开始等待
$pendingCount = 0
foreach ($p in @($Pending)) { if (-not $p.Done) { $pendingCount++ } }
if ($pendingCount -gt 0 -and -not $DryRun) {
  if ($Wait -gt 0) {
    $text = @(
      '录像已经放好了！'
      ''
      '现在请回到游戏里完成最后一步：'
      '观战(Watch) → 你的比赛 → 找到这一局 → 点「下载」'
      ''
      ('我会在窗口里等你 {0} 分钟。等你点完，脚本会自动把文件名对齐，然后弹窗告诉你「可以看了」。' -f $Wait)
      ''
      '（如果这次不想等：在黑色窗口里按任意键跳过，稍后再双击一次本工具即可收尾。）'
    ) -join "`n"
    Show-Popup $text 'CS2 回放整理'
    Invoke-WaitForInfos -ReplaysDir $Replays -Minutes $Wait -State $State
  }
}
foreach ($p in @($Pending)) {
  if (-not $p.Done) {
    Write-Log ('[' + $p.Key + '] 还没等到游戏内下载的 .info，稍后双击一次工具即可继续。')
    Add-Summary -Key $p.Key -State 'wait' -Text '录像已放好；请到游戏内点这一局的「下载」，然后双击一次本工具收尾'
  }
}

if (-not $DryRun) { Save-State $State }

# ================= 结果弹窗 =================
$ready = @($Summary | Where-Object { $_.State -eq 'ready' })
$waitItems = @($Summary | Where-Object { $_.State -eq 'wait' })
$warnItems = @($Summary | Where-Object { $_.State -eq 'warn' })
$demoItems = @($Summary | Where-Object { $_.State -eq 'demo' })

if ($Summary.Count -eq 0) {
  $text = @(
    '这次没有发现新的回放压缩包。'
    ''
    '请确认：'
    '1) 已经在 Steam 里点了这一局的「下载录像」'
    ('2) 压缩包在「下载」文件夹里：' + $Downloads)
    ''
    '也可以把压缩包（或解压出来的 .dem）直接拖到本工具上再试。'
  ) -join "`n"
  Show-Popup $text 'CS2 回放整理'
} else {
  $lines = New-Object System.Collections.ArrayList
  if ($ready.Count -gt 0) {
    [void]$lines.Add('✅ 可以看了（回到游戏刷新一下）：')
    foreach ($it in $ready) { [void]$lines.Add('   · 比赛 ' + $it.MatchId + ' —— ' + $it.Text) }
  }
  if ($waitItems.Count -gt 0) {
    if ($lines.Count -gt 0) { [void]$lines.Add('') }
    [void]$lines.Add('⏳ 还差一步：')
    foreach ($it in $waitItems) { [void]$lines.Add('   · 比赛 ' + $it.MatchId + ' —— ' + $it.Text) }
  }
  if ($warnItems.Count -gt 0) {
    if ($lines.Count -gt 0) { [void]$lines.Add('') }
    [void]$lines.Add('⚠️ 需要留意：')
    foreach ($it in $warnItems) { [void]$lines.Add('   · ' + $it.Text) }
  }
  if ($demoItems.Count -gt 0) {
    if ($lines.Count -gt 0) { [void]$lines.Add('') }
    [void]$lines.Add('🔎 演示模式发现（本次没有写入任何文件）：')
    foreach ($it in $demoItems) { [void]$lines.Add('   · ' + $it.Text) }
  }
  [void]$lines.Add('')
  [void]$lines.Add('（详细过程记录在「整理日志.txt」里。）')
  Show-Popup (($lines -join "`n")) 'CS2 回放整理 —— 结果'
}

if ($ready.Count -gt 0) { Play-DoneSound }
Write-Log '本次运行结束'
exit 0
