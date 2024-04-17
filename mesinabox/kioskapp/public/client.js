console.log('Client-side code running');

const button = document.getElementById('myButton');
const clusterAddress = window.location.origin;
button.addEventListener('click', function(e) {
  window.location.replace(`https://portaldev.criticalmanufacturing.dev/DevopsCenter/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
  console.log('button was clicked');
});
const expandDiskButton = document.getElementById("expandDiskButton");
expandDiskButton.addEventListener("click", function() {
    // Make an HTTP POST request to trigger script execution
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
        // Handle success response from server
        console.log('Script executed successfully:', data);
    })
    .catch(error => {
        // Handle errors
        console.error('There was a problem with the expand disk operation:', error);
    });
});

