console.log('Client-side code running');

const clusterAddress = window.location.origin;

// Function to create a button
function createButton() {
  const button = document.createElement('button');
  button.textContent = 'Button Text';
  button.addEventListener('click', () => {
    window.location.replace(`https://portaldev.criticalmanufacturing.dev/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
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

      if (!data) {
          // File does not exist, show button
          const button = createButton();
          button.textContent = 'Go to Portal';
          buttonContainer.appendChild(button);
      } else {
          // File exists, display content
          contentDiv.innerText = JSON.stringify(data, null, 2);
      }
  })
  .catch(error => {
      console.error('Error:', error);
      document.getElementById('content').innerText = 'Error loading content';
  });


