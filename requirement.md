# Tempo 3.x 分布式链路追踪平台部署文档编写需求

**文档版本：** V1.1  
**目标环境：** 生产 Kubernetes 集群  
**部署模式：** Tempo 3.x Microservices  
**首选部署工具：** Helm  
**任务性质：** 生成可执行的生产部署方案、配置文件及运维文档

---

## 1. AI 的角色与任务

你是一名熟悉 Kubernetes、OpenTelemetry、Grafana Tempo、Kafka、Prometheus Operator、MinIO 和 ELK 的高级 SRE 架构工程师。

请基于以下需求编写一套完整的 Grafana Tempo 3.x 生产环境部署文档，并生成可直接使用的部署配置。

输出不能只是架构介绍，必须包括：

- 详细部署步骤及执行顺序
- 所有新增组件的 Kubernetes 配置
- Helm values.yaml 或完整 Kubernetes Manifest
- 现有基础设施的对接配置
- 参数说明、环境变量及 Secret 管理
- 健康检查、故障排查、验收及回滚方案
- 生产安全、高可用、容量规划及扩缩容方案

最终结果应达到 SRE 工程师拿到文档后，只需要替换明确标识的环境参数，就可以按步骤实施的程度。

## 2. 建设目标

通过 OpenTelemetry Gateway 统一接收业务系统 Span，使用 Tempo 3.x 微服务架构对链路数据进行摄取、缓冲、查询和持久化。

需要实现以下功能：

1. 统一接收各类微服务的 OTLP Trace 数据。
2. Tempo 3.x 通过现有 Kafka 实现异步数据处理。
3. 使用现有 MinIO 作为 Tempo 的长期对象存储。
4. 使用现有 Prometheus 存储 Trace 派生指标。
5. 使用现有 Grafana 查询 Trace，并展示服务拓扑和指标。
6. 利用现有 ELK 中的日志，实现 Trace 与 Log 的关联查询。
7. 支持 Kubernetes 生产环境的高可用、弹性扩容、监控告警和故障恢复。
8. 支持未来扩展到多集群、多环境和多业务服务。

## 3. 基础环境与部署边界

生产环境已经存在：

- Kubernetes 集群
- MinIO 对象存储服务
- Kafka 集群
- Prometheus 及 Prometheus Operator / kube-prometheus-stack
- Elasticsearch、Logstash、Kibana
- Grafana

以上服务均不允许重新部署。

OpenTelemetry Gateway 是指定的 Span 接入层。如已存在可复用实例，应优先复用；如果不存在，则在 K8s 新增部署。

新增服务主要包括 Tempo 3.x 的微服务组件，以及确有必要的新建 OpenTelemetry Gateway。

必须避免：

- 重复安装 MinIO
- 重复安装 Kafka
- 重复安装 Prometheus
- 重复安装 Grafana
- 重复安装 Elasticsearch 或 Loki
- 使用旧版 Tempo 2.x 架构替代 Tempo 3.x
- 将开发测试环境使用的单体 Tempo 方案作为生产方案

任何涉及现有集群配置修改的操作必须独立列出、说明影响，并要求审批。

## 4. 版本与部署技术选型

### 4.1 版本要求

采用 Grafana Tempo 3.x 稳定正式版本。

优先检查 Tempo 3.1.x 或更新的稳定 3.x 版本是否满足现有 Kafka 认证、存储及 Helm Chart 兼容性要求。

所有镜像、Chart 和依赖必须固定具体版本，不允许生产配置直接使用 latest 标签。

### 4.2 Helm 方案

首选 `tempo-distributed` Helm Chart。

使用当前社区维护的 Grafana Community Chart 仓库，并确认当前 Chart 已支持 Tempo 3.x 的 Kafka 写入架构。

部署必须提供：

- Helm 仓库添加命令
- Helm Chart 版本检查
- values.yaml
- helm template 验证
- helm lint 验证
- helm upgrade --install
- helm status 检查
- Helm 升级及回滚命令

### 4.3 Tempo Operator 可行性验证

检查 Grafana 官方 Tempo Operator 的最新正式版本，确认是否支持 Tempo 3.x 微服务架构。

