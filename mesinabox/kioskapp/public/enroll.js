//handle Server-Sent Events
function handleSSE() {
    const outputDiv = document.getElementById('output');
    const eventSource = new EventSource('/enroll');

    // Event listener for receiving data
    eventSource.onmessage = function(event) {
        outputDiv.innerHTML += `<p>${event.data}</p>`;
        outputDiv.scrollTop = outputDiv.scrollHeight; // Scroll to bottom
    };

    // Event listener for error
    eventSource.onerror = function(event) {
        console.error('SSE error:', event);
        eventSource.close();
    };
}

// Start handling SSE when the page loads
window.onload = handleSSE;