# OCI Free Tier Kubernetes クラスター

Oracle Cloud の [Always Free Tier][oci-free-tier] を利用して、**月額コスト 0 円** で Kubernetes クラスターを構築します。

[oci-free-tier]: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm


---

## 設計概要

### クラスター構成

```mermaid
graph TB
    Internet(("Internet"))

    subgraph OCI["Oracle Cloud — Always Free"]
        subgraph VCN["VCN  10.0.0.0/16"]
            subgraph Public["Public Subnet  10.0.0.0/24"]
                LB7["Layer 7 LB Flexible 10Mbps envoy-gateway"]
                LB4["Layer 4 NLB Teleport"]
            end
            subgraph Private["Private Subnet  10.0.1.0/24"]
                subgraph OKE["OKE Cluster  k8s v1.35.1"]
                    N1["Node 01 VM.Standard.A1.Flex 2 vCPU / 12 GB RAM / 100 GB"]
                    N2["Node 02 VM.Standard.A1.Flex 2 vCPU / 12 GB RAM / 100 GB"]
                end
            end
        end
        OS[("Object Storage Terraform state")]
        Vault[("OCI Vault Secrets")]
    end

    Internet --> LB7
    Internet --> LB4
    LB7 --> N1 & N2
    LB4 --> N1 & N2
```

| リソース | スペック | 無料枠 |
|----------|----------|--------|
| OKE コントロールプレーン | マネージド | 無料 |
| Worker Node x2 | VM.Standard.A1.Flex (2 vCPU / 12GB) | 無料 |
| Boot Volume x2 | 100GB 各 | 無料 |
| Layer 7 LB | Flexible (10Mbps) | 無料 |
| Layer 4 NLB | Network LB | 無料 |
| Object Storage | Terraform state 保存用 | 無料 |

### コンポーネント構成

```mermaid
graph TD
    TF["Terraform terraform apply"]

    subgraph argocd_ns["namespace: argocd"]
        ARGO["ArgoCD"]
        HELMSET["ApplicationSet core-helm-apps"]
        GITONLYSET["ApplicationSet core-gitonly-apps"]
    end

    TF -->|"helm install"| ARGO
    TF -->|"kubectl apply"| HELMSET & GITONLYSET
    ARGO -->|"管理"| HELMSET & GITONLYSET

    subgraph apps["ApplicationSet — gitops/core/apps/"]
        direction LR
        ES["external-secrets OCI Vault 連携"]
        CM["cert-manager Let's Encrypt DNS01"]
        EG["envoy-gateway GatewayAPI"]
        ED["external-dns Cloudflare"]
        DEX["dex OIDC (GitHub)"]
        KPS["kube-prometheus-stack 監視基盤"]
        GF["grafana ダッシュボード"]
        LH["longhorn 分散ストレージ"]
        TP["teleport k8s アクセス管理"]
        MS["metrics-server リソースメトリクス"]
        S3["s3-proxy Object Storage GW"]
        LY["lychee カスタムアプリ"]
    end

    HELMSET -->|"生成"| ES & CM & EG & ED & DEX
    HELMSET -->|"生成"| KPS & GF & LH & TP & MS & S3
    GITONLYSET -->|"生成"| LY
```

### Terraform 構成

```
terraform/
├── infra/          # OCI インフラ (VCN, OKE Cluster, Node Pool)
│                   # ← まずこちらを apply
└── config/         # Kubernetes 設定 (ArgoCD, External Secrets, etc.)
                    # ← infra の後に apply
```

### GitOps 構成 (ApplicationSet パターン)

