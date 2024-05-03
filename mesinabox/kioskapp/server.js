const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const forge = require('node-forge');
const { spawn } = require('child_process');
const app = express();
const { KubeConfig, CoreV1Api, AppsV1Api, NetworkingV1Api } = require('@kubernetes/client-node');

// Initialize Kubernetes/OpenShift configuration
const kubeConfig = new KubeConfig();
kubeConfig.loadFromDefault();

const dataDirectory = '/opt/app-root/src/data';
const installedAgentInfoFile = 'installedAgentInfo.json'
const filePath = path.join(dataDirectory, installedAgentInfoFile);

// Serve static files from the public directory
app.use(express.static('public'));

// Middleware to enable CORS for certificate upload & domain change
app.use((req, res, next) => {
  // Allow requests from all origins for now ( TODO: Replace '*' with current domain )
  res.setHeader('Access-Control-Allow-Origin', '*');
  next(); // Pass control to the next middleware
});

// Middleware to set a timeout for requests
function timeoutMiddleware(timeout) {
  return function (req, res, next) {
    req.setTimeout(timeout, () => {
      const err = new Error('Request Timeout');
      err.status = 408; // Request Timeout status code
      next(err);
    });
    next();
  };
}

// Set storage engine
const storage = multer.diskStorage({
  destination: function (req, file, cb) {
    const uploadDir = './uploads';
    if (!fs.existsSync(uploadDir)) {
      fs.mkdirSync(uploadDir);
    }
    cb(null, uploadDir); // Directory where files will be uploaded
  },
  filename: function (req, file, cb) {
    cb(null, file.fieldname + '-' + Date.now() + '.pem'); // Save file with .pem extension
  }
});
// Initialize upload
const upload = multer({
  storage: storage
});


// Create Kubernetes API client
const appsApi = kubeConfig.makeApiClient(AppsV1Api);
const coreApi = kubeConfig.makeApiClient(CoreV1Api);
const networkingApi = kubeConfig.makeApiClient(NetworkingV1Api);


// Fetch the Deployment
const fetchDeployment = async (deploymentNamespace, deploymentName) => {
  try {
    const response = await appsApi.readNamespacedDeployment(deploymentName, deploymentNamespace);
    return response.body;
  } catch (error) {
    console.error('Error fetching Deployment:', error);
    throw error;
  }
};

// Function to remove the first part of the domain (subdomain)
const removeFirstPartOfDomain = (fullDomain) => {
  const parts = fullDomain.split('.');
  parts.shift();
  const rootDomain = parts.join('.');
  return rootDomain;
};

// Function to check if a deployment is ready
const waitForDeploymentReady = async (namespace, deploymentName) => {
  try {
    let deploymentReady = false;
    await new Promise(resolve => setTimeout(resolve, 5000));
    while (!deploymentReady) {
      // Fetch the deployment
      const deploymentResponse = await appsApi.readNamespacedDeployment(deploymentName, namespace);
      const deployment = deploymentResponse.body;

      // Check if all replicas are available
      const availableReplicas = deployment.status.availableReplicas || 0;
      const desiredReplicas = deployment.spec.replicas || 0;

      if (availableReplicas === desiredReplicas) {
        console.log(`Deployment ${deploymentName} is ready`);
        deploymentReady = true;    
      } else {
        console.log(`Waiting for deployment ${deploymentName} to be ready...`);
        await new Promise(resolve => setTimeout(resolve, 5000)); // Wait for 5 seconds before checking again
      }
    }
  } catch (error) {
    console.error(`Error waiting for deployment ${deploymentName} to be ready:`, error);
    throw error;
  }
};


// Update the Deployment
const updateDeployment = async (deployment, secretName, namespace, deploymentName, domain) => {
  try {

    // Update environment variable
    const container = deployment.spec.template.spec.containers.find(container => container.name === 'router');
    const envVarIndex = container.env.findIndex(envVar => envVar.name === 'ROUTER_DOMAIN');
    if (envVarIndex !== -1) {
      container.env[envVarIndex].value = domain;
    } else {
      container.env.push({ name: 'ROUTER_DOMAIN', value: domain });
    }

    // Update volume's secret name
    const volumeIndex = deployment.spec.template.spec.volumes.findIndex(volume => volume.name === 'default-certificate');
    if (volumeIndex !== -1) {
      deployment.spec.template.spec.volumes[volumeIndex].secret.secretName = secretName;
    }

    await appsApi.replaceNamespacedDeployment(deploymentName, namespace, deployment);
  } catch (error) {
    console.error('Error updating Deployment:', error);
    throw error;
  }
};

// Check if the secret exists
const checkSecretExists = async (secretName, namespace) => {
  try {
    const response = await coreApi.readNamespacedSecret(secretName, namespace);
    return response.body;
  } catch (error) {
    if (error.response.statusCode === 404) {
      return null; // Secret does not exist
    }
    console.error('Error checking if secret exists:', error);
    throw error;
  }
};

