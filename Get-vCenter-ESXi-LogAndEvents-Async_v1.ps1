# Dmitriy
# Version: 1
# Date: 2024-Jan

$throttleLimit = 6
$timeoutMilliseconds = 90000
$waitMetod = "WaitCompleted"  # or "WaitAny" or "WaitOne"

# Setting PowerCLI configurations
try {
    if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) { 
        Import-Module VMware.VimAutomation.Core -Global
        Start-Sleep -Milliseconds 1000
        Write-Host "VMware.VimAutomation.Core - Imported!" -ForegroundColor Green
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
            Import-Module VMware.VimAutomation.Core -Global | Out-Null
            Start-Sleep -Milliseconds 1000
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
        Start-Sleep -Milliseconds 1000
        Write-Host -ForegroundColor Green "DisconnectFromVCenter: Connected closed" $vCenterId
    }
    catch {
        Write-Warning "DisconnectFromVCenter: Warning for vCenterId=$vCenterId, $_"
    }
}

$ScriptEsxiLogsAndEvents = {
    Param (
    $vCenterId,
    $datacenter,
    $cluster,
    $esxi,
    [DateTime] $dateBegin,
    [DateTime] $dateEnd,
    [string] $notMatch = ""
    )

     function CheckPowerCliFunc([string] $funcName)
     {
         [string] $foundName = ''
         $count = 1
         Do {
            try {
                [string]$foundName = Get-Command -Module VMware.VimAutomation.Core | 
                                        Select-Object -ExpandProperty Name | 
                                        Where-Object {$_ -eq $funcName}
                if([string]::IsNullOrEmpty($foundName)) {
                    Import-Module VMware.VimAutomation.Core | Out-Null
                    Start-Sleep -Milliseconds 1000
                }
                else {
                    Write-Verbose "   ---   CheckPowerCliFunc:  $count : $funcName" -Verbose
                }
            }
            catch {
                Write-Error "CheckPowerCliFunc: Not found $count : $funcName : $_"
            }
            $count++
         }
         While([string]::IsNullOrEmpty($foundName) -or $count -eq 4)
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
    
    function ConvertVMKernelLogsToCsvRowArr([array] $logVmKernelArr, [string] $vCenterName, [string]$datacenterName, [string]$clusterName, [string]$esxiName) {
        $csvRowArr = @()
        [Regex]$rx = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z'
        
        foreach($logVmKernel in $logVmKernelArr){
            if($rx.IsMatch($logVmKernel)) {
                [DateTime] $dt = $rx.Match($logVmKernel).Value 
            }
            else {
                $dt = Get-Date
            }
            if($logVmKernel -match 'WARNING') {
                $color = 'yellow'
                $type = 'warning'
                $VmKernelLine = ($logVmKernel -replace '^.*WARNING:(\s*)').Trim()
            }
            else {
                $color = 'red'
                $type = 'error'
                $VmKernelLine = ($logVmKernel -replace $rx.Match($logVmKernel).Value).Trim()
            }  
            $csvRowArr +=  [pscustomobject]@{
                    Color         = $color
                    Type          = $type
                    vCenterServer = $vCenterName
                    Datacenter    = $datacenterName
                    Cluster       = $clusterName
                    Host          = $esxiName
                    DateTime      = $dt
                    Message       = $VmKernelLine                               
            }
        }
        return $csvRowArr
    }

    function GetVMKernelLogs($vCenterId,[string] $esxiName,[DateTime] $dateBegin,[DateTime] $dateEnd,[string] $notMatch='') {
        $logVmKernelArr = @()
        CheckPowerCliFunc 'Get-Log'
        $matchDateString = GetMatchDate $dateBegin $dateEnd 
        Write-Verbose "      GetVMKernelLogs: $esxiName  Match Date String: $matchDateString" -Verbose

        try {
            if([string]::IsNullOrEmpty($notMatch)) {
                $logVmKernelArr = Get-Log  -Server $vCenterId  -VMHost $esxiName -Key "vmkernel"   | 
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
        return $logVmKernelArr
    }

    function GetEvents($vCenterId, [string]$datacenterName, [string]$clusterName,[string] $esxiName,[DateTime] $dateBegin,[DateTime] $dateEnd) {
        $eventsArr = @()
        $selectedEventsArr = @()

        $vCenterName = $vCenterId.Name
        CheckPowerCliFunc 'Get-VIEvent'

        if($null -eq $dateBegin) { 
            Write-Warning 'GetEvents: dateBegin is NULL setup default value -1 day'
            $dateBegin =  (Get-Date).AddDays(-1)
        }
        if($null -eq $dateEnd) {
            Write-Warning 'GetEvents: dateEnd is NULL setup default value current day'
            $dateEnd =  (Get-Date)
        }

        try {
            if($dateEnd -lt $dateBegin) {
                $eventsArr = Get-VIEvent -Server $vCenterId -Start $dateEnd -Finish $dateBegin -Entity $esxiName    
            }
            else {   
                $eventsArr = Get-VIEvent -Server $vCenterId -Start $dateBegin -Finish $dateEnd -Entity $esxiName
            }                 
        }
        catch {
            Write-Warning "GetEvents: ESXi $esxiName not get vmkernel $_"
        }
        foreach($eve in $eventsArr){
            if($eve.Severity -eq 'error')
            {
                $selectedEventsArr += [pscustomobject]@{
                    Color         = 'red'
                    Type          = 'error'
                    vCenterServer = $vCenterName
                    Datacenter    = $datacenterName
                    Cluster       = $clusterName
                    Host          = $esxiName
                    DateTime      = $eve.CreatedTime
                    Message       = $eve.FullFormattedMessage                               
                }
            }
            elseif($eve.Severity -eq 'warning')
            {
                $selectedEventsArr += [pscustomobject]@{
                    Color         = 'yellow'
                    Type          = 'warning'
                    vCenterServer = $vCenterName
                    Datacenter    = $datacenterName
                    Cluster       = $clusterName
                    Host          = $esxiName
                    DateTime      = $eve.CreatedTime
                    Message       = $eve.FullFormattedMessage
                }
            }
            elseif($eve.Severity -eq 'info' -or [string]::IsNullOrEmpty($eve.Severity))
            {
                if($eve.GetType().FullName -match 'Error|Failed|Conflict|Lost|Crashed' )
                {
                    $selectedEventsArr += [pscustomobject]@{
                        Color         = 'red'
                        Type          = 'error'
                        vCenterServer = $vCenterName
                        Datacenter    = $datacenterName
                        Cluster       = $clusterName
                        Host          = $esxiName
                        DateTime      = $eve.CreatedTime
                        Message       = $eve.FullFormattedMessage                               
                    }
                }
                elseif($eve.GetType().FullName -match 'Warning|Removed|Disconnected|Destroyed|Emigrating|Resources')
                {
                    $selectedEventsArr += [pscustomobject]@{
                        Color         = 'yellow'
                        Type          = 'warning'
                        vCenterServer = $vCenterName
                        Datacenter    = $datacenterName
                        Cluster       = $clusterName
                        Host          = $esxiName
                        DateTime      = $eve.CreatedTime
                        Message       = $eve.FullFormattedMessage                               
                    }
                }
                elseif($eve.GetType().FullName -match 'Alarm')
                {
                    $selectedEventsArr += [pscustomobject]@{
                        Color         = 'orange'
                        Type          = 'alarm'
                        vCenterServer = $vCenterName
                        Datacenter    = $datacenterName
                        Cluster       = $clusterName
                        Host          = $esxiName
                        DateTime      = $eve.CreatedTime
                        Message       = $eve.FullFormattedMessage                               
                    }
                }
                elseif($eve.GetType().FullName -match 'Task')
                {
                    #Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage -ForegroundColor Green
                }
                elseif($eve.GetType().FullName -match'User|Session')
                {
                   if($eve.FullFormattedMessage -notmatch '127.0.0.1')
                   {
                        #Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage   $eve.GetType().FullName -ForegroundColor Green
                   }
                   else
                   {
                        #Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage   -ForegroundColor Gray
                   }
                }
                else
                {
                    if($eve.FullFormattedMessage  -match "Alarm")
                    {
                        $selectedEventsArr += [pscustomobject]@{
                            Color         = 'orange'
                            Type          = 'alarm'
                            vCenterServer = $vCenterName
                            Datacenter    = $datacenterName
                            Cluster       = $clusterName
                            Host          = $esxiName
                            DateTime      = $eve.CreatedTime
                            Message       = $eve.FullFormattedMessage                               
                        }
                    }
                    elseif($eve.FullFormattedMessage  -match "Error|Failed|Failure|failover|lost access|is down|changed to Unreachable|changed from .+ to '?red'?")
                    {
                        $selectedEventsArr += [pscustomobject]@{
                            Color         = 'red'
                            Type          = 'error'
                            vCenterServer = $vCenterName
                            Datacenter    = $datacenterName
                            Cluster       = $clusterName
                            Host          = $esxiName
                            DateTime      = $eve.CreatedTime
                            Message       = $eve.FullFormattedMessage                               
                        }
                    }
                    elseif($eve.FullFormattedMessage  -match "changed from .+ to '?(yellow|skipped)'?")
                    {
                        $selectedEventsArr += [pscustomobject]@{
                            Color         = 'yellow'
                            Type          = 'warning'
                            vCenterServer = $vCenterName
                            Datacenter    = $datacenterName
                            Cluster       = $clusterName
                            Host          = $esxiName
                            DateTime      = $eve.CreatedTime
                            Message       = $eve.FullFormattedMessage                               
                        }
                    }
                    elseif($eve.FullFormattedMessage  -match 'Firewall')
                    {
                       # Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage   -ForegroundColor Gray
                    }
                    elseif($eve.FullFormattedMessage  -match 'vSAN')
                    {
                       # Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage   -ForegroundColor Gray
                    }
                    elseif($eve.FullFormattedMessage  -match "restored on|linkstate is up|changed from .+ to '?green'?")
                    {
                       # Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage   -ForegroundColor Green
                    }
                    else
                    {
                       # Write-Host  'FullFormattedMessage: ' $eve.FullFormattedMessage   $eve.GetType().FullName
                    }
                }
             }
        }
        return $selectedEventsArr
    }

    function GetEsxiLogsAndEvents($vCenterId,$datacenter,$cluster,$esxi,[DateTime] $dateBegin,[DateTime] $dateEnd,[string] $notMatch='') {
        $logVmKernelArr = @()
        $csvVmKernelRowArr = @()
        $csvEventsRowArr = @()

        $datacenterName = ''
        $clusterName = ''
        $esxiName = ''     

        if($null -eq $vCenterId) {
            Write-Warning 'GetEsxiLogsAndEvents: vCenterId is NULL'
            return $logVmKernelArr
        }

        if($null -eq $esxi) {
            Write-Warning 'GetEsxiLogsAndEvents: esxi is NULL'
            return $logVmKernelArr
        }

        if($null -eq $datacenter)
        {
            Write-Warning 'GetEsxiLogsAndEvents: datacenter is NULL'
            $datacenterName = ''
        }
        elseif($datacenter -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.DatacenterImpl] -or $datacenter -is [VMware.Vim.Datacenter]) {
            $datacenterName = $datacenter.Name
        }
        elseif ($esxi -is [string]) {
            $datacenterName = $datacenter      
        }
        
        if($null -eq $cluster) {
            Write-Warning 'GetEsxiLogsAndEvents: cluster is NULL'
            $clusterName = ''
        }
        elseif($cluster -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl] -or $cluster -is [VMware.Vim.ClusterComputeResource]) {
            $clusterName = $cluster.Name
        }
        elseif ($esxi -is [string]) {
            $clusterName = $cluster      
        }


        if($esxi -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost] -or $esxi -is [VMware.Vim.HostSystem]) {
            $esxiName = $esxi.Name
        }
        elseif ($esxi -is [string]) {
            $esxiName = $esxi      
        }
	    else {
            Write-Warning 'GetEsxiLogsAndEvents: esxi not supported data type:' $esxi.GetType().FullName
            return $logVmKernelArr
        }


        $totalWorkTime = [math]::Round((Measure-Command {
           $logVmKernelArr = GetVMKernelLogs $vCenterId $esxiName $dateBegin $dateEnd $notMatch
           $csvVmKernelRowArr = ConvertVMKernelLogsToCsvRowArr $logVmKernelArr  $vCenterId.Name $datacenterName $clusterName $esxiName
        }).TotalSeconds, 2)
        Write-Verbose "GetEsxiLogsAndEvents: $esxiName TotalWorkTime: $totalWorkTime, csvVmKernelRowArr: $($csvVmKernelRowArr.Count)" -Verbose

        $totalWorkTime = [math]::Round((Measure-Command {
            $csvEventsRowArr = GetEvents $vCenterId $datacenterName $clusterName $esxiName $dateBegin $dateEnd
        }).TotalSeconds, 2)
        Write-Verbose "GetEsxiLogsAndEvents: $esxiName TotalWorkTime: $totalWorkTime, csvEventsRowArr: $($csvEventsRowArr.Count)" -Verbose
        return ($csvVmKernelRowArr + $csvEventsRowArr)
    }

    GetEsxiLogsAndEvents $vCenterId $datacenter $cluster $esxi $dateBegin $dateEnd
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
        [ValidateSet("WaitOne", "WaitAny","WaitAll", "WaitCompleted", "WaitTime")]
        [string]$waitType = "WaitCompleted",
        [int] $sleep = 1000
    )

    $resultArr = @()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timeRemaining = $timeoutMilliseconds
    if($WaitType -eq "WaitOne") {
        foreach ($task in $runspaceTaskArr) {
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            if($timeRemaining -gt 0) {
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

function CreateTask([string] $taskId, [System.Management.Automation.Runspaces.RunspacePool]$runspacePool, [scriptblock]$scriptBlock,[array]$argumentArr) {

    if([string]::IsNullOrEmpty( $taskId)) {
        Write-Warning 'CreateTask: taskId is NULL'
        return $null
    }
    if($null -eq $runspacePool) {
        Write-Warning 'CreateTask: runspacePool is NULL'
        return $null
    }
    if($null -eq $scriptBlock) {
        Write-Warning 'CreateTask: scriptBlock is NULL'
        return $null
    }
    if($null -eq $argumentArr) {
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

function RetrieveLogsAndEvents($vCenterId,$ScriptEsxiLogsAndEvents,[DateTime] $dateBegin,[DateTime] $dateEnd) {

    $csvLogVmKernelArr = @()
    $datacenterArr = @()
    $runspaceTaskArr = @()

    if($null -eq $vCenterId) {
        Write-Warning 'RetrieveLogsAndEvents: vCenterId is NULL'
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

                    $powerShellTaskCustomObject = CreateTask $esxi.Name $runspacePool $ScriptEsxiLogsAndEvents @($vCenterId,$datacenter,$clusterEsxi,$esxi,$dateBegin,$dateEnd,"")
                    if($powerShellTaskCustomObject) {
                        $runspaceTaskArr += $powerShellTaskCustomObject
                    }
                }
            }

            $standaloneEsxiArr =  Get-View -Server $vCenterId -ViewType HostSystem -Property Name,Parent  -SearchRoot $datacenter.MoRef  | Where-Object { $_.Parent -notmatch '^Cluster.*' }
            foreach ($standaloneEsxi in $standaloneEsxiArr) {
                Write-Host " -- Standalone ESXi Name: "$standaloneEsxi.Name
                $powerShellTaskCustomObject = CreateTask $standaloneEsxi.Name $runspacePool $ScriptEsxiLogsAndEvents @($vCenterId,$datacenter,$null,$standaloneEsxi,$dateBegin,$dateEnd,"")
                if($powerShellTaskCustomObject) {
                    $runspaceTaskArr += $powerShellTaskCustomObject
                }
            }  
        }


        $totalWorkTime = [math]::Round((Measure-Command {
            $csvLogVmKernelArr = WaitAndProcessTasks  $runspaceTaskArr  $timeoutMilliseconds $waitMetod
        }).TotalSeconds, 2)

        Write-Verbose "RetrieveLogsAndEvents: TOTAL WorkTime = $totalWorkTime" -Verbose
    }
    catch {
        Write-Error "RetrieveLogsAndEvents: $_"
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


function GenerateHtmlReport($TableArr,[string] $FileName) {
    if($null -eq $TableArr) {
        Write-Warning 'GenerateHtmlReport: TableArr is NULL'
        return
    }
    if([string]::IsNullOrEmpty($FileName)) {
        Write-Warning 'GenerateHtmlReport: FileName is NULL'
        return
    }

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Tables Navigation</title>
    <style>
        /* Стили для меню и контента */
        .menu-container {
            position: fixed;
            top: 0;
            left: 0;
            height: 100%;
            width: 200px;
            background-color: #f1f1f1;
            overflow-x: hidden;
            padding-top: 20px;
        }
        .menu-container a {
            padding: 6px 8px 6px 16px;
            text-decoration: none;
            font-size: 20px;
            color: #818181;
            display: block;
        }
        .menu-container a:hover {
            color: #000;
        }
        .table-content {
            margin-left: 200px;
            padding: 20px;
        }
        table {
            font-family: Arial, sans-serif;
            border-collapse: collapse;
            width: 100%;
            display: none;
        }
        table.visible {
            display: table;
        }
        th, td {
            border: 1px solid #dddddd;
            text-align: left;
            padding: 8px;
        }
        
        th:first-child, td:first-child {
            display: none;
        }
        .hide {
            display: none;
        }

        /* Добавление цвета для строк */
        .red-row {
            background-color: #fa8072;
        }
        .yellow-row {
            background-color: #ecd540;
        }
        .green-row {
            background-color: #50c878;
        }
    </style>
    <script>
	class TableManager {

		constructor() {
			this.tables = document.querySelectorAll('table');
		}
		
		filterTable(table, searchInputId) {
			const input = document.getElementById(searchInputId);
			const filter = input.value.toUpperCase();
			const tableRows = table.querySelectorAll("tr");

			for (let i = 1; i < tableRows.length; i++) {
				const tableCells = tableRows[i].querySelectorAll("td");
				let found = false;

				for (let j = 0; j < tableCells.length; j++) {
					const txtValue = tableCells[j].textContent || tableCells[j].innerText;

					if (txtValue.toUpperCase().indexOf(filter) > -1) {
						found = true;
						break;
					}
				}

				tableRows[i].style.display = found ? '' : 'none';
			}
		}

		showTable(tableId) {
			this.tables.forEach((table) => {
				table.classList.toggle('visible', table.id === tableId);
			});
		}

		setupInput(table, inputId) {
			const input = document.getElementById(inputId);
			input.style.display = "";
			input.addEventListener('keyup', () => {
				this.filterTable(table, inputId);
			});
		}

		showColors(tableRows) {
			for (let j = 1; j < tableRows.length; j++) {
				const tableCells = tableRows[j].querySelectorAll('td');
				const colorCell = tableCells[0];

				if (colorCell) {
					const color = colorCell.textContent.trim().toLowerCase();
					if (color === 'red') {
						tableRows[j].classList.add('red-row');
					} else if (color === 'yellow') {
						tableRows[j].classList.add('yellow-row');
					} else if (color === 'green') {
						tableRows[j].classList.add('green-row');
					}
				}
			}
		}
		
		createDynamicMenuLink(table) {
			const tableRows = table.querySelectorAll('tr');
			const tableName = table.getAttribute('name');
			const link = document.createElement('a');
			link.href = '#'
			link.textContent = tableName + ' (' + (tableRows.length - 1) + ')';
			link.addEventListener('click',() => {
				this.showColors(tableRows);
				this.showTable(table.id);
				this.setupInput(table, 'searchInput');
			});

			return link;
		}

		createButton(text,clickHandler) {
			const button = document.createElement('button');
			button.innerText = text;
			button.addEventListener('click', clickHandler);
			return button;
		}
		
		toggleRowsVisibility(rows) {
			rows.forEach((row) => {
				row.classList.toggle('hide');
			});
		}

		hideRows(rows) {
			rows.forEach((row) => {
				row.classList.add('hide');
			});
		}

		addPlusButton(nameMap, name, columnIndex) {
			const plusButton = this.createButton('+',() => {
				this.toggleRowsVisibility(nameMap[name].slice(1));
			});

			const cellWithName = nameMap[name][0].children[columnIndex];
			cellWithName.insertBefore(plusButton, cellWithName.firstChild);
		}
		
		getColumnIndex(tableRows, columnName) {
			try {
				const tableHeaders = tableRows[0].querySelectorAll('th');
				const columnIndex = Array.from(tableHeaders).findIndex((header) => header.innerText.trim() === columnName);

				if (columnIndex === -1) {
					throw new Error('Index not found');
				}
				
				return columnIndex;
			} catch (error) {
				console.error('Error:', error.message);
				return -1; 
			}
		}

		populateNameMap(tableRows, columnIndex) {
			const nameMap = {};
			for (let i = 1; i < tableRows.length; i++) {
				const tableCell = tableRows[i].children[columnIndex];
				const cellContent = tableCell.innerText.trim();
				if (!nameMap[cellContent]) {
					nameMap[cellContent] = [];
				}
				nameMap[cellContent].push(tableRows[i]);
			}
			
			return nameMap;
		}

		handleDuplicates(table, columnName) {
			const tableRows = table.querySelectorAll('tr');
			const columnIndex = this.getColumnIndex(tableRows, columnName);

			if (columnIndex === -1) {
				return;
			}

			const nameMap = this.populateNameMap(tableRows, columnIndex);

			for (const name in nameMap) {
				if (nameMap[name].length > 1) {
					this.addPlusButton(nameMap, name, columnIndex);
					this.hideRows(nameMap[name].slice(1));
				}
			}
		}
		
		initializeTables() {
			const menuContainer = document.createElement('div');
			menuContainer.className = 'menu-container';
			
			this.tables.forEach((table) => {
				const summaryAttr = table.getAttribute('summary');
				this.handleDuplicates(table, summaryAttr);
				const link = this.createDynamicMenuLink(table);
				menuContainer.appendChild(link);
			});
			document.body.insertBefore(menuContainer, document.body.firstChild);
		}
	}

	window.addEventListener('DOMContentLoaded', function() {
		const manager = new TableManager();
		manager.initializeTables();
	});
</script>
</head>
<body>
    
    <div id="main-div" class="table-content">    
    <input type="text" id="searchInput"  style="display: none;" placeholder="Поиск по таблице...">   
    <p></p>   
        $TableArr
    </div>
</body>
</html>
"@

    # Save HTML
    $htmlContent | Out-File -FilePath $FileName -Encoding utf8
}

# Main script logic

$dateBegin =  (Get-Date).AddDays(-1)
$dateEnd =  (Get-Date)
$inputVC = Read-Host 'Please enter vCenter Name (if multiple separate with a comma)'
$vCenterServerNameArr = ($inputVC.Split(',')).Trim()

foreach($vCenterServerName in $vCenterServerNameArr) 
{
    $csvLogAndEventsArr = @()
    $TableArr = @()
    $Index = 0

    $csvReportFileName  = [System.Environment]::GetFolderPath("Desktop") + "\$vCenterServerName-LOGS-$((Get-Date).ToString("dd-MM-yyyy")).csv" 
    $htmlReportFileName = [System.Environment]::GetFolderPath("Desktop") + "\$vCenterServerName-LOGS-$((Get-Date).ToString("dd-MM-yyyy")).html" 

    $vCenterId = ConnectToVCenter $vCenterServerName
    if ($null -eq $vCenterId) {
        Write-Error 'vCenter:' $vCenterServerName ', Connection status = false' -ForegroundColor Red
        continue
    } 

    # Retrieve logs and events
    $csvLogAndEventsArr = RetrieveLogsAndEvents $vCenterId $ScriptEsxiLogsAndEvents $dateBegin $dateEnd
    # Generate report
    GenerateCsvReport $csvLogAndEventsArr $csvReportFileName

    
    
    $csvLogAndEventsArr |  Group-Object -Property Type | ForEach-Object {
        $Index++
        $TableArr += (($_.Group | ConvertTo-Html -Fragment) -replace '<table>', ('<table id="table' + $Index + '" name="' + $_.Name + '" summary="Message">'))
    }
    GenerateHtmlReport $TableArr $htmlReportFileName
    # Disconnect from vCenter
    DisconnectFromVCenter $vCenterId
}



