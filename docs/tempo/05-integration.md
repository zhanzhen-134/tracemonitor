# 现有平台增量集成

本节是各组件集成的原理与约束说明；Tempo 专用的 Kafka / RustFS，以及现有 Prometheus、Grafana、ES 的逐条操作命令以 [04-installation.md](04-installation.md) 为准，由安装执行人执行，共享设施变更先取得审批。kubectl 操作使用当前 kubeconfig context，显式指定 namespace。

## Tempo 专用 Kafka（tempo-kafka）

Tempo 不使用业务现有的 Kafka，而是在 TEMPO_NAMESPACE 中部署专用的单节点 Kafka，清单在 `manifests/kafka/`：

- **形态**：`apache/kafka:4.3.1`，KRaft 模式（broker 与 controller 在同一进程），1 个 Pod，数据在 PVC `data-tempo-kafka-0`。`CLUSTER_ID` 固定写在清单中，与 PVC 中已格式化的数据对应，不要修改。
- **监听器**：`PLAINTEXT://:9092`（客户端）、`CONTROLLER://:9093`（仅本机）。advertised 地址是 `tempo-kafka-0.tempo-kafka-headless.<ns>.svc.cluster.local:9092`。Tempo 通过 Service `tempo-kafka:9092` 连接。
- **安全**：集群内明文、无认证。NetworkPolicy `tempo-kafka` 只允许 Tempo Pod（`app.kubernetes.io/name=tempo`）和初始化 Job（`tempo-kafka-setup`）访问 9092；Tempo 的 NetworkPolicy 只放行到 `tempo-kafka` 的 9092 出口。
- **broker 默认值**：`num.partitions=3`、副本数 1、`message.max.bytes=16000000`、`log.retention.hours=24`、`log.retention.bytes=28000000000`（每分区），关闭自动创建 Topic。
- **Topic**：由 Job `tempo-kafka-create-topic` 创建 `tempo-traces`，3 分区、1 副本、`min.insync.replicas=1`、`cleanup.policy=delete`、保留 24 小时、每分区最多 28GB、`max.message.bytes=16000000`。Job 使用 `--if-not-exists`，可以重复执行。

查看状态（在 Tempo 自己的 Kafka Pod 内执行，不涉及业务）：

```bash
kubectl -n "$TEMPO_NAMESPACE" exec tempo-kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic tempo-traces
kubectl -n "$TEMPO_NAMESPACE" exec tempo-kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list
kubectl -n "$TEMPO_NAMESPACE" exec tempo-kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group metrics-generator
```

消费组为 `block-builder`、`metrics-generator`、`tempo-live-store`（双可用区模式为 `tempo-live-store-zone-a`、`tempo-live-store-zone-b`）。Block Builder 是静态分配，不能只看 consumer-group 成员数判断是否正常，要同时看 Tempo 的 partition lag、offset 和对象落盘。

**单节点的限制**：Kafka Pod 重启或节点故障期间 Tempo 无法写入，otel-gateway 最多重试 5 分钟。需要高可用时，可以把 StatefulSet 扩为 3 个 KRaft 节点（需同时修改 `KAFKA_NODE_ID`、`KAFKA_CONTROLLER_QUORUM_VOTERS` 和各副本数配置），或改用 Strimzi，这些属于单独的变更。

## Tempo 专用 RustFS（tempo-rustfs）

Tempo 不使用业务现有的 MinIO，而是部署专用的 RustFS（兼容 S3 的对象存储），清单在 `manifests/rustfs/`：

- **形态**：`rustfs/rustfs:1.0.0`，单节点单盘，1 个 Pod，数据在 PVC `data-tempo-rustfs-0`。Service `tempo-rustfs` 提供 9000（S3 API）和 9001（控制台）。
- **认证**：root 密钥来自 Secret `tempo-credentials` 的 `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY`。Tempo 用同一对密钥访问，这个 RustFS 只给 Tempo 使用。
- **安全**：集群内 HTTP。NetworkPolicy `tempo-rustfs` 只允许 Tempo Pod 和初始化 Job（`tempo-rustfs-setup`）访问 9000；控制台只能通过 `kubectl port-forward` 访问。
- **bucket**：由 Job `tempo-rustfs-create-bucket`（`amazon/aws-cli:2.37.4`）创建 `tempo-traces`，然后用 Tempo 的密钥写入、读取、删除一个测试对象。Job 可以重复执行。
- **Tempo 配置**：`storage.trace.s3.endpoint=tempo-rustfs.<ns>.svc.cluster.local:9000`、`insecure: true`、`forcepathstyle: true`。

Block Builder 把 Parquet block 写入对象存储，Querier 按 block 元数据读取，Scheduler 调度 Worker 执行 compaction 和 retention。values 中设为保留 720h，由 Tempo 管理过期删除，不要在 RustFS 上另设会提前删除对象的生命周期规则，也不要开启版本控制（否则已删除对象仍会占空间）。

