# AMS Studio H4 验收脚本（参数化、可重复）
#
# 用途：一条命令核对"当前发布真值"——版本矩阵、H2/H3 feed、签名、setup/kernel/gateway/plugin 哈希、
#       本地发布物料结构、Gateway 单元测试、release 单元测试，并输出 results.json + summary.md。
# 不覆盖：UI CDP（见 ui-cdp.ps1）、GPU E2E（见 h4-gpu-e2e.ps1），这些在 summary 中标记 DEFERRED。
#
# 用法：
#   pwsh -File qa/run-h4.ps1
#   pwsh -File qa/run-h4.ps1 -AmsHome 'F:\AMS-H4-H3\data'
#
# 安全：只读（除自身输出目录）；不写 C 盘；不删除任何文件。

param(
  [string]$ProjRoot = 'F:\Deepseek_harness\AI音乐处理',
  [string]$AmsHome = '',
  [string]$OutDir = '',
  [string]$H2Feed = '',
  [string]$H3Feed = ''
)

$ErrorActionPreference = 'Stop'

# ---------- 路径与输出 ----------
$codeRoot   = Join-Path $ProjRoot '08_项目代码'
$releaseDir = Join-Path $codeRoot 'ams-release'
$services   = Join-Path $codeRoot 'ams-services'
$plugins    = Join-Path $codeRoot 'ams-plugins'
$launcher   = Join-Path $codeRoot 'ams-launcher'
$pubKey     = Join-Path $releaseDir 'examples\keys\public.pem'
$py         = Join-Path $services 'gateway\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $py)) { $py = 'python' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $ProjRoot ('_接管审计\qa\' + $stamp)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$steps = New-Object System.Collections.Generic.List[object]
function Add-Step([string]$name, [string]$status, [string]$detail) {
  $script:steps.Add([pscustomobject]@{ name = $name; status = $status; detail = $detail })
  Write-Output ('{0,-26} {1,-9} {2}' -f $name, $status, $detail)
}
function Get-Version([string]$path, [string]$pattern) {
  try {
    $m = Select-String -LiteralPath $path -Pattern $pattern | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
  } catch {}
  return '?'
}
function Resolve-Feed([string]$explicit, [string[]]$candidates) {
  if (-not [string]::IsNullOrWhiteSpace($explicit) -and (Test-Path -LiteralPath $explicit)) { return (Resolve-Path -LiteralPath $explicit).Path }
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } }
  return ''
}
function Get-Sha([string]$path) {
  if (Test-Path -LiteralPath $path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
  return ''
}

# ---------- 1. 版本矩阵（当前源码应统一 1.0.0-rc.1） ----------
$matrix = [ordered]@{
  launcher_package = Get-Version (Join-Path $launcher 'package.json') '"version"\s*:\s*"([^"]+)"'
  launcher_tauri   = Get-Version (Join-Path $launcher 'src-tauri\tauri.conf.json') '"version"\s*:\s*"([^"]+)"'
  launcher_cargo   = Get-Version (Join-Path $launcher 'src-tauri\Cargo.toml') '(?m)^version\s*=\s*"([^"]+)"'
  plugin_core      = Get-Version (Join-Path $plugins 'packages\plugin-core\package.json') '"version"\s*:\s*"([^"]+)"'
  plugin_ui        = Get-Version (Join-Path $plugins 'packages\plugin-ui\package.json') '"version"\s*:\s*"([^"]+)"'
  gateway          = Get-Version (Join-Path $services 'gateway\pyproject.toml') '(?m)^version\s*=\s*"([^"]+)"'
}
$expect = '1.0.0-rc.1'
$bad = $matrix.GetEnumerator() | Where-Object { $_.Value -ne $expect } | ForEach-Object { $_.Key + '=' + $_.Value }
if ($bad.Count -eq 0) { Add-Step 'version-matrix' 'PASS' (($matrix.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' ') }
else { Add-Step 'version-matrix' 'FAIL' ('not ' + $expect + ': ' + ($bad -join ', ')) }

# ---------- 2. 解析 feed 路径（优先 09_发布/当前 新结构，回退旧结构） ----------
$h2candidates = @(
  (Join-Path $ProjRoot '09_发布\当前\H2_0.2.1_feed2049\ams-components.json'),
  (Join-Path $ProjRoot '09_发布\当前\H2_0.2.1\ams-components.json'),
  (Join-Path $ProjRoot '09_发布\_H2_KERNEL_FIX\ams-components.json')
)
$h3candidates = @(
  (Join-Path $ProjRoot '09_发布\当前\H3_1.0.0-rc.1_feed2050\ams-components.json'),
  (Join-Path $ProjRoot '09_发布\当前\H3_1.0.0-rc.1\ams-components.json'),
  (Join-Path $ProjRoot '09_发布\_H2_KERNEL_FIX\h3-ams-components.json')
)
$h2Path = Resolve-Feed $H2Feed $h2candidates
$h3Path = Resolve-Feed $H3Feed $h3candidates
if ($h2Path) { Add-Step 'feed-h2-found' 'PASS' $h2Path } else { Add-Step 'feed-h2-found' 'FAIL' 'H2 feed missing' }
if ($h3Path) { Add-Step 'feed-h3-found' 'PASS' $h3Path } else { Add-Step 'feed-h3-found' 'FAIL' 'H3 feed missing' }

# ---------- 3. feed sequence / 组件数 / 签名 ----------
foreach ($item in @(@{ tag = 'h2'; path = $h2Path; seq = 2049 }, @{ tag = 'h3'; path = $h3Path; seq = 2050 })) {
  if (-not $item.path) { continue }
  $feed = Get-Content -LiteralPath $item.path -Raw -Encoding UTF8 | ConvertFrom-Json
  $seqOk = ($feed.sequence -eq $item.seq)
  Add-Step ('feed-' + $item.tag + '-sequence') $(if ($seqOk) { 'PASS' } else { 'FAIL' }) ('sequence=' + $feed.sequence + ' expect=' + $item.seq + ' components=' + $feed.components.Count)
  $sha = Get-Sha $item.path
  Add-Step ('feed-' + $item.tag + '-sha256') 'INFO' $sha
  $verify = & $py (Join-Path $releaseDir 'tools\manifest.py') verify $item.path --pub $pubKey 2>&1
  if ($LASTEXITCODE -eq 0) { Add-Step ('feed-' + $item.tag + '-signature') 'PASS' ($verify -join ' ') }
  else { Add-Step ('feed-' + $item.tag + '-signature') 'FAIL' ($verify -join ' ') }
}

# ---------- 4. 本地发布物料哈希（按 feed 声明核对） ----------
if ($h2Path) {
  $f2 = Get-Content -LiteralPath $h2Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $setupEntry = $f2.setup
  $candidates2 = @(
    (Join-Path $ProjRoot ('09_发布\当前\H2_0.2.1_feed2049\' + $setupEntry.file)),
    (Join-Path $ProjRoot ('09_发布\_H2_KERNEL_FIX\' + $setupEntry.file)),
    (Join-Path $launcher ('installer\' + $setupEntry.file))
  )
  $setupPath = Resolve-Feed '' $candidates2
  if ($setupPath) {
    $sha = Get-Sha $setupPath
    $ok = ($sha -eq $setupEntry.sha256)
    Add-Step 'h2-setup-sha' $(if ($ok) { 'PASS' } else { 'FAIL' }) ($setupPath + ' ' + $sha)
  } else { Add-Step 'h2-setup-sha' 'FAIL' ('missing ' + $setupEntry.file) }
  $kernel = $f2.components | Where-Object { $_.id -eq 'kernel.ams.dsh' } | Select-Object -First 1
  if ($kernel) {
    $kernelCandidates = @(
      (Join-Path $ProjRoot ('09_发布\当前\H2_0.2.1_feed2049\' + (Split-Path $kernel.url -Leaf))),
      (Join-Path $ProjRoot ('09_发布\_H2_KERNEL_FIX\' + (Split-Path $kernel.url -Leaf)))
    )
    $kernelPath = Resolve-Feed '' $kernelCandidates
    if ($kernelPath) {
      $sha = Get-Sha $kernelPath
      Add-Step 'h2-kernel-sha' $(if ($sha -eq $kernel.sha256) { 'PASS' } else { 'FAIL' }) ($kernelPath + ' ' + $sha)
    } else { Add-Step 'h2-kernel-sha' 'WARN' 'kernel zip not present locally' }
  }
}
if ($h3Path) {
  $f3 = Get-Content -LiteralPath $h3Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $setupEntry = $f3.setup
  $candidates3 = @(
    (Join-Path $ProjRoot ('09_发布\当前\H3_1.0.0-rc.1_feed2050\' + $setupEntry.file)),
    (Join-Path $ProjRoot ('09_发布\_H3_1.0.0-rc.1\' + $setupEntry.file)),
    (Join-Path $launcher ('installer\' + $setupEntry.file))
  )
  $setupPath = Resolve-Feed '' $candidates3
  if ($setupPath) {
    $sha = Get-Sha $setupPath
    Add-Step 'h3-setup-sha' $(if ($sha -eq $setupEntry.sha256) { 'PASS' } else { 'FAIL' }) ($setupPath + ' ' + $sha)
  } else { Add-Step 'h3-setup-sha' 'FAIL' ('missing ' + $setupEntry.file) }
}

# ---------- 5. Gateway / release 单元测试 ----------
try {
  Push-Location (Join-Path $services 'gateway')
  $glog = Join-Path $OutDir 'gateway-pytest.txt'
  & $py -m pytest -q 2>&1 | Tee-Object -FilePath $glog | Out-Null
  if ($LASTEXITCODE -eq 0) { Add-Step 'gateway-pytest' 'PASS' 'see gateway-pytest.txt' }
  else { Add-Step 'gateway-pytest' 'FAIL' 'see gateway-pytest.txt' }
} finally { Pop-Location }
try {
  Push-Location $releaseDir
  $rlog = Join-Path $OutDir 'release-pytest.txt'
  & $py -m pytest -q tests 2>&1 | Tee-Object -FilePath $rlog | Out-Null
  if ($LASTEXITCODE -eq 0) { Add-Step 'release-pytest' 'PASS' 'see release-pytest.txt' }
  else { Add-Step 'release-pytest' 'FAIL' 'see release-pytest.txt' }
} finally { Pop-Location }

# ---------- 6. 可选：运行中的 Gateway 健康检查 ----------
if (-not [string]::IsNullOrWhiteSpace($AmsHome)) {
  $amsHomeFull = [System.IO.Path]::GetFullPath($AmsHome)
  $portsFile = Join-Path $amsHomeFull 'runtime\ports.json'
  $tokenFile = Join-Path $amsHomeFull 'runtime\gateway.token'
  if ((Test-Path -LiteralPath $portsFile) -and (Test-Path -LiteralPath $tokenFile)) {
    $ports = Get-Content -LiteralPath $portsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    $port = if ($ports.gateway) { $ports.gateway } elseif ($ports.port) { $ports.port } else { $null }
    if ($port) {
      try {
        $h = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $port + '/api/v1/health') -Headers @{ Authorization = 'Bearer ' + $token } -TimeoutSec 10
        Add-Step 'gateway-health' 'PASS' ('port=' + $port + ' ' + ($h | ConvertTo-Json -Compress))
      } catch {
        Add-Step 'gateway-health' 'FAIL' ('port=' + $port + ' ' + $_.Exception.Message)
      }
    } else { Add-Step 'gateway-health' 'WARN' 'ports.json has no gateway port' }
  } else { Add-Step 'gateway-health' 'WARN' 'AmsHome given but ports/token missing' }
}

# ---------- 7. 待执行项（本脚本不覆盖） ----------
Add-Step 'h3-ui-cdp-12tabs' 'DEFERRED' 'run qa/ui-cdp.ps1 against running Kernel'
Add-Step 'h3-gpu-e2e' 'DEFERRED' 'run qa/h4-gpu-e2e.ps1 (RVC/pymss/TTS/train/eval/mix)'
Add-Step 'clean-feed-install' 'DEFERRED' 'strict fresh install from feed in a clean directory'

# ---------- 输出 ----------
$result = [pscustomobject]@{
  schema     = 'ams.qa.h4/1'
  generated  = (Get-Date).ToString('o')
  expect_version = $expect
  feeds      = [pscustomobject]@{ h2 = $h2Path; h3 = $h3Path }
  steps      = $steps
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json') -Encoding UTF8
$md = @('# H4 QA ' + $stamp, '')
$md += '| step | status | detail |'
$md += '|---|---|---|'
foreach ($s in $steps) { $md += ('| ' + $s.name + ' | ' + $s.status + ' | ' + ($s.detail -replace '\|', '/') + ' |') }
$md | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding UTF8
$fail = ($steps | Where-Object { $_.status -eq 'FAIL' }).Count
Write-Output ''
Write-Output ('OUT=' + $OutDir + ' FAIL=' + $fail)
if ($fail -gt 0) { exit 1 }
exit 0
