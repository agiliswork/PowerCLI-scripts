# Dmitriy
# Version: 4
# Date: 2023-Dec

$throttleLimit = 6
$timeoutMilliseconds = 90000


# Setting PowerCLI configurations
try {
    if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) { 
        Import-Module VMware.VimAutomation.Core 
        Start-Sleep -Milliseconds 500
    }
    else
    {
        Write-Host "VMware.VimAutomation.Core - Done!" -ForegroundColor Green
    }

    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -ErrorAction Stop | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "Failed to set PowerCLI configurations: $_"
}

function ConnectToVCenter([string] $vCenterServerName) {
    $vCenterId = $null
	if([string]::IsNullOrWhiteSpace($vCenterServerName)) {
        Write-Warning 'ConnectToVCenter: vCenterServerName is NULL on Empty'
    }

    try {
        [string]$vmCommands = Get-Command -Module VMware.VimAutomation.Core | 
                                Select-Object -ExpandProperty Name | 
                                Where-Object {$_ -eq 'Connect-VIServer'}
        if([string]::IsNullOrEmpty($vmCommands))
        {
            Import-Module VMware.VimAutomation.Core | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        Write-Error "ConnectToVCenter: Not found Connect-VIServer: $_"
        return $null
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
        Write-Error "ConnectToVCenter: Connect-VIServer $vCenterServerName Error: $_"
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
        Start-Sleep -Milliseconds 3000
        Write-Host -ForegroundColor Green "DisconnectFromVCenter: Connected closed" $vCenterId
    }
    catch {
        Write-Warning "DisconnectFromVCenter: Warning for vCenterId=$vCenterId, $_"
    }
}

$ScriptGetVMKernelLogs = {
    Param (
    $vCenterId,
    $datacenter,
    $cluster,
    $esxi,
    [DateTime] $dateBegin,
    [DateTime] $dateEnd,
    [string] $notMatch = ""
    )


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
    
    function ConvertVMKernelLogsToCsvRowArr([array] $logVmKernelArr, [string] $vCenterName, [string]$datacenterName, [string]$clusterName, [string]$esxiName) {
        $csvRowArr = @()
        [Regex]$rx = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.\d{3}Z'
        $dt = Get-Date
        foreach($logVmKernel in $logVmKernelArr){
            if($rx.IsMatch($logVmKernel)) {
                [DateTime] $dt = $rx.Match($logVmKernel).Value 
            }
            $csvRowArr +=  [pscustomobject]@{
                    vCenterServer = $vCenterName
                    Datacenter    = $datacenterName
                    Cluster       = $clusterName
                    Host          = $esxiName
                    DateTime      = $dt
                    Message       = $logVmKernel -replace '^.*WARNING:(\s*)'                               
            }
        }
        return $csvRowArr
    }

    function GetVMKernelLogs($vCenterId,$datacenter,$cluster,$esxi,[DateTime] $dateBegin,[DateTime] $dateEnd,[string] $notMatch='') {
        $logVmKernelArr = @()
        $datacenterName = ''
        $clusterName = ''
        $esxiName = ''     

        if($null -eq $vCenterId) {
            Write-Warning 'GetVMKernelLogs: vCenterId is NULL'
            return $logVmKernelArr
        }

        if($null -eq $datacenter)
        {
            Write-Warning 'GetVMKernelLogs: datacenter is NULL'
            $datacenterName = ''
        }
        elseif($datacenter -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.DatacenterImpl] -or $datacenter -is [VMware.Vim.Datacenter]) {
            $datacenterName = $datacenter.Name
        }
        elseif ($esxi -is [string]) {
            $datacenterName = $datacenter      
        }
        
        if($null -eq $cluster)
        {
            Write-Warning 'GetVMKernelLogs: cluster is NULL'
            $clusterName = ''
        }
        if($cluster -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl] -or $cluster -is [VMware.Vim.ClusterComputeResource]) {
            $clusterName = $cluster.Name
        }
        elseif ($esxi -is [string]) {
            $clusterName = $cluster      
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

        try {
            [string]$vmCommands = Get-Command -Module VMware.VimAutomation.Core | Select-Object -ExpandProperty Name | Where-Object {$_ -eq 'Get-Log'}
            if([string]::IsNullOrEmpty($vmCommands))
            {
                Import-Module VMware.VimAutomation.Core | Out-Null
                Start-Sleep -Milliseconds 500
            }
        }
        catch {
            Write-Error "GetVMKernelLogs: Not found Get-Log: $_"
        }

        $matchDateString = GetMatchDate $dateBegin $dateEnd 
        Write-Verbose "      GetVMKernelLogs: $esxiName  Match Date String: $matchDateString" -Verbose
        $totalWorkTime = [math]::Round((Measure-Command {
           
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
        }).TotalSeconds, 2)
        Write-Verbose "GetVMKernelLogs: $esxiName TotalWorkTime: $totalWorkTime, LogVmKernelArr: $($logVmKernelArr.Count)" -Verbose
        return (ConvertVMKernelLogsToCsvRowArr $logVmKernelArr  $vCenterId.Name $datacenterName $clusterName $esxiName)
    }

    GetVMKernelLogs $vCenterId $datacenter $cluster $esxi $dateBegin $dateEnd
}

