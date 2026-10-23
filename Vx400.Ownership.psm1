#requires -Version 5.1
Set-StrictMode -Version Latest
# Immutable SHA256 allowlist of genuine controller versions from this repository's
# history through 38cd715. Normalize only CRLF to LF (ZIP/git checkout compatibility).
$script:knownHashes=@{
    'Watch-VxOperator.ps1'=@()
    'Watch-Vx400Plan.ps1'=@('82424FDE0CC4876168C24AD87A6B13DDC0C60350583BC742879E67CB015245EB','A212C9025445C393EFA8BD433CB05C6CA446F7A389F1FC2FC42E9147EEC386C9','D43BE1033DD6DC0C733A1745163007B899FA98193CCD216183F7890783CD0062','F21B0250C2BC10C0C6B4135DC8185208A89006603A0602715CD1E08BCCED46B0')
    'Watch-Vx400.ps1'=@('250506E7CECC6E13395315E624016C19BC0F50327A80811A0B2FBF030230BAFB','C490789B36A49813687ECA9F27CD1D085CAC3CEB8F0FE7B417538F0A819B3131')
    'Set-Vx400Manual.ps1'=@('22F3D77A82FDE35F86B4B5F1168DEBF2004B8840BF710F061F664A26ADA85F13','F06C9D3BA39403E35D3E6F8C8DAE3B373AD16579FD9C11DBEDED4A16D82CAFF9')
}
function ConvertFrom-VxControllerCommandLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)
    # Deliberately accept a strict subset of CommandLineToArgvW: entire quoted
    # arguments or unquoted atoms, with no embedded/escaped quotes or line breaks.
    # Reject ambiguity instead of trying to repair a command before terminating it.
    $matches=[regex]::Matches($CommandLine,'"[^"\r\n]*"|[^\s"\r\n]+')
    $tokens=@();$offset=0
    foreach($match in $matches){
        $gap=$CommandLine.Substring($offset,$match.Index-$offset)
        if($gap -notmatch '\A[ \t]*\z' -or ($offset -gt 0 -and $gap.Length -eq 0)){throw 'Ambiguous command quoting or token separator.'}
        $token=$match.Value
        if($token.StartsWith('"')){
            $token=$token.Substring(1,$token.Length-2)
            if($token.EndsWith('\')){throw 'Ambiguous trailing backslash in quoted argument.'}
        }
        if(-not $token){throw 'Empty command argument.'}
        $tokens+=$token;$offset=$match.Index+$match.Length
    }
    if($CommandLine.Substring($offset) -notmatch '\A[ \t]*\z' -or $tokens.Count -lt 3){throw 'Malformed PowerShell command line.'}
    $allowedHosts=@('-nologo','-noprofile','-noninteractive','-sta','-mta')
    $index=1;$hostOptions=@{}
    while($index -lt $tokens.Count -and $tokens[$index] -ine '-File'){
        $key=$tokens[$index].ToLowerInvariant()
        if($hostOptions.ContainsKey($key)){throw 'Duplicate host option.'};$hostOptions[$key]=$true
        if($allowedHosts -contains $key){$index++;continue}
        if($key -eq '-executionpolicy'){
            $index++
            if($index -ge $tokens.Count -or $tokens[$index] -notin @('RemoteSigned','Bypass','Restricted','AllSigned','Unrestricted')){throw 'Unknown execution policy.'}
            $index++;continue
        }
        throw 'Unrecognized PowerShell host switch; only genuine -File invocations qualify.'
    }
    if($index -ge $tokens.Count-1){throw 'Missing -File script.'}
    $index++;$scriptPath=$tokens[$index];$index++
    $name=([regex]::Split($scriptPath,'[\\/]'))[-1]
    if($name -notin @('Watch-Vx400Plan.ps1','Watch-Vx400.ps1','Set-Vx400Manual.ps1','Watch-VxOperator.ps1')){throw 'Not an owned controller script.'}
    $switches=@{ 'Watch-VxOperator.ps1'=@('-enablecontrol');'Watch-Vx400Plan.ps1'=@('-enablecontrol','-manualdry');'Watch-Vx400.ps1'=@('-enablesequence');'Set-Vx400Manual.ps1'=@('-enablecontrol') }
    $values=@('-configpath','-datadirectory')
    if($name -eq 'Watch-VxOperator.ps1'){$values+='-operatorconfigpath'}
    if($name -ne 'Set-Vx400Manual.ps1'){$values+='-maxpolls'}else{$values+=@('-brightnesspercent','-display')}
    $parameters=@{}
    while($index -lt $tokens.Count){
        $key=$tokens[$index].ToLowerInvariant();$index++
        if($parameters.ContainsKey($key)){throw 'Duplicate controller argument.'}
        if($switches[$name] -contains $key){$parameters[$key]=$true;continue}
        if($values -notcontains $key -or $index -ge $tokens.Count){throw 'Unknown/missing controller argument.'}
        $value=$tokens[$index];$index++
        if($key -eq '-maxpolls' -and $value -notmatch '^\d{1,7}$'){throw 'Invalid MaxPolls.'}
        if($key -eq '-brightnesspercent' -and $value -notmatch '^(?:100(?:\.0+)?|[0-9]{1,2}(?:\.[0-9]+)?)$'){throw 'Invalid brightness argument.'}
        if($key -eq '-display' -and $value -notin @('Normal','Blackout','White')){throw 'Invalid display argument.'}
        $parameters[$key]=$value
    }
    return [pscustomobject]@{executable=$tokens[0];scriptPath=$scriptPath;scriptName=$name;parameters=$parameters}
}
function Resolve-VxOwnershipPath {
    param([Parameter(Mandatory)][string]$Path,[switch]$Directory,[switch]$AllowMissing)
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path -match '(^|[\\/])\.\.?([\\/]|$)' -or $Path.Contains('"')){throw 'An absolute local, unambiguous path is required.'}
    if($env:OS -eq 'Windows_NT' -and $Path -notmatch '^[A-Za-z]:[\\/]'){throw 'Drive-relative and root-relative paths are forbidden.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($env:OS -eq 'Windows_NT' -and ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':'))){throw 'Device/alternate-stream paths are forbidden.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if(((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse points are forbidden.'}}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
    if(-not $AllowMissing){
        $type=if($Directory){'Container'}else{'Leaf'}
        if(-not (Test-Path -LiteralPath $full -PathType $type)){throw "Required path missing: $full"}
    }
    if($Directory){
        if(-not [string]::IsNullOrWhiteSpace($env:SystemRoot) -and $full.StartsWith($env:SystemRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Windows system directories are unsafe data/script roots.'}
        if($full.TrimEnd('\','/') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')){throw 'Root directory is unsafe.'}
        foreach($special in @($env:SystemRoot,$env:ProgramFiles,$env:ProgramData,$env:USERPROFILE)){
            if(-not [string]::IsNullOrWhiteSpace($special) -and $full.TrimEnd('\','/') -ieq $special.TrimEnd('\','/')){throw 'Default system/profile root is unsafe.'}
        }
    }
    return $full.TrimEnd('\','/')
}
function Get-VxOwnershipHash([string]$Path){
    if((Get-Item -LiteralPath $Path).Length -gt 1048576){throw 'Ownership source exceeds the inspection limit.'}
    $raw=[IO.File]::ReadAllText($Path,(New-Object Text.UTF8Encoding($false,$true)))
    # ReadAllText consumes the UTF8 BOM; consistently remove it from the source allowlist below too.
    $bytes=[Text.Encoding]::UTF8.GetBytes($raw.Replace("`r`n","`n"))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
}
function Get-VxEndpointFromConfig([string]$Path){
    $real=Resolve-VxOwnershipPath $Path
    if((Get-Item -LiteralPath $real).Length -gt 262144){throw 'Config exceeds ownership inspection bound.'}
    $config=Get-Content -LiteralPath $real -Raw -Encoding UTF8|ConvertFrom-Json
    if($null -ne $config.PSObject.Properties['connectionType']){
        if($config.connectionType -isnot [string] -or $config.connectionType -cnotin @('Ethernet','USB')){throw 'Unknown controller connection type.'}
        if($config.connectionType -ceq 'USB'){return 'USB:LOCAL'}
    }
    $ip=$null
    if($config.deviceAddress -isnot [string] -or -not [Net.IPAddress]::TryParse($config.deviceAddress,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $config.deviceAddress -cne $ip.ToString() -or $ip.GetAddressBytes()[0] -eq 0 -or $ip.GetAddressBytes()[0] -ge 224){throw 'Config endpoint requires canonical unicast IPv4.'}
    if($config.tcpPort -isnot [int] -and $config.tcpPort -isnot [long]){throw 'Config port must be integer.'}
    if($config.tcpPort -lt 1 -or $config.tcpPort -gt 65535){throw 'Invalid config port.'}
    return $ip.ToString()+':'+$config.tcpPort
}
function Get-VxControllerIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProcessRecord,[Parameter(Mandatory)][string]$Endpoint,[Parameter(Mandatory)][string]$ExpectedPowerShell)
    $parsed=ConvertFrom-VxControllerCommandLine $ProcessRecord.CommandLine
    $exe=Resolve-VxOwnershipPath $ProcessRecord.ExecutablePath
    $commandExe=if($parsed.executable -ieq 'powershell.exe'){$exe}else{Resolve-VxOwnershipPath $parsed.executable}
    $expected=Resolve-VxOwnershipPath $ExpectedPowerShell
    if($exe -ine $expected -or $commandExe -ine $expected){throw 'Process executable is not the actual Windows PowerShell path.'}
    $path=Resolve-VxOwnershipPath $parsed.scriptPath
    $root=Resolve-VxOwnershipPath ([IO.Path]::GetDirectoryName($path)) -Directory
    $scriptHash=Get-VxOwnershipHash $path
    $trusted=@($script:knownHashes[$parsed.scriptName])
    $ownSource=Join-Path $PSScriptRoot $parsed.scriptName
    if(Test-Path -LiteralPath $ownSource -PathType Leaf){$null=Resolve-VxOwnershipPath $ownSource;$trusted+=Get-VxOwnershipHash $ownSource}
    if($trusted -notcontains $scriptHash){throw 'Script content is not a known genuine VX400 controller.'}
    $legacy=($parsed.scriptName -eq 'Watch-Vx400.ps1')
    $config=if($parsed.parameters.ContainsKey('-configpath')){[string]$parsed.parameters['-configpath']}else{Join-Path $root $(if($legacy){'watcher.config.json'}else{'plan.config.json'})}
    $data=if($parsed.parameters.ContainsKey('-datadirectory')){[string]$parsed.parameters['-datadirectory']}else{Join-Path $root $(if($legacy){'watcher-data'}else{'plan-data'})}
    $config=Resolve-VxOwnershipPath $config
    $data=Resolve-VxOwnershipPath $data -Directory
    if((Get-VxEndpointFromConfig $config) -cne $Endpoint){throw 'Different controller endpoint.'}
    if($null -eq $ProcessRecord.CreationDate){throw 'Process creation time unavailable.'}
    if([int]$ProcessRecord.ProcessId -gt 0 -and (Get-Item -LiteralPath $config).LastWriteTimeUtc -gt ([DateTime]$ProcessRecord.CreationDate).ToUniversalTime()){throw 'Controller config changed after startup; the running endpoint is unconfirmed. Inspect the original controller.'}
    $operatorProfile='';$operatorHash=''
    if($parsed.scriptName -ceq 'Watch-VxOperator.ps1'){
        $operatorProfile=if($parsed.parameters.ContainsKey('-operatorconfigpath')){[string]$parsed.parameters['-operatorconfigpath']}else{Join-Path $root 'operator.config.json'}
        $operatorProfile=Resolve-VxOwnershipPath $operatorProfile
        if([int]$ProcessRecord.ProcessId -gt 0 -and (Get-Item -LiteralPath $operatorProfile).LastWriteTimeUtc -gt ([DateTime]$ProcessRecord.CreationDate).ToUniversalTime()){throw 'Operator profile changed after startup; inspect and stop the original owner.'}
        $operatorHash=Get-VxOwnershipHash $operatorProfile
    }
    return [pscustomobject]@{processId=[int]$ProcessRecord.ProcessId;scriptPath=$path;configPath=$config;operatorConfigPath=$operatorProfile;operatorConfigHash=$operatorHash;dataDirectory=$data;creationTimeUtc=([DateTime]$ProcessRecord.CreationDate).ToUniversalTime().ToString('o');gracefulSupported=($parsed.scriptName -in @('Watch-Vx400Plan.ps1','Watch-VxOperator.ps1'));scriptHash=$scriptHash;configHash=(Get-VxOwnershipHash $config);commandLine=[string]$ProcessRecord.CommandLine;executablePath=$exe}
}
function Find-VxControllers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Endpoint,[Parameter(Mandatory)][string]$ExpectedPowerShell)
    $result=@()
    foreach($record in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop)){
        if($record.ProcessId -eq $PID -or [string]::IsNullOrWhiteSpace($record.CommandLine)){continue}
        try{$result+=Get-VxControllerIdentity -ProcessRecord $record -Endpoint $Endpoint -ExpectedPowerShell $ExpectedPowerShell}catch{
            if($_.Exception -is [UnauthorizedAccessException]){throw}
            # An unrelated or ambiguous invocation never qualifies for a stop or a kill.
        }
    }
    return $result
}
function Test-VxOwnedControllerTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Task,[Parameter(Mandatory)][string]$Endpoint,[Parameter(Mandatory)][string]$ExpectedPowerShell)
    try{
        if($Task.TaskPath -ceq '\' -and $Task.TaskName -cmatch '^NovaStar-Usuarios-[A-F0-9]{16}$'){return (Test-VxOwnedOperatorTask $Task $Endpoint $ExpectedPowerShell)}
        if($Task.TaskPath -cne '\' -or $Task.TaskName -notin @('NovaStar-VX400-Control','NovaStar-VX400-Watcher')){return $false}
        $actions=@($Task.Actions);if($actions.Count -ne 1){return $false}
        $root=Join-Path $env:ProgramFiles $Task.TaskName
        $data=Join-Path $env:ProgramData $Task.TaskName
        $name=if($Task.TaskName -eq 'NovaStar-VX400-Control'){'Watch-Vx400Plan.ps1'}else{'Watch-Vx400.ps1'}
        $config=if($Task.TaskName -eq 'NovaStar-VX400-Control'){'plan.config.json'}else{'watcher.config.json'}
        if($actions[0].WorkingDirectory -ine $root){return $false}
        $record=[pscustomobject]@{ProcessId=0;CreationDate=[DateTime]::UtcNow;ExecutablePath=$actions[0].Execute;CommandLine=('"'+$actions[0].Execute+'" '+$actions[0].Arguments)}
        $identity=Get-VxControllerIdentity $record $Endpoint $ExpectedPowerShell
        $parsed=ConvertFrom-VxControllerCommandLine $record.CommandLine
        if(-not $parsed.parameters.ContainsKey('-configpath') -or -not $parsed.parameters.ContainsKey('-datadirectory')){return $false}
        return ($identity.scriptPath -ieq (Join-Path $root $name) -and $identity.configPath -ieq (Join-Path $root $config) -and $identity.dataDirectory -ieq $data)
    }catch{return $false}
}

function Test-VxOwnedOperatorTask($Task,[string]$Endpoint,[string]$ExpectedPowerShell){
    try{
        $actions=@($Task.Actions)
        if($Task.TaskPath -cne '\' -or $Task.TaskName -cnotmatch '^NovaStar-Usuarios-[A-F0-9]{16}$' -or $actions.Count -ne 1 -or $Task.Principal.LogonType -ne 'Interactive'){return $false}
        $record=[pscustomobject]@{ProcessId=0;CreationDate=[DateTime]::UtcNow;ExecutablePath=$actions[0].Execute;CommandLine=('"'+$actions[0].Execute+'" '+$actions[0].Arguments)}
        $parsed=ConvertFrom-VxControllerCommandLine $record.CommandLine
        if($parsed.scriptName -cne 'Watch-VxOperator.ps1' -or -not $parsed.parameters.ContainsKey('-enablecontrol')){return $false}
        foreach($required in @('-configpath','-operatorconfigpath','-datadirectory')){if(-not $parsed.parameters.ContainsKey($required)){return $false}}
        $identity=Get-VxControllerIdentity $record $Endpoint $ExpectedPowerShell
        $operator=Resolve-VxOwnershipPath $parsed.parameters['-operatorconfigpath']
        $markerPath=Resolve-VxOwnershipPath (Join-Path $identity.dataDirectory 'operator-startup.json')
        if((Get-Item -LiteralPath $markerPath).Length -gt 32768){return $false}
        $marker=Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8|ConvertFrom-Json
        $principalSid=if([string]$Task.Principal.UserId -match '^S-1-\d+(?:-\d+)+$'){[string]$Task.Principal.UserId}else{(New-Object Security.Principal.NTAccount([string]$Task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value}
        if($marker.schemaVersion -ne 1 -or $marker.application -cne 'NovaStar-Usuarios' -or $marker.taskName -cne $Task.TaskName -or $marker.userSid -cne $principalSid){return $false}
        if($marker.configPath -ine $identity.configPath -or $marker.operatorConfigPath -ine $operator -or $marker.dataDirectory -ine $identity.dataDirectory){return $false}
        if($marker.scriptRoot -ine (Split-Path $identity.scriptPath -Parent) -or $actions[0].WorkingDirectory -ine $marker.scriptRoot){return $false}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$key=[IO.Path]::GetFullPath($identity.dataDirectory).TrimEnd('\','/').ToUpperInvariant();$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}
        return ($Task.TaskName -ceq ('NovaStar-Usuarios-'+$hash))
    }catch{return $false}
}

function Assert-VxControllerStillSame($Identity,$HeldProcess,[string]$Endpoint,[string]$ExpectedPowerShell){
    if($HeldProcess.HasExited){return $false}
    $record=Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = '+$Identity.processId) -ErrorAction Stop
    if($null -eq $record){return $false}
    $now=Get-VxControllerIdentity $record $Endpoint $ExpectedPowerShell
    foreach($field in @('creationTimeUtc','commandLine','scriptHash','configHash','executablePath','scriptPath','configPath','dataDirectory')){if($now.$field -cne $Identity.$field){throw 'Controller identity changed. Abort and scan again.'}}
    if($now.operatorConfigPath){foreach($field in @('operatorConfigPath','operatorConfigHash')){if($now.$field -cne $Identity.$field){throw 'Operator profile identity changed; scan again.'}}}
    if([Math]::Abs(($HeldProcess.StartTime.ToUniversalTime()-[DateTime]$record.CreationDate.ToUniversalTime()).TotalMilliseconds) -gt 2){throw 'PID creation time does not match held process.'}
    return $true
}
function Test-VxEndpointMutex([string]$Endpoint){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Endpoint))).Replace('-','')}finally{$sha.Dispose()}
    $mutex=$null;$owns=$false
    try{
        $mutex=New-Object Threading.Mutex($false,('Global\NovaStarVX400-'+$key))
        try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
        return $owns
    }finally{if($owns){$mutex.ReleaseMutex()};if($null -ne $mutex){$mutex.Dispose()}}
}
function Request-VxOwnershipStop([string]$DataDirectory){
    $data=Resolve-VxOwnershipPath $DataDirectory -Directory
    $stop=Join-Path $data 'stop.request'
    $null=Resolve-VxOwnershipPath $stop -AllowMissing
    # Never truncate an existing request/hardlink in another user's data folder.
    $stopStream=$null
    try{
        $stopStream=[IO.File]::Open($stop,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $bytes=[Text.Encoding]::UTF8.GetBytes('Explicit local ownership recovery '+[DateTimeOffset]::UtcNow.ToString('o'))
        $stopStream.Write($bytes,0,$bytes.Length)
    }catch [IO.IOException]{
        if(-not [IO.File]::Exists($stop)){throw}
        $null=Resolve-VxOwnershipPath $stop
    }finally{if($null -ne $stopStream){$stopStream.Dispose()}}
}
function Invoke-VxOwnershipRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$DataDirectory,[switch]$Force,[string]$ExpectedOwnersPath='')
    $result=[ordered]@{schemaVersion=1;endpoint='';success=$false;needsForce=$false;message='';controllers=@();pausedTasks=@();mutexAvailable=$false}
    $held=@()
    try{
        if($env:OS -ne 'Windows_NT'){throw 'Ownership recovery requires Windows PowerShell on the local PC.'}
        $endpoint=Get-VxEndpointFromConfig $ConfigPath;$result.endpoint=$endpoint
        $null=Resolve-VxOwnershipPath $DataDirectory -Directory -AllowMissing
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $controllers=@(Find-VxControllers -Endpoint $endpoint -ExpectedPowerShell $exe)
        $result.controllers=$controllers
        if($Force){
            if([string]::IsNullOrWhiteSpace($ExpectedOwnersPath)){throw 'Force requires ExpectedOwnersPath from the previously reviewed recovery result.'}
            $snapshotPath=Resolve-VxOwnershipPath $ExpectedOwnersPath
            if((Get-Item -LiteralPath $snapshotPath).Length -gt 1048576){throw 'Owner snapshot too large.'}
            $snapshot=Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8|ConvertFrom-Json
            if($snapshot.schemaVersion -ne 1 -or $snapshot.endpoint -cne $endpoint -or -not $snapshot.needsForce -or $snapshot.controllers -isnot [array]){throw 'Invalid reviewed owner snapshot.'}
            $same=$true
            foreach($identity in $controllers){
                $match=@($snapshot.controllers|Where-Object{$_.processId -eq $identity.processId})
                if($match.Count -ne 1){$same=$false;break}
                $fields=@('creationTimeUtc','commandLine','scriptHash','configHash','executablePath','scriptPath','configPath','dataDirectory')
                if($identity.operatorConfigPath){$fields+=@('operatorConfigPath','operatorConfigHash')}
                foreach($field in $fields){
                    if($field -eq 'creationTimeUtc'){$equal=([DateTime]$match[0].$field -eq [DateTime]$identity.$field)}else{$equal=($match[0].$field -ceq $identity.$field)}
                    if(-not $equal){$same=$false;break}
                }
            }
            if(-not $same){$result.needsForce=$true;$result.message='Los procesos cambiaron desde la revision. Revise los nuevos PID y rutas antes de elegir Forzar cierre otra vez.';return [pscustomobject]$result}
        }
        # Hold original OS process handles before acting. Requery identity immediately before each mutation.
        foreach($identity in $controllers){
            try{$process=[Diagnostics.Process]::GetProcessById($identity.processId);$null=$process.Handle}catch{throw 'Cannot open identified controller. Run the control panel as administrator.'}
            $held+=[pscustomobject]@{identity=$identity;process=$process}
            $null=Assert-VxControllerStillSame $identity $process $endpoint $exe
        }
        $taskNames=@('NovaStar-VX400-Control','NovaStar-VX400-Watcher')
        $taskNames+=@(Get-ScheduledTask -TaskName 'NovaStar-Usuarios-*' -TaskPath '\' -ErrorAction SilentlyContinue | ForEach-Object {$_.TaskName})
        foreach($name in @($taskNames|Select-Object -Unique)){
            $task=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
            if($null -ne $task -and (Test-VxOwnedControllerTask $task $endpoint $exe)){
                $fresh=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop
                if(-not (Test-VxOwnedControllerTask $fresh $endpoint $exe) -or ($fresh.Actions|ConvertTo-Json -Compress) -cne ($task.Actions|ConvertTo-Json -Compress)){throw 'Task changed; abort and scan again.'}
                Disable-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop|Out-Null
                $result.pausedTasks+= $name
            }
        }
        foreach($item in $held){
            if(Assert-VxControllerStillSame $item.identity $item.process $endpoint $exe){
                if($item.identity.gracefulSupported){
                    Request-VxOwnershipStop $item.identity.dataDirectory
                }
            }
        }
        $wait=[Diagnostics.Stopwatch]::StartNew()
        do{
            $remaining=@($held|Where-Object{-not $_.process.HasExited})
            if($remaining.Count -eq 0 -or $wait.Elapsed.TotalSeconds -ge 10){break}
            Start-Sleep -Milliseconds 200
        }while($true)
        if($remaining.Count -gt 0 -and -not $Force){
            $result.needsForce=$true;$result.message='Quedan motores locales activos. Revise sus PID y rutas antes de elegir Forzar cierre. La salida anterior puede permanecer visible.'
            return [pscustomobject]$result
        }
        if($remaining.Count -gt 0){
            if(-not ('Vx400OwnershipNative' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Vx400OwnershipNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateProcess(IntPtr processHandle, uint exitCode);
}
'@}
            foreach($item in $remaining){
                if(Assert-VxControllerStillSame $item.identity $item.process $endpoint $exe){
                    if(-not [Vx400OwnershipNative]::TerminateProcess($item.process.Handle,2)){throw 'Termination failed. Run as administrator and scan again.'}
                    if(-not $item.process.WaitForExit(3000)){throw 'Verified controller did not exit after termination.'}
                }
            }
        }
        $new=@(Find-VxControllers -Endpoint $endpoint -ExpectedPowerShell $exe)
        if($new.Count -gt 0){$result.controllers=$new;throw 'Another verified local controller appeared; scan again. No newly discovered process was terminated.'}
        $result.mutexAvailable=Test-VxEndpointMutex $endpoint
        if(-not $result.mutexAvailable){throw 'Endpoint mutex remains owned by an unidentified controller. No unknown process will be stopped.'}
        $result.success=$true;$result.message='Motores locales detenidos y bloqueo disponible. El inicio automatico queda pausado. La salida no esta confirmada: elija Mostrar negro antes de continuar. No se detectan clientes de otros computadores.'
    }catch{
        $result.success=$false;$result.needsForce=$false
        $result.message=$_.Exception.Message
        if($_.Exception -is [UnauthorizedAccessException] -or $result.message -match '(?i)access.*denied|acceso.*denegado|unauthorized'){$result.message+=' Abra el panel como administrador para acceder al bloqueo de Windows.'}
    }finally{foreach($item in $held){$item.process.Dispose()}}
    return [pscustomobject]$result
}
Export-ModuleMember -Function ConvertFrom-VxControllerCommandLine,Get-VxControllerIdentity,Find-VxControllers,Test-VxOwnedControllerTask,Invoke-VxOwnershipRecovery
