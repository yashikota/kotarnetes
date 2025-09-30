# kotarnetes

kota + kubernetes = kotarnetes

## システム要件

Ubuntu 24.04

## 技術スタック

- Incus
- Kubernetes (v1.34)

## セットアップ

### 1. 環境の構築

```bash
sh setup.sh
```

これにより、Incusがインストールされ、cloud-initを使用して以下のVMが作成されます

- k8s-master （マスターノード）
- k8s-worker1（ワーカーノード1）
- k8s-worker2（ワーカーノード2）