重点确认是否能够管理：

- Distributor
- Live Store
- Block Builder
- Backend Scheduler
- Backend Worker
- Querier
- Query Frontend
- Metrics Generator

特别注意，Tempo Operator v0.22.0 的发布说明使用 Tempo 2.10.8，不能未经验证就将其作为 Tempo 3.x 的部署工具。

如果 Operator 尚不支持完整的 Tempo 3.x 新架构，必须明确说明原因，采用 Helm 部署，不得降级 Tempo。

### 4.4 清单方式

可以额外提供 Kubernetes Manifest 或 Kustomize 方案。

清单必须适用于 Tempo 3.x，不能使用旧版 Ingester、Compactor 等已废弃的架构组件。

## 5. Tempo 3.x 微服务架构要求

审查补充（2026-10-10）：Backend Scheduler 按选定版本的官方约束运行单实例，不强制多副本。Live Store 高可用必须保障每个分区有跨故障域副本，不能用不同分区的多个 Pod 代替。若所选 Chart 的跨区协调依赖 rollout-operator，应独立列出其 CRD、RBAC 和 webhook 变更，并评审是否复用现有实例。

需要解释各组件的功能、部署方式、资源需求、依赖关系、端口及通信路径。

| 组件 | 功能要求 |
|---|---|
| Distributor | 接收来自 OTel Gateway 的 OTLP Span，校验并写入 Kafka |
| Kafka | 作为 Tempo 分布式模式的持久化写入缓冲 |
| Live Store | 从 Kafka 消费数据，为最近产生的 Trace 提供查询能力 |
| Block Builder | 消费 Kafka Span，生成持久化 Block 并写入 MinIO |
| Backend Scheduler | 负责后台维护任务调度 |
| Backend Worker | 执行 Compaction 等后台维护任务 |
| Querier | 查询 Live Store 中的数据以及 MinIO 中的历史 Block |
| Query Frontend | 接收 TraceQL 和 Trace ID 查询，拆分及聚合请求 |
| Metrics Generator | 从 Kafka 数据生成 Span Metrics、Service Graph 等指标 |
| Gateway（可选） | Tempo 入口路由、鉴权或多租户访问控制，区别于 OTel Gateway |

需提供完整架构图、组件间端口矩阵、依赖关系及数据流。

要求明确：Tempo 3.x 不再采用传统 Ingester + Compactor 作为核心组件的 2.x 架构，也不能配置已移除的 `local-blocks` Metrics Generator Processor。

## 6. OpenTelemetry Gateway 需求

### 6.1 接入协议

使用 OpenTelemetry Collector 的 Gateway 部署模式。

优先支持：

- OTLP/gRPC：4317
- OTLP/HTTP：4318

应用统一将 Trace 发送到 OTel Gateway，而不是直接访问 Tempo Distributor。

Gateway 再通过 OTLP exporter 将数据发送到 Tempo Distributor。

需要说明 OTel Gateway 和 Tempo Helm Chart 中可能存在的 Gateway 组件不是同一种服务。

### 6.2 Collector Pipeline

提供完整、经验证的 Collector 配置，包括：

- receivers
- processors
- exporters
- extensions
- service.pipelines

至少包含：

- otlp receiver
- memory_limiter processor
- batch processor
- otlp exporter
- retry 和发送队列配置
- health_check extension（如所用版本支持）

配置必须满足实际选用的 Collector 版本，不能引用不存在的 exporter 或 processor。

需说明发送队列的内存与持久化方式、流量积压限制，以及重启情况下可能出现的数据丢失风险。

### 6.3 生产能力

默认考虑 OTel Gateway 多副本部署。

需要提供：

- Deployment
- Service
- ServiceAccount
- ConfigMap
- Secret（如需要）
- HPA 或扩容策略
- PodDisruptionBudget
- NetworkPolicy
- ServiceMonitor
- 资源 Requests/Limits
- Readiness/Liveness/Startup Probes

同时说明 TLS、认证、批量发送、限流、背压处理及采样策略。

如涉及 Tail Sampling，需要解释同一 Trace 的 Span 如何路由到同一采样实例，不得假设普通多副本负载均衡天然满足这一要求。

