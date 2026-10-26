# AMS Studio H3/H4 UI CDP 验收脚本
#
# 用途：用 Edge CDP 对运行中的 AMS Kernel 音乐页面逐页签点击验收：
#   前置：关闭预览弹窗 -> 点击侧栏「AMS 音乐」进入插件页
#   逐页签：点击 -> 等待 -> 断言页面文本包含页签名 -> 截屏 -> 收集 console/exception 错误
#   输出：results.json + summary.md + run.log + <序号>-<页签>.png
#
# 用法：
#   pwsh -File qa/ui-cdp.ps1 -KernelUrl 'http://127.0.0.1:1279/?token=...'
#   pwsh -File qa/ui-cdp.ps1 -KernelUrl 'http://127.0.0.1:1279' -CdpPort 9223 -NoLaunch
#
# 安全：只读页面；输出只写项目 _接管审计 下；Edge profile 固定在 F 盘。

param(
  [string]$KernelUrl = 'http://127.0.0.1:10567',
  [int]$CdpPort = 9223,
  [string]$OutDir = '',
  [string]$EdgePath = '',
  [switch]$NoLaunch,
  [int]$TabWaitMs = 700,
  [int]$CdpTimeoutMs = 15000
)

$ErrorActionPreference = 'Stop'
$projRoot = 'F:\Deepseek_harness\AI音乐处理'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $projRoot ('_接管审计\qa\ui-cdp-' + $stamp) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$runLog = Join-Path $OutDir 'run.log'
function Log([string]$msg) {
  $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $msg
  Add-Content -LiteralPath $runLog -Value $line -Encoding UTF8
  Write-Output $line
}

# H3 实际页签（plugin-ui：PROJECT_TAB/VC_TAB/LIBRARY_TAB/TTS_BATCH_TAB + 10 个 FEATURE_TABS = 14）
$tabs = @(
  @{ name = '项目'; aliases = @('项目') },
  @{ name = '实时变声'; aliases = @('实时变声') },
  @{ name = '音色库'; aliases = @('音色库') },
  @{ name = 'TTS 批量'; aliases = @('TTS 批量') },
  @{ name = '音源炼制'; aliases = @('音源炼制') },
  @{ name = '数据集工作室'; aliases = @('数据集工作室') },
  @{ name = '评测器'; aliases = @('评测器') },
  @{ name = '混音母带'; aliases = @('混音母带') },
  @{ name = '人声分离'; aliases = @('人声分离') },
  @{ name = '歌曲换源'; aliases = @('歌曲换源') },
  @{ name = 'MSVC 工具'; aliases = @('MSVC 工具') },
  @{ name = 'TTS 语音合成'; aliases = @('TTS 语音合成') },
  @{ name = 'TTS 数据集'; aliases = @('TTS 数据集') },
  @{ name = 'TTS 音源炼制'; aliases = @('TTS 音源炼制') }
)

function Test-Cdp {
  try { $null = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $CdpPort + '/json/version') -TimeoutSec 3; return $true }
  catch { return $false }
}
function Find-Edge {
  if (-not [string]::IsNullOrWhiteSpace($EdgePath) -and (Test-Path -LiteralPath $EdgePath)) { return $EdgePath }
  foreach ($c in @(
      'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      'C:\Program Files\Microsoft\Edge\Application\msedge.exe')) {
    if (Test-Path -LiteralPath $c) { return $c }
  }
  return ''
}

if (-not (Test-Cdp)) {
  if ($NoLaunch) { throw ('CDP port ' + $CdpPort + ' not available and -NoLaunch set') }
  $edge = Find-Edge
  if (-not $edge) { throw 'msedge.exe not found' }
  $profile = 'F:\_edge-cdp-profile'; $cache = 'F:\_edge-cdp-cache'
  New-Item -ItemType Directory -Force -Path $profile, $cache | Out-Null
  $env:TMP = 'F:\_edge-cdp-tmp'; $env:TEMP = $env:TMP; $env:TMPDIR = $env:TMP
  New-Item -ItemType Directory -Force -Path $env:TMP | Out-Null
  Log ('launch edge: ' + $edge)
  Start-Process -FilePath $edge -ArgumentList @(
    ('--remote-debugging-port=' + $CdpPort), ('--user-data-dir=' + $profile),
    ('--disk-cache-dir=' + $cache), '--no-first-run', '--no-default-browser-check',
    '--disable-crash-reporter', $KernelUrl) | Out-Null
  $deadline = (Get-Date).AddSeconds(40)
  while (-not (Test-Cdp)) { if ((Get-Date) -gt $deadline) { throw 'Edge CDP did not become ready' }; Start-Sleep -Milliseconds 500 }
}

$pages = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $CdpPort + '/json') -TimeoutSec 10
$kernelPort = ([Uri]$KernelUrl).Port
$page = $pages | Where-Object { $_.type -eq 'page' -and $_.url -match (':(' + $kernelPort + ')/') } | Select-Object -First 1
$needNavigate = $false
if (-not $page) {
  $page = $pages | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
  $needNavigate = $true
}
if (-not $page) { throw 'no page target found in Edge' }
Log ('target page: ' + $page.url)

$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait()
$script:cdpId = 0
$script:errors = New-Object System.Collections.Generic.List[string]

