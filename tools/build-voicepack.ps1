param(
    [string]$Source = "F:\ai歌曲\0 曼波",
    [string]$Out = "",
    [string]$Name = "曼波"
)
$ErrorActionPreference = "Stop"
$pth = Join-Path $Source "manbo.pth"
$index = Join-Path $Source "manbo.index"
if (-not (Test-Path -LiteralPath $pth)) { throw "pth 不存在：$pth" }
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "dist\voicepack-$Name.zip" }
$Out = $Out -replace '\\','/'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ams-voicepack-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$targetPth = Join-Path $tmp ("$Name.pth")
$hash = (Get-FileHash -LiteralPath $pth -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item -LiteralPath $pth).Length
Copy-Item -LiteralPath $pth -Destination $targetPth
$entry = [ordered]@{
    schema = "ams-voice/1"
    name = $Name
    pth = [ordered]@{ file = "$Name.pth"; size = $size; sha256 = $hash }
    index = $null
    source = "local"
    created_at = (Get-Date).ToString("o")
}
if (Test-Path -LiteralPath $index) {
    Copy-Item -LiteralPath $index -Destination (Join-Path $tmp ("$Name.index"))
    $entry.index = [ordered]@{
        file = "$Name.index"
        size = (Get-Item -LiteralPath $index).Length
        sha256 = (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash.ToLower()
    }
}
$entry | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $tmp "voice.json") -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $Out -CompressionLevel Optimal
Remove-Item -LiteralPath $tmp -Recurse -Force
[pscustomobject]@{ voicepack = $Out; size = (Get-Item -LiteralPath $Out).Length; sha256 = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLower() } | Format-List