### 6.4 应用埋点

提供一个 Python 微服务埋点示例，至少包含：

- OpenTelemetry SDK 安装
- OTLP Exporter 配置
- service.name、service.version、deployment.environment
- HTTP 服务及 HTTP 客户端自动埋点
- 跨微服务 Trace Context 传播
- 异常和错误 Span
- trace_id、span_id 注入结构化日志
- Kubernetes Deployment 的环境变量示例

还需说明跨 Kafka 异步消息传播 Trace Context 的方式。

应用埋点不应依赖业务代码直接操作 Tempo 或 MinIO。

## 7. Kafka 集成需求

### 7.1 数据路径

明确区分两种概念：

1. OTel Gateway → Tempo Distributor：OTLP Trace 接入。
2. Tempo Distributor → Kafka：Tempo 3.x 内部持久化摄取路径。

默认不要求 OTel Gateway 先向业务 Kafka Topic 写入 Span，再由 Tempo 消费。

### 7.2 Topic 要求

在现有 Kafka 集群创建独立的 Tempo 专用 Topic，例如：

`tempo-traces`

该 Topic 不得与已有业务事件 Topic 混用。

部署文档应提供：

- Topic 创建命令
- Partition 数量规划
- Replication Factor
- min.insync.replicas
- Retention
- cleanup.policy=delete
- max.message.bytes
- Kafka ACL
- Consumer Group 监控方式

生产默认建议参考 3 副本、最少 2 个 ISR 的可靠性配置，具体值须按现有 Kafka 集群能力确认。

Kafka Retention 建议以 24 小时作为评估起点，并根据故障恢复时间、积压处理能力和 Kafka 容量确定最终值。

消息最大大小要求必须与 Tempo 官方推荐配置一致。

### 7.3 Kafka 认证

必须支持现有集群的实际认证配置：

- PLAINTEXT（仅在获批的可信内部网络中）
- SASL/PLAIN
- SASL/SCRAM
- TLS/mTLS（按选定 Tempo 版本能力）

若现有 Kafka 强制使用 SCRAM + TLS，必须确认选定的 Tempo 3.x 版本支持该组合。

密码通过 Kubernetes Secret 注入，不允许硬编码。

提供 Bootstrap Server、CA、Topic、ACL、认证方式的配置示例。

### 7.4 分区与扩缩容

需详细说明 Kafka Partition、Live Store 和 Block Builder 之间的对应关系。

不得简单地认为 Kafka Topic Partition 数量必须始终等于全部 Tempo Pod 数量。

说明 Partition 激活、实例副本数、消费能力及安全缩容流程。

未经验证，不得直接为 Live Store / Block Builder StatefulSet 设置会自动缩容的通用 HPA。

## 8. MinIO 持久化需求

使用现有 MinIO 的 S3 兼容 API。

必须提供：

- MinIO Endpoint
- Bucket Name
- Access Key / Secret Key
- TLS 与 CA 配置
- S3 Path Style 支持
- Secret 注入方式
- 网络连通性验证
- Bucket 读写权限验证

为 Tempo 创建独立 Bucket，例如：

`tempo-traces`

不得与其他业务 Bucket 混用。

要求说明：

- Tempo Block 的持久化机制
- Block Builder 写入 MinIO 的流程
- Querier 读取 MinIO 的流程
- Backend Worker 的 Compaction 职责
- Trace 保留周期配置
- 过期数据清理机制
- Bucket 生命周期规则与 Tempo 保留策略的关系
- MinIO 故障及恢复处理
- MinIO 高可用与灾备要求

必须明确：MinIO 是长期 Trace 存储，Kafka 是短期可靠性缓冲，两者不能互相替代。

本地 PVC 应按各组件实际需求配置，不能将本地存储当作唯一的长期 Trace 存储。

## 9. Prometheus 集成需求

### 9.1 运行指标监控

使用现有 Prometheus Operator，新增 Tempo 和 OTel Gateway 的 ServiceMonitor。

必须提供：

