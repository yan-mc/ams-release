# AMS Studio H3/H4 GPU E2E 脚本
#
# 用途：对运行中的 Gateway 提交真实音频任务并校验产物，覆盖：
#   ping / convert.rvc / separate.pymss / tts.synthesize / evaluate.audio / mix.master
#   可选：train.rvc（小样本，-IncludeTrain）、12 分钟长音频（-IncludeLong）
#
# 前提：Gateway 已用正确的 AMS_HOME 启动；data 内已有 voices/tts_voices/projects 测试数据。
#
# 用法：
#   pwsh -File qa/h4-gpu-e2e.ps1 -AmsHome 'F:\AMS-H4-H3\data'
#   pwsh -File qa/h4-gpu-e2e.ps1 -AmsHome 'F:\AMS-H4-H3\data' -IncludeTrain -IncludeLong
#
# 安全：只提交任务/读产物；输出只写项目 _接管审计 下。

param(
  [string]$AmsHome = 'F:\AMS-H4-H3\data',
  [string]$OutDir = '',
  [switch]$IncludeTrain,
  [switch]$IncludeLong,
  [string]$Device = 'cuda:0',
  [int]$PollSec = 5
)

$ErrorActionPreference = 'Stop'
$projRoot = 'F:\Deepseek_harness\AI音乐处理'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $projRoot ('_接管审计\qa\gpu-e2e-' + $stamp) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$amsHomeFull = [System.IO.Path]::GetFullPath($AmsHome)

# ---------- Gateway 连接 ----------
$portsFile = Join-Path $amsHomeFull 'runtime\ports.json'
$tokenFile = Join-Path $amsHomeFull 'runtime\gateway.token'
if (-not (Test-Path -LiteralPath $portsFile)) { throw ('ports.json missing: ' + $portsFile) }
if (-not (Test-Path -LiteralPath $tokenFile)) { throw ('gateway.token missing: ' + $tokenFile) }
$ports = Get-Content -LiteralPath $portsFile -Raw -Encoding UTF8 | ConvertFrom-Json
# ports.json 形如 {"gateway": {"host":..., "port":..., "pid":..., "api_prefix":..., "token_file":...}}
$port = $null
if ($ports.gateway -and $ports.gateway.port) { $port = $ports.gateway.port }
elseif ($ports.port) { $port = $ports.port }
elseif ($ports.gateway -is [int]) { $port = $ports.gateway }
if (-not $port) {
  $intProp = $ports.PSObject.Properties | Where-Object { $_.Value -is [int] -or $_.Value -is [long] } | Select-Object -First 1
  if ($intProp) { $port = $intProp.Value }
}
if (-not $port) { throw 'cannot determine gateway port from ports.json' }
$token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
$hostAddr = if ($ports.gateway -and $ports.gateway.host) { $ports.gateway.host } else { '127.0.0.1' }
$base = 'http://' + $hostAddr + ':' + $port + '/api/v1'
$headers = @{ Authorization = 'Bearer ' + $token }
Write-Output ('Gateway: ' + $base + '  AMS_HOME=' + $amsHomeFull)

function Invoke-Api([string]$method, [string]$path, $body = $null) {
  $uri = $base + $path
  if ($body -ne $null) {
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Method $method -Uri $uri -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
  }
  return Invoke-RestMethod -Method $method -Uri $uri -Headers $headers -TimeoutSec 60
}

function Resolve-First([string[]]$candidates) {
  foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path } }
  return ''
}

function Submit-Job([string]$type, [hashtable]$params) {
  $resp = Invoke-Api 'POST' '/jobs' @{ type = $type; params = $params; project_id = $null }
  return $resp
}

function Wait-Job([string]$jobId, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  $last = $null
  while ($true) {
    $last = Invoke-Api 'GET' ('/jobs/' + $jobId)
    $status = $last.status
    if ($status -in @('succeeded', 'failed', 'cancelled')) { return $last }
    if ((Get-Date) -gt $deadline) { return $last }
    Start-Sleep -Seconds $PollSec
  }
}

