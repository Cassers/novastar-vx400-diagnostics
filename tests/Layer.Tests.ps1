#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Vx.Layers.psm1') -Force
$script:passed=0
function Assert-True($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:passed++}
function Reject([scriptblock]$Action,[string]$Label){$failed=$false;try{& $Action}catch{$failed=$true};Assert-True $failed $Label}
function Block([int]$Number){
    [byte[]]$block=New-Object byte[] 48
    $block[1]=[byte]$Number;$block[4]=0x11;$block[47]=100
    foreach($pair in @(@(5,10),@(9,20),@(13,1920),@(17,1080))){[Array]::Copy([BitConverter]::GetBytes([uint32]$pair[1]),0,$block,$pair[0],4)}
    for($i=21;$i -le 46;$i++){$block[$i]=[byte]($i+128)}
    return ,$block
}
$blocks=@((Block 0),(Block 1),(Block 2))
$names=@('Main','PIP1','PIP2')
$views=@();for($i=0;$i -lt 3;$i++){$views+=ConvertFrom-VxLayerBlock $blocks[$i] $names[$i]}
for($i=0;$i -lt 3;$i++){
    $read=New-VxLayerReadRequest -Layer $names[$i] -Sequence 5
    Assert-True ([BitConverter]::ToUInt32($read,12) -eq (0x13020010+48*$i) -and [BitConverter]::ToUInt16($read,16) -eq 48 -and $read[10] -eq 0) 'Read mapped full block'
    $patched=New-VxLayerPatch $blocks[$i] $names[$i] ([pscustomobject]@{enabled=$true}) $views
    Assert-True ($patched[0] -eq 1 -and $blocks[$i][0] -eq 0) 'Switch changed on clone'
    Assert-True ([Convert]::ToBase64String($patched[1..47]) -ceq [Convert]::ToBase64String($blocks[$i][1..47])) 'Every non-switch byte preserved including reserved'
    $write=New-VxLayerWriteRequest -Layer $names[$i] -Block $patched -Sequence 7
    Assert-True ($write.Length -eq 68 -and $write[10] -eq 1 -and $write[3] -eq 7 -and [Convert]::ToBase64String($write[18..65]) -ceq [Convert]::ToBase64String($patched)) 'Full48 write with exact payload'
    [int]$sum=0x5555;foreach($value in $write[2..65]){$sum+=$value}
    Assert-True ([BitConverter]::ToUInt16($write,66) -eq ($sum -band 65535)) 'Write checksum'
}
Assert-True ($views[0].input -eq 'HDMI1' -and $views[0].width -eq 1920 -and $views[0].priority -eq 1 -and $views[0].opacity -eq 100) 'Decoded layer view'
foreach($bad in @($null,@(),[pscustomobject]@{},[pscustomobject]@{enabled=1},[pscustomobject]@{enabled='false'},[pscustomobject]@{enabled=$true;input='SDI'},[pscustomobject]@{Enabled=$true})){
    Reject {Assert-VxLayerChanges $bad} 'Strict enabled boolean schema'
}
Reject {ConvertFrom-VxLayerBlock $blocks[0][0..46] Main} 'No truncated defaults'
foreach($pair in @(@(0,2),@(1,1),@(3,3),@(47,101))){$bad=[byte[]]$blocks[0].Clone();$bad[$pair[0]]=$pair[1];Reject {ConvertFrom-VxLayerBlock $bad Main} 'Malformed layer rejected'}
$unknown=[byte[]]$blocks[0].Clone();$unknown[2]=99
$disabled=New-VxLayerPatch $unknown Main ([pscustomobject]@{enabled=$false}) $views
Assert-True ([Convert]::ToBase64String($disabled) -ceq [Convert]::ToBase64String($unknown)) 'Unknown source preserved when disabling'
Reject {New-VxLayerPatch $unknown Main ([pscustomobject]@{enabled=$true}) $views} 'Unknown source cannot be enabled'
$zero=[byte[]]$blocks[0].Clone();$zero[13]=0;$zero[14]=0
$null=ConvertFrom-VxLayerBlock $zero Main
Reject {New-VxLayerPatch $zero Main ([pscustomobject]@{enabled=$true}) $views} 'Disabled zero geometry can read but not enable'
$mosaic=[byte[]]$blocks[0].Clone();$mosaic[0]=1;$mosaic[2]=6;$mosaic[4]=224
$mosaicViews=@((ConvertFrom-VxLayerBlock $mosaic Main),$views[1],$views[2])
Reject {New-VxLayerPatch $blocks[1] PIP1 ([pscustomobject]@{enabled=$true}) $mosaicViews} 'Active mosaic prevents enabling PIP'
$mosaicViews[0].enabled=$false
Reject {New-VxLayerPatch $blocks[1] PIP1 ([pscustomobject]@{enabled=$true}) $mosaicViews} 'Disabled Main mosaic still prevents enabling PIP'
$activeViews=@($views[0],[pscustomobject]@{layer='PIP1';enabled=$true;input='HDMI1'},$views[2])
Reject {New-VxLayerPatch $mosaic Main ([pscustomobject]@{enabled=$true}) $activeViews} 'Active PIP prevents enabling mosaic'
$null=New-VxLayerPatch $mosaic Main ([pscustomobject]@{enabled=$false}) $activeViews
Assert-True $true 'Mosaic conflict can be resolved by disabling'
Write-Host "PASS: $script:passed layer assertions"
