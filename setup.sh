# Install Incus
sudo apt install -y incus qemu-system
sudo adduser $USER incus-admin

# Initialize Incus
sudo incus admin init --preseed < scripts/incus-init.yaml

# Create VM with cloud-init
sudo incus launch images:ubuntu/24.04/cloud k8s-master --vm --config=user.user-data="$(cat scripts/cloud-init.yaml)"
sudo incus launch images:ubuntu/24.04/cloud k8s-worker1 --vm --config=user.user-data="$(cat scripts/cloud-init.yaml)"
sudo incus launch images:ubuntu/24.04/cloud k8s-worker2 --vm --config=user.user-data="$(cat scripts/cloud-init.yaml)"

# Check VM status
sudo incus list

