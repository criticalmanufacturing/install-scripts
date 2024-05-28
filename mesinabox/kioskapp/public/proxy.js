// Constants
const proxyAddrField = document.getElementById('proxyAddrField');
const proxyPortField = document.getElementById('proxyPortField');
const proxyUserField = document.getElementById('proxyUserField');
const proxyPassField = document.getElementById('proxyPassField');
const useAuthCheck = document.getElementById('proxyUseAuthCheckbox');

const changeProxyForm = document.getElementById('ProxyForm');
const changeProxyBtn = document.getElementById('ChangeProxyBtn');

const changeProxyBtnLoadingInitStr = 'Loading Config...';
const changeProxyBtnApplyProxyStr = 'Update Proxy';
const changeProxyBtnInProgressStr = 'In Progress...';

// Hidden Vars
let useAuthentication = null;

// Proxy original configs
let proxyAddr = null;
let proxyPort = null;
let proxyUseAuth = null;
let proxyUser = null;
let proxyPass = null;

function createFeedbackMessage(message, isError, isSuccess) {
  const feedbackDiv = document.getElementById('proxyFeedbackMessage');
  feedbackDiv.replaceChildren(); // removes all child nodes
  const text = document.createElement('p');
  text.textContent = message;
  text.style.color = isError ? "red" : (isSuccess ? "green" : null);
  feedbackDiv.appendChild(text);
}

function enableDisableProxyAuthentication(useAuthBool) {
  useAuthentication = useAuthBool;
  useAuthCheck.checked = useAuthentication;
  document.querySelector("#proxyUserField").disabled = !useAuthBool;
  document.querySelector("#proxyPassField").disabled = !useAuthBool;
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
      if (response.status == 504) {
        throw new Error('504 Gateway Timeout');
      }
      throw new Error(data);
    }
    createFeedbackMessage(data, false, true);
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