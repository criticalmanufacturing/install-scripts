const clusterAddress = window.location.origin;
const expandDiskButton = document.getElementById("ExpandDiskBtn");
expandDiskButton.addEventListener("click", function() {
    fetch('/expandDisk', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({
            size: 5
        })
    })
    .then(response => {
        if (!response.ok) {
            throw new Error('Network response was not ok');
        }
        return response.json();
    })
    .then(data => {
      const expandDiskLabel = document.getElementById('ExpandDiskLabel');
      expandDiskLabel.textContent = data === 0  ? "The disk was expanded with success!" : "There's was an issue while trying to expand the disk!";
      expandDiskLabel.className = data === 0 ? 'success' : 'failure';
    })
    .catch(error => {
        console.error('There was a problem with the expand disk operation:', error);
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

fetch('/api/connectivity')
.then(response => response.json())
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
})
.catch(error => {
    console.error('Error fetching ping result:', error);
});


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
