#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$DataDirectory='', [switch]$SmokeTest, [string]$ScreenshotPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Resolve defaults here: Windows PowerShell 5.1 can evaluate parameter defaults before PSScriptRoot.
$explicitConfig = -not [string]::IsNullOrWhiteSpace($ConfigPath)
$explicitData = -not [string]::IsNullOrWhiteSpace($DataDirectory)
$installedRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NovaStar-VX400-Control'
if (-not $explicitConfig) {
    if (-not $explicitData -and (Test-Path -LiteralPath (Join-Path $installedRoot 'plan.config.json'))) {
        $ConfigPath=Join-Path $installedRoot 'plan.config.json'
        $DataDirectory=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'NovaStar-VX400-Control'
    } else { $ConfigPath=Join-Path $PSScriptRoot 'plan.config.json' }
}
if ([string]::IsNullOrWhiteSpace($DataDirectory)) { $DataDirectory=Join-Path $PSScriptRoot 'plan-data' }
$ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
$DataDirectory=[IO.Path]::GetFullPath($DataDirectory)
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Abra esta aplicación con Windows PowerShell -STA.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# Installed machine-wide data is private to Administrators/SYSTEM. Let Windows request UAC on double click.
if(-not $SmokeTest -and $ConfigPath.StartsWith($installedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        try{
            foreach($argumentPath in @($PSCommandPath,$ConfigPath,$DataDirectory)){if($argumentPath.Contains('"')){throw 'Ruta no válida: contiene comillas.'}}
            $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -DataDirectory "{2}"' -f $PSCommandPath,$ConfigPath,$DataDirectory
            $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $null=Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs
            exit 0
        }catch{
            $null=[Windows.Forms.MessageBox]::Show('Windows necesita permiso de administrador para abrir la configuración protegida y el inicio automático. No se abrió el control. '+$_.Exception.Message,'NovaStar VX400',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
            exit 1
        }
    }
}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
try { $script:config=Read-VxPlanConfig -Path $ConfigPath }
catch {
    if($ConfigPath.StartsWith($installedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
        $message='La instalación protege sus archivos. Abra Abrir-Control-VX400.bat con «Ejecutar como administrador». '+$_.Exception.Message
        $null=[Windows.Forms.MessageBox]::Show($message,'NovaStar VX400',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
        exit 1
    }
    throw
}
$script:configPath=$ConfigPath; $script:dataDirectory=$DataDirectory
$script:smoke=[bool]$SmokeTest
$script:state=$null; $script:stateRecent=$false; $script:manualProcess=$null; $script:manualError=''
$script:panelProcess=$null;$script:panelOutput='';$script:panelError='';$script:panelPending=$null;$script:panelPauseId='';$script:panelPauseDeadline=[DateTimeOffset]::MinValue;$script:panelResumeTask=$false
$script:installerProcess=$null; $script:installerOutput=''; $script:installerError=''; $script:installerAction=''
$script:stopDeadline=$null; $script:task=$null; $script:tickBusy=$false; $script:installerMigrates=$false
$script:logOffset=0L; $script:logFragment=''; $script:logLines=New-Object 'Collections.Generic.List[string]'
$script:logIdentity=''; $script:loading=$false; $script:profileKey='dry'; $script:gateId=''
$script:profiles=@{}
foreach ($key in @('dry','preheat','cooldown')) { $script:profiles[$key]=@($script:config.profiles.$key) }
$script:blue=[Drawing.Color]::FromArgb(24,82,166)
$script:ink=[Drawing.Color]::FromArgb(25,40,64)
$script:muted=[Drawing.Color]::FromArgb(94,111,133)
$script:background=[Drawing.Color]::FromArgb(242,246,251)
$script:mutex=$null; $script:ownsMutex=$false

function Get-Property($Object,[string]$Name,$Default='') {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function New-Label([string]$Text,[int]$Size=10,[bool]$Bold=$false) {
    $item=New-Object Windows.Forms.Label
    $item.Text=$Text; $item.AutoSize=$true; $item.ForeColor=$script:ink
    $style=if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
    $item.Font=New-Object Drawing.Font('Segoe UI',[single]$Size,$style)
    $item.Margin=New-Object Windows.Forms.Padding(0,5,12,5)
    return ,$item
}
function New-Button([string]$Text,[bool]$Primary=$false) {
    $item=New-Object Windows.Forms.Button
    $item.Text=$Text; $item.AutoSize=$true; $item.Height=36; $item.MinimumSize=New-Object Drawing.Size(110,36)
    $item.Padding=New-Object Windows.Forms.Padding(10,2,10,2)
    $item.FlatStyle='Flat'; $item.FlatAppearance.BorderSize=1
    $item.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(203,215,231)
    $item.BackColor=if($Primary){$script:blue}else{[Drawing.Color]::White}
    $item.ForeColor=if($Primary){[Drawing.Color]::White}else{$script:ink}
    $item.Margin=New-Object Windows.Forms.Padding(0,5,9,5)
    return ,$item
}
function New-Number([decimal]$Min,[decimal]$Max,[decimal]$Value,[int]$Decimals=0) {
    $item=New-Object Windows.Forms.NumericUpDown
    $item.Minimum=$Min; $item.Maximum=$Max; $item.DecimalPlaces=$Decimals; $item.Value=$Value
    $item.Width=100; $item.Margin=New-Object Windows.Forms.Padding(0,5,18,5)
    return ,$item
}
function New-Grid {
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill'; $grid.BackgroundColor=[Drawing.Color]::White
    $grid.BorderStyle='None'; $grid.AutoSizeColumnsMode='Fill'; $grid.RowHeadersVisible=$false
    $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.SelectionMode='FullRowSelect'
    $grid.MultiSelect=$false; $grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(232,239,249)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor=$script:ink
    $grid.ColumnHeadersHeight=38; $grid.RowTemplate.Height=32
    $grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(248,250,253)
    $grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(211,229,253)
    $grid.DefaultCellStyle.SelectionForeColor=$script:ink
    $grid.Add_DataError({param($sender,$eventArgs) $eventArgs.ThrowException=$false; Set-Notice 'Revise el valor de la celda; los números usan punto decimal.' $true})
    return ,$grid
}
function Add-TextColumn($Grid,[string]$Name,[string]$Header,[int]$Weight=100) {
    $column=New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name=$Name; $column.HeaderText=$Header; $column.FillWeight=$Weight
    $null=$Grid.Columns.Add($column)
}
function New-Page([string]$Title) {
    $page=New-Object Windows.Forms.TabPage
    $page.Text=$Title; $page.BackColor=$script:background; $page.Padding=New-Object Windows.Forms.Padding(20)
    $null=$script:tabs.TabPages.Add($page)
    return ,$page
}
function New-Stack($Parent,[int]$Rows) {
    $stack=New-Object Windows.Forms.TableLayoutPanel
    $stack.Dock='Fill'; $stack.ColumnCount=1; $stack.RowCount=$Rows; $stack.BackColor=$script:background
    $stack.Margin=New-Object Windows.Forms.Padding(0)
    $Parent.Controls.Add($stack)
    return ,$stack
}
function Add-StackRow($Stack,$Control,[int]$Index,[int]$Height=0) {
    if($Height -gt 0){$null=$Stack.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$Height)))}
    else{$null=$Stack.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))}
    $Control.Dock='Fill'; $Stack.Controls.Add($Control,0,$Index)
}
function New-Flow {
    $flow=New-Object Windows.Forms.FlowLayoutPanel
    $flow.WrapContents=$true; $flow.AutoScroll=$true; $flow.Margin=New-Object Windows.Forms.Padding(0)
    return ,$flow
}
function Set-Notice([string]$Text,[bool]$Error=$false) {
    $script:notice.Text=$Text
    $script:notice.ForeColor=if($Error){[Drawing.Color]::FromArgb(170,43,43)}else{$script:muted}
}
function Invoke-UiAction([scriptblock]$Action) {
    try { & $Action } catch { Set-Notice $_.Exception.Message $true }
}
function Get-LocalZone {
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($script:config.timeZone) }
    catch { if($script:config.timeZone -eq 'SA Pacific Standard Time'){return [TimeZoneInfo]::FindSystemTimeZoneById('America/Bogota')}; throw }
}
function Convert-LocalToUtc([DateTime]$Value) {
    $zone=Get-LocalZone
    $value=[DateTime]::SpecifyKind($Value,[DateTimeKind]::Unspecified)
    if($zone.IsInvalidTime($value) -or $zone.IsAmbiguousTime($value)){throw 'La hora elegida es ambigua o no existe en la zona configurada.'}
    return [DateTimeOffset]([TimeZoneInfo]::ConvertTimeToUtc($value,$zone))
}
function Format-RequestTime([string]$Value) {
    return [TimeZoneInfo]::ConvertTime([DateTimeOffset]$Value,(Get-LocalZone)).ToString('dd/MM/yyyy HH:mm')
}
function Write-ValidatedJson([string]$Path,$Document,[ValidateSet('config','requests','reply')][string]$Kind) {
    $directory=Split-Path $Path -Parent
    $null=[IO.Directory]::CreateDirectory($directory)
    $temporary=Join-Path $directory ('.vx400-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllText($temporary,($Document|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($true)))
        if($Kind -eq 'config'){$null=Read-VxPlanConfig -Path $temporary}
        if($Kind -eq 'requests'){$null=Read-VxRequests -Path $temporary}
        Move-VxAtomicFile -Source $temporary -Destination $Path
    } finally { if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)} }
}
function Convert-GridNumber($Value,[string]$Field) {
    $number=0.0
    if(-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) {throw "Valor inválido en $Field; use punto decimal."}
    return $number
}
function Save-ProfileEdits {
    $null=$script:phaseGrid.EndEdit()
    $segments=@(foreach($row in $script:phaseGrid.Rows){
        [pscustomobject]@{name=[string]$row.Cells['name'].Value; from=(Convert-GridNumber $row.Cells['from'].Value 'Desde'); to=(Convert-GridNumber $row.Cells['to'].Value 'Hasta'); minutes=(Convert-GridNumber $row.Cells['minutes'].Value 'Minutos'); content=[string]$row.Cells['content'].Value}
    })
    $script:profiles[$script:profileKey]=$segments
}
function Show-Profile([string]$Key) {
    $script:loading=$true
    try {
        $script:profileKey=$Key; $script:phaseGrid.Rows.Clear()
        foreach($phase in $script:profiles[$Key]){
            $content=[string](Get-Property $phase content $(if($Key -eq 'cooldown'){'FromInput'}else{$script:config.conditioningPattern}))
            $null=$script:phaseGrid.Rows.Add([string]$phase.name,([double]$phase.from).ToString([Globalization.CultureInfo]::InvariantCulture),([double]$phase.to).ToString([Globalization.CultureInfo]::InvariantCulture),([double]$phase.minutes).ToString([Globalization.CultureInfo]::InvariantCulture),$content)
        }
    } finally {$script:loading=$false}
    Update-Totals
}
function Update-Totals {
    if($script:loading){return}
    try {
        Save-ProfileEdits
        $dry=(Get-VxProfileSeconds -Profile $script:profiles.dry)/60
        $preheat=(Get-VxProfileSeconds -Profile $script:profiles.preheat)/60
        $cool=(Get-VxProfileSeconds -Profile $script:profiles.cooldown)/60
        $script:totalLabel.Text=('Duración: secado {0:0.##} min  ·  preparación {1:0.##} min  ·  enfriamiento {2:0.##} min' -f $dry,$preheat,$cool)
        $ends=@(foreach($time in ($script:dailyStarts.Text -split '[,;\s]+'|Where-Object{$_})){
            $start=[DateTime]::ParseExact($time,'HH:mm',[Globalization.CultureInfo]::InvariantCulture)
            '{0} → {1}' -f $time,$start.AddMinutes($dry).ToString('HH:mm')
        })
        $script:dailyEnd.Text='Secado diario: '+($ends -join '   |   ')
        $script:requestLead.Text=('Reserve con al menos {0:0.##} minutos de anticipación. Zona: {1}.' -f ((Get-VxProfileSeconds -Profile $script:config.profiles.preheat)/60),$script:config.timeZone)
    } catch { $script:totalLabel.Text='Revise fases y horas: '+$_.Exception.Message }
}
function Get-EditedConfig {
    Save-ProfileEdits
    $candidate=$script:config|ConvertTo-Json -Depth 20|ConvertFrom-Json
    $candidate.deviceAddress=$script:address.Text.Trim(); $candidate.tcpPort=[int]$script:port.Value
    $candidate.pollIntervalSeconds=[double]$script:poll.Value; $candidate.timeoutMs=[int]$script:timeout.Value
    $candidate.offlineFailures=[int]$script:offlineFailures.Value; $candidate.onlineSuccesses=[int]$script:onlineSuccesses.Value
    $candidate.maximumObservationGapSeconds=[double]$script:maxGap.Value
    $candidate.timeZone=$script:zone.Text.Trim()
    $candidate.panelPowerCouplingVerified=[bool]$script:powerVerified.Checked
    $candidate.startupProtectionVerified=[bool]$script:startupVerified.Checked
    $candidate.idleBrightnessPercent=[double]$script:idle.Value; $candidate.operatingBrightnessPercent=[double]$script:operating.Value
    $candidate.conditioningPattern=[string]$script:pattern.SelectedItem
    $candidate.dailyStarts=@($script:dailyStarts.Text -split '[,;\s]+'|Where-Object{$_})
    $null=$script:windowGrid.EndEdit()
    $candidate.operatingWindows=@(foreach($row in $script:windowGrid.Rows){
        $days=@(for($d=0;$d -lt 7;$d++){if($row.Cells['day'+$d].Value -eq $true){$d}})
        [pscustomobject]@{start=[string]$row.Cells['start'].Value;end=[string]$row.Cells['end'].Value;days=$days}
    })
    foreach($key in @('dry','preheat','cooldown')){$candidate.profiles.$key=@($script:profiles[$key])}
    return $candidate
}
function Test-Admin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-WritableContext {
    if($script:configPath.StartsWith($installedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and -not (Test-Admin)) {
        throw 'Para guardar la instalación, cierre y abra Abrir-Control-VX400.bat con «Ejecutar como administrador».'
    }
}
function Get-ControlTask {
    if($script:smoke){return $null}
    $task=Get-ScheduledTask -TaskName 'NovaStar-VX400-Control' -TaskPath '\' -ErrorAction SilentlyContinue
    if($null -eq $task){return $null}
    $actions=@($task.Actions)
    $exe=Get-WindowsPowerShell
    $watcher=Join-Path $installedRoot 'Watch-Vx400Plan.ps1'
    $configuration=Join-Path $installedRoot 'plan.config.json'
    $data=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'NovaStar-VX400-Control'
    $arguments='-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -DataDirectory "{2}"' -f $watcher,$configuration,$data
    if($actions.Count -ne 1 -or $actions[0].Execute -ine $exe -or $actions[0].WorkingDirectory -ine $installedRoot -or @($arguments,($arguments+' -EnableControl')) -notcontains $actions[0].Arguments){
        throw 'Existe una tarea con el mismo nombre que no pertenece a esta instalación. No se modificó; revise el Programador de tareas.'
    }
    return $task
}
function Test-Running {
    if($null -ne $script:manualProcess -and -not $script:manualProcess.HasExited){return $true}
    if($null -ne $script:task -and [string]$script:task.State -eq 'Running'){return $true}
    $lockPath=Join-Path $script:dataDirectory 'watcher.lock'
    if([IO.File]::Exists($lockPath)){
        $probe=$null
        try{$probe=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
        catch [IO.IOException]{return $true}
        finally{if($null -ne $probe){$probe.Dispose()}}
    }
    return ($script:stateRecent -and [string](Get-Property $script:state state) -ne 'STOPPED')
}
function Save-Configuration {
    if(-not $script:smoke -and (Test-Running)){throw 'Pulse Detener y espere la confirmación antes de guardar cambios. La configuración anterior sigue activa.'}
    Assert-WritableContext
    $candidate=Get-EditedConfig
    Write-ValidatedJson -Path $script:configPath -Document $candidate -Kind config
    $script:config=Read-VxPlanConfig -Path $script:configPath
    $script:endpoint.Text=('{0}:{1}  ·  {2}' -f $script:config.deviceAddress,$script:config.tcpPort,$script:config.timeZone)
    Update-Totals
    Set-Notice 'Configuración guardada y validada. Se aplicará al iniciar el monitor o control.'
}
function Quote-Argument([string]$Value) {
    if($Value.Contains('"')){throw 'Ruta no válida: contiene comillas.'}
    return '"'+$Value+'"'
}
function Get-WindowsPowerShell { return Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
function Set-GuiMutex([string]$Directory) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Directory.ToLowerInvariant()))).Replace('-','')}finally{$hash.Dispose()}
    $nextMutex=New-Object Threading.Mutex($false,('Local\NovaStar-VX400-GUI-'+$key))
    $owns=$false
    try{$owns=$nextMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){$nextMutex.Dispose();throw 'Ya hay una ventana de control abierta para esta carpeta de datos.'}
    if($script:ownsMutex){$script:mutex.ReleaseMutex();$script:mutex.Dispose()}
    $script:mutex=$nextMutex;$script:ownsMutex=$true
}
function Use-InstalledContext {
    $nextConfig=Join-Path $installedRoot 'plan.config.json'
    $nextData=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'NovaStar-VX400-Control'
    $loaded=Read-VxPlanConfig -Path $nextConfig
    if($script:dataDirectory -ne $nextData){Set-GuiMutex $nextData}
    $script:configPath=$nextConfig;$script:dataDirectory=$nextData;$script:config=$loaded
    $script:state=$null;$script:stateRecent=$false;$script:logOffset=0L;$script:logFragment='';$script:logLines.Clear();$script:logIdentity=''
    Update-Requests;Update-Status;Update-Log
}
function Begin-Installer([string]$Action,[bool]$Control=$false) {
    if($script:smoke){throw 'Instalación deshabilitada en SmokeTest.'}
    if($null -ne $script:installerProcess){throw 'Espere a que termine la operación de inicio automático.'}
    if(-not (Test-Admin)){throw 'Abra Abrir-Control-VX400.bat con «Ejecutar como administrador» para modificar el inicio automático.'}
    $installer=Join-Path $PSScriptRoot 'Install-Vx400Control.ps1'
    if(-not (Test-Path -LiteralPath $installer)){throw 'Falta Install-Vx400Control.ps1. Use el paquete completo.'}
    $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File '+(Quote-Argument $installer)
    $script:installerMigrates=$false
    if($Action -eq 'remove'){$arguments+=' -Remove'}
    else{
        $arguments+=' -ConfigPath '+(Quote-Argument $script:configPath)+' -SourceDataDirectory '+(Quote-Argument $script:dataDirectory)
        if($Control){$null=Read-VxPlanConfig -Path $script:configPath -EnableControl; $arguments+=' -EnableControl'}
        if($null -ne (Get-ControlTask) -or (Test-Path -LiteralPath (Join-Path $installedRoot 'installation.json'))){$arguments+=' -Update'}
        else{
            $script:installerMigrates=$true
        }
        $arguments+=' -StartNow'
    }
    $script:installerOutput=Join-Path ([IO.Path]::GetTempPath()) ('vx400-install-'+[guid]::NewGuid().ToString('N')+'.out')
    $script:installerError=$script:installerOutput+'.err'; $script:installerAction=$Action
    $script:installerProcess=Start-Process -FilePath (Get-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:installerOutput -RedirectStandardError $script:installerError
    Set-Notice 'Actualizando inicio automático…'
}
function Start-Controller([bool]$Control,[switch]$ManualDry) {
    if($script:smoke){throw 'Controlador deshabilitado en SmokeTest.'}
    $script:task=Get-ControlTask
    if($null -ne $script:panelProcess -or $null -ne $script:panelPending){throw 'Espere a que termine el mando manual.'}
    if((Test-Running) -or ($null -ne $script:manualProcess -and -not $script:manualProcess.HasExited)){throw 'El monitor o control ya está activo. Pulse Detener antes de cambiar el modo.'}
    if($null -ne $script:stopDeadline){throw 'Espere a que finalice la detención.'}
    Save-Configuration
    # Starting always uses the saved, validated config.
    if($Control -and -not $ManualDry){if(-not $script:config.panelPowerCouplingVerified -or -not $script:config.startupProtectionVerified){throw 'Para iniciar control, confirme las dos condiciones de seguridad en Estado y guarde la configuración.'};$null=Read-VxPlanConfig -Path $script:configPath -EnableControl}else{$null=Read-VxPlanConfig -Path $script:configPath}
    if($ManualDry){
        $null=Read-VxPlanConfig -Path $script:configPath -EnableControl -ManualControl
        if($null -ne $script:task -and [string]$script:task.State -ne 'Disabled'){throw 'Pulse Detener primero para pausar el inicio automatico durante el secado manual.'}
    }elseif($null -ne $script:task){Begin-Installer -Action start -Control $Control;return}
    $watcher=Join-Path $PSScriptRoot 'Watch-Vx400Plan.ps1'
    if(-not (Test-Path -LiteralPath $watcher)){throw 'Falta Watch-Vx400Plan.ps1. Use el paquete completo.'}
    $null=[IO.Directory]::CreateDirectory($script:dataDirectory)
    $stopPath=Join-Path $script:dataDirectory 'stop.request'
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
    $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File '+(Quote-Argument $watcher)+' -ConfigPath '+(Quote-Argument $script:configPath)+' -DataDirectory '+(Quote-Argument $script:dataDirectory)
    if($Control){$arguments+=' -EnableControl'}
    if($ManualDry){$arguments+=' -ManualDry'}
    $script:manualError=Join-Path ([IO.Path]::GetTempPath()) ('vx400-control-'+[guid]::NewGuid().ToString('N')+'.err')
    $script:manualProcess=Start-Process -FilePath (Get-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardError $script:manualError
    Set-Notice $(if($ManualDry){'Secado manual solicitado. Una sola ejecucion; ante una perdida de comunicacion se detiene.'}else{'Inicio solicitado. Esperando los datos del controlador…'})
}
function Start-PanelCommand([ValidateSet('Normal','Blackout','White')][string]$Display) {
    if($script:smoke){throw 'Mandos deshabilitados en SmokeTest.'}
    if($null -ne $script:panelProcess -or $null -ne $script:panelPending){throw 'Espere a que termine el mando anterior.'}
    if($null -ne $script:manualProcess -and -not $script:manualProcess.HasExited -and -not (Test-Running)){throw 'Espere a que el controlador publique su estado.'}
    if(Test-Running){
        if(-not $script:stateRecent -or ((Get-Property $script:state mode) -eq 'control' -and (Get-Property $script:state state) -notin @('BLACK','OPERATING'))){throw 'El brillo manual esta bloqueado durante la secuencia. Espere a que termine o use Detener.'}
        $task=Get-ControlTask
        $script:panelResumeTask=($null -ne $task -and $task.Settings.Enabled)
        if($script:panelResumeTask){$null=Disable-ScheduledTask -TaskName 'NovaStar-VX400-Control' -TaskPath '\' -ErrorAction Stop}
        $script:panelPending=$Display;$script:panelPauseId=[Guid]::NewGuid().ToString();$script:panelPauseDeadline=[DateTimeOffset]::UtcNow.AddSeconds(12)
        $pausePath=Join-Path $script:dataDirectory 'manual-pause.request';$temporary=$pausePath+'.tmp'
        [IO.File]::WriteAllText($temporary,$script:panelPauseId)
        Move-VxAtomicFile -Source $temporary -Destination $pausePath
        $script:panelResult.Text='Pausando el motor antes del mando manual...'
        return
    }
    $task=Get-ControlTask
    if($null -ne $task -and [string]$task.State -ne 'Disabled'){throw 'Pulse Detener para pausar el inicio automatico antes de usar los mandos.'}
    Save-Configuration
    $command=Join-Path $PSScriptRoot 'Set-Vx400Manual.ps1'
    if(-not (Test-Path -LiteralPath $command)){throw 'Falta Set-Vx400Manual.ps1. Use el paquete completo.'}
    $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File '+(Quote-Argument $command)+' -ConfigPath '+(Quote-Argument $script:configPath)+' -DataDirectory '+(Quote-Argument $script:dataDirectory)+' -EnableControl -Display '+$Display+' -BrightnessPercent '+([double]$script:panelBrightness.Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    $script:panelOutput=Join-Path ([IO.Path]::GetTempPath()) ('vx400-panel-'+[guid]::NewGuid().ToString('N')+'.out')
    $script:panelError=$script:panelOutput+'.err'
    $script:panelProcess=Start-Process -FilePath (Get-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:panelOutput -RedirectStandardError $script:panelError
    $script:panelResult.Text='Enviando mando; esperando confirmacion del VX400...'
}
function Request-Stop {
    if($script:smoke){throw 'Detención deshabilitada en SmokeTest.'}
    $script:task=Get-ControlTask
    if($null -ne $script:task){
        if(-not (Test-Admin)){throw 'Abra la aplicación como administrador para detener el servicio y pausar su reinicio automático.'}
        $null=Disable-ScheduledTask -TaskName 'NovaStar-VX400-Control' -TaskPath '\' -ErrorAction Stop
    }
    if(-not (Test-Running)){Set-Notice 'No hay un controlador activo con datos recientes. Se pausó cualquier inicio automático instalado.';return}
    $null=[IO.Directory]::CreateDirectory($script:dataDirectory)
    [IO.File]::WriteAllText((Join-Path $script:dataDirectory 'stop.request'),[DateTimeOffset]::UtcNow.ToString('o'))
    $script:stopDeadline=[DateTimeOffset]::UtcNow.AddSeconds(10)
    Set-Notice 'Detención ordenada solicitada. Espere hasta 10 segundos; no se forzará el proceso.'
}
function Send-OperatorAnswer([ValidateSet('restart','hold')][string]$Action) {
    if($script:smoke){throw 'Respuestas deshabilitadas en SmokeTest.'}
    $state=Read-VxSharedText -Path (Join-Path $script:dataDirectory 'estado.json')|ConvertFrom-Json
    $age=([DateTimeOffset]::UtcNow-[DateTimeOffset]$state.updatedUtc).TotalSeconds
    if($age -lt -5 -or $age -gt 10 -or (Get-Property $state communication) -ne 'reachable' -or -not (Get-Property $state operatorPending $false) -or [string](Get-Property $state operatorGateId) -ne $script:gateId) {
        throw 'La consulta ya cambió o no hay comunicación reciente. Espere una nueva actualización.'
    }
    $reply=[pscustomobject]@{id=[guid]::NewGuid().ToString();gateId=$script:gateId;action=$Action;utc=[DateTimeOffset]::UtcNow.ToString('o')}
    Write-ValidatedJson -Path (Join-Path $script:dataDirectory 'operador.json') -Document $reply -Kind reply
    Set-Notice $(if($Action -eq 'restart'){'Preparación solicitada para esta recuperación.'}else{'Reposo solicitado. Puede iniciar la preparación desde esta consulta cuando esté listo.'})
}
function Update-Requests {
    $items=Read-VxRequests -Path (Join-Path $script:dataDirectory 'solicitudes.json')
    $script:requestGrid.Rows.Clear()
    foreach($item in @($items|Sort-Object startUtc -Descending)){
        $null=$script:requestGrid.Rows.Add($item.id,$item.title,(Format-RequestTime $item.startUtc),(Format-RequestTime $item.endUtc),$(if($item.cancelled){'Cancelada'}else{'Reservada'}))
    }
}
function Change-Requests([ValidateSet('add','cancel')][string]$Action) {
    $null=[IO.Directory]::CreateDirectory($script:dataDirectory)
    $path=Join-Path $script:dataDirectory 'solicitudes.json'
    # Single GUI per data directory plus a file lock; read fresh before modifying to retain all bookings.
    $lock=$null
    try {
        try{$lock=[IO.File]::Open(($path+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch{throw 'Otra ventana está guardando solicitudes. Vuelva a intentar.'}
        $items=Read-VxRequests -Path $path
        if($Action -eq 'add'){
            $title=$script:requestTitle.Text.Trim()
            if([string]::IsNullOrWhiteSpace($title)){throw 'Escriba el nombre de la solicitud.'}
            $start=Convert-LocalToUtc $script:requestStart.Value; $end=Convert-LocalToUtc $script:requestEnd.Value
            $lead=Get-VxProfileSeconds -Profile $script:config.profiles.preheat
            if($start -lt [DateTimeOffset]::UtcNow.AddSeconds($lead)){throw ('Reserve al menos {0:0.##} minutos antes del uso.' -f ($lead/60))}
            if($end -le $start){throw 'La hora final debe ser posterior al inicio.'}
            $items += [pscustomobject]@{id=[guid]::NewGuid().ToString();title=$title;startUtc=$start.ToString('o');endUtc=$end.ToString('o');cancelled=$false}
        }else{
            if($null -eq $script:requestGrid.CurrentRow){throw 'Seleccione la solicitud que desea cancelar.'}
            $id=[string]$script:requestGrid.CurrentRow.Cells['id'].Value
            $found=$false
            foreach($item in $items){if($item.id -eq $id){$item.cancelled=$true;$found=$true}}
            if(-not $found){throw 'La solicitud cambió. Actualice la lista y vuelva a intentar.'}
        }
        Write-ValidatedJson -Path $path -Document ([pscustomobject]@{schemaVersion=1;items=@($items)}) -Kind requests
    }finally{if($null -ne $lock){$lock.Dispose()}}
    Update-Requests
    Set-Notice $(if($Action -eq 'add'){'Solicitud reservada. El controlador iniciará la preparación con la anticipación configurada.'}else{'Solicitud cancelada; se conserva en el historial.'})
}
function Update-Log {
    $path=Join-Path $script:dataDirectory 'eventos.jsonl'
    if(-not [IO.File]::Exists($path)){return}
    $file=Get-Item -LiteralPath $path
    $identity=$file.CreationTimeUtc.Ticks.ToString()
    if($file.Length -lt $script:logOffset -or $script:logIdentity -ne $identity){$script:logOffset=0L;$script:logFragment='';$script:logLines.Clear();$script:logIdentity=$identity}
    if($file.Length -eq $script:logOffset){return}
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
        $skipFirst=$false
        # Read at most the final 64 KiB when attaching or when the writer outruns this window.
        if($stream.Length-$script:logOffset -gt 65536){$script:logOffset=$stream.Length-65536;$script:logFragment='';$skipFirst=$true}
        $null=$stream.Seek($script:logOffset,[IO.SeekOrigin]::Begin)
        $bytes=New-Object byte[] ([int][Math]::Min(65536,$stream.Length-$script:logOffset))
        $count=$stream.Read($bytes,0,$bytes.Length);$script:logOffset=$stream.Position
        $text=$script:logFragment+[Text.Encoding]::UTF8.GetString($bytes,0,$count)
        $lines=$text -split "`n"; $script:logFragment=$lines[-1]
        for($i=0;$i -lt $lines.Count-1;$i++){
            if($skipFirst -and $i -eq 0){continue}
            $line=$lines[$i].Trim();if(-not $line){continue}
            try{$event=$line|ConvertFrom-Json;$line=('{0}  {1}  {2}' -f (Get-Property $event utc (Get-Property $event timestamp)),(Get-Property $event event (Get-Property $event level)),(Get-Property $event message (Get-Property $event detail $line)))}catch{}
            $script:logLines.Add($line)
        }
        while($script:logLines.Count -gt 80){$script:logLines.RemoveAt(0)}
        $script:logBox.Text=$script:logLines -join [Environment]::NewLine
        $script:logBox.SelectionStart=$script:logBox.TextLength;$script:logBox.ScrollToCaret()
    }finally{$stream.Dispose()}
}
function Update-Status {
    $script:stateRecent=$false
    $path=Join-Path $script:dataDirectory 'estado.json'
    if([IO.File]::Exists($path)){
        try{
            if((Get-Item -LiteralPath $path).Length -gt 65536){throw 'Estado demasiado grande.'}
            $script:state=Read-VxSharedText -Path $path|ConvertFrom-Json
            $age=([DateTimeOffset]::UtcNow-[DateTimeOffset]$script:state.updatedUtc).TotalSeconds
            $script:stateRecent=($age -ge -5 -and $age -le 10)
        }catch{$script:state=$null}
    }
    $fresh=$script:stateRecent
    $communication=[string](Get-Property $script:state communication 'unknown')
    $stateName=[string](Get-Property $script:state state)
    $script:connectionValue.Text=if(-not $fresh){'Sin datos recientes'}elseif($stateName -eq 'STOPPED'){'Proceso detenido'}elseif($communication -eq 'reachable'){'Comunicación disponible'}elseif($communication -eq 'unreachable'){'Sin comunicación'}elseif($communication -eq 'uncertain'){'Comunicación inestable'}else{'Sin confirmar'}
    $script:connectionValue.ForeColor=if($fresh -and $stateName -ne 'STOPPED' -and $communication -eq 'reachable'){[Drawing.Color]::FromArgb(22,126,91)}else{$script:muted}
    $names=@{BOOT='Iniciando';WAITING='En espera';PREHEAT='Preparación';OPERATING='En uso';DRY='Secado';COOLDOWN='Enfriamiento';BLACK='Reposo / negro';FAULT='Revisar alerta';STOPPED='Detenido';WAIT_OPERATOR='Espera su decisión'}
    $stateName=[string](Get-Property $script:state state)
    $script:phaseValue.Text=if(-not $fresh){'—'}elseif($names.ContainsKey($stateName)){$names[$stateName]}else{$stateName}
    $script:phaseDetail.Text=if($fresh -and $stateName -eq 'STOPPED'){'Sin secuencia activa'}elseif($fresh -and $stateName -eq 'FAULT'){'Detenga y reinicie el controlador'}elseif($fresh){[string](Get-Property $script:state phase)}else{'Esperando al controlador'}
    $brightness=Get-Property $script:state brightnessRequested $null
    $script:brightnessValue.Text=if($fresh -and $null -ne $brightness){'{0:0.#} %' -f [double]$brightness}else{'—'}
    $remaining=Get-Property $script:state remainingSeconds $null
    $script:remainingValue.Text=if($fresh -and $stateName -ne 'STOPPED' -and $null -ne $remaining){$span=[TimeSpan]::FromSeconds([Math]::Max(0,[double]$remaining));'{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds}else{'—'}
    $script:progress.Value=if($fresh -and $stateName -ne 'STOPPED'){[int][Math]::Max(0,[Math]::Min(100,[double](Get-Property $script:state progressPercent 0)))}else{0}
    $mode=[string](Get-Property $script:state mode)
    $script:modeLabel.Text=if(-not $fresh){'CONTROL LOCAL · SIN ESTADO RECIENTE'}elseif($stateName -eq 'STOPPED'){'CONTROLADOR DETENIDO'}elseif($stateName -eq 'FAULT'){'CONTROLADOR EN FALLO'}elseif((Get-Property $script:state execution) -eq 'manual-dry'){'SECADO MANUAL · UNA EJECUCIÓN'}elseif($mode -eq 'control'){'CONTROL ACTIVO'}else{'MONITOR · SOLO LECTURA'}
    $script:gateId=[string](Get-Property $script:state operatorGateId)
    $script:operatorBanner.Visible=($fresh -and $stateName -notin @('STOPPED','FAULT') -and $communication -eq 'reachable' -and [bool](Get-Property $script:state operatorPending $false) -and -not [string]::IsNullOrWhiteSpace($script:gateId))
    $script:operatorText.Text='Se recuperó la comunicación. ¿Iniciar preparación o dejar en reposo? '+[string](Get-Property $script:state operatorMessage)
    $lastEvent=Get-Property $script:state lastEvent
    if($lastEvent -is [pscustomobject]){$lastEvent=[string](Get-Property $lastEvent message (Get-Property $lastEvent detail (Get-Property $lastEvent event '')))}
    $script:lastRead.Text=if($fresh){'Última lectura válida: '+[string](Get-Property $script:state lastSuccessfulReadUtc 'sin lectura')+'  ·  '+[string]$lastEvent}else{'El estado no confirma alimentación eléctrica ni el brillo medido de los paneles.'}
}
function Invoke-Tick {
    if($script:tickBusy){return};$script:tickBusy=$true
    try{
        Update-Status;Update-Log
        if(-not $script:smoke){$script:task=Get-ControlTask}
        if($null -ne $script:manualProcess -and $script:manualProcess.HasExited){
            $detail=''
            if([IO.File]::Exists($script:manualError)){
                $errorStream=[IO.File]::OpenRead($script:manualError)
                try{
                    $null=$errorStream.Seek([Math]::Max(0L,$errorStream.Length-4096L),[IO.SeekOrigin]::Begin)
                    $reader=New-Object IO.StreamReader($errorStream)
                    try{$detail=$reader.ReadToEnd().Trim()}finally{$reader.Dispose()}
                }finally{$errorStream.Dispose()}
                [IO.File]::Delete($script:manualError)
            }
            if($script:manualProcess.ExitCode -ne 0){Set-Notice ('El controlador terminó con código {0}. {1} Consulte Registro.' -f $script:manualProcess.ExitCode,$detail) $true}
            $script:manualProcess.Dispose();$script:manualProcess=$null
        }
        if($null -ne $script:installerProcess -and $script:installerProcess.HasExited){
            $exitCode=$script:installerProcess.ExitCode
            $detail=''
            if([IO.File]::Exists($script:installerError)){$detail=[IO.File]::ReadAllText($script:installerError)}
            if($exitCode -ne 0 -and [string]::IsNullOrWhiteSpace($detail) -and [IO.File]::Exists($script:installerOutput)){$detail=[IO.File]::ReadAllText($script:installerOutput)}
            $script:installerProcess.Dispose();$script:installerProcess=$null
            foreach($file in @($script:installerOutput,$script:installerError)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
            if($exitCode -ne 0){Set-Notice ('Inicio automático: error {0}. {1}' -f $exitCode,$detail.Trim()) $true}
            else{
                if($script:installerAction -ne 'remove'){Use-InstalledContext}
                Set-Notice $(if($script:installerAction -eq 'remove'){'Inicio automático retirado. Se conservan los datos y el registro.'}else{'Inicio automático actualizado. Usando la instalación y sus datos; esperando al controlador…'})
            }
        }
                if($null -ne $script:panelPending){
            if((Get-Property $script:state manualPauseRejectedId) -eq $script:panelPauseId){
                $script:panelPending=$null
                if($script:panelResumeTask){$null=Enable-ScheduledTask -TaskName 'NovaStar-VX400-Control' -TaskPath '\' -ErrorAction Stop}
                $script:panelResult.Text='Mando rechazado: la secuencia esta en curso y conserva el control del brillo.'
            }elseif(-not (Test-Running)){
                $pending=$script:panelPending;$script:panelPending=$null
                $path=Join-Path $script:dataDirectory 'manual-pause.request'
                if([IO.File]::Exists($path) -and (Read-VxSharedText $path).Trim() -eq $script:panelPauseId){[IO.File]::Delete($path)}
                Start-PanelCommand $pending
            }elseif([DateTimeOffset]::UtcNow -gt $script:panelPauseDeadline){
                $script:panelPending=$null
                $path=Join-Path $script:dataDirectory 'manual-pause.request'
                if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
                $script:panelResult.Text='No se confirmo la pausa. No se envio el mando; revise Registro.'
            }
        }
        $thermal=$script:stateRecent -and (Get-Property $script:state mode) -eq 'control' -and (Get-Property $script:state state) -in @('DRY','PREHEAT','COOLDOWN')
        $script:panelFields.Enabled=(-not $thermal -and $null -eq $script:panelProcess -and $null -eq $script:panelPending)
        if($null -ne $script:panelProcess -and $script:panelProcess.HasExited){
            $code=$script:panelProcess.ExitCode
            $detail=if([IO.File]::Exists($script:panelError)){[IO.File]::ReadAllText($script:panelError)}else{''}
            $output=if([IO.File]::Exists($script:panelOutput)){[IO.File]::ReadAllText($script:panelOutput)}else{''}
            $script:panelProcess.Dispose();$script:panelProcess=$null
            foreach($path in @($script:panelOutput,$script:panelError)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
            if($code -ne 0){$script:panelResult.Text='Mando sin confirmar. '+$detail.Trim();Set-Notice 'Revise el error del mando manual.' $true}
            else{
                $result=$output|ConvertFrom-Json
                if(-not $result.success){throw 'Resultado manual invalido.'}
                $displayName=@{Normal='Señal de entrada';Blackout='Negro';White='Blanco de prueba'}[[string]$result.display]
                $script:panelResult.Text=('{0} · Brillo solicitado {1:0.#}% confirmado por protocolo. No es una medicion optica.' -f $displayName,[double]$result.brightnessRequestedPercent)
                Set-Notice 'Mando manual confirmado por el VX400.'
            }
        }
        if($null -ne $script:stopDeadline){
            if(-not (Test-Running)){$script:stopDeadline=$null;Set-Notice 'Controlador detenido. Ya puede guardar la configuración.'}
            elseif([DateTimeOffset]::UtcNow -gt $script:stopDeadline){$script:stopDeadline=$null;Set-Notice 'No se confirmó la detención en 10 segundos. Revise Registro antes de guardar; no se forzó el proceso.' $true}
        }
    }catch{Set-Notice ('No se pudo actualizar la ventana: '+$_.Exception.Message) $true}
    finally{$script:tickBusy=$false}
}

$script:form=New-Object Windows.Forms.Form
$script:form.Text='NovaStar VX400 · Control local'
$script:form.ClientSize=New-Object Drawing.Size(1200,860)
$script:form.MinimumSize=New-Object Drawing.Size(1050,700)
$script:form.StartPosition='CenterScreen';$script:form.BackColor=$script:background
$script:form.Font=New-Object Drawing.Font('Segoe UI',10)
$header=New-Object Windows.Forms.Panel;$header.Width=1200;$header.Dock='Top';$header.Height=100;$header.BackColor=$script:blue
$title=New-Label 'VX400  /  Control local' 23 $true;$title.ForeColor=[Drawing.Color]::White;$title.Location=New-Object Drawing.Point(24,13);$header.Controls.Add($title)
$script:endpoint=New-Label ('{0}:{1}  ·  {2}' -f $script:config.deviceAddress,$script:config.tcpPort,$script:config.timeZone) 10
$script:endpoint.ForeColor=[Drawing.Color]::FromArgb(219,233,255);$script:endpoint.Location=New-Object Drawing.Point(27,61);$header.Controls.Add($script:endpoint)
$script:modeLabel=New-Label 'CONTROL LOCAL · SIN ESTADO RECIENTE' 9 $true
$script:modeLabel.ForeColor=[Drawing.Color]::White;$script:modeLabel.AutoSize=$false;$script:modeLabel.TextAlign='MiddleRight';$script:modeLabel.Anchor='Top,Right';$script:modeLabel.Size=New-Object Drawing.Size(410,38);$script:modeLabel.Location=New-Object Drawing.Point(760,25);$header.Controls.Add($script:modeLabel)
$footer=New-Object Windows.Forms.Panel;$footer.Dock='Bottom';$footer.Height=62;$footer.Padding=New-Object Windows.Forms.Padding(20,10,20,8);$footer.BackColor=[Drawing.Color]::White
$save=New-Button 'Guardar configuración' $true;$save.Dock='Right';$save.Width=205;$save.Add_Click({Invoke-UiAction {Save-Configuration}});
$script:notice=New-Label 'Listo. Inicie el monitor para consultar el estado del equipo.' 9
$script:notice.AutoSize=$false;$script:notice.Dock='Fill';$script:notice.Padding=New-Object Windows.Forms.Padding(0,4,14,0);$footer.Controls.Add($script:notice);$footer.Controls.Add($save)
$script:tabs=New-Object Windows.Forms.TabControl;$script:tabs.Dock='Fill';$script:tabs.Padding=New-Object Drawing.Point(23,11)
$script:form.Controls.Add($script:tabs);$script:form.Controls.Add($footer);$script:form.Controls.Add($header)

$statePage=New-Page 'Estado';$statePage.AutoScroll=$true;$stateStack=New-Stack $statePage 6
$stateStack.Dock='Top';$stateStack.Height=610
$actions=New-Flow
$monitor=New-Button 'Iniciar monitor' $true;$monitor.Add_Click({Invoke-UiAction {Start-Controller $false}});$actions.Controls.Add($monitor)
$control=New-Button 'Iniciar control';$control.Add_Click({Invoke-UiAction {Start-Controller $true}});$actions.Controls.Add($control)
$stop=New-Button 'Detener';$stop.Add_Click({Invoke-UiAction {Request-Stop}});$actions.Controls.Add($stop)
$install=New-Button 'Instalar al iniciar Windows';$install.Add_Click({Invoke-UiAction {if(Test-Running){throw 'Detenga el controlador antes de instalar o actualizar el inicio automático.'};Save-Configuration;Begin-Installer -Action install -Control $false}});$actions.Controls.Add($install)
$remove=New-Button 'Quitar inicio automático';$remove.Add_Click({Invoke-UiAction {if(Test-Running){throw 'Pulse Detener y espere antes de quitar el inicio automático.'};Begin-Installer -Action remove}});$actions.Controls.Add($remove)
Add-StackRow $stateStack $actions 0 55
$cards=New-Object Windows.Forms.TableLayoutPanel;$cards.ColumnCount=4;$cards.RowCount=1
foreach($cardIndex in 0..3){$null=$cards.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,25)))}
$cardTitles=@('COMUNICACIÓN','ESTADO / FASE','BRILLO SOLICITADO','TIEMPO RESTANTE')
$values=@()
foreach($cardIndex in 0..3){
    $card=New-Object Windows.Forms.Panel;$card.Width=270;$card.Dock='Fill';$card.BackColor=[Drawing.Color]::White;$card.Margin=New-Object Windows.Forms.Padding(0,5,12,5);$card.Padding=New-Object Windows.Forms.Padding(14)
    $label=New-Label $cardTitles[$cardIndex] 9 $true;$label.Location=New-Object Drawing.Point(14,11);$card.Controls.Add($label)
    $value=New-Label '—' 15 $true;$value.AutoSize=$false;$value.Location=New-Object Drawing.Point(14,38);$value.Size=New-Object Drawing.Size(238,58);$value.Anchor='Top,Left,Right';$card.Controls.Add($value);$values+=,$value
    if($cardIndex -eq 1){$script:phaseDetail=New-Label 'Esperando al controlador' 9;$script:phaseDetail.Location=New-Object Drawing.Point(14,91);$card.Controls.Add($script:phaseDetail)}
    if($cardIndex -eq 2){$hint=New-Label 'No es una medición del panel' 9;$hint.Location=New-Object Drawing.Point(14,91);$card.Controls.Add($hint)}
    $cards.Controls.Add($card,$cardIndex,0)
}
$script:connectionValue=$values[0];$script:phaseValue=$values[1];$script:brightnessValue=$values[2];$script:remainingValue=$values[3]
Add-StackRow $stateStack $cards 1 134
$progressPanel=New-Object Windows.Forms.Panel
$script:progress=New-Object Windows.Forms.ProgressBar;$script:progress.Dock='Top';$script:progress.Height=7;$progressPanel.Controls.Add($script:progress)
$script:lastRead=New-Label '' 9;$script:lastRead.AutoSize=$false;$script:lastRead.Dock='Bottom';$script:lastRead.Height=32;$progressPanel.Controls.Add($script:lastRead)
Add-StackRow $stateStack $progressPanel 2 48
$script:operatorBanner=New-Object Windows.Forms.Panel;$script:operatorBanner.BackColor=[Drawing.Color]::FromArgb(255,244,214);$script:operatorBanner.Visible=$false
$script:operatorText=New-Label '' 10 $true;$script:operatorText.AutoSize=$false;$script:operatorText.Dock='Top';$script:operatorText.Height=43;$script:operatorText.Padding=New-Object Windows.Forms.Padding(12,4,12,0);$script:operatorBanner.Controls.Add($script:operatorText)
$operatorActions=New-Flow;$operatorActions.Dock='Bottom';$operatorActions.Height=49;$operatorActions.Padding=New-Object Windows.Forms.Padding(12,0,0,0)
$restart=New-Button 'Iniciar preparación' $true;$restart.Add_Click({Invoke-UiAction {Send-OperatorAnswer restart}});$operatorActions.Controls.Add($restart)
$hold=New-Button 'Dejar en reposo';$hold.Add_Click({Invoke-UiAction {Send-OperatorAnswer hold}});$operatorActions.Controls.Add($hold);$script:operatorBanner.Controls.Add($operatorActions)
Add-StackRow $stateStack $script:operatorBanner 3 100
$settings=New-Object Windows.Forms.GroupBox;$settings.Text='Conexión y condiciones de control';$settings.Padding=New-Object Windows.Forms.Padding(14,22,14,10)
$settingsFlow=New-Flow;$settingsFlow.Dock='Fill';$settings.Controls.Add($settingsFlow)
$script:address=New-Object Windows.Forms.TextBox;$script:address.Text=$script:config.deviceAddress;$script:address.Width=140
$script:port=New-Number 1 65535 $script:config.tcpPort
$script:poll=New-Number 0.1 60 $script:config.pollIntervalSeconds 1
$script:timeout=New-Number 250 15000 $script:config.timeoutMs
$script:offlineFailures=New-Number 1 20 $script:config.offlineFailures
$script:onlineSuccesses=New-Number 1 20 $script:config.onlineSuccesses
$script:maxGap=New-Number 1 300 $script:config.maximumObservationGapSeconds 1
foreach($pair in @(@('IP del equipo',$script:address),@('Puerto TCP',$script:port),@('Consulta (s)',$script:poll),@('Espera (ms)',$script:timeout),@('Fallos para alerta',$script:offlineFailures),@('Lecturas para recuperar',$script:onlineSuccesses),@('Intervalo máximo (s)',$script:maxGap))){
    $fieldPanel=New-Object Windows.Forms.Panel;$fieldPanel.Size=New-Object Drawing.Size(244,52);$fieldPanel.Margin=New-Object Windows.Forms.Padding(0,0,15,0)
    $fieldLabel=New-Label $pair[0] 9;$fieldLabel.Location=New-Object Drawing.Point(0,0);$fieldPanel.Controls.Add($fieldLabel)
    $pair[1].Location=New-Object Drawing.Point(0,25);$fieldPanel.Controls.Add($pair[1]);$settingsFlow.Controls.Add($fieldPanel)
}
$script:powerVerified=New-Object Windows.Forms.CheckBox;$script:powerVerified.Text='Paneles y VX400 comparten alimentación';$script:powerVerified.AutoSize=$true;$script:powerVerified.Checked=$script:config.panelPowerCouplingVerified;$script:powerVerified.Margin=New-Object Windows.Forms.Padding(0,12,20,5)
$script:startupVerified=New-Object Windows.Forms.CheckBox;$script:startupVerified.Text='Arranque en negro comprobado';$script:startupVerified.AutoSize=$true;$script:startupVerified.Checked=$script:config.startupProtectionVerified;$script:startupVerified.Margin=New-Object Windows.Forms.Padding(0,12,20,5)
$settingsFlow.SetFlowBreak($fieldPanel,$true);$settingsFlow.Controls.Add($script:powerVerified);$settingsFlow.Controls.Add($script:startupVerified)
Add-StackRow $stateStack $settings 4 230
$note=New-Label 'Monitor: consulta sin modificar el VX400. Control: ejecuta las secuencias guardadas. Una pérdida de comunicación no confirma un apagado eléctrico.' 9;$note.AutoSize=$false
Add-StackRow $stateStack $note 5 43

$schedulePage=New-Page 'Horarios';$scheduleStack=New-Stack $schedulePage 5
$scheduleIntro=New-Label 'Encendido / apagado de video y brillo. No corta la alimentación eléctrica.' 15 $true
Add-StackRow $scheduleStack $scheduleIntro 0 45
$dailyFlow=New-Flow
$dailyFlow.Controls.Add((New-Label 'Inicios de secado diario (HH:mm, separados por coma)' 10))
$script:dailyStarts=New-Object Windows.Forms.TextBox;$script:dailyStarts.Text=$script:config.dailyStarts -join ', ';$script:dailyStarts.Width=230;$dailyFlow.Controls.Add($script:dailyStarts)
$dailyFlow.Controls.Add((New-Label 'Zona horaria Windows' 10));$script:zone=New-Object Windows.Forms.TextBox;$script:zone.Text=$script:config.timeZone;$script:zone.Width=230;$dailyFlow.Controls.Add($script:zone)
$script:dailyEnd=New-Label '' 10;$dailyFlow.SetFlowBreak($script:zone,$true);$dailyFlow.Controls.Add($script:dailyEnd)
Add-StackRow $scheduleStack $dailyFlow 1 100
$script:windowGrid=New-Grid;Add-TextColumn $script:windowGrid start 'Inicio de uso (HH:mm)' 125;Add-TextColumn $script:windowGrid end 'Fin de uso (HH:mm)' 125
$dayNames=@('Dom','Lun','Mar','Mié','Jue','Vie','Sáb')
foreach($d in 0..6){$col=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$col.Name='day'+$d;$col.HeaderText=$dayNames[$d];$col.FillWeight=60;$null=$script:windowGrid.Columns.Add($col)}
foreach($window in $script:config.operatingWindows){$row=$script:windowGrid.Rows.Add();$script:windowGrid.Rows[$row].Cells['start'].Value=$window.start;$script:windowGrid.Rows[$row].Cells['end'].Value=$window.end;foreach($d in 0..6){$script:windowGrid.Rows[$row].Cells['day'+$d].Value=($window.days -contains $d)}}
Add-StackRow $scheduleStack $script:windowGrid 2
$windowActions=New-Flow;$addWindow=New-Button 'Añadir horario';$addWindow.Add_Click({$null=$script:windowGrid.Rows.Add('08:00','18:00',$false,$true,$true,$true,$true,$true,$false)});$windowActions.Controls.Add($addWindow)
$removeWindow=New-Button 'Quitar horario';$removeWindow.Add_Click({if($null -ne $script:windowGrid.CurrentRow){$script:windowGrid.Rows.Remove($script:windowGrid.CurrentRow)}});$windowActions.Controls.Add($removeWindow)
Add-StackRow $scheduleStack $windowActions 3 54
$scheduleNote=New-Label 'Marque los días de inicio. Un fin anterior al inicio termina al día siguiente. La preparación comienza antes de cada uso según su duración (4 h por defecto). Sin horarios: solo secado diario y solicitudes puntuales.' 10;$scheduleNote.AutoSize=$false
Add-StackRow $scheduleStack $scheduleNote 4 65

$profilesPage=New-Page 'Secuencias';$profilesStack=New-Stack $profilesPage 6
$profileIntro=New-Label 'Ajuste cada fase de las secuencias' 17 $true;Add-StackRow $profilesStack $profileIntro 0 45
$profileBar=New-Flow
$script:profileChoice=New-Object Windows.Forms.ComboBox;$script:profileChoice.DropDownStyle='DropDownList';$script:profileChoice.Width=245;$null=$script:profileChoice.Items.AddRange(@('Secado diario','Preparación antes del uso','Enfriamiento al terminar'));$script:profileChoice.SelectedIndex=0;$profileBar.Controls.Add($script:profileChoice)
$profileBar.Controls.Add((New-Label 'Reposo (%)' 10));$script:idle=New-Number 0 100 $script:config.idleBrightnessPercent 1;$profileBar.Controls.Add($script:idle)
$profileBar.Controls.Add((New-Label 'Uso (%)' 10));$script:operating=New-Number 0 100 $script:config.operatingBrightnessPercent 1;$profileBar.Controls.Add($script:operating)
$profileBar.Controls.Add((New-Label 'Patrón' 10));$script:pattern=New-Object Windows.Forms.ComboBox;$script:pattern.DropDownStyle='DropDownList';$script:pattern.Width=120;$null=$script:pattern.Items.AddRange(@('White','FromInput'));$script:pattern.SelectedItem=$script:config.conditioningPattern;$profileBar.Controls.Add($script:pattern)
Add-StackRow $profilesStack $profileBar 1 55
$script:phaseGrid=New-Grid
Add-TextColumn $script:phaseGrid name 'Nombre de fase' 180;Add-TextColumn $script:phaseGrid from 'Desde (%)' 80;Add-TextColumn $script:phaseGrid to 'Hasta (%)' 80;Add-TextColumn $script:phaseGrid minutes 'Duración (min)' 100
$contentColumn=New-Object Windows.Forms.DataGridViewComboBoxColumn;$contentColumn.Name='content';$contentColumn.HeaderText='Contenido';$null=$contentColumn.Items.AddRange(@('White','FromInput'));$contentColumn.FillWeight=110;$null=$script:phaseGrid.Columns.Add($contentColumn)
Add-StackRow $profilesStack $script:phaseGrid 2
$phaseActions=New-Flow
$manualDryButton=New-Button 'Iniciar secado manual' $true;$manualDryButton.Add_Click({Invoke-UiAction {Start-Controller $true -ManualDry}});$phaseActions.Controls.Add($manualDryButton)
$addPhase=New-Button 'Añadir fase';$addPhase.Add_Click({$last=if($script:phaseGrid.Rows.Count -gt 0){$script:phaseGrid.Rows[$script:phaseGrid.Rows.Count-1].Cells['to'].Value}else{'10'};$null=$script:phaseGrid.Rows.Add('Nueva fase',$last,$last,'10','FromInput');Update-Totals});$phaseActions.Controls.Add($addPhase)
$removePhase=New-Button 'Quitar fase';$removePhase.Add_Click({if($null -ne $script:phaseGrid.CurrentRow){$script:phaseGrid.Rows.Remove($script:phaseGrid.CurrentRow);Update-Totals}});$phaseActions.Controls.Add($removePhase)
Add-StackRow $profilesStack $phaseActions 3 54
$script:totalLabel=New-Label '' 11 $true;Add-StackRow $profilesStack $script:totalLabel 4 36
$profileNote=New-Label 'Perfil general provisional: origen no certificado. White = blanco interno; FromInput = señal de entrada. Las fases deben ser continuas y coincidir con los niveles de reposo y uso. Puede editar todos los porcentajes y tiempos.' 10;$profileNote.AutoSize=$false
Add-StackRow $profilesStack $profileNote 5 65
$script:profileChoice.Add_SelectedIndexChanged({Invoke-UiAction {Save-ProfileEdits;$key=@('dry','preheat','cooldown')[$script:profileChoice.SelectedIndex];Show-Profile $key}})
$script:phaseGrid.Add_CellValueChanged({if(-not $script:loading){Update-Totals}})
$script:dailyStarts.Add_TextChanged({Update-Totals})

$requestPage=New-Page 'Solicitudes';$requestStack=New-Stack $requestPage 6
$requestIntro=New-Label 'Reserve un uso puntual de la pantalla' 17 $true;Add-StackRow $requestStack $requestIntro 0 45
$script:requestLead=New-Label '' 10;Add-StackRow $requestStack $script:requestLead 1 36
$requestForm=New-Flow
$requestForm.Controls.Add((New-Label 'Nombre' 10));$script:requestTitle=New-Object Windows.Forms.TextBox;$script:requestTitle.Width=230;$script:requestTitle.MaxLength=256;$requestForm.Controls.Add($script:requestTitle)
$requestForm.Controls.Add((New-Label 'Inicio' 10));$script:requestStart=New-Object Windows.Forms.DateTimePicker;$script:requestStart.Format='Custom';$script:requestStart.CustomFormat='dd/MM/yyyy HH:mm';$script:requestStart.Width=180;$requestForm.Controls.Add($script:requestStart)
$requestForm.Controls.Add((New-Label 'Fin' 10));$script:requestEnd=New-Object Windows.Forms.DateTimePicker;$script:requestEnd.Format='Custom';$script:requestEnd.CustomFormat='dd/MM/yyyy HH:mm';$script:requestEnd.Width=180;$requestForm.Controls.Add($script:requestEnd)
$localNow=[TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow,(Get-LocalZone)).DateTime
$script:requestStart.Value=$localNow.AddDays(1);$script:requestEnd.Value=$localNow.AddDays(1).AddHours(2)
Add-StackRow $requestStack $requestForm 2 55
$requestActions=New-Flow;$addRequest=New-Button 'Reservar solicitud' $true;$addRequest.Add_Click({Invoke-UiAction {Change-Requests add}});$requestActions.Controls.Add($addRequest)
$cancelRequest=New-Button 'Cancelar seleccionada';$cancelRequest.Add_Click({Invoke-UiAction {Change-Requests cancel}});$requestActions.Controls.Add($cancelRequest)
$refreshRequests=New-Button 'Actualizar lista';$refreshRequests.Add_Click({Invoke-UiAction {Update-Requests}});$requestActions.Controls.Add($refreshRequests)
Add-StackRow $requestStack $requestActions 3 54
$script:requestGrid=New-Grid;$script:requestGrid.ReadOnly=$true
Add-TextColumn $script:requestGrid id 'ID';$script:requestGrid.Columns['id'].Visible=$false
Add-TextColumn $script:requestGrid title 'Solicitud' 180;Add-TextColumn $script:requestGrid start 'Inicio local' 120;Add-TextColumn $script:requestGrid end 'Fin local' 120;Add-TextColumn $script:requestGrid status 'Estado' 80
Add-StackRow $requestStack $script:requestGrid 4
$requestNote=New-Label 'Las reservas no pueden solaparse. Cancelar conserva el historial. Los horarios semanales se editan en Horarios y no se duplican aquí.' 10;$requestNote.AutoSize=$false;Add-StackRow $requestStack $requestNote 5 50

$manualPage=New-Page 'Control manual';$manualStack=New-Stack $manualPage 5
Add-StackRow $manualStack (New-Label 'Mandos directos de la pantalla' 17 $true) 0 45
$manualHelp=New-Label 'Fuera de una secuencia, un mando pausa el motor y su inicio automatico. Durante secado o preparacion, el brillo queda bloqueado. Los cambios se aplican al VX400 y mantienen la salida elegida hasta el siguiente mando. El modo manual no ejecuta horarios.' 10;$manualHelp.AutoSize=$false
Add-StackRow $manualStack $manualHelp 1 65
$manualFields=New-Flow;$script:panelFields=$manualFields
$manualFields.Controls.Add((New-Label 'Brillo solicitado (%)' 11 $true))
$script:panelBrightness=New-Number 0 100 10 1;$manualFields.Controls.Add($script:panelBrightness)
$manualFields.Controls.Add((New-Label 'Contenido' 11 $true))
$script:panelDisplay=New-Object Windows.Forms.ComboBox;$script:panelDisplay.DropDownStyle='DropDownList';$script:panelDisplay.Width=200;$null=$script:panelDisplay.Items.AddRange(@('Negro','Señal de entrada','Blanco de prueba'));$script:panelDisplay.SelectedIndex=0;$manualFields.Controls.Add($script:panelDisplay)
$applyManual=New-Button 'Aplicar' $true;$applyManual.Add_Click({Invoke-UiAction {Start-PanelCommand (@('Blackout','Normal','White')[$script:panelDisplay.SelectedIndex])}});$manualFields.Controls.Add($applyManual)
$manualFields.SetFlowBreak($applyManual,$true)
foreach($entry in @(@('Mostrar negro','Blackout'),@('Mostrar entrada','Normal'),@('Mostrar blanco','White'))){
    $button=New-Button $entry[0];$button.Tag=$entry[1]
    $button.Add_Click({param($sender,$eventArgs) Invoke-UiAction {Start-PanelCommand ([string]$sender.Tag)}})
    $manualFields.Controls.Add($button)
}
$manualFields.SetFlowBreak($button,$true)
$runDry=New-Button 'Iniciar secado manual' $true;$runDry.Add_Click({Invoke-UiAction {Start-Controller $true -ManualDry}});$manualFields.Controls.Add($runDry)
Add-StackRow $manualStack $manualFields 2 155
$script:panelResult=New-Label 'Sin mandos enviados. El porcentaje mostrado es una consigna, no una medición del panel.' 11;$script:panelResult.AutoSize=$false
Add-StackRow $manualStack $script:panelResult 3 100
$manualDetail=New-Label 'Secado manual: ejecuta una vez el perfil de Secado diario de Secuencias (188 min inicialmente). No modifica reservas ni horarios, no exige declarar alimentación conjunta y no se reinicia tras una desconexión. Mantenga la pantalla bajo supervisión durante la prueba.' 10;$manualDetail.AutoSize=$false
Add-StackRow $manualStack $manualDetail 4

$logPage=New-Page 'Registro';$logStack=New-Stack $logPage 3
$logIntro=New-Label 'Actividad reciente del controlador' 17 $true;Add-StackRow $logStack $logIntro 0 45
$logHint=New-Label 'Últimos 80 eventos. Una alerta de comunicación no permite deducir si el equipo tiene alimentación eléctrica.' 10;Add-StackRow $logStack $logHint 1 35
$script:logBox=New-Object Windows.Forms.TextBox;$script:logBox.Multiline=$true;$script:logBox.ReadOnly=$true;$script:logBox.ScrollBars='Both';$script:logBox.WordWrap=$false;$script:logBox.BackColor=[Drawing.Color]::White;$script:logBox.Font=New-Object Drawing.Font('Consolas',10);$script:logBox.BorderStyle='FixedSingle';Add-StackRow $logStack $script:logBox 2

function Get-ControlCount($Control){$count=1;foreach($child in $Control.Controls){$count+=Get-ControlCount $child};return $count}
function Invoke-GuiSmoke {
    # Only fixture paths are passed here by tests. No timer, task lookup, network, controller or installer.
    $originalConfig=$script:configPath;$originalData=$script:dataDirectory
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('vx400-gui-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($temporary)
    try {
        $script:configPath=Join-Path $temporary 'plan.config.json';$script:dataDirectory=Join-Path $temporary 'data'
        Save-Configuration
        $saved=Read-VxPlanConfig -Path $script:configPath
        if($saved.deviceAddress -ne $script:config.deviceAddress){throw 'Smoke: config save round-trip failed.'}
        $oldMinutes=$script:phaseGrid.Rows[0].Cells['minutes'].Value
        $script:phaseGrid.Rows[0].Cells['minutes'].Value='24.5';$script:poll.Value=1.5
        $windowIndex=$script:windowGrid.Rows.Add('08:00','18:00',$false,$true,$false,$false,$false,$false,$false)
        Save-Configuration
        $edited=Read-VxPlanConfig -Path $script:configPath
        if($edited.pollIntervalSeconds -ne 1.5 -or $edited.profiles.dry[0].minutes -ne 24.5 -or $edited.operatingWindows.Count -ne 1 -or $edited.operatingWindows[0].days[0] -ne 1){throw 'Smoke: editable numeric/profile/weekly config was not preserved.'}
        $script:phaseGrid.Rows[0].Cells['minutes'].Value=$oldMinutes;$script:poll.Value=$saved.pollIntervalSeconds
        $script:windowGrid.Rows.RemoveAt($windowIndex)
        Save-Configuration
        $saved=Read-VxPlanConfig -Path $script:configPath
        $validBytes=[IO.File]::ReadAllBytes($script:configPath)
        $script:address.Text='invalid-address'
        $rejected=$false;try{Save-Configuration}catch{$rejected=$true}
        if(-not $rejected){throw 'Smoke: invalid config was accepted.'}
        if([Convert]::ToBase64String($validBytes) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:configPath))){throw 'Smoke: invalid save changed previous config.'}
        $script:address.Text=$saved.deviceAddress
        $localStart=[TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow.AddSeconds((Get-VxProfileSeconds -Profile $saved.profiles.preheat)+3600),(Get-LocalZone)).DateTime
        $script:requestTitle.Text='Ensayo GUI';$script:requestStart.Value=$localStart;$script:requestEnd.Value=$localStart.AddHours(1)
        Change-Requests add
        $requestsPath=Join-Path $script:dataDirectory 'solicitudes.json'
        $requests=Read-VxRequests -Path $requestsPath
        if($requests.Count -ne 1 -or $requests[0].cancelled){throw 'Smoke: request creation failed.'}
        $beforeOverlap=[IO.File]::ReadAllBytes($requestsPath)
        $rejected=$false;try{Change-Requests add}catch{$rejected=$true}
        if(-not $rejected -or [Convert]::ToBase64String($beforeOverlap) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($requestsPath))){throw 'Smoke: overlap must preserve previous requests.'}
        $script:requestGrid.CurrentCell=$script:requestGrid.Rows[0].Cells['title']
        Change-Requests cancel
        $requests=Read-VxRequests -Path $requestsPath
        if($requests.Count -ne 1 -or -not $requests[0].cancelled){throw 'Smoke: cancellation must preserve history.'}
        # Demonstrate a real pending question using disposable state, then prove stale data never shows connected.
        $null=[IO.Directory]::CreateDirectory($script:dataDirectory)
        $statePath=Join-Path $script:dataDirectory 'estado.json'
        $state=[pscustomobject]@{schemaVersion=1;mode='monitor';state='WAIT_OPERATOR';communication='reachable';brightnessRequested=10;phase='Esperando al operador';progressPercent=0;remainingSeconds=0;updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');lastSuccessfulReadUtc=[DateTimeOffset]::UtcNow.ToString('o');lastEvent='Consulta pendiente';operatorPending=$true;operatorGateId=[guid]::NewGuid().ToString();operatorMessage='Datos de demostración: elija cómo continuar.'}
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json))
        Update-Status
        if(-not $script:operatorBanner.Visible -and $script:form.Visible){throw 'Smoke: operator banner missing.'}
        $state.updatedUtc=[DateTimeOffset]::UtcNow.AddSeconds(-11).ToString('o');[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json));Update-Status
        if($script:connectionValue.Text -ne 'Sin datos recientes'){throw 'Smoke: stale status claimed communication.'}
        $state.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json));Update-Status
        $state.mode='control';$state.state='DRY'
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json));Invoke-Tick
        if($script:panelFields.Enabled){throw 'Smoke: manual brightness enabled during dry.'}
        $state.mode='monitor';$state.state='WAIT_OPERATOR'
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json));Invoke-Tick
        if(-not $script:panelFields.Enabled){throw 'Smoke: manual fields remain blocked outside dry.'}
        $count=Get-ControlCount $script:form
        if($script:tabs.TabPages.Count -ne 6 -or $count -lt 65){throw 'Smoke: expected tabs and controls missing.'}
        $script:form.Show();[Windows.Forms.Application]::DoEvents()
        if(-not $script:operatorBanner.Visible){throw 'Smoke: reachable operator question not displayed.'}
        $script:tabs.SelectedTab=$manualPage
        $applyManual.PerformClick()
        if($script:notice.Text -ne 'Mandos deshabilitados en SmokeTest.'){throw ('Smoke: Apply handler failed: '+$script:notice.Text)}
        $button.PerformClick()
        if($script:notice.Text -ne 'Mandos deshabilitados en SmokeTest.'){throw ('Smoke: direct button handler failed: '+$script:notice.Text)}
        $runDry.PerformClick()
        if($script:notice.Text -ne 'Controlador deshabilitado en SmokeTest.'){throw ('Smoke: manual dry handler failed: '+$script:notice.Text)}
        Set-Notice 'Vista de prueba. No se enviaron mandos.'

        if(-not [string]::IsNullOrWhiteSpace($ScreenshotPath)){
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($ScreenshotPath))
            for($tabIndex=0;$tabIndex -lt $script:tabs.TabPages.Count;$tabIndex++){
                $script:tabs.SelectedIndex=$tabIndex;$script:form.PerformLayout();[Windows.Forms.Application]::DoEvents()
                $bitmap=New-Object Drawing.Bitmap($script:form.Width,$script:form.Height)
                try{$script:form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save((Join-Path $ScreenshotPath ('{0:00}-{1}.png' -f $tabIndex,@('Estado','Horarios','Secuencias','Solicitudes','Control-manual','Registro')[$tabIndex])),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
            }
        }
        Write-Output ('GUI smoke passed: 6 tabs, {0} controls, config round-trip + invalid-save preservation + requests CRUD/overlap + stale-state gate.' -f $count)
    }finally{$script:form.Close();$script:configPath=$originalConfig;$script:dataDirectory=$originalData;if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
}

$timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({Invoke-Tick})
$script:form.Add_FormClosed({$timer.Stop()})
try{
    Show-Profile dry
    if($script:smoke){Invoke-GuiSmoke}
    else{
        Set-GuiMutex $script:dataDirectory
        Invoke-UiAction {Update-Requests}
        Invoke-Tick;$timer.Start();$null=$script:form.ShowDialog()
    }
}finally{
    $timer.Stop();$timer.Dispose();$script:form.Dispose()
    if($script:ownsMutex){$script:mutex.ReleaseMutex()}
    if($null -ne $script:mutex){$script:mutex.Dispose()}
    # Closing the window leaves the explicitly started background controller running.
    if($null -ne $script:manualProcess){$script:manualProcess.Dispose()}
    if($null -ne $script:panelProcess){$script:panelProcess.Dispose()}
    if($null -ne $script:installerProcess){$script:installerProcess.Dispose()}
}
