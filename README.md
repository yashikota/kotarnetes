# kotarnetes

kota + kubernetes = kotarnetes

## システム要件

Ubuntu 24.04

## 技術スタック

- Incus
- Kubernetes (v1.34)
- Cilium
- Helm
- Argo CD
- Metrics Server
- Kubernetes Dashboard
- k9s
- cloudflared

## セットアップ

### 1. VMの作成

```bash
sh scripts/vm.sh
newgrp incus-admin
```

これにより、Incusがインストールされ、cloud-initを使用して以下のVMが作成されます

- k8s-master
- k8s-worker1
- k8s-worker2

### 2. k8sクラスターの作成

```sh
sh scripts/cluster.sh
```
