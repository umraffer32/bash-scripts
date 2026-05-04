#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

APT_PACKAGES=(
  gh
  kubectx
  packer
  vault
  consul
  nomad
  direnv
  bat
  eza
  zoxide
  unzip
)

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

verify_checksum_file() {
  local artifact="$1"
  local checksum_file="$2"
  local artifact_name
  local expected
  local actual

  artifact_name="$(basename "$artifact")"
  expected="$(awk -v name="$artifact_name" '$NF == name { print $1; found=1; exit } END { if (!found) exit 1 }' "$checksum_file")"
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

install_apt_packages() {
  sudo apt-get update
  sudo apt-get install -y "${APT_PACKAGES[@]}"
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

verify_tools() {
  gh --version
  docker ps
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
}

main() {
  if ! grep -q '^ID=ubuntu$' /etc/os-release; then
    printf 'This bootstrap script expects Ubuntu.\n' >&2
    exit 1
  fi

  install_apt_packages
  ensure_fd_symlink
  ensure_bat_symlink
  install_release_binaries
  verify_tools
}

main "$@"
