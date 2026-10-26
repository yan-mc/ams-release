# AMS Studio H3/H4 UI CDP 验收脚本
#
# 用途：用 Edge CDP 对运行中的 AMS Kernel 音乐页面逐页签点击验收：
#   - 每个页签：点击 -> 等待 -> 断言页面文本包含页签名 -> 截屏 -> 收集 console 错误
#   - 输出 results.json + summary.md + <序号>-<页签>.png
#
# 前提：Kernel 已启动（launcher 打开 AMS 页面），已知 Kernel URL 与 CDP 端口。
# 若 CDP 端口无浏览器，脚本会尝试用独立 profile 启动 Edge（user-data-dir 在 F 盘）。
#
# 用法：
#   pwsh -File qa/ui-cdp.ps1 -KernelUrl 'http://127.0.0.1:10567'
#   pwsh -File qa/ui-cdp.ps1 -KernelUrl 'http://127.0.0.1:10567' -CdpPort 9223 -NoLaunch
#
# 安全：只读页面；输出只写项目 _接管审计 下；Edge profile 固定在 F 盘。

param(
  [string]$KernelUrl = 'http://127.0.0.1:10567',
  [int]$CdpPort = 9223,
  [string]$OutDir = '',
  [string]$EdgePath = '',
  [switch]$NoLaunch,
  [int]$TabWaitMs = 900
)

$ErrorActionPreference = 'Stop'
$projRoot = 'F:\Deepseek_harness\AI音乐处理'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $projRoot ('_接管审计\qa\ui-cdp-' + $stamp) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# H3 实际页签（plugin-ui FEATURE_TABS + PROJECT_TAB/VC_TAB/LIBRARY_TAB/TTS_BATCH_TAB = 14）
$tabs = @(
  @{ name = '项目'; aliases = @('项目') },
  @{ name = '实时变声'; aliases = @('实时变声') },
  @{ name = '音色库'; aliases = @('音色库') },
  @{ name = 'TTS 批量'; aliases = @('TTS 批量') },
  @{ name = '音源炼制'; aliases = @('音源炼制') },
  @{ name = '数据集工作室'; aliases = @('数据集工作室', '数据集工作室') },
  @{ name = '评测器'; aliases = @('评测器') },
  @{ name = '混音母带'; aliases = @('混音母带') },
  @{ name = '人声分离'; aliases = @('人声分离') },
  @{ name = '歌曲换源'; aliases = @('歌曲换源') },
  @{ name = 'MSVC 工具'; aliases = @('MSVC 工具', 'MSVC') },
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
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return ''
}

if (-not (Test-Cdp)) {
  if ($NoLaunch) { throw ('CDP port ' + $CdpPort + ' not available and -NoLaunch set') }
  $edge = Find-Edge
  if (-not $edge) { throw 'msedge.exe not found' }
  $profile = 'F:\_edge-cdp-profile'
  $cache = 'F:\_edge-cdp-cache'
  New-Item -ItemType Directory -Force -Path $profile, $cache | Out-Null
  $env:TMP = 'F:\_edge-cdp-tmp'; $env:TEMP = $env:TMP; $env:TMPDIR = $env:TMP
  New-Item -ItemType Directory -Force -Path $env:TMP | Out-Null
  Write-Output ('launching Edge: ' + $edge)
  Start-Process -FilePath $edge -ArgumentList @(
    ('--remote-debugging-port=' + $CdpPort),
    ('--user-data-dir=' + $profile),
    ('--disk-cache-dir=' + $cache),
    '--no-first-run', '--no-default-browser-check', '--disable-crash-reporter',
    $KernelUrl
  ) | Out-Null
  $deadline = (Get-Date).AddSeconds(40)
  while (-not (Test-Cdp)) {
    if ((Get-Date) -gt $deadline) { throw 'Edge CDP did not become ready' }
    Start-Sleep -Milliseconds 500
  }
}

# 选择 Kernel 页面
$pages = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $CdpPort + '/json') -TimeoutSec 10
$kernelPort = ([Uri]$KernelUrl).Port
$page = $pages | Where-Object { $_.type -eq 'page' -and $_.url -match (':(' + $kernelPort + ')/') } | Select-Object -First 1
if (-not $page) { $page = $pages | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 }
if (-not $page) { throw 'no page target found in Edge' }
Write-Output ('target page: ' + $page.url)

# ---------- CDP 连接 ----------
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait()
$script:cdpId = 0
$script:events = New-Object System.Collections.Generic.List[object]

