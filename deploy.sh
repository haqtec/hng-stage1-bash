#!/bin/bash
# deploy.sh
# A robust, production-grade Bash script for Dockerized application deployment.
# It handles local Git operations, remote environment setup (Docker, Nginx),
# file transfer, and deployment via SSH.

# --- Global Configuration and Setup ---

# Enable strict mode: exit immediately if a command exits with a non-zero status,
# treat unset variables as errors, and pipefail prevents errors in a pipeline from being masked.
set -euo pipefail

# Log file name (timestamped)
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
PROJECT_DIR="" # Will hold the local project directory name after cloning

# --- Helper Functions ---

# Function for logging messages to stdout and the log file
log_action() {
    local message="$1"
    local status_code="${2:-0}"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    if [[ "$status_code" -eq 0 ]]; then
        echo -e "[\033[32mINFO\033[0m] $timestamp | $message" | tee -a "$LOG_FILE"
    else
        echo -e "[\033[31mERROR\033[0m] $timestamp | $message" | tee -a "$LOG_FILE" >&2
        return 1
    fi
    return 0
}

# Cleanup function to be called on EXIT, ERR, or INT
cleanup() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        log_action "Deployment failed at stage $exit_code. Check $LOG_FILE for details." 1
    fi

    # Clean up local repository directory if it was created
    if [[ -n "$PROJECT_DIR" ]] && [[ -d "$PROJECT_DIR" ]]; then
        log_action "Attempting to clean up local project directory: $PROJECT_DIR"
        # Be cautious: Only remove if it was freshly cloned
        # For simplicity, we assume we clone into a temp workspace.
        # If running in project root, this step needs more complex logic (e.g., git status check)
        # For this script, we'll just log a warning/info.
    fi
    log_action "Script execution finished with exit code $exit_code."
}

# Set traps for signals and errors
trap 'cleanup' EXIT
trap 'log_action "FATAL: An unexpected error occurred on line $LINENO." 1; exit 10' ERR
trap 'log_action "FATAL: Script interrupted by user (Ctrl+C)." 1; exit 11' INT

# --- Cleanup Mode (Optional) ---

if [[ "$#" -gt 0 ]] && [[ "$1" == "--cleanup" ]]; then
    log_action "Cleanup mode activated."
    # We still need SSH details for remote cleanup
    read -rp "Enter Remote SSH Username: " SSH_USER
    read -rp "Enter Remote Server IP: " SERVER_IP
    read -rp "Enter Path to SSH Private Key: " SSH_KEY_PATH
    read -rp "Enter Project Name (must match deployment name): " PROJECT_NAME

    REMOTE_PROJECT_DIR="/opt/app/${PROJECT_NAME}"

    log_action "Attempting remote cleanup on ${SERVER_IP}..."

    # Execute cleanup commands remotely
    if ! ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SERVER_IP}" "
        set +e
        echo \"Stopping and removing containers for ${PROJECT_NAME}...\"
        docker-compose -f ${REMOTE_PROJECT_DIR}/docker-compose.yml down --remove-orphans
        echo \"Removing Nginx config...\"
        sudo rm -f /etc/nginx/conf.d/${PROJECT_NAME}.conf
        echo \"Reloading Nginx...\"
        sudo nginx -t && sudo systemctl reload nginx
        echo \"Removing project directory ${REMOTE_PROJECT_DIR}...\"
        sudo rm -rf ${REMOTE_PROJECT_DIR}
        exit 0
    "; then
        log_action "Remote cleanup failed. Check permissions/connectivity." 1
        exit 12
    fi

    log_action "Cleanup successful. Exiting."
    exit 0
fi

# --- 1. Collect and Validate Parameters ---

log_action "Starting deployment script. Log file: $LOG_FILE"

# Prompts
read -rp "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " GIT_URL
read -rp "Enter Git Personal Access Token (PAT): " PAT
read -rp "Enter Branch name (default: main): " BRANCH_NAME
BRANCH_NAME=${BRANCH_NAME:-main}

read -rp "Enter Remote SSH Username: " SSH_USER
read -rp "Enter Remote Server IP: " SERVER_IP
read -rp "Enter Path to SSH Private Key: " SSH_KEY_PATH

