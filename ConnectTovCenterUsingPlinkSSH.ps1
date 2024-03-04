$VerbosePreference = "Continue"
$script:currentSctiptDir = $PSScriptRoot
$Script:PlinkDir  = Join-Path  $PSScriptRoot "\putty\PLINK.EXE"
$ServerName = 'serverName'
$UserName = 'root'
$Password = 'Password'
$command = "shell"
$Inputs = @('ls -l /var/opt/apache-tomcat/webapps/examples',"exit")

function InvokeProcess([string] $Program, [string] $Command, [string[]] $Inputs = $null, [int] $timeoutMilliseconds = 5000, [int] $extendTimeoutMilliseconds = 60000)
{
    # Updated 30 Jan 2024
    Write-Verbose "InvokeProcess: $Program $Command"
    [string[]]$lineArr = $null
    $process = $null
    $standardOutput = $null
    $standardError = $null
    $standardInput = $null
    $errorsStr = ''

    if ([string]::IsNullOrEmpty($Program)) { 
        Write-Warning 'InvokeProcess: Program path is empty'
        return $null
    }

    if (-not (Test-Path $Program -PathType Leaf)) {
        Write-Warning "InvokeProcess: Program not found at $Program"
        return $null
	}
	
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Program
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = $Command


    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        Write-Warning "InvokeProcess: Failed to start process: $_"
    }

    if ($null -eq $process) {
        Write-Warning  "InvokeProcess: Failed to start process"
        return $null 
    }

	Write-Verbose "InvokeProcess: Started $($process.Id)" 
	$standardOutput = $process.StandardOutput
	$standardError = $process.StandardError
	$standardInput = $process.StandardInput
    Start-Sleep -Milliseconds 1000
    if (-not $process.HasExited -and $Program -match 'PLINK') {
        if( $standardError.ReadLine() -match 'key is not cached for this server') {
            $standardInput.WriteLine('y')
            Write-Verbose 'InvokeProcess: Sended yes'
        }
    }
	$stopwatch = [Diagnostics.Stopwatch]::StartNew()
	$timeRemaining = $timeoutMilliseconds
	while (-not $process.HasExited -and $timeRemaining -gt 0) {
		Start-Sleep -Milliseconds 1000
		Write-Verbose    $timeRemaining 
		$timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
	}

    if (-not $process.HasExited) {
        if ($null -ne $Inputs) {
            foreach($inputCmd in $Inputs) {
                Write-Verbose "InvokeProcess: Input ($inputCmd)"
                $standardInput.WriteLine($inputCmd)
                Start-Sleep -Milliseconds 500
            }
        }

        Write-Verbose "InvokeProcess: process.WaitForExit($extendTimeoutMilliseconds)"
        $process.WaitForExit($extendTimeoutMilliseconds)    
    }
		
    if ($process.ExitCode) {
        Write-Host "process.ExitCode $($process.ExitCode)"
    }
    else {
        Write-Verbose 'InvokeProcess: process.ExitCode = NULL' 
    }
	
    while (-not $standardOutput.EndOfStream) {
        $outputline = $standardOutput.ReadLine()

        if ([string]::IsNullOrEmpty($outputline) -or $outputline -isnot [string]) {
            Write-Verbose "  Skipped    $outputline"
        }
        else {
            Write-Verbose "             $outputline"
            $lineArr += $outputline
        }
    }
	
	while (-not $standardError.EndOfStream) {
		$errorsStr += $standardError.ReadLine()
	}
	
    $standardOutput.Close()
    $standardError.Close()
    $standardInput.Close()
	
    if (-not $process.HasExited) {
        try {
            Write-Verbose "Forcefully killing process $($process.Id)"
            $process.Kill()
        }
        catch {
            Write-Warning "InvokeProcess: $_" 
        }
    }
    if ([string]::IsNullOrEmpty($errorsStr)) { 
        Write-Verbose 'InvokeProcess: No errors'
    }
    else {
        Write-Warning "InvokeProcess errors: $errorsStr"  
    }

    return $lineArr 
}

function InvokePlink([string] $ServerName,[string] $UserName,[string] $Password, [string] $Command, [string[]] $Inputs=$null, [int] $TimeoutMilliseconds = 5000)
{
    # Updated 30 Jan 2024
    $lineArr = @()
	if([string]::IsNullOrEmpty($ServerName)) { 
		Write-Warning 'InvokePlink:ServerName = null'
        return $lineArr
	}
	if([string]::IsNullOrEmpty($UserName)) { 
		Write-Warning 'InvokePlink:UserName = null'
        return $lineArr
	}
	if([string]::IsNullOrEmpty($Password)) { 
		Write-Warning 'InvokePlink:Password = null'
        return $lineArr
	}

    for($i = 0; $i -le 2; $i++) {
		$arguments = "$ServerName -l  $UserName -pw $Password $Command"
		$lineArr = InvokeProcess  $Script:PlinkDir  $arguments $Inputs $timeoutMilliseconds
		Write-Verbose "InvokePlink: ServerName: $ServerName ,UserName: $UserName ,Command: $command"
		
		if($null -eq $lineArr) {
			Write-Warning " ---- $i) InvokePlink: lineArr = NULL,Start-Sleep 5 sec"
			Start-Sleep -Milliseconds 5000
			continue
		}

		if($lineArr -is [array] -and $lineArr.Count -ne 0) {
			Write-Verbose " ---- $i) InvokePlink: $($lineArr.Count)"
			break
		}
		elseif($lineArr -is [string] -and ( -not [string]::IsNullOrEmpty($lineArr))) {
			Write-Verbose " ---- $i) InvokePlink: lineArr - string"
			break
		}
		else {
            Write-Warning " ---- $i) InvokePlink: Start-Sleep 5 sec"
			Start-Sleep -Milliseconds 5000
		}
    }
	
    return $lineArr
}

$lineArr = InvokePlink $ServerName $UserName $Password $command $Inputs 1000
foreach($line in $lineArr)
{
    Write-Host $line
}

