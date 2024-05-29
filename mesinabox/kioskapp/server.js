const express = require('express');
const http = require('http');
const https = require('https');
const { URL } = require('url');
const { spawn } = require('child_process');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const forge = require('node-forge');
const app = express();
const { KubeConfig, CoreV1Api, AppsV1Api, NetworkingV1Api } = require('@kubernetes/client-node');
const { HttpsProxyAgent } = require('https-proxy-agent');

//#region Init / Constants

// Initialize Kubernetes/OpenShift configuration
const kubeConfig = new KubeConfig();
kubeConfig.loadFromDefault();

const dataDirectory = '/opt/app-root/src/data';
const installedAgentInfoFile = 'installedAgentInfo.json'
const filePath = path.join(dataDirectory, installedAgentInfoFile);
const pipePath = "./pipe/pipe";
const pipeOutputPath = "./pipe/output.txt";
const proxyFilePath = path.join(dataDirectory, 'proxyInfo.json');

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

const registryAddress = `https://${process.env.REGISTRY_ADDRESS}`;
const portalAddress = `https://${process.env.CUSTOMER_PORTAL_ADDRESS}/api/ping`;

const edgeSquidProxyDeploymentName = "edgesquidproxy";

//#region Proxy Configs

let currentProxyConfigs = {
  // basic proxy info
  address: null,
  port: null,
  useAuth: null,
  user: null,
  password: null,
  // computed urls created from the basic info
  hostAddress: null,
  hostAddressEscaped: null,
  fullAuth: null,
  fullAuthEscaped: null,
  fullProxyAddr: null,
  fullProxyAddrEscaped: null,
  authProxyRequestHeader: null
};

let httpsAgent = null; // HttpsProxyAgent

const deleteProxyScript = `
  echo "Delete Proxy START"
  echo -n "" > /etc/environment
  unset http_proxy
  unset https_proxy
  unset no_proxy

  mkdir -p /etc/systemd/system/crio.service.d/
  mkdir -p /etc/systemd/system/rpm-ostreed.service.d/
  echo -n "" > /etc/systemd/system/rpm-ostreed.service.d/00-proxy.conf
  echo -n "" > /etc/systemd/system/crio.service.d/00-proxy.conf
  echo "systemctl start"
  systemctl daemon-reload
  echo "systemctl 0"
  systemctl restart rpm-ostreed.service
  echo "systemctl 1"
  systemctl restart crio
  echo "systemctl 2"
  systemctl restart microshift
  echo "Delete Proxy END"
  `;

const createOrUpdateProxyScript = `
  echo "Create Proxy START"
  echo "http_proxy={FULL_PROXY_ADDR}" > /etc/environment
  echo "https_proxy={FULL_PROXY_ADDR}" >> /etc/environment
  echo "no_proxy=localhost,127.0.0.1" >> /etc/environment
  source /etc/environment
  echo "source'd /etc/environment"

  mkdir -p /etc/systemd/system/crio.service.d/
  mkdir -p /etc/systemd/system/rpm-ostreed.service.d/
  
  cat > /etc/systemd/system/crio.service.d/00-proxy.conf <<EOF
  [Service]
  Environment=NO_PROXY="localhost,127.0.0.1"
  Environment=HTTP_PROXY="{FULL_PROXY_ADDR}"
  Environment=HTTPS_PROXY="{FULL_PROXY_ADDR}"
  EOF
  
  cat > /etc/systemd/system/rpm-ostreed.service.d/00-proxy.conf <<EOF
  [Service]
  Environment="http_proxy={FULL_PROXY_ADDR}"
  EOF
  
  echo "systemctl start"
  systemctl daemon-reload
  echo "systemctl 0"
  systemctl restart rpm-ostreed.service
  echo "systemctl 1"
  systemctl restart crio
  echo "systemctl 2"
  systemctl restart microshift
  echo "Create Proxy END"
  `;

//#endregion

//#endregion

//#region Upload Certificate

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

//#endregion

//#region Infra Agent Status