```
gitops/core/
├── apps/                          # ApplicationSet generator 用パラメータファイル
│   ├── helm/                      # Helm+Git マルチソース アプリ (core-helm-apps が管理)
│   │   ├── cert-manager/config.yaml
│   │   ├── dex/config.yaml
│   │   ├── envoy-gateway/config.yaml
│   │   ├── external-dns/config.yaml
│   │   ├── external-secrets/config.yaml
│   │   ├── grafana/config.yaml
│   │   ├── kube-prometheus-stack/config.yaml
│   │   ├── longhorn/config.yaml
│   │   ├── metrics-server/config.yaml
│   │   ├── s3-proxy/config.yaml
│   │   └── teleport/config.yaml
│   └── gitonly/                   # Git のみ アプリ (core-gitonly-apps が管理)
│       ├── cert-manager-issuer/config.yaml
│       └── lychee/config.yaml
│
├── cert-manager/          # Namespace + ClusterIssuer 定義 + values.yaml
├── dex/                   # Namespace + HTTPRoute + Secret + values.yaml
├── envoy-gateway/         # Namespace + Gateway + EnvoyProxy + values.yaml
├── external-dns/          # Namespace + Secret + DNS records + values.yaml
├── external-secrets/      # Namespace + values.yaml
├── grafana/               # Namespace + HTTPRoute + Dashboards + values.yaml
├── kube-prometheus-stack/ # Namespace + HTTPRoute + SecurityPolicy + values.yaml
├── longhorn/              # Namespace + HTTPRoute + SecurityPolicy + values.yaml
├── lychee/                # Namespace + Deployment + Service
├── metrics-server/        # Namespace + values.yaml
├── s3-proxy/              # Namespace + HTTPRoute + Secret + values.yaml
└── teleport/              # Namespace + RBAC + values.yaml
```

Helm アプリは **multi-source** 形式で:
1. Helm chart レポジトリから Chart を取得 (`config.yaml` の `helmRepoURL` / `chart` / `chartVersion`)
2. このリポジトリの `gitops/core/<component>/` から追加マニフェストと `values.yaml` を取得

Git-only アプリはこのリポジトリの `gitops/core/<component>/` のみを参照します。

---

## 前提条件

### クライアント側ツール

```bash
# 必須
brew install terraform        # >= v1.12
brew install oci-cli          # OCI CLI

# 任意 (クラスターアクセス用)
brew install teleport         # tsh コマンド
brew install kubectl
```

### OCI セットアップ

```bash
# OCI CLI の初期設定
oci setup config
```

`~/.oci/config` に以下が設定されていること:

```ini
[DEFAULT]
user=ocid1.user.oc1..xxx
fingerprint=ee:f4:xx:xx
tenancy=ocid1.tenancy.oc1..xxx
region=eu-frankfurt-1
key_file=/Users/yourname/.oci/oci_api_key.pem

# Terraform OCI バックエンド用 (S3 互換)
[default]
aws_access_key_id = xxx      # OCI コンソール: ユーザー → 顧客シークレットキー
aws_secret_access_key = xxx
```

---

## デプロイ手順

### Step 1: OCI バックエンド用バケット作成

Terraform の state を保存する Object Storage バケットを作成します。

```bash
oci os bucket create \
  --name terraform-states \
  --versioning Enabled \
  --compartment-id <YOUR_COMPARTMENT_OCID>
```

### Step 2: Terraform バックエンドのネームスペース更新

OCI Object Storage のバックエンド設定にはテナンシーネームスペースが必要です。以下のコマンドで自分のネームスペースを確認し、ファイルを書き換えてください。

```bash
# テナンシーネームスペースを取得して変数に格納
NAMESPACE=$(oci os ns get --query 'data' --raw-output)

# 両ファイルのプレースホルダーを置き換え
sed -i '' "s/<YOUR_TENANCY_NAMESPACE>/$NAMESPACE/g" terraform/infra/_terraform.tf
sed -i '' "s/<YOUR_TENANCY_NAMESPACE>/$NAMESPACE/g" terraform/config/_terraform.tf
```

### Step 3: Git リポジトリの準備

このリポジトリを fork または clone して、GitHub に push します。

```bash
git clone https://github.com/YOUR_ORG/oci-build-free-k8s.git
cd oci-build-free-k8s
git push
```

> [!NOTE]
> Git リポジトリ URL の設定は不要です。ArgoCD ApplicationSet は Terraform の `git_url` 変数から直接 URL を参照するため、ファイルの書き換えは必要ありません。

### Step 4: シークレットの準備

