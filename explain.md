# 安装对现有业务、Kafka、MinIO 的影响说明

本文说明按 [安装手册](docs/tempo/04-installation.md) 或 [交互式脚本](scripts/tempo/interactive-install.sh) 安装时，对现有系统做了哪些改动、为什么要改、会有什么影响，以及如何回退。

结论：

- **业务代码、业务镜像、业务配置文件都不修改。**
- 对业务只做两处 Kubernetes 层面的改动：给业务 namespace 打一个标签，给选中的 Deployment 加注解。加注解会触发一次滚动重启，重启后 Pod 里多了一个 Java agent。
- Kafka 和 MinIO 上只**新增** Tempo 专用的资源（Topic、Bucket、账号、权限），不修改、不读取业务已有的 Topic 和 Bucket。唯一会影响全局的是一个可选的 Kafka broker 参数调整，执行前会单独确认。

---

## 1. 对现有业务的改动

### 1.1 改了什么

| 改动 | 具体内容 | 执行位置 |
|---|---|---|
| namespace 标签 | 给业务 namespace 加 `tracing-access=enabled` | 手册 11.3 / 脚本步骤 12 |
| Deployment 注解 | 在 Pod 模板上加 `instrumentation.opentelemetry.io/inject-java: "tracemonitoring/java"`；多容器的 Pod 还会加 `instrumentation.opentelemetry.io/container-names` | 手册 12.1 / 脚本步骤 12 |

只有你在脚本中**明确选中**的 Deployment 才会加注解；没选中的服务完全不受影响。

### 1.2 没有改什么

- 业务代码、镜像、启动命令、ConfigMap、Secret、Service、Ingress。
- 业务 namespace 中已有的 NetworkPolicy。手册只提示：如果业务侧有默认拒绝的出口策略，需要你自己补一条放行到 otel-gateway 4319 的规则。脚本只做检查和提示，不会修改。
- 业务日志格式。trace_id 写进日志（手册第 14.2 步）需要业务自己改日志 pattern，脚本不做。

### 1.3 这些改动的意义

- **namespace 标签**：otel-gateway 的 NetworkPolicy 只允许带这个标签的 namespace 发送 trace 数据，相当于一个接入白名单。这个标签对业务 Pod 本身**没有任何作用**。
- **Deployment 注解**：OpenTelemetry Operator 看到注解后，在 Pod **创建时**把 Java agent 注入进去，采集 HTTP 入口、对外 HTTP 调用、数据库、Redis、MQ 等调用，生成 trace，并发送到 otel-gateway。Service Graph 就是根据这些 trace 计算出来的。

### 1.4 注入后 Pod 里发生的变化

Operator 在 Pod 创建时自动做以下修改；Deployment 本身除了注解之外不变：

| 变化 | 说明 |
|---|---|
| 增加 init 容器 `opentelemetry-auto-instrumentation-java` | 启动时把 `javaagent.jar` 复制到一个 emptyDir 卷，然后退出 |
| 增加 emptyDir 卷与挂载 | 存放 agent jar |
| 环境变量 `JAVA_TOOL_OPTIONS` | 追加 `-javaagent:...`。业务原来设置的 `JAVA_TOOL_OPTIONS` 会保留，agent 参数追加在后面 |
| 环境变量 `OTEL_*` | 服务名、导出地址、采样率等。业务已经设置的同名变量不会被覆盖 |

### 1.5 对业务运行的影响

| 影响 | 程度 | 说明 |
|---|---|---|
| 滚动重启 | 一次 | 加注解后立即触发，和一次普通发布一样；应在业务允许的窗口执行 |
| 内存 | 每个 Pod 增加约 50～100MB | 内存 limit 比较紧的服务，可能需要先调高 limit |
| 启动时间 | 增加几秒到十几秒 | agent 在类加载时织入代码。启动探针时间设得很紧的服务需要放宽 |
| CPU / 延迟 | 一般增加几个百分点 | 采样率为 20%；未被采样的请求只做很轻的处理 |
| 下游 HTTP 请求 | 自动增加 `traceparent`、`tracestate`、`baggage` 请求头 | 用来把调用串成一条链路。对绝大多数服务没有影响；如果下游会拒绝未知请求头，需要提前确认 |
| 业务 Kafka 消息 | 生产者发出的消息会多出 `traceparent` 等 **record header** | 消息体不变。如果消费方严格校验 header，或者 broker 版本很老（低于 0.11，不支持 header），需要提前确认 |
| 网络 | 增加到 otel-gateway 4319 的集群内流量 | 只发送 trace 数据，不影响业务流量 |
| 与其他 agent 冲突 | 已使用 SkyWalking、Pinpoint 等 Java agent 的服务**不要注入** | 两个 agent 同时织入可能出现异常 |