# Input validation loop for port
while true; do
    read -rp "Enter Internal Container Port (e.g., 8080): " APP_PORT
    if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )); then
        break
    else
        echo "Invalid port number. Please enter a number between 1 and 65535."
    fi
done

# Basic validation
if [[ -z "$GIT_URL" || -z "$PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY_PATH" ]]; then
    log_action "Missing required parameter. Cannot proceed." 1
    exit 20
fi

# Extract project name from Git URL (used for remote directory and Nginx config)
PROJECT_NAME=$(basename "$GIT_URL" .git)
REMOTE_PROJECT_DIR="/opt/app/${PROJECT_NAME}"

# --- 2. Clone the Repository (Local) ---

log_action "Cloning or pulling repository: ${PROJECT_NAME} (Branch: ${BRANCH_NAME})"

if [[ -d "$PROJECT_NAME" ]]; then
    cd "$PROJECT_NAME"
    PROJECT_DIR="$PWD"
    log_action "Repository already exists. Pulling latest changes..."
    # Authentication for pull
    if ! git -c http.extraheader="Authorization: Basic $(echo -n ":$PAT" | base64)" pull origin "$BRANCH_NAME"; then
        log_action "Failed to pull latest changes from branch $BRANCH_NAME. Check PAT or branch name." 1
        exit 21
    fi
else
    # Use PAT for HTTPS authentication
    AUTH_GIT_URL=$(echo "$GIT_URL" | sed "s/https:\/\//https:\/\/:${PAT}@/")
    if ! git clone --single-branch --branch "$BRANCH_NAME" "$AUTH_GIT_URL" "$PROJECT_NAME"; then
        log_action "Failed to clone repository. Check URL, PAT, or branch name." 1
        exit 22
    fi
    cd "$PROJECT_NAME"
    PROJECT_DIR="$PWD"
fi

# --- 3. Navigate and Verify Files (Local) ---

log_action "Navigated into local project directory: $PROJECT_NAME"

# Check for required deployment files
if [[ ! -f "Dockerfile" ]] && [[ ! -f "docker-compose.yml" ]]; then
    log_action "Neither Dockerfile nor docker-compose.yml found in $PROJECT_NAME. Cannot deploy." 1
    exit 23
fi

# --- 4. SSH Connectivity Check ---

log_action "Checking SSH connectivity to ${SSH_USER}@${SERVER_IP}..."
if ! ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${SERVER_IP}" "exit 0"; then
    log_action "SSH dry-run failed. Check IP, user, or key path." 1
    exit 24
fi
log_action "SSH connectivity confirmed."

# --- 5. & 6. Prepare, Transfer, and Deploy (Remote) ---

log_action "Starting file transfer and remote deployment process."

# 5.1 Transfer Project Files using rsync (better for idempotency/incremental updates)
log_action "Transferring project files to remote host..."

if ! rsync -avz -e "ssh -i ${SSH_KEY_PATH}" --exclude='.git' "./" "${SSH_USER}@${SERVER_IP}:${REMOTE_PROJECT_DIR}"; then
    log_action "File transfer failed via rsync." 1
    exit 25
fi
log_action "File transfer successful to ${REMOTE_PROJECT_DIR}"

# 5.2 Execute the main deployment block remotely via SSH
log_action "Executing remote deployment commands..."

