#!/bin/bash

# ==============================================================================
# DevOps Intern Stage 1 Task: Automated Deployment Bash Script
#
# Objective: Develop a robust, production-grade Bash script to automate the
# setup, deployment, and configuration of a Dockerized application on a
# remote Linux server using SSH.
# ==============================================================================

# --- Configuration and Environment Setup ---

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and prohibit errors in a pipeline
# from being masked. This ensures robustness.
set -euo pipefail

LOG_FILE="deploy_$(date +%Y%m%d).log"
REPO_DIR="" # Will be set after cloning
DEFAULT_BRANCH="main"
APP_NAME="" # Derived from repo name
CONTAINER_NAME="app-container"
NETWORK_NAME="app-network"

# --- Logging and Error Handling ---

# Function to log messages to both console and file
log_message() {
    local type="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    echo "[$timestamp] [$type] $message" | tee -a "$LOG_FILE"
}

# Function to handle errors and ensure proper exit status
error_exit() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        log_message "ERROR" "Script failed at stage: $1 (Exit Code: $status)"
    fi
    # Only exit if the status is a failure (or if explicitly called from trap)
    if [[ $status -ne 0 ]] || [[ "$1" == "TRAP" ]]; then
        echo ""
        log_message "FATAL" "Deployment failed. Check '$LOG_FILE' for details."
        exit $status
    fi
}

# Trap unexpected errors and call error_exit with context
trap 'error_exit "TRAP"' ERR

# --- Parameter Collection and Validation (Stage 1) ---

collect_parameters() {
    log_message "INFO" "--- Starting Deployment Script ---"

    if [[ "$#" -gt 0 && "$1" == "--cleanup" ]]; then
        CLEANUP_MODE=true
        log_message "INFO" "Cleanup mode enabled."
    else
        CLEANUP_MODE=false
    fi

    # 1. Git Repository URL
    read -r -p "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " GIT_REPO
    if [[ -z "$GIT_REPO" ]]; then error_exit "Repository URL cannot be empty."; fi
    # Extract app name from repo URL (e.g., user/repo.git -> repo)
    APP_NAME=$(basename "$GIT_REPO" .git)
    REPO_DIR="./$APP_NAME"

    # 2. Personal Access Token (PAT)
    read -r -s -p "Enter Personal Access Token (PAT) for Git authentication: " PAT
    echo # Newline after silent input
    if [[ -z "$PAT" ]]; then error_exit "PAT cannot be empty."; fi

    # 3. Branch name
    read -r -p "Enter branch name (Default: $DEFAULT_BRANCH): " BRANCH
    BRANCH=${BRANCH:-$DEFAULT_BRANCH}

    # 4. Remote Server SSH details
    read -r -p "Enter Remote Server Username: " REMOTE_USER
    read -r -p "Enter Remote Server IP Address: " REMOTE_HOST
    read -r -p "Enter Path to SSH Private Key (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        error_exit "SSH key file not found at $SSH_KEY_PATH"
    fi

    # 5. Application Port
    read -r -p "Enter Application Container Port (e.g., 3000): " APP_PORT
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [[ "$APP_PORT" -lt 1 || "$APP_PORT" -gt 65535 ]]; then
        error_exit "Invalid application port. Must be a number between 1 and 65535."
    fi

    log_message "INFO" "Parameters collected successfully."
}

# --- Local Repository Management (Stage 2 & 3) ---

