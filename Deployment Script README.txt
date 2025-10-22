Automated Deployment Bash Script (deploy.sh)

This script automates the full setup, deployment, and configuration of a Dockerized application on a remote Linux server. It is designed to be robust, idempotent, and production-grade, incorporating extensive logging, error handling, and validation at every stage.

Prerequisites

Before running the script, ensure you have the following:

A remote Linux server (Ubuntu/Debian or RHEL/CentOS compatible) with basic SSH access.

SSH Key Pair: The script requires the local path to your private SSH key (id_rsa or similar) to connect to the remote server.

Git Personal Access Token (PAT): A GitHub (or other Git provider) PAT is required to clone private repositories. It must have the repo scope.

Local Tools: bash, git, and rsync must be installed locally on the machine running this script.

Usage

1. Make the script executable

chmod +x deploy.sh


2. Run the deployment

Execute the script and follow the interactive prompts to provide the necessary parameters.

./deploy.sh


3. Run the cleanup (Optional)

To safely stop, remove the container, image, network, Nginx config, and the project files on the remote server, run the script with the --cleanup flag.

./deploy.sh --cleanup


Script Stages and Features

The script executes the following steps in sequence:

Stage

Action

Features

1. Collect Parameters

Gathers and validates all required inputs: Git URL, PAT, Branch, SSH credentials (User, Host, Key Path), and Application Port.

Input validation, silent input for PAT.

2 & 3. Local Setup

Authenticates and clones/pulls the specified Git repository.

Uses PAT for authentication, handles existing directories (pulls instead of clones), verifies Dockerfile or docker-compose.yml existence.

4. SSH Connectivity

Establishes SSH connection to the remote host.

Performs dry-run check before executing payload.

5. Remote Prepare

Updates system packages and installs Docker, Docker Compose, and Nginx (if missing).

Supports apt and yum systems, adds the user to the docker group, enables/starts services.

6. Deployment

Transfers project files via rsync, builds, and runs the application containers.

Idempotency: Stops/removes old containers gracefully. Supports both plain Dockerfile build/run and docker-compose up -d.

7. Nginx Config

Dynamically generates an Nginx reverse proxy configuration.

Forwards port 80 traffic to the specified internal container port (APP_PORT), tests config (nginx -t), and reloads Nginx.

8. Validation

Confirms container health and Nginx proxying is working.

Uses docker ps for container health check and curl both remotely (loopback) and locally (external access) on port 80.

9 & 10. Robustness

Logging, Error Handling, and Idempotency.

Uses set -euo pipefail, trap for unexpected errors, and logs all actions to a timestamped file (deploy_YYYYMMDD.log). Implements the optional --cleanup flag.