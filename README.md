# MediaLite (メディアライト)

> 「写真も動画も、もっと軽く。」  
> iPhone内で完結する、Apple Liquid Glassデザイン準拠のメディア圧縮・動画形式変換アプリ。

---

## 📱 アプリ概要

MediaLiteは、すべてのメディア処理（写真圧縮、動画圧縮、形式変換）を端末ローカル環境のみで完結させるセキュアなiOSアプリケーションです。

- **完全オンデバイス処理**: 外部サーバーへのアップロード・外部通信はゼロ（0 Network Symbols）。
- **非破壊ポリシー**: 元ファイルは絶対に上書き・削除せず、PhotoKitを用いて写真ライブラリへ安全に追加保存。
- **Apple Liquid Glassデザイン**: 派手なグラデーションや過剰な装飾を排し、モノクローム基調＋システムTint、`.ultraThinMaterial`、連続角丸（Continuous Corner Radius）による奥行きと透明感を実現。
- **完全日本語対応**: システム言語（iOS設定）に連動する日本語UIローカライズ、および設定画面での言語切替に対応。
- **アクセシビリティ標準準拠**: Dynamic Type、VoiceOver、Reduce Motion、Reduce Transparency、Dark Modeに完全対応。

---

## 🚀 主な機能

### 1. 写真圧縮 (Image Compression)
- **対応形式**: JPEG / HEIC / PNG
- **品質プロファイル**:
  - `LOW`: 画質最優先（JPEG品質 約90%）
  - `MEDIUM`: バランス（JPEG品質 約75%）
  - `HIGH`: 容量削減優先（JPEG品質 約55%）
- **メモリ効率**: ImageIOストリーミングダウンサンプリングにより、ピークメモリを30MB以下に抑制。
- **メタデータ保持**: EXIF、TIFF、GPS座標、Orientation（回転）、色空間、透過アルファチャンネルを完全維持。
- **安全保持フォールバック**: 圧縮によってファイルサイズが増加する場合は、元ファイルデータを安全に保持・採用してユーザーの不利益を防止。
- **ExifHelper厳密分離**: 単一JPEGとステレオMPO（Multi-Picture Format）をMagic Bytesおよび画像数で高精度に識別。

### 2. 動画圧縮・形式変換 (Video Compression & Transcoding)
- **対応形式**: MOV / MP4 / HEVC (H.265) / H.264 (AVC)
- **3つの処理モード**:
  1. **容量縮小**: 解像度とビットレートを最適化してサイズを削減。
  2. **互換性向上**: 幅広い機器で再生可能な標準MP4 (H.264 / AAC) に変換。
  3. **圧縮＋H.264変換**: 容量を削減しながらH.264形式へ再エンコード。
- **HDR対応**: HDR動画（10-bit HLG/PQ, Rec. 2020）を検出し、適切なSDR（Rec. 709）トーンマッピングを適用。
- **インターリーブ多重化**: 映像・音声ストリームを協調してAVAssetWriterへ供給し、バッファ滞留やバックプレッシャーによるデッドロックを防止。
- **音声・アスペクト比維持**: AAC音声を確実に保持。無音動画（画面収録など）や音声のみ動画も安全にハンドリング。
- **非同期進捗＆キャンセル**: `AsyncStream` によるリアルタイム進捗通知と、キャンセル時の一時ファイル完全自動クリーンアップ。

### 3. 5画面ナビゲーション (Liquid Glass UI)
- **Home**: アプリ概要、各機能カード、累計削減容量バッジ、最近の処理履歴。
- **Compress**: 写真・動画の圧縮実行、品質プロファイル選択、削減率プレビュー。
- **Convert**: 動画形式変換（HEVC ↔ H.264）、処理モード選択。
- **History**: 処理日時、元容量・処理後容量、削減量、サムネイル、個別削除機能。
- **Settings**: デフォルト圧縮強度、動画出力設定、キャッシュ/一時ファイル削除、バージョン情報。

---

## 🛠 アーキテクチャ & ディレクトリ構成

MVVMアーキテクチャおよびSwift Concurrency（async/await, Actor）を採用しています。

