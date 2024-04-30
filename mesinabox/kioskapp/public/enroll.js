const queryParams = new Proxy(new URLSearchParams(window.location.search), {
    get: (searchParams, prop) => searchParams.get(prop),
});
// Get the value of "infra" in eg "https://example.com/?infra=infraName&agent=agentName"
let infraName = queryParams.infra;
const openInPortalButton = document.getElementById('OpenInfraPortalBtn');

// Open Infra In Portal Button
fetch('/api/config/portalAddress')
  .then(response => response.json())
  .then(data => {
    
    openInPortalButton.addEventListener('click', function (e) {
        console.log("'Open Infra In Portal' Button was clicked");
        window.location.replace(`https://${data.customerPortalAddress}/Entity/CustomerInfrastructure/${encodeURIComponent(infraName)}/View/Details`);
    });
  }) 
  .catch(error => {
    console.error('Error fetching data from API:', error);
  });

//handle Server-Sent Events
function handleSSE() {
    const outputDiv = document.getElementById('logs-output');
    const eventSource = new EventSource(`/enrollstart${window.location.search}`);

    eventSource.onopen = () => {
        console.log('Connection opened')
    }

    // Event listener for receiving data
    eventSource.onmessage = event => {
        const { type, data } = JSON.parse(event.data)
        if (type === 'close') {
            console.log(`Close Message received - Code = ${data}`);
            eventSource.close();
            if (data == 0) {
                // Script finished successfully
                openInPortalButton.className = 'cmf-btn-primary';
                openInPortalButton.innerText = 'Open In Portal';
                openInPortalButton.disabled = false;
            }
            else if (data >= 0) {
                // Script errored
                openInPortalButton.className = 'cmf-btn';
                openInPortalButton.innerText = 'Installation Failed';
                openInPortalButton.disabled = true;
            }
        }
        else {
            console.log(data);
            outputDiv.innerHTML += `<p>${data}</p>`;
            outputDiv.scrollTop = outputDiv.scrollHeight; // Scroll to bottom
        }
    }

    // Event listener for error
    eventSource.onerror = event => {
        console.error('SSE error:', event);
        eventSource.close();
    }
}

// Start handling SSE when the page loads
window.onload = handleSSE;
