const fileInput = document.querySelector("#sslCertPicker");
const filePreview = document.querySelector(".preview");
const uploadBtn = document.getElementById('UploadCertBtn');

const uploadBtnBaseStr =      'Upload Certificate';
const uploadBtnUploadingStr = 'Uploading...';
const uploadBtnPollingStr =   'Waiting for Domain';
uploadBtn.innerText = uploadBtnBaseStr;

let pollingInterval;
let pollingTimeout;

fileInput.addEventListener("change", updateFileDisplay);

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
      switch (response.status) {
        case 504:
          throw new Error('504 Gateway Timeout');
        default:
          break;
      }
      throw new Error(data.message);
    }
    
    uploadBtn.innerText = uploadBtnPollingStr;

    pollingInterval = setInterval(pingNewDomain, 2000, data.newDomain);
    pollingTimeout = setTimeout(() => {
      clearInterval(pollingInterval);
      alert('Timeout while waiting for new domain to be up.\nForcing a redirect to the new domain');
      window.location.href = `https://${data.newDomain}`;
    }, 90000); // 90s timeout

  } catch (error) {
    clearErrorMessages();
    const errorDiv = document.getElementById('uploadErrorMessage');
    // Display error message
    const text = document.createElement('p');
    text.textContent = error.message;
    errorDiv.appendChild(text);
    uploadBtn.disabled = false;
    uploadBtn.innerText = uploadBtnBaseStr;
  }
});