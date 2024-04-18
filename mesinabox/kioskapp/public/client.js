const clusterAddress = window.location.origin;

// Function to create a button
function createButton() {
  const button = document.createElement('button');
  button.className = 'cmf-btn-primary';
  button.textContent = 'Go to Portal';
  button.id = 'GoToPortalBtn';
  button.addEventListener('click', () => {
    window.location.replace(`https://portalqa.criticalmanufacturing.dev/DevOpsCenter/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
    console.log("'Go To Portal' Button was clicked");
  });
  return button;
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
          // File does not exist, show button
          const button = createButton();
          button.textContent = 'Go to Portal';
          buttonContainer.appendChild(button);
      } else {
          // File exists, display content
          contentDiv.textContent = `The infrastructure named ${JSON.stringify(data, null, 2)} has already an agent installed in this cluster.`;
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