# 现有平台增量集成

本节是各平台集成的原理与约束说明；集群内 Kafka/MinIO、Prometheus、Grafana、ES 的逐条操作命令以 [04-installation.md](04-installation.md) 为准，由安装执行人执行，共享设施变更先取得审批。Kafka/MinIO CLI 连接的是显式 endpoint，没有 Kubernetes namespace；kubectl 操作使用当前 kubeconfig context，显式指定 namespace。

## Kafka

使用与现有 Kafka 版本一致的 CLI。管理员的 `client.properties` 必须存于受限文件，包含 security.protocol=SASL_SSL、sasl.mechanism、JAAS 与 truststore 配置；不要将密码写入命令行或 Git。运行创建脚本前先填齐所有环境变量：

```bash
export KAFKA_BOOTSTRAP='<host:port>' KAFKA_TOPIC='tempo-traces' PARTITIONS=3
export KAFKA_ADMIN_CONFIG='<受限文件路径>' KAFKA_PRINCIPAL='User:tempo'
export CHANGE_APPROVAL_ID='<单号>' KAFKA_GROUP='<实际消费组>'
bash scripts/kafka/create-topic.sh
kafka-topics.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" --describe --topic "$KAFKA_TOPIC"
kafka-consumer-groups.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" --list
kafka-consumer-groups.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" --describe --group "$KAFKA_GROUP"
```

脚本遇到已有 Topic 会失败，避免悄悄接受不兼容配置。已建 Topic 仅在审阅 describe/configs 后复用，不盲目 --alter。可单独执行 `scripts/kafka/grant-acls.sh` 修复授权。固定版本源码核验的生产消费组为 `block-builder`、`metrics-generator`、`tempo-live-store-zone-a`、`tempo-live-store-zone-b`；Live Store 组名是 Pod 实例名去掉末尾 `-数字`。本脚本逐组授予 Read/Describe，不授予 `*` group 或业务 Topic 权限。更名或改 zone 时同步修改 ACL，开发单区组名为 `tempo-live-store`。Block Builder 静态分配，不能仅用 consumer-group 成员数判断是否正常；同时看 Tempo partition lag、offset 和对象落盘。

max.message.bytes=16000000 为最小值；同时核验 broker message.max.bytes 与 replica.fetch.max.bytes（及请求限制）能处理该大小，检查与调整命令见 04 第 5.3 步。现有共享 broker 参数改变应独立审批。Broker 使用 delete cleanup policy，RF=3、min ISR=2、禁止不安全 leader election；评审磁盘告警和恢复余量。24h retention 不能低于未落 S3 数据最长恢复时间。

认证变体：SASL PLAIN 与 SCRAM 只改机制；TLS/mTLS 在 `tempo.structuredConfig.ingest.kafka` 增加 tls_cert_path、tls_key_path 并将对应 Secret 文件挂载给所有 Kafka 客户端组件。TLS 不允许 skip verify。获批 PLAINTEXT 才能关闭 tls_enabled 并移除 CA；无 SASL 的场景使用 PLAIN 且用户名/密码同时为空，必须另建经过审核的覆盖文件，默认模板不降级认证。

## MinIO

管理员通过已有 `mc` alias（例如 `$MINIO_ALIAS`，本地配置受限）操作专用 bucket。先审查别名指向正确实例，不重建 MinIO。

```bash
mc mb "$MINIO_ALIAS/$MINIO_BUCKET"
mc stat "$MINIO_ALIAS/$MINIO_BUCKET"
printf 'tempo access probe\n' > /tmp/tempo-probe.txt
mc cp /tmp/tempo-probe.txt "$MINIO_ALIAS/$MINIO_BUCKET/_acceptance/probe.txt"
mc cat "$MINIO_ALIAS/$MINIO_BUCKET/_acceptance/probe.txt"
mc rm "$MINIO_ALIAS/$MINIO_BUCKET/_acceptance/probe.txt"
```

上面 canary 必须另外用 **Tempo 账号** 重复执行，管理员成功不代表应用账号可用。最小 policy 见 `integrations/minio/policy.json`：只允许指定 bucket 的 List/GetLocation 与对象 Get/Put/Delete/Multipart 操作；不能授权其他 bucket。服务账号由平台密钥流程创建，访问密钥写入 tempo-credentials。证书检查可在获准诊断机执行 `openssl s_client -connect '<host:port>' -servername '<host>' -CAfile '<ca-file>'`，不要通过跳过证书校验解决问题。

Block Builder 构建 Parquet block 到对象存储；Querier 按 block 元数据读取；Scheduler 调度 Worker 执行 compaction/retention。values 设 720h。对象存储生命周期不要先于 Tempo 删除活跃块或元数据；优先由 Tempo 管理逻辑保留。若 bucket 开启版本控制，已删除对象的非当前版本仍可能占空间，单独评审生命周期与备份保留，防止把灾备版本一并清除。MinIO HA/跨站复制、凭据备份和实际恢复演练归现有平台负责。

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

本仓库规则基于 Tempo v3.1.0 官方 mixin，已按 namespace 收窄。导入 `integrations/grafana/tempo-overview.json` 仪表板时选择现有 Prometheus。先在 /metrics 核验系列名、单位和 label，再验证规则不会因缺失系列静默失效。Kafka ISR/磁盘和 MinIO 节点健康使用平台现有 exporter/告警，不另装栈。阈值 5m、80% 仅起点，结合 SLO/压测修改。

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
