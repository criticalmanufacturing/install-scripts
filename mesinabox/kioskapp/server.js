const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const { KubeConfig, CoreV1Api } = require('@kubernetes/client-node');

const app = express();

// Initialize Kubernetes/OpenShift configuration
const kubeConfig = new KubeConfig();
kubeConfig.loadFromDefault();

const dataDirectory = '/opt/app-root/src/data';
const installedAgentInfoFile = 'installedAgentInfo.json'
const filePath = path.join(dataDirectory, installedAgentInfoFile);
const coreApi = kubeConfig.makeApiClient(CoreV1Api);

// Serve static files from the public directory
app.use(express.static('public'));

// Function to check if a file exists and read its content
function readFileIfExists(filePath) {
    return new Promise((resolve, reject) => {
        fs.access(filePath, fs.constants.F_OK, async (err) => {
            if (err) {
                // File doesn't exist
                console.log("Error  "+err);
                resolve(false); // Resolve with false if the file doesn't exist
            } else {
                // File exists, read its content
                fs.readFile(filePath, 'utf8',async (err, data) => {
                    if (err) {
                        reject(err);
                    } else {
                        try {
                            console.log(data);
                            const jsonData = JSON.parse(data);
                            const infra = jsonData.infra;
                            console.log('Infra', infra);
                            await listPods().then(namespace => {
                                if (namespace) {
                                    resolve(infra);
                                } else {
                                    resolve(false);
                                }
                            });
                            
                          } catch (parseError) {
                            console.error('Error parsing JSON:', parseError);
                            reject(parseError);
                          }
                        
                    }
                });
            }
        });
    });
}

async function listPods() {
    try {
        const response = await coreApi.listPodForAllNamespaces();
        console.log('Pods:');
        const podName = "edgesquidproxy";
        const pods = response.body.items.filter(pod => pod.metadata.name.startsWith(podName));
        console.log(pods);
  
        if (pods.length > 0) {
            return pods[0].metadata.namespace;
        } else {
            return null;
        }
    } catch (err) {
        console.error('Error:', err);
        return null;
    }
  }
// Route to handle running the PowerShell script
app.get('/enroll', (req, res) => {

    // Set response headers for Server-Sent Events
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    // Spawn PowerShell script
    const powershell = spawn('pwsh', ['./scriptAfterEnrollment/afterEnrollment.ps1', req.query.pat, req.query.infra, req.query.agent, "./as_agent_test_2_Development_parameters.json", "./appsettings.dev.json", "OpenShiftOnPremisesTarget", "desc", "Development", ""]);

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
        if (code === 0) {
            const dataToWrite = {
                infra: req.query.infra
              };
              // Convert the data object to a JSON string
              const jsonData = JSON.stringify(dataToWrite, null, 2);
            
              // Write the JSON string to a file
              fs.writeFile(filePath, jsonData, 'utf8', (err) => {
                if (err) {
                  console.error('Error writing file:', err);
                  return;
                }
            })
        }
        res.end(); // End the response when the script exits
    });
});

// Serve index.html for root URL
app.get('/', (req, res) => {

    res.sendFile(path.join(__dirname, 'views', 'index.html'));
});
// API to fetch dynamic content
app.get('/api/content', async (req, res) => {
    try {
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
