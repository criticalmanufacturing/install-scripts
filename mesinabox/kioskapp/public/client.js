const clusterAddress = window.location.origin;
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

// Function to create a button
function createButton(portalAddress) {
  const button = document.createElement('button');
  button.className = 'cmf-btn-primary';
  button.textContent = 'Go to Portal';
  button.id = 'GoToPortalBtn';
  button.addEventListener('click', () => {
    window.location.replace(`https://${portalAddress}/DevOpsCenter/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
    console.log("'Go To Portal' Button was clicked");
  });
  return button;
}

function infraAlreadyCreated(contentDiv, data) {
  const checkmark = document.createElement('img');
  checkmark.src = 'checked-checkbox-64.png';
  contentDiv.appendChild(checkmark);
  const text = document.createElement('p');
  text.textContent = `The ${JSON.stringify(data, null, 2)} infrastructure already has an agent installed in this cluster.`
  contentDiv.appendChild(text);
}


// Fetch dynamic content from the server
fetch('/api/content')
  .then(response => {
    if (!response.ok) {
      throw new Error('Network response was not ok');
    }
    return response.text();
  })
  .then(data => {
    const contentDiv = document.getElementById('content');
    const buttonContainer = document.getElementById('enrollButtonDiv');
    console.log(data);

    if (data === "false") {
      fetch('/api/config/portalAddress')
        .then(response => response.json())
        .then(data => {
          const customerPortalAddress = data.customerPortalAddress;
          // File does not exist, show button
          const button = createButton(customerPortalAddress);
          button.textContent = 'Go to Portal';
          buttonContainer.appendChild(button);
        })
        .catch(error => {
          console.error('Error fetching data from API:', error);
        });

    } else {
      // File exists, display content
      infraAlreadyCreated(contentDiv, data);
    }
  })
  .catch(error => {
    console.error('Error:', error);
    document.getElementById('content').innerText = 'Error loading content';
  });


const btnManageSslCert = document.getElementById('ManageSslCertBtn');
btnManageSslCert.addEventListener('click', function (e) {
  window.location = `/sslcert`;
  console.log("'Manage SSL Certificate' was clicked");
});

//#region Check Internet Connection to Portal and Registry

// recursive function for testing connectivity
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
      const GoToPortalBtn = document.getElementById('GoToPortalBtn');
      customerPortalConnectivity.textContent = isCustomerPortalReachable ? 'Customer Portal is reachable' : 'Customer Portal is unreachable';
      customerPortalConnectivity.className = isCustomerPortalReachable ? 'alive' : 'dead';

      const registryConnectivity = document.getElementById('registryConnectivity');
      registryConnectivity.textContent = isRegistryReachable ? 'Registry is reachable' : 'Registry is unreachable';
      registryConnectivity.className = isRegistryReachable ? 'alive' : 'dead';
      GoToPortalBtn.disabled = !isRegistryReachable || !isCustomerPortalReachable;
    })
    .catch(error => {
      console.error('Error fetching ping result:', error);
    })
    .finally(_ => {
      setTimeout(testConnectivity, 5000); // test again after 5 seconds
    });
}

testConnectivity();

//#endregion