param(
    [string]$Out = "F:\Deepseek_harness\AI音乐处理\09_发布\updates",
    [string]$Version = "0.2.0",
    [string]$PluginVersion = "0.3.0",
    [long]$Sequence = 2000,
    [string]$Key = "F:\Deepseek_harness\AI音乐处理\08_项目代码\ams-release\examples\keys\private.pem",
    [string]$PublicKey = "F:\Deepseek_harness\AI音乐处理\08_项目代码\ams-release\examples\keys\public.pem",
    [string]$UrlBase = ""
)
$ErrorActionPreference = "Stop"
$project = "F:\Deepseek_harness\AI音乐处理"
$pluginsDist = Join-Path $project "08_项目代码\ams-plugins\dist"
$gatewayDist = Join-Path $project "08_项目代码\ams-services\gateway\build\dist\ams-gateway"
$catalogJson = Join-Path $project "08_项目代码\ams-release\examples\catalog.models-2026.10.19.json"
$manifestTool = Join-Path $project "08_项目代码\ams-release\tools\manifest.py"
$outFull = [System.IO.Path]::GetFullPath($Out)
$allowed = [System.IO.Path]::GetFullPath((Join-Path $project "09_发布"))
if (-not $outFull.StartsWith($allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝写入 09_发布 以外的目录：$outFull"
}
foreach ($src in @($pluginsDist, $gatewayDist, $catalogJson, $manifestTool, $Key, $PublicKey)) {
    if (-not (Test-Path -LiteralPath $src)) { throw "缺少输入：$src" }
}
if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Recurse -Force }
$packages = Join-Path $outFull "packages"
New-Item -ItemType Directory -Force -Path $packages | Out-Null

function New-ComponentZip($name, $sourceDir, $outFile) {
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
    Compress-Archive -Path (Join-Path $sourceDir "*") -DestinationPath $outFile -CompressionLevel Optimal
}

$pluginZip = Join-Path $packages ("plugin-ams-music-bundle-$PluginVersion.zip")
$gatewayZip = Join-Path $packages ("service-gateway-0.1.0.zip")
$catalogZip = Join-Path $packages ("catalog-models-2026.10.19.zip")
New-ComponentZip "plugins" $pluginsDist $pluginZip
New-ComponentZip "gateway" $gatewayDist $gatewayZip
$catalogTmp = Join-Path $outFull "_catalog_tmp"
New-Item -ItemType Directory -Force -Path $catalogTmp | Out-Null
Copy-Item -LiteralPath $catalogJson -Destination (Join-Path $catalogTmp "models.json") -Force
New-ComponentZip "catalog" $catalogTmp $catalogZip
Remove-Item -LiteralPath $catalogTmp -Recurse -Force

function Asset($id, $kind, $version, $file, $notes) {
    $full = $file
    $url = if ($UrlBase) { $UrlBase.TrimEnd('/') + '/' + (Split-Path $full -Leaf) } else { "file:///" + ($full -replace '\\','/') }
    [ordered]@{
        id = $id
        kind = $kind
        version = $version
        url = $url
        size = (Get-Item -LiteralPath $full).Length
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
        signature_key_id = "ed25519:ams-dev-2026a"
        requires = @{}
        notes = $notes
    }
}

$components = @(
    (Asset "plugin.ams.music.bundle" "plugin" $PluginVersion $pluginZip "AMS 插件 bundle（plugin-core/plugin-ui/music-bundle 3 个 tgz），解包到 components 目录后由 DSH 安装"),
    (Asset "service.gateway" "service" "0.1.0" $gatewayZip "Gateway PyInstaller 单文件目录，解包到 components/service.gateway"),
    (Asset "catalog.models" "catalog" "2026.10.19" $catalogZip "模型目录索引（zip 内 models.json）")
)
$manifest = [ordered]@{
    schema = "ams-update/1"
    channel = "stable"
    generated_at = (Get-Date).ToString("o")
    sequence = $Sequence
    min_launcher = $Version
    components = $components
}
$unsigned = Join-Path $outFull "ams-components.unsigned.json"
$signed = Join-Path $outFull "ams-components.signed.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unsigned -Encoding UTF8

& python $manifestTool sign $unsigned --key $Key --out $signed
if ($LASTEXITCODE -ne 0) { throw "签名失败（exit $LASTEXITCODE）" }
& python $manifestTool verify $signed --pub $PublicKey --min-sequence $Sequence
if ($LASTEXITCODE -ne 0) { throw "验签失败（exit $LASTEXITCODE）" }
Copy-Item -LiteralPath $signed -Destination (Join-Path $outFull "ams-components.json") -Force

$readme = @"
AMS M2 本地组件更新包
- feed: ams-components.json（Ed25519 已签名，sequence=$Sequence，min_launcher=$Version）
- packages/: 组件 zip（plugin/service/catalog）
- 启动器用 AMS_COMPONENTS_FEED 指向本目录的 ams-components.json 即可离线检查/安装
- 生产环境应把同一 feed 与 packages 放到可公开访问的更新服务器；私有 GitHub Release 需鉴权，不能直接作为匿名 feed
"@
$readme | Set-Content -LiteralPath (Join-Path $outFull "README.txt") -Encoding UTF8

$result = [ordered]@{
    out = $outFull
    sequence = $Sequence
    components = @($components | ForEach-Object { [ordered]@{ id=$_.id; kind=$_.kind; version=$_.version; size=$_.size; sha256=$_.sha256; url=$_.url } })
    feed = (Join-Path $outFull "ams-components.json")
}
$result | ConvertTo-Json -Depth 6