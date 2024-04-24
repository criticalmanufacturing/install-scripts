console.log('Client-side code running');

const clusterAddress = window.location.origin;
const expandDiskButton = document.getElementById("expandDiskButton");
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
        console.log('Script executed successfully:', data);
    })
    .catch(error => {
        console.error('There was a problem with the expand disk operation:', error);
    });
});

// Function to create a button
function createButton() {
  const button = document.createElement('button');
  button.textContent = 'Button Text';
  button.addEventListener('click', () => {
    window.location.replace(`https://portalqa.criticalmanufacturing.dev/DevOpsCenter/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
    console.log('button was clicked');
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