function Run-Case([string]$name, [string]$type, [hashtable]$params, [int]$timeoutSec, [scriptblock]$validate) {
  $item = [ordered]@{ name = $name; type = $type; params = $params; job_id = ''; status = 'FAIL'; detail = ''; artifacts = @() }
  try {
    if ($null -eq $params -or $params.Count -eq 0 -or (@($params.Values) -contains $null) -or (@($params.Values) | Where-Object { $_ -is [string] -and $_ -eq '' })) {
      $item.status = 'SKIP'
      $item.detail = 'missing fixture/params'
      return [pscustomobject]$item
    }
    $submitted = Submit-Job $type $params
    $jobId = $submitted.id
    if (-not $jobId) { $jobId = $submitted.job.id }
    $item.job_id = $jobId
    Write-Output ('  submit ' + $name + ' -> ' + $jobId)
    $final = Wait-Job $jobId $timeoutSec
    $item.status = if ($final.status -eq 'succeeded') { 'PASS' } else { 'FAIL' }
    $item.detail = ('status=' + $final.status + ' progress=' + $final.progress + ' stage=' + $final.stage + ' error=' + ($final.error | ConvertTo-Json -Compress))
    try {
      $arts = Invoke-Api 'GET' ('/jobs/' + $jobId + '/artifacts')
      $list = if ($arts.artifacts) { $arts.artifacts } else { @($arts) }
      $item.artifacts = @($list | ForEach-Object { [pscustomobject]@{ name = $_.name; kind = $_.kind; bytes = $_.bytes; path = $_.path; sha256 = $_.sha256 } })
      if ($item.status -eq 'PASS' -and $validate) {
        $v = & $validate $final $list
        if ($v -ne $true) { $item.status = 'FAIL'; $item.detail = ($item.detail + ' validate=' + $v) }
      }
    } catch { $item.detail = ($item.detail + ' artifacts-error=' + $_.Exception.Message) }
  } catch {
    $item.status = 'FAIL'
    $item.detail = ('exception=' + $_.Exception.Message)
  }
  Write-Output ('  {0,-22} {1,-5} {2}' -f $name, $item.status, $item.detail)
  return [pscustomobject]$item
}

# ---------- 测试夹具 ----------
$imports = Join-Path $amsHomeFull 'projects\imports'
$audio3 = Resolve-First @((Join-Path $imports 'e_audit_3min.wav'), (Join-Path $imports 'sample3min.wav'))
$audio12 = Resolve-First @((Join-Path $imports 'e_audit_12min_long.wav'))
$manbo = Resolve-First @((Join-Path $amsHomeFull 'voices\曼波\曼波.pth'))
$ttsZh = Resolve-First @((Join-Path $amsHomeFull 'tts_voices\zh_CN-huayan-medium\zh_CN-huayan-medium.onnx'))
$trainData = Resolve-First @((Join-Path $amsHomeFull 'datasets\xianyun640\processed'), (Join-Path $amsHomeFull 'datasets\xianyun640'), (Join-Path $amsHomeFull 'datasets\tts\xianyun_full'))
Write-Output ('fixtures: audio3=' + $audio3 + ' audio12=' + $audio12 + ' voice=' + $manbo + ' tts=' + $ttsZh + ' train=' + $trainData)

$cases = New-Object System.Collections.Generic.List[object]

# 1. ping
$cases.Add((Run-Case 'ping' 'ping' @{} 60 { param($j, $a) if (@($a).Count -ge 1) { $true } else { 'no artifact' } }))

# 2. RVC 3 分钟
if ($audio3 -and $manbo) {
  $cases.Add((Run-Case 'convert.rvc.3min' 'convert.rvc' @{
        input_path = $audio3; voice_name = $manbo; f0_up_key = 0; index_rate = 0.75; device = $Device
      } 1800 {
        param($j, $a)
        $wav = @($a) | Where-Object { $_.name -like '*.wav' } | Select-Object -First 1
        if (-not $wav) { return 'no wav artifact' }
        if ([IO.File]::Exists($wav.path) -and (Get-Item -LiteralPath $wav.path).Length -gt 10000) { $true } else { 'wav missing/too small' }
      }))
} else { Write-Output 'SKIP convert.rvc.3min (fixture missing)' }

# 3. pymss 3 分钟
if ($audio3) {
  $cases.Add((Run-Case 'separate.pymss.3min' 'separate.pymss' @{
        input_path = $audio3; model = 'scnet_checkpoint_musdb18'; device = 'auto'
      } 1800 {
        param($j, $a)
        $stems = @($a) | Where-Object { $_.name -like '*.wav' }
        if ($stems.Count -ge 4) { $true } else { 'stems=' + $stems.Count + ' (<4)' }
      }))
} else { Write-Output 'SKIP separate.pymss.3min (fixture missing)' }