// Create or update the secret
const createOrUpdateSecret = async (secretName, namespace, data) => {
  try {
    const existingSecret = await checkSecretExists(secretName, namespace);
    if (existingSecret) {
      // if secret exists, update it
      existingSecret.data = data;
      await coreApi.replaceNamespacedSecret(secretName, namespace, existingSecret);
      console.log('Secret updated successfully:', secretName);
    } else {
      // if secret does not exist, create it
      const newSecret = {
        metadata: { name: secretName },
        data: data
      };
      await coreApi.createNamespacedSecret(namespace, newSecret);
      console.log('Secret created successfully:', secretName);
    }
  } catch (error) {
    console.error('Error creating or updating secret:', error);
    throw error;
  }
};

async function updateIngresses(newRouterDomain) {
  try {
    // Retrieve all ingresses
    const ingresses = await networkingApi.listIngressForAllNamespaces();

    // Update ingress host values
    for (const ingress of ingresses.body.items) {
      for (const rule of ingress.spec.rules) {
        const subdomain = rule.host.split('.')[0];
        rule.host = `${subdomain}.${newRouterDomain}`;
      }
      await networkingApi.replaceNamespacedIngress(ingress.metadata.name, ingress.metadata.namespace, ingress);
    }
    console.log(`Ingresses updated successfully.`);
  } catch (err) {
    console.error(`Error updating ingresses: ${err}`);
  }
}

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
  
function sendEvent(res, type, data) {
  res.write(`data: ${JSON.stringify({ type, data })}\n\n`)
}

app.get('/enroll', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'enroll.html'));
});

// Route to handle running the PowerShell script
app.get('/enrollstart', (req, res) => {
  // Set response headers for Server-Sent Events
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');

  let closeConnectionTimer;

  // Close the connection when the client disconnects
  req.on('close', () => {
    console.log('client disconnected.')

    // prevent shutting down the connection twice
    if (closeConnectionTimer != null) {
      clearTimeout(closeConnectionTimer)
    }
  });

  // Spawn PowerShell script
  const powershell = spawn('pwsh', ['./scriptAfterEnrollment/afterEnrollment.ps1', req.query.pat, req.query.infra, req.query.agent, "./as_agent_test_2_Development_parameters.json", "./appsettings.dev.json", "OpenShiftOnPremisesTarget", "desc", "Development", ""]);

  // Handle stdout data
  powershell.stdout.on('data', (data) => {
    // Send data to the client
    const currentDate = new Date();
    const formattedDate = `${currentDate.toLocaleDateString()} ${currentDate.toLocaleTimeString()}`;
    sendEvent(res, 'message', `${formattedDate}: ${data}\n`);
  });

  // Handle errors
  powershell.stderr.on('data', (data) => {
    console.error(`Error: ${data}`);
  });

  // Handle script exit - End the response when the script exits
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
    
    // give it a safe buffer of time before we shut it down manually
    sendEvent(res, 'close', code);
    closeConnectionTimer = setTimeout(() => res.end(), 2000);
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

// Serve sslCert.html for /sslcert URL
app.get('/sslcert', async (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'sslCert.html'));
});

// Route to handle file upload
app.post('/upload', upload.single('sslCertificate'), async (req, res) => {
  try {
    const subdomain = req.get('host').split('.')[0];

    if (req.file == null) {
      res.status(400).json({ message: 'No file was selected' });
      return;
    }
    const filePath = req.file.path;
    const fileContent = fs.readFileSync(filePath, 'utf8');

    // Parse the certificate
    const cert = forge.pki.certificateFromPem(fileContent);
    // Get the subject field of the certificate
    const subjectAttributes = cert.subject.attributes;

    // Extract the domain name from the certificate's subject
    let domainNames = [];
    subjectAttributes.forEach(attribute => {
      if (attribute.shortName === 'CN') {
        domainNames.push(attribute.value);
      }
    });
    let domain;
    if (domainNames.length > 0) {
        domain = removeFirstPartOfDomain(domainNames[0]);
    }

    const secretName = 'ssl-certificate-secret';
    const namespace = 'openshift-ingress';

    const secretData = {
      'tls.crt': Buffer.from(fileContent).toString('base64')
    };

    // Start updating k8s object only after closing the request with a status 200,
    // otherwise the router restart will make the request fail with a 504 gateway timeout
    setTimeout(async () => {
      await createOrUpdateSecret(secretName, namespace, secretData)
      .then(() => {
        console.log('Secret creation or update completed successfully');
      })
      .catch((error) => {
        console.error('An error occurred during secret creation or update:', error);
      });

      try {
        const deploymentNamespace = 'openshift-ingress';
        const deploymentName = 'router-default';
        const deployment = await fetchDeployment(deploymentNamespace, deploymentName);
        await updateDeployment(deployment, secretName, deploymentNamespace, deploymentName, domain);
        await waitForDeploymentReady(deploymentNamespace, deploymentName);
        await updateIngresses(domain);
        res.redirect(`${subdomain}.${domain}`);
      } catch (error) {
        console.log('An error occurred:', error);
      }
    }, 1000);
    
    res.status(200).json({ message: 'Upload successful, updating domain...', newDomain: `${subdomain}.${domain}` });
  } catch (error) {
    console.log('Error:', error);
    res.status(500).json({ message: 'Internal server error' });
  }
});

// Start server
const port = process.env.port || 8081;
const server = app.listen(port, () => {
  console.log('Server running on port 8081');
});