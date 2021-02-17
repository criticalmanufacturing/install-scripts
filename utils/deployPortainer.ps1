param (
       [String]$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main",
       #[String]$PortainerPassword = "",
       [Int]$PortainerPasswordLength = 18
      )

if ($PortainerPassword -eq "") 
{
    #Generate a random secure password
    $PortainerPassword = ("!@#$%^*0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz".tochararray() | Sort-Object {Get-Random})[0..$PortainerPasswordLength] -join ''
}
#Write-Debug "RepositoryUrl: $RepositoryUrl"
#Write-Debug "PortainerPassword: $PortainerPassword"
#Download files
#Write-Debug "Downloading file $RepositoryUrl/utils/portainer-agent-stack.yml"
Invoke-WebRequest -Uri "$RepositoryUrl/utils/portainer-agent-stack.yml" -OutFile portainer-agent-stack.yml
#Write-Debug "Downloading file $RepositoryUrl/utils/createStackInPortainer.ps1"
Invoke-WebRequest -Uri "$RepositoryUrl/utils/createStackInPortainer.ps1" -OutFile createStackInPortainer.ps1

#Hash portainer password
docker pull httpd:2.4-alpine
$hashedPassword = (docker run --rm httpd:2.4-alpine htpasswd -nbB admin $PortainerPassword)
$hashedPassword = $hashedPassword.Split(":")[1]
#Write-Debug "Hashed password: $hashedPassword"
((Get-Content -Path portainer-agent-stack.yml -Raw) -replace "ADMIN_PASSWORD", $hashedPassword) -replace  '\$','$$$' | Set-Content -Path portainer-agent-stack.yml
#make sure docker is running in swarm mode
docker swarm init
#limit task history
docker swarm update --task-history-limit 3
#deploy the portainer stack 
docker stack deploy -c portainer-agent-stack.yml portainer
#Add portainer stack to portainer (avoid it to be marked as external)
./createStackInPortainer.ps1 -StackName portainer -PortainerUser admin -PortainerPassword "$portainerPassword" -StackFileName ./portainer-agent-stack.yml 

#Clean up 
Remove-Item ./portainer-agent-stack.yml
Remove-Item ./createStackInPortainer.ps1

Write-Host "Portainer has been deployed!"
Write-Host ""
Write-Host "***************************************"
Write-Host ""
Write-Host "Url:       http://localhost:9000"
Write-Host "User:      admin"
Write-Host "Password:  $PortainerPassword"
Write-Host ""
Write-Host "***************************************"