# The core remote logic is contained within this SSH command block
# Note: \$VAR prevents local shell expansion, allowing remote shell expansion
# Note: ${VAR} allows local shell expansion before SSH executes.
REMOTE_DEPLOY_COMMAND=$(cat <<EOF_REMOTE
    set -euo pipefail

    # Variables
    REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR}"
    PROJECT_NAME="${PROJECT_NAME}"
    APP_PORT="${APP_PORT}"

    log_remote() {
        echo "[REMOTE \$(date +'%Y-%m-%d %H:%M:%S')] \$1" | sudo tee -a "/tmp/deploy_${PROJECT_NAME}.log" > /dev/null
        echo "   [REMOTE] \$1"
    }

    log_remote "Starting remote environment setup and deployment..."

    # Check for root/sudo access
    if ! sudo -n true 2>/dev/null; then
        log_remote "ERROR: Cannot gain root privileges for installation. Aborting."
        exit 30
    fi

    # 1. Prepare Remote Environment (Installation)
    log_remote "Updating system packages and installing dependencies..."
    
    # Generic Linux installation steps (adjust for specific distributions if needed)
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release nginx
    
    # Install Docker
    if ! command -v docker > /dev/null; then
        log_remote "Installing Docker..."
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "\$ID")/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "\$ID") $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        log_remote "Docker installed."
    fi

    # Install Docker Compose (using the plugin method)
    if ! docker compose version > /dev/null 2>&1; then
        log_remote "Installing Docker Compose plugin..."
        sudo apt-get install -y docker-compose-plugin
        log_remote "Docker Compose installed."
    fi

    # Add user to docker group (required for running docker without sudo)
    if ! id -nG "\$USER" | grep -qw docker; then
        log_remote "Adding user \$USER to the docker group..."
        sudo usermod -aG docker \$USER
        log_remote "User added to docker group. NOTE: You may need to log out and back in for this to take effect on future manual sessions."
    fi

    # Enable and start services
    log_remote "Ensuring Docker and Nginx services are running..."
    sudo systemctl enable docker nginx
    sudo systemctl start docker nginx

    # 2. Deploy the Application
    log_remote "Navigating to project directory: \${REMOTE_PROJECT_DIR}"
    cd "\${REMOTE_PROJECT_DIR}"

    log_remote "Stopping and removing existing containers for idempotency..."
    # The -f flag handles non-existent docker-compose.yml gracefully
    docker compose -f docker-compose.yml down --remove-orphans > /dev/null 2>&1 || true
    
    log_remote "Building and starting new containers in detached mode..."
    # Using 'docker compose' which is the recommended modern command
    docker compose up -d --build --wait

    # 3. Configure Nginx as a Reverse Proxy
    log_remote "Configuring Nginx reverse proxy..."

    NGINX_CONF_PATH="/etc/nginx/conf.d/${PROJECT_NAME}.conf"
    
    # Generate Nginx configuration
    NGINX_CONFIG="
# Managed by deploy.sh script for project ${PROJECT_NAME}
server {
    listen 80;
    listen [::]:80;
    server_name _; # Listen on all hostnames

    # Placeholder for HTTPS redirection (uncomment for Certbot)
    # listen 443 ssl http2;
    # listen [::]:443 ssl http2;
    # ssl_certificate /etc/letsencrypt/live/\$server_name/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/\$server_name/privkey.pem;

    location / {
        # Proxy traffic to the container's internal port
        proxy_pass http://localhost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"
    echo "\$NGINX_CONFIG" | sudo tee "\${NGINX_CONF_PATH}" > /dev/null
    log_remote "Nginx configuration written to \${NGINX_CONF_PATH}"

    log_remote "Testing Nginx configuration and reloading service..."
    if sudo nginx -t; then
        sudo systemctl reload nginx
        log_remote "Nginx configuration test successful and service reloaded."
    else
        log_remote "ERROR: Nginx configuration test failed. Check the generated config file: \${NGINX_CONF_PATH}"
        exit 31
    fi

    # 4. Final Validation (Remote)
    log_remote "Validation: Checking container health..."
    CONTAINER_HEALTH=\$(docker compose ps | grep "Up" | wc -l)

    if [[ "\$CONTAINER_HEALTH" -ge 1 ]]; then
        log_remote "Validation SUCCESS: At least \${CONTAINER_HEALTH} container(s) are running."
    else
        log_remote "Validation FAILED: No containers are running. Check 'docker compose logs'."
        exit 32
    fi

    log_remote "Deployment on remote host completed successfully."
EOF_REMOTE
)

# Execute the remote block
if ! ssh -i "${SSH_KEY_PATH}" "${SSH_USER}@${SERVER_IP}" "${REMOTE_DEPLOY_COMMAND}"; then
    log_action "Remote deployment failed. Check remote log /tmp/deploy_${PROJECT_NAME}.log on the server." 1
    exit 33
fi

# --- 7. Validate Deployment (Local External Check) ---

log_action "External validation: Testing application access via Nginx (Port 80) on ${SERVER_IP}..."

if curl --fail --silent --show-error "http://${SERVER_IP}" > /dev/null; then
    log_action "Deployment fully validated. Application is accessible via Nginx at http://${SERVER_IP}." 0
else
    log_action "External validation FAILED. Nginx is not proxying correctly or the app is not responding." 1
    exit 40
fi

