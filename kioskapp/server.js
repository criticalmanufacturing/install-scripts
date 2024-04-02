const express = require('express');
const { spawn } = require('child_process');
const path = require('path');

const app = express();

// Serve static files from the public directory
app.use(express.static('public'));

// Route to handle running the PowerShell script
app.get('/enroll/:param1/:param2', (req, res) => {

    const param1 = req.params.param1;
    const param2 = req.params.param2;
    // Set response headers for Server-Sent Events
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    // Spawn PowerShell script
    const powershell = spawn('pwsh', ['./scriptAfterEnrollment/afterEnrollment.ps1','eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJjbGllbnRJZCI6Ik1FUyIsInRlbmFudE5hbWUiOiJDdXN0b21lclBvcnRhbERFViIsInN1YiI6IlN5c3RlbSIsInNjb3BlIjpudWxsLCJleHRyYVZhbHVlcyI6bnVsbCwidHlwZSI6IlBBVCIsImlhdCI6MTY4MDA5NjY0MSwiZXhwIjoxODk4NTUzNTM5LCJhdWQiOiJBdXRoUG9ydGFsIiwiaXNzIjoiQXV0aFBvcnRhbCJ9.b5iWHJnqB90OsZxqbUX3IAFoPCa-uaUTrkGj4h1OMfw', 'as_test_new_infra', "as_agent_test_2", "./as_agent_test_2_Development_parameters.json", "./appsettings.dev.json", "OpenShiftOnPremisesTarget", "desc", "Development", ""]);

    // Handle stdout data
    powershell.stdout.on('data', (data) => {
        // Send data to the client
        res.write(`data: ${data}\n\n`);
    });

    // Handle errors
    powershell.stderr.on('data', (data) => {
        console.error(`Error: ${data}`);
    });

    // Handle script exit
    powershell.on('exit', (code) => {
        console.log(`Script exited with code ${code}`);
        res.end(); // End the response when the script exits
    });
});

// Serve index.html for root URL
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

// Start server
const server = app.listen(8081, () => {
    console.log('Server running on port 8081');
});