manage_local_repo() {
    log_message "INFO" "Starting local repository operations."

    # Authenticated URL for cloning/pulling
    AUTH_URL=$(echo "$GIT_REPO" | sed "s/:\/\//:\/\/$PAT@/")

    if [ -d "$REPO_DIR" ]; then
        log_message "INFO" "Repository directory '$REPO_DIR' already exists. Pulling latest changes..."
        (cd "$REPO_DIR" && git pull --rebase origin "$BRANCH")
    else
        log_message "INFO" "Cloning repository '$GIT_REPO' into '$REPO_DIR'..."
        # We need to suppress PAT in logs, but git won't clone with PAT directly in URL unless it's basic auth
        # Using a temporary credential helper is more secure, but simpler is to use a masked URL (HTTP/S only)
        # Since this is a script environment, we'll rely on the user having a good PAT setup,
        # but clone with the masked URL for the PAT usage.
        git clone --branch "$BRANCH" "$AUTH_URL" "$REPO_DIR" 2>/dev/null
    fi

    log_message "SUCCESS" "Repository cloned/updated and switched to branch '$BRANCH'."

    # Navigate into the cloned directory and check for Docker artifacts
    cd "$REPO_DIR"
    if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
        error_exit "No Dockerfile or docker-compose.yml found in the repository root. Cannot deploy."
    fi
    log_message "SUCCESS" "Verified Docker artifact existence in $REPO_DIR."
}

# --- Remote Execution Logic (Stages 4, 5, 6, 7, 8) ---