// Check if InfrastructureAgent status file exists and get its content
function getInfraAgentIfInstalled(filePath) {
  return new Promise((resolve, reject) => {
    fs.access(filePath, fs.constants.F_OK, async (err) => {
      if (err) {
        // File doesn't exist - no agent was installed previously
        console.log("Error  " + err);
        resolve(null); // Resolve with null if the file doesn't exist
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
                  resolve(null);
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
    const pods = response.body.items.filter(pod => pod.metadata.name.startsWith(edgeSquidProxyDeploymentName));
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

//#endregion

//#region Expand Disk

// Helper function to write to the FIFO and handle closing
const writeToFifo = async (fifoPath, content) => {
  return new Promise((resolve, reject) => {
    const fifoStream = fs.createWriteStream(fifoPath, { flags: 'a' });
    fifoStream.write(content, (err) => {
      if (err) {
        reject(err);
      } else {
        console.log('Script injected into FIFO for execution.');
        fifoStream.end(resolve);
      }
    });
  });
};

// Function to read fifo output file
const readFifoOutput = (res, callback, timeoutToThrow) => {
  let timeout = timeoutToThrow ?? 10000; //stop waiting after 10 (something might be wrong)
  const timeoutStart = Date.now();
  const myLoop = setInterval(function () {
    if (Date.now() - timeoutStart > timeout) {
      clearInterval(myLoop);
      if (res != null) {
        res.status(408).send('Expand Disk: Operation timed out.');
      } else {
        throw new Error('Inserted Pipe Instructions: Operation timed out.');
      }
    } else {
      //if output.txt exists, read it
      if (fs.existsSync(pipeOutputPath)) {
        clearInterval(myLoop);
        const data = fs.readFileSync(pipeOutputPath).toString().trim();
        if (fs.existsSync(pipeOutputPath)) {
          fs.unlinkSync(pipeOutputPath); //delete the output file
        }
        callback(data);
      }
    }
  }, 300);
}

const checkIfDiskExists = `
largest_disk_device=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -d -n | awk '$2 ~ /^[0-9]/ && $3=="disk" {print $2,$1,$4}' | sort -nr | head -n 1 | awk '{print $2}')

pvdisplay "/dev/\${largest_disk_device}"
`;

const createPVScript = `
largest_disk_device=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -d -n | awk '$2 ~ /^[0-9]/ && $3=="disk" {print $2,$1,$4}' | sort -nr | head -n 1 | awk '{print $2}')

pvcreate "/dev/\${largest_disk_device}"
    echo "Physical volume created on /dev/\${largest_disk_device}"

    vgcreate externalDiskVolumeGroup "/dev/\${largest_disk_device}"
    echo "Volume group externalDiskVG created"
    mv /etc/microshift/lvmd.yaml.default /etc/microshift/lvmd.yaml
`;

const restartMicroshiftService =  `systemctl restart microshift` 

const expandScript = `
pvresize "$(pvdisplay --units b -c | awk -F: \'{print $1,$7}\' | sort -k2 -nr | head -n1 | awk \'{print $1}\')"
`;

//#endregion

//#region Proxy Update

// Validates that the information on the proxy input is valid
function validateProxyInput(newProxyConfig) {
  if (!((newProxyConfig.address && newProxyConfig.port) || (!newProxyConfig.address && !newProxyConfig.port))) { // If one is defined but the other isn't
    return {valid:false, reason:'Proxy adress and port need to be both defined to set a proxy, or none should be set to remove it'};
  }
  if (!newProxyConfig.address && !newProxyConfig.port) { // basic proxy info "falsy"
    if (newProxyConfig.useAuth && (newProxyConfig.user || newProxyConfig.password)) {
      return {valid:false, reason:'Proxy authentication should only be set if address and port are also set'};
    }
  } else { // basic proxy set
    if (newProxyConfig.useAuth && (!newProxyConfig.user != !newProxyConfig.password)) { // If one is defined but the other isn't
      return {valid:false, reason:'Proxy username and password need to be both defined to set authentication, or none should be set to remove it'};
    } 
    if (newProxyConfig.useAuth && (!newProxyConfig.user && !newProxyConfig.password)) { // useAuth true but no auth defined
      return {valid:false, reason:'Proxy username and password need to be both defined to set authentication'};
    }
  }
  return {valid:true};
}

function calculateProxyFullUrl() {
  if (!currentProxyConfigs.address && !currentProxyConfigs.port) {
    clearCurrentProxyFullUrl();
    return;
  }

  const escapingChars = {
    '@': "\\@",
    '\\': "\\\\"
  };
  currentProxyConfigs.hostAddress = `${currentProxyConfigs.address}:${currentProxyConfigs.port}`;
  currentProxyConfigs.hostAddressEscaped = currentProxyConfigs.hostAddress.replace(/[\\]/g, m => escapingChars[m]); // escapes \ -> \\

  const proxyOptions = new URL(`http://${currentProxyConfigs.hostAddress}`);

  if (currentProxyConfigs.useAuth) {
    currentProxyConfigs.fullAuth = `${currentProxyConfigs.user}:${currentProxyConfigs.password}`;
    currentProxyConfigs.fullAuthEscaped = currentProxyConfigs.fullAuth.replace(/[@\\]/g, m => escapingChars[m]); // escapes @ -> \@ && \-> \\
    currentProxyConfigs.authProxyRequestHeader = 'Basic ' + Buffer.from(currentProxyConfigs.fullAuth).toString('base64');

    currentProxyConfigs.fullProxyAddr = `http://${currentProxyConfigs.fullAuth}@${currentProxyConfigs.hostAddress}`;
    currentProxyConfigs.fullProxyAddrEscaped = `http://${currentProxyConfigs.fullAuthEscaped}@${currentProxyConfigs.hostAddressEscaped}`;
    
    proxyOptions.username = currentProxyConfigs.user;
    proxyOptions.password = currentProxyConfigs.password;
  } else {
    currentProxyConfigs.fullProxyAddr = `http://${currentProxyConfigs.hostAddress}`;
    currentProxyConfigs.fullProxyAddrEscaped = `http://${currentProxyConfigs.hostAddressEscaped}`;
    
    currentProxyConfigs.fullAuth = null;
    currentProxyConfigs.fullAuthEscaped = null;
    currentProxyConfigs.authProxyRequestHeader = null;
  }
  
  httpsAgent = new HttpsProxyAgent(proxyOptions);
}

function clearCurrentProxyFullUrl() {
  currentProxyConfigs.hostAddress = null;
  currentProxyConfigs.hostAddressEscaped = null;
  currentProxyConfigs.fullAuth = null;
  currentProxyConfigs.fullAuthEscaped = null;
  currentProxyConfigs.fullProxyAddr = null;
  currentProxyConfigs.fullProxyAddrEscaped = null;
  currentProxyConfigs.authProxyRequestHeader = null;

  httpsAgent = null;
}

// Update the Agent proxy variables if it already exists or create/remove them
async function updateAgentProxy() {
  try {
    const namespace = await tryGetInstalledAgentNamespace();
    if (!namespace) {
      console.log("No namespace for agent detected, skipping updateAgentProxy!")
      return;
    }
    const deployment = await fetchDeployment(namespace, edgeSquidProxyDeploymentName);

    // Update environment variables
    const container = deployment.spec.template.spec.containers.find(container => container.name.startsWith(edgeSquidProxyDeploymentName));
    if (container == null) {
      console.error("Attempted to update proxy of agent, but unable to find agent container.");
      return;
    }
    
    const httpProxyEnvVarIndex = container.env.findIndex(envVar => envVar.name === 'HTTP_PROXY');
    const httpsProxyEnvVarIndex = container.env.findIndex(envVar => envVar.name === 'HTTPS_PROXY');
    const noProxyEnvVarIndex = container.env.findIndex(envVar => envVar.name === 'NO_PROXY');
    if (!currentProxyConfigs.address) { // no address = remove proxy
      if (httpProxyEnvVarIndex !== -1) {
        container.env.splice(httpProxyEnvVarIndex, 1);
      }
      if (httpsProxyEnvVarIndex !== -1) {
        container.env.splice(httpsProxyEnvVarIndex, 1);
      }
      if (noProxyEnvVarIndex !== -1) {
        container.env.splice(noProxyEnvVarIndex, 1);
      }
    } else {
      if (httpProxyEnvVarIndex !== -1) {
        container.env[httpProxyEnvVarIndex].value = currentProxyConfigs.fullProxyAddrEscaped;
      } else {
        container.env.push({ name: 'HTTP_PROXY', value: fullProxyAddrEscaped });
      }
      if (httpsProxyEnvVarIndex !== -1) {
        container.env[httpsProxyEnvVarIndex].value = fullProxyAddrEscaped;
      } else {
        container.env.push({ name: 'HTTPS_PROXY', value: fullProxyAddrEscaped });
      }
      if (noProxyEnvVarIndex !== -1) {
        container.env[noProxyEnvVarIndex].value = "localhost,127.0.0.1";
      } else {
        container.env.push({ name: 'NO_PROXY', value: "localhost,127.0.0.1" });
      }
    }

    await appsApi.replaceNamespacedDeployment(edgeSquidProxyDeploymentName, namespace, deployment);
  } catch (error) {
    console.error('Error updating Agent Deployment:', error);
  }
}

// Function to update proxy settings - at first on this pod to make pings go through the proxy, and then on the whole network. (proxy on this pod may then have to be reverted after network restart)
async function updateProxy() {
  await updateAgentProxy();

  // Open the FIFO in write mode
  if (fs.existsSync(pipeOutputPath)) {
    fs.unlinkSync(pipeOutputPath);
  }
  const fifoStream = fs.createWriteStream(pipePath, { flags: 'a' }); // 'a' flag appends data to the FIFO

  let proxyCommands = !currentProxyConfigs.address ? deleteProxyScript : createOrUpdateProxyScript; // no address = remove proxy
  proxyCommands = proxyCommands.replaceAll("{FULL_PROXY_ADDR}", currentProxyConfigs.fullProxyAddrEscaped);

  fifoStream.write(proxyCommands);

  console.log(`${!currentProxyConfigs.address ? "Delete Proxy":"Create Proxy"} script injected into FIFO for execution.`);
  fifoStream.close();

  await writeToFifo(pipePath, proxyCommands);
  readFifoOutput(undefined, async (output) => {
    if (output === '0') {
      console.log(`Proxy settings updated. New proxy: ${currentProxyConfigs.fullProxyAddr}`);
      return;
    } else {
      console.error('Update Proxy: There was an issue while trying to change the proxy configuration.');
    }
  }, 300000); // 5 minute script timeout
}

async function makeProxydGet(url, proxyHost, proxyPort, proxyAuth) {
  return new Promise ((resolve, reject) => {
    let req;
    const urlParsed = new URL(url);
    if (currentProxyConfigs.address) {
      if (urlParsed.protocol == 'https:') {
        // console.log("https w/ proxy");
        req = https.get(url, {agent: httpsAgent, timeout: connectivityCheckTimeout});
      } else {
        // console.log("http w/ proxy");
        const options = {
          host: currentProxyConfigs.address,
          port: currentProxyConfigs.port,
          path: url,
          timeout: connectivityCheckTimeout,
          headers: {
            Host: urlParsed.host
          }
        };
        if (currentProxyConfigs.fullAuth) {
          options.headers['Proxy-Authorization'] = currentProxyConfigs.authProxyRequestHeader;
        }
        req = http.get(options);
      }
    } else {
      const httpModule = urlParsed.protocol == 'https:' ? https : http;
      req = httpModule.get(url, {timeout: connectivityCheckTimeout});
    }

    req.on('response', res => {
      resolve(res);
    });

    req.on('error', err => {
      console.log("Proxied Request Error Code:", err.code);
      reject(err);
    });

    req.on('timeout', () => {
      req.destroy();
      console.log(`Request timeout to: ${urlParsed}`);
      reject();
    });

    req.end();
  }); 
}

// Saves the current proxy settings to a local file.
function saveProxyConfigsToFile() {
  const dataToWrite = { 
    proxyAddr: currentProxyConfigs.address,
    proxyPort: currentProxyConfigs.port,
    proxyUseAuth: currentProxyConfigs.useAuth,
    proxyUser: currentProxyConfigs.user,
    proxyPass: currentProxyConfigs.password
  };
  const jsonData = JSON.stringify(dataToWrite, null, 2);
  console.log("proxyConfig:", jsonData);
  fs.writeFile(proxyFilePath, jsonData, 'utf8', (err) => {
    if (err) {
      console.error('Error writing file:', err);
      return;
    }
  });
}

// Check if proxy configurations were saved in file and load its values
function getSavedProxyConfigs() {
  return new Promise((resolve, reject) => {
    fs.access(proxyFilePath, fs.constants.F_OK, async (err) => {
      if (err) {
        // File doesn't exist
        console.log("Error accessing proxy file, may not exist: " + err);
        resolve({proxyAddr: undefined, proxyPort: undefined, proxyUseAuth: undefined, proxyUser: undefined, proxyPass: undefined}); // Resolve with empty if the file doesn't exist
      } else {
        fs.readFile(proxyFilePath, 'utf8', async (err, data) => {
          if (err) {
            reject(err);
          } else {
            try {
              // Parse proxy config json data
              console.log(data);
              const jsonData = JSON.parse(data);
              const proxyAddr = jsonData.proxyAddr;
              const proxyPort = jsonData.proxyPort;
              const proxyUseAuth = jsonData.proxyUseAuth;
              const proxyUser = jsonData.proxyUser;
              const proxyPass = jsonData.proxyPass;
              console.log('proxySavedJsonData', jsonData);
              resolve({proxyAddr: proxyAddr, proxyPort: proxyPort, proxyUseAuth: proxyUseAuth, proxyUser: proxyUser, proxyPass: proxyPass});
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

// Load saved proxy configs on start
getSavedProxyConfigs().then((proxyConfigs) => {
  console.log(proxyConfigs);
  currentProxyConfigs.address = proxyConfigs.proxyAddr;
  currentProxyConfigs.port = proxyConfigs.proxyPort;
  currentProxyConfigs.useAuth = proxyConfigs.proxyUseAuth;
  currentProxyConfigs.user = proxyConfigs.proxyUser;
  currentProxyConfigs.password = proxyConfigs.proxyPass;
  calculateProxyFullUrl();  
}).catch();// ignore

//#endregion

function sendEvent(res, type, data) {
  res.write(`data: ${JSON.stringify({ type, data })}\n\n`);
}

//#region API

//#region Enroll API
app.get('/enroll', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'enroll.html'));
});

// Route to handle running the PowerShell script
app.get('/enrollstart', async (req, res) => {
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
      });

      updateAgentProxy();
    }

    // give it a safe buffer of time before we shut it down manually
    sendEvent(res, 'close', code);
    closeConnectionTimer = setTimeout(() => res.end(), 2000);
  });
});
//#endregion

//#region Expand Disk API

// API endpoint to execute script to expand disk space
app.post('/expandDisk', async (req, res) => {

  // Open the FIFO in write mode
  if (fs.existsSync(pipeOutputPath)) {
    fs.unlinkSync(pipeOutputPath);
  }
  await writeToFifo(pipePath, checkIfDiskExists);
  readFifoOutput(res, async (output) => {
      if (output === '0') {
        await writeToFifo(pipePath, expandScript);
        readFifoOutput(res, async(output) => {
          if (output === '0') {
            res.status(200).send("Disk successfully expanded!");
          } else {
            res.status(500).send("There was an issue while trying to expand the disk!");
          }})
      } else {
       await writeToFifo(pipePath, createPVScript);
       readFifoOutput(res, async (output) => {
          if (output === '0') {
            res.status(200).send("System is restarting. Refresh it in 1 minute.");
            await writeToFifo(pipePath, restartMicroshiftService);
          } else {
            res.status(500).send("There was an issue while trying to expand the disk!");
          }})
      }
    })
});

//#endregion

//#region Main Page API

// Serve index.html for root URL
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

app.get('/api/config/portalAddress', (req, res) => {
  res.json({ customerPortalAddress: portalAddress });
});

// API to fetch if agent is installed
app.get('/api/agentInstalled', async (req, res) => {
  try {
    const agentStatus = await getInfraAgentIfInstalled(filePath);
    if (agentStatus == null) {
      res.status(404).send('No Agent is Installed');
    } else {
      res.send(agentStatus);
    }
  } catch (err) {
    console.error('Error:', err);
    res.status(500).send('Internal Server Error');
  }
});

const connectivityCheckTimeout = parseInt(process.env.CONNECTION_CHECK_TIMEOUT) || 30000;

app.get('/api/connectivity', async (req, res) => {
  const results = {};

  try {
    // Execute the pings in parallel
    const [portalResponse, registryResponse] = await Promise.allSettled([
      makeProxydGet(portalAddress),
      makeProxydGet(registryAddress)
    ]);

    // Process responses
    if (portalResponse.status === 'rejected') {
      console.error("Portal Connectivity Check Error:", portalResponse.reason);
    }
    if (registryResponse.status === 'rejected') {
      console.error("Registry Connectivity Check Error:", registryResponse.reason);
    }
    results['portal'] = portalResponse.status === 'fulfilled' && portalResponse.value.statusCode >= 200 && portalResponse.value.statusCode <= 399; // Redirects (3xx) will be considered connected too
    results['registry'] = registryResponse.status === 'fulfilled' && registryResponse.value.statusCode >= 200 && registryResponse.value.statusCode <= 399;
    res.json(results);
    console.log(JSON.stringify(results));
  } catch (error) {
    console.error('Error during connectivity check:', error);
    res.status(500).json({ error: 'An error occurred during connectivity check.' });
  }
});

//#endregion

//#region Upload Certificates API

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

//#endregion

//#region Proxy Config API

app.get('/proxy', async (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'proxy.html'));
});

app.post('/changeProxy', upload.none(), async (req, res) => {
  console.log(req.body);
  const newProxyConfig = structuredClone(currentProxyConfigs);
  newProxyConfig.address = req.body.proxyAddr;
  newProxyConfig.port = req.body.proxyPort;
  newProxyConfig.useAuth = req.body.UseAuth === 'true';
  newProxyConfig.user = req.body.proxyUser;
  newProxyConfig.password = req.body.proxyPass;

  try {
    const valRes = validateProxyInput(newProxyConfig);
    if (!valRes.valid) {
      res.status(400).send(valRes.reason);
      console.error('Non-valid Proxy:', valRes.reason);
      return;
    }
    currentProxyConfigs = newProxyConfig;
    saveProxyConfigsToFile();
    calculateProxyFullUrl();
    updateProxy().catch((err) => console.error(err));
    res.status(200).send('Proxy settings updated successfully! System is restarting.');
  } catch (error) {
    console.error('Error updating proxy settings: ', error);
    res.status(500).send('Failed to update proxy settings.');
    return;
  }
});

app.get('/proxyConfig', async (req, res, next) => {
  try {
    res.json({
      proxyAddr: currentProxyConfigs.address,
      proxyPort: currentProxyConfigs.port,
      proxyUseAuth: currentProxyConfigs.useAuth,
      proxyUser: currentProxyConfigs.user,
      proxyPass: currentProxyConfigs.password
    });
  } catch (err) {
    console.error('Error retrieving proxy settings: ', error);
    res.status(500).send('Error retrieving proxy settings: ', error);
    return;
  }
});

//#endregion

//#endregion

// Start server
const port = process.env.port || 8081;
const server = app.listen(port, () => {
  console.log('Server running on port 8081');
});