# kotarnetes

## プロジェクト概要

kotarnetes は物理3台の各ホスト上にIncus VMを1台ずつ作成し、そのVM内で Kubernetes クラスタを構築するホームラボ環境。Kubernetesやcontainerdなどの変更はVM内に閉じ込め、ノード間通信は物理ホストのTailscale subnet routingでVM subnet同士を接続する。

## セットアップコマンド

```bash
# 各物理ホストでVMを作成
sh scripts/vm.sh master
sh scripts/vm.sh worker1
sh scripts/vm.sh worker2

# 各物理ホストでVM subnetをTailscaleに広告（scripts/vm.shが表示する値を使う）
sudo tailscale set --advertise-routes=<VM_SUBNET> --snat-subnet-routes=false

# 各VM内にリポジトリを配置
sudo incus exec <VM_NAME> -- git clone https://github.com/yashikota/kotarnetes.git /root/kotarnetes

# master VMでKubernetesを初期化
sudo incus exec k8s-master -- sh /root/kotarnetes/scripts/k8s.sh master

# worker VMで参加（masterが表示したjoinコマンドを渡す）
sudo incus exec k8s-worker1 -- sh /root/kotarnetes/scripts/k8s.sh worker 'kubeadm join <VM_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:...'
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


## 手動Sync

```bash
kubectl exec -n argocd deploy/argocd-server -- argocd app sync <app-name>
```
