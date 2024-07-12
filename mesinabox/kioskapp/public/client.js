const clusterAddress = window.location.origin;
let customerPortalAddress = null;

const expandDiskButton = document.getElementById("ExpandDiskBtn");
expandDiskButton.addEventListener("click", function () {
  fetch('/expandDisk', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    }
  })
    .then(response => {
      console.log(response);
      if (!response.ok) {
        return response.text().then(errorMessage => {
          throw new Error(errorMessage);
        });
      }
      return response.text();
    }).then(data => {
      const expandDiskLabel = document.getElementById('ExpandDiskLabel');
      expandDiskLabel.textContent = data;
      expandDiskLabel.className = 'success';
    })
    .catch(error => {
      const expandDiskLabel = document.getElementById('ExpandDiskLabel');
      expandDiskLabel.textContent = error.message;
      expandDiskLabel.className = 'failure';

      console.error('There was a problem with the expand disk operation:', error.message);
    });
});

const btnManageSslCert = document.getElementById('ManageSslCertBtn');
btnManageSslCert.addEventListener('click', function (e) {
  window.location = `/sslcert`;
  console.log("'Manage SSL Certificate' was clicked");
});

//#region Go To Portal button actions

let goToPortalBtnIsDisabled = true; // start disabled, until connectivity works
function setOrUpdateGoToPortalButtonDisabled(isDisabled) {
  if (isDisabled != null) {
    goToPortalBtnIsDisabled = isDisabled;
  }
  const GoToPortalBtn = document.getElementById('GoToPortalBtn');
  if (GoToPortalBtn != null) {
    GoToPortalBtn.disabled = goToPortalBtnIsDisabled;
  }
}

// Function to create the "Go To Portal" button redirecting to portal depending if infra id exists or not
function createGoToPortalButton(portalAddress, infraId) {
  const button = document.createElement('button');
  button.className = 'cmf-btn-primary';
  button.textContent = 'Go to Portal';
  button.id = 'GoToPortalBtn';
  button.addEventListener('click', () => {
    if (infraId != null) {
      window.location.replace(`https://${portalAddress}/Entity/CustomerInfrastructure/${infraId}/View/Details`);
    }
    else {
      window.location.replace(`https://${portalAddress}/DevOpsCenter/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
    }
  });
  button.disabled = goToPortalBtnIsDisabled;
  return button;
}

//#endregion

//#region Check Internet Connection to Portal and Registry

// Recursive function for testing connectivity
function testConnectivity() {
  fetch('/api/connectivity')
    .then(response => {
      if (response.ok) {
        return response.json();
      }
      throw new Error('Fetch failed.');
    })
    .then(data => {
      // Get ping results for each address
      const isCustomerPortalReachable = data["portal"];
      const isRegistryReachable = data["registry"];

      // Update HTML content based on ping results
      const customerPortalConnectivity = document.getElementById('customerPortalConnectivity');
      customerPortalConnectivity.textContent = isCustomerPortalReachable ? 'Customer Portal is reachable' : 'Customer Portal is unreachable';
      customerPortalConnectivity.className = isCustomerPortalReachable ? 'alive' : 'dead';

      const registryConnectivity = document.getElementById('registryConnectivity');
      registryConnectivity.textContent = isRegistryReachable ? 'Registry is reachable' : 'Registry is unreachable';
      registryConnectivity.className = isRegistryReachable ? 'alive' : 'dead';
      setOrUpdateGoToPortalButtonDisabled(!isRegistryReachable || !isCustomerPortalReachable);
    })
    .catch(error => {
      console.error('Error fetching ping result:', error);
      const customerPortalConnectivity = document.getElementById('customerPortalConnectivity');
      customerPortalConnectivity.textContent = 'Connectivity Check Failed!';
      customerPortalConnectivity.className = 'dead';
      const registryConnectivity = document.getElementById('registryConnectivity');
      registryConnectivity.textContent = '';
      setOrUpdateGoToPortalButtonDisabled(true);
    })
    .finally(_ => {
      setTimeout(testConnectivity, 5000); // test again after 5 seconds
    });
}

testConnectivity();

//#endregion

//#region Infrastructure Agent Already Installed Checks

// Displays Infra Already installed message
function infraAlreadyCreated(contentDiv, agentData) {
  const text = document.createElement('p');
  text.textContent = `The ${agentData.infraName} infrastructure already has an agent installed in this cluster.`
  contentDiv.appendChild(text);
}

const portalAddrFetch = fetch('/api/config/portalAddress')
    .then(response => response.json())
    .then(portalAddrData => {
      customerPortalAddress = portalAddrData.customerPortalAddress;
      return portalAddrData;
    })
    .catch(error => {
      console.error('Error fetching portal address from API: ', error);
    });

// Fetch agent installation from the server
const agentStatusFetch = fetch('/api/agentInstalled')
  .then(response => {
    if (!response.ok) {
      if (response.status == 404) {
        return null;
      }
      throw new Error('Network response was not ok');
    }
    return response.json();
  })
  .catch(error => {
    console.error('Error fetching agent status from API: ', error);
    document.getElementById('content').innerText = 'Error loading content';
  });

async function getInfrastructureStatus() {
  const [portalAddrResponse, agentStatusResponse] = await Promise.allSettled([portalAddrFetch, agentStatusFetch]);
  if (portalAddrResponse.status == "rejected" || agentStatusResponse.status == "rejected") {
    return new Promise.reject();
  }

  const agentInstalledData = agentStatusResponse.value;

  let infraId = null; // If left null, the File with infra agent status does not exist, show Go To Portal Button that goes to Enroll Cluster

  if (agentInstalledData != null) {
    // File with infra agent status exists, display message and show button to infrastructure page
    infraId = agentInstalledData.infraId;
    const contentDiv = document.getElementById('content');
    infraAlreadyCreated(contentDiv, agentInstalledData);
  }
  
  // Generate GoToPortalButton
  const button = createGoToPortalButton(customerPortalAddress, infraId);
  const buttonContainer = document.getElementById('enrollButtonDiv');
  buttonContainer.appendChild(button);
}
getInfrastructureStatus();

//#endregion