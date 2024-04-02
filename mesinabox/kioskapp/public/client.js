const { exec } = require('child_process');

let clusterDomain;

function getClusterDomain() {
  return new Promise((resolve, reject) => {
    exec('oc get route -n openshift-console console -o jsonpath="{.spec.host}"', (error, stdout, stderr) => {
      if (error) {
        reject(error);
        return;
      }
      if (stderr) {
        reject(stderr);
        return;
      }
      const clusterDNSName = stdout.trim(); // Extracted Cluster DNS Name
      if (!clusterDNSName) {
        reject('Unable to retrieve Cluster DNS Name');
        return;
      }
      clusterDomain = clusterDNSName.split('.').slice(1).join('.');
      resolve(clusterDomain);
    });
  });
}

// Usage
getClusterDomain()
  .then(domain => {
    console.log("Cluster Domain:", domain);
    // Use domain variable here
    console.log("Using domain outside of the function:", clusterDomain);
  })
  .catch(error => {
    console.error("Error:", error);
  });

const button = document.getElementById('myButton');
button.addEventListener('click', function(e) {
  getClusterDomain();
  const clusterAddress = `kioskapp.${clusterDomain}`;
  window.location.replace(`https://portaldev.criticalmanufacturing.dev/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
  console.log('button was clicked');
});


