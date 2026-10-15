# Cattle Not Laptops

A project to automate system provisioning and configuration using Ansible and Chezmoi.

This project automates the setup of your development environment by installing common tools, configuring your shell, and managing dotfiles. It's designed to ensure a consistent and reproducible setup across different machines, saving you time and effort in configuring new systems or re-establishing your environment.

## Tech Stack

* Ansible
* Chezmoi
* Fish Shell
* Git
* Make
* Vim
* VS Code
* Google Cloud CLI
* Kubectl
* K9s

## Quick Start

1. **Clone the repository:**
 ```bash
 git clone https://github.com/uduwat/cattle-not-laptops.git
 cd cattle-not-laptops
 ```

2. **Run the bootstrap script:**
 ```bash
 ./bootstrap.sh
 ```
 The script will guide you through checking your OS, installing necessary tools like Ansible and Git, and prompting for user-specific configurations such as your principal user and dotfiles repository.

 If you encounter issues or need to re-run the provisioning, you can use `ansible-pull` directly:
 ```bash
 ansible-pull -U https://github.com/uduwat/cattle-not-laptops.git -e "principaluser=<your_username>" -e "dotfiles_repo=<your_dotfiles_repo_url>" -e "ansible_shell_executable='/bin/bash -l'" --accept-host-key -v local.yml
 ```
 Replace `<your_username>` with your actual username and `<your_dotfiles_repo_url>` with the URL of your dotfiles repository if you are using one.

## Project Structure

```
.
├── bootstrap.sh
├── local.yml
├── requirements.yaml
└── roles/
 ├── cloudutils/
 ├── commons/
 ├── dotfiles/
 ├── editors/
 ├── filemanagers/
 ├── gitcli/
 ├── linters/
 ├── networkutils/
 ├── secrets/
 ├── shell/
 └── systemwide/
```

## Key Concepts

* **`local.yml`**: This is the main Ansible playbook that orchestrates the entire provisioning process. It defines the order in which roles are applied to the system.
* **`bootstrap.sh`**: A shell script that automates the initial setup, including checking system compatibility, installing Ansible and Git, and prompting for user-specific variables before running `ansible-pull`.
* **Roles (`roles/`)**: Ansible roles are used to group related tasks. Each directory within `roles/` represents a distinct set of configurations or installations (e.g., `shell/` for shell configurations, `editors/` for text editors).
* **`requirements.yaml`**: Specifies Ansible collections that need to be installed for the playbooks to function correctly.
* **Chezmoi (`roles/dotfiles/`)**: This role manages your dotfiles. It uses Chezmoi to pull configurations from a specified Git repository, ensuring your personal settings are applied consistently. The `dotfiles_repo` variable, passed during `ansible-pull`, is crucial for this.