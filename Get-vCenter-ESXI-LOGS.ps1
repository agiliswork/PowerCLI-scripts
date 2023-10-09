# Dmitriy
# Version 2023-Oct



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
    $clusterArr = Get-Cluster  -Server $vCenterId | Sort-Object Name
    foreach($esxCluster in $clusterArr)
    {
        $csvRowArr = @()
        $esxiArr = @()
        Write-Host " -- Cluster: "$esxCluster.Name  
        $reportFileName = [System.Environment]::GetFolderPath("Desktop") + "\$env:USERDOMAIN-$($esxCluster.Name)-LOGS-$((Get-Date).ToString("dd-MM-yyyy")).csv" 
        $esxiArr = $esxCluster  | Get-VMHost | Sort-Object Name
        foreach($esxi in $esxiArr)
        {
            Write-Host "     ++  ESXI: "$esxi.Name   
            
            $dateStringFilterOld =  (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
            $dateStringFilterCurrent =  (Get-Date).ToString("yyyy-MM-dd")
            $logVmKernelArr = @()
            try
            {
                $logVmKernelArr = Get-Log  -VMHost $esxi.Name -Key "vmkernel"   | 
                              Select -ExpandProperty Entries  | 
                              ?{$_ -match "($dateStringFilterOld|$dateStringFilterCurrent).*(WARNING|ERROR).*"} #| ?{$_ -notmatch 'device mpx.vmhba32:C0:T0:L0'} 
                Write-Host "ESXi vmkernel count:"$logVmKernelArr.Count
            }
            catch
            {
                Write-Error "ESXi Get vmkernel Error"
                $logVmKernelArr = @()
            }

            foreach($logVmKernel in $logVmKernelArr)
            {
                [regex]$rx = "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.\d{3}Z"
                if($rx.IsMatch($logVmKernel))
                {
                    [datetime] $dt = $rx.Match($logVmKernel).Value
                    $csvRowArr +=  [pscustomobject]@{
                                Host       =  $esxi.Name
                                DateTime = $dt
                                Message = $logVmKernel -replace '^.*WARNING:(\s*)'
                                }
                }
            }
        }
        $csvRowArr | Export-Csv -Path $reportFileName -NoTypeInformation -Force #-Delimiter ';' 
        $csvRowArr | Format-Table * -AutoSize 
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