function Send-Cdp([string]$method, [hashtable]$params) {
  $script:cdpId++
  $id = $script:cdpId
  $obj = @{ id = $id; method = $method; params = $params }
  $json = $obj | ConvertTo-Json -Depth 12 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
  $buf = New-Object byte[] 2097152
  $cts = [System.Threading.CancellationTokenSource]::new(20000)
  while ($true) {
    $res = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
    $msg = $text | ConvertFrom-Json
    if ($msg.id -eq $id) { return $msg }
    if ($msg.method) { $script:events.Add($msg) }
    if ($msg.id -ne $id -and -not $msg.method) { continue }
  }
}
function Eval([string]$expr) {
  $r = Send-Cdp 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
  if ($r.result.exceptionDetails) { return ('EVAL_ERROR: ' + ($r.result.exceptionDetails.text)) }
  return $r.result.result.value
}

$null = Send-Cdp 'Runtime.enable' @{}
$null = Send-Cdp 'Page.enable' @{}
$null = Send-Cdp 'Log.enable' @{}
Start-Sleep -Milliseconds 500

$title = Eval 'document.title'
$url = Eval 'location.href'
$sessionOk = Eval "(()=>{try{return document.body.innerText.includes('AMS')||document.querySelectorAll('button').length>0}catch(e){return false}})()"
Write-Output ('page title=' + $title + ' url=' + $url)

$results = New-Object System.Collections.Generic.List[object]
$index = 0
foreach ($tab in $tabs) {
  $index++
  $script:events.Clear()
  $aliasJson = ($tab.aliases | ConvertTo-Json -Compress)
  $clickJs = @"
(() => {
  const aliases = $aliasJson;
  const nodes = [...document.querySelectorAll('button,[role=tab],a,div,span')];
  for (const alias of aliases) {
    const hit = nodes.find(x => x.innerText && x.innerText.trim() === alias);
    if (hit) { hit.click(); return 'clicked:' + alias; }
  }
  return 'missing';
})()
"@
  $click = Eval $clickJs
  Start-Sleep -Milliseconds $TabWaitMs
  $body = Eval 'document.body.innerText'
  $has = $false
  if ($body -is [string]) { $has = $body.Contains($tab.name) }
  $errs = @()
  foreach ($ev in $script:events) {
    if ($ev.method -eq 'Runtime.exceptionThrown') { $errs += ('exception:' + $ev.params.exceptionDetails.text) }
    if ($ev.method -eq 'Log.entryAdded' -and $ev.params.entry.level -eq 'error') { $errs += ('log:' + $ev.params.entry.text) }
    if ($ev.method -eq 'Runtime.consoleAPICalled' -and $ev.params.type -eq 'error') { $errs += 'console.error' }
  }
  $shotFile = ''
  try {
    $shot = Send-Cdp 'Page.captureScreenshot' @{ format = 'png' }
    if ($shot.result.data) {
      $shotFile = Join-Path $OutDir (('{0:d2}-' -f $index) + ($tab.name -replace '[\\/:*?"<>| ]', '_') + '.png')
      [IO.File]::WriteAllBytes($shotFile, [Convert]::FromBase64String($shot.result.data))
    }
  } catch { $errs += ('screenshot:' + $_.Exception.Message) }
  $status = 'PASS'
  if ($click -ne 'clicked' -and $click -notlike 'clicked:*') { $status = 'FAIL' }
  elseif (-not $has) { $status = 'FAIL' }
  elseif ($errs.Count -gt 0) { $status = 'WARN' }
  $results.Add([pscustomobject]@{
      index = $index; tab = $tab.name; click = $click; contains = $has
      status = $status; errors = $errs; screenshot = $shotFile
    })
  Write-Output ('{0,-14} {1,-5} click={2,-18} contains={3} errors={4}' -f $tab.name, $status, $click, $has, $errs.Count)
}

$ws.Dispose()

# ---------- 输出 ----------
$result = [pscustomobject]@{
  schema    = 'ams.qa.uicdp/1'
  generated = (Get-Date).ToString('o')
  kernelUrl = $KernelUrl
  pageUrl   = $url
  pageTitle = $title
  tabs      = $results
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
Write-Output ''
Write-Output ('OUT=' + $OutDir + ' FAIL=' + $fails + ' TABS=' + $results.Count)
if ($fails -gt 0) { exit 1 }
exit 0
