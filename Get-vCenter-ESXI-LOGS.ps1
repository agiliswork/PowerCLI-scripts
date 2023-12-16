# Dmitriy
# Version: 2
# Date: 2023-Dec

# Setting PowerCLI configurations
try {
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -ErrorAction Stop | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "Failed to set PowerCLI configurations"
    Write-Error $_
}

function ConnectToVCenter([string] $vCenterServerName) {
    $vCenterId = $null
	if([string]::IsNullOrWhiteSpace($vCenterServerName)) {
        Write-Warning 'ConnectToVCenter: vCenterServerName is NULL on Empty'
    }
    $currentConnection = $global:DefaultVIServer | Where-Object { $_.Name -eq $vCenterServerName }
    if($currentConnection.IsConnected) {
        Write-Host "ConnectToVCenter: Used Connection from global:DefaultVIServers" $global:DefaultVIServer.Name  -ForegroundColor Green
        return $currentConnection
    }

    try {
        $vCenterId =  Connect-VIServer $vCenterServerName  -ErrorAction Stop -WarningAction SilentlyContinue 
    }
    catch {
        Write-Error "ConnectToVCenter: Connect-VIServer $vCenterServerName Error"
        Write-Error $_
        return $null
    }

    if($null -eq $vCenterId) {
    	Write-Warning 'ConnectToVCenter: vCenterId is NULL'
	    return $null
    }

	if($vCenterId.IsConnected) {
		Write-Host 'ConnectToVCenter:' $vCenterId.Name  ', Connection status:'$vCenterId.IsConnected  ', Type: ' $vCenterId.GetType().FullName -ForegroundColor Green
		return $vCenterId
	}
	else {
		Write-Warning 'ConnectToVCenter: Not Connected'
		return $null
	}
}

function DisconnectFromVCenter($vCenterId) {
    if($null -eq $vCenterId) {
        Write-Warning 'DisconnectFromVCenter: vCenterId is NULL'
        return
    }
    try {
        Disconnect-VIServer $vCenterId -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null 
        Start-Sleep -Seconds 5
        Write-Host -ForegroundColor Green "DisconnectFromVCenter: Connected closed" $vCenterId
    }
    catch {
        Write-Warning "DisconnectFromVCenter: Warning for vCenterId=$vCenterId"
        Write-Warning $_
    }
}


function GetMatchDate([DateTime] $dateBegin,[DateTime] $dateEnd) {
    $matchDateArr = @()

    if($null -eq $dateBegin) { 
        Write-Warning 'GetMatchDate: dateBegin is NULL setup default value -1 day'
        $dateBegin =  (Get-Date).AddDays(-1)
    }
    if($null -eq $dateEnd) {
        Write-Warning 'GetMatchDate: dateEnd is NULL setup default value current day'
        $dateEnd =  (Get-Date)
    }

    if($dateBegin -lt $dateEnd) {
        $matchDate = $dateBegin
        while($matchDate -le $dateEnd) {
            $matchDateArr += $matchDate.ToString("yyyy-MM-dd")
            $matchDate = $matchDate.AddDays(1)
        }
    }
    elseif($dateEnd -lt $dateBegin) {
        $matchDate = $dateEnd
        while($matchDate -le $dateBegin) {
            $matchDateArr += $matchDate.ToString("yyyy-MM-dd")
            $matchDate = $matchDate.AddDays(1)
        }
    }
    else {   
        $matchDateArr += $dateBegin.ToString("yyyy-MM-dd") 
    }
    return ($matchDateArr -join '|')
}
    
function GetVMKernelLogs($vCenterId,$esxi,[DateTime] $dateBegin,[DateTime] $dateEnd,[string] $notMatch='') {
    $logVmKernelArr = @()
    $esxiName = ''     

    if($null -eq $vCenterId) {
        Write-Warning 'GetVMKernelLogs: vCenterId is NULL'
        return $logVmKernelArr
    }

    if($null -eq $esxi) {
        Write-Warning 'GetVMKernelLogs: esxi is NULL'
        return $logVmKernelArr
    }

    if($esxi -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost] -or $esxi -is [VMware.Vim.HostSystem]) {
        $esxiName = $esxi.Name
    }
    elseif ($esxi -is [string]) {
        $esxiName = $esxi      
    }
	else {
        Write-Warning 'GetVMKernelLogs: esxi not supported data type:' $esxi.GetType().FullName
        return $logVmKernelArr
    }

    $matchDateString = GetMatchDate $dateBegin $dateEnd 
    Write-Host 'matchDateString ' $matchDateString -ForegroundColor Gray
    try {
        if([string]::IsNullOrEmpty($notMatch)) {
            $logVmKernelArr = Get-Log -Server $vCenterId  -VMHost $esxiName -Key "vmkernel"   | 
                        Select-Object -ExpandProperty Entries  | 
                        Where-Object {$_ -match "($matchDateString).*(WARNING|ERROR).*"} 
        }
        else {
            $logVmKernelArr = Get-Log -Server $vCenterId -VMHost $esxiName -Key "vmkernel"   | 
                        Select-Object -ExpandProperty Entries  | 
                        Where-Object {$_ -match "($matchDateString).*(WARNING|ERROR).*"} | 
                        Where-Object {$_ -notmatch $notMatch}             
        }         
    }
    catch {
        Write-Warning "GetVMKernelLogs: ESXi $esxiName not get vmkernel $_"
    }
    Write-Host 'logVmKernelArr ' $logVmKernelArr.Count -ForegroundColor Gray
    return $logVmKernelArr
}