# 4. TTS 中文
if ($ttsZh) {
  $cases.Add((Run-Case 'tts.synthesize.zh' 'tts.synthesize' @{
        text = 'AMS Studio H3 验收：中文语音合成，一二三四五。'; model = $ttsZh
      } 600 {
        param($j, $a)
        $wav = @($a) | Where-Object { $_.name -like '*.wav' } | Select-Object -First 1
        if ($wav -and [IO.File]::Exists($wav.path)) { $true } else { 'no wav' }
      }))
} else { Write-Output 'SKIP tts.synthesize (fixture missing)' }

# 5. 评测
if ($audio3) {
  $cases.Add((Run-Case 'evaluate.audio' 'evaluate.audio' @{ input_path = $audio3 } 600 {
        param($j, $a)
        if (@($a).Count -ge 1) { $true } else { 'no report artifact' }
      }))
} else { Write-Output 'SKIP evaluate.audio (fixture missing)' }

# 6. 混音（两轨同一素材，验通链路）
if ($audio3) {
  $cases.Add((Run-Case 'mix.master.2track' 'mix.master' @{
        input_paths = ($audio3 + ';' + $audio3); loudness = '-14'; true_peak = '-1'
      } 900 {
        param($j, $a)
        $wav = @($a) | Where-Object { $_.name -like '*.wav' } | Select-Object -First 1
        if ($wav -and [IO.File]::Exists($wav.path)) { $true } else { 'no wav' }
      }))
} else { Write-Output 'SKIP mix.master (fixture missing)' }

# 7. 可选 12 分钟长音频 RVC（分段 + 长度锁定）
if ($IncludeLong -and $audio12 -and $manbo) {
  $cases.Add((Run-Case 'convert.rvc.12min' 'convert.rvc' @{
        input_path = $audio12; voice_name = $manbo; f0_up_key = 0; index_rate = 0.75; device = $Device
      } 3600 {
        param($j, $a)
        $wav = @($a) | Where-Object { $_.name -like '*.wav' } | Select-Object -First 1
        if (-not $wav) { return 'no wav' }
        if ($wav.meta -and $wav.meta.chunks -and $wav.meta.chunks -ge 2) { $true } else { 'chunks<2' }
      }))
} elseif ($IncludeLong) { Write-Output 'SKIP convert.rvc.12min (fixture missing)' }

# 8. 可选小样本训练
if ($IncludeTrain -and $trainData) {
  $modelName = 'h3_e2e_' + $stamp
  $cases.Add((Run-Case 'train.rvc.smoke' 'train.rvc' @{
        dataset_dir = $trainData; model_name = $modelName; version = 'v2'; sample_rate = '48k'
        if_f0 = 1; f0_method = 'rmvpe'; epochs = 1; batch_size = 2; save_every = 1; gpu = '0'
      } 7200 {
        param($j, $a)
        $voiceDir = Join-Path $amsHomeFull ('voices\' + $modelName)
        $pth = Get-ChildItem -LiteralPath $voiceDir -Filter *.pth -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pth) { $true } else { 'no registered pth' }
      }))
} elseif ($IncludeTrain) { Write-Output 'SKIP train.rvc.smoke (fixture missing)' }

# ---------- 输出 ----------
$failed = @($cases | Where-Object { $_.status -eq 'FAIL' })
$result = [pscustomobject]@{
  schema = 'ams.qa.gpue2e/1'; generated = (Get-Date).ToString('o'); amsHome = $amsHomeFull
  gateway = $base; device = $Device; cases = $cases
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json') -Encoding UTF8
$md = @('# H3 GPU E2E ' + $stamp, '', ('- AMS_HOME: ' + $amsHomeFull), ('- Gateway: ' + $base), ('- Device: ' + $Device), '')
$md += '| case | status | job_id | detail | artifacts |'
$md += '|---|---|---|---|---|'
foreach ($c in $cases) { $md += ('| ' + $c.name + ' | ' + $c.status + ' | ' + $c.job_id + ' | ' + ($c.detail -replace '\|', '/') + ' | ' + @($c.artifacts).Count + ' |') }
$md | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding UTF8
Write-Output ''
Write-Output ('OUT=' + $OutDir + ' FAIL=' + $failed.Count + ' TOTAL=' + $cases.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
