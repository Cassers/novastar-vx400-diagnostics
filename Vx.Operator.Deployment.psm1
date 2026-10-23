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
    return @('Control-VxUsuarios.ps1','Abrir-Control-Usuarios.bat','Watch-VxOperator.ps1','Vx.Operator.psm1','Play-VxOperatorMedia.ps1','Vx.Operator.Media.cs','Vx400.Schedule.psm1','Vx400.Protocol.psm1','Vx.Connection.psm1','Vx.Usb.psm1','Vx.Usb.Native.cs','Vx.Layers.psm1','Recover-VxOperatorUi.ps1','Recover-Vx400.ps1','Vx400.Ownership.psm1','Vx.Operator.Deployment.psm1','Install-VxUsuariosStartup.ps1')
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
