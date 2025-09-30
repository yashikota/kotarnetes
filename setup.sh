# Install Incus
sudo apt install -y incus qemu-system
sudo adduser $USER incus-admin
newgrp incus-admin

# Initialize Incus
incus admin init --preseed < incus-init.yaml

# Create VM with cloud-init
incus launch images:ubuntu/24.04/cloud k8s-master --vm --config=user.user-data="$(cat scripts/cloud-init.yaml)"
incus launch images:ubuntu/24.04/cloud k8s-worker1 --vm --config=user.user-data="$(cat scripts/cloud-init.yaml)"
incus launch images:ubuntu/24.04/cloud k8s-worker2 --vm --config=user.user-data="$(cat scripts/cloud-init.yaml)"

# Check VM status
incus list
