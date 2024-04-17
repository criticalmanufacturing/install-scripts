const queryParams = new Proxy(new URLSearchParams(window.location.search), {
    get: (searchParams, prop) => searchParams.get(prop),
});
// Get the value of "infra" in eg "https://example.com/?infra=infraName&agent=agentName"
let infraName = queryParams.infra;

// Open Infra In Portal Button
const btnManageSslCert = document.getElementById('OpenInfraPortalBtn');
btnManageSslCert.addEventListener('click', function (e) {
    console.log("'Open Infra In Portal' Button was clicked");
    window.location.replace(`https://portalqa.criticalmanufacturing.dev/Entity/CustomerInfrastructure/${encodeURIComponent(infraName)}/View/Details`);
});

//handle Server-Sent Events
function handleSSE() {
    const outputDiv = document.getElementById('logs-output');
    const openInPortalButton = document.getElementById('OpenInfraPortalBtn');
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
            //TODO: show "OpenInPortal" Button
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