function ConvertVMKernelLogToCsvRow([string] $logVmKernel, [string] $vCenterName, [string]$datacenterName, [string]$clusterName, [string]$esxiName) {
    [Regex]$rx = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.\d{3}Z'
    $dt = Get-Date
    if($rx.IsMatch($logVmKernel)) {
        [DateTime] $dt = $rx.Match($logVmKernel).Value 
    }
    $csvRow =  [pscustomobject]@{
            vCenterServer = $vCenterName
            Datacenter    = $datacenterName
            Cluster       = $clusterName
            Host          = $esxiName
            DateTime      = $dt
            Message       = $logVmKernel -replace '^.*WARNING:(\s*)'                               
    }
    return $csvRow
}

function RetrieveAndProcessLogs($vCenterId,[DateTime] $dateBegin,[DateTime] $dateEnd) {
    $csvRowArr = @()
    if($null -eq $vCenterId) {
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

            foreach ($esxi in $esxiArr) {
                $logVmKernelArr = @()
                Write-Host "     ++  ESXI: "$esxi.Name  
                $totalWorkTime = [math]::round((Measure-Command { 
                    $logVmKernelArr = GetVMKernelLogs $vCenterId $esxi $dateBegin  $dateEnd 
                    foreach($logVmKernel in $logVmKernelArr)
                    {
                        $csvRowArr +=  ConvertVMKernelLogToCsvRow $logVmKernel $WorkTime $vCenterId.Name $datacenter.Name $clusterEsxi.Name $esxi.Name 
                    } 
                }).TotalSeconds, 2) 
                Write-Host $esxi.Name "TOTAL WorkTime = $totalWorkTime" -ForegroundColor Gray
            }
        }

        $standaloneEsxiArr =  Get-View -Server $vCenterId -ViewType HostSystem -Property Name,Parent  -SearchRoot $datacenter.MoRef  | Where-Object { $_.Parent -notmatch '^Cluster.*' }
        foreach ($standaloneEsxi in $standaloneEsxiArr) {
            Write-Host " -- Standalone ESXi Name: "$standaloneEsxi.Name
                $totalWorkTime = [math]::round((Measure-Command { 
                    $logVmKernelArr = GetVMKernelLogs $vCenterId $standaloneEsxi $dateBegin  $dateEnd 
                    foreach($logVmKernel in $logVmKernelArr)
                    {
                        $csvRowArr +=  ConvertVMKernelLogToCsvRow $logVmKernel $WorkTime $vCenterId.Name $datacenter.Name $clusterEsxi.Name $standaloneEsxi.Name 
                    } 
                }).TotalSeconds, 2) 
                Write-Host $standaloneEsxi.Name "TOTAL WorkTime = $totalWorkTime" -ForegroundColor Gray
            }  
        }

    return $csvRowArr
}

function GenerateCsvReport($RowArr,[string] $FileName) {
    if($null -eq $RowArr) {
        Write-Warning 'GenerateCsvReport: RowArr is NULL'
        return
    }
    if([string]::IsNullOrEmpty($FileName)) {
        Write-Warning 'GenerateCsvReport: FileName is NULL'
        return
    }
    if($RowArr -is [array]) {
        if($RowArr.Count -gt 0) {
            $RowArr | Export-Csv -Path $FileName -NoTypeInformation -Force
        }
        else {
            Write-Warning 'GenerateCsvReport: RowArr.Count = 0'
        }
    }
    else {
       
        Write-Warning 'GenerateCsvReport: Not array'  $RowArr.GetType().Name
        $RowArr | Export-Csv -Path $FileName -NoTypeInformation -Force
    }
}

# Main script logic

$dateBegin =  (Get-Date).AddDays(-2)
$dateEnd =  (Get-Date)

$inputVC = Read-Host 'Please enter vCenter Name (if multiple separate with a comma)'
$vCenterServerNameArr = ($inputVC.Split(',')).Trim()

foreach($vCenterServerName in $vCenterServerNameArr) 
{
    $csvRowArr = @()
    $reportFileName = [System.Environment]::GetFolderPath("Desktop") + "\$vCenterServerName-LOGS-$((Get-Date).ToString("dd-MM-yyyy")).csv" 
    $vCenterId = ConnectToVCenter $vCenterServerName

    if ($null -eq $vCenterId) {
        Write-Error 'vCenter:' $vCenterServerName ', Connection status = false' -ForegroundColor Red
        continue
    } 

    # Retrieve logs and process
    $csvRowArr += RetrieveAndProcessLogs $vCenterId $dateBegin $dateEnd
    # Generate report
    GenerateCsvReport $csvRowArr $reportFileName
    # Disconnect from vCenter
    DisconnectFromVCenter $vCenterId

}



