#!/usr/bin/env bash
set -Eeuo pipefail

# ===================== Helpers =====================

yes_no() {
  local prompt="${1:-Are you sure? (y/n): }"
  local reply
  read -rp "$prompt " reply || true
  reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
  [[ "$reply" == "y" || "$reply" == "yes" ]]
}

ask_default() {
  local prompt="${1:?}"
  local def="${2:-}"
  local reply
  if [[ -n "$def" ]]; then
    read -rp "$prompt [$def]: " reply || true
    echo "${reply:-$def}"
  else
    read -rp "$prompt: " reply || true
    echo "$reply"
  fi
}

require() {
  local cmd="$1"; local pkg="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$pkg" ]]; then
      sudo apt-get update -y
      sudo apt-get install -y "$pkg"
    else
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  fi
}

docker_codename() {
  . /etc/os-release
  case "${VERSION_ID:-}" in
    24.04*) echo "noble" ;;
    22.04*) echo "jammy" ;;
    20.04*) echo "focal" ;;
    *)      echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
  esac
}

detect_minikube_driver() {
  if command -v docker >/dev/null 2>&1; then
    echo "docker"
  elif command -v podman >/dev/null 2>&1; then
    echo "podman"
  else
    echo "none"
  fi
}

# --- NEW: ensure we can talk to Docker daemon in this shell ---
ensure_docker_access() {
  echo
  echo "Verifying Docker daemon access..."

  # Is docker installed?
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker CLI not found. Skipping docker access checks."
    return 0
  fi

  # Is user listed in docker group (in /etc/group)?
  local listed_in_group="no"
  if getent group docker | grep -qw "\b${USER}\b"; then
    listed_in_group="yes"
  fi

  # Does this shell currently have docker group effective?
  local in_group_now="no"
  if id -nG "$USER" | grep -qw docker; then
    in_group_now="yes"
  fi

  # Offer to add user to group if not listed
  if [[ "$listed_in_group" == "no" ]]; then
    echo "User '$USER' is NOT in the 'docker' group."
    if yes_no "Add '$USER' to the 'docker' group now? (y/n):"; then
      sudo groupadd docker 2>/dev/null || true
      sudo usermod -aG docker "$USER"
      echo "Added '$USER' to 'docker' group."
      echo "➡ Open a NEW SSH session or run: newgrp docker"
    else
      echo "Skipping group add. Docker (and Minikube docker driver) may fail without sudo."
    fi
  fi

  # If listed but not effective in this shell, advise newgrp
  if [[ "$listed_in_group" == "yes" && "$in_group_now" == "no" ]]; then
    echo "You are in 'docker' group, but this shell doesn't have it yet."
    echo "➡ Run: newgrp docker    (or open a new SSH session)"
  fi

  # Ensure dockerd is running
  if ! systemctl is-active --quiet docker; then
    echo "Docker service is not active; attempting to start it..."
    sudo systemctl start docker || true
  fi

  # Check socket permissions and basic connectivity
  if [[ -S /var/run/docker.sock ]]; then
    ls -l /var/run/docker.sock || true
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker CLI cannot talk to the daemon yet."
    echo "Try: newgrp docker; then test: docker run --rm hello-world"
  else
    echo "Docker daemon access OK."
  fi
}

# ===================== Start =====================

echo "Updating system package index..."
sudo apt-get update -y

# ---------------- Docker ----------------
install_or_reinstall_docker() {
  echo "Setting up Docker apt repository..."
  require curl curl
  require gpg gnupg

  sudo rm -f \
    /etc/apt/sources.list.d/archive_uri-https_download_docker_com_linux_debian-*.list \
    /etc/apt/sources.list.d/docker.list

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  DOCKER_CODENAME="$(docker_codename)"
  echo "Using Docker repo codename: ${DOCKER_CODENAME}"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo sed -i 's/\r$//' /etc/apt/sources.list.d/docker.list
  sudo apt-get update -y

  echo "Installing Docker Engine..."
  sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
  sudo apt-get install -y \
    ca-certificates curl gnupg \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "Docker installed: $(docker --version)"
}

