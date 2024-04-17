//handle Server-Sent Events
function handleSSE() {
    const outputDiv = document.getElementById('logs-output');
    const eventSource = new EventSource('/enrollstart');

    // Default events
    eventSource.addEventListener('open', () => {
        console.log('Connection opened')
    });

    eventSource.addEventListener('error', () => {
        console.error("Subscription err'd")
        eventSource.close();
    });

    eventSource.addEventListener('message', (event) => {
        console.log(`Receive message: ${event.data}`)
        outputDiv.innerHTML += `<p>${event.data}</p>`;
        outputDiv.scrollTop = outputDiv.scrollHeight; // Scroll to bottom
    });
    
    eventSource.addEventListener('connected', () => {
        console.log('Subscription successful!');
    });

    eventSource.addEventListener('current-date', (event) => {
        console.log(`Date: ${event.data}`);
    });


    // Event listener for receiving data
    // eventSource.onmessage = function(event) {
    //     outputDiv.innerHTML += `<p>${event.data}</p>`;
    //     outputDiv.scrollTop = outputDiv.scrollHeight; // Scroll to bottom
    // };

    // // Event listener for error
    // eventSource.onerror = function(event) {
    //     console.error('SSE error:', event);
    //     eventSource.close();
    // };
}

// Start handling SSE when the page loads
window.onload = handleSSE;