- ServiceMonitor
- PrometheusRule
- Labels 和 Namespace Selector
- Prometheus 对 ServiceMonitor 的发现配置
- 告警规则
- Grafana 监控 Dashboard

不得新建第二套 Prometheus。

### 9.2 Metrics Generator

部署 Tempo Metrics Generator。

优先启用：

- span-metrics
- service-graphs

评估 host-info 的必要性。

Metrics Generator 通过 Prometheus Remote Write 协议将 Trace 派生指标发送到现有 Prometheus。

必须检查现有 Prometheus 是否启用了 Remote Write Receiver。

如果未启用，给出适用于现有 kube-prometheus-stack 的最小增量配置及审批要求，避免覆盖现有 Helm values。

如生产环境使用 Prometheus Operator，需验证对应的：

`prometheus.prometheusSpec.enableRemoteWriteReceiver`

是否适用于当前 Chart 版本。

Remote Write 接收地址通常为 Prometheus 对应 Service 的：

`/api/v1/write`

还需评估接收写入的性能、序列基数和容量影响。若现有 Prometheus 不适合承担该负载，应提出兼容存储替代方案供审批，但不能默认额外部署一套指标系统。

### 9.3 关联要求

实现：

- Trace → Metrics
- Metrics → Trace（在具备 Exemplar 或可用关联条件时）
- Service Graph
- RED Metrics：请求速率、错误率和耗时

提供 Grafana Explore 验证步骤。

## 10. Grafana 与 ELK 集成

### 10.1 Grafana

使用现有 Grafana 新增 Tempo Data Source。

提供 UI 配置方式与 Data Source Provisioning 配置示例。

Tempo 数据源查询地址应指向 Query Frontend 或实际启用的 Tempo 查询 Gateway。

不得直接把 Grafana 数据源指向 Distributor OTLP 接收端口。

需要配置：

- Trace ID 查询
- TraceQL 查询
- Service Graph
- Trace to Metrics
- Trace to Logs
- 适用时的 Exemplars 关联

### 10.2 ELK

继续保留原来的业务日志链路，不改变 Elasticsearch 的日志存储职责。

业务日志增加或规范：

- trace_id
- span_id
- service.name
- deployment.environment
- timestamp

提供 Elasticsearch 字段映射建议。

Grafana 通过现有 Elasticsearch Data Source 实现从 Trace 跳转到相关日志。

同时评估从 Elasticsearch 日志反向定位 Tempo Trace 的支持方式，并根据现有 Grafana 版本给出可执行配置。

不要求将 Tempo 的全部 Trace 存入 Elasticsearch。

不引入 Loki，除非有独立、充分论证并经过批准的需求。

## 11. 生产级非功能需求

### 11.1 高可用

根据实际吞吐和故障域提供：

- 主要组件多副本策略
- PodDisruptionBudget
- Pod Anti-Affinity
- Topology Spread Constraints
- 节点故障恢复
- 滚动升级
- 故障期间数据积压及恢复
- 查询链路与写入链路隔离

无足够资源时允许提供较小测试配置，但必须与正式生产配置分开。

### 11.2 安全

至少包含：

- Kubernetes RBAC 最小权限
- ServiceAccount
- NetworkPolicy
- MinIO 和 Kafka Secret
- TLS 证书管理
- API 鉴权
- 非 root 容器运行
- 容器镜像版本固定
- 敏感 Span 属性脱敏策略
- Secret 不进入 Git 明文仓库
- 必要时的单租户、多租户隔离

### 11.3 容量规划

提供容量估算方法和可修改参数表。

关键输入包含：

- 峰值 Spans/s
- 平均 Span 大小
- 峰值和平均入口 MB/s
- Trace 采样比例
- Kafka Retention
- MinIO Trace 保留天数
- 预计查询 QPS
- 峰值并发查询
- Metrics Generator 指标基数
- K8s Node CPU/Memory
- 可用区数量

必须分别估算 Kafka、MinIO、Tempo Pod 和 Prometheus 的容量。

资源规模未知时使用显式假设和示例，不得把示例数值当作已经确认的生产配置。

### 11.4 监控与告警

至少监控：

