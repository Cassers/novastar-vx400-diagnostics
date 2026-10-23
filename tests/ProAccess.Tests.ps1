#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Vx.ProAccess.psm1') -Force
$module=Get-Module Vx.ProAccess
$script:passed=0
function Assert($value,$label){if(-not $value){throw "FAIL $label"};$script:passed++}
function Reject([scriptblock]$body,$label){$rejected=$false;try{& $body}catch{$rejected=$true};Assert $rejected $label}
function Secret([string]$text){return ConvertTo-SecureString $text -AsPlainText -Force}
function Clone($object){return $object|ConvertTo-Json|ConvertFrom-Json}
function Save($object,$file){[IO.File]::WriteAllText($file,($object|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
function QueueDialogs($items){& $module {param($entries) $script:dialogQueue=[Collections.Queue]::new();foreach($entry in $entries){$script:dialogQueue.Enqueue($entry)}} $items}
function DialogsConsumed {return (& $module {$script:dialogQueue.Count}) -eq 0}
& $module {
    function script:Read-VxProDialog {
        param($Mode,$ErrorText,$Owner)
        if($script:dialogQueue.Count -eq 0){throw 'Unexpected dialog.'}
        $entry=$script:dialogQueue.Dequeue()
        if($entry.mode -ne $Mode){throw "Unexpected dialog mode $Mode"}
        if($entry.cancel){return $null}
        $result=@{}
        foreach($key in @('CurrentPassword','NewPassword','ConfirmPassword')) {
            if($entry.ContainsKey($key)){$result[$key]=ConvertTo-SecureString $entry[$key] -AsPlainText -Force}
        }
        return $result
    }
}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('vx-pro-test-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($directory);$path=Join-Path $directory 'pro-access.json'
$password=Secret 'test-initial-secret-2026';$other=Secret 'test-replacement-secret-2026';$wrong=Secret 'test-wrong-secret-2026';$short=Secret 'short'
try {
    $policy=New-VxProAccessPolicy -Password $password -RequireChange
    Assert ($policy.requireChange -and $policy.iterations -eq 600000 -and $policy.kdf -ceq 'PBKDF2-SHA256') 'New strict policy'
    Assert ([Convert]::FromBase64String($policy.salt).Length -eq 32 -and [Convert]::FromBase64String($policy.hash).Length -eq 32) 'Random 32 byte salt and derived hash'
    $second=New-VxProAccessPolicy -Password $password
    Assert ($second.salt -cne $policy.salt -and $second.hash -cne $policy.hash) 'Fresh random salt per policy'
    Assert (Test-VxProPassword $policy $password) 'Correct secret'
    Assert (-not (Test-VxProPassword $policy $wrong)) 'Wrong secret'
    Reject {New-VxProAccessPolicy -Password $short} 'Short initial password rejected'
    $empty=New-Object Security.SecureString
    try {
        Reject {New-VxProAccessPolicy -Password $empty} 'Empty initial password rejected'
        Save $policy $path;$beforeEmpty=[IO.File]::ReadAllText($path)
        Reject {Set-VxProPassword $path $password $empty} 'Empty replacement rejected'
        Assert ([IO.File]::ReadAllText($path) -ceq $beforeEmpty) 'Empty replacement preserves policy'
    } finally {$empty.Dispose()}
    Remove-Item -LiteralPath $path
    $unicode=Secret ('contrase'+[char]0xf1+'a-'+[char]0x3b1+[char]0x3b2+[char]0x3b3+'-'+[char]0x4e2d+[char]0x6587+'-2026')
    try {$unicodePolicy=New-VxProAccessPolicy -Password $unicode;Assert (Test-VxProPassword $unicodePolicy $unicode) 'Unicode SecureString round trip'} finally {$unicode.Dispose()}
    $tooLong=Secret ('x'*1025);try{Reject {New-VxProAccessPolicy -Password $tooLong} 'Oversize secret rejected'}finally{$tooLong.Dispose()}
    # Known vector checks actual SHA256/UTF8 derivation, independent of generated policies.
    $salt=[Convert]::FromBase64String($policy.salt)
    $utf8=[Text.Encoding]::UTF8.GetBytes('test-initial-secret-2026')
    $reference=[Security.Cryptography.Rfc2898DeriveBytes]::new($utf8,$salt,600000,[Security.Cryptography.HashAlgorithmName]::SHA256)
    try{Assert ([Convert]::ToBase64String($reference.GetBytes(32)) -ceq $policy.hash) 'Explicit PBKDF2 SHA256 vector'}finally{$reference.Dispose();[Array]::Clear($utf8,0,$utf8.Length)}
    Reject {Read-VxProAccessPolicy $path} 'Missing policy closed'
    Assert (-not (Request-VxProAccess $path)) 'Missing policy never grants'
    foreach($raw in @('{','[]','null','{}','{"schemaVersion":1}')) {
        [IO.File]::WriteAllText($path,$raw)
        Reject {Read-VxProAccessPolicy $path} 'Malformed policy closed'
    }
    foreach($case in @(
        @('schemaVersion',2),@('schemaVersion','1'),@('schemaVersion',@(1)),@('kdf','PBKDF2-SHA1'),
        @('iterations',599999),@('iterations',600001),@('iterations',2147483647),@('iterations','600000'),
        @('salt','invalid'),@('salt',[Convert]::ToBase64String((New-Object byte[] 31))),
        @('hash','invalid'),@('hash',[Convert]::ToBase64String((New-Object byte[] 33))),@('hash',(' '+$policy.hash)),@('requireChange','false')
    )) {
        $invalid=Clone $policy;$invalid.($case[0])=$case[1];Save $invalid $path
        Reject {Read-VxProAccessPolicy $path} "Invalid $($case[0]) closed"
        Assert (-not (Test-VxProPassword $invalid $password)) 'Verifier rejects invalid policy'
        Assert (-not (Request-VxProAccess $path)) 'Invalid policy never grants'
    }
    $invalid=Clone $policy;$invalid|Add-Member NoteProperty bypass $true;Save $invalid $path
    Reject {Read-VxProAccessPolicy $path} 'Unknown field rejected'
    # Windows PowerShell 5.1 and PS7 format JSON whitespace differently.
    $schemaKey=[regex]::new('"schemaVersion"\s*:\s*1(?=\s*[,}])')
    $compact=$policy|ConvertTo-Json -Compress
    $spaced=$schemaKey.Replace($compact,'"schemaVersion" :  1',1)
    foreach($json in @(($policy|ConvertTo-Json),$compact,$spaced)) {
        $raw=$schemaKey.Replace($json,'"schemaVersion":1,"schemaVersion":1',1)
        Assert ([regex]::Matches($raw,'"schemaVersion"\s*:').Count -eq 2) 'Duplicate fixture contains exactly two schema keys'
        [IO.File]::WriteAllText($path,$raw);Reject {Read-VxProAccessPolicy $path} 'Duplicate key rejected'
    }
    Save $policy $path;$original=[IO.File]::ReadAllText($path)
    foreach($new in @($short,$password)) {Reject {Set-VxProPassword $path $password $new} 'Invalid replacement rejected';Assert ([IO.File]::ReadAllText($path) -ceq $original) 'Invalid replacement preserves policy'}
    Reject {Set-VxProPassword $path $wrong $other} 'Current secret required'
    Assert ([IO.File]::ReadAllText($path) -ceq $original) 'Wrong current preserves policy'
    QueueDialogs @(@{mode='Login';cancel=$true})
    Assert (-not (Request-VxProAccess $path)) 'Login cancel denies'
    QueueDialogs @(@{mode='Login';cancel=$false;CurrentPassword='test-wrong-secret-2026'},@{mode='Login';cancel=$true})
    Assert (-not (Request-VxProAccess $path)) 'Wrong login then cancel denies'
    Assert (DialogsConsumed) 'Wrong login retries'
    QueueDialogs @(@{mode='Login';cancel=$false;CurrentPassword='test-initial-secret-2026'},@{mode='Change';cancel=$true})
    Assert (-not (Request-VxProAccess $path)) 'Required initial change cannot cancel into Pro'
    Assert ([IO.File]::ReadAllText($path) -ceq $original) 'Canceled forced change preserves policy'
    QueueDialogs @(@{mode='Change';cancel=$false;CurrentPassword='test-initial-secret-2026';NewPassword='test-replacement-secret-2026';ConfirmPassword='test-wrong-secret-2026'},@{mode='Change';cancel=$true})
    Assert (-not (Request-VxProPasswordChange $path)) 'Mismatched confirmation cannot change'
    Assert ([IO.File]::ReadAllText($path) -ceq $original) 'Mismatch preserves policy'
    QueueDialogs @(@{mode='Login';cancel=$false;CurrentPassword='test-initial-secret-2026'},@{mode='Change';cancel=$false;CurrentPassword='test-initial-secret-2026';NewPassword='test-replacement-secret-2026';ConfirmPassword='test-replacement-secret-2026'})
    Assert (Request-VxProAccess $path) 'Initial login requires verified password change'
    Assert (DialogsConsumed) 'Forced change prompts consumed'
    $changed=Read-VxProAccessPolicy $path
    Assert (-not $changed.requireChange -and (Test-VxProPassword $changed $other) -and -not (Test-VxProPassword $changed $password)) 'New works and old invalidated'
    QueueDialogs @()
    Assert (Request-VxProAccess $path) 'Same process same fingerprint cached'
    $alternate=Join-Path $directory 'alternate.json';Save $changed $alternate
    QueueDialogs @(@{mode='Login';cancel=$true})
    Assert (-not (Request-VxProAccess $alternate)) 'Cache bound to policy path'
    [IO.File]::AppendAllText($path,"`n")
    QueueDialogs @(@{mode='Login';cancel=$true})
    Assert (-not (Request-VxProAccess $path)) 'Any policy content change invalidates cache'
    QueueDialogs @(@{mode='Login';cancel=$false;CurrentPassword='test-replacement-secret-2026'})
    Assert (Request-VxProAccess $path) 'Current password relogin grants'
    Set-VxProPassword $path $other $password
    QueueDialogs @(@{mode='Login';cancel=$true})
    Assert (-not (Request-VxProAccess $path)) 'Set password revokes process cache'
    Assert ((Get-Command -Module Vx.ProAccess).Count -eq 6) 'Only intended APIs exported; no grant setter'
    Assert (@(Get-ChildItem $directory -Filter '*.tmp').Count -eq 0) 'No leftover temp policy'
    Write-Host "PASS: $script:passed Pro access assertions"
} finally {
    foreach($secret in @($password,$other,$wrong,$short)){$secret.Dispose()}
    Remove-Item $directory -Recurse -Force
}
