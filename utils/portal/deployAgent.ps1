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

    try
    {
        # check if agent is connected
        $isConnected = Get-AgentConnection -Name $agent
    }
    catch 
    {
        Write-Host $_.Exception.Message
    }

    # log state
    if ($isConnected)
    {
        Write-Host "Infrastructure Agent $agent connected!"
    }
    else
    {
        Write-Host "Infrastructure Agent $agent not connected. Retrying in $waitTime seconds."
    }
} While ((!$isConnected) -and ($totalWaitedTime -le $timeout))


if (!$isConnected)
{
    Write-Error "Was not possible to connect the Infrastructure Agent $agent! You must check and if necessary fix the connection."
    exit 1
}