- OTel Gateway 接收、丢弃和导出 Span 数量
- OTel Gateway 队列使用率和导出失败
- Tempo Distributor Kafka 写入失败
- Kafka 生产和消费延迟
- Kafka Partition 可用性
- Live Store 就绪状态
- Block Builder 积压和错误
- MinIO 读写错误及延迟
- Query Frontend 延迟和失败率
- Metrics Generator Remote Write 失败
- Kubernetes Pod Restart / OOM
- Tempo 数据查询成功率

给出告警规则及建议阈值，并说明阈值需要通过压测校准。

## 12. 部署文档必须包含的实施流程

输出文档必须按实际部署顺序编写：

1. 收集现有环境信息和兼容性矩阵。
2. 检查 K8s 集群版本、权限、StorageClass、网络及 DNS。
3. 检查 Kafka、MinIO、Prometheus、Grafana 和 Elasticsearch。
4. 创建 Namespace、RBAC 与 Secret。
5. 申请并创建 MinIO Bucket 及访问账户。
6. 在 Kafka 创建 Tempo 专用 Topic 及 ACL。
7. 准备 Tempo Helm values 配置。
8. 验证并部署 Tempo 3.x 微服务。
9. 部署或对接 OpenTelemetry Gateway。
10. 验证 Span 摄取与 Kafka 消费。
11. 验证 Block Builder 到 MinIO 的持久化。
12. 配置 Prometheus ServiceMonitor 和告警。
13. 配置 Metrics Generator 与 Prometheus Remote Write。
14. 在现有 Grafana 注册 Tempo Data Source。
15. 配置 Elasticsearch 日志关联。
16. 部署 Python 测试服务或 Trace 生成任务。
17. 执行完整链路验收。
18. 执行生产压测、故障演练和交付。

每一步必须包含：操作目的、所用文件、执行命令、预期输出、失败排查方式。

## 13. 需要生成的文件

最终交付按用户补充要求组织：Kubernetes 清单放在 `manifests/<项目名称>/`，Helm 包及 values 放在 `charts/<项目名称>/`，脚本放在 `scripts/<项目名称>/`。文档按 `docs/tempo/` 组织，现有平台增量配置放在 `integrations/`。

```text
tracemonitor/
├── README.md
├── environment.example.json
├── docs/tempo/
│   ├── 00-requirement-review.md
│   ├── 01-architecture.md
│   ├── 02-prerequisites.md
│   ├── 03-capacity-planning.md
│   ├── 04-installation.md
│   ├── 05-integration.md
│   ├── 06-validation.md
│   ├── 07-troubleshooting.md
│   ├── 08-upgrade-rollback.md
│   ├── 09-operations-runbook.md
│   ├── 10-verification-report.md
│   └── 11-change-approval.md
├── charts/tempo/
│   ├── tempo-distributed-<固定版本>.tgz
│   ├── versions.json
│   ├── values-production.yaml
│   └── values-dev.yaml
├── manifests/
│   ├── tempo/
│   ├── otel-gateway/
│   └── python-otel-demo/
├── integrations/
│   ├── minio/
│   ├── prometheus/
│   ├── grafana/
│   └── elk/
├── examples/
│   └── python-otel-demo/
└── scripts/
    ├── tempo/
    ├── kafka/
    └── python-otel-demo/
```

如 Chart 自动生成相应 Kubernetes 对象，不应重复编写冲突的 Deployment、Service、StatefulSet。

文件必须完整，不允许只给片段后写“其他配置省略”。

所有环境相关值使用显式占位符，如：

- `<KAFKA_BOOTSTRAP>`
- `<MINIO_ENDPOINT>`
- `<MINIO_BUCKET>`
- `<PROMETHEUS_URL>`
- `<GRAFANA_URL>`
- `<TEMPO_NAMESPACE>`

实际凭据应在安装时通过安全机制提供，不得放入示例文件。

## 14. 验收标准

必须提供可复现的验收过程。

### 基础检查

- Helm Release 部署成功
- Tempo 3.x 所需组件运行正常
- 不存在作为旧架构残留的 Ingester
- Kafka 认证和 Topic 访问正常
- MinIO Bucket 读写正常
- OTel Gateway OTLP 接口可访问

