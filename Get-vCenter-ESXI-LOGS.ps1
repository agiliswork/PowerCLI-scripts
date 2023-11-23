# Dmitriy
# Version 2023-Nov


# Setting PowerCLI configurations
try 
{
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -ErrorAction Stop | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
}
catch 
{
    Write-Error "Failed to set PowerCLI configurations"
    Write-Error $_.Exception.Message
}

function ConnectToVCenter([string] $vCenterServerName) 
{
    $vCenterId = $null
	if([string]::IsNullOrWhiteSpace($vCenterServerName))
    {
        Write-Warning 'ConnectToVCenter: vCenterServerName is NULL on Empty'
    }
    try
    {
        $vCenterId =  Connect-VIServer $vCenterServerName -Credential (Get-Credential)  -ErrorAction Stop -WarningAction SilentlyContinue 
    }
    catch
    {
        Write-Error "ConnectToVCenter: Connect-VIServer $vCenterServerName Error"
        Write-Error $_.Exception.Message
        return $null
    }
    if($null -ne $vCenterId)
    {
		if($vCenterId.IsConnected)
		{
			Write-Host 'ConnectToVCenter:' $vCenterId.Name  ', Connection status:'$vCenterId.IsConnected  ', Type: ' $vCenterId.GetType().Name -ForegroundColor Green
			return $vCenterId
		}
		else
		{
			Write-Warning 'ConnectToVCenter: Not Connected'
			return $null
		}
    }
    else
    {
	    Write-Warning 'ConnectToVCenter: vCenterId is NULL'
	    return $null
    }
}

function DisconnectFromVCenter($vCenterId) 
{
    if($null -eq $vCenterId)
    {
        Write-Warning 'DisconnectFromVCenter: vCenterId is NULL'
        return
    }
    try
    {
        Disconnect-VIServer $vCenterId -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null 
        Start-Sleep -Seconds 5
        Write-Host -ForegroundColor Green "DisconnectFromVCenter: Connected closed" $vCenterId
    }
    catch
    {
        Write-Warning "DisconnectFromVCenter: Warning for vCenterId=$vCenterId"
        Write-Warning $_.Exception.Message
    }
}

function GetVMKernelLogs($esxi,$dateBegin,$dateEnd,$notMatch = "")
{
    $logVmKernelArr = @()
    $esxiName = ''
    if($null -eq $esxi)
    {
        Write-Warning 'GetVMKernelLogs: esxi is NULL'
        return $logVmKernelArr
    }
    if($null -eq $dateBegin)
    { 
        Write-Warning 'GetVMKernelLogs: dateBegin is NULL setup default value -1 day'
        $dateBegin =  (Get-Date).AddDays(-1)
    }
    if($null -eq $dateEnd)
    {
        Write-Warning 'GetVMKernelLogs: dateEnd is NULL setup default value current day'
        $dateEnd =  (Get-Date)
    }

    if($esxi -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost] -or $esxi -is [VMware.Vim.HostSystem] )
    {
        $esxiName = $esxi.Name
    }
    elseif ($esxi -is [string])                                                
    {
        $esxiName = $esxi
    }
	else   
    {
        Write-Error 'GetVMKernelLogs: esxi not supported data type'
        return $logVmKernelArr
    }

    $matchDateArr = @()
    if($dateBegin -lt $dateEnd)
    {
        $matchDate = $dateBegin
        while($matchDate -le $dateEnd)
        {
            $matchDateArr += $matchDate.ToString("yyyy-MM-dd")
            $matchDate = $matchDate.AddDays(1)
        }
    }
    elseif($dateEnd -lt $dateBegin)
    {
        $matchDate = $dateEnd
        while($matchDate -le $dateBegin)
        {
            $matchDateArr += $matchDate.ToString("yyyy-MM-dd")
            $matchDate = $matchDate.AddDays(1)
        }
    }
    else
    {   
        $matchDateArr += $dateBegin.ToString("yyyy-MM-dd") 
    }

    $matchDateString = $matchDateArr -join '|'
    try
    {
        if([string]::IsNullOrEmpty($notMatch))
        {
            $logVmKernelArr = Get-Log  -VMHost $esxiName -Key "vmkernel"   | 
                        Select -ExpandProperty Entries  | 
                        ?{$_ -match "($matchDateString).*(WARNING|ERROR).*"} 
        }
        else
        {
            $logVmKernelArr = Get-Log  -VMHost $esxiName -Key "vmkernel"   | 
                        Select -ExpandProperty Entries  | 
                        ?{$_ -match "($matchDateString).*(WARNING|ERROR).*"} | 
                        ?{$_ -notmatch $notMatch}             
        }
        Write-Host "GetVMKernelLogs: ESXi $esxiName vmkernel count:"$logVmKernelArr.Count
    }
    catch
    {
        Write-Warning "GetVMKernelLogs: ESXi $esxiName not get vmkernel"
        Write-Warning $_.Exception.Message
        return $logVmKernelArr
    }

    return $logVmKernelArr
}