```
MediaLite/
├── App/
│   ├── MediaLiteApp.swift        # Appエントリーポイント
│   └── ContentView.swift          # 標準TabView（5タブ）ナビゲーション
├── Models/
│   ├── CompressionQuality.swift   # LOW / MEDIUM / HIGH
│   ├── ConversionMode.swift       # 3つの動画変換モード
│   ├── MediaItem.swift            # 選択メディア情報
│   ├── ProcessingResult.swift     # 処理結果・削減率計算
│   ├── HistoryRecord.swift        # 履歴レコード
│   └── AppSettings.swift          # ユーザー設定（UserDefaults永続化）
├── Views/
│   ├── Home/HomeView.swift
│   ├── Compress/CompressView.swift
│   ├── Convert/ConvertView.swift
│   ├── History/HistoryView.swift
│   ├── Settings/SettingsView.swift
│   └── Components/
│       ├── LiquidGlassCard.swift  # Liquid Glassカードコンポーネント
│       ├── SavingsBadge.swift     # 削減率バッジ
│       └── StatMetricView.swift   # メトリクス表示
├── ViewModels/
│   ├── HomeViewModel.swift
│   ├── CompressViewModel.swift
│   ├── ConvertViewModel.swift
│   ├── HistoryViewModel.swift
│   └── SettingsViewModel.swift
├── Services/
│   ├── PhotoCompressorService.swift # ImageIOストリーミング圧縮
│   ├── VideoProcessorService.swift   # AVFoundation再エンコード/トーンマッピング
│   ├── PhotoLibraryService.swift     # PhotoKit追加専用保存
│   └── HistoryStorageService.swift   # スレッドセーフな履歴Actor永続化
├── Utilities/
│   ├── DesignSystem.swift         # Liquid Glassデザイントークン
│   ├── Formatters.swift           # ファイル容量・時間フォーマッター
│   ├── TempFileManager.swift     # 一時ファイル安全管理
│   └── ExifHelper.swift           # メタデータ抽出・注入
└── Resources/
    ├── Assets.xcassets            # アプリアイコン・カラートークン
    ├── Info.plist                 # 写真ライブラリ権限（Add-only）
    └── PrivacyInfo.xcprivacy      # Appleプライバシーマニフェスト
```

---

## 🧪 テスト体制 (全324テストケース・100% Pass)

リポジトリには合計324件の網羅的テストスイートが含まれており、全件パス（0 failures）を達成しています。

- **Tier 1 (Feature Coverage)**: 写真圧縮、動画変換、履歴永続化、設定保存、モデル計算。
- **Tier 2 (Boundary & Corner)**: ゼロバイト・極大ファイル、非同期キャンセル、競合耐性。
- **Tier 3 (Cross-Feature Combinations)**: 形式×品質×変換モードの全マトリクスペアワイズ検証。
- **Tier 4 (Real-World Scenarios)**: バケーション写真一括処理、SNS共有向けトランスコード、ストレージ解放。
- **Tier 5 (Adversarial Hardening)**: 66件のホワイトボックス敵対的ストレステスト（縮退解像度、極小フレーム、リエントランシー、ファイル肥大化通知）。
- **Synthetic Zero-Git-Bloat**: テスト用メディアは `SyntheticAssetGenerator` により実行時に動的合成され、Gitリポジトリの肥大化を防ぎます。

---

## 🏗 ビルド & 実行方法

### 1. macOS / Xcode でのビルド & テスト
```bash
# プロジェクトを開く
open MediaLite.xcodeproj

# またはスクリプトで最新シミュレータを自動検出してテストを実行
DEST=$(python3 scripts/detect_simulator.py)
xcodebuild -scheme MediaLite -destination "$DEST" test
```

### 2. Windows / Linux / Codespace 環境での開発
- Codespace / VSCode Remote Containers 環境で編集可能。
- `scripts/validate_ci.py` により、CI設定・スキーマの整合性を手元で即座に検証可能。
```bash
python3 scripts/validate_ci.py
```

### 3. GitHub Actions CI
`.github/workflows/ci.yml` が用意されており、プルリクエストやPush時に自動的に以下が実行されます：
- `macos-26` ランナー（Xcode 26.6）でのビルド
- SwiftLint 構文チェック
- プライバシースキャン（外部通信APIのゼロ検証、Add-Only宣言、マニフェスト）
- ユニットテスト＆E2Eテスト全324件実行
- テスト結果（`.xcresult`）の自動アップロード
- Release Archive（Unsigned Build Packaging）の自動生成とアップロード

Apple Developer証明書およびProvisioning ProfileをGitHub Secretsに登録することで、署名済み成果物（.ipa）の自動生成も可能です。
