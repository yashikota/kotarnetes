# Install Incus
sudo apt install -y incus qemu-system
sudo adduser $USER incus-admin
newgrp incus-admin

# Initialize Incus
incus admin init --preseed < incus-init.yaml

# Create VM
incus launch images:ubuntu/24.04 k8s-master --vm
incus launch images:ubuntu/24.04 k8s-worker1 --vm
incus launch images:ubuntu/24.04 k8s-worker2 --vm

# Check VM status
incus list
