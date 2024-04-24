const fileInput = document.querySelector("#sslCertPicker");
const filePreview = document.querySelector(".preview");

fileInput.addEventListener("change", updateFileDisplay);

function updateFileDisplay() {
    while (filePreview.firstChild) {
        filePreview.removeChild(filePreview.firstChild);
    }
  
    const curFiles = fileInput.files;
    if (curFiles.length === 0) {
      const para = document.createElement("p");
      para.textContent = "No files selected for upload";
      filePreview.appendChild(para);
    } else {
      const div = document.createElement("div");
      filePreview.appendChild(div);
      for (const file of curFiles) {
        const para = document.createElement("p");
        para.textContent = `${file.name}`;
        div.appendChild(para);
      }
    }
  }