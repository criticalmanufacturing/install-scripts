const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const app = express();
const dataDirectory = '/opt/app-root/src/data';

// Serve static files from the public directory
app.use(express.static('public'));

// Function to check if a file exists and read its content
function readFileIfExists(filePath) {
    return new Promise((resolve, reject) => {
        fs.access(filePath, fs.constants.F_OK, (err) => {
            if (err) {
                // File doesn't exist
                console.log("Error  "+err);
                resolve(false); // Resolve with false if the file doesn't exist
            } else {
                // File exists, read its content
                fs.readFile(filePath, 'utf8', (err, data) => {
                    if (err) {
                        reject(err);
                    } else {
                        resolve(data);
                    }
                });
            }
        });
    });
}

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

// Serve index.html for root URL
app.get('/', (req, res) => {

    const userId = process.getuid();
    const groupId = process.getgid();
    console.log('User ID:', userId);
    console.log('Group ID:', groupId);
    const filePath = path.join(dataDirectory, 'myfile.txt');
    const content = 'Hello, world';
   /* fs.writeFile(filePath, content, (err) => {
        if (err) {
        console.error('Error creating file:', err);
        return;
        }
    console.log('File created successfully');
  });*/
    res.sendFile(path.join(__dirname, 'views', 'index.html'));
});
// API to fetch dynamic content
app.get('/api/content', async (req, res) => {
    try {
        // Define the file path in the mounted volume
        const filePath = path.join(dataDirectory, 'myfile.txt');
        console.log(filePath);
        const content = await readFileIfExists(filePath);
        res.send(content || false); // Send false if file does not exist
    } catch (err) {
        console.error('Error:', err);
        res.status(500).send('Internal Server Error');
    }
});

// Start server
const port = process.env.port || 8081;
const server = app.listen(port, () => {
    console.log('Server running on port 8081');
});
