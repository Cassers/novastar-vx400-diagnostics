#requires -Version 5.1
Set-StrictMode -Version Latest
$script:proGrants=@{}

function Assert-VxProPolicy {
    param($Policy)
    if ($null -eq $Policy -or $Policy -isnot [pscustomobject]) { throw 'Politica Pro invalida.' }
    $fields=@('schemaVersion','kdf','iterations','salt','hash','requireChange')
    $actual=@($Policy.PSObject.Properties.Name)
    if ($actual.Count -ne $fields.Count) { throw 'Campos de politica Pro invalidos.' }
    foreach($name in $fields){ if($actual -cnotcontains $name){ throw 'Campos de politica Pro invalidos.' } }
    if (($Policy.schemaVersion -isnot [int] -and $Policy.schemaVersion -isnot [long]) -or $Policy.schemaVersion -ne 1) { throw 'Version Pro no compatible.' }
    if ($Policy.kdf -isnot [string] -or $Policy.kdf -cne 'PBKDF2-SHA256') { throw 'KDF Pro no compatible.' }
    # Schema 1 has one cost: reject weak costs and attacker-controlled excessive work.
    if (($Policy.iterations -isnot [int] -and $Policy.iterations -isnot [long]) -or $Policy.iterations -ne 600000) { throw 'Costo Pro invalido.' }
    if ($Policy.requireChange -isnot [bool]) { throw 'Indicador Pro invalido.' }
    foreach($name in @('salt','hash')) {
        if($Policy.$name -isnot [string]){ throw 'Material Pro invalido.' }
        try { $bytes=[Convert]::FromBase64String($Policy.$name) } catch { throw 'Material Pro invalido.' }
        if($bytes.Length -ne 32 -or [Convert]::ToBase64String($bytes) -cne $Policy.$name){ throw 'Material Pro invalido.' }
    }
}

function Get-VxProDerivedBytes {
    param([Security.SecureString]$Password,[byte[]]$Salt,[int]$Iterations)
    $pointer=[IntPtr]::Zero;$chars=$null;$passwordBytes=$null;$derive=$null
    try {
        if($null -eq $Password -or $Password.Length -eq 0 -or $Password.Length -gt 1024){ throw 'La clave debe tener entre 12 y 1024 caracteres.' }
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        $chars=New-Object char[] $Password.Length
        [Runtime.InteropServices.Marshal]::Copy($pointer,$chars,0,$chars.Length)
        $passwordBytes=[Text.Encoding]::UTF8.GetBytes($chars)
        # Explicit SHA256 overload; the legacy constructor silently uses SHA1.
        $derive=[Security.Cryptography.Rfc2898DeriveBytes]::new($passwordBytes,$Salt,$Iterations,[Security.Cryptography.HashAlgorithmName]::SHA256)
        return ,$derive.GetBytes(32)
    } finally {
        if($null -ne $derive){$derive.Dispose()}
        if($null -ne $passwordBytes){[Array]::Clear($passwordBytes,0,$passwordBytes.Length)}
        if($null -ne $chars){[Array]::Clear($chars,0,$chars.Length)}
        if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)}
    }
}

function New-VxProAccessPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$Password,[switch]$RequireChange)
    if($Password.Length -lt 12 -or $Password.Length -gt 1024){throw 'La clave debe tener entre 12 y 1024 caracteres.'}
    $salt=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try {$rng.GetBytes($salt)} finally {$rng.Dispose()}
    $hash=Get-VxProDerivedBytes $Password $salt 600000
    try {
        return [pscustomobject][ordered]@{schemaVersion=1;kdf='PBKDF2-SHA256';iterations=600000;salt=[Convert]::ToBase64String($salt);hash=[Convert]::ToBase64String($hash);requireChange=[bool]$RequireChange}
    } finally {[Array]::Clear($hash,0,$hash.Length)}
}

function Get-VxProSnapshot {
    param([string]$Path)
    $canonical=[IO.Path]::GetFullPath($Path)
    if(-not [IO.File]::Exists($canonical)){throw 'Falta la politica Pro. Acceso bloqueado.'}
    $file=New-Object IO.FileInfo $canonical
    if($file.Length -gt 65536){throw 'Politica Pro demasiado grande.'}
    $raw=[IO.File]::ReadAllText($canonical,[Text.Encoding]::UTF8)
    $policy=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    Assert-VxProPolicy $policy
    # Reject duplicate keys (ConvertFrom-Json otherwise silently keeps the last).
    foreach($name in @('schemaVersion','kdf','iterations','salt','hash','requireChange')) {
        if([regex]::Matches($raw,('"'+$name+'"\s*:')).Count -ne 1){throw 'Campos de politica Pro duplicados o invalidos.'}
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$fingerprint=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw)))} finally {$sha.Dispose()}
    return [pscustomobject]@{path=$canonical;policy=$policy;fingerprint=$fingerprint}
}

