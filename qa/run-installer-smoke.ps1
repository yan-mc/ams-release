param(
  [string]$Setup = 'F:\Deepseek_harness\AI音乐处理\09_发布\_H3_1.0.0-rc.1\AMS-Studio-Setup-1.0.0-rc.1.exe',
  [string]$OldSetup = 'F:\Deepseek_harness\AI音乐处理\08_项目代码\ams-launcher\installer\dist\AMS-Studio-Setup-0.2.1.exe',
  [string]$Target = 'F:\AMS-Studio-H3AutoTest'
)
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path 'F:\AMS-Studio\data\qa\H3' ('installer-' + $stamp)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$steps = @()
function Add-Step($name,$status,$detail){ $script:steps += [pscustomobject]@{name=$name;status=$status;detail=$detail}; Write-Output ($name+' | '+$status+' | '+$detail) }
function Install-Setup($file,$dir){
  if(-not (Test-Path -LiteralPath $file)){ throw ('setup missing: '+$file) }
  $line = '"'+$file+'" /S /D='+$dir
  $p = Start-Process cmd.exe -ArgumentList '/c',$line -PassThru -Wait -WindowStyle Hidden
  if($p.ExitCode -ne 0){ throw ('installer exit '+$p.ExitCode) }
  Start-Sleep -Seconds 2
  if(-not (Test-Path -LiteralPath (Join-Path $dir 'ams-launcher.exe'))){ throw 'launcher missing after install' }
  $v=(Get-Item (Join-Path $dir 'ams-launcher.exe')).VersionInfo.FileVersion
  return $v
}
if(Test-Path -LiteralPath $Target){ throw ('target exists: '+$Target) }
try {
  $v0=Install-Setup $OldSetup $Target
  Add-Step 'install-0.2.1' 'PASS' ('version='+$v0)
  $marker=Join-Path $Target 'data\H3_AUTO_KEEP.txt'
  [IO.File]::WriteAllText($marker,'keep',[Text.UTF8Encoding]::new($false))
  $v1=Install-Setup $Setup $Target
  Add-Step 'upgrade-rc' 'PASS' ('version='+$v1+' marker='+(Test-Path $marker))
  $v2=Install-Setup $OldSetup $Target
  Add-Step 'rollback-0.2.1' 'PASS' ('version='+$v2+' marker='+(Test-Path $marker))
  $u=Join-Path $Target 'AMS-Studio-Uninstall.exe'
  if(-not (Test-Path -LiteralPath $u)){ throw 'uninstaller missing' }
  $p=Start-Process $u -ArgumentList '/S' -PassThru -Wait -WindowStyle Hidden
  Add-Step 'uninstall' 'PASS' ('exit='+$p.ExitCode+' data='+(Test-Path (Join-Path $Target 'data'))+' marker='+(Test-Path $marker))
} catch {
  Add-Step 'installer' 'FAIL' $_.Exception.Message
  throw
}
$result=[pscustomobject]@{timestamp=$stamp;target=$Target;setup=$Setup;old_setup=$OldSetup;steps=$steps}
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
$md=@('# Installer H3 smoke '+$stamp+'','')
foreach($s in $steps){ $md += '- **'+$s.name+'**: '+$s.status+' - '+$s.detail }
$md|Set-Content -LiteralPath (Join-Path $out 'summary.md') -Encoding UTF8
Write-Output ('OUT='+$out)
