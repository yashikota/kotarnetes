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
sh scripts/incus-init.sh
newgrp incus-admin
```

これにより、Incusがインストールされ、cloud-initを使用して以下のVMが作成されます

- k8s-master （マスターノード）
- k8s-worker1（ワーカーノード1）
- k8s-worker2（ワーカーノード2）

### 2. k8sクラスターの初期化

```sh
sh scripts/cluster-init.sh
```
