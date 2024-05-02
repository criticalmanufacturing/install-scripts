const fileInput = document.querySelector("#sslCertPicker");
const filePreview = document.querySelector(".preview");
const uploadBtn = document.getElementById('UploadCertBtn');

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

// Form upload + error processing
document.getElementById('UploadCertificateForm').addEventListener('submit', async (event) => {
  uploadBtn.disabled = true;
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
    alert(data.message); // Display success message

    // const success = await waitForEndpointUp(data.newEndpoint, 120000)
    // if (!success) {
    //   throw new Error('Timeout: Failed to ping the endpoint within 2 minutes');
    // }

    // Redirect to the new endpoint
    // window.location.href = data.newEndpoint; // Commented for now since we need a way of only redirecting when route(r)+ingress is up.
  } catch (error) {
    clearErrorMessages();
    const errorDiv = document.getElementById('uploadErrorMessage');
    // Display error message
    const text = document.createElement('p');
    text.textContent = error.message;
    errorDiv.appendChild(text);
  } finally {
    uploadBtn.disabled = false;
  }
});