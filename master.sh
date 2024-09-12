#!/bin/bash

# Update and upgrade the system
sudo apt update -y
sudo apt upgrade -y

# Install required packages
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg

# Modify the needrestart configuration to auto-restart services after updates
sudo sed -i 's/#$nrconf{restart} = .*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf

# Disable swap immediately
sudo swapoff -a

# Remove any existing swap file
sudo rm -f /swap.img

# Comment out any swap entry from /etc/fstab to prevent it from being enabled on reboot
sudo sed -i '/swap/d' /etc/fstab

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
127.0.1.1 k8master

10.1.80.10 k8master
10.1.80.80 k8worker1
10.1.80.82 k8worker2
EOF'

# Download and apply Calico network plugin
wget https://raw.githubusercontent.com/projectcalico/calico/master/manifests/calico.yaml
kubectl apply -f calico.yaml

# Initialize Kubernetes master and save output to kubeadm-init.log
sudo kubeadm init --kubernetes-version 1.27.14 | tee kubeadm-init.log

# Set up local kubeconfig for kubectl to interact with the cluster
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Apply the Calico CNI plugin to the cluster
kubectl apply -f calico.yaml

# Function to check if all pods are running
function check_pods_running {
  while true; do
    # Check if any pods are not in running state
    if kubectl get pods --all-namespaces --no-headers | awk '{print $4}' | grep -v 'Running' > /dev/null 2>&1; then
      echo "Waiting for all pods to be in 'Running' state..."
      sleep 10
    else
      echo "All pods are running!"
      break
    fi
  done
}

# Start kubectl get pods in watch mode in the background and capture its PID
kubectl get pods --all-namespaces -w &
KUBECTL_PID=$!

# Call the function to wait for pods to be running
check_pods_running

# Stop the kubectl watch process after all pods are running
kill $KUBECTL_PID

# Print the kubeadm join command after pods are running
echo "Use the following command to join worker nodes to the cluster:"
grep -A2 "kubeadm join" kubeadm-init.log

# Return to the prompt