function OpenRunspacePool() {
    $runspacePool = $null
    try{
        $runspacePool = [runspacefactory]::CreateRunspacePool(
                            1,
                            $throttleLimit, 
                            [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault(), 
                            $host 
                            )
        $runspacePool.ApartmentState = "MTA"
        $runspacePool.Open()
        Write-Verbose "OpenRunspacePool: runspacePool Opened" -Verbose
    }
    catch {
        Write-Warning "OpenRunspacePool $_"
    }
    return $runspacePool
}

function WaitAndProcessTasks {
    param(
        [array] $runspaceTaskArr,
        [int] $timeoutMilliseconds,
        [ValidateSet("WaitOne", "WaitAny", "WaitCompleted", "WaitTime")]
        [string]$waitType = "WaitCompleted",
        [int] $sleep = 1000
    )

    $resultArr = @()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timeRemaining = $timeoutMilliseconds
    if($WaitType -eq "WaitOne") {
        foreach ($task in $runspaceTaskArr)        {
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            if($timeRemaining -gt 0)
            {
                Write-Verbose "WaitAndProcessTasks: WaitOne TimeRemaining $timeRemaining" -Verbose
                $task.AsyncResult.AsyncWaitHandle.WaitOne($timeRemaining,$true) | Out-Null
            }
        }
    }
    elseif($WaitType -eq "WaitAny")
    {           
        $allAsyncResult = $runspaceTaskArr | 
                            Where-Object {$_.AsyncResult.IsCompleted -contains $false} |
                            Select-Object -ExpandProperty AsyncResult | 
                            Select-Object -ExpandProperty AsyncWaitHandle
        while ($allAsyncResult.Count -gt 0 -and $timeRemaining -gt 0) 
        {
            Write-Verbose "WaitAndProcessTasks: WaitAny TimeRemaining $timeRemaining" -Verbose
            $index = [System.Threading.WaitHandle]::WaitAny($allAsyncResult,$timeRemaining,$true)
	        if ($index -eq [System.Threading.WaitHandle]::WaitTimeout) {
                Write-Verbose "WaitAndProcessTasks: WaitAny Timed out $timeRemaining" -Verbose 
                break
            }
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds $sleep
            $allAsyncResult = $runspaceTaskArr | 
                        Where-Object {$_.AsyncResult.IsCompleted -contains $false} |
                        Select-Object -ExpandProperty AsyncResult | 
                        Select-Object -ExpandProperty AsyncWaitHandle
        }
    } 
    elseif($WaitType -eq "WaitCompleted")
    {           
       while ($runspaceTaskArr.AsyncResult.IsCompleted -contains $false -and $timeRemaining -gt 0) {
            Write-Verbose "WaitAndProcessTasks: WaitCompleted TimeRemaining $timeRemaining" -Verbose
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds $sleep
        } 
    }
    else
    {
       while ($timeRemaining -gt 0) {
            Write-Verbose "WaitAndProcessTasks: RemainingTime  $timeRemaining" -Verbose
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds $sleep
        }   
    }

    foreach ($task in $runspaceTaskArr) {  
        if ($task.AsyncResult.IsCompleted) {
            $resultArr += $task.PowerShell.EndInvoke($task.AsyncResult)
            Write-Host (Get-Date).ToString() "Done!  TaskId: $($task.TaskId)" -ForegroundColor Green
        }
        else {
            Write-Host (Get-Date).ToString() "False! TaskId: $($task.TaskId)" -ForegroundColor Yellow
            $task.PowerShell.Stop() | Out-Null
        }
        $task.TaskId = $taskId
        $task.AsyncResult = $null
        $task.PowerShell.Dispose()
    }
    return $resultArr
}

function CloseRunspacePool($runspacePool) {
    if($null -eq $runspacePool) {
        Write-Warning 'CloseRunspacePool: runspacePool is NULL'
        return
    }
    try {
        $runspacePool.Close()
        $runspacePool.Dispose()
        Write-Verbose "CloseRunspacePool: runspacePool closed" -Verbose
    }
    catch {
        Write-Warning "CloseRunspacePool: $_"
    }
}

function CreateTask([string] $taskId, [scriptblock]$scriptBlock,[array]$argumentArr) {
    if($null -eq $scriptBlock) {
        Write-Warning 'CreateTask: scriptBlock is NULL'
        return $null
    }
    if($null -eq $scriptBlock) {
        Write-Warning 'CreateTask: ArgumentArr is NULL'
        return $null
    }
    try {
        $powerShellTask = [powershell]::Create() 
        $powerShellTask.RunspacePool = $runspacePool
        $powerShellTask.AddScript($scriptBlock).AddParameters($argumentArr) | Out-Null
        $runspaceTask = [PSCustomObject]@{ 
            TaskId      = $taskId
            PowerShell  = $powerShellTask
            AsyncResult = $powerShellTask.BeginInvoke() 
        }
        return $runspaceTask 
    }
    catch {
        Write-Warning "CreateTask: $_"
        return $null
    }
}

function RetrieveAndProcessLogs($vCenterId,[DateTime] $dateBegin,[DateTime] $dateEnd) {

    $csvLogVmKernelArr = @()
    $datacenterArr = @()
    $runspaceTaskArr = @()

    if($null -eq $vCenterId) {
        Write-Warning 'RetrieveAndProcessLogs: vCenterId is NULL'
        return $csvLogVmKernelArr
    }

    try {
        $runspacePool = OpenRunspacePool 
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

                    $powerShellTaskCustomObject = CreateTask $esxi.Name $ScriptGetVMKernelLogs @($vCenterId,$datacenter,$clusterEsxi,$esxi,$dateBegin,$dateEnd,"")
                    if($powerShellTaskCustomObject) {
                        $runspaceTaskArr += $powerShellTaskCustomObject
                    }
                }
            }

            $standaloneEsxiArr =  Get-View -Server $vCenterId -ViewType HostSystem -Property Name,Parent  -SearchRoot $datacenter.MoRef  | Where-Object { $_.Parent -notmatch '^Cluster.*' }
            foreach ($standaloneEsxi in $standaloneEsxiArr) {
                Write-Host " -- Standalone ESXi Name: "$standaloneEsxi.Name
                $powerShellTaskCustomObject = CreateTask $standaloneEsxi.Name $ScriptGetVMKernelLogs @($vCenterId,$datacenter,$null,$standaloneEsxi,$dateBegin,$dateEnd,"")
                if($powerShellTaskCustomObject) {
                    $runspaceTaskArr += $powerShellTaskCustomObject
                }
            }  
        }


        $totalWorkTime = [math]::Round((Measure-Command {
            $csvLogVmKernelArr = WaitAndProcessTasks  $runspaceTaskArr $timeoutMilliseconds 
        }).TotalSeconds, 2)

        Write-Verbose "RetrieveAndProcessLogs: TOTAL WorkTime = $totalWorkTime" -Verbose
    }
    catch {
        Write-Error "RetrieveAndProcessLogs: $_"
    }
    finally {
        $runspaceTaskArr.Clear()
        CloseRunspacePool $runspacePool
    }

    return $csvLogVmKernelArr
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
    $csvLogVmKernelArr = @()
    $reportFileName = [System.Environment]::GetFolderPath("Desktop") + "\$vCenterServerName-LOGS-$((Get-Date).ToString("dd-MM-yyyy")).csv" 

    $vCenterId = ConnectToVCenter $vCenterServerName
    if ($null -eq $vCenterId) {
        Write-Error 'vCenter:' $vCenterServerName ', Connection status = false' -ForegroundColor Red
        continue
    } 

    # Retrieve logs and process
    $csvLogVmKernelArr = RetrieveAndProcessLogs $vCenterId $dateBegin $dateEnd
    # Generate report
    GenerateCsvReport $csvLogVmKernelArr $reportFileName
    # Disconnect from vCenter
    DisconnectFromVCenter $vCenterId
}



