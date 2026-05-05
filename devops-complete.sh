#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# This script is intended to work on a fresh Ubuntu 24.04 amd64 VM.

PRE_APT_PACKAGES=(
  apt-transport-https
  ca-certificates
  curl
  gnupg
  lsb-release
  software-properties-common
)

BASE_APT_PACKAGES=(
  dnsutils
  fd-find
  fzf
  git
  iproute2
  jq
  make
  build-essential
  netcat-openbsd
  openssh-client
  pipx
  pre-commit
  python3
  python3-pip
  python3-venv
  ripgrep
  rsync
  shellcheck
  shfmt
  tcpdump
  tmux
  unzip
)

APT_PACKAGES=(
  age
  ansible
  bat
  code
  consul
  containerd.io
  direnv
  docker-buildx-plugin
  docker-ce
  docker-ce-cli
  docker-compose-plugin
  eza
  gh
  kubectx
  nomad
  packer
  terraform
  vault
  zoxide
)

KUBECTL_VERSION="1.36.0"
HELM_VERSION="4.1.4"
SOPS_VERSION="3.12.2"
STERN_VERSION="1.34.0"
K9S_VERSION="0.50.18"
KIND_VERSION="0.31.0"
TERRAGRUNT_VERSION="1.0.3"
TFLINT_VERSION="0.62.0"
TERRAFORM_DOCS_VERSION="0.22.0"

download() {
  local url="$1"
  local output="$2"

  curl --fail --location --show-error --silent --retry 3 --retry-delay 2 \
    --output "$output" "$url"
}

ubuntu_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s\n' "$VERSION_CODENAME"
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

require_ubuntu_amd64() {
  if ! grep -q '^ID=ubuntu$' /etc/os-release; then
    printf 'This bootstrap script expects Ubuntu.\n' >&2
    exit 1
  fi

  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    printf 'This bootstrap script currently installs amd64 release binaries only.\n' >&2
    exit 1
  fi
}

verify_checksum_file() {
  local artifact="$1"
  local checksum_file="$2"
  local artifact_name
  local expected
  local actual

  artifact_name="$(basename "$artifact")"
  expected="$(
    awk -v name="$artifact_name" '
      NF == 1 {
        print $1
        found = 1
        exit
      }
      {
        file = $NF
        sub(/^\*/, "", file)
      }
      file == name {
        print $1
        found = 1
        exit
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$checksum_file"
  )"
  actual="$(sha256sum "$artifact" | awk '{ print $1 }')"

  if [[ "$expected" != "$actual" ]]; then
    printf 'Checksum mismatch for %s\nexpected: %s\nactual:   %s\n' "$artifact_name" "$expected" "$actual" >&2
    exit 1
  fi
}

verify_checksum_value() {
  local artifact="$1"
  local checksum_file="$2"
  local expected
  local actual

  expected="$(awk '{ print $1; exit }' "$checksum_file")"
  actual="$(sha256sum "$artifact" | awk '{ print $1 }')"

  if [[ "$expected" != "$actual" ]]; then
    printf 'Checksum mismatch for %s\nexpected: %s\nactual:   %s\n' "$(basename "$artifact")" "$expected" "$actual" >&2
    exit 1
  fi
}

install_tar_binary() {
  local name="$1"
  local archive_url="$2"
  local checksum_url="$3"
  local binary_relative_path="$4"
  local tmpdir
  local archive
  local checksum_file

  tmpdir="$(mktemp -d)"
  archive="$tmpdir/$(basename "$archive_url")"
  checksum_file="$tmpdir/$(basename "$checksum_url")"

  download "$archive_url" "$archive"
  download "$checksum_url" "$checksum_file"
  verify_checksum_file "$archive" "$checksum_file"

  mkdir -p "$tmpdir/extract"
  tar -xzf "$archive" -C "$tmpdir/extract"
  sudo install -m 0755 "$tmpdir/extract/$binary_relative_path" "/usr/local/bin/$name"
  rm -rf "$tmpdir"
}

