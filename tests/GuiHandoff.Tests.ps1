#requires -Version 5.1
# No Forms, UAC or controllers: exercise the production mutex function in separate processes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Control-Vx400.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'GUI source parse error.'}
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-GuiMutex'},$true).Extent.Text
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('vx-gui-handoff-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temporary)
$GuiHandoff=$false;$script:ownsMutex=$false;$script:mutex=$null
. ([scriptblock]::Create($definition))
$exe=(Get-Process -Id $PID).Path
$child=$null
try{
    Set-GuiMutex $temporary
    foreach($mode in @('duplicate','handoff','timeout')){
        $result=Join-Path $temporary ($mode+'.txt');$ready=Join-Path $temporary ($mode+'.ready')
        $fixture=Join-Path $temporary ($mode+'.ps1')
        $code=@'
param([string]$Directory,[string]$Result,[string]$Ready,[bool]$Handoff)
$ErrorActionPreference='Stop'
$script:ownsMutex=$false;$script:mutex=$null;$GuiHandoff=$Handoff
'@ + "`n" + $definition + @'

[IO.File]::WriteAllText($Ready,'ready')
$clock=[Diagnostics.Stopwatch]::StartNew()
try{Set-GuiMutex $Directory;[IO.File]::WriteAllText($Result,('acquired|'+$clock.ElapsedMilliseconds))}
catch{[IO.File]::WriteAllText($Result,('rejected|'+$clock.ElapsedMilliseconds))}
finally{if($script:ownsMutex){$script:mutex.ReleaseMutex()};if($null -ne $script:mutex){$script:mutex.Dispose()}}
'@
        # Literal bool in generated invocation avoids Windows PowerShell -File boolean string conversion.
        $code=$code.Replace('[bool]$Handoff','[switch]$Handoff')
        [IO.File]::WriteAllText($fixture,$code,(New-Object Text.UTF8Encoding($true)))
        $arguments='-NoProfile -File "'+$fixture+'" -Directory "'+$temporary+'" -Result "'+$result+'" -Ready "'+$ready+'"'
        if($mode -ne 'duplicate'){$arguments+=' -Handoff'}
        $child=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not [IO.File]::Exists($ready)){if($child.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'Mutex child did not start.'};Start-Sleep -Milliseconds 25}
        if($mode -eq 'handoff'){
            Start-Sleep -Milliseconds 500
            if([IO.File]::Exists($result)){throw 'Successor failed or acquired while predecessor still owns lock.'}
            $script:mutex.ReleaseMutex();$script:ownsMutex=$false
        }
        if(-not $child.WaitForExit(20000)){throw 'Mutex child exceeded bounded wait.'}
        $parts=[IO.File]::ReadAllText($result).Split('|')
        if($mode -eq 'handoff'){
            if($parts[0] -ne 'acquired' -or [int]$parts[1] -lt 400){throw 'Successor did not acquire released mutex.'}
            Set-GuiMutex $temporary
        }elseif($mode -eq 'duplicate'){
            if($parts[0] -ne 'rejected' -or [int]$parts[1] -gt 4000){throw 'Regular duplicate did not fail promptly.'}
        }elseif($parts[0] -ne 'rejected' -or [int]$parts[1] -lt 14000 -or [int]$parts[1] -gt 19000){throw 'Handoff timeout was not bounded.'}
        $child.Dispose();$child=$null
    }
    Write-Output 'PASS: normal duplicate rejected; elevated-successor handoff waits and acquires; unreleased predecessor times out.'
}finally{
    if($null -ne $child){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    if($script:ownsMutex){$script:mutex.ReleaseMutex()};if($null -ne $script:mutex){$script:mutex.Dispose()}
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
