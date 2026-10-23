#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$OperatorConfigPath='', [string]$DataDirectory='', [switch]$SmokeTest, [string]$ScreenshotPath='', [switch]$Modal)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'Esta aplicación requiere Windows PowerShell 5.1 y Windows Forms.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Abra con Windows PowerShell -STA.'}
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path (Split-Path $ConfigPath -Parent) 'operator.config.json'}
if(-not $DataDirectory){$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
$ConfigPath=[IO.Path]::GetFullPath($ConfigPath);$OperatorConfigPath=[IO.Path]::GetFullPath($OperatorConfigPath);$DataDirectory=[IO.Path]::GetFullPath($DataDirectory)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'Vx.ProAccess.psm1')
$script:proAccessPath=Join-Path (Split-Path $ConfigPath -Parent) 'pro-access.json'
if(-not $SmokeTest){
    try{$null=Read-VxProAccessPolicy -Path $script:proAccessPath}catch{
        $null=[Windows.Forms.MessageBox]::Show('No se puede abrir Pro. Conserve o restaure pro-access.json de esta instalación. '+$_.Exception.Message,'Acceso Pro','OK','Error')
        return
    }
    if(-not (Request-VxProAccess -Path $script:proAccessPath)){return}
}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Connection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Ownership.psm1') -Force
# This entrypoint exposes only pure path/profile validators when dot-sourced.
. (Join-Path $PSScriptRoot 'Play-VxOperatorMedia.ps1') -OperatorConfigPath $OperatorConfigPath -DataDirectory $DataDirectory -SmokeTest:$SmokeTest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:fixture=''
if($SmokeTest){
    $script:fixture=Join-Path ([IO.Path]::GetTempPath()) ('vx-operator-config-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($script:fixture)
    $planSource=$ConfigPath;$ConfigPath=Join-Path $script:fixture 'plan.config.json';Copy-Item -LiteralPath $planSource -Destination $ConfigPath
    $profileSource=$OperatorConfigPath;$OperatorConfigPath=Join-Path $script:fixture 'operator.config.json'
    if([IO.File]::Exists($profileSource)){Copy-Item -LiteralPath $profileSource -Destination $OperatorConfigPath}
    $DataDirectory=Join-Path $script:fixture 'data'
}
$script:plan=Read-VxPlanConfig -Path $ConfigPath
$script:profile=if([IO.File]::Exists($OperatorConfigPath)){Read-VxOperatorConfig -Path $OperatorConfigPath}else{New-VxOperatorConfig}
$script:fields=@{}
function New-ConfigLabel([string]$Text){$c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.AutoSize=$true;$c.Margin=New-Object Windows.Forms.Padding(6,8,10,8);return ,$c}
function Add-ConfigRow($Table,[string]$Name,[string]$Label,$Control){$r=$Table.RowCount;$Table.RowCount++;$Table.Controls.Add((New-ConfigLabel $Label),0,$r);$Control.Dock='Top';$Control.Margin=New-Object Windows.Forms.Padding(6);$Table.Controls.Add($Control,1,$r);$script:fields[$Name]=$Control}
function New-ConfigPage([string]$Title){
    $p=New-Object Windows.Forms.TabPage;$p.Text=$Title;$p.AutoScroll=$true;$p.Padding=New-Object Windows.Forms.Padding(12)
    $t=New-Object Windows.Forms.TableLayoutPanel;$t.Dock='Top';$t.AutoSize=$true;$t.ColumnCount=2;$t.RowCount=0
    $null=$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,48)))
    $null=$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,52)))
    $p.Controls.Add($t);$null=$script:tabs.TabPages.Add($p);return ,$t
}
function Add-ConfigNumber($Table,[string]$Name,[string]$Label,[decimal]$Maximum,[int]$Decimals=3){$c=New-Object Windows.Forms.NumericUpDown;$c.Minimum=0;$c.Maximum=$Maximum;$c.DecimalPlaces=$Decimals;$c.Value=[decimal]$script:profile.$Name;Add-ConfigRow $Table $Name $Label $c}
function Add-ConfigText($Table,[string]$Name,[string]$Label){$c=New-Object Windows.Forms.TextBox;$c.Text=$script:profile.$Name;Add-ConfigRow $Table $Name $Label $c}
function Add-ConfigCheck($Table,[string]$Name,[string]$Label){$c=New-Object Windows.Forms.CheckBox;$c.Checked=$script:profile.$Name;$c.AutoSize=$true;Add-ConfigRow $Table $Name $Label $c}
function Get-EditedOperatorConfig {
    $candidate=New-VxOperatorConfig
    foreach($name in $script:fields.Keys){
        $control=$script:fields[$name]
        if($control -is [Windows.Forms.CheckBox]){$candidate.$name=[bool]$control.Checked}
        elseif($control -is [Windows.Forms.NumericUpDown]){$candidate.$name=[double]$control.Value}
        elseif($name -eq 'screenDeviceName'){$candidate.$name=if($control.SelectedIndex -ge 0){[string]$control.SelectedItem.device}else{''}}
        else{$candidate.$name=[string]$control.Text}
    }
    return $candidate
}
function Assert-OperatorScreen($Candidate){
    if(-not $Candidate.mediaEnabled){return}
    $screen=@([Windows.Forms.Screen]::AllScreens|Where-Object {$_.DeviceName -ceq $Candidate.screenDeviceName})
    if($screen.Count -ne 1){throw 'Seleccione una pantalla Windows conectada explícitamente.'}
    if($screen[0].Primary -and -not $Candidate.allowPrimaryScreen){throw 'La salida seleccionada es principal. Debe aceptar expresamente su uso.'}
}
function Save-OperatorConfiguration {
    if(-not $SmokeTest -and -not (Request-VxProAccess -Path $script:proAccessPath -Owner $script:form)){throw 'Acceso Pro cancelado.'}
    # Hold the same storage lock as every engine throughout validation and replacement.
    $candidate=Get-EditedOperatorConfig
    if(-not $candidate.configured){throw 'Marque la aceptación explícita antes de guardar.'}
    if($candidate.mediaEnabled){
        foreach($name in @('videoFile','blackImageFile')){$candidate.$name=Resolve-VxOperatorMediaPath -Config $candidate -File $candidate.$name}
    }
    Assert-VxOperatorConfig -Config $candidate -ForControl
    Assert-OperatorScreen $candidate
    $plan=Read-VxPlanConfig -Path $ConfigPath
    $null=[IO.Directory]::CreateDirectory($DataDirectory)
    $held=$null;$temporary=''
    try{
        try{$held=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Hay un motor activo o no se puede comprobar su bloqueo. Deténgalo desde Soporte antes de guardar.'}
        if(-not $SmokeTest){
            $owners=@(Find-VxControllers -Endpoint (Get-VxConnectionKey -Config $plan) -ExpectedPowerShell (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            if($owners.Count){throw 'Existe un motor para esta conexión. Solicite su parada antes de guardar.'}
        }
        $directory=Split-Path $OperatorConfigPath -Parent;$null=[IO.Directory]::CreateDirectory($directory)
        $temporary=Join-Path $directory ('.operator-'+[guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::WriteAllText($temporary,($candidate|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        $null=Read-VxOperatorConfig -Path $temporary -ForControl
        $null=Read-VxMediaProfile -Path $temporary
        Move-VxAtomicFile -Source $temporary -Destination $OperatorConfigPath
        $script:profile=Read-VxOperatorConfig -Path $OperatorConfigPath -ForControl
        $script:notice.Text='Perfil Usuarios guardado, validado y aceptado. Abra Usuarios para iniciar. El calendario avanzado permanece intacto.'
    }finally{if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)};if($null -ne $held){$held.Dispose()}}
}
$script:form=New-Object Windows.Forms.Form;$script:form.Text='Pro · Configurar Usuarios';$script:form.MinimumSize=New-Object Drawing.Size(900,650);$script:form.Size=New-Object Drawing.Size(1020,780);$script:form.StartPosition='CenterScreen';$script:form.Font=New-Object Drawing.Font('Segoe UI',10)
$root=New-Object Windows.Forms.TableLayoutPanel;$root.Dock='Fill';$root.ColumnCount=1;$root.RowCount=4;$root.Padding=New-Object Windows.Forms.Padding(16)
$null=$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,68)))
$null=$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
$null=$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,54)))
$null=$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,65)))
$script:form.Controls.Add($root)
$intro=New-ConfigLabel 'Perfil diario de Usuarios. La conexión y las verificaciones físicas se editan en Pro. Guardar requiere todos los motores detenidos. Valores provisionales: requieren revisión del responsable del panel.';$intro.Dock='Fill';$intro.AutoSize=$false;$root.Controls.Add($intro,0,0)
$script:tabs=New-Object Windows.Forms.TabControl;$script:tabs.Dock='Fill';$root.Controls.Add($script:tabs,0,1)
$t=New-ConfigPage 'Tiempos y niveles'
Add-ConfigText $t 'dailyStart' 'Inicio diario de mañana (HH:mm)'
Add-ConfigText $t 'dailyEnd' 'Fin diario de mañana (HH:mm)'
Add-ConfigNumber $t 'idlePercent' 'Nivel de reposo (%)' 100
Add-ConfigNumber $t 'preheatPercent' 'Tope de preparación (%)' 100
Add-ConfigNumber $t 'dryPercent' 'Tope de secado (%)' 100
Add-ConfigNumber $t 'dryRampMinutes' 'Subida de secado (minutos)' 10080
Add-ConfigNumber $t 'dryFallMinutes' 'Bajada de secado (minutos)' 10080
Add-ConfigNumber $t 'preheatMinutes' 'Preparación mínima completa (minutos)' 10080
Add-ConfigNumber $t 'cooldownMinutes' 'Enfriamiento al apagar (minutos)' 10080
$t=New-ConfigPage 'Multimedia y salida'
Add-ConfigCheck $t 'mediaEnabled' 'Habilitar salida multimedia en Windows'
Add-ConfigText $t 'mediaFolder' 'Carpeta de medios (ruta absoluta)'
Add-ConfigText $t 'videoFile' 'Vídeo en bucle para secado (ruta o archivo)'
Add-ConfigText $t 'blackImageFile' 'Imagen NEGRO para reposo (ruta o archivo)'
$screenSelect=New-Object Windows.Forms.ComboBox;$screenSelect.DropDownStyle='DropDownList';$screenSelect.DisplayMember='label'
foreach($screen in [Windows.Forms.Screen]::AllScreens){$i=$screenSelect.Items.Add([pscustomobject]@{device=$screen.DeviceName;label=('{0} · {1} × {2}{3}' -f $screen.DeviceName,$screen.Bounds.Width,$screen.Bounds.Height,$(if($screen.Primary){' · PRINCIPAL'}else{''}))});if($screen.DeviceName -ceq $script:profile.screenDeviceName){$screenSelect.SelectedIndex=$i}}
# No implicit selection: an absent configured output remains unselected.
Add-ConfigRow $t 'screenDeviceName' 'Salida Windows explícita' $screenSelect
Add-ConfigCheck $t 'allowPrimaryScreen' 'Acepto ocupar la pantalla principal si fue seleccionada'
$pick=New-Object Windows.Forms.FlowLayoutPanel;$pick.AutoSize=$true
foreach($entry in @(@('Carpeta…','mediaFolder'),@('Vídeo…','videoFile'),@('Imagen NEGRO…','blackImageFile'))){$b=New-Object Windows.Forms.Button;$b.Text=$entry[0];$b.AutoSize=$true;$b.Tag=$entry[1];$b.Add_Click({param($sender,$e)
    if($SmokeTest){$script:notice.Text='Selectores deshabilitados en SmokeTest.';return}
    $dialog=if($sender.Tag -eq 'mediaFolder'){New-Object Windows.Forms.FolderBrowserDialog}else{New-Object Windows.Forms.OpenFileDialog}
    try{if($dialog.ShowDialog() -eq 'OK'){$script:fields[$sender.Tag].Text=$(if($sender.Tag -eq 'mediaFolder'){$dialog.SelectedPath}else{$dialog.FileName})}}finally{$dialog.Dispose()}
});$pick.Controls.Add($b)}
$r=$t.RowCount;$t.RowCount++;$t.Controls.Add($pick,1,$r)
$t=New-ConfigPage 'SCALE y aceptación'
Add-ConfigNumber $t 'canvasWidth' 'Ancho de lienzo SCALE (píxeles; 0 = deshabilitado)' 32768 0
Add-ConfigNumber $t 'canvasHeight' 'Alto de lienzo SCALE (píxeles; 0 = deshabilitado)' 32768 0
$l=New-ConfigLabel 'SCALE ajusta la geometría de una única capa activa de menor prioridad al lienzo; requiere READY y prioridad inequívoca. No equivale a una dirección nativa SCALE. Esquema del perfil: 1.';$l.MaximumSize=New-Object Drawing.Size(820,0);$r=$t.RowCount;$t.RowCount++;$t.Controls.Add($l,0,$r);$t.SetColumnSpan($l,2)
Add-ConfigCheck $t 'configured' 'He revisado y acepto este perfil, sus medios y salida'