function Send-Cdp([string]$method, [hashtable]$params) {
  $script:cdpId++
  $id = $script:cdpId
  $obj = @{ id = $id; method = $method; params = $params }
  $json = $obj | ConvertTo-Json -Depth 12 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  try { $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait() }
  catch { Log ('send-fail ' + $method + ' ' + $_.Exception.Message); return $null }
  $buf = New-Object byte[] 4194304
  $cts = [System.Threading.CancellationTokenSource]::new($CdpTimeoutMs)
  try {
    while ($true) {
      $res = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
      $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
      $m = $txt | ConvertFrom-Json
      if ($m.id -eq $id) { return $m }
      if ($m.method -eq 'Runtime.exceptionThrown') { $script:errors.Add('exception:' + $m.params.exceptionDetails.text) }
      if ($m.method -eq 'Log.entryAdded' -and $m.params.entry.level -eq 'error') { $script:errors.Add('log:' + $m.params.entry.text) }
      if ($m.method -eq 'Runtime.consoleAPICalled' -and $m.params.type -eq 'error') { $script:errors.Add('console.error') }
    }
  } catch {
    Log ('timeout ' + $method)
    return $null
  }
}
function Eval([string]$expr) {
  $r = Send-Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
  if ($null -eq $r) { return $null }
  if ($r.result.exceptionDetails) { return ('EVAL_ERROR: ' + $r.result.exceptionDetails.text) }
  return $r.result.result.value
}

$null = Send-Cdp 'Runtime.enable' @{}
$null = Send-Cdp 'Page.enable' @{}
$null = Send-Cdp 'Log.enable' @{}
Start-Sleep -Milliseconds 400

# 若当前页面不是目标 Kernel，先导航过去（复用同一个 CDP 页面，避免测试到旧环境）
if ($needNavigate) {
  Log ('navigate -> ' + $KernelUrl)
  $null = Send-Cdp 'Page.navigate' @{ url = $KernelUrl }
  Start-Sleep -Seconds 4
}

$title = Eval 'document.title'
$url = Eval 'location.href'
Log ('page title=' + $title + ' url=' + $url)

# 前置 1：关闭预览版说明等弹窗
$dismissed = Eval "(()=>{for(const l of ['继续','知道了','关闭','稍后再说']){const b=[...document.querySelectorAll('button')].find(x=>x.innerText&&x.innerText.trim()===l);if(b){b.click();return 'dismissed:'+l}}return 'none'})()"
Log ('overlay: ' + $dismissed)
Start-Sleep -Milliseconds 600

# 前置 2：进入 AMS 音乐页
$entered = Eval "(()=>{const els=[...document.querySelectorAll('button,a,[role=button],div,span')];const hit=els.find(x=>x.innerText&&x.innerText.trim()==='AMS 音乐');if(hit){hit.click();return 'entered'}return 'missing'})()"
Log ('ams-page: ' + $entered)
Start-Sleep -Milliseconds 1200
$amsBody = Eval 'document.body.innerText'
if ($amsBody -is [string]) { Log ('ams page body chars=' + $amsBody.Length) }

$results = New-Object System.Collections.Generic.List[object]
$index = 0
foreach ($tab in $tabs) {
  $index++
  $script:errors.Clear()
  $aliasJson = ConvertTo-Json -InputObject @($tab.aliases) -Compress
  $clickJs = @"
(() => {
  const aliases = $aliasJson;
  const els = [...document.querySelectorAll('button,[role=tab],a,div,span')];
  for (const alias of aliases) {
    const hit = els.find(x => x.innerText && x.innerText.trim() === alias);
    if (hit) { hit.click(); return 'clicked:' + alias; }
  }
  return 'missing';
})()
"@
  $click = Eval $clickJs
  Start-Sleep -Milliseconds $TabWaitMs
  $body = Eval 'document.body.innerText'
  $has = ($body -is [string]) -and $body.Contains($tab.name)
  $errs = @($script:errors)
  $shotFile = ''
  $shot = Send-Cdp 'Page.captureScreenshot' @{ format = 'png'; fromSurface = $false }
  if ($null -ne $shot -and $shot.result.data) {
    $shotFile = Join-Path $OutDir (('{0:d2}-' -f $index) + ($tab.name -replace '[\\/:*?"<>| ]', '_') + '.png')
    [IO.File]::WriteAllBytes($shotFile, [Convert]::FromBase64String($shot.result.data))
  }
  $status = 'PASS'
  if ($null -eq $click -or $click -notlike 'clicked:*') { $status = 'FAIL' }
  elseif (-not $has) { $status = 'FAIL' }
  elseif ($errs.Count -gt 0) { $status = 'WARN' }
  $results.Add([pscustomobject]@{
      index = $index; tab = $tab.name; click = $click; contains = $has
      status = $status; errors = $errs; screenshot = $shotFile
    })
  Log (('{0,-14} {1,-5} click={2,-16} contains={3} errors={4}' -f $tab.name, $status, $click, $has, $errs.Count))
}

try { $ws.Dispose() } catch {}

$result = [pscustomobject]@{
  schema = 'ams.qa.uicdp/1'; generated = (Get-Date).ToString('o')
  kernelUrl = $KernelUrl; pageUrl = $url; pageTitle = $title; tabs = $results
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json') -Encoding UTF8
$md = @('# H3 UI CDP ' + $stamp, '', ('- KernelUrl: ' + $KernelUrl), ('- page: ' + $url), '')
$md += '| # | tab | status | click | contains | errors | screenshot |'
$md += '|---|---|---|---|---|---|---|'
foreach ($r in $results) {
  $shot = if ($r.screenshot) { [IO.Path]::GetFileName($r.screenshot) } else { '' }
  $md += ('| ' + $r.index + ' | ' + $r.tab + ' | ' + $r.status + ' | ' + $r.click + ' | ' + $r.contains + ' | ' + ($r.errors -join '; ') + ' | ' + $shot + ' |')
}
$md | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding UTF8
$fails = ($results | Where-Object { $_.status -eq 'FAIL' }).Count
Log ('OUT=' + $OutDir + ' FAIL=' + $fails + ' TABS=' + $results.Count)
if ($fails -gt 0) { exit 1 }
exit 0
