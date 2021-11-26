param (
    [Parameter(Mandatory=$true)][string]$agent
)


# Run agent installation script
Push-Location .\agent\
.\deployStackToSwarm.ps1
Pop-Location

# Check agent connection to customer portal
$waitTime = 10
$timeout = 60 * $waitTime
$isConnected = $false
$totalWaitedTime = 0

Write-Host "Waiting for agent to be connected with Customer Portal..."

Do
{
    # wait
    Start-Sleep -Seconds $waitTime
    $totalWaitedTime = $totalWaitedTime + $waitTime

    # check if agent is connected
    $isConnected = Get-AgentConnection -Name $agent

    # log state
    if ($isConnected -eq $true)
    {
        Write-Debug "Infrastructure Agent $agent not connected. Retrying in $waitTime seconds."
    }
    else
    {
        Write-Debug "Infrastructure Agent $agent not connected. Retrying in $waitTime seconds."
    }
} While (($isConnected -eq $false) -and ($totalWaitedTime -le $timeout))
