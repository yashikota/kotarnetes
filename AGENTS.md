# kotarnetes

## プロジェクト概要

kotarnetes は Ubuntu 24.04 上で Incus を使って Kubernetes クラスタを構築し、Argo CD による GitOps でアプリケーションをデプロイするホームラボ環境。

## セットアップコマンド

```bash
# VMの作成（Incus + cloud-init）
sh scripts/vm.sh && newgrp incus-admin

# Kubernetesクラスタの作成
sh scripts/k8s.sh

# クラスタ再作成（VMからやり直す場合）
incus stop k8s-master k8s-worker1 k8s-worker2 && incus delete k8s-master k8s-worker1 k8s-worker2
sh scripts/vm.sh && newgrp incus-admin && sh scripts/k8s.sh
```

## アーキテクチャ

### GitOps構成 (App of Apps パターン)

```
manifests/apps/root.yaml     # ルートApplication（platform/appsを管理）
    ├── platform Application # manifests/platform/*.yaml を監視
    └── apps Application     # manifests/apps/*.yaml を監視（root.yaml除く）
```

- `manifests/platform/`: Argo CD Applicationリソース（Helmチャートへの参照）
- `manifests/apps/`: 個別アプリのApplicationリソース
- `manifests/<app-name>/`: 各アプリのvaluesファイルやKustomization

### sync-wave によるデプロイ順序

| Wave | リソース |
|------|----------|
| -5 | cert-manager |
| -4 | External Secrets Operator |
| -3 | bitwarden-sdk-server |
| -2 | ClusterSecretStore |
| -1 | ExternalSecret |
| 1 | アプリケーション (valkey, rustfs, cloudflared等) |

### シークレット管理

External Secrets Operator + Bitwarden Secrets Manager を使用。
- `manifests/external-secrets/store/`: ClusterSecretStore設定
- `manifests/external-secrets/secrets/`: ExternalSecret定義（Bitwarden IDを参照）

## アプリケーション追加方法

1. `manifests/platform/` に Argo CD Application を作成（Helmチャートを参照）
2. `manifests/<app-name>/` に values.yaml を配置
3. git push → Argo CD が自動Sync

## 主要コンポーネント

- **CNI/Ingress**: Cilium + Hubble
- **GitOps**: Argo CD + argocd-image-updater
- **Secrets**: External Secrets Operator + Bitwarden
- **Monitoring**: Prometheus, Loki, Alloy, Grafana K8s Monitoring
- **Storage**: local-path-provisioner, Valkey, RustFS

## アクセス

```bash
# Argo CD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Kubernetes Dashboard
kubectl port-forward -n kubernetes-dashboard svc/kubernetes-dashboard-kong-proxy 8443:443
```

## 手動Sync

```bash
kubectl exec -n argocd deploy/argocd-server -- argocd app sync <app-name>
```
