# Deployment Script (deploy.sh)

This is a robust, production-grade Bash script designed to automate the entire setup, deployment, and configuration of a Dockerized application on a remote Linux server.

It is idempotent, meaning it can be safely re-run without breaking existing configurations.

## Prerequisites

Local Machine:

Bash environment (Linux/macOS/WSL).

git and rsync installed.

The SSH private key (SSH_KEY_PATH) must have read permissions and be the correct key for the remote user.

Remote Server (Linux):

Accessible via SSH using the provided username and IP.

sudo access without a password prompt is required for the initial installation of Docker, Docker Compose, and Nginx.

Application Repository:

Must contain either a Dockerfile or, preferably, a docker-compose.yml file in the root directory.

A Personal Access Token (PAT) with read access to the repository is required.

## Usage

Standard Deployment

Make the script executable and run it:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will interactively prompt you for the following parameters:

 - Parameter
- Description
- Git Repository URL
- HTTPS URL of your application repository.
- Personal Access Token (PAT)
- Your Git PAT for authentication during cloning/pulling.
- Branch name
- The Git branch to deploy. Defaults to main.
- Remote SSH Username
- The user account on the remote server.
- Remote Server IP
- The public IP address of the target server.
- Path to SSH Private Key
- Local path to the id_rsa or similar file (e.g., ~/.ssh/id_rsa).
- Internal Container Port
- The port your application container exposes (e.g., 8080).

### Cleanup Mode

To gracefully stop and remove the deployed application (containers, Nginx config, and project files) from the remote server, run the script with the --cleanup flag:

```bash
./deploy.sh --cleanup
```

Cleanup mode will only ask for the necessary SSH details and the original project name to perform the remote removal.

## Deployment Process Overview

The script performs the following steps in sequence:

Parameter Collection & Validation: Gathers all inputs and ensures the required Git URL, PAT, and SSH details are provided.

Local Git Operation: Clones the specified branch of the repository. If the local directory already exists, it performs an authenticated git pull for idempotency.

File Verification: Checks locally that either a Dockerfile or docker-compose.yml exists.

SSH Connectivity Check: Performs a dry-run check to ensure the server is reachable with the given credentials.

File Transfer: Uses rsync to efficiently transfer the local project files (excluding .git) to the remote directory (/opt/app/<PROJECT_NAME>).

Remote Execution: Executes a single, large SSH command block to handle the core deployment:

Environment Setup: Updates packages, installs Docker, Docker Compose (Plugin), and Nginx.

Idempotency: Stops and removes any existing containers for the project.

Deployment: Runs docker compose up -d --build --wait.

Nginx Proxy: Dynamically generates and writes an Nginx configuration file to proxy traffic from Port 80 to the application's internal container port.

Service Reload: Tests the Nginx configuration and reloads the service.

Remote Validation: Confirms container(s) are running.

External Validation: Performs a final check using curl from the local machine to the remote server's Port 80 to confirm the Nginx proxy is working correctly.

## Logging and Error Handling

Logging: All actions (success and failure) are logged to both the console and a timestamped log file (deploy_YYYYMMDD_HHMMSS.log).

Strict Mode: The script uses set -euo pipefail for immediate failure on errors.

Traps: trap commands are set for ERR and INT to ensure proper exit codes and informative error messages upon unexpected termination.

Exit Codes: Meaningful exit codes are used to identify the stage where failure occurred (e.g., 21 for Git pull failure, 31 for Nginx configuration failure).