**单节点的限制**：RustFS 不可用期间 Block Builder 无法落盘、历史查询失败，数据暂存在 Kafka 中，恢复后追平；停机时间不能超过 Kafka 的保留时间。RustFS 的 PVC 是历史 trace 的唯一副本，需要按企业要求做卷快照或备份。
## Prometheus 与告警

先导出现有 Helm values 和 Prometheus CR，不在本项目创建新 Prometheus：

```bash
helm -n "$MONITORING_NAMESPACE" get values "$PROMETHEUS_RELEASE" -o yaml > build/prometheus-before.yaml
kubectl -n "$MONITORING_NAMESPACE" get prometheus -o yaml > build/prometheus-cr-before.yaml
kubectl -n "$MONITORING_NAMESPACE" explain prometheus.spec.enableRemoteWriteReceiver
```

检查当前 `/api/v1/status/flags` 的 `web.enable-remote-write-receiver`；为 false 时先从当前固定 kube-prometheus-stack 版本 `helm show values` 确認 `prometheus.prometheusSpec.enableRemoteWriteReceiver`。审批后用**相同 Chart 版本**、保存的现有 user values、`integrations/prometheus/values-remote-write.yaml` 执行 helm template/diff，再 helm upgrade。不能只给增量文件导致现有值回到默认。GitOps 管理时在原仓库修改，不在集群制造漂移。

Prometheus 的 serviceMonitorSelector/ruleSelector 必须匹配 release 标签，namespaceSelector 必须包含 tracing namespace。记录变更前后 selector；如跨 namespace 使用 Secret，遵循当前 Operator Secret 作用域规则。Remote Write 若要求 Basic/OAuth/TLS，先在 metricsGenerator.config.storage.remote_write 项增加对应认证和 CA 配置，Secret 文件挂载到 generator 后再开流量，不在 URL 填密码。

查询 `traces_spanmetrics_calls_total`、`traces_spanmetrics_latency_bucket`、`traces_service_graph_request_total`；无数据时检查 processors、实际流量、Remote Write 4xx/5xx、时钟偏差与拒收旧样本。host-info 默认不启用，只有需要主机关联且资源字段齐全时再评估，防止扩大基数。
Exemplar 需要 Prometheus 版本支持并启用 exemplar storage、generator 发送以及 Grafana 指标源配置 exemplar trace link；缺一就不能承诺 Metrics→Trace。

本仓库规则基于 Tempo v3.1.0 官方 mixin，已按 namespace 收窄。导入 `integrations/grafana/tempo-overview.json` 仪表板时选择现有 Prometheus。先在 /metrics 核验系列名、单位和 label，再验证规则不会因缺失系列静默失效。专用 Kafka / RustFS 目前没有部署 exporter，至少要对两个 PVC 的使用率和 `tempo-kafka-0`、`tempo-rustfs-0` 的就绪状态配置告警（kube-prometheus-stack 自带的 kubelet volume 与 kube-state-metrics 指标即可覆盖）。阈值 5m、80% 仅起点，结合 SLO/压测修改。

## Grafana 与 ELK

UI：Connections → Data sources → Add Tempo；URL 为 Query Frontend:3200；Save & Test。关联现有 Prometheus/Elasticsearch UID，选择 Service Map、Trace to metrics、Trace to logs 的自定义 Lucene 查询 `trace_id:"${__span.traceId}"`。Provisioning 使用 build/integrations/grafana/datasources.yaml，复制到现有 provisioning 挂载位置或通过原 GitOps 管理，之后调用 `POST /api/admin/provisioning/datasources/reload`（服务器管理员）或重启 Grafana 才会生效；kube-prometheus-stack 自带 Grafana 则建带 `grafana_datasource: "1"` 标签的 ConfigMap 由 sidecar 自动加载。具体命令见 04 第 10 步。它只新增 UID=tempo，不覆盖整个数据源列表；同名/UID 存在时先审查。配置中的 `$$` 是 Grafana provisioning 防止环境变量展开的转义，不能删掉。

保持原 Logstash/采集链路，JSON 解码后 `trace_id`/`span_id` 为小写十六进制 keyword，service.name 与 deployment.environment 为 keyword，@timestamp 为 date。`integrations/elk/mapping.json` 是用于合并现有 template 的 properties 增量；字段类型冲突需新索引 rollover/reindex 评审，不能在线改既有类型。

Elasticsearch→Tempo：在现有 ES 数据源 Data links 增加 Field=trace_id、内部链接数据源 Tempo、查询 `${__value.raw}`。支持 dataLinks provisioning 的现有 Grafana 可合并以下 jsonData 内容（不能创建第二个 ES 数据源替代原配置）：

```yaml
dataLinks:
  - field: trace_id
    datasourceUid: tempo
    url: '$${__value.raw}'
    urlDisplayLabel: View trace
```

若当前版本不支持该内部链接，保留复制 Trace ID 到 Tempo Explore 的可用流程并记录升级待办。日志中未保存 trace_id 或日志保留期短于 trace 保留期时，链接可能无结果，并非 Tempo 丢失。不要配置 Loki derivedFields 来替代 ES dataLinks。