**数据安全**：

- trace 中会包含 URL、SQL 等调用信息。gateway 会删除 `db.statement`、认证头、Cookie，以及 URL 中的查询参数，然后才写入 Tempo。
- 业务代码自己写入 span 的自定义属性不会被过滤。
- 业务 Pod 到 gateway 这一段是集群内明文传输，只有带标签的 namespace 能访问。

### 1.6 集群级影响：Operator 的准入 webhook

Operator 会注册一个**对全集群 Pod 创建都生效**的 mutating webhook：

- 只有带注入注解的 Pod 会被修改，其他 Pod 原样放行。
- 失败策略设为 `Ignore`：Operator 故障时，Pod 照常创建，只是不注入 agent，**不会阻塞任何发布**。
- 但如果 Operator 无响应（而不是直接拒绝连接），API Server 最多会等待 webhook 超时（10 秒）后才放行。这期间全集群新建 Pod 会变慢。所以要监控 Operator 的运行状态。

### 1.7 回退

| 范围 | 操作 | 影响 |
|---|---|---|
| 单个服务 | 删除注解（手册 13.3 有命令） | 再触发一次滚动重启，之后恢复为原样 |
| namespace | `kubectl label namespace <ns> tracing-access-` | 该 namespace 不能再发送 trace，对业务无影响 |
| 整体 | 先删除所有注解，再删除 Instrumentation，最后 `helm uninstall` Operator | 必须先删注解，否则以后重建 Pod 时可能残留引用 |

---

## 2. 对 Kafka 的操作

### 2.1 为什么 Tempo 需要 Kafka

Tempo 3.x 的写入路径是：

```text
otel-gateway → distributor → Kafka Topic → live-store（近期查询）
                                         → block-builder（写成文件存入 MinIO）
                                         → metrics-generator（计算 Service Graph 指标）
```

Kafka 在这里是 Tempo **内部的缓冲队列**：distributor 收到数据先写 Kafka 再确认，下游组件故障或重启时，可以从 Kafka 重放，不丢数据。它和业务 Topic 完全无关，不读取也不写入任何业务 Topic。

### 2.2 做了哪些操作

| 操作 | 内容 | 目的 |
|---|---|---|
| 新建 Topic `tempo-traces` | 3 分区、3 副本、`min.insync.replicas=2`、保留 24 小时、`cleanup.policy=delete`、单条消息上限 16MB（只对该 Topic 生效） | Tempo 专用的数据通道 |
| 新建用户 `tempo` | SCRAM-SHA-512，随机生成密码 | Tempo 使用独立账号，可以单独吊销 |
| ACL（Kafka 已开启授权时） | `tempo` 只能读写 `tempo-traces`，只能使用 4 个固定的消费组：`block-builder`、`metrics-generator`、`tempo-live-store-zone-a`、`tempo-live-store-zone-b` | 最小权限，**看不到任何业务 Topic** |
| （可选）broker 默认参数 | `message.max.bytes`、`replica.fetch.max.bytes` 调到 16000000 | 只在非 Strimzi 方式下、而且你确认后才执行，见 2.4 |

Strimzi 管理的 Kafka 通过 `KafkaTopic`、`KafkaUser` 资源创建，由 Strimzi 统一管理，不直接用命令行修改。

### 2.3 对 Kafka 的影响

| 方面 | 影响 |
|---|---|
| 磁盘 | 主要影响项。按 [容量算例](docs/tempo/03-capacity-planning.md)（平均 2MB/s 写入），24 小时 × 3 副本约需 **337GB**。实际值取决于业务流量和采样率，上线初期应观察 broker 磁盘使用 |
| 网络与 IO | 增加写入流量，以及 3 个消费组的读取流量和副本同步流量 |
| 分区数 | 增加 3 个分区 × 3 副本，对集群元数据的压力可以忽略 |
| 业务 Topic / 业务消费组 | **不受影响**：没有修改任何已有 Topic、ACL 或消费组 |
| broker 重启 | 脚本**不会**重启 broker |

### 2.4 需要特别注意的几种情况

以下情况会影响整个 Kafka，脚本不会自动执行，或者执行前单独确认：

