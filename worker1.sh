#!/bin/bash

# Update and upgrade the system
sudo apt update -y
sudo apt upgrade -y

# Install required packages
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg

# Disable swap immediately (required by Kubernetes)
sudo swapoff -a

# Remove or comment out any swap entry from /etc/fstab to disable it persistently
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Verify that swap is disabled
if free | grep -i swap | awk '{print $2}' | grep -q '^0$'; then
  echo "Swap is disabled."
else
  echo "Error: Swap is still enabled."
fi

# Load necessary kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Load the modules into the running system
sudo modprobe overlay
sudo modprobe br_netfilter

# Set sysctl parameters required by Kubernetes
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply the sysctl parameters without reboot
sudo sysctl --system

# Install containerd
sudo apt-get install -y containerd

# Create containerd config directory and configure it for Kubernetes
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup in containerd configuration
sudo sed -i 's/            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd to apply changes
sudo systemctl restart containerd

# Add Kubernetes APT repository
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.27/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.27/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update the package index and install Kubernetes tools
sudo apt-get update
VERSION=1.27.14-1.1
sudo apt-get install -y kubelet=$VERSION kubeadm=$VERSION kubectl=$VERSION

# Prevent automatic updates for Kubernetes components
sudo apt-mark hold kubelet kubeadm kubectl containerd

# Restart kubelet to apply changes
sudo systemctl restart kubelet

# Update /etc/hosts with new entries (replace existing content)
sudo bash -c 'cat <<EOF > /etc/hosts
127.0.0.1 localhost
127.0.1.1 k8worker1

10.1.80.10 k8master
10.1.80.80 k8worker1
10.1.80.82 k8worker2
EOF'

# Create necessary directories under /mnt and set permissions and ownership for Palo Alto CN firewall
sudo mkdir -p /mnt/pan-local{1..6}
sudo chmod 755 /mnt/pan-local{1..6}
sudo chown -R jan:jan /mnt/pan-local{1..6}

# Create necessary directories under /var/log and set permissions and ownership
sudo mkdir -p /var/log/pan-appinfo/pan-cni-ready
sudo chmod 755 /var/log/pan-appinfo /var/log/pan-appinfo/pan-cni-ready
sudo chown -R jan:jan /var/log/pan-appinfo

echo "Worker node setup complete. Please join the cluster manually with 'kubeadm join'."