### 端到端追踪

从 Python 测试服务产生一条跨服务 Trace。

验证：

业务服务 → OTel Gateway → Tempo Distributor → Kafka → Live Store / Block Builder → MinIO → Query Frontend → Grafana。

必须记录并查询具体 Trace ID。

不仅要验证近期 Trace，还要在数据完成长期持久化后，验证可以通过 MinIO 后端再次查询。

### 指标验收

- Prometheus 能发现 Tempo 与 Collector 运行指标
- Metrics Generator 正常运行
- Remote Write 接收成功
- Prometheus 能查询 Span Metrics
- Grafana 能展示 Service Graph

### 日志验收

- Elasticsearch 中存在可检索的 trace_id
- 能由 Grafana Trace 进入关联日志
- 如版本和数据源功能允许，实现由日志返回 Trace

### 故障验证

至少提供以下演练方案：

- 重启 OTel Gateway
- 重启 Tempo Distributor
- 重启 Block Builder
- 重启 Live Store
- 短暂模拟 MinIO 不可用
- 模拟 Kafka 消费积压
- 模拟 Metrics Generator 写入 Prometheus 失败

必须解释预期现象、恢复步骤，以及哪些场景可能发生数据丢失。

不能未经验证宣称所有故障下零数据丢失。

## 15. 升级与回滚要求

提供独立的运维手册，覆盖：

- Tempo 3.x 小版本升级
- Helm Chart 升级
- 配置修改与回滚
- Kubernetes Pod 滚动更新
- Kafka Partition 安全扩容、Tempo Partition 停用与消费者安全缩容；Kafka Topic 不能原地减少物理分区，确需减少时采用新 Topic 迁移方案
- MinIO 保留和清理策略变更
- OTel Gateway 版本升级
- 灾难恢复步骤

必须明确区分：

1. Helm 配置回滚
2. Tempo 组件版本回滚
3. 不兼容的跨大版本降级
4. 外部数据存储恢复

升级前要求备份 Kubernetes 配置、Helm values、Secret 引用与关键外部资源配置。

不允许依赖简单的 `helm rollback` 就假定能够恢复所有组件的数据格式及状态。

## 16. 职责分工

SRE 负责：

- K8s 部署
- Helm 版本管理
- 环境配置
- 生产发布
- 可观测性平台运维
- 容量规划与告警
- 故障处理

开发团队负责：

- 业务应用 OTel SDK 埋点
- Trace Context 传播
- 服务名及资源属性规范
- 业务 Span 定义
- 日志 Trace ID 注入
- 业务敏感数据保护

Kafka、MinIO、Prometheus、Grafana、ELK 的现有平台负责人负责审批并执行涉及共享基础设施的必要修改。

## 17. AI 输出质量要求

必须遵循以下要求：

1. 优先依据 Grafana、OpenTelemetry、Prometheus 官方文档和对应版本发布说明。
2. 首先核实版本兼容性，不允许混用 Tempo 2.x 与 3.x 配置。
3. 不能凭空编造 Helm Chart 的 values 字段。
4. 不能编造不存在的 OpenTelemetry Collector 组件。
5. 所有配置文件必须相互对应，Deployment 与 Service 端口必须一致。
6. 所有命令使用 kubectl/Helm 当前 kubeconfig context，无需显式传入 context；Namespace 必须明确指定。
7. 现有基础设施只能提供最小增量配置，不能整体替换其配置。
8. 明确每个数据类型的实际存储位置和持久化方式。
9. 区分测试配置和正式生产配置。
10. 不确定的环境参数必须列在待确认清单中，不得随意假设。
11. 提供官方参考 URL、版本信息和配置来源。
12. 对关键配置尽可能提供 Helm 渲染、Schema 校验及部署前验证方法。

最终交付必须包括可执行配置、部署文档、验收手册和生产运维手册。

**最终目标：建设一套复用现有 Kafka、MinIO、Prometheus、Grafana 和 ELK，使用 OpenTelemetry Gateway 接入 Span 的 Tempo 3.x Kubernetes 微服务链路追踪平台。**
