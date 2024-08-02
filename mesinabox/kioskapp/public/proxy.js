// Constants
const proxyAddrField = document.getElementById('proxyAddrField');
const proxyPortField = document.getElementById('proxyPortField');
const proxyUserField = document.getElementById('proxyUserField');
const proxyPassField = document.getElementById('proxyPassField');
const useAuthCheck = document.getElementById('proxyUseAuthCheckbox');

const changeProxyForm = document.getElementById('ProxyForm');
const changeProxyBtn = document.getElementById('ChangeProxyBtn');

const feedbackDiv = document.getElementById('proxyFeedbackMessage');
const statusDiv = document.getElementById('proxyStatusMessage');

const changeProxyBtnLoadingInitStr = 'Loading Config...';
const changeProxyBtnApplyProxyStr = 'Update Proxy';
const changeProxyBtnInProgressStr = 'In Progress...';

const proxyPollingTimeoutSeconds = 300;

// Proxy original configs
let proxyAddr = null;
let proxyPort = null;
let proxyUseAuth = null;
let proxyUser = null;
let proxyPass = null;

// Polling after proxy restart
let proxyPollingInterval;
let proxyPollingTimeout;
let proxyPollingStatusTextInterval;

let proxyFeedbackText = null;
let proxyPollStatusText = null;

function createFeedbackMessage(message, isError, isSuccess) {
  if (!proxyFeedbackText) {
    feedbackDiv.replaceChildren(); // removes all child nodes
    proxyFeedbackText = document.createElement('p');
    feedbackDiv.appendChild(proxyFeedbackText);
  }
  proxyFeedbackText.innerHTML = message;
  proxyFeedbackText.style.color = isError ? "red" : (isSuccess ? "green" : null);
}

function createStatusMessage(message) {
  if (!proxyPollStatusText) {
    statusDiv.replaceChildren(); // removes all child nodes
    proxyPollStatusText = document.createElement('p');
    statusDiv.appendChild(proxyPollStatusText);
  }
  proxyPollStatusText.innerHTML = message;
}

function enableDisableProxyAuthentication(useAuthBool) {
  useAuthCheck.checked = useAuthBool;
  document.querySelector("#proxyUserField").disabled = !useAuthBool;
  document.querySelector("#proxyPassField").disabled = !useAuthBool;
}

function onProxyRestarted() {
  clearTimeout(proxyPollingTimeout);
  clearInterval(proxyPollingInterval);
  clearInterval(proxyPollingStatusTextInterval);
  createStatusMessage(`Cluster restart complete, reloading page...`);
  proxyPollStatusText.style.color = "green";
  // setTimeout(() => window.location.reload(), 5000);
}

async function pingBackendDueToRestart() {
  try {
    const response = await fetch('/isExecutingCommands');
    if (!response.ok) {
      throw new Error("Response not ok", { cause: response });
    }
    const resJson = await response.json();
    if (resJson.isExecutingCommands == true) {
      createStatusMessage(`Cluster services are still restarting...`);
    } else {
      onProxyRestarted();
    }
  } catch (error) {
    // Handle errors (e.g., network issues, server errors)
    console.error('Error checking pinging backend after proxy change:', error);
  }
}

// Display the seconds remaining until timeout, decreasing every second
function displayProxyWaitingProgress() {
  createStatusMessage(`Waiting up to ${proxyPollingTimeoutSeconds} seconds for the cluster to restart...`);

  let remainingTimeoutSeconds = proxyPollingTimeoutSeconds;
  proxyPollingStatusTextInterval = setInterval(() => {
    remainingTimeoutSeconds--;
    createStatusMessage(`Waiting up to ${remainingTimeoutSeconds} seconds for the cluster to restart...`);
    if (remainingTimeoutSeconds <= 0) {
      clearInterval(proxyPollingStatusTextInterval);
    }
  }, 1000);
}

// remove timeout
function proxyTimeout() {
  clearInterval(proxyPollingInterval); // stop polling the new domain
  pollStatusText.innerHTML = `Timed out waiting for the cluster to restart.<br>Please refresh the page manually.`;
}

// Enable-disable user/pass fields
useAuthCheck.onchange = function() {
  enableDisableProxyAuthentication(this.checked);
}

// Form upload + error processing
changeProxyForm.addEventListener('submit', async (event) => {
  changeProxyBtn.disabled = true;
  changeProxyBtn.innerText = changeProxyBtnInProgressStr;
  event.preventDefault();
  const formData = new FormData(changeProxyForm);
  formData.set('UseAuth', formData.get('UseAuth') == 'on'); // set UseAuth to true or false instead of 'on' or undefined
  try {
    const response = await fetch('/changeProxy', {
      method: 'POST',
      body: formData
    });
    const data = await response.text();
    if (!response.ok) {
      throw new Error(data);
    }
    createFeedbackMessage(data, false, true);
    
    proxyPollingInterval = setInterval(pingBackendDueToRestart, 5000);
    
    displayProxyWaitingProgress();

    proxyPollingTimeout = setTimeout(proxyTimeout, proxyPollingTimeoutSeconds * 1000);
  } catch (error) {
    createFeedbackMessage(error, true, false);
  } finally {
    changeProxyBtn.disabled = false;
    changeProxyBtn.innerText = changeProxyBtnApplyProxyStr;
  }
});

function populateInitialProxyConfigs() {
  proxyAddrField.value = proxyAddr ?? null;
  proxyPortField.value = proxyPort ?? null;
  enableDisableProxyAuthentication(proxyUseAuth);
  proxyUserField.value = proxyUser ? proxyUser : null;
  proxyPassField.value = proxyPass ? proxyPass : null;
}

const portalAddrFetch = fetch('/proxyConfig')
    .then(response => response.json())
    .then(proxyConfigs => {
      proxyAddr = proxyConfigs.proxyAddr;
      proxyPort = proxyConfigs.proxyPort;
      proxyUseAuth = proxyConfigs.proxyUseAuth;
      proxyUser = proxyConfigs.proxyUser;
      proxyPass = proxyConfigs.proxyPass;
      populateInitialProxyConfigs();
      changeProxyBtn.disabled = false;
      changeProxyBtn.innerText = changeProxyBtnApplyProxyStr;
      return proxyConfigs;
    })
    .catch(error => {
      console.error('Error fetching portal address from API: ', error);
      createFeedbackMessage(error, true, false);
    });