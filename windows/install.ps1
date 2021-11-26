$RepositoryUrl = "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/install-scripts-70367-InfrastructureAgentCommand"
Invoke-WebRequest -Uri "$RepositoryUrl/utils/deployPortainer.ps1" -OutFile deployPortainer.ps1
./deployPortainer.ps1 -RepositoryUrl "$RepositoryUrl"
#Clean up 
Remove-Item ./deployPortainer.ps1