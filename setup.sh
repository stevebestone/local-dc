#!/usr/bin/env bash
#
# Datacenter-in-a-Box — Bootstrap
# Installs Ansible (if needed) and runs the playbook.
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./setup.sh"; exit 1; }

# Install Ansible if missing
if ! command -v ansible-playbook &>/dev/null; then
    echo "Installing Ansible..."
    if command -v rpm-ostree &>/dev/null; then
        rpm-ostree install --idempotent --allow-inactive ansible-core
        if rpm-ostree status | grep -q Staged; then
            echo "Ansible staged. Reboot and re-run: sudo reboot && sudo ./setup.sh"
            exit 0
        fi
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq ansible
    elif command -v dnf &>/dev/null; then
        dnf install -y -q ansible-core
    fi
fi

# Install required Ansible collections
ansible-galaxy collection install ansible.posix community.general --force 2>/dev/null || true

# Run the playbook
ansible-playbook \
    -i "$SCRIPT_DIR/ansible/inventory.yml" \
    "$SCRIPT_DIR/ansible/playbook.yml" \
    --become \
    "$@"
