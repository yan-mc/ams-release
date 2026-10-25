param([switch]$Offline)
$ErrorActionPreference='Stop'
$root='F:\Deepseek_harness\AI音乐处理'
$code=Join-Path $root '08_项目代码'
$launcher=Join-Path $code 'ams-launcher'
$plugins=Join-Path $code 'ams-plugins'
$services=Join-Path $code 'ams-services'
$release=Join-Path $code 'ams-release'
$py=Join-Path $services 'gateway\.venv\Scripts\python.exe'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$out=Join-Path 'F:\AMS-Studio\data\qa\H3' $stamp
New-Item -ItemType Directory -Force -Path $out|Out-Null
$steps=@()
function Add-Step($name,$status,$detail){ $script:steps += [pscustomobject]@{name=$name;status=$status;detail=$detail}; Write-Output ($name+' | '+$status+' | '+$detail) }
function Get-Version($path,$pattern){ try { $m=Select-String -Path $path -Pattern $pattern|Select-Object -First 1; if($m){return $m.Matches[0].Groups[1].Value} } catch {}; return '?' }
$lv=Get-Version (Join-Path $launcher 'package.json') '"version"\s*:\s*"([^"]+)"'
$tv=Get-Version (Join-Path $launcher 'src-tauri\tauri.conf.json') '"version"\s*:\s*"([^"]+)"'
$pv=Get-Version (Join-Path $plugins 'packages\plugin-core\package.json') '"version"\s*:\s*"([^"]+)"'
$gv=Get-Version (Join-Path $services 'gateway\pyproject.toml') '^version\s*=\s*"([^"]+)"'
Add-Step 'version-matrix' 'INFO' ("launcher=$lv tauri=$tv plugin=$pv gateway=$gv expected=1.0.0-rc.1")
if(($lv -eq '1.0.0-rc.1') -and ($tv -eq '1.0.0-rc.1') -and ($pv -eq '1.0.0-rc.1') -and ($gv -eq '1.0.0-rc.1')){ Add-Step 'version-unified' 'PASS' 'all 1.0.0-rc.1' } else { Add-Step 'version-unified' 'FAIL' 'not unified for RC' }
# feed/setup
try {
 $feed=Invoke-RestMethod 'https://github.com/yan-mc/ams-release/releases/latest/download/ams-components.json'
 $setup=$feed.setup
 Add-Step 'feed' 'PASS' ('sequence='+$feed.sequence+' setup='+$setup.file+' bytes='+$setup.bytes)
 $setupPath=Join-Path $launcher ('installer\dist\'+$setup.file)
 if(Test-Path -LiteralPath $setupPath){ $h=(Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash; if($h -eq $setup.sha256){Add-Step 'setup-hash' 'PASS' $h}else{Add-Step 'setup-hash' 'FAIL' ('local='+$h+' feed='+$setup.sha256)} } else { Add-Step 'setup-hash' 'WARN' ('local setup missing: '+$setupPath) }
} catch { Add-Step 'feed' 'FAIL' $_.Exception.Message }
# remote release manifest
try {
 $mtmp=Join-Path $out 'remote-manifest.json'
 & curl.exe -sS -L 'https://github.com/yan-mc/ams-release/releases/download/v0.2.1/RELEASE_MANIFEST.json' -o $mtmp
 $m=Get-Content -LiteralPath $mtmp -Raw|ConvertFrom-Json
 $ftmp=Join-Path $out 'remote-feed.json'
 & curl.exe -sS -L 'https://github.com/yan-mc/ams-release/releases/latest/download/ams-components.json' -o $ftmp
 $feed=Get-Content -LiteralPath $ftmp -Raw|ConvertFrom-Json
 if(($m.sequence -eq $feed.sequence) -and ($m.setup.sha256 -eq $feed.setup.sha256)){Add-Step 'release-manifest' 'PASS' ('sequence='+$m.sequence)}else{Add-Step 'release-manifest' 'FAIL' ('manifest='+$m.sequence+'/'+$m.product_version+' feed='+$feed.sequence+'/'+$feed.setup.sha256)}
} catch { Add-Step 'release-manifest' 'FAIL' $_.Exception.Message }
# gateway tests
Set-Location (Join-Path $services 'gateway')
$glog=Join-Path $out 'gateway-pytest.txt'
& $py -m pytest -q 2>&1 | Tee-Object -FilePath $glog | Out-Null
if($LASTEXITCODE -eq 0){Add-Step 'gateway-pytest' 'PASS' 'see gateway-pytest.txt'}else{Add-Step 'gateway-pytest' 'FAIL' 'see gateway-pytest.txt'}
# release tests
Set-Location $release
$rlog=Join-Path $out 'release-pytest.txt'
& $py -m pytest -q tests 2>&1 | Tee-Object -FilePath $rlog | Out-Null
if($LASTEXITCODE -eq 0){Add-Step 'release-pytest' 'PASS' 'see release-pytest.txt'}else{Add-Step 'release-pytest' 'FAIL' 'see release-pytest.txt'}
# feed signature only if local v44 exists
$localFeed=Join-Path $root '09_发布\_阶段G_20261025_135440\ams-components-v44.json'
$pub=Join-Path $release 'examples\keys\public.pem'
if(Test-Path -LiteralPath $localFeed){ & $py (Join-Path $release 'tools\manifest.py') verify $localFeed --pub $pub --min-sequence 2044 2>&1 | Tee-Object -FilePath (Join-Path $out 'signature.txt') | Out-Null; if($LASTEXITCODE -eq 0){Add-Step 'feed-signature' 'PASS' 'v44'}else{Add-Step 'feed-signature' 'FAIL' 'see signature.txt'} } else { Add-Step 'feed-signature' 'WARN' 'local feed v44 missing' }
# H3 RC local artifacts
$rc=Join-Path $root '09_发布\_H3_1.0.0-rc.1'
$rcFeed=Join-Path $rc 'ams-components.json'
$rcMan=Join-Path $rc 'RELEASE_MANIFEST.json'
$rcSetup=Join-Path $rc 'AMS-Studio-Setup-1.0.0-rc.1.exe'
if((Test-Path $rcFeed) -and (Test-Path $rcMan)){
 $rf=Get-Content $rcFeed -Raw|ConvertFrom-Json; $rm=Get-Content $rcMan -Raw|ConvertFrom-Json
 if(($rf.sequence -eq 2045) -and ($rm.sequence -eq 2045) -and ($rf.setup.sha256 -eq $rm.setup.sha256)){Add-Step 'rc-feed-manifest' 'PASS' 'sequence=2045'}else{Add-Step 'rc-feed-manifest' 'FAIL' ('feed='+$rf.sequence+' manifest='+$rm.sequence)}
 & $py (Join-Path $release 'tools\manifest.py') verify $rcFeed --pub $pub --min-sequence 2045 2>&1 | Tee-Object -FilePath (Join-Path $out 'rc-signature.txt') | Out-Null
 if($LASTEXITCODE -eq 0){Add-Step 'rc-signature' 'PASS' 'v45'}else{Add-Step 'rc-signature' 'FAIL' 'see rc-signature.txt'}
 if(Test-Path $rcSetup){ $h=(Get-FileHash $rcSetup -Algorithm SHA256).Hash; if($h -eq $rf.setup.sha256){Add-Step 'rc-setup-hash' 'PASS' $h}else{Add-Step 'rc-setup-hash' 'FAIL' ('local='+$h+' feed='+$rf.setup.sha256)} }else{Add-Step 'rc-setup-hash' 'FAIL' 'RC setup missing'}
}else{Add-Step 'rc-feed-manifest' 'FAIL' 'local RC artifacts missing'}
# deferred
Add-Step 'ui-cdp' 'DEFERRED' 'requires running UI/Gateway; run after H2'
Add-Step 'installer-clean-dir' 'DEFERRED' 'run after RC setup build'
Add-Step 'clean-dir-rc' 'DEFERRED' 'run after RC version/build'
$result=[pscustomobject]@{timestamp=$stamp;steps=$steps}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
$md=@('# H3 QA '+$stamp+'','')
foreach($s in $steps){$md += '- **'+$s.name+'**: '+$s.status+' - '+$s.detail}
$md|Set-Content -LiteralPath (Join-Path $out 'summary.md') -Encoding UTF8
Write-Output ('OUT='+$out)
