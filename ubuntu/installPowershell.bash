# Install powershell
wget -q https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update -y
add-apt-repository universe
apt-get install -y powershell
rm -f packages-microsoft-prod.deb