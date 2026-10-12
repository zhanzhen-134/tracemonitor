# Tempo 3.1 Kubernetes 部署交付

需求整体可行，修订结论见 [需求审查](docs/tempo/00-requirement-review.md)。本仓库提供部署配置及手册，尚未连接或修改生产集群。

- `charts/tempo/`：固定版本原始 Helm 包、生产 values、开发覆盖配置、版本与 SHA256。
- `manifests/tempo/`、`manifests/otel-gateway/`、`manifests/python-otel-demo/`：按项目组织的 Kubernetes 清单。
- `charts/otel-operator/`、`manifests/otel-instrumentation/`：OpenTelemetry Operator values 与 Java 自动注入 Instrumentation，用于现有 Java 业务免改代码接入。
- `scripts/tempo/`、`scripts/kafka/`：参数渲染、预检、安装、验收、回滚及外部 Topic 创建脚本。
- `integrations/`：现有 Grafana、Prometheus、ELK 的增量配置，不部署这些平台。
- `docs/tempo/`：架构、前置条件、容量、部署、集成、验收与运维。

先阅读 [前置条件](docs/tempo/02-prerequisites.md)，按 [安装手册](docs/tempo/04-installation.md) 实施；也可以运行交互式脚本 `bash scripts/tempo/interactive-install.sh`，它会按手册顺序执行到 Grafana 中能看到 Service Graph 为止。完全不使用脚本时，按 [纯手工安装手册](docs/tempo/04b-manual-installation.md) 操作，只需要 kubectl、helm 等标准命令。

```bash
# Python 3.10.12；Ubuntu 22.04 需先 apt-get install python3-pip python3-venv，详见安装手册第 1.1 步
python3 -m venv .venv && source .venv/bin/activate
python3 -m pip install -r scripts/tempo/requirements.txt
cp environment.example.json environment.local.json
# 填入非敏感环境参数；密码通过 Secret 提供
python3 scripts/tempo/render.py environment.local.json
export TEMPO_NAMESPACE='<与参数文件一致>'
bash scripts/tempo/preflight-check.sh
```

默认生产示例：3 个 Kafka 分区、2 个可用区、6 个 Live Store、3 个 Block Builder；资源与 30 天保留期均为待压测假设。应用到 Collector 使用 mTLS，Collector 到 Tempo 及 Tempo 内部 RPC 使用受 NetworkPolicy 限制的集群明文通道，需按安全基线评审；需要全链路加密时先配置已有 service mesh 或 Tempo RPC TLS 再上线。

生产包启用 rollout-operator，增加 CRD、RBAC 和 admission webhook；这是跨区滚动更新及驱逐保护所需的额外组件。复用现有实例时按前置条件调整，不能重复安装。Backend Scheduler 保持单实例并使用 PVC，不承诺所有组件无中断。

已做的本地检查及尚未执行的集群检查见 [验证报告](docs/tempo/10-verification-report.md)，现有平台变更见 [上线变更清单](docs/tempo/11-change-approval.md)。不要将 Helm 渲染成功视为生产验收通过。