function ConvertVMKernelLogToCsvRow($logVmKernel,$workTime, $vCenterName,$datacenterName,$clusterName,$esxiName)
{
    [Regex]$rx = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.\d{3}Z'
    $dt = Get-Date
    if($rx.IsMatch($logVmKernel))
    {
        [DateTime] $dt = $rx.Match($logVmKernel).Value 
    }
    $csvRow =  [pscustomobject]@{
            WorkTime      = $workTime
            vCenterServer = $vCenterName
            Datacenter    = $datacenterName
            Cluster       = $clusterName
            Host          = $esxiName
            DateTime      = $dt
            Message       = $logVmKernel -replace '^.*WARNING:(\s*)'                               
    }
    return $csvRow
}

function RetrieveAndProcessLogs($vCenterId,$dateBegin,$dateEnd) 
{

    $csvRowArr = @()
    $datacenterArr = @()

    if($null -eq $vCenterId)
    {
        Write-Warning 'RetrieveAndProcessLogs: vCenterId is NULL'
        return $csvRowArr
    }

    $datacenterArr = Get-View -Server $vCenterId -ViewType Datacenter -Property Name -ErrorAction Stop

    foreach ($datacenter in $datacenterArr) 
    {
        Write-Host " DC: " $datacenter.Name  
        $clusterEsxiArr = @()
        $standaloneEsxiArr = @()
        $clusterEsxiArr = Get-View -Server $vCenterId -ViewType ClusterComputeResource -Property Name -SearchRoot $datacenter.MoRef 

        foreach ($clusterEsxi in $clusterEsxiArr) 
        {
            Write-Host " -- Cluster: "$clusterEsxi.Name  

            $esxiArr = @()
            $esxiArr = Get-View -Server $vCenterId -ViewType HostSystem -Property Name -SearchRoot $clusterEsxi.MoRef
            foreach ($esxi in $esxiArr) 
            {
                Write-Host "     ++  ESXI: "$esxi.Name   
                $WorkTime = [math]::round((Measure-Command { $logVmKernelArr = GetVMKernelLogs $esxi  $dateBegin  $dateEnd }).TotalSeconds, 2) 
                foreach($logVmKernel in $logVmKernelArr)
                {
                    $csvRowArr +=  ConvertVMKernelLogToCsvRow $logVmKernel $WorkTime $vCenterId.Name $datacenter.Name $clusterEsxi.Name $esxi.Name 
                }
            }
        }

        $standaloneEsxiArr =  Get-View -Server $vCenterId -ViewType HostSystem -Property Name,Parent  -SearchRoot $datacenter.MoRef  | Where-Object { $_.Parent -notmatch '^Cluster.*' }
        foreach ($standaloneEsxi in $standaloneEsxiArr) 
        {
            Write-Host " -- Standalone ESXi Name: "$standaloneEsxi.Name
            $WorkTime = [math]::round((Measure-Command { $logVmKernelArr = GetVMKernelLogs $standaloneEsxi  $dateBegin  $dateEnd }).TotalSeconds, 2)        
            foreach($logVmKernel in $logVmKernelArr)
            {
                $csvRowArr +=  ConvertVMKernelLogToCsvRow $logVmKernel $WorkTime $vCenterId.Name $datacenter.Name 'NoCluster' $standaloneEsxi.Name 
            }
        }
    }

    return $csvRowArr
}

function GenerateCsvReport($RowArr,[String] $FileName)
{
    if($null -eq $RowArr)
    {
        Write-Warning 'GenerateCsvReport: RowArr is NULL'
        return
    }
    if([string]::IsNullOrEmpty($FileName))
    {
        Write-Warning 'GenerateCsvReport: FileName is NULL'
        return
    }
    if($RowArr -is [array])
    {
        if($RowArr.Count -gt 0)
        {
            $RowArr | Export-Csv -Path $FileName -NoTypeInformation -Force
        }
        else
        {
            Write-Warning 'GenerateCsvReport: RowArr.Count = 0'
        }
    }
    else
    {
       
        Write-Warning 'GenerateCsvReport: Not array'  $RowArr.GetType().Name
    }
}



# Main script logic

$dateBegin =  (Get-Date).AddDays(-5)
$dateEnd =  (Get-Date)
$reportFileName = [System.Environment]::GetFolderPath("Desktop") + "\$env:USERDOMAIN-LOGS-$((Get-Date).ToString("dd-MM-yyyy")).csv" 
$inputVC = Read-Host 'Please enter vCenter Name (if multiple separate with a comma)'
$vCenterServerNameArr = ($inputVC.Split(',')).Trim()

foreach($vCenterServerName in $vCenterServerNameArr) 
{
    $vCenterId = ConnectToVCenter $vCenterServerName
    
    if ($vCenterId -ne $null) 
	{
        # Retrieve logs and process
        $csvRowArr = RetrieveAndProcessLogs $vCenterId $dateBegin $dateEnd
        
        # Generate report
        GenerateCsvReport $csvRowArr $reportFileName
    } 
    else 
	{
        Write-Error 'vCenter:' $vCenterServerName ', Connection status = false' -ForegroundColor Red
        continue
    }
    
    # Disconnect from vCenter
    DisconnectFromVCenter $vCenterId
}