install_zip_binary() {
  local name="$1"
  local archive_url="$2"
  local checksum_url="$3"
  local binary_relative_path="$4"
  local tmpdir
  local archive
  local checksum_file

  tmpdir="$(mktemp -d)"
  archive="$tmpdir/$(basename "$archive_url")"
  checksum_file="$tmpdir/$(basename "$checksum_url")"

  download "$archive_url" "$archive"
  download "$checksum_url" "$checksum_file"
  verify_checksum_file "$archive" "$checksum_file"

  mkdir -p "$tmpdir/extract"
  unzip -q "$archive" -d "$tmpdir/extract"
  sudo install -m 0755 "$tmpdir/extract/$binary_relative_path" "/usr/local/bin/$name"
  rm -rf "$tmpdir"
}

install_direct_binary() {
  local name="$1"
  local binary_url="$2"
  local checksum_url="$3"
  local checksum_mode="$4"
  local tmpdir
  local binary
  local checksum_file

  tmpdir="$(mktemp -d)"
  binary="$tmpdir/$(basename "$binary_url")"
  checksum_file="$tmpdir/$(basename "$checksum_url")"

  download "$binary_url" "$binary"
  download "$checksum_url" "$checksum_file"

  if [[ "$checksum_mode" == "file" ]]; then
    verify_checksum_file "$binary" "$checksum_file"
  else
    verify_checksum_value "$binary" "$checksum_file"
  fi

  sudo install -m 0755 "$binary" "/usr/local/bin/$name"
  rm -rf "$tmpdir"
}

install_base_apt_packages() {
  sudo apt-get update
  sudo apt-get install -y "${PRE_APT_PACKAGES[@]}"
  ensure_universe_repository
  sudo apt-get update
  sudo apt-get install -y "${BASE_APT_PACKAGES[@]}"
}

ensure_universe_repository() {
  local sources

  sources=(/etc/apt/sources.list.d)
  if [[ -f /etc/apt/sources.list ]]; then
    sources+=('/etc/apt/sources.list')
  fi

  if grep -RE '^(Components:.*[[:space:]]universe([[:space:]]|$)|[^#].*[[:space:]]universe([[:space:]]|$))' \
    "${sources[@]}" >/dev/null 2>&1; then
    return
  fi

  sudo add-apt-repository -y universe
}

configure_docker_apt_repo() {
  local tmpdir
  local codename
  local arch

  tmpdir="$(mktemp -d)"
  codename="$(ubuntu_codename)"
  arch="$(dpkg --print-architecture)"

  sudo install -m 0755 -d /etc/apt/keyrings
  download https://download.docker.com/linux/ubuntu/gpg "$tmpdir/docker.asc"
  sudo install -m 0644 "$tmpdir/docker.asc" /etc/apt/keyrings/docker.asc

  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  rm -rf "$tmpdir"
}

configure_hashicorp_apt_repo() {
  local tmpdir
  local codename

  tmpdir="$(mktemp -d)"
  codename="$(ubuntu_codename)"

  download https://apt.releases.hashicorp.com/gpg "$tmpdir/hashicorp.asc"
  sudo gpg --dearmor --yes --output /usr/share/keyrings/hashicorp-archive-keyring.gpg "$tmpdir/hashicorp.asc"

  printf 'deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com %s main\n' "$codename" |
    sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

  rm -rf "$tmpdir"
}

configure_vscode_apt_repo() {
  local tmpdir

  tmpdir="$(mktemp -d)"

  download https://packages.microsoft.com/keys/microsoft.asc "$tmpdir/microsoft.asc"
  sudo gpg --dearmor --yes --output /usr/share/keyrings/microsoft.gpg "$tmpdir/microsoft.asc"
  sudo chmod 0644 /usr/share/keyrings/microsoft.gpg

  {
    printf 'Types: deb\n'
    printf 'URIs: https://packages.microsoft.com/repos/code\n'
    printf 'Suites: stable\n'
    printf 'Components: main\n'
    printf 'Architectures: amd64\n'
    printf 'Signed-By: /usr/share/keyrings/microsoft.gpg\n'
  } | sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null

  rm -rf "$tmpdir"
}

