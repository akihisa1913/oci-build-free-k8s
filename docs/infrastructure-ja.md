# インフラストラクチャ説明書

Oracle Cloud Infrastructure (OCI) の Always Free Tier を使用して構築した、
本格的な Kubernetes 環境の構成と各コンポーネントの解説書です。

---

## 目次

1. [概要](#概要)
2. [全体アーキテクチャ](#全体アーキテクチャ)
3. [インフラストラクチャ層 (terraform/infra)](#インフラストラクチャ層)
4. [Kubernetes 設定層 (terraform/config)](#kubernetes-設定層)
5. [GitOps 管理コンポーネント (gitops/core)](#gitops-管理コンポーネント)
6. [ネットワーク構成](#ネットワーク構成)
7. [セキュリティ設計](#セキュリティ設計)
8. [監視・可観測性](#監視可観測性)
9. [ストレージ](#ストレージ)
10. [コスト構成](#コスト構成)
11. [ファイル構成](#ファイル構成)
12. [構築フロー](#構築フロー)

---

## 概要

| 項目 | 内容 |
|------|------|
| クラウドプロバイダー | Oracle Cloud Infrastructure (OCI) |
| Kubernetes ディストリビューション | Oracle Kubernetes Engine (OKE) |
| Kubernetes バージョン | 1.33.1 |
| アーキテクチャ | ARM64 (aarch64) |
| ワーカーノード数 | 2 |
| 月額費用 | **0円** (OCI Always Free Tier) |
| IaC ツール | Terraform >= 1.12 |
| CD ツール | FluxCD Operator |
| DNS プロバイダー | Cloudflare |
| TLS 証明書 | Let's Encrypt (DNS-01 チャレンジ) |

OCI の Always Free Tier は **4 oCPU / 24 GB メモリ** を Compute インスタンスに提供します。
この枠を2ノードに分割し、エンタープライズレベルの Kubernetes 環境を月額0円で実現しています。

---

## 全体アーキテクチャ

```
┌────────────────────────────────────────────────────────────┐
│                       インターネット                         │
│             Cloudflare DNS / Let's Encrypt TLS             │
└──────────────────────┬─────────────────────────────────────┘
                       │
         ┌─────────────┴─────────────┐
         │                           │
  ┌──────────────┐           ┌──────────────┐
  │ Layer 7 LB   │           │ Layer 4 NLB  │
  │ (10Mbps 無料) │           │ (無料)        │
  │ Envoy Gateway│           │ Teleport     │
  └──────┬───────┘           └──────┬───────┘
         │                          │
         └────────────┬─────────────┘
                      │
       ┌──────────────┴──────────────────┐
       │       OCI OKE クラスタ           │
       │      (Kubernetes 1.33.1)        │
       │                                 │
       │  ┌────────────────────────────┐ │
       │  │  Control Plane (OCI管理)   │ │
       │  └────────────────────────────┘ │
       │                                 │
       │  ┌─────────────┬──────────────┐ │
       │  │  Worker 1   │   Worker 2   │ │
       │  │ A1.Flex     │  A1.Flex     │ │
       │  │ 2 oCPU      │  2 oCPU      │ │
       │  │ 12 GB RAM   │  12 GB RAM   │ │
       │  │ 100 GB Boot │  100 GB Boot │ │
       │  │ ~60 GB LH   │  ~60 GB LH   │ │
       │  └─────────────┴──────────────┘ │
       │                                 │
       │  ┌──────────────────────────┐   │
       │  │     コアコンポーネント    │   │
       │  │  cert-manager            │   │
       │  │  external-dns            │   │
       │  │  dex (OIDC プロバイダー) │   │
       │  │  envoy-gateway           │   │
       │  │  external-secrets        │   │
       │  │  teleport                │   │
       │  │  fluxcd operator         │   │
       │  │  longhorn                │   │
       │  │  metrics-server          │   │
       │  └──────────────────────────┘   │
       │                                 │
       │  ┌──────────────────────────┐   │
       │  │   監視スタック            │   │
       │  │  kube-prometheus-stack   │   │
       │  │  grafana + dex OAuth     │   │
       │  │  lychee (リンク監視)     │   │
       │  └──────────────────────────┘   │
       │                                 │
       │  ┌──────────────────────────┐   │
       │  │     アプリケーション      │   │
       │  │  s3-proxy                │   │
       │  └──────────────────────────┘   │
       └─────────────────────────────────┘
                      │
       ┌──────────────┴──────────────────┐
       │     OCI Object Storage          │
       │  terraform-states バケット      │
       │  (バージョニング有効, 無料10GB) │
       └─────────────────────────────────┘
```

---

## インフラストラクチャ層

`terraform/infra/` で管理。K8s API エンドポイントまでの OCI リソースを構築します。

### Kubernetes クラスタ (OKE)

| 設定 | 値 |
|------|----|
| クラスタタイプ | Basic (無料) |
| Kubernetes バージョン | 1.33.1 |
| VCN CIDR | 10.0.0.0/16 |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/16 |
| Kubernetes Proxy CIDR | 10.96.0.1/32 |

### ノードプール

| 設定 | 値 |
|------|----|
| インスタンスシェイプ | VM.Standard.A1.Flex |
| アーキテクチャ | ARM64 (aarch64) |
| ノード数 | 2 |
| oCPU / ノード | 2 |
| メモリ / ノード | 12 GB |
| ブートボリューム | 100 GB |
| Longhorn 用ストレージ | ~60 GB |
| OS イメージ | Oracle Linux (OKE 最適化) |

> **注意**: Always Free Tier の ARM Compute 枠は 4 oCPU / 24 GB が上限です。
> 2ノード × (2 oCPU + 12 GB) でちょうど上限内に収まります。

### ネットワーク (VCN)

`networking.tf` で Oracle 公式 VCN Terraform Module (v3.6.0) を使用:

| サブネット | CIDR | 用途 |
|-----------|------|------|
| パブリック | 10.0.0.0/24 | ロードバランサー、NAT GW |
| プライベート | 10.0.1.0/24 | ワーカーノード |

**ゲートウェイ:**
- インターネットゲートウェイ: パブリックサブネット向け外部通信
- NAT ゲートウェイ: プライベートサブネットからの外部通信
- サービスゲートウェイ: OCI サービスへのプライベートアクセス

### Terraform 状態管理

Terraform の state は OCI Object Storage (S3 互換) に保存:

```hcl
backend "s3" {
  bucket = "terraform-states"
  # OCI Object Storage (S3 互換エンドポイント)
}
```

- バージョニング有効 (災害復旧対応)
- 無料枠 10 GB 以内で運用

---

## Kubernetes 設定層

`terraform/config/` で管理。K8s API に依存するリソースを構築します。

### FluxCD モジュール

FluxCD Operator を使った GitOps の基盤セットアップ:

| コンポーネント | 説明 |
|-------------|------|
| Flux Operator | FluxCD のライフサイクル管理 |
| Flux Instance | Git リポジトリとの同期設定 |

- 認証方式: GitHub App (PEM 鍵方式)
- 同期対象: `gitops/core/` パス
- 参照ブランチ: `main`
- Webhook 受信で即時同期

### Ingress モジュール

Envoy Gateway が使用するロードバランサー向けセキュリティグループを OCI に作成:

- HTTP (80) インバウンド許可
- HTTPS (443) インバウンド許可

### External Secrets モジュール

OCI Vault との連携に必要な IAM ポリシーを作成:

- Dynamic Group: ワーカーノードのグループ定義
- IAM Policy: Vault シークレットの読み取り権限

---

## GitOps 管理コンポーネント

FluxCD が `gitops/core/` を監視し、以下のコンポーネントを自動デプロイします。

### ネットワーキング / Ingress

#### Envoy Gateway (GatewayAPI 実装)

| 項目 | 値 |
|------|----|
| バージョン | 1.6.1 |
| 役割 | HTTP/HTTPS ルーティング (Layer 7) |
| ロードバランサー | OCI Flexible LB (10Mbps、無料) |
| 特徴 | SecurityPolicy で OIDC 保護が可能 |

HTTPRoute リソースを使ってトラフィックをサービスにルーティングします。
`SecurityPolicy` で特定の HTTPRoute を Dex 経由の OIDC 認証で保護できます。

### TLS / 証明書管理

#### Cert-manager

| 項目 | 値 |
|------|----|
| バージョン | v1.19.2 |
| チャレンジ方式 | DNS-01 (Cloudflare) |
| 証明書発行 | Let's Encrypt (無料) |

HTTP-01 チャレンジではなく DNS-01 を採用:
- ワイルドカード証明書 (`*.example.com`) が取得可能
- Cloudflare の API トークンで自動更新

### DNS 管理

#### External-DNS

| 項目 | 値 |
|------|----|
| バージョン | 1.20.0 |
| バックエンド | Cloudflare |
| 機能 | Service/Ingress/HTTPRoute から DNS レコードを自動生成 |

Kubernetes リソースのアノテーションを元に Cloudflare の DNS レコードを自動管理します。
CRD (`DNSEndpoint`) でカスタム DNS レコード (例: ホームネットワークの A レコード) も管理可能。

### 認証・アクセス管理

#### Dex (OIDC プロバイダー)

| 項目 | 値 |
|------|----|
| バージョン | 0.24.0 |
| 役割 | クラスタ内 OIDC IdP |
| Identity Provider | GitHub |

Dex は GitHub を IdP として OIDC トークンを発行します。
Grafana や Teleport がこの Dex を使って GitHub SSO ログインを実現します。

```
ユーザー → Dex → GitHub OAuth → Dex トークン発行 → 各サービス認証
```

#### Teleport (K8s クラスターアクセス)

| 項目 | 値 |
|------|----|
| バージョン | 18.6.3 |
| ロードバランサー | OCI NLB (Layer 4、無料) |
| SSO | GitHub (Dex 経由ではなく直接) |
| 機能 | セキュアな K8s API アクセス、監査ログ |

ローカルユーザーは廃止し、GitHub SSO のみを使用:

```bash
# ログイン
❯ tsh login --proxy teleport.example.com:443 --auth=github-acme --user <user>
❯ tsh kube login oci
❯ kubectl get pods
```

### シークレット管理

#### External Secrets Operator

| 項目 | 値 |
|------|----|
| バックエンド | OCI Vault |
| 認証 | IAM Instance Principal (ノードの IAM ロール) |

OCI Vault に保存したシークレットを Kubernetes Secret として自動同期します。

```
OCI Vault (シークレット保管)
    ↓ External Secrets Operator (自動同期)
Kubernetes Secret (Pod から参照)
```

### ストレージ

#### Longhorn (分散ブロックストレージ)

| 項目 | 値 |
|------|----|
| バージョン | 1.10.1 |
| レプリカ数 | 2 |
| 最小空き容量 | 10% |
| 総ストレージ容量 | ~120 GB (60 GB × 2ノード) |

各ノードのブートボリュームの余剰領域を使ってレプリカ付きの PersistentVolume を提供します。
2レプリカ構成により、1ノード障害時もデータが保護されます。

### GitOps / CD

#### FluxCD Operator

| 項目 | 値 |
|------|----|
| 管理方式 | FluxCD Operator (新方式) |
| 認証 | GitHub App (PEM 鍵) |
| Webhook | 有効 (コミット後即時同期) |
| Commit Status | GitHub にデプロイ状態を注釈 |

```
git push → GitHub → Webhook → FluxCD → K8s リソース同期
                                ↓
                    GitHub コミットに状態注釈 (✅/❌)
```

### 監視・可観測性

#### Kube Prometheus Stack

Prometheus + Alertmanager + Grafana の統合スタック:

| コンポーネント | 役割 |
|-------------|------|
| Prometheus | メトリクス収集・保存 |
| Alertmanager | アラート管理 |
| Node Exporter | ノードメトリクス |
| kube-state-metrics | K8s リソースメトリクス |

#### Grafana

| 項目 | 値 |
|------|----|
| バージョン | 10.5.5 |
| 認証 | Dex (GitHub SSO) |
| ダッシュボード | FluxCD 同期状態、クラスターリソース |

#### Metrics Server

軽量なリソース使用量モニタリング。`kubectl top` コマンドを有効化します。

#### Lychee (リンク監視)

Web サイトや外部リンクの死活監視。

### アプリケーション

#### S3 Proxy

OCI Object Storage バケットへの HTTP アクセスを提供するプロキシ。
外部からバケット内のファイルを HTTP 経由で参照可能にします。

---

## ネットワーク構成

### セキュリティリスト / セキュリティグループ

| レイヤー | ルール | 対象 |
|---------|-------|------|
| パブリック Ingress | TCP 6443 | K8s API サーバー (外部から) |
| パブリック Ingress | TCP 80, 443 | Envoy Gateway LB |
| パブリック Ingress | TCP 30000-32767 | NLB ノードポート (Teleport) |
| プライベート | VCN 内全通信 | ノード間通信 |
| プライベート Egress | 全て許可 | 外部通信 (NAT GW 経由) |

### ロードバランサー構成

| LB | 種別 | レイヤー | 用途 | 費用 |
|----|------|---------|------|------|
| OCI Flexible LB | Layer 7 | HTTP/HTTPS | Envoy Gateway | 無料 (10Mbps) |
| OCI NLB | Layer 4 | TCP | Teleport | 無料 |

---

## セキュリティ設計

### 多層防御

```
インターネット
    │
    ├── Cloudflare (DDoS 保護、DNS)
    │
    ├── OCI Security Group (ファイアウォール)
    │
    ├── Envoy Gateway (SecurityPolicy / OIDC 保護)
    │
    ├── Dex + GitHub SSO (認証)
    │
    ├── Teleport (K8s アクセス + 監査ログ)
    │
    ├── Kubernetes RBAC (認可)
    │
    └── OCI Vault + External Secrets (シークレット保護)
```

### TLS 戦略

- 全通信を HTTPS 化 (Let's Encrypt, DNS-01 チャレンジ)
- ワイルドカード証明書 (`*.example.com`) で統一管理
- Cert-manager が自動更新

### シークレット管理戦略

- アプリのシークレットは OCI Vault に保存
- K8s マニフェストにシークレットは記載しない
- External Secrets Operator が定期的に同期

---

## 監視・可観測性

| 項目 | ツール |
|------|-------|
| メトリクス | Prometheus |
| ダッシュボード | Grafana |
| アラート | Alertmanager |
| ノードリソース | Metrics Server |
| リンク死活監視 | Lychee |
| K8s 監査ログ | Teleport |

Grafana は Dex 経由の GitHub SSO でログインし、
FluxCD の同期状態やクラスターのリソース使用量を確認できます。

---

## ストレージ

### Longhorn 詳細

| 項目 | 値 |
|------|----|
| タイプ | 分散ブロックストレージ |
| レプリカ数 | 2 (ノード間冗長化) |
| ストレージクラス | `longhorn` (デフォルト) |
| 総容量 | ~120 GB |
| 最小空き容量閾値 | 10% |

各 PersistentVolumeClaim は 2 ノードにまたがってレプリケーションされます。
1 ノードがダウンしても、もう一方のノードからボリュームに引き続きアクセスできます。

### Terraform 状態ストレージ

| バケット | 用途 |
|---------|------|
| `terraform-states` | Terraform state ファイル保存 |
| バージョニング | 有効 (ロールバック対応) |

---

## コスト構成

### 月額費用: **0円**

| リソース | 無料枠内? | 備考 |
|---------|---------|------|
| OKE (K8s Control Plane) | ✅ | 無料 |
| VM.Standard.A1.Flex × 2 | ✅ | 4 oCPU / 24 GB 枠内 |
| Boot Volume 200 GB (2 × 100) | ✅ | 200 GB 枠内 |
| Object Storage (terraform-states) | ✅ | 10 GB 枠内 |
| Flexible LB (10 Mbps) | ✅ | 1基無料 |
| Network LB | ✅ | 無料 |
| Virtual Cloud Network | ✅ | 無料 |
| Cloudflare DNS | ✅ | 無料プラン |
| Let's Encrypt TLS | ✅ | 無料 |

![コスト実績](cost.25.png)

---

## ファイル構成

```
oci-free-cloud-k8s/
├── terraform/
│   ├── infra/                    # OCI リソース (クラスタ構築)
│   │   ├── _provider.tf          # OCI プロバイダー
│   │   ├── _terraform.tf         # S3 バックエンド設定
│   │   ├── _variables.tf         # 変数定義
│   │   ├── k8s.tf                # OKE クラスタ・ノードプール
│   │   ├── networking.tf         # VCN モジュール
│   │   ├── subnets.tf            # サブネット・セキュリティリスト
│   │   └── output.tf             # 出力 (kubeconfig 等)
│   │
│   └── config/                   # K8s 依存リソース
│       ├── main.tf               # モジュール呼び出し
│       ├── _providers.tf         # K8s・Helm プロバイダー
│       ├── _terraform.tf         # バックエンド設定
│       ├── _variables.tf         # 変数定義
│       └── modules/
│           ├── fluxcd/           # FluxCD Operator + Instance
│           ├── ingress/          # LB セキュリティグループ
│           ├── external-secrets/ # OCI Vault IAM 設定
│           └── grafana/          # Grafana 用 IAM 設定
│
├── gitops/
│   └── core/                     # FluxCD 管理 K8s マニフェスト
│       ├── kustomization.yaml    # エントリーポイント
│       ├── cert-manager/         # TLS 証明書管理
│       ├── dex/                  # OIDC プロバイダー
│       ├── envoy-gateway/        # GatewayAPI 実装
│       ├── external-dns/         # DNS 自動管理
│       ├── external-secrets/     # シークレット同期
│       ├── fluxcd-addons/        # FluxCD 追加設定
│       ├── grafana/              # ダッシュボード
│       ├── kube-prometheus-stack/ # 監視スタック
│       ├── longhorn/             # ブロックストレージ
│       ├── lychee/               # リンク監視
│       ├── metrics-server/       # リソース使用量
│       ├── s3-proxy/             # S3 HTTP プロキシ
│       └── teleport/             # K8s アクセス管理
│
├── docs/                         # ドキュメント・画像
├── README.md                     # セットアップガイド (英語)
├── DESIGN.md                     # 設計概要 (WIP)
├── .pre-commit-config.yaml       # コミット前チェック
└── renovate.json                 # 依存関係自動更新
```

---

## 構築フロー

### 初期セットアップ手順

```
Step 1: OCI アカウント作成 (Always Free Tier)
    ↓
Step 2: OCI CLI セットアップ
    oci setup config
    ↓
Step 3: Terraform State 用バケット作成
    oci os bucket create --name terraform-states --versioning Enabled
    ↓
Step 4: terraform/infra で OCI リソース構築 (~15分)
    terraform init && terraform apply
    → .kube.config 生成
    ↓
Step 5: terraform/config で K8s 設定
    terraform init && terraform apply
    → FluxCD Operator デプロイ
    ↓
Step 6: FluxCD が gitops/core を自動同期
    → 全コアコンポーネント自動デプロイ
    ↓
Step 7: Teleport 経由で K8s クラスターにアクセス
    tsh login → tsh kube login oci
```

### 継続運用 (自動化)

```
毎週月曜日 03:00 (ベルリン時間)
    Renovate が依存関係の更新を検出
    ↓
Pull Request 自動作成
    ↓
PR マージ → git push
    ↓
GitHub Webhook → FluxCD 即時同期
    ↓
新バージョンのコンポーネント自動デプロイ
    ↓
GitHub コミットに同期状態を注釈 (✅/❌)
```

### 開発ブランチへの切り替え

FluxCD の同期先ブランチを変更するには、クラスター内の `FluxInstance` リソースを編集:

```yaml
spec:
  sync:
    ref: refs/heads/feature-branch  # ← ブランチ名を変更
```

---

## 関連ドキュメント

- [セットアップガイド (英語)](../README.md)
- [設計概要](../DESIGN.md)
- [Terraform Infra](../terraform/infra/)
- [Terraform Config](../terraform/config/)
- [GitOps マニフェスト](../gitops/core/)