function Read-VxProAccessPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-VxProSnapshot $Path).policy
}

function Test-VxProPassword {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy,[Parameter(Mandatory)][Security.SecureString]$Password)
    $actual=$null;$expected=$null
    try {
        Assert-VxProPolicy $Policy
        if($Password.Length -eq 0 -or $Password.Length -gt 1024){return $false}
        $expected=[Convert]::FromBase64String($Policy.hash)
        $actual=Get-VxProDerivedBytes $Password ([Convert]::FromBase64String($Policy.salt)) $Policy.iterations
        $difference=0
        for($i=0;$i -lt 32;$i++) {$difference=$difference -bor ($actual[$i] -bxor $expected[$i])}
        return ($difference -eq 0)
    } catch {return $false} finally {
        if($null -ne $actual){[Array]::Clear($actual,0,$actual.Length)}
        if($null -ne $expected){[Array]::Clear($expected,0,$expected.Length)}
    }
}

function Set-VxProPassword {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][Security.SecureString]$CurrentPassword,[Parameter(Mandatory)][Security.SecureString]$NewPassword)
    $canonical=[IO.Path]::GetFullPath($Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$lockId=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical.ToUpperInvariant())))).Replace('-','')} finally {$sha.Dispose()}
    $mutex=[Threading.Mutex]::new($false,('VxProPassword-'+$lockId));$locked=$false
    try {
    try {$locked=$mutex.WaitOne(10000)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked){throw 'La politica Pro esta ocupada.'}
    $snapshot=Get-VxProSnapshot $Path
    if(-not (Test-VxProPassword $snapshot.policy $CurrentPassword)){throw 'Clave actual incorrecta.'}
    if($NewPassword.Length -lt 12 -or $NewPassword.Length -gt 1024){throw 'La clave nueva debe tener entre 12 y 1024 caracteres.'}
    if(Test-VxProPassword $snapshot.policy $NewPassword){throw 'La clave nueva debe ser diferente.'}
    $policy=New-VxProAccessPolicy -Password $NewPassword
    $temp=$snapshot.path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($policy|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $current=Get-VxProSnapshot $snapshot.path
        if($current.fingerprint -cne $snapshot.fingerprint){throw 'La politica cambio; vuelva a intentar.'}
        [IO.File]::Replace($temp,$snapshot.path,[NullString]::Value)
        $script:proGrants.Remove($snapshot.path)
    } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Initialize-VxProForms {
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'El acceso Pro requiere Windows.'}
    if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'El acceso Pro requiere PowerShell -STA.'}
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function Read-VxProDialog {
    param([ValidateSet('Login','Change')][string]$Mode,[string]$ErrorText,$Owner)
    Initialize-VxProForms
    $form=New-Object Windows.Forms.Form
    $form.Name='VxProAccessDialog';$form.Text=if($Mode -eq 'Login'){'Acceso Pro'}else{'Cambiar clave Pro'}
    $form.ClientSize=New-Object Drawing.Size(440,310)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false
    $form.ShowInTaskbar=$false
    $fields=@('CurrentPassword');if($Mode -eq 'Change'){$fields+=@('NewPassword','ConfirmPassword')}
    $boxes=@{};$row=15
    foreach($name in $fields){
        $label=New-Object Windows.Forms.Label;$label.Location=New-Object Drawing.Point(15,$row);$label.AutoSize=$true
        $label.Text=switch($name){'CurrentPassword'{if($Mode -eq 'Login'){'Clave Pro'}else{'Clave actual'}}'NewPassword'{'Nueva clave (minimo 12 caracteres)'}'ConfirmPassword'{'Confirmar nueva clave'}}
        $form.Controls.Add($label)
        $box=New-Object Windows.Forms.TextBox;$box.Name=$name;$box.Location=New-Object Drawing.Point(15,($row+22));$box.Width=410
        $box.UseSystemPasswordChar=$true;$box.MaxLength=1024;$form.Controls.Add($box);$boxes[$name]=$box;$row+=63
    }
    $errorLabel=New-Object Windows.Forms.Label;$errorLabel.Name='ErrorText';$errorLabel.Text=$ErrorText
    $errorLabel.Location=New-Object Drawing.Point(15,($row+4));$errorLabel.Size=New-Object Drawing.Size(410,40);$errorLabel.ForeColor=[Drawing.Color]::DarkRed;$form.Controls.Add($errorLabel)
    $ok=New-Object Windows.Forms.Button;$ok.Name='Submit';$ok.Text=if($Mode -eq 'Login'){'Entrar'}else{'Guardar'}
    $ok.Location=New-Object Drawing.Point(235,265);$ok.DialogResult='OK';$form.Controls.Add($ok);$form.AcceptButton=$ok
    $cancel=New-Object Windows.Forms.Button;$cancel.Name='Cancel';$cancel.Text='Cancelar';$cancel.Location=New-Object Drawing.Point(330,265);$cancel.DialogResult='Cancel';$form.Controls.Add($cancel);$form.CancelButton=$cancel
    $result=$null
    try {
        $dialogResult=if($null -eq $Owner){$form.ShowDialog()}else{$form.ShowDialog($Owner)}
        if($dialogResult -eq [Windows.Forms.DialogResult]::OK){
            $result=@{}
            foreach($name in $fields){
                $secure=New-Object Security.SecureString
                foreach($character in $boxes[$name].Text.ToCharArray()){$secure.AppendChar($character)}
                $secure.MakeReadOnly();$result[$name]=$secure
            }
        }
        return $result
    } finally {
        foreach($box in $boxes.Values){$box.Clear()}
        $form.Dispose()
    }
}

