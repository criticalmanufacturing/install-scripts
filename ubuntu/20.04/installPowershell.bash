# Install powershell
wget -q https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update -y
add-apt-repository universe
apt-get install -y powershell
rm -f packages-microsoft-prod.deb