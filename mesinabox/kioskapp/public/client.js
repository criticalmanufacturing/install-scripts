const button = document.getElementById('GoToPortalBtn');
const clusterAddress = `${window.location.origin}/enroll`
button.addEventListener('click', function (e) {
  window.location.replace(`http://wsl:8080/DevOpsCenter/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
  console.log("'Go To Portal' Button was clicked");
});

const btnManageSslCert = document.getElementById('ManageSslCertBtn');
btnManageSslCert.addEventListener('click', function (e) {
  window.location = `/sslcert`;
  console.log("'Manage SSL Certificate' was clicked");
});