echo
if command -v docker >/dev/null 2>&1; then
  echo "Docker is already installed: $(docker --version)"
  if yes_no "Do you want to reinstall Docker? (y/n):"; then
    install_or_reinstall_docker
  else
    echo "Skipping Docker reinstall."
  fi
else
  echo "Docker is not installed."
  if yes_no "Do you want to install Docker? (y/n):"; then
    install_or_reinstall_docker
  else
    echo "Skipping Docker install."
  fi
fi

# Optional: Add current user to docker group
if command -v docker >/dev/null 2>&1; then
  if yes_no "Add the current user to the 'docker' group to run docker without sudo? (y/n):"; then
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker "$USER"
    echo "User '$USER' added to 'docker' group. Log out/in or run: newgrp docker"
  fi
fi

# ---------------- Podman ----------------
echo
install_or_reinstall_podman() {
  echo "Installing Podman..."
  sudo apt-get update -y
  sudo apt-get install -y podman
  echo "Podman installed: $(podman --version)"
}

if command -v podman >/dev/null 2>&1; then
  echo "Podman is already installed: $(podman --version)"
  if yes_no "Do you want to reinstall Podman? (y/n):"; then
    install_or_reinstall_podman
  else
    echo "Skipping Podman reinstall."
  fi
else
  echo "Podman is not installed."
  if yes_no "Do you want to install Podman? (y/n):"; then
    install_or_reinstall_podman
  else
    echo "Skipping Podman install."
  fi
fi

# ---------------- kubectl (Kubernetes CLI) ----------------
echo
install_or_reinstall_kubectl() {
  echo "Installing kubectl (stable)..."
  require curl curl
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) KARCH=amd64 ;;
    arm64) KARCH=arm64 ;;
    armhf) KARCH=arm ;;
    *) echo "Unsupported architecture for kubectl: $ARCH" >&2; return 1 ;;
  esac
  cd /tmp
  curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${KARCH}/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

  echo "kubectl binary kept at: /tmp/kubectl"
  echo "kubectl installed at: /usr/local/bin/kubectl"
  echo "kubectl version:"
  kubectl version --client || true
}

if command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is already installed:"
  kubectl version --client || true
  if yes_no "Do you want to reinstall kubectl? (y/n):"; then
    install_or_reinstall_kubectl
  else
    echo "Skipping kubectl reinstall."
  fi
else
  echo "kubectl is not installed."
  if yes_no "Do you want to install kubectl? (y/n):"; then
    install_or_reinstall_kubectl
  else
    echo "Skipping kubectl install."
  fi
fi

# ---------------- Minikube ----------------
echo
install_or_reinstall_minikube() {
  echo "Installing Minikube..."
  require curl curl
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) MARCH=amd64 ;;
    arm64) MARCH=arm64 ;;
    *) echo "Unsupported architecture for Minikube: $ARCH" >&2; return 1 ;;
  esac
  cd /tmp
  curl -fsSLO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${MARCH}"
  sudo install -o root -g root -m 0755 "minikube-linux-${MARCH}" /usr/local/bin/minikube
  rm -f "minikube-linux-${MARCH}"
  echo "Minikube installed: $(minikube version)"
}