1. **调整 broker 默认消息大小**（非 Strimzi，需要确认）：对所有 Topic 生效，允许更大的消息批次。不需要重启 broker。如果原来的值已经够大，选 N 跳过即可。
2. **Strimzi 没有 TLS + SCRAM 监听器**：脚本直接停止，提示你手工增加。增加监听器会**滚动重启所有 broker**。
3. **Kafka 原来没有开启授权**：脚本不会开启，只是不创建 ACL。如果你按手册手工开启 `simple` 授权，**没有配置 ACL 的现有业务客户端会被拒绝访问**，影响很大，必须先评估。

### 2.5 回退

- 删除 `tempo` 用户及其 ACL，删除 `tempo-traces` Topic。Strimzi 下删除对应的 `KafkaTopic` / `KafkaUser` 资源即可。
- 删除前先停止 Tempo，否则 Tempo 会报错。
- Topic 中的 trace 数据本来就只保留 24 小时，删除不影响已经写入 MinIO 的历史数据。

---

## 3. 对 MinIO 的操作

### 3.1 为什么 Tempo 需要 MinIO

Kafka 只保留 24 小时，live-store 只保存近期数据。block-builder 会把 trace 编码成 Parquet 文件写入对象存储，作为**长期存储**（保留 30 天）。查询 30 天内较早的 trace 时，querier 从 MinIO 读取。backend-worker 定期合并小文件，并删除过期的文件。

### 3.2 做了哪些操作

| 操作 | 内容 | 目的 |
|---|---|---|
| 新建 bucket `tempo-traces` | 独立 bucket | 与业务数据隔离 |
| 新建策略 `tempo-rw` | 只允许操作 `tempo-traces` 这一个 bucket（list / get / put / delete / 分片上传） | 最小权限 |
| 新建用户 `tempo` 并绑定策略 | 随机生成密钥 | Tempo 使用独立账号，可以单独吊销 |
| canary 测试 | 用 `tempo` 账号写入、读取并删除 `tempo-traces/_acceptance/probe.txt` | 在安装前确认账号权限正确 |
| 取 CA 证书 | 只读取 MinIO 的证书文件 | 让 Tempo 能校验 MinIO 的 TLS 证书 |

脚本在 MinIO Pod 内执行 `mc` 命令时，配置写在 Pod 的 `/tmp` 下，完成后删除。如果 MinIO 镜像里没有 `mc`，会临时创建一个 `tempo-mc` Pod，用完删除。

### 3.3 对 MinIO 的影响

| 方面 | 影响 |
|---|---|
| 容量 | 主要影响项。按容量算例，30 天约 **2TB** 逻辑数据；物理占用还要再乘以 MinIO 自身的纠删码或复制开销。实际值取决于流量和采样率 |
| 请求量 | block-builder 定期写入；backend-worker 合并和删除文件；querier 查询时读取。相比业务访问，属于持续、平稳的后台负载 |
| 业务 bucket | **不受影响**：`tempo` 账号的策略只覆盖 `tempo-traces`，没有修改任何已有 bucket、用户或策略 |
| MinIO 服务配置 | **不修改**：不改服务端配置，不重启 MinIO，不改证书 |
| root 账号 | 只读取，用于执行上面的管理命令，不修改，也不写入任何文件 |

注意事项：

- 如果 MinIO 中已经存在名为 `tempo` 的用户，`mc admin user add` 会**重置它的密钥**。执行前用 `mc admin user list` 确认没有重名用户。
- 如果 MinIO 开启了版本控制，Tempo 删除的过期文件会保留历史版本，继续占用空间，需要另外配置生命周期规则。

### 3.4 回退

删除 `tempo` 用户和 `tempo-rw` 策略，确认不再需要历史 trace 后删除 `tempo-traces` bucket。删除 bucket 会丢失 30 天内的历史 trace，但不影响任何业务数据。

---

## 4. 其他现有平台（简要）

| 平台 | 改动 | 影响 |
|---|---|---|
| Prometheus | 开启 Remote Write 接收（`enableRemoteWriteReceiver: true`） | helm upgrade 会重启 Prometheus，约 1～2 分钟无法抓取和查询；之后接收 Tempo 推送的 Service Graph 和 span 指标，增加时间序列数量 |
| Prometheus | 在 Tempo namespace 中新增 ServiceMonitor 和 PrometheusRule | 新增对 Tempo 组件的抓取和告警，不改已有规则 |
| Grafana | 新增 UID 为 `tempo` 的数据源（sidecar 方式会新增一个 ConfigMap） | 不修改已有数据源。sidecar 以 initContainer 方式运行时会重启一次 Grafana |
| Elasticsearch（手工第 14 步，脚本不做） | 新增 component template、ingest pipeline，并挂到业务日志的 index template 上 | 只对 rollover 之后的新索引生效；ingest 时多一次 grok 解析。操作前会先备份原 template，可以回退 |
