# How to generate Microshift ISO

To follow this guide, a Red Hat subscription is required. 
1. Get [RHEL 9 Binary DVD .iso](https://access.redhat.com/downloads/content/rhel). 
2. Create the VM.
    
    - This VM needs to be created with the following requirements:
        - Generation 2 to support newer virtualization features.
        - Network is connected to the default virtual switch or another virtual switch that has external connectivity.
        - A 100 GB or larger virtual disk.
        - 2 or more vCPUs are recommended.
    - After the VM is created the secure boot settings needs to be change to **Microsoft UEFI Certificate Authority**. 
    - Now that the VM is created, start it and follow the setup instructions that are presented when it is launched.
3. After the VM is up and running

    - As root, run `subscription-manager register` and insert RedHat valid credentials.
    - As root, install ansible.
        - `dnf install -y ansible-core`
    -  Download the infra.osbuild Ansible collection.
        - `ansible-galaxy collection install -f git+https://github.com/redhat-cop/infra.osbuild --upgrade ` 
    - Clone install-scripts repository into Rhel VM and navigate into edge-demos/demos/microshift-disconnected. 
        - `git clone https://github.com/criticalmanufacturing/install-scripts.git`
    - Modify the Ansible inventory file.
        - Change ansible_host to the VM IP. It is possible to find it through `hostname -I`
        - Change ansible_user and ansible_become_password to the current VM user data.
    - Create an SSH key with `ssh-keygen` and copy it into the Image Builder system.
        - `ssh-copy-id <user>@<image builder IP> `
    - Inject the pull secret as an Ansible variable so [get the pull secret from the Red Hat Console](https://console.redhat.com/openshift/install/pull-secret).
        - `ansible-vault create vars/secrets.yml`
        - Then add the variable microshift_pull_secret in that file with the right value and then save it.
            - `microshift_pull_secret: '<YOUR PULL SECRET>'`
    - Create CMOS App.
        - Create cmos folder in edge-demos/demos/microshift-disconnected/files/manifests and copy yaml files from mesinabox/stack into it. 
        - Run the splitTraefikCustomResourcesFile script, that is in mesinabox/microshiftIsoGeneration folder, to create individual files for each Traefik CRD resources.
        - Copy cmos_config.j2 file from microshiftIsoGeneration folder to the following directory edge-demos/demos/microshift-disconnected/templates.
        - Delete the install-scripts folder.
    - Move again to the `edge-demos/demos/microshift-disconnected`.
        - Add the following line to the microshift-disconnected/vars/main.yml in the additional_kickstart_post section.
            - `- "{{ lookup('ansible.builtin.template', '../templates/cmos_config.j2') }}"`.

    - Create the image and the ISO. This command needs to be run inside the edge-demos/demos/microshift-disconnected folder. 
        - `ansible-playbook -vvi inventory --ask-vault-pass playbooks/main.yml` 
    - Access the address that is presented at the end of the command execution and download the ISO.

4. After the Microshift ISO is ready to download, download it and mount a VM with it.

## Known Issues

- It is not possible to create files in any location other than /etc.
- Pipe files must be located in a subfolder within /etc, but they cannot be placed in /etc/microshift. The designated subfolder has specific constraints that prevent the execution of the FIFO script.




