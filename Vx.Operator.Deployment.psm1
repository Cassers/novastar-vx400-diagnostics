#requires -Version 5.1
Set-StrictMode -Version Latest
function Get-VxOperatorTaskName([string]$DataDirectory) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $key=[IO.Path]::GetFullPath($DataDirectory).TrimEnd('\','/').ToUpperInvariant()
        $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','').Substring(0,16)
        return 'NovaStar-Usuarios-'+$hash
    } finally {$sha.Dispose()}
}
function Get-VxUserPackageFiles {
    # Keep the historical API while deploying one complete Users + Pro runtime.
    # Config/profile/policy are deliberately copied separately from the selected installation.
    $files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {
        $_.Extension -in @('.ps1','.psm1','.cs','.bat') -or
        $_.Name -eq 'watcher.config.json' -or $_.Name -like 'appsettings*.json' -or
        $_.Name -like '*.runtimeconfig.json' -or $_.Name -like '*.deps.json'
    } | ForEach-Object {$_.Name})
    # Fail closed when assembling an incomplete checkout rather than omit the Pro gate.
    $files+=@('Control-Vx400.ps1','Control-VxUsuarios.ps1','Configurar-VxUsuarios.ps1','Vx.ProAccess.psm1','Export-VxUsuarios.ps1','Abrir-NovaStar.bat')
    return @($files | Sort-Object -Unique)
}
function Get-VxPrincipalSid([string]$UserId) {
    if($UserId -match '^S-1-\d+(?:-\d+)+$'){return $UserId}
    return (New-Object Security.Principal.NTAccount($UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Assert-VxDeploymentPath([string]$Path) {
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.Contains('"') -or $Path.Contains("`r") -or $Path.Contains("`n") -or $Path.StartsWith('\\')){throw 'Use una ruta local absoluta sin comillas.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($env:OS -eq 'Windows_NT' -and ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':'))){throw 'Ruta de dispositivo o flujo alternativo no permitida.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if(((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'No se admiten enlaces en la instalación.'}}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
    return $full
}
Export-ModuleMember -Function Get-VxOperatorTaskName,Get-VxUserPackageFiles,Assert-VxDeploymentPath,Get-VxPrincipalSid
