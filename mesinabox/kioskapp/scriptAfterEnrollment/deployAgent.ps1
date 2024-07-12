param (
    [Parameter(Mandatory=$true)][string]$AgentName,
    [Parameter(Mandatory=$true)][string]$DeploymentScriptPath,
    [Parameter(Mandatory=$true)][string]$CmfPortalLocation
)

$AgentStackFolderPath = Split-Path -Parent $DeploymentScriptPath

Push-Location $AgentStackFolderPath
. $deployStackToKubernetesPath
Pop-Location

if (($LASTEXITCODE -ne 0) -Or $error) {
    Write-Error "Failed to deploy agent stack. ExitCode: $LASTEXITCODE | $error"
    exit 1
}

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
        $isConnected = Invoke-Expression "$CmfPortalLocation/cmf-portal checkagentconnection -n $AgentName"
    }
    catch 
    {
        Write-Host $_.Exception.Message
    }

    # log state
    if ($isConnected)
    {
        Write-Host "Infrastructure Agent $AgentName connected!"
    }
    else
    {
        Write-Host "Infrastructure Agent $AgentName not connected. Retrying in $waitTime seconds."
    }
} While ((!$isConnected) -and ($totalWaitedTime -le $timeout))


if (!$isConnected)
{
    Write-Error "Was not possible to connect the Infrastructure Agent $AgentName! You must check and if necessary fix the connection."
    exit 1
}