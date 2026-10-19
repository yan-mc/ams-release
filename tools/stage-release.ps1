param(
    [string]$Out = "F:\Deepseek_harness\AI音乐处理\09_发布\staging",
    [string]$VoiceSource = "F:\ai歌曲\0 曼波"
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$launcherBundle = "F:\Deepseek_harness\AI音乐处理\08_项目代码\ams-launcher\src-tauri\target\release\bundle"
if (-not (Test-Path -LiteralPath $launcherBundle)) { throw "先构建启动器：corepack pnpm tauri build" }
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$assets = Join-Path $Out "assets"
New-Item -ItemType Directory -Force -Path $assets | Out-Null
& (Join-Path $PSScriptRoot "build-voicepack.ps1") -Source $VoiceSource -Out (Join-Path $assets "voicepack-manbo.zip") | Out-Null
$latestExe = Get-ChildItem -LiteralPath (Join-Path $launcherBundle "nsis") -Filter *.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$latestMsi = Get-ChildItem -LiteralPath (Join-Path $launcherBundle "msi") -Filter *.msi | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latestExe -or -not $latestMsi) { throw "未找到 NSIS/MSI 产物" }
Copy-Item -LiteralPath $latestExe.FullName -Destination $Out -Force
Copy-Item -LiteralPath $latestMsi.FullName -Destination $Out -Force
Copy-Item -LiteralPath "F:\Deepseek_harness\AI音乐处理\08_项目代码\ams-launcher\src-tauri\target\release\ams-launcher.exe" -Destination $Out -Force
$files = Get-ChildItem -LiteralPath $Out -Recurse -File | Where-Object { $_.Name -ne "stage-manifest.json" }
$components = foreach ($f in $files) {
    [ordered]@{
        file = $f.FullName.Substring($Out.Length + 1).Replace('\','/')
        size = $f.Length
        sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
    }
}
$manifest = [ordered]@{
    schema = "ams-stage/1"
    generated_at = (Get-Date).ToString("o")
    root = $Out
    voicepack = "assets/voicepack-manbo.zip"
    components = $components
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Out "stage-manifest.json") -Encoding UTF8
$manifest | ConvertTo-Json -Depth 5