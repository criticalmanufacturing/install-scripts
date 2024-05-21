# How to generate Microshift ISO

To follow this guide, a Red Hat subscription is required. 
1. Get [RHEL 9 Binary DVD .iso](https://access.redhat.com/downloads/content/rhel). 
2. Create the VM.
    
    - This VM needs to be created with the following requirements:

        - Generation 2 to support newer virtualization features.
        - 2GB of RAM at a minimum. 4GB or larger is  recommended.
        - Network is connected to the default virtual switch or another virtual switch that has external connectivity.
        - A 20 GB or larger virtual disk.
        - 2 or more vCPUs are recommended.
    - After the VM is created the secure boot settings needs to be change to **Microsoft UEFI Certificate Authority**. 
    - Now that the VM is created, start it and follow the setup instructions that are presented when it is launched.
3. After the VM is up and running

    - Run `subscription-manager register` and insert RedHat valid credentials.
    - Install ansible dnf install -y ansible-core
    - run dnf update as root
        - `yum install python3-pip`
        - `pip3 install ansible`
    -  Download the infra.osbuild Ansible collection.
        - `ansible-galaxy collection install -f git+https://github.com/redhat-cop/infra.osbuild --upgrade ` 
    - Clone the repo
        - `git clone https://github.com/luisarizmendi/edge-demos`
    - Move to the `edge-demos/demos/microshift-disconnected` directory
    - Remove all the directories located in edge-demos/demos/microshift-disconnected/files/manifests. Currently, this folder contains only example projects. 
    - Modify the Ansible inventory file.
        - Change ansible_host to the VM IP. It is possible to find it through `hostname -I`
        - Change ansible_user and ansible_password to the current VM user data.
    - Create an SSH key with `ssh-keygen` and copy it into the Image Builder system.
        - `ssh-copy-id <user>@<image builder IP> `
    - Inject the pull secret as an Ansible variable so [get the pull secret from the Red Hat Console](https://console.redhat.com/openshift/install/pull-secret).
        - `ansible-vault create vars/secrets.yml`
        - Then add the variable microshift_pull_secret in that file with the right value and then save it.
            - `microshift_pull_secret: '<YOUR PULL SECRET>'`
    - Create CMOS App.
        - Clone install-scripts repository into Rhel VM
            - `git clone https://github.com/criticalmanufacturing/install-scripts.git`
        - Copy files from mesinabox/stack in this repo to the following directory edge-demos/demos/microshift-disconnected/files/manifests/cmos
        - Run the splitTraefikCustomResourcesFile script to create individual files for each Traefik CRD resources.
        - Copy cmos_config.j2 file from microshiftIsoGeneration folder to the following directory edge-demos/demos/microshift-disconnected/templates.
        - Delete the install-scripts folder.
    - Move again to the `edge-demos/demos/microshift-disconnected`.
        - Add the following line to the microshift-disconnected/vars/main.yml in the additional_kickstart_post section.
            - `- "{{ lookup('ansible.builtin.template', '../templates/cmos_config.j2') }}"`.

    - Create the image and the ISO
        - `ansible-playbook -vvi inventory --ask-vault-pass playbooks/main.yml` 
    - Access the address that is presented at the end of the command execution and download the ISO.

4. After the Microshift ISO is ready to download, download it and mount a VM with it.


## Known Issues

- It is not possible to create files in any location other than /etc.
- Pipe files must be located in a subfolder within /etc, but they cannot be placed in /etc/microshift. The designated subfolder has specific constraints that prevent the execution of the FIFO script.




