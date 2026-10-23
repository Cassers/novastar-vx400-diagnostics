#requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1')

function Get-VxLayerNumber([string]$Layer) {
    switch -CaseSensitive ($Layer) { 'Main' {return 0} 'PIP1' {return 1} 'PIP2' {return 2} default {throw 'Layer must be Main, PIP1 or PIP2.'} }
}
function Get-VxLayerAddress([string]$Layer) { return [uint32](0x13020010+0x30*(Get-VxLayerNumber $Layer)) }
function ConvertFrom-VxLayerBlock {
    param([Parameter(Mandatory)][byte[]]$Block,[Parameter(Mandatory)][string]$Layer)
    $number=Get-VxLayerNumber $Layer
    if($Block.Length -ne 48){throw 'Layer read unavailable: expected exactly 48 bytes; no defaults inferred.'}
    if($Block[0] -gt 1 -or $Block[1] -ne $number -or $Block[3] -gt 2 -or $Block[47] -gt 100){throw 'Invalid layer switch, WindowNo, priority or opacity.'}
    $source=('{0}:{1}' -f $Block[2],$Block[4])
    $inputName=switch($source){'0:17'{'HDMI1'} '1:18'{'HDMI2'} '2:0'{'DVI'} '3:48'{'SDI'} '4:233'{'OPT1'} '5:234'{'OPT2'} '6:224'{'MOSAIC'} default {'UNKNOWN('+ $source + ')'}}
    $geometry=@()
    foreach($offset in @(5,9,13,17)){
        $value=[BitConverter]::ToUInt32($Block,$offset)
        if($value -gt 32768){throw 'Layer geometry outside supported safety bound 0..32768.'}
        $geometry+= [int]$value
    }
    return [pscustomobject]@{layer=$Layer;enabled=($Block[0] -eq 1);input=$inputName;x=$geometry[0];y=$geometry[1];width=$geometry[2];height=$geometry[3];priority=([int]$Block[3]+1);opacity=[int]$Block[47]}
}
function Assert-VxLayerChanges($Changes) {
    if($Changes -isnot [pscustomobject]){throw 'Layer changes must be a JSON object containing only enabled boolean.'}
    $fields=@($Changes.PSObject.Properties.Name)
    if($fields.Count -ne 1 -or $fields[0] -cne 'enabled' -or $Changes.enabled -isnot [bool]){throw 'Layer changes must contain exactly enabled boolean; no other controls allowed.'}
}
function New-VxLayerPatch {
    param([Parameter(Mandatory)][byte[]]$Block,[Parameter(Mandatory)][string]$Layer,[Parameter(Mandatory)]$Changes,[Parameter(Mandatory)][object[]]$Layers)
    Assert-VxLayerChanges $Changes
    $current=ConvertFrom-VxLayerBlock -Block $Block -Layer $Layer
    if($Changes.enabled){
        if($current.width -lt 1 -or $current.height -lt 1 -or $current.input.StartsWith('UNKNOWN') -or ($Layer -ne 'Main' -and $current.input -eq 'MOSAIC')){throw 'Cannot enable layer with unavailable source or unusable dimensions.'}
        if($Layers.Count -ne 3 -or @($Layers | Where-Object {$_.layer -ceq 'Main'}).Count -ne 1){throw 'Fresh complete three-layer snapshot required.'}
        $main=@($Layers | Where-Object {$_.layer -ceq 'Main'})[0]
        if(($Layer -ne 'Main' -and $main.input -eq 'MOSAIC') -or
           ($Layer -eq 'Main' -and $current.input -eq 'MOSAIC' -and @($Layers | Where-Object {$_.layer -ne 'Main' -and $_.enabled}).Count -gt 0)){throw 'MOSAIC Main and active PIP layers cannot coexist.'}
    }
    # VX600 protocol 3.4.2 full block: modify only Switch; all other bytes stay device-derived.
    [byte[]]$patched=$Block.Clone();$patched[0]=[byte][int]$Changes.enabled
    return ,$patched
}
function New-VxLayerReadRequest([string]$Layer,[byte]$Sequence=0) {
    New-VxReadRequest -Address (Get-VxLayerAddress $Layer) -Length 48 -Sequence $Sequence
}
function New-VxLayerWriteRequest([string]$Layer,[byte[]]$Block,[byte]$Sequence=0) {
    $null=ConvertFrom-VxLayerBlock -Block $Block -Layer $Layer
    New-VxFrame -Address (Get-VxLayerAddress $Layer) -Length 48 -Sequence $Sequence -Command 1 -Payload $Block
}
Export-ModuleMember -Function Get-VxLayerNumber,Get-VxLayerAddress,ConvertFrom-VxLayerBlock,Assert-VxLayerChanges,New-VxLayerPatch,New-VxLayerReadRequest,New-VxLayerWriteRequest

# Protocol 3.4.2 geometry equivalent of SCALE. No undocumented native SCALE address.
function New-VxLayerScalePatch {
    param([Parameter(Mandatory)][object[]]$Snapshot,[Parameter(Mandatory)][int]$CanvasWidth,[Parameter(Mandatory)][int]$CanvasHeight)
    if($CanvasWidth -lt 1 -or $CanvasWidth -gt 32768 -or $CanvasHeight -lt 1 -or $CanvasHeight -gt 32768){throw 'SCALE requires known configured canvas dimensions 1..32768.'}
    if($Snapshot.Count -ne 3){throw 'SCALE requires fresh complete three-layer snapshot.'}
    $views=@();$names=@()
    foreach($item in $Snapshot){$names+=$item.layer;$views+=ConvertFrom-VxLayerBlock -Block $item.block -Layer $item.layer}
    if(@($names|Select-Object -Unique).Count -ne 3){throw 'Duplicate layer snapshot.'}
    $active=@($views|Where-Object {$_.enabled})
    if($active.Count -eq 0){throw 'No active layer to SCALE.'}
    # VX600 protocol V1.1 Appendix V: raw 0 bottom, 1 middle, 2 top.
    # https://www.ezledvisual.com/storage/file/20240926/1727345641282825.pdf (p15)
    $lowest=($active|Measure-Object -Property priority -Minimum).Minimum
    $targets=@($active|Where-Object {$_.priority -eq $lowest})
    if($targets.Count -ne 1){throw 'Ambiguous lowest active layer priority.'}
    $target=$targets[0]
    if($target.input.StartsWith('UNKNOWN') -or $target.input -eq 'MOSAIC'){throw 'SCALE source unsupported.'}
    $source=@($Snapshot|Where-Object {$_.layer -ceq $target.layer})[0]
    [byte[]]$patched=$source.block.Clone()
    [Array]::Copy([BitConverter]::GetBytes([uint32]0),0,$patched,5,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]0),0,$patched,9,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$CanvasWidth),0,$patched,13,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$CanvasHeight),0,$patched,17,4)
    [pscustomobject]@{layer=$target.layer;block=$patched}
}
Export-ModuleMember -Function New-VxLayerScalePatch
