param (
       [String]$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main",
       [String]$PortainerPassword = "",
       [Int]$PortainerPasswordLength = 18
      )

if ($PortainerPassword -eq "") 
{
    #Generate a random secure password
    $PortainerPassword = ("!@#$%^*0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz".tochararray() | sort {Get-Random})[0..$PortainerPasswordLength] -join ''
}
Write-Host $RepositoryUrl
#Download files
Invoke-WebRequest -Uri "$RepositoryUrl/utils/portainer-agent-stack.yml" -OutFile portainer-agent-stack.yml
Invoke-WebRequest -Uri "$RepositoryUrl/utils/createStackInPortainer.ps1" -OutFile createStackInPortainer.ps1

#Hash portainer password
docker pull httpd:2.4-alpine
$hashedPassword = (docker run --rm httpd:2.4-alpine htpasswd -nbB admin $PortainerPassword)
$hashedPassword = ($hashedPassword -replace '\$','$$$').Split(":")[1]
(Get-Content -Path portainer-agent-stack.yml -Raw) -replace "ADMIN_PASSWORD",$hashedPassword | Set-Content -Path portainer-agent-stack.yml
docker stack deploy -c portainer-agent-stack.yml portainer
#Deploy the portainer stack within portainer (avoid it to be marked as external)
./createStackInPortainer.ps1 -StackName portainer -PortainerUser admin -PortainerPassword "$portainerPassword" -StackFileName ./portainer-agent-stack.yml

#Clean up 
Remove-Item -Name portainer-agent-stack.yml
Remove-Item -Name createStackInPortainer.ps1

Write-Host "Portainer is Installed"
Write-Host "Url:       http://localhost:9000"
Write-Host "User:      admin"
Write-Host "Password:  $PortainerPassword"
