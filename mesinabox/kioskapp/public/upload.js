const fileInput = document.querySelector("#sslCertPicker");
const filePreview = document.querySelector(".preview");
const uploadBtn = document.getElementById('UploadCertBtn');

const uploadBtnBaseStr =      'Upload Certificate';
const uploadBtnUploadingStr = 'Uploading...';
const uploadBtnPollingStr =   'Waiting for Domain';
uploadBtn.innerText = uploadBtnBaseStr;

let pollingInterval;
let pollingTimeout;
let pollingStatusTextInterval;

let pollStatusText = null;

const pollingTimeoutSeconds = 90;

fileInput.addEventListener("change", updateFileDisplay);

function createErrorMessage(errorMessage) {
  const errorDiv = document.getElementById('uploadErrorMessage');
  // Display error message
  const text = document.createElement('p');
  text.textContent = errorMessage;
  errorDiv.appendChild(text);
}

function clearErrorMessages() {
  const errorDiv = document.getElementById('uploadErrorMessage');
  errorDiv.replaceChildren(); // removes all child nodes
}

function updateFileDisplay() {
  while (filePreview.firstChild) {
    filePreview.removeChild(filePreview.firstChild);
  }

  const curFiles = fileInput.files;
  if (curFiles.length === 0) {
    const para = document.createElement("p");
    para.textContent = "No files selected for upload";
    filePreview.appendChild(para);
    uploadBtn.disabled = true;
  } else {
    const div = document.createElement("div");
    filePreview.appendChild(div);
    for (const file of curFiles) {
      const para = document.createElement("p");
      para.textContent = `${file.name}`;
      div.appendChild(para);
    }
    uploadBtn.disabled = false;
  }

  // Clear error message as well
  clearErrorMessages();
}

async function pingNewDomain(newDomain) {
  const fullDomain = `https://${newDomain}`
  fetch(fullDomain)
  .then(response => {
    if (!response.ok) {
      throw new Error("Response not ok", {cause: response});
    }
    clearTimeout(pollingTimeout);
    clearInterval(pollingInterval);
    window.location.href = fullDomain;
  })
  .catch(error => {
    // Handle errors (e.g., network issues, server errors)
    console.error('Error checking domain availability:', error);
  });
}

// Display the seconds remaining until timeout, decreasing every second
function displayCertWaitingProgress() {
  const statusDiv = document.getElementById('uploadStatusMessage');
  pollStatusText = document.createElement('p');
  pollStatusText.textContent = `Waiting up to ${pollingTimeoutSeconds} seconds for new domain to be up...`
  statusDiv.appendChild(pollStatusText);
  
  let remainingTimeoutSeconds = pollingTimeoutSeconds;
  pollingStatusTextInterval = setInterval(() => {
    remainingTimeoutSeconds--;
    pollStatusText.textContent = `Waiting up to ${remainingTimeoutSeconds} seconds for new domain to be up...`;
    if (remainingTimeoutSeconds <= 0) {
      clearInterval(pollingStatusTextInterval);
    }
  }, 1000);
}

// Wait 5 seconds until forced redirect
function certTimeoutWaitingProgress(pollingInterval) {
  clearInterval(pollingInterval); // stop polling the new domain
  let redirectTimeoutSecs = 5;
  pollStatusText.textContent = `Timed out waiting for new deployment to be up. Redirecting in ${redirectTimeoutSecs} seconds...`

  const redirectInterval = setInterval(() => {
    redirectTimeoutSecs--;
    pollStatusText.textContent = `Timed out waiting for new deployment to be up. Redirecting in ${redirectTimeoutSecs} seconds...`
    if (redirectTimeoutSecs <= 0) {
      pollStatusText.textContent = `Redirecting...`
      clearInterval(redirectInterval); // stops the timeout messages from going negative trying to override this
      window.location.href = `https://${data.newDomain}`;
    }
  }, 1000);
}

// Form upload + error processing
document.getElementById('UploadCertificateForm').addEventListener('submit', async (event) => {
  uploadBtn.disabled = true;
  uploadBtn.innerText = uploadBtnUploadingStr;
  event.preventDefault();
  const formData = new FormData(event.target);
  try {
    const response = await fetch('/upload', {
      method: 'POST',
      body: formData
    });
    const data = await response.json();
    if (!response.ok) {
      if (response.status == 504) {
        throw new Error('504 Gateway Timeout');
      }
      throw new Error(data.message);
    }
    
    uploadBtn.innerText = uploadBtnPollingStr;

    pollingInterval = setInterval(pingNewDomain, 2000, data.newDomain);
    displayCertWaitingProgress();

    pollingTimeout = setTimeout(certTimeoutWaitingProgress, pollingTimeoutSeconds * 1000, pollingInterval);

  } catch (error) {
    clearErrorMessages();
    createErrorMessage(error.message)
    uploadBtn.disabled = false;
    uploadBtn.innerText = uploadBtnBaseStr;
  }
});