minikube_driver_setup() {
  local suggested; suggested="$(detect_minikube_driver)"
  local driver; driver="$(ask_default "Choose Minikube driver (docker/podman/none)" "$suggested")"
  case "$driver" in
    docker|podman|none) : ;;
    *) echo "Unknown driver '$driver'. Using '$suggested'."; driver="$suggested" ;;
  esac

  # If docker driver, ensure current shell can access Docker
  if [[ "$driver" == "docker" ]]; then
    ensure_docker_access
  fi

  local cpus mem
  cpus="$(ask_default "CPUs for Minikube" "2")"
  mem="$(ask_default "Memory (MB) for Minikube" "4096")"

  local cmd=(minikube start --driver="${driver}" --cpus="${cpus}" --memory="${mem}")
  if [[ "$driver" == "podman" ]]; then
    cmd+=(--container-runtime=cri-o)
  fi

  echo "Starting Minikube: ${cmd[*]}"
  "${cmd[@]}"

  echo "Minikube status:"
  minikube status || true

  if command -v kubectl >/dev/null 2>&1; then
    kubectl config use-context minikube >/dev/null 2>&1 || true
    echo "kubectl current-context: $(kubectl config current-context || echo 'unknown')"
    echo "Try: kubectl get nodes"
  fi
}

if command -v minikube >/dev/null 2>&1; then
  echo "Minikube is already installed: $(minikube version)"
  if yes_no "Do you want to reinstall Minikube? (y/n):"; then
    install_or_reinstall_minikube
  else
    echo "Skipping Minikube reinstall."
  fi
else
  echo "Minikube is not installed."
  if yes_no "Do you want to install Minikube? (y/n):"; then
    install_or_reinstall_minikube
  else
    echo "Skipping Minikube install."
  fi
fi

# Offer to start a cluster now
if command -v minikube >/dev/null 2>&1; then
  if yes_no "Do you want to start a Minikube cluster now? (y/n):"; then
    minikube_driver_setup
  else
    echo "You can start later with: minikube start --driver=$(detect_minikube_driver)"
  fi
fi

# ---------------- Git (install + user config) ----------------
echo
install_or_configure_git() {
  echo "Installing Git..."
  sudo apt-get update -y
  sudo apt-get install -y git

  echo "Configuring Git user settings (global)..."
  local cur_name cur_email cur_branch
  cur_name="$(git config --global user.name || true)"
  cur_email="$(git config --global user.email || true)"
  cur_branch="$(git config --global init.defaultBranch || true)"

  local name email branch
  name="$(ask_default "Your Git user.name" "${cur_name:-$USER}")"
  email="$(ask_default "Your Git user.email" "${cur_email:-}")"
  branch="$(ask_default "Default branch name for new repos" "${cur_branch:-main}")"

  git config --global user.name "$name"
  git config --global user.email "$email"
  git config --global init.defaultBranch "$branch"

  git config --global pull.rebase false
  git config --global push.default simple
  git config --global core.editor "${EDITOR:-nano}"

  echo "Git configured:"
  git config --global --list | sed 's/^/  /'

  if yes_no "Generate a new SSH key for Git (ed25519) and show its public key? (y/n):"; then
    require ssh-keygen openssh-client
    local email_for_key="${email:-$USER@$(hostname -f 2>/dev/null || hostname)}"
    local keyfile="$HOME/.ssh/id_ed25519"
    if [[ -f "$keyfile" ]]; then
      echo "SSH key already exists at $keyfile"
    else
      mkdir -p "$HOME/.ssh"
      chmod 700 "$HOME/.ssh"
      ssh-keygen -t ed25519 -C "$email_for_key" -f "$keyfile" -N ""
      chmod 600 "$keyfile"
      chmod 644 "${keyfile}.pub"
    fi
    echo "Public key (${keyfile}.pub):"
    echo "------------------------------------------------------------"
    cat "${keyfile}.pub"
    echo "------------------------------------------------------------"
    echo "Add this public key to GitHub/GitLab/Bitbucket SSH keys."
  fi
}

if command -v git >/dev/null 2>&1; then
  echo "Git is already installed: $(git --version)"
  if yes_no "Do you want to (re)configure Git user settings now? (y/n):"; then
    install_or_configure_git
  else
    echo "Skipping Git reconfiguration."
  fi
else
  echo "Git is not installed."
  if yes_no "Do you want to install and configure Git now? (y/n):"; then
    install_or_configure_git
  else
    echo "Skipping Git."
  fi
fi

echo
echo "✅ All selected tools have been processed."
