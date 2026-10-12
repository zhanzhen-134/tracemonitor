# 前置条件、参数与兼容性

以下现网信息尚未提供，不能视为已验证。将非敏感值填写到 `environment.local.json`，该文件及 `build/` 已被 Git 忽略。

| 参数/信息 | 约束与确认方法 |
|---|---|
| 当前 kubeconfig、TEMPO_NAMESPACE | 使用 kubectl/Helm 当前 context，无需设置 context 参数；namespace 显式指定，建议专用 namespace |
| K8s 版本、CNI、metrics-server | Chart 声明 >=1.25；仍需服务端 dry-run、NetworkPolicy 实际阻断测试和 HPA 指标测试 |
| STORAGE_CLASS | 支持 RWO、跨节点重挂载；跨区 PVC 不会自动变成异地副本；核验 reclaimPolicy/扩容 |
| ZONE_A / ZONE_B | 可选。都留空为单可用区模式（默认，节点不需要 zone 标签，live-store 3 个，不装 rollout-operator）；都填写时为双可用区模式，必须是真实且不同的 topology.kubernetes.io/zone 标签，由 `charts/tempo/values-multi-zone.yaml` 开启跨区复制 |
| Kafka / 对象存储 | 不使用业务现有的 Kafka / MinIO。Tempo 专用的单节点 Kafka（`apache/kafka:4.3.1`）和 RustFS（`rustfs/rustfs:1.0.0`）由本项目部署在 TEMPO_NAMESPACE；需要能拉取这两个镜像和 `amazon/aws-cli:2.37.4`，否则先同步到企业仓库 |
| KAFKA_STORAGE_SIZE / RUSTFS_STORAGE_SIZE | 两者的 PVC 大小，默认 100Gi / 500Gi。Kafka 保留 24h、每分区上限 28GB，PVC 不小于 100Gi；RustFS 按 30 天 trace 容量估算 |
| PROMETHEUS_REMOTE_WRITE_URL | 完整 http(s)://host:port/api/v1/write；kube-prometheus-stack 通常为 `http://<release>-kube-prometheus-prometheus.<ns>.svc.cluster.local:9090/api/v1/write`（不要用 headless 的 prometheus-operated）；确认 receiver 开启及认证要求，查找方法见 04 第 2.1 步 |
| PROMETHEUS_RELEASE | ServiceMonitor / PrometheusRule 标签必须匹配现有 selector，不能猜 release 名 |
| MONITORING_NAMESPACE、GRAFANA_NAMESPACE | 现有实例所在命名空间；本例网络策略按 namespace 放行 |
| Grafana/ES/Prometheus 版本与 UID | 记录准确版本；确认日志数据源支持关联、exemplar 能力和索引 time field。PROMETHEUS_UID / ELASTICSEARCH_UID 为 Grafana 现有数据源 UID（数据源编辑页 URL 最后一段，或 `GET /api/datasources`），Service Graph 依赖其正确，见 04 第 2.2 步 |
| DEMO_NAMESPACE / DEMO_IMAGE | 受控验收 namespace 与已推送的固定版本镜像；不自动部署示例。不使用示例时两项都填空字符串，render 跳过示例清单 |
| PROMETHEUS_RELEASE 取值 | 填 `helm list` 的 NAME 列（如 `kube-prometheus-stack`），不是 CHART 列（如 `kube-prometheus-stack-75.6.0`）；以 Prometheus CR 的 serviceMonitorSelector 中 release 标签值为准 |
| OpenTelemetry Operator | Java 业务自动注入用，固定 Chart 0.96.0 / Operator 0.135.0 / Java agent 1.33.6；集群已有 Operator 时先确认版本与所有权，不重复安装；内网需同步 operator 与 autoinstrumentation-java 镜像 |
| 已有 OTel Gateway | 如可复用，使用 GATEWAY_MODE=reuse；合并 traces pipeline，不替换其其他 pipeline |
| 证书/Secret | tempo-credentials（RustFS 访问密钥，RustFS 与 Tempo 共用）、otel-gateway-tls；CA/客户端证书生命周期和轮换负责人 |
| SLO/RPO/RTO/吞吐 | 明确写入成功率、近期查询可用性、长期查询延迟和故障恢复预算 |

现有 Prometheus 必须选择目标 namespace 中的 ServiceMonitor/PrometheusRule。namespaceSelector 选择的是对象所在 namespace，ServiceMonitor.spec.namespaceSelector 选择的是被监控 Service，两个不能混淆。

权限：Tempo 与 Collector 不需要 Kubernetes 读写权限，SA token 不挂载，不授予 ClusterRole。双可用区模式下的 rollout-operator 是例外，它需要工作负载及 webhook 权限；审阅 `build/tempo-rendered.yaml` 中的 Role/ClusterRole/Binding、CRD、Mutating/ValidatingWebhookConfiguration。已有兼容 rollout-operator 时，设置 `rollout_operator.enabled=false` 与 `liveStore.zoneAwareReplication.rolloutOperatorManagedExternally=true`，确认 CRD 和 webhook 覆盖当前 namespace。不能仅设开关就假定兼容。

环境中未安装 helm/kubectl 时，运维机安装审核过的固定版本。仓库本地验证使用 Helm 3.19.0、Python 3.10.12、PyYAML 6.0.3；示例应用镜像基于 `python:3.10.12-slim-bookworm`，`requirements.lock` 中的依赖均已确认提供 Python 3.10 的安装包。运行脚本要求 Bash、Python、kubectl、helm、curl；Windows 可用 Git Bash/WSL，离线渲染可直接用 PowerShell + Python。

## 官方版本与字段来源

- [Tempo 3.1.0 release](https://github.com/grafana/tempo/releases/tag/v3.1.0)：固定发行版。
- [Tempo 3.1 release notes](https://grafana.com/docs/tempo/latest/release-notes/v3-1/)：Kafka 摄取能力。
- [Chart 3.11.1 发布](https://github.com/grafana-community/helm-charts/releases/tag/tempo-distributed-3.11.1)：本地 tgz 为校验基准，values 从此包验证。
- [Tempo v3.1.0 配置源](https://github.com/grafana/tempo/blob/v3.1.0/docs/sources/tempo/configuration/_index.md)：structuredConfig 字段来源。
- [Tempo Operator v0.22.0](https://github.com/grafana/tempo-operator/releases/tag/v0.22.0)：Components 为 Tempo 2.10.8，故不用于本项目。
- [Kafka 配置](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/configure-kafka/)；[Partition ring](https://grafana.com/docs/tempo/latest/reference-tempo-architecture/partition-ring/)。
- [Collector v0.135.0](https://github.com/open-telemetry/opentelemetry-collector-contrib/releases/tag/v0.135.0)；[内部遥测](https://opentelemetry.io/docs/collector/internal-telemetry/)；[队列与韧性](https://opentelemetry.io/docs/collector/resiliency/)。
- [Prometheus Operator API](https://prometheus-operator.dev/docs/api-reference/api/)；[Prometheus receiver](https://prometheus.io/docs/prometheus/latest/querying/api/#remote-write-receiver)。
- [Grafana Trace to logs](https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/configure-trace-to-logs/)；[Elasticsearch 数据源](https://grafana.com/docs/grafana/latest/datasources/elasticsearch/configure/)。

latest 文档可能继续变化；升级必须重新对照固定 tag 源码与发布说明，不能将本次版本矩阵自动沿用。