function Clear-VxProDialogSecrets {
    param($Answer)
    if($null -ne $Answer){foreach($secret in $Answer.Values){if($secret -is [Security.SecureString]){$secret.Dispose()}}}
}

function Invoke-VxProPasswordChangeCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,$Owner,[switch]$Required)
    $errorText=if($Required){'Clave temporal: debe cambiarla antes de abrir Pro.'}else{''};$answer=$null
    try {
        $null=Read-VxProAccessPolicy $Path
        while($true){
            $answer=Read-VxProDialog -Mode Change -ErrorText $errorText -Owner $Owner
            if($null -eq $answer){return $null}
            try {
                # Compare confirmation through the same constant-time KDF verification.
                $confirmation=New-VxProAccessPolicy -Password $answer.NewPassword
                if(-not (Test-VxProPassword $confirmation $answer.ConfirmPassword)){throw 'La confirmacion no coincide.'}
                Set-VxProPassword -Path $Path -CurrentPassword $answer.CurrentPassword -NewPassword $answer.NewPassword
                $changed=Get-VxProSnapshot $Path
                if($changed.policy.requireChange -or -not (Test-VxProPassword $changed.policy $answer.NewPassword)){throw 'La politica cambio; vuelva a intentar.'}
                return $changed
            } catch {$errorText=$_.Exception.Message} finally {Clear-VxProDialogSecrets $answer;$answer=$null}
        }
    } catch {return $null} finally {Clear-VxProDialogSecrets $answer}
}

function Request-VxProPasswordChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,$Owner)
    return ($null -ne (Invoke-VxProPasswordChangeCore -Path $Path -Owner $Owner))
}

function Request-VxProAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,$Owner)
    $answer=$null;$errorText=''
    try {
        $snapshot=Get-VxProSnapshot $Path
        if(-not $snapshot.policy.requireChange -and $script:proGrants.ContainsKey($snapshot.path) -and $script:proGrants[$snapshot.path] -ceq $snapshot.fingerprint){return $true}
        $script:proGrants.Remove($snapshot.path)
        while($true){
            $answer=Read-VxProDialog -Mode Login -ErrorText $errorText -Owner $Owner
            if($null -eq $answer){return $false}
            # Re-read after the modal to avoid authenticating a policy replaced while it was open.
            $snapshot=Get-VxProSnapshot $Path
            $valid=Test-VxProPassword $snapshot.policy $answer.CurrentPassword
            Clear-VxProDialogSecrets $answer;$answer=$null
            if(-not $valid){$errorText='Clave incorrecta.';continue}
            if($snapshot.policy.requireChange){
                $updated=Invoke-VxProPasswordChangeCore -Path $Path -Owner $Owner -Required
                if($null -eq $updated){return $false}
                $snapshot=$updated
            }
            # Refuse a race after verification, before granting this fingerprint.
            $current=Get-VxProSnapshot $Path
            if($current.fingerprint -cne $snapshot.fingerprint){return $false}
            $script:proGrants[$snapshot.path]=$snapshot.fingerprint
            return $true
        }
    } catch {return $false} finally {Clear-VxProDialogSecrets $answer}
}

Export-ModuleMember -Function New-VxProAccessPolicy,Read-VxProAccessPolicy,Test-VxProPassword,Set-VxProPassword,Request-VxProAccess,Request-VxProPasswordChange
