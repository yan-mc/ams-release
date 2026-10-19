param(
    [string]$Workspace = "F:\Deepseek_harness\AI音乐处理\08_项目代码",
    [string]$OutDir = ""
)
$ErrorActionPreference = "Stop"
$repos = @("ams-launcher","ams-harness","ams-plugins","ams-services","ams-tools","ams-release","ams-docs")
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $Workspace "_backups" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$results = @()
foreach ($name in $repos) {
    $repo = Join-Path $Workspace $name
    if (-not (Test-Path (Join-Path $repo ".git"))) {
        $results += [pscustomobject]@{ repo=$name; status="skip"; file="" }
        continue
    }
    $bundle = Join-Path $OutDir ("{0}-{1}.bundle" -f $name, $stamp)
    git -C $repo bundle create $bundle --all | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $results += [pscustomobject]@{ repo=$name; status="FAIL-create"; file=$bundle }
        continue
    }
    git -C $repo bundle verify $bundle | Out-Null
    $status = if ($LASTEXITCODE -eq 0) { "ok" } else { "FAIL-verify" }
    $results += [pscustomobject]@{ repo=$name; status=$status; file=$bundle }
}
$results | Format-Table -AutoSize | Out-String -Width 240
