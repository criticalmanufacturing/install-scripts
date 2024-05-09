const express = require('express');
const { spawn } = require('child_process');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const forge = require('node-forge');
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

// Check if InfrastructureAgent status file exists and get its content
function getInfraAgentIfInstalled(filePath) {
  return new Promise((resolve, reject) => {
    fs.access(filePath, fs.constants.F_OK, async (err) => {
      if (err) {
        // File doesn't exist - no agent was installed previously
        console.log("Error  " + err);
        resolve(JSON.stringify({})); // Resolve with empty object if the file doesn't exist
      } else {
        // Agent was installed previously
        fs.readFile(filePath, 'utf8', async (err, data) => {
          if (err) {
            reject(err);
          } else {
            try {
              // Parse installed agent json data
              console.log(data);
              const jsonData = JSON.parse(data);
              const infraName = jsonData.infraName;
              const infraId = jsonData.infraId;
              console.log('infraName', infraName);
              console.log('infraId', infraId);
              await tryGetInstalledAgentNamespace().then(namespace => {
                if (namespace) {
                  resolve(JSON.stringify({infraName: infraName, infraId: infraId}));
                } else {
                  resolve(JSON.stringify({}));
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

// Returns the namespace of an existing EdgeSquidProxy pod, null if there is none. EdgeSquidProxy is only used in agents, so its asking for a installed agent's namespace.
async function tryGetInstalledAgentNamespace() {
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

  const appSettingsRaw = fs.readFileSync('./scriptAfterEnrollment/appsettings.json');
  let appSettings = JSON.parse(appSettingsRaw);

  // Set or override parameters dynamically
  appSettings.ClientConfiguration.HostAddress = `${process.env.CUSTOMER_PORTAL_ADDRESS}:${process.env.CUSTOMER_PORTAL_PORT}`
  appSettings.ClientConfiguration.ClientTenantName = process.env.TENANT_NAME;
  appSettings.ClientConfiguration.ClientId = process.env.CLIENT_ID;
  appSettings.ClientConfiguration.SecurityPortalBaseAddress = `https://${process.env.SECURITY_PORTAL_ADRESS}:${process.env.CUSTOMER_PORTAL_PORT}`;

  // Convert the modified settings back to JSON
  const updatedSettings = JSON.stringify(appSettings, null, 2);

  // Write the updated settings back to the appsettings.json file
  fs.writeFileSync('./scriptAfterEnrollment/appsettings.json', updatedSettings);


  // Spawn PowerShell script
  const powershell = spawn('pwsh', ['./scriptAfterEnrollment/afterEnrollment.ps1', req.query.pat, req.query.infraName, req.query.agent, "./as_agent_test_2_Development_parameters.json", "./appsettings.json", "OpenShiftOnPremisesTarget", "desc", "Development", ""]);

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
        infraId: req.query.infraId,
        infraName: req.query.infraName
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


const pipePath = "./pipe/resizeDiskPipe";
const outputPath = "./pipe/output.txt";

// API endpoint to execute script to expand disk space
app.post('/expandDisk', (req, res) => {

  // Open the FIFO in write mode
  if (fs.existsSync(outputPath)) {
    fs.unlinkSync(outputPath);
  }
  const fifoStream = fs.createWriteStream(pipePath, { flags: 'a' }); // 'a' flag appends data to the FIFO

  // Write the script content to the FIFO
  fifoStream.write(script);

  console.log('Script injected into FIFO for execution.');
  fifoStream.close();

  // Start listening for exit code

  let timeout = 10000; //stop waiting after 10 seconds (something might be wrong)
  const timeoutStart = Date.now();
  const myLoop = setInterval(function () {
    if (Date.now() - timeoutStart > timeout) {
      clearInterval(myLoop);
      res.status(408).send('Expand Disk: Operation timed out.');
    } else {
      //if output.txt exists, read it
      if (fs.existsSync(outputPath)) {
        clearInterval(myLoop);
        const data = fs.readFileSync(outputPath).toString().trim();
        if (fs.existsSync(outputPath)) {
          fs.unlinkSync(outputPath); //delete the output file
        }
        if (data === '0') {
          res.status(200).send("Disk successfully expanded!");
        } else {
          res.status(500).send("There was an issue while trying to expand the disk!");
        }
      }
    }
  }, 300);

});

const script = `
largest_disk_device=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -d -n | awk '$2 ~ /^[0-9]/ && $3=="disk" {print $2,$1,$4}' | sort -nr | head -n 1 | awk '{print $2}')

pvdisplay "/dev/\${largest_disk_device}"

if [ $? -ne 0 ]; then
    pvcreate "/dev/\${largest_disk_device}"
    echo "Physical volume created on /dev/\${largest_disk_device}"

    vgcreate externalDiskVG "/dev/\${largest_disk_device}"
    echo "Volume group externalDiskVG created"
else
    echo "Physical volume already exists on /dev/\${largest_disk_device}"
fi

pvresize "$(pvdisplay --units b -c | awk -F: \'{print $1,$7}\' | sort -k2 -nr | head -n1 | awk \'{print $1}\')"
`;

// Serve index.html for root URL
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

app.get('/api/config/portalAddress', (req, res) => {
  const portalAddress = process.env.CUSTOMER_PORTAL_ADDRESS;
  res.json({ customerPortalAddress: portalAddress });
});

// API to fetch if agent is installed
app.get('/api/agentInstalled', async (req, res) => {
  try {
    const agentStatus = await getInfraAgentIfInstalled(filePath);
    res.send(agentStatus || JSON.stringify({})); // Send empty object if file/agent does not exist
  } catch (err) {
    console.error('Error:', err);
    res.status(500).send('Internal Server Error');
  }
});

const connectivityCheckTimeout = parseInt(process.env.CONNECTION_CHECK_TIMEOUT) || 30000;

app.get('/api/connectivity', async (req, res) => {

  const registryAddress = `https://${process.env.REGISTRY_ADDRESS}` 
  const portalAddress = `https://${process.env.CUSTOMER_PORTAL_ADDRESS}/api/ping`
  const results = {};

  try {
    // Execute the pings in parallel
    const [portalResponse, registryResponse] = await Promise.allSettled([
      fetch(portalAddress, { signal: AbortSignal.timeout(connectivityCheckTimeout) }),
      fetch(registryAddress, { signal: AbortSignal.timeout(connectivityCheckTimeout) })
    ]);

    // Process responses
    results['portal'] = portalResponse.status === 'fulfilled' && portalResponse.value.ok;
    results['registry'] = registryResponse.status === 'fulfilled' && registryResponse.value.ok;
    res.json(results);
    console.log(JSON.stringify(results));
  } catch (error) {
    console.error('Error during connectivity check:', error);
    res.status(500).json({ error: 'An error occurred during connectivity check.' });
  }
})

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
          return;
        });

      try {
        const deploymentNamespace = 'openshift-ingress';
        const deploymentName = 'router-default';
        const deployment = await fetchDeployment(deploymentNamespace, deploymentName);
        await updateDeployment(deployment, secretName, deploymentNamespace, deploymentName, domain);
        await waitForDeploymentReady(deploymentNamespace, deploymentName);
        await updateIngresses(domain);
      } catch (error) {
        console.log('An error occurred:', error);
      }
    }, 1000);

    res.status(200).json({ message: 'Upload successful, updating domain...', newDomain: `${subdomain}.${domain}` });
  } catch (error) {
    console.log('Error:', error);
    res.status(500).json({ message: error.message });
  }
});

// Start server
const port = process.env.port || 8081;
const server = app.listen(port, () => {
  console.log('Server running on port 8081');
});