# This function defines the set of commands to be executed on the remote server via SSH
remote_execution_plan() {
    local SSH_COMMAND="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no $REMOTE_USER@$REMOTE_HOST"

    # 4. SSH Connection & Connectivity Check
    log_message "INFO" "Checking SSH connectivity to $REMOTE_HOST..."
    if ! $SSH_COMMAND "echo 'SSH connection successful'" 2>/dev/null; then
        error_exit "Failed to establish SSH connection to $REMOTE_HOST. Check IP, user, and SSH key path."
    fi
    log_message "SUCCESS" "SSH connectivity confirmed."

    # 5. Prepare the Remote Environment
    log_message "INFO" "Preparing remote environment (installing Docker, Docker Compose, Nginx)..."
    $SSH_COMMAND << EOF
        set -euo pipefail
        
        # --- Stage 5: System Update and Prerequisite Installation ---

        # Use -y for non-interactive mode
        if command -v apt &> /dev/null; then
            sudo apt update -y
            sudo apt install -y docker.io docker-compose nginx curl
        elif command -v yum &> /dev/null; then
            sudo yum update -y
            sudo yum install -y docker docker-compose nginx curl
            sudo systemctl start docker
            sudo systemctl enable docker
        else
            echo "ERROR: Unsupported package manager (only apt/yum supported)."
            exit 1
        fi

        # Add user to docker group (if not already there)
        if ! getent group docker | grep -q "\b$(whoami)\b"; then
            echo "Adding user \$(whoami) to docker group..."
            sudo usermod -aG docker \$(whoami)
            # Need to re-login for changes to take effect, but for script continuation,
            # we will use 'sg' or rely on the user having previously run this step.
            # For simplicity in a single script run, we rely on sudo/sg for permissions.
        fi

        # Enable and start services
        sudo systemctl enable nginx || true
        sudo systemctl start nginx || true
        
        echo "Docker Version: \$(docker --version || echo 'Not Installed')"
        echo "Docker Compose Version: \$(docker-compose --version || echo 'Not Installed')"
        echo "Nginx Version: \$(nginx -v 2>&1 || echo 'Not Installed')"
        echo "Remote environment setup complete."

EOF
    log_message "SUCCESS" "Remote environment configured."

    # 6. Deploy the Dockerized Application

    log_message "INFO" "Transferring project files via rsync..."
    # rsync is used for efficient transfer (only sends changed files)
    rsync -avz -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" --exclude='.git/' . "$REMOTE_USER@$REMOTE_HOST:/home/$REMOTE_USER/$APP_NAME"
    log_message "SUCCESS" "Project files transferred."

    log_message "INFO" "Running deployment on remote server..."
    $SSH_COMMAND << EOF
        set -euo pipefail

        # Set deployment variables
        DEPLOY_DIR="/home/$REMOTE_USER/$APP_NAME"
        CONTAINER_NAME_REMOTE="$CONTAINER_NAME-$APP_NAME"
        NETWORK_NAME_REMOTE="$NETWORK_NAME-$APP_NAME"

        cd "\$DEPLOY_DIR"

        # Idempotency and Cleanup (Step 10 part)
        echo "Stopping and removing existing container and network..."
        docker stop "\$CONTAINER_NAME_REMOTE" 2>/dev/null || true
        docker rm "\$CONTAINER_NAME_REMOTE" 2>/dev/null || true
        docker network rm "\$NETWORK_NAME_REMOTE" 2>/dev/null || true

        echo "Creating Docker network: \$NETWORK_NAME_REMOTE"
        docker network create "\$NETWORK_NAME_REMOTE" || true

        if [ -f "docker-compose.yml" ]; then
            echo "Deploying with docker-compose..."
            docker-compose -p "\$APP_NAME" up -d
            # Container name is often implicitly projectname_service_1 for compose
            # We assume the main container is the one running on the APP_PORT
        elif [ -f "Dockerfile" ]; then
            echo "Deploying with Dockerfile (plain docker build/run)..."
            # Build the image
            docker build -t "\$APP_NAME:latest" .

            # Run the container
            docker run -d \
                --name "\$CONTAINER_NAME_REMOTE" \
                --network "\$NETWORK_NAME_REMOTE" \
                -p $APP_PORT:$APP_PORT \
                "\$APP_NAME:latest"
        else
            echo "ERROR: Docker configuration files not found."
            exit 1
        fi

        # Validate container health and logs
        echo "Checking container health for \$CONTAINER_NAME_REMOTE..."
        sleep 5 # Give container time to start up
        if docker ps -f name="\$CONTAINER_NAME_REMOTE" --format "{{.Status}}" | grep -q "healthy\|Up"; then
            echo "SUCCESS: Container is running."
        else
            echo "ERROR: Container failed to start. Logs:"
            docker logs "\$CONTAINER_NAME_REMOTE"
            exit 1
        fi
EOF
    log_message "SUCCESS" "Dockerized application built and deployed on remote server."

    # 7. Configure Nginx as a Reverse Proxy

    log_message "INFO" "Configuring Nginx reverse proxy..."
    # Dynamically create Nginx configuration file content using a Heredoc
    NGINX_CONF=$(cat << _NGINX_CONF_
server {
    listen 80;
    server_name $REMOTE_HOST; # Use IP as server name

    location / {
        # Forward traffic to the deployed container's port
        proxy_pass http://127.0.0.1:$APP_PORT; 
        
        # Standard proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Optional SSL readiness placeholder (needs actual cert files)
    # To enable SSL, uncomment and configure paths:
    # listen 443 ssl;
    # ssl_certificate /etc/nginx/ssl/server.crt;
    # ssl_certificate_key /etc/nginx/ssl/server.key;
}
_NGINX_CONF_
)
    
    # Use SSH to pipe the Nginx config string into a file on the remote server
    $SSH_COMMAND "
        set -euo pipefail
        NGINX_SITES_AVAILABLE='/etc/nginx/sites-available/$APP_NAME.conf'
        NGINX_SITES_ENABLED='/etc/nginx/sites-enabled/$APP_NAME.conf'

        # 1. Write the configuration
        echo 'Writing Nginx config to \$NGINX_SITES_AVAILABLE'
        sudo sh -c \"echo '$NGINX_CONF' > \$NGINX_SITES_AVAILABLE\"

        # 2. Link the configuration
        if [ ! -L \$NGINX_SITES_ENABLED ]; then
            echo 'Enabling Nginx site'
            sudo ln -s \$NGINX_SITES_AVAILABLE \$NGINX_SITES_ENABLED || true
        fi
        
        # 3. Test and Reload
        echo 'Testing Nginx configuration...'
        if sudo nginx -t; then
            echo 'Reloading Nginx service...'
            sudo systemctl reload nginx
            echo 'SUCCESS: Nginx reloaded.'
        else
            echo 'ERROR: Nginx configuration test failed.'
            exit 1
        fi
    "
    log_message "SUCCESS" "Nginx reverse proxy configured and reloaded."

    # 8. Validate Deployment (Remote and Local Check)
    log_message "INFO" "Starting final deployment validation..."
    
    # Remote check (via loopback on the remote host)
    $SSH_COMMAND << EOF
        set -euo pipefail
        
        echo "Validating Nginx proxy (local check on port 80)..."
        if curl -sI http://127.0.0.1/ | grep -q 'HTTP/1.1 200 OK'; then
            echo "SUCCESS: Remote Nginx proxy check passed (port 80 -> app)."
        else
            echo "ERROR: Remote Nginx proxy check failed. Status code not 200."
            exit 1
        fi
EOF
    
    # Local check (from the current machine to the remote IP on port 80)
    log_message "INFO" "Validating external access to $REMOTE_HOST:80..."
    if curl -sI "http://$REMOTE_HOST/" | grep -q 'HTTP/1.1 200 OK'; then
        log_message "SUCCESS" "External access validation passed. App is live at http://$REMOTE_HOST"
    else
        log_message "ERROR" "External access validation failed. Check firewall rules or application health."
        # This is a soft error, we continue since the remote checks passed.
    fi

}

# --- Idempotency and Cleanup (Stage 10) ---

cleanup_remote_environment() {
    log_message "INFO" "Starting remote cleanup process for application: $APP_NAME."
    local SSH_COMMAND="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no $REMOTE_USER@$REMOTE_HOST"
    
    $SSH_COMMAND << EOF
        set -euo pipefail
        
        CONTAINER_NAME_REMOTE="$CONTAINER_NAME-$APP_NAME"
        NETWORK_NAME_REMOTE="$NETWORK_NAME-$APP_NAME"
        NGINX_CONF_PATH='/etc/nginx/sites-available/$APP_NAME.conf'

        echo "1. Stopping and removing Docker container: \$CONTAINER_NAME_REMOTE"
        docker stop "\$CONTAINER_NAME_REMOTE" 2>/dev/null || true
        docker rm "\$CONTAINER_NAME_REMOTE" 2>/dev/null || true

        echo "2. Removing Docker image: $APP_NAME:latest"
        docker rmi "$APP_NAME:latest" 2>/dev/null || true

        echo "3. Removing Docker network: \$NETWORK_NAME_REMOTE"
        docker network rm "\$NETWORK_NAME_REMOTE" 2>/dev/null || true
        
        echo "4. Removing local project directory: /home/$REMOTE_USER/$APP_NAME"
        rm -rf "/home/$REMOTE_USER/$APP_NAME"

        echo "5. Cleaning up Nginx configuration..."
        sudo rm -f "/etc/nginx/sites-enabled/$APP_NAME.conf" 2>/dev/null || true
        sudo rm -f "\$NGINX_CONF_PATH" 2>/dev/null || true

        echo "6. Testing and reloading Nginx after cleanup..."
        if sudo nginx -t; then
            sudo systemctl reload nginx
            echo "Nginx reloaded successfully."
        else
            echo "WARNING: Could not reload Nginx after config removal. Service may need manual restart."
            # Do not exit on error here, cleanup should continue
        fi

        echo "Cleanup completed successfully on remote server."
EOF
    
    log_message "SUCCESS" "Remote environment for '$APP_NAME' successfully cleaned up."
    log_message "INFO" "Removing local repository directory: $REPO_DIR"
    rm -rf "$REPO_DIR"
    log_message "SUCCESS" "Local cleanup completed."
    
}

# --- Main Execution Flow ---

main() {
    collect_parameters "$@"

    if $CLEANUP_MODE; then
        cleanup_remote_environment
        log_message "INFO" "--- Script Finished (Cleanup Mode) ---"
        exit 0
    fi

    log_message "INFO" "Starting deployment for application '$APP_NAME' on '$REMOTE_HOST'."

    # Stage 2 & 3: Local Repository Management
    manage_local_repo

    # Stages 4, 5, 6, 7, 8: Remote Execution
    # Note: We return to the original directory by not using a subshell for manage_local_repo
    # The remote_execution_plan handles all SSH and remote commands.
    remote_execution_plan

    log_message "INFO" "--- Deployment Completed Successfully! ---"
    exit 0
}

# Execute the main function
main "$@"
