const express = require('express');
const { spawn, exec } = require('child_process');
const path = require('path');

const app = express();

// Serve static files from the public directory
app.use(express.static('public'));


// Serve index.html for root URL
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

// Route to handle running the PowerShell script
app.get('/enroll', (req, res) => {

    const pat = req.query.pat;
    // Set response headers for Server-Sent Events
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    // Spawn PowerShell script
    const powershell = spawn('pwsh', ['./scriptAfterEnrollment/afterEnrollment.ps1', pat, req.query.infra, req.query.agent, "./as_agent_test_2_Development_parameters.json", "./appsettings.dev.json", "OpenShiftOnPremisesTarget", "desc", "Development", ""]);

    // Handle stdout data
    powershell.stdout.on('data', (data) => {
        // Send data to the client
        res.write(`data: ${data}\n`);
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



// API endpoint to execute script to expand disk space
app.post('/expandDisk', (req, res) => {
    // Execute PowerShell script directly
    exec('pwsh ./scripts/expandDiskScript.ps1', (error, stdout, stderr) => {
        if (error) {
            console.error(`Error executing script: ${error}`);
            res.status(500).send('Error executing script');
            return;
        }
        console.log(`Script output: ${stdout}`);
        res.send('Script executed successfully');
    });
});

// Start server
const port = process.env.port || 8081;
const server = app.listen(port, () => {
    console.log('Server running on port 8081');
});
