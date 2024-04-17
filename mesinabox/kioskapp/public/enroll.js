//handle Server-Sent Events
function handleSSE() {
    const outputDiv = document.getElementById('logs-output');
    const eventSource = new EventSource(`/enrollstart${window.location.search}`);

    // Default events
    eventSource.addEventListener('open', () => {
        console.log('Connection opened')
    });

    // Event listener for error
    eventSource.addEventListener('error', (event) => {
        console.error('SSE error:', event);
        eventSource.close();
    });

    // Event listener for receiving data
    eventSource.addEventListener('message', (event) => {
        outputDiv.innerHTML += `<p>${event.data}</p>`;
        outputDiv.scrollTop = outputDiv.scrollHeight; // Scroll to bottom
    });
}

// Start handling SSE when the page loads
window.onload = handleSSE;