configure_apt_repositories() {
  configure_docker_apt_repo
  configure_hashicorp_apt_repo
  configure_vscode_apt_repo
}

install_apt_packages() {
  sudo apt-get update
  sudo apt-get install -y "${APT_PACKAGES[@]}"
}

configure_docker_access() {
  local user

  user="$(target_user)"
  sudo groupadd -f docker

  if [[ "$user" != "root" ]] && id "$user" >/dev/null 2>&1; then
    sudo usermod -aG docker "$user"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker
  else
    sudo service docker start
  fi
}

ensure_fd_symlink() {
  if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    sudo ln -s /usr/bin/fdfind /usr/local/bin/fd
  fi
}

ensure_bat_symlink() {
  if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
    sudo ln -s /usr/bin/batcat /usr/local/bin/bat
  fi
}

install_aws_cli() {
  local tmpdir

  tmpdir="$(mktemp -d)"
  download https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip "$tmpdir/awscliv2.zip"
  unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"

  if command -v aws >/dev/null 2>&1; then
    sudo "$tmpdir/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
  else
    sudo "$tmpdir/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
  fi

  rm -rf "$tmpdir"
}

install_ssm_plugin() {
  local tmpdir

  tmpdir="$(mktemp -d)"
  download https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb "$tmpdir/session-manager-plugin.deb"
  sudo apt-get install -y "$tmpdir/session-manager-plugin.deb"
  rm -rf "$tmpdir"
}

install_core_release_binaries() {
  install_direct_binary \
    kubectl \
    "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    value

  install_tar_binary \
    helm \
    "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
    linux-amd64/helm

  install_direct_binary \
    sops \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.checksums.txt" \
    file
}

install_release_binaries() {
  install_tar_binary \
    stern \
    "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_amd64.tar.gz" \
    "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/checksums.txt" \
    stern

  install_tar_binary \
    k9s \
    "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/checksums.sha256" \
    k9s

  install_direct_binary \
    kind \
    "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64" \
    "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64.sha256sum" \
    value

  install_direct_binary \
    terragrunt \
    "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64" \
    "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/SHA256SUMS" \
    file

  install_zip_binary \
    tflint \
    "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip" \
    "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt" \
    tflint

  install_tar_binary \
    terraform-docs \
    "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-amd64.tar.gz" \
    "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}.sha256sum" \
    terraform-docs
}

verify_docker() {
  local user

  docker --version

  if docker ps; then
    return
  fi

  user="$(target_user)"
  if [[ "$user" != "root" ]] && getent group docker | grep -Eq "(^|,)$user(,|$)"; then
    if sudo -u "$user" sg docker -c 'docker ps'; then
      printf 'Docker access works through the docker group. Log out and back in before using docker without sudo in this shell.\n' >&2
      return
    fi
  fi

  sudo docker ps
  printf 'Docker works with sudo. Log out and back in if this user was just added to the docker group.\n' >&2
}

verify_tools() {
  gh --version
  verify_docker
  terraform version
  packer version
  vault version
  consul version
  nomad version
  terragrunt --version
  tflint --version
  terraform-docs --version
  ansible --version
  aws --version
  session-manager-plugin --version
  kubectl version --client=true
  helm version --short
  kubectx --help >/dev/null
  kubens --help >/dev/null
  stern --version
  k9s version
  kind version
  sops --version
  age --version
  code --version
  direnv --version
  bat --version || batcat --version
  eza --version
  zoxide --version
  pipx --version
  fd --version || fdfind --version
  shellcheck --version
  shfmt -version
  pre-commit --version
}

main() {
  require_ubuntu_amd64
  install_base_apt_packages
  configure_apt_repositories
  install_apt_packages
  configure_docker_access
  ensure_fd_symlink
  ensure_bat_symlink
  install_aws_cli
  install_ssm_plugin
  install_core_release_binaries
  install_release_binaries
  verify_tools
}

main "$@"