各サービスで使用するシークレットを発行し、次の Step 5 で OCI Vault に登録します。取得方法は [付録: シークレット取得・発行手順](#付録-シークレット取得発行手順) を参照してください。

### Step 5: OCI Vault の準備

シークレット管理に **OCI Vault を1つ**作成し、その中に以下のシークレットを個別に登録します。

```
OCI Vault (1つ)
 ├── cloudflare-api-token
 ├── github-dex-client-id
 ├── github-dex-client-secret
 ├── dex-grafana-client
 ├── dex-s3-proxy-client-secret
 ├── dex-envoy-client-secret
 ├── slack-api-url
 ├── s3-proxy-user-access-key
 └── s3-proxy-user-secret-key
```

OCI コンソールで Vault を作成後、**Vault 詳細画面 → Secrets → Create Secret** から1つずつ登録してください。登録する値の取得方法は [付録: シークレット取得・発行手順](#付録-シークレット取得発行手順) を参照してください。

| OCI Vault シークレット名 | 値 | 用途 |
|---|---|---|
| `cloudflare-api-token` | Cloudflare API トークン文字列 | cert-manager / external-dns 共有 |
| `github-dex-client-id` | GitHub OAuth App の Client ID | Dex GitHub コネクタ |
| `github-dex-client-secret` | GitHub OAuth App の Client Secret | Dex GitHub コネクタ |
| `dex-grafana-client` | 任意のランダム文字列 (Client Secret) | Dex → Grafana OIDC |
| `dex-s3-proxy-client-secret` | 任意のランダム文字列 (Client Secret) | Dex → S3 Proxy OIDC |
| `dex-envoy-client-secret` | 任意のランダム文字列 (Client Secret) | Dex → Envoy / Prometheus OIDC |
| `slack-api-url` | Slack Incoming Webhook URL | Alertmanager 通知 |
| `s3-proxy-user-access-key` | OCI 顧客シークレットキーのアクセスキー | S3 Proxy → OCI Object Storage |
| `s3-proxy-user-secret-key` | OCI 顧客シークレットキーのシークレット | S3 Proxy → OCI Object Storage |

### Step 6: terraform/infra の適用

OKE クラスターと VCN を作成します。

```bash
cd terraform/infra

# 変数ファイルを作成
cat > terraform.tfvars <<EOF
compartment_id = "ocid1.compartment.oc1..xxx"
EOF

# 初期化と適用 (約 15〜20 分)
terraform init
terraform apply
```

適用後、カレントディレクトリに `.kube.config` が生成されます。

```bash
# クラスターへの接続確認
kubectl --kubeconfig ../.kube.config get nodes
```

### Step 7: terraform/config の適用

ArgoCD と Kubernetes 設定をデプロイします。

```bash
cd terraform/config

# 変数ファイルを作成 (infra の output 値を使用)
cat > terraform.tfvars <<EOF
compartment_id = "ocid1.compartment.oc1..xxx"
tenancy_id     = "ocid1.tenancy.oc1..xxx"
vault_id       = "ocid1.vault.oc1..xxx"
public_subnet_id = "$(cd ../infra && terraform output --raw public_subnet_id)"
node_pool_id     = "$(cd ../infra && terraform output --raw node_pool_id)"
git_url          = "https://github.com/YOUR_ORG/oci-build-free-k8s.git"
EOF

terraform init
terraform apply
```

> [!TIP]
> 初回 apply 時に `ClusterSecretStore` の作成が失敗する場合があります。
> これは `external-secrets` が ArgoCD によってデプロイされる前に Terraform が実行されるためです。
> ArgoCD が `external-secrets` を正常にデプロイした後に `terraform apply` を再実行してください。

### Step 8: ArgoCD へのアクセス確認

```bash
# ArgoCD の Pod 確認
kubectl --kubeconfig ../.kube.config -n argocd get pods

# ArgoCD UI へのポートフォワード
kubectl --kubeconfig ../.kube.config -n argocd port-forward svc/argocd-server 8080:80

# 初期管理者パスワードの取得
kubectl --kubeconfig ../.kube.config -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

ブラウザで http://localhost:8080 を開き、`admin` / 上記パスワードでログインします。

`core-helm-apps` / `core-gitonly-apps` ApplicationSet が Application を生成し始めると、配下の全コンポーネントが自動デプロイされます。

### Step 9: DNS と証明書の確認

```bash
kubectl --kubeconfig ../.kube.config get certificate -A
kubectl --kubeconfig ../.kube.config get clusterissuer
```

---

## 運用

### ArgoCD による GitOps フロー

```mermaid
flowchart LR
    Dev["開発者"]
    Git["GitHub (main ブランチ)"]
    ArgoCD["ArgoCD (ポーリング / Webhook)"]
    K8s["Kubernetes クラスター"]

    Dev -->|"git push"| Git
    Git -->|"差分検知"| ArgoCD
    ArgoCD -->|"自動同期 prune + selfHeal"| K8s
```

ArgoCD は定期的にリポジトリをポーリングし、差分があれば自動で適用します。

### ArgoCD CLI の使用

```bash
# ArgoCD CLI インストール
brew install argocd

# ログイン
argocd login localhost:8080 --username admin

# ApplicationSet 一覧
argocd appset list

# Application 一覧 (ApplicationSet が生成したものを含む)
argocd app list

# 特定 Application の状態確認
argocd app get cert-manager

# ApplicationSet が生成した Application を手動同期
argocd app sync cert-manager
```

### 開発ブランチへの切り替え

feature ブランチで作業する場合、Terraform の `git_revision` 変数を変更して `terraform apply` するか、両 ApplicationSet の `targetRevision` を直接パッチします:

```bash
# terraform.tfvars で変更する場合
# git_revision = "refs/heads/feature-branch" を追加して terraform apply

# kubectl で直接変更する場合
for appset in core-helm-apps core-gitonly-apps; do
  kubectl --kubeconfig ../.kube.config -n argocd patch applicationset $appset \
    --type='json' \
    -p='[{"op":"replace","path":"/spec/generators/0/git/revision","value":"refs/heads/feature-branch"}]'
done
```

### Teleport によるクラスターアクセス

Teleport が正常にデプロイされた後:

```bash
# GitHub SSO でログイン
tsh login --proxy teleport.nce.wtf:443 --auth=github-acme --user YOUR_GITHUB_USER teleport.nce.wtf

# k8s クラスターにログイン
tsh kube login oci

# 動作確認
kubectl get pods -n teleport
```

---

## Kubernetes バージョンアップグレード

> [!IMPORTANT]
> アップグレードは必ず 1 マイナーバージョンずつ段階的に行ってください。
> [K8s Skew Policy][k8s-skew] により、Worker ノードはコントロールプレーンより最大 3 バージョン古い状態が許容されます。

[k8s-skew]: https://kubernetes.io/releases/version-skew-policy/#kubelet

```bash
cd terraform/infra

# 利用可能なアップグレードバージョンを確認
oci ce cluster get \
  --cluster-id $(terraform output --raw k8s_cluster_id) \
  | jq -r '.data."available-kubernetes-upgrades"'

# _variables.tf のバージョンを更新
sed -i '' 's/default = "v1.35.1"/default = "v1.36.0"/' _variables.tf

# コントロールプレーンとノードプールをアップグレード (約 10 分)
terraform apply
```

**Worker ノードのローリングアップグレード:**

```bash
# ノード一覧を確認
kubectl get nodes

# 1台目をドレイン
kubectl drain <node-name> --force --ignore-daemonsets --delete-emptydir-data
kubectl cordon <node-name>

# OCI コンソールまたは CLI でインスタンスを終了
# (ノードプールが自動的に新しいノードを起動します)
oci compute instance terminate --force --instance-id <instance-ocid>

# 新ノードが Ready になるまで待機
kubectl get nodes -w

# Longhorn のボリュームが全て Healthy になるまで待機
kubectl get volumes.longhorn.io -A -w

# 2台目も同様に繰り返す
```

---

## コスト

Always Free Tier を正しく使用した場合の月額コスト: **¥0**

![コスト概要](docs/cost.25.png)

---

## 参考ドキュメント

### OCI / OKE
- [OCI Load Balancer Annotations][lb-annotations]
- [OKE Kubernetes バージョン一覧][oke-versions]

### Ingress / Gateway API
- [GatewayAPI 公式][gatewayapi]
- [Envoy Gateway][envoy-gateway]

### 証明書
- [cert-manager DNS01 チャレンジ][cert-manager-dns-challenge]

### シークレット管理
- [External Secrets Advanced Templating][secrets-templating]

### DNS
- [External DNS CRD][dns-crds]

### ArgoCD
- [ArgoCD 公式ドキュメント][argocd-docs]
- [ApplicationSet][argocd-applicationset]
- [Multi-source Applications][argocd-multi-source]

### Teleport
- [Teleport Helm デプロイ][teleport-helm-doc]
- [GitHub SSO 設定][teleport-github-sso]
- [Teleport Operator][teleport-operator]

---

## 付録: シークレット取得・発行手順

### `cloudflare-api-token` — Cloudflare API トークン

cert-manager (DNS01 チャレンジ) と external-dns (A/CNAME レコード管理) が共有します。

1. Cloudflare ダッシュボード → **My Profile** → **API Tokens** → **Create Token**
2. **Create Custom Token** を選択し、以下の通り設定:

| 項目 | 値 |
|------|----|
| Token name | `oci-k8s-dns` (任意) |
| Permissions | `Zone - DNS - Edit` |
| Permissions | `Zone - Zone - Read` |
| Zone Resources | `Include - Specific zone - <your-domain>` |

> [!IMPORTANT]
> Zone Resources は **Specific zone** で対象ドメインのみに限定してください。
> `All zones` にするとアカウント上の全ドメインを操作できるトークンになります。

3. **Continue to summary** → **Create Token** → 表示されたトークン文字列を OCI Vault の `cloudflare-api-token` に登録

---

### `github-dex-client-id` / `github-dex-client-secret` — GitHub OAuth App

Dex が GitHub 認証に使用します。

1. GitHub → **Settings** → **Developer settings** → **OAuth Apps** → **New OAuth App**
2. 以下の通り設定:

| 項目 | 値 |
|------|----|
| Application name | `dex-oci-k8s` (任意) |
| Homepage URL | `https://login.<your-domain>` |
| Authorization callback URL | `https://login.<your-domain>/dex/callback` |

3. **Register application** → 表示された **Client ID** を `github-dex-client-id` に登録
4. **Generate a new client secret** → 表示された **Client Secret** を `github-dex-client-secret` に登録

---

### `dex-grafana-client` / `dex-s3-proxy-client-secret` / `dex-envoy-client-secret` — Dex OIDC クライアントシークレット

Dex の静的クライアント (Grafana / S3 Proxy / Envoy Gateway) 用のシークレットです。
任意のランダム文字列を生成して OCI Vault に登録してください。

```bash
# 各シークレットに異なる値を設定する
openssl rand -base64 32   # dex-grafana-client 用
openssl rand -base64 32   # dex-s3-proxy-client-secret 用
openssl rand -base64 32   # dex-envoy-client-secret 用
```

> [!NOTE]
> これらの値は Dex と各クライアントアプリで共有される任意の文字列です。
> Dex の設定 (`dex/values.yaml`) と ExternalSecret の両方が同じ OCI Vault シークレットを参照するため、一度設定した値は変更しないようにしてください。

---

### `slack-api-url` — Slack Incoming Webhook URL

Alertmanager の通知先として使用します。

1. Slack ワークスペース → **Settings & administration** → **Manage apps**
2. **Incoming WebHooks** → **Add to Slack**
3. 投稿先チャンネル (`#monitoring` 等) を選択 → **Add Incoming WebHooks integration**
4. 表示された **Webhook URL** (`https://hooks.slack.com/services/...`) を `slack-api-url` に登録

---

### `s3-proxy-user-access-key` / `s3-proxy-user-secret-key` — OCI 顧客シークレットキー

S3 Proxy が OCI Object Storage にアクセスするための S3 互換認証情報です。

1. OCI コンソール → 右上のユーザーアイコン → **My profile**
2. 左メニュー → **Customer secret keys** → **Generate secret key**
3. Name に `s3-proxy` (任意) を入力 → **Generate secret key**
4. 表示された **Secret** を `s3-proxy-user-secret-key` に登録 (この画面を閉じると再表示できません)
5. 生成されたキーの **Access Key** 列の値を `s3-proxy-user-access-key` に登録

> [!NOTE]
> これは [OCI バックエンド用の顧客シークレットキー](前述の `~/.oci/config` の設定) と同じ仕組みですが、用途が異なるため別のキーとして発行することを推奨します。

[lb-annotations]: https://github.com/oracle/oci-cloud-controller-manager/blob/master/docs/load-balancer-annotations.md
[oke-versions]: https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengaboutk8sversions.htm
[gatewayapi]: https://gateway-api.sigs.k8s.io/
[envoy-gateway]: https://gateway.envoyproxy.io/
[cert-manager-dns-challenge]: https://cert-manager.io/docs/configuration/acme/dns01/
[secrets-templating]: https://external-secrets.io/v0.15.0/guides/templating/#helm
[dns-crds]: https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/crd/#using-crd-source-to-manage-dns-records-in-different-dns-providers
[argocd-docs]: https://argo-cd.readthedocs.io/
[argocd-applicationset]: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
[argocd-multi-source]: https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/
[teleport-helm-doc]: https://goteleport.com/docs/admin-guides/deploy-a-cluster/helm-deployments/kubernetes-cluster/
[teleport-github-sso]: https://goteleport.com/docs/admin-guides/access-controls/sso/github-sso/
[teleport-operator]: https://goteleport.com/docs/admin-guides/infrastructure-as-code/teleport-operator/
