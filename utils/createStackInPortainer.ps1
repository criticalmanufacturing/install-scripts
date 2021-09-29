param (
       [String]$StackName, 
       [String]$PortainerUrl = "http://localhost:9000",
       [String]$PortainerUser = "admin",
       [String]$PortainerPassword,
       [String]$StackFileName 
      )

#read stack file
$stack = Get-Content $StackFileName -Raw

#Login Portainer
$loginMessage = ConvertTo-Json @{
                                  username = $PortainerUser
                                  password = $PortainerPassword    
                                }

Write-Host "Try to login or wait until the endpoint is ready..."
#wait until the endpoint is available - in case the portainer stack is still being deployed

$count = 10;
DO
{
    Start-Sleep -s 5
    try
    {
        $response = Invoke-WebRequest -Uri $PortainerUrl/api/auth -Method POST -ContentType "application/json" -Body $loginMessage
        $StatusCode = $response.StatusCode
        Write-Host "Portainer Login:" $response.StatusCode
    } catch {
        $StatusCode = $_.Exception.Response.StatusCode.value__
        Write-Host $_.Exception.Message             
    } 
    $count = $count - 1
} While (-not($StatusCode -eq 200) -and $count -gt 0)

if ($response.StatusCode -eq 200)
{
    #authentication succeeded
    $token = (ConvertFrom-Json $response.Content).jwt

    $PortainerHeaders = @{
        "Accept" = "application/json"
        "Authorization" = "Bearer $token"
    }
    #Get Endpoints
    $response = Invoke-WebRequest -Uri "$PortainerUrl/api/endpoints" -Method GET -Headers $PortainerHeaders
    if ($response.StatusCode -eq 200) 
    {
        $endpoints = ConvertFrom-Json ($response.Content)
        $endpoint = $endpoints[0].Id
        if ($endpoints.Count -gt 1)
        {
            Write-Host "Found multiple endpoints! Please select 1:"
            $endpoints | Select-Object -Property Id, Name
            $endpoint = Read-Host 
        }
        #Get SwarmID            
        $response = Invoke-WebRequest -Uri $PortainerUrl/api/endpoints/$endpoint/docker/swarm -Method GET -Headers $PortainerHeaders
        if ($response.StatusCode -eq 200) 
        { 
            $swarmID = (ConvertFrom-Json $response.Content).ID
            $request = ConvertTo-Json @{
                                            Name = $StackName
                                            SwarmID = $swarmID
                                            StackFileContent = ($stack).ToString()
                                            Env = @()
                                            ProjectPath = "/data/compose/$StackName"
                                        }
            #in case 1 of the values contains a &
            $request = $request -replace '\\u0026', '&'
            $response = Invoke-WebRequest -Uri "$PortainerUrl/api/stacks?endpointId=$($endpoint)&method=string&type=1" -Method PUT -Headers $PortainerHeaders -ContentType "application/json" -Body $request
            if ($response.StatusCode -eq 200) 
            { 
                Write-Host Stack $StackName created!                 
                #set stack permissions (only Administrators)
                Write-Host "Set stack permissions (only Administrators)"
                $stackId = (ConvertFrom-Json $response.Content).ResourceControl.Id
                $request = Invoke-WebRequest -Uri $PortainerUrl/api/resource_controls/$stackId -Method PUT -ContentType "application/json" -Headers $PortainerHeaders -Body "{`"AdministratorsOnly`":true,`"Public`":false,`"Users`":[],`"Teams`":[]}"       
            }
        }        
    }
}