$t=New-ConfigPage 'Entrega e inicio'
$l=New-ConfigLabel ('Instalación configurada: '+(Split-Path $ConfigPath -Parent)+[Environment]::NewLine+'Usuarios comparte este perfil y plan-data. Exportar crea una copia completa nueva; los medios conservan sus rutas y deben existir en el PC de destino. Para editar una copia, abra Pro → Otra instalación Usuarios. El inicio de Usuarios se ejecuta al iniciar sesión, con Windows activo y sesión abierta. Desactive el inicio avanzado Pro para esta conexión antes de activar Usuarios.')
$l.MaximumSize=New-Object Drawing.Size(850,0);$r=$t.RowCount;$t.RowCount++;$t.Controls.Add($l,0,$r);$t.SetColumnSpan($l,2)
$deploymentButtons=New-Object Windows.Forms.FlowLayoutPanel;$deploymentButtons.AutoSize=$true;$deploymentButtons.Dock='Top'
foreach($entry in @(@('Exportar instalación…','export'),@('Activar al iniciar sesión','install'),@('Quitar inicio Usuarios','remove'))){
    $b=New-Object Windows.Forms.Button;$b.Text=$entry[0];$b.Tag=$entry[1];$b.AutoSize=$true;$b.Height=36
    $b.Add_Click({param($sender,$e)try{Start-OperatorDeployment ([string]$sender.Tag)}catch{$script:notice.Text=$_.Exception.Message}})
    $deploymentButtons.Controls.Add($b)
}
$r=$t.RowCount;$t.RowCount++;$t.Controls.Add($deploymentButtons,0,$r);$t.SetColumnSpan($deploymentButtons,2)
$script:deploymentProcess=$null;$script:deploymentOut='';$script:deploymentError=''
function Start-OperatorDeployment([string]$Action){
    if($SmokeTest){$script:notice.Text='Entrega e instalación deshabilitadas en SmokeTest.';return}
    if($null -ne $script:deploymentProcess){throw 'Espere el resultado de la operación actual.'}
    if($Action -ne 'remove'){Save-OperatorConfiguration}
    $target='';$entry='Install-VxUsuariosStartup.ps1'
    if($Action -eq 'export'){
        $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Cree o seleccione una carpeta nueva vacía para la instalación unificada.';$dialog.ShowNewFolderButton=$true
        try{if($dialog.ShowDialog() -ne 'OK'){return};$target=$dialog.SelectedPath}finally{$dialog.Dispose()}
        $entry='Export-VxUsuarios.ps1'
    }
    foreach($path in @($ConfigPath,$OperatorConfigPath,$DataDirectory,$target,$PSScriptRoot)){if($path.Contains('"')){throw 'Ruta no válida.'}}
    $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -OperatorConfigPath "{2}"' -f (Join-Path $PSScriptRoot $entry),$ConfigPath,$OperatorConfigPath
    if($Action -eq 'export'){$arguments+=' -Destination "'+$target+'"'}else{$arguments+=' -DataDirectory "'+$DataDirectory+'" -ApplicationDirectory "'+(Split-Path $ConfigPath -Parent)+'"';if($Action -eq 'remove'){$arguments+=' -Remove'}}
    $script:deploymentOut=Join-Path ([IO.Path]::GetTempPath()) ('vx-deploy-'+[guid]::NewGuid().ToString('N')+'.out')
    $script:deploymentError=$script:deploymentOut+'.err'
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:deploymentProcess=Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $script:deploymentOut -RedirectStandardError $script:deploymentError -PassThru
    $null=$script:deploymentProcess.Handle # Windows PowerShell 5.1 redirected-process ExitCode retention.
    foreach($button in $deploymentButtons.Controls){$button.Enabled=$false}
    $script:notice.Text='Operación en curso. Espere el resultado…'
}
$deploymentTimer=New-Object Windows.Forms.Timer;$deploymentTimer.Interval=500
$deploymentTimer.Add_Tick({
    if($null -eq $script:deploymentProcess -or -not $script:deploymentProcess.HasExited){return}
    try{
        $script:deploymentProcess.WaitForExit();$code=$script:deploymentProcess.ExitCode
        $message=if([IO.File]::Exists($script:deploymentOut)){[IO.File]::ReadAllText($script:deploymentOut)}else{''}
        if($code -ne 0){$message+=' '+[IO.File]::ReadAllText($script:deploymentError)}
        $script:notice.Text=$message.Trim()
    }catch{$script:notice.Text=$_.Exception.Message}finally{
        $script:deploymentProcess.Dispose();$script:deploymentProcess=$null
        foreach($button in $deploymentButtons.Controls){$button.Enabled=$true}
        foreach($path in @($script:deploymentOut,$script:deploymentError)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
    }
})
$deploymentTimer.Start()

$buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill'
$save=New-Object Windows.Forms.Button;$save.Text='Validar y guardar';$save.AutoSize=$true;$save.Height=36;$save.Add_Click({try{Save-OperatorConfiguration}catch{$script:notice.Text=$_.Exception.Message}});$buttons.Controls.Add($save)
$close=New-Object Windows.Forms.Button;$close.Text='Cerrar';$close.AutoSize=$true;$close.Add_Click({$script:form.Close()});$buttons.Controls.Add($close);$root.Controls.Add($buttons,0,2)
$script:notice=New-ConfigLabel 'No se inició ningún motor. La configuración de Usuarios se guarda por separado.';$script:notice.AutoSize=$false;$script:notice.Dock='Fill';$root.Controls.Add($script:notice,0,3)
function Invoke-ConfigSmoke {
    $planHash=(Get-FileHash -LiteralPath $ConfigPath).Hash
    $script:fields['mediaEnabled'].Checked=$false;$script:fields['configured'].Checked=$true
    $script:fields['preheatMinutes'].Value=241.125
    Save-OperatorConfiguration
    $saved=Read-VxOperatorConfig -Path $OperatorConfigPath -ForControl
    if($saved.preheatMinutes -ne 241.125){throw 'Smoke: duration roundtrip failed.'}
    if((Get-FileHash -LiteralPath $ConfigPath).Hash -ne $planHash){throw 'Smoke: advanced plan changed.'}
    $good=(Get-FileHash -LiteralPath $OperatorConfigPath).Hash
    $script:fields['dailyEnd'].Text='02:00';$rejected=$false
    try{Save-OperatorConfiguration}catch{$rejected=$true}
    if(-not $rejected -or (Get-FileHash -LiteralPath $OperatorConfigPath).Hash -ne $good){throw 'Smoke: invalid save changed profile.'}
    $script:fields['dailyEnd'].Text=$saved.dailyEnd
    $held=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$rejected=$false;try{Save-OperatorConfiguration}catch{$rejected=$true};if(-not $rejected){throw 'Smoke: active storage lock did not reject save.'}}finally{$held.Dispose()}
    $script:fields['configured'].Checked=$false;$rejected=$false;try{Save-OperatorConfiguration}catch{$rejected=$true};if(-not $rejected){throw 'Smoke: unaccepted save allowed.'}
    $script:fields['configured'].Checked=$true
    # Empty disposable files validate path policy only; no playback/codec success is claimed.
    $video=Join-Path $script:fixture 'fixture.mp4';$image=Join-Path $script:fixture 'fixture.png'
    [IO.File]::WriteAllBytes($video,[byte[]]@());[IO.File]::WriteAllBytes($image,[byte[]]@())
    $script:fields['mediaFolder'].Text=$script:fixture;$script:fields['videoFile'].Text='fixture.mp4';$script:fields['blackImageFile'].Text='fixture.png'
    $script:fields['mediaEnabled'].Checked=$true;$script:fields['allowPrimaryScreen'].Checked=$true
    $script:fields['screenDeviceName'].SelectedIndex=0
    Save-OperatorConfiguration
    $normalized=Read-VxMediaProfile -Path $OperatorConfigPath
    if($normalized.videoFile -cne $video -or $normalized.blackImageFile -cne $image){throw 'Smoke: relative media paths not normalized.'}
    $good=(Get-FileHash -LiteralPath $OperatorConfigPath).Hash
    [IO.File]::WriteAllBytes((Join-Path $script:fixture 'fixture.unsupported'),[byte[]]@())
    $script:fields['videoFile'].Text='fixture.unsupported';$rejected=$false;try{Save-OperatorConfiguration}catch{$rejected=$true}
    if(-not $rejected){throw 'Smoke: invalid media accepted.'}
    $script:fields['videoFile'].Text='fixture.mp4'
    if((Get-FileHash -LiteralPath $OperatorConfigPath).Hash -ne $good){throw 'Smoke: rejected save damaged profile.'}
    $script:notice.Text='Smoke: roundtrip, invalid save, acceptance, active lock and plan preservation PASS.'
    if($ScreenshotPath){$null=[IO.Directory]::CreateDirectory($ScreenshotPath);for($i=0;$i -lt $script:tabs.TabCount;$i++){$script:tabs.SelectedIndex=$i;[Windows.Forms.Application]::DoEvents();$bitmap=New-Object Drawing.Bitmap($script:form.Width,$script:form.Height);try{$script:form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save((Join-Path $ScreenshotPath ('config-{0}.png' -f $i)),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}}}
    Write-Output 'PASS Operator configurator smoke (temporary fixtures; no engine launched).'
}
try{
    if($SmokeTest){$script:form.Show();[Windows.Forms.Application]::DoEvents();Invoke-ConfigSmoke;$script:form.Close()}elseif($Modal){$null=$script:form.ShowDialog()}else{[Windows.Forms.Application]::Run($script:form)}
}finally{$deploymentTimer.Stop();$deploymentTimer.Dispose();if($null -ne $script:deploymentProcess){$script:deploymentProcess.Dispose()};$script:form.Dispose();if($script:fixture -and [IO.Directory]::Exists($script:fixture)){Remove-Item -LiteralPath $script:fixture -Recurse -Force}}
