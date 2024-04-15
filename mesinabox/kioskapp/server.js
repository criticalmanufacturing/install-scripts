const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const forge = require('node-forge');
const { spawn } = require('child_process');
const app = express();
const { KubeConfig, CoreV1Api, AppsV1Api, NetworkingV1Api } = require('@kubernetes/client-node');

// Serve static files from the public directory
app.use(express.static('public'));

// Initialize Kubernetes/OpenShift configuration
const kubeConfig = new KubeConfig();
kubeConfig.loadFromDefault();

// Middleware to set a timeout for requests
function timeoutMiddleware(timeout) {
  return function(req, res, next) {
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

// Function to list pods from all namespaces
async function listPods() {
  try {
      const response = await coreApi.listPodForAllNamespaces();
      console.log('Pods:');
      const podName = "edgesquidproxy";
      const pods = response.body.items.filter(pod => pod.metadata.name.startsWith(podName));

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
      const currentDate = new Date();
      const formattedDate = `${currentDate.toLocaleDateString()} ${currentDate.toLocaleTimeString()}`;
      res.write(`${formattedDate}: ${data}\n`);
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
app.get('/', async (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'index.html'));
  /*await listPods().then(namespace => {
      if (namespace) {
          res.sendFile(path.join(__dirname, 'views','agentAlreadyExists.html'), {"namespace" : namespace});
      } else {
          res.sendFile(path.join(__dirname, 'views', 'index.html'));
      }});*/
  
});


// Route to handle file upload
app.post('/upload', upload.single('sslCertificate'), async (req, res) => {
    try {
      const subdomain = req.get('host').split('.')[0];

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
      // Initialize Kubernetes configuration
      const kubeConfig = new KubeConfig();
      kubeConfig.loadFromDefault();

      const secretName = 'ssl-certificate-secret';
      const namespace = 'openshift-ingress';

      const secretData = {
        'tls.crt': Buffer.from(fileContent).toString('base64')
      };
      
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
        await  updateIngresses(domain);
        res.redirect(`${subdomain}.${domain}`);
      } catch (error) {
        console.log('An error occurred:', error);
      }
    } catch (error) {
      console.log('Error:', error);
      res.status(500).send('Internal Server Error');
    }
  }); 

// Start server
const port = process.env.port || 8081;
const server = app.listen(port, () => {
    console.log('Server running on port 8081');
});

