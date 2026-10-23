#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$OperatorConfigPath='', [string]$DataDirectory='', [switch]$NoAutoStart, [switch]$SmokeTest, [string]$ScreenshotPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'Usuarios requiere Windows PowerShell 5.1 y Windows Forms.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Abra Usuarios con Windows PowerShell -STA.'}
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path (Split-Path $ConfigPath -Parent) 'operator.config.json'}
if(-not $DataDirectory){$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
$ConfigPath=[IO.Path]::GetFullPath($ConfigPath);$OperatorConfigPath=[IO.Path]::GetFullPath($OperatorConfigPath);$DataDirectory=[IO.Path]::GetFullPath($DataDirectory)
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Connection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Ownership.psm1') -Force
. (Join-Path $PSScriptRoot 'Play-VxOperatorMedia.ps1') -OperatorConfigPath $OperatorConfigPath -DataDirectory $DataDirectory -SmokeTest:$SmokeTest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:fixture=''
if($SmokeTest){
    $script:fixture=Join-Path ([IO.Path]::GetTempPath()) ('vx-operator-ui-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($script:fixture)
    $planSource=$ConfigPath;$ConfigPath=Join-Path $script:fixture 'plan.config.json';Copy-Item -LiteralPath $planSource -Destination $ConfigPath
    $profileSource=$OperatorConfigPath;$OperatorConfigPath=Join-Path $script:fixture 'operator.config.json';Copy-Item -LiteralPath $profileSource -Destination $OperatorConfigPath
    $DataDirectory=Join-Path $script:fixture 'data';$null=[IO.Directory]::CreateDirectory($DataDirectory)
}
$script:state=$null;$script:pendingId='';$script:pendingSession='';$script:recoveryProcess=$null;$script:recoveryOutput='';$script:recoverySnapshot='';$script:needsForce=$false;$script:motorProcess=$null;$script:tickBusy=$false
$script:plan=$null;$script:profile=$null;$script:configurationIssue=''
try{$script:plan=Read-VxPlanConfig -Path $ConfigPath;$script:profile=Read-VxOperatorConfig -Path $OperatorConfigPath}catch{$script:configurationIssue=$_.Exception.Message}
function Get-UiProperty($Object,[string]$Name,$Default=''){if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default}
function Open-UiPro {
    if($SmokeTest){throw 'Pro no se abre durante SmokeTest.'}
    $proScript=Join-Path $PSScriptRoot 'Control-Vx400.ps1'
    if(-not [IO.File]::Exists($proScript)){throw 'Extraiga el paquete unificado completo para abrir Pro.'}
    $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File '+(Quote-UiArgument $proScript)+' -ConfigPath '+(Quote-UiArgument $ConfigPath)+' -DataDirectory '+(Quote-UiArgument $DataDirectory)
    $null=Start-Process -FilePath (Get-UiPowerShell) -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
    $script:notice.Text='Acceso Pro abierto: introduzca la clave en su ventana. El motor conserva su estado.'
}
function Get-UiPowerShell {return Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'}
function Quote-UiArgument([string]$Value){if($Value.Contains('"')){throw 'Ruta no válida: contiene comillas.'};return '"'+$Value+'"'}
function Read-UiJson([string]$Name){$path=Join-Path $DataDirectory $Name;if(-not [IO.File]::Exists($path)){return $null};if((Get-Item -LiteralPath $path).Length -gt 65536){throw 'Archivo de estado demasiado grande.'};return (Read-VxSharedText -Path $path|ConvertFrom-Json)}
function Write-UiJson([string]$Name,$Value){$path=Join-Path $DataDirectory $Name;$tmp=Join-Path $DataDirectory ('.ui-'+[guid]::NewGuid().ToString('N')+'.tmp');try{[IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)));Move-VxAtomicFile -Source $tmp -Destination $path}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}}
function Test-UiOwnerContext($Identity){
    # Get-VxControllerIdentity already resolves the genuine engine's explicit/default
    # operator profile. Attach only when every displayed configuration matches it.
    try{
        return ([IO.Path]::GetFullPath($Identity.scriptPath) -ieq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Watch-VxOperator.ps1')) -and
            $Identity.configPath -ieq $ConfigPath -and $Identity.dataDirectory -ieq $DataDirectory -and
            $Identity.operatorConfigPath -ieq $OperatorConfigPath)
    }catch{return $false}
}
function Test-UiOwner($State){
    if($SmokeTest){return ([int](Get-UiProperty $State ownerProcessId 0) -eq $PID)}
    try{
        $ownerId=[int](Get-UiProperty $State ownerProcessId 0);if($ownerId -le 0){return $false}
        $record=Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = '+$ownerId) -ErrorAction Stop
        if($null -eq $record){return $false}
        $plan=Read-VxPlanConfig -Path $ConfigPath
        $identity=Get-VxControllerIdentity -ProcessRecord $record -Endpoint (Get-VxConnectionKey -Config $plan) -ExpectedPowerShell (Get-UiPowerShell)
        if(-not (Test-UiOwnerContext $identity)){return $false}
        return ([DateTimeOffset](Get-UiProperty $State updatedUtc) -ge [DateTimeOffset]$identity.creationTimeUtc)
    }catch{return $false}
}
function Test-UiFreshState($State){
    if($null -eq $State -or (Get-UiProperty $State schemaVersion 0) -ne 1){return $false}
    if((Get-UiProperty $State schemaVersion) -is [string] -or (Get-UiProperty $State schemaVersion) -is [bool]){return $false}
    if((Get-UiProperty $State state) -cnotin @('BLACK','DRY','PREHEAT','READY','COOLDOWN','FAULT','STOPPED','WAIT_OPERATOR')){return $false}
    foreach($name in @('preheatReady','operatorPending')){if((Get-UiProperty $State $name $null) -isnot [bool]){return $false}}
    if([string](Get-UiProperty $State updatedUtc) -notmatch '(Z|[+-]\d{2}:\d{2})$'){return $false}
    $stamp=[DateTimeOffset]::MinValue;$session=[guid]::Empty
    if(-not [DateTimeOffset]::TryParse([string](Get-UiProperty $State updatedUtc),[ref]$stamp)){return $false}
    $age=([DateTimeOffset]::UtcNow-$stamp).TotalSeconds
    if($age -gt 10 -or $age -lt -2){return $false}
    if(-not [guid]::TryParseExact([string](Get-UiProperty $State sessionId),'D',[ref]$session) -or $session -eq [guid]::Empty){return $false}
    if((Get-UiProperty $State communication) -cne 'reachable'){return $false}
    return (Test-UiOwner $State)
}
function Test-UiPending($State){
    if($script:pendingId){
        if((Get-UiProperty $State sessionId) -cne $script:pendingSession){$script:pendingId='';$script:pendingSession=''}
        elseif((Get-UiProperty $State lastCommandId) -ceq $script:pendingId){$script:pendingId='';$script:pendingSession=''}
        else{return $true}
    }
    try{
        $command=Read-UiJson 'operator-command.json'
        if($null -ne $command -and (Get-UiProperty $command sessionId) -ceq (Get-UiProperty $State sessionId) -and (Get-UiProperty $command id) -cne (Get-UiProperty $State lastCommandId)){
            # Only a matching owner acknowledgement or a new session releases this gate.
            # The engine rejects stale commands; the UI never replaces an unacknowledged one.
            return $true
        }
    }catch{return $true}
    return $false
}
function Test-UiAction($State,[string]$Action){
    if(-not (Test-UiFreshState $State) -or (Test-UiPending $State) -or $null -ne $script:recoveryProcess){return $false}
    $mode=[string](Get-UiProperty $State state)
    if($Action -eq 'preheat'){return ($mode -cin @('BLACK','WAIT_OPERATOR'))}
    if($Action -eq 'shutdown'){return ($mode -cin @('BLACK','DRY','PREHEAT','READY','WAIT_OPERATOR'))}
    if($Action -cin @('layer','scale')){return ($mode -ceq 'READY' -and (Get-UiProperty $State preheatReady $false) -eq $true -and (Get-UiProperty $State operatorPending $true) -eq $false -and $null -ne $script:plan -and $script:plan.deviceModel -ceq 'VX600')}
    return $false
}
function Send-UiCommand([ValidateSet('preheat','shutdown','layer','scale')][string]$Action,[string]$Layer='', [bool]$Enabled=$false){
    # Serialize GUI submissions, then re-read the owner state inside the lock.
    $gate=$null
    try{
        if(-not [IO.Directory]::Exists($DataDirectory)){throw 'No hay motor conectado.'}
        $gate=[IO.File]::Open((Join-Path $DataDirectory 'operator-command.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $state=Read-UiJson 'operator-state.json'
        if(-not (Test-UiAction $state $Action)){throw 'Orden bloqueada: espere estado reciente, modo permitido y confirmación de la orden pendiente.'}
        $command=[ordered]@{schemaVersion=1;id=[guid]::NewGuid().ToString();sessionId=[string]$state.sessionId;utc=[DateTimeOffset]::UtcNow.ToString('o');action=$Action}
        if($Action -eq 'layer'){$command['layer']=$Layer;$command['enabled']=$Enabled}
        Assert-VxOperatorCommand -Command ([pscustomobject]$command) -SessionId $state.sessionId
        Write-UiJson 'operator-command.json' $command
        $script:pendingId=$command.id;$script:pendingSession=$command.sessionId
        $script:notice.Text='Orden enviada. Espere la confirmación del motor; el estado refleja ACK, no una medición física.'
    }finally{if($null -ne $gate){$gate.Dispose()}}
    Update-OperatorUi
}
function Assert-UiStartProfile {
    $script:plan=Read-VxPlanConfig -Path $ConfigPath -EnableControl
    $script:profile=Read-VxOperatorConfig -Path $OperatorConfigPath -ForControl
    $null=Read-VxMediaProfile -Path $OperatorConfigPath
    if($script:profile.mediaEnabled){
        $screens=@([Windows.Forms.Screen]::AllScreens|Where-Object {$_.DeviceName -ceq $script:profile.screenDeviceName})
        if($screens.Count -ne 1){throw 'La salida multimedia configurada en Pro no está conectada.'}
        if($screens[0].Primary -and -not $script:profile.allowPrimaryScreen){throw 'Pro no ha aceptado usar la pantalla principal.'}
    }
    foreach($name in @('Watch-VxOperator.ps1','Play-VxOperatorMedia.ps1')){if(-not [IO.File]::Exists((Join-Path $PSScriptRoot $name))){throw ('Falta '+$name+'. Extraiga el paquete completo.')}}
}
function Start-UiEngine {
    if($SmokeTest){throw 'Inicio del motor deshabilitado en SmokeTest.'}
    Assert-UiStartProfile
    $null=[IO.Directory]::CreateDirectory($DataDirectory)
    $held=$null
    try{$held=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{$script:notice.Text='Ya hay un motor o un bloqueo activo. Usuarios se conectará al propietario; use Soporte si necesita detenerlo.';return}finally{if($null -ne $held){$held.Dispose()}}
    $owners=@(Find-VxControllers -Endpoint (Get-VxConnectionKey -Config $script:plan) -ExpectedPowerShell (Get-UiPowerShell))
    if($owners.Count){$script:notice.Text='Existe un motor para esta conexión. No se inició otro; use Soporte para solicitar su parada.';return}
    $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File '+(Quote-UiArgument (Join-Path $PSScriptRoot 'Watch-VxOperator.ps1'))+' -ConfigPath '+(Quote-UiArgument $ConfigPath)+' -OperatorConfigPath '+(Quote-UiArgument $OperatorConfigPath)+' -DataDirectory '+(Quote-UiArgument $DataDirectory)+' -EnableControl'
    $script:motorProcess=Start-Process -FilePath (Get-UiPowerShell) -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru
    $script:notice.Text='Motor iniciado en proceso independiente. Espere conexión e identidad confirmadas.'
}
function Start-UiRecovery([bool]$Force=$false){
    if($SmokeTest){throw 'Recuperación deshabilitada en SmokeTest.'}
    if($null -ne $script:recoveryProcess){throw 'Espere la recuperación actual.'}
    if($Force -and (-not $script:needsForce -or -not [IO.File]::Exists($script:recoverySnapshot))){throw 'Revise primero la lista de propietarios detectados.'}
    if($Force){$answer=[Windows.Forms.MessageBox]::Show(('Se cerrarán solo los propietarios identificados en la lista revisada. Se interrumpirá cualquier preparación activa. ¿Continuar?'+[Environment]::NewLine+$script:recoveryDetail.Text),'Confirmar parada de propietarios','YesNo','Warning');if($answer -ne 'Yes'){return}}
    $worker=Join-Path $PSScriptRoot 'Recover-VxOperatorUi.ps1';if(-not [IO.File]::Exists($worker)){throw 'Falta el componente Soporte. Extraiga el paquete completo.'}
    $script:recoveryOutput=Join-Path ([IO.Path]::GetTempPath()) ('vx-user-recovery-'+[guid]::NewGuid().ToString('N')+'.json')
    $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File '+(Quote-UiArgument $worker)+' -ConfigPath '+(Quote-UiArgument $ConfigPath)+' -DataDirectory '+(Quote-UiArgument $DataDirectory)+' -OutputPath '+(Quote-UiArgument $script:recoveryOutput)
    if($Force){$arguments+=' -Force -ExpectedOwnersPath '+(Quote-UiArgument $script:recoverySnapshot)}
    $script:needsForce=$false;$script:forceRecovery.Enabled=$false
    $script:recoveryProcess=Start-Process -FilePath (Get-UiPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $script:recoveryDetail.Text='Solicitando parada propia y comprobando propietarios. Espere; Windows puede pedir permisos.'
    $script:notice.Text='Soporte en curso. No se reanuda ninguna secuencia automáticamente.'
}
function Update-UiRecovery {
    if($null -eq $script:recoveryProcess -or -not $script:recoveryProcess.HasExited){return}
    $script:recoveryProcess.Dispose();$script:recoveryProcess=$null
    try{
        if(-not [IO.File]::Exists($script:recoveryOutput)){throw 'El recuperador no confirmó un resultado. Revise permisos y vuelva a solicitar parada.'}
        $result=Read-VxSharedText -Path $script:recoveryOutput|ConvertFrom-Json
        $rows=New-Object 'Collections.Generic.List[string]';$rows.Add([string](Get-UiProperty $result message 'Sin confirmación.'))
        foreach($owner in @(Get-UiProperty $result controllers @())){$rows.Add(('PID {0} | {1} | Datos: {2}' -f (Get-UiProperty $owner processId),(Get-UiProperty $owner scriptPath),(Get-UiProperty $owner dataDirectory)))}
        if($script:recoverySnapshot -and [IO.File]::Exists($script:recoverySnapshot)){[IO.File]::Delete($script:recoverySnapshot)}
        $script:recoverySnapshot='';$script:needsForce=((Get-UiProperty $result needsForce $false) -eq $true)
        if($script:needsForce){$script:recoverySnapshot=$script:recoveryOutput;$rows.Add('Revise estos propietarios antes de usar Forzar cierre revisado.')}else{[IO.File]::Delete($script:recoveryOutput)}
        $script:recoveryDetail.Text=$rows -join [Environment]::NewLine
        $script:notice.Text='Soporte finalizado. Para volver a operar, cierre y abra Usuarios; PREHEAT siempre inicia una preparación completa.'
    }catch{$script:recoveryDetail.Text=$_.Exception.Message;$script:needsForce=$false}
    $script:forceRecovery.Enabled=$script:needsForce
}
function New-UiLabel([string]$Text,[int]$Size=11){$c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.AutoSize=$true;$c.Font=New-Object Drawing.Font('Segoe UI',[single]$Size);$c.Margin=New-Object Windows.Forms.Padding(4,7,10,7);return ,$c}
function New-UiButton([string]$Text,[scriptblock]$Action){$c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.AutoSize=$true;$c.MinimumSize=New-Object Drawing.Size(150,40);$c.Margin=New-Object Windows.Forms.Padding(5);if($null -ne $Action){$c.Add_Click({param($sender,$e)try{& $sender.Tag}catch{$script:notice.Text=$_.Exception.Message}})};$c.Tag=$Action;return ,$c}
function New-UiFlow{$c=New-Object Windows.Forms.FlowLayoutPanel;$c.AutoSize=$true;$c.WrapContents=$true;$c.Dock='Top';return ,$c}
$script:form=New-Object Windows.Forms.Form;$script:form.Text='NovaStar · Usuarios';$script:form.MinimumSize=New-Object Drawing.Size(900,650);$script:form.Size=New-Object Drawing.Size(1020,800);$script:form.StartPosition='CenterScreen';$script:form.Font=New-Object Drawing.Font('Segoe UI',10)
$scroll=New-Object Windows.Forms.Panel;$scroll.Dock='Fill';$scroll.AutoScroll=$true;$scroll.Padding=New-Object Windows.Forms.Padding(18);$script:form.Controls.Add($scroll)
$stack=New-Object Windows.Forms.TableLayoutPanel;$stack.ColumnCount=1;$null=$stack.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)));$stack.AutoSize=$true;$stack.Dock='Top';$stack.RowCount=0;$scroll.Controls.Add($stack)
function Add-UiRow($Control){$r=$stack.RowCount;$stack.RowCount++;$Control.Dock='Top';$stack.Controls.Add($Control,0,$r)}
Add-UiRow (New-UiLabel 'OPERACIÓN DIARIA' 18)
$script:status=New-UiLabel 'Esperando estado del motor…' 15;Add-UiRow $script:status
$script:timing=New-UiLabel 'Preparación: pendiente';Add-UiRow $script:timing
$script:detail=New-UiLabel '';$script:detail.AutoSize=$false;$script:detail.Height=60;Add-UiRow $script:detail
$flow=New-UiFlow
$script:preheatOn=New-UiButton 'PREHEAT · ON' {Send-UiCommand 'preheat'};$flow.Controls.Add($script:preheatOn)
$script:preheatOff=New-UiButton 'PREHEAT · OFF' {Send-UiCommand 'shutdown'};$flow.Controls.Add($script:preheatOff);Add-UiRow $flow
$flow=New-UiFlow
$script:shutdownOn=New-UiButton 'APAGADO · ON' {Send-UiCommand 'shutdown'};$flow.Controls.Add($script:shutdownOn)
$shutdownOff=New-UiButton 'APAGADO · OFF' {$script:notice.Text='APAGADO OFF no reanuda ni aumenta brillo. Para un nuevo uso, pulse PREHEAT ON y complete toda la preparación.'};$flow.Controls.Add($shutdownOff);Add-UiRow $flow
Add-UiRow (New-UiLabel 'Capas de entrada · disponibles únicamente cuando el panel esté READY')
$flow=New-UiFlow;$script:layerButtons=@{}
foreach($name in @('Main','PIP1','PIP2')){
    $button=New-UiButton ($name.ToUpperInvariant()+' · sin lectura') $null;$button.Tag=$name
    # Handle layer identity directly, avoiding closure capture of the foreach variable.
    $button.Add_Click({param($sender,$e)try{$row=@((Get-UiProperty $script:state layers @())|Where-Object {$_.layer -ceq [string]$sender.Tag});if($row.Count -ne 1){throw 'No hay lectura confirmada de esta capa.'};Send-UiCommand 'layer' ([string]$sender.Tag) (-not [bool]$row[0].enabled)}catch{$script:notice.Text=$_.Exception.Message}})
    $script:layerButtons[$name]=$button;$flow.Controls.Add($button)
}
$script:scale=New-UiButton 'SCALE' {Send-UiCommand 'scale'};$flow.Controls.Add($script:scale);Add-UiRow $flow
$flow=New-UiFlow
$script:accessPro=New-UiButton 'Acceso Pro…' {Open-UiPro};$flow.Controls.Add($script:accessPro);Add-UiRow $flow
Add-UiRow (New-UiLabel 'Soporte · detener / recuperar solo controladores identificados')
$flow=New-UiFlow
$script:recover=New-UiButton 'Solicitar parada propia' {Start-UiRecovery};$flow.Controls.Add($script:recover)
$script:forceRecovery=New-UiButton 'Forzar cierre revisado' {Start-UiRecovery $true};$script:forceRecovery.Enabled=$false;$flow.Controls.Add($script:forceRecovery);Add-UiRow $flow
$script:recoveryDetail=New-Object Windows.Forms.TextBox;$script:recoveryDetail.Multiline=$true;$script:recoveryDetail.ReadOnly=$true;$script:recoveryDetail.ScrollBars='Vertical';$script:recoveryDetail.Height=82;$script:recoveryDetail.Text='Solicitar parada no modifica la configuración. Los procesos ajenos permanecen intactos.';Add-UiRow $script:recoveryDetail
$script:notice=New-UiLabel 'Los ajustes se realizan en Pro. Cerrar esta ventana mantiene el motor y los medios en segundo plano.';$script:notice.AutoSize=$false;$script:notice.Height=82;Add-UiRow $script:notice
function Update-OperatorUi {
    try{$script:state=Read-UiJson 'operator-state.json'}catch{$script:state=$null;$script:notice.Text='No se puede leer el estado del motor. '+$_.Exception.Message}
    $fresh=Test-UiFreshState $script:state;$pending=Test-UiPending $script:state
    $script:preheatOn.Enabled=Test-UiAction $script:state 'preheat'
    $script:preheatOff.Enabled=((Test-UiAction $script:state 'shutdown') -and (Get-UiProperty $script:state state) -cin @('PREHEAT','READY'))
    $script:shutdownOn.Enabled=Test-UiAction $script:state 'shutdown'
    $layerAllowed=Test-UiAction $script:state 'layer'
    foreach($name in $script:layerButtons.Keys){$rows=@((Get-UiProperty $script:state layers @())|Where-Object {(Get-UiProperty $_ layer) -ceq $name});$known=($rows.Count -eq 1 -and (Get-UiProperty $rows[0] enabled $null) -is [bool]);$script:layerButtons[$name].Enabled=$layerAllowed -and $known;$script:layerButtons[$name].Text=$name.ToUpperInvariant()+' · '+$(if($known){if($rows[0].enabled){'ON → OFF'}else{'OFF → ON'}}else{'sin lectura'})}
    $script:scale.Enabled=($layerAllowed -and $null -ne $script:profile -and $script:profile.canvasWidth -gt 0 -and $script:profile.canvasHeight -gt 0)
    $script:recover.Enabled=($null -eq $script:recoveryProcess);$script:forceRecovery.Enabled=$script:needsForce -and $null -eq $script:recoveryProcess
    if(-not $fresh){$script:status.Text='SIN ESTADO VIGENTE · mandos bloqueados';$script:timing.Text='Tiempo restante y preparación sin confirmar';$script:detail.Text='Se requiere propietario vivo, sesión válida, comunicación confirmada y estado de los últimos 10 segundos.';return}
    $mode=[string]$script:state.state;$script:status.Text=$mode+$(if($pending){' · orden pendiente de confirmación'}else{''})
    $remaining=[double](Get-UiProperty $script:state remainingSeconds 0);$minutes=[Math]::Ceiling([Math]::Max(0,$remaining)/60)
    $minimum=if($null -ne $script:profile){$script:profile.preheatMinutes}else{'?'}
    $script:timing.Text=('Restante: {0} min · Preparación mínima: {1} min · {2}' -f $minutes,$minimum,$(if((Get-UiProperty $script:state preheatReady $false) -eq $true){'PREPARADO'}else{'aún no preparado'}))
    $script:detail.Text=([string](Get-UiProperty $script:state phase)+' · '+[string](Get-UiProperty $script:state message)+[Environment]::NewLine+'Última orden: '+[string](Get-UiProperty $script:state lastCommandResult))
}
$script:timer=New-Object Windows.Forms.Timer;$script:timer.Interval=1000;$script:timer.Add_Tick({if($script:tickBusy){return};$script:tickBusy=$true;try{Update-UiRecovery;Update-OperatorUi}catch{$script:notice.Text=$_.Exception.Message}finally{$script:tickBusy=$false}})
$script:form.Add_FormClosing({if(-not $SmokeTest){$null=[Windows.Forms.MessageBox]::Show('Cerrar Usuarios deja el motor y el reproductor en segundo plano. APAGADO ON solicita enfriamiento; Soporte solicita detener el control. Cerrar sesión o suspender Windows impide operar multimedia.','Usuarios','OK','Information')}})
function Invoke-OperatorSmoke {
    $owner=[pscustomobject]@{scriptPath=(Join-Path $PSScriptRoot 'Watch-VxOperator.ps1');configPath=$ConfigPath;dataDirectory=$DataDirectory;operatorConfigPath=$OperatorConfigPath}
    if(-not (Test-UiOwnerContext $owner)){throw 'Smoke: matching owner context rejected.'}
    $owner.operatorConfigPath=Join-Path $script:fixture 'different-operator-profile.json'
    if(Test-UiOwnerContext $owner){throw 'Smoke: GUI attached to engine using a different operator profile.'}
    $script:profile=New-VxOperatorConfig;$script:profile.canvasWidth=1920;$script:profile.canvasHeight=1080
    $session=[guid]::NewGuid().ToString()
    $state=[pscustomobject]@{schemaVersion=1;ownerProcessId=$PID;sessionId=$session;updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');communication='reachable';state='BLACK';phase='Black';remainingSeconds=0;preheatReady=$false;layers=@([pscustomobject]@{layer='Main';enabled=$true},[pscustomobject]@{layer='PIP1';enabled=$false},[pscustomobject]@{layer='PIP2';enabled=$false});lastCommandId='';lastCommandResult='';operatorPending=$false;message='Fixture; no playback or hardware'}
    Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    if(-not $script:preheatOn.Enabled -or $script:scale.Enabled){throw 'Smoke: BLACK action gates.'}
    $state.updatedUtc=[DateTimeOffset]::UtcNow.AddSeconds(-11).ToString('o');Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    if($script:preheatOn.Enabled -or $script:shutdownOn.Enabled){throw 'Smoke: stale state accepted.'}
    $state.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');$state.ownerProcessId=0;Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    if($script:preheatOn.Enabled){throw 'Smoke: dead owner accepted.'}
    $state.ownerProcessId=$PID;Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    $script:preheatOn.PerformClick();$command=Read-UiJson 'operator-command.json';Assert-VxOperatorCommand -Command $command -SessionId $session
    if($command.action -cne 'preheat' -or $script:preheatOn.Enabled -or $script:shutdownOn.Enabled){throw 'Smoke: pending command not blocked.'}
    $state.lastCommandId=$command.id;$state.state='PREHEAT';Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    if($script:preheatOn.Enabled -or $script:scale.Enabled -or -not $script:preheatOff.Enabled){throw 'Smoke: PREHEAT gates.'}
    $script:preheatOff.PerformClick();$shutdown=Read-UiJson 'operator-command.json'
    if($shutdown.action -cne 'shutdown'){throw 'Smoke: PREHEAT OFF did not request shutdown.'}
    $state.lastCommandId=$shutdown.id
    $state.state='READY';$state.preheatReady=$true;Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    if($script:plan.deviceModel -eq 'VX600' -and -not $script:scale.Enabled){throw 'Smoke: READY scale gate.'}
    if($script:plan.deviceModel -eq 'VX600'){$script:layerButtons['PIP1'].PerformClick();$command=Read-UiJson 'operator-command.json';if($command.layer -cne 'PIP1' -or $command.enabled -ne $true){throw 'Smoke: typed layer command.'};$state.lastCommandId=$command.id;Write-UiJson 'operator-state.json' $state;Update-OperatorUi;$script:scale.PerformClick();$command=Read-UiJson 'operator-command.json';Assert-VxOperatorCommand -Command $command -SessionId $session;$state.lastCommandId=$command.id}
    $state.state='COOLDOWN';$state.preheatReady=$false;Write-UiJson 'operator-state.json' $state;Update-OperatorUi
    if($script:preheatOn.Enabled -or $script:shutdownOn.Enabled -or $script:scale.Enabled){throw 'Smoke: cooldown gates.'}
    $before=(Get-FileHash -LiteralPath (Join-Path $DataDirectory 'operator-command.json')).Hash;$rejected=$false;try{Send-UiCommand 'preheat'}catch{$rejected=$true}
    if(-not $rejected -or (Get-FileHash -LiteralPath (Join-Path $DataDirectory 'operator-command.json')).Hash -ne $before){throw 'Smoke: invalid mode wrote command.'}
    $shutdownOff.PerformClick()
    if((Get-FileHash -LiteralPath (Join-Path $DataDirectory 'operator-command.json')).Hash -ne $before){throw 'Smoke: APAGADO OFF wrote a command.'}
    $rejected=$false;try{Start-UiEngine}catch{$rejected=$true};if(-not $rejected){throw 'Smoke: engine launched.'}
    $rejected=$false;try{Start-UiRecovery}catch{$rejected=$true};if(-not $rejected){throw 'Smoke: recovery launched.'}
    $rejected=$false;try{Open-UiPro}catch{$rejected=$true};if(-not $rejected -or $script:accessPro.Text -cne 'Acceso Pro…'){throw 'Smoke: Pro launcher bypassed fixture gate.'}
    $script:notice.Text='Smoke PASS: typed commands, fresh owner, pending, mode gates. Temporary fixtures; no motor or playback.'
    if($ScreenshotPath){$null=[IO.Directory]::CreateDirectory($ScreenshotPath);[Windows.Forms.Application]::DoEvents();$bitmap=New-Object Drawing.Bitmap($script:form.Width,$script:form.Height);try{$script:form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save((Join-Path $ScreenshotPath 'usuarios.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}}
    Write-Output 'PASS Operator user GUI smoke (temporary fixtures; no engine launched).'
}
try{
    Update-OperatorUi
    if($SmokeTest){$script:form.Show();[Windows.Forms.Application]::DoEvents();Invoke-OperatorSmoke;$script:form.Close()}
    else{
        $script:form.Add_Shown({
            $script:timer.Start()
            if($script:configurationIssue){$script:notice.Text='Configure Usuarios en Pro antes de operar. '+$script:configurationIssue;return}
            if(-not $script:profile.configured){$script:notice.Text='Perfil sin aceptar: abra Pro → Configurar Usuarios, revise y guarde la aceptación explícita.';return}
            if(-not $NoAutoStart){try{Start-UiEngine}catch{$script:notice.Text='Inicio bloqueado. Configure y valide Usuarios desde Pro. '+$_.Exception.Message}}
        })
        [Windows.Forms.Application]::Run($script:form)
    }
}finally{$script:timer.Stop();$script:timer.Dispose();$script:form.Dispose();if($null -ne $script:motorProcess){$script:motorProcess.Dispose()};if($null -ne $script:recoveryProcess){$script:recoveryProcess.Dispose()};if($script:fixture -and [IO.Directory]::Exists($script:fixture)){Remove-Item -LiteralPath $script:fixture -Recurse -Force}}
