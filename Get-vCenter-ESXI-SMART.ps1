# Dmitriy
# Version 2023-Oct

$reportFileName = [System.Environment]::GetFolderPath("Desktop") + "\$env:USERDOMAIN-SMART-$((Get-Date).ToString("dd-MM-yyyy")).csv" 
$csvParamArr = @('ClusterName','ESXiName','CanonicalName','CapacityGB','Model','Revision')
$smartParamArr = @('Read Error Count','Write Error Count','Drive Temperature','Reallocated Sector Count','Media Wearout Indicator','Health Status')
$csvRowArr = @()
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null 
$inputVC = Read-Host "Please enter vCenter Name(if multiple separate with a comma)"
$vCenterServerNameArr =  ($inputVC.Split(',')).Trim()

foreach($vCenterServerName in $vCenterServerNameArr )
{
    $vCenterId = $null
    $clusterArr = @()
    Write-Host "VC: "$vCenterServerName  ", Domain: " $env:USERDOMAIN
    $vCenterId =  Connect-VIServer $vCenterServerName -Credential (Get-Credential)  -ErrorAction Stop -WarningAction SilentlyContinue 
    if($null -ne $vCenterId)
    {
        Write-Host 'vCenter:' $vCenterId.Name  ', Connection status:'$vCenterId.IsConnected  -ForegroundColor Green
    }
    else
    {
        Write-Error 'vCenter:' $vCenterServerName  ', Connection status = false' -ForegroundColor Red
        continue
    }
    $clusterArr = Get-Cluster -Server $vCenterId | Sort-Object Name
    foreach($esxCluster in $clusterArr)
    {
        $esxiArr = @()
        Write-Host " -- Cluster: "$esxCluster.Name  

        $esxiArr = $esxCluster  | Get-VMHost | Sort-Object Name
        foreach($esxi in $esxiArr)
        {
            $esxiCli = $null
            $esxiDiskArr = @()
            Write-Host "     ++  ESXI: "$esxi.Name   
            
            $esxiDiskArr = Get-ScsiLun -VmHost $esxi.Name | Where {$_.LunType -eq 'disk' -and $_.ExtensionData.OperationalState -eq 'ok' -and $_.CanonicalName -notlike 'mpx.*' -and $_.Model -notlike 'PERC*'}
            try
            {
                $esxiCli = Get-EsxCli -V2 -VMHost $esxi.Name
            }
            catch
            {
                Write-Warning "Get-EsxCli Warning for ESXI=$($esxi.Name)"
                Write-Warning $_
                $esxiCli = $null
            }

            foreach($esxiDisk in $esxiDiskArr)
            {
                $smartArr = @()
                $canonicalName = $esxiDisk.CanonicalName
                $csvRow = ""| Select-Object ($csvParamArr + $smartParamArr)
                $csvRow.ClusterName = $esxCluster.Name
                $csvRow.ESXiName  = $esxi.Name
                $csvRow.CanonicalName  = $canonicalName
                $csvRow.CapacityGB = $esxiDisk.CapacityGB 
                $csvRow.Model = $esxiDisk.Model 
                $csvRow.Revision = $esxiDisk.ExtensionData.Revision 
 
                if($esxiCli)
                {
                    try
                    {
                        $smartArr = $esxiCli.storage.core.device.smart.get.Invoke(@{devicename=$canonicalName})
                    }
                    catch
                    {
                        Write-Host "Get SMART Warning for devicename=$canonicalName"
                        Write-Warning $_
                        $smartArr = @()
                    }
                }
                foreach($smart in $smartArr)
                {
                    foreach($smartParam in $smartParamArr)   
                    {
                        if($smart.Parameter -eq $smartParam)
                        {
                            try
                            {
                                $csvRow.$smartParam = $smart.Value
                            }
                            catch
                            {
                                $csvRow.$smartParam = 'NA'
                            }
                            break
                        }
                    }
                }
                $csvRowArr += $csvRow

            }
        }
    }


    if($null -eq $vCenterId)
    {
        Write-Warning "CloseConnection vCenterId is null"
        continue
    }
    try
    {
        Disconnect-VIServer $vCenterId -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null 
        Start-Sleep -Seconds 5
        Write-Host -ForegroundColor Green "CloseConnection: Connected closed" $vCenterId
    }
    catch
    {
        Write-Warning "CloseConnection Warning for vCenterId=$vCenterId"
        Write-Warning $_
    }
}


$csvRowArr | Export-Csv -Path $reportFileName -NoTypeInformation -Force #-Delimiter ';' 
$csvRowArr | Format-Table * -AutoSize 