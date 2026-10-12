# 安装对现有业务与集群的影响说明

本文说明按 [安装手册](docs/tempo/04-installation.md)、[纯手工安装手册](docs/tempo/04b-manual-installation.md) 或 [交互式脚本](scripts/tempo/interactive-install.sh) 安装时，对现有系统做了哪些改动、为什么要改、会有什么影响，以及如何回退。第 5 节说明仓库中每个脚本具体做了什么。

结论：

- **业务代码、业务镜像、业务配置文件都不修改。**
- 对业务只做两处 Kubernetes 层面的改动：给业务 namespace 打一个标签，给选中的 Deployment 加注解。加注解会触发一次滚动重启，重启后 Pod 里多了一个 Java agent。
- **业务现有的 Kafka 和 MinIO 完全不使用、不修改。** Tempo 使用自己专用的单节点 Kafka 和 RustFS（对象存储），与 Tempo 一起部署在 `TEMPO_NAMESPACE` 中。对集群的影响只是多占用一些节点资源和两块 PVC。

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

## 2. Tempo 专用的 Kafka（tempo-kafka）

### 2.1 为什么 Tempo 需要 Kafka

Tempo 3.x 的写入路径是：

```text
otel-gateway → distributor → Kafka Topic → live-store（近期查询）
                                         → block-builder（写成文件存入 RustFS）
                                         → metrics-generator（计算 Service Graph 指标）
```

Kafka 在这里是 Tempo **内部的缓冲队列**：distributor 收到数据先写 Kafka 再确认，下游组件故障或重启时可以从 Kafka 重放，不丢数据。

### 2.2 部署了什么

| 资源 | 内容 |
|---|---|
| StatefulSet `tempo-kafka` | 1 个 Pod，镜像 `apache/kafka:4.3.1`，KRaft 单节点（不需要 ZooKeeper）；请求 0.5 核 / 2GB 内存，上限 2 核 / 3GB |
| PVC `data-tempo-kafka-0` | 大小为 `KAFKA_STORAGE_SIZE`（默认 100Gi） |
| Service `tempo-kafka`、`tempo-kafka-headless` | 只在集群内访问，端口 9092 |
| NetworkPolicy `tempo-kafka` | 只允许 Tempo 的 Pod 和初始化 Job 访问 |
| Job `tempo-kafka-create-topic` | 创建 Topic `tempo-traces`：3 分区、1 副本、保留 24 小时、每分区最多 28GB、单条消息上限 16MB；24 小时后自动清理 |

### 2.3 影响

| 方面 | 影响 |
|---|---|
| 业务的 Kafka（lmspro-release 等） | **没有任何影响**：不连接、不读写、不修改配置 |
| 节点资源 | 增加一个 Pod 的 CPU / 内存占用，以及一块 PVC；使用 `local-path` 时占用所在节点的本地磁盘 |
| 可用性 | 单节点：Kafka Pod 重启或所在节点故障期间，Tempo 无法写入新数据，otel-gateway 最多重试 5 分钟后丢弃；已写入的数据在 PVC 中，不会丢失 |
| 安全 | 集群内明文、无认证，由 NetworkPolicy 限制只有 Tempo 能访问 |

### 2.4 回退

`kubectl -n <TEMPO_NAMESPACE> delete statefulset tempo-kafka`，并删除对应的 Service、NetworkPolicy；确认不再需要其中的数据后删除 PVC `data-tempo-kafka-0`。只影响 Tempo。

---

## 3. Tempo 专用的 RustFS（tempo-rustfs）

### 3.1 为什么 Tempo 需要对象存储

Kafka 只保留 24 小时，live-store 只保存近期数据。block-builder 会把 trace 编码成 Parquet 文件写入对象存储作为**长期存储**（保留 30 天），查询较早的 trace 时 querier 从对象存储读取，backend-worker 定期合并小文件并删除过期文件。RustFS 是兼容 S3 协议的对象存储，Tempo 按 S3 方式访问它。

### 3.2 部署了什么

| 资源 | 内容 |
|---|---|
| StatefulSet `tempo-rustfs` | 1 个 Pod，镜像 `rustfs/rustfs:1.0.0`，单节点单盘；请求 0.25 核 / 512MB 内存，上限 2 核 / 2GB |
| PVC `data-tempo-rustfs-0` | 大小为 `RUSTFS_STORAGE_SIZE`（默认 500Gi） |
| Service `tempo-rustfs` | 9000（S3 API）、9001（控制台），只在集群内访问 |
| NetworkPolicy `tempo-rustfs` | 只允许 Tempo 的 Pod 和初始化 Job 访问 9000 |
| Secret `tempo-credentials` | RustFS 的 root 密钥，RustFS 与 Tempo 共用 |
| Job `tempo-rustfs-create-bucket` | 创建 bucket `tempo-traces`，并用 Tempo 的密钥写入、读取、删除一个测试对象；24 小时后自动清理 |

### 3.3 影响

| 方面 | 影响 |
|---|---|
| 业务的 MinIO | **没有任何影响**：不连接、不创建 bucket 或账号 |
| 节点资源 | 增加一个 Pod 和一块 PVC。30 天 trace 的容量取决于流量和采样率，需要观察使用量并及时扩容 |
| 可用性 | 单节点：RustFS 不可用期间 block-builder 无法落盘、历史查询失败，数据暂存在 Kafka 中，恢复后追平；停机不能超过 Kafka 的保留时间 |
| 数据安全 | PVC 是历史 trace 的唯一副本，需要按企业要求做卷快照或备份 |

### 3.4 回退

`kubectl -n <TEMPO_NAMESPACE> delete statefulset tempo-rustfs`，并删除对应的 Service、NetworkPolicy；确认不再需要历史 trace 后删除 PVC `data-tempo-rustfs-0`。只影响 Tempo。

---

## 4. 其他现有平台（简要）

| 平台 | 改动 | 影响 |
|---|---|---|
| Prometheus | 开启 Remote Write 接收（`enableRemoteWriteReceiver: true`） | helm upgrade 会重启 Prometheus，约 1～2 分钟无法抓取和查询；之后接收 Tempo 推送的 Service Graph 和 span 指标，增加时间序列数量 |
| Prometheus | 在 Tempo namespace 中新增 ServiceMonitor 和 PrometheusRule | 新增对 Tempo 组件的抓取和告警，不改已有规则 |
| Grafana | 新增 UID 为 `tempo` 的数据源（sidecar 方式会新增一个 ConfigMap） | 不修改已有数据源。sidecar 以 initContainer 方式运行时会重启一次 Grafana |
| Elasticsearch（手工第 14 步，脚本不做） | 新增 component template、ingest pipeline，并挂到业务日志的 index template 上 | 只对 rollover 之后的新索引生效；ingest 时多一次 grok 解析。操作前会先备份原 template，可以回退 |

---

## 5. 仓库中的脚本分别做了什么

使用 [纯手工安装手册](docs/tempo/04b-manual-installation.md) 时不会用到下面任何脚本；使用 [安装手册](docs/tempo/04-installation.md) 或交互式脚本时会用到。

脚本分为两类：只在本机准备文件（不碰集群），以及对集群执行 kubectl / helm 命令。**会修改 Prometheus、Grafana 或业务服务的，只有 `interactive-install.sh`。** 其余脚本要么只改 Tempo 自己的 namespace（包括 Tempo 专用的 Kafka 和 RustFS），要么只读。

### 5.1 只在本机运行，不影响集群

**[render.py](scripts/tempo/render.py)：填写配置文件**

1. 读取 `environment.local.json` 并校验：
   - 占位符都已填写；
   - namespace 格式正确；
   - Kafka / RustFS 的 PVC 大小格式正确（如 100Gi）；
   - ZONE_A / ZONE_B 要么都留空（单可用区），要么都填写且不同（双可用区）；
   - Prometheus 端口为整数；
   - 对照 `environment.example.json`，缺少参数时会直接列出。
2. 把 `charts/tempo/values-production.yaml`（双可用区模式下再合并 `values-multi-zone.yaml`）、`manifests/`、`integrations/` 中的 `<TEMPO_NAMESPACE>` 这类占位符替换为实际值，结果写到 `build/`，**不修改原文件**。DEMO_* 留空时跳过示例应用。
3. 校验 Chart 包的 SHA256，必须与 `versions.json` 一致。
4. 执行 `helm lint` 和 `helm template`，渲染结果保存到 `build/tempo-rendered.yaml`。
5. 检查渲染结果：8 个 Tempo 组件齐全，不包含旧组件（ingester / compactor），镜像没有使用 `latest` 标签。

纯手工安装手册第 5 步用 `sed` 完成的就是这件事。

**[check_rendered.py](scripts/tempo/check_rendered.py)：额外的离线检查（只读）**

检查渲染结果：

- Tempo 配置：对象存储为 S3 并指向 `tempo-rustfs`、Kafka 指向 `tempo-kafka`、关闭了 Kafka Topic 自动创建、启用了 Service Graph 处理器。
- 工作负载：每个 Tempo 容器都引用了凭据 Secret，并设置了资源限制和探针。
- Service：每个 Service 都能选中工作负载。
- NetworkPolicy：端口都是整数。
- 副本数：与生产 / 开发模式一致。

**[verify_sdk.py](scripts/python-otel-demo/verify_sdk.py)：Python 示例应用的冒烟测试**

用内存 exporter 在本机运行示例应用，验证 HTTP 上下文传播、错误 span、日志中的 trace_id。不连接任何服务器。

### 5.2 对集群执行操作

**[common.sh](scripts/tempo/common.sh)：其他脚本共用，自身不执行任何操作**

- 要求设置 `TEMPO_NAMESPACE`，并查找 Python 3.10 及以上版本的解释器。
- 每次执行前检查 `build/`：必须是生产模式的渲染结果，没有未替换的占位符，namespace 与 `TEMPO_NAMESPACE` 一致。这样可以避免装到错误的 namespace。

**[preflight-check.sh](scripts/tempo/preflight-check.sh)：只读检查**

列出节点可用区和 StorageClass，检查 Prometheus Operator 的 CRD 是否存在，用 `kubectl auth can-i` 检查权限。**不做任何修改。**

**[install.sh](scripts/tempo/install.sh)：部署 Kafka / RustFS 并安装 Tempo，只在 Tempo namespace 内操作**

1. 要求设置 `CHANGE_APPROVAL_ID` 和 `GATEWAY_MODE`。
2. 检查 namespace 和 Secret（`tempo-credentials`、`otel-gateway-tls`）是否存在（不会创建它们）。
3. 应用 Tempo 的 NetworkPolicy（先做服务端 dry-run）。
4. 部署 `tempo-kafka`、`tempo-rustfs` 及其 Service 和 NetworkPolicy，等待两者就绪。
5. 删除上一次的初始化 Job 后重新运行：创建 Topic、创建 bucket 并做读写测试，打印 Job 日志。
6. 执行 `helm upgrade --install tempo`，最长等待 20 分钟。双可用区模式下这一步会同时安装 rollout-operator 及其 CRD 和 webhook，这是它唯一新增的集群级资源；单可用区模式不安装。
7. 应用 PrometheusRule 告警规则。
8. `GATEWAY_MODE=new` 时应用 otel-gateway 的清单，并等待其就绪。

**不涉及业务的 Kafka / MinIO、Prometheus、Grafana 和业务服务。**

**[validate.sh](scripts/tempo/validate.sh)：只读验证**

显示 release 和 Pod 状态，等待 Tempo 的 Pod 就绪，然后通过 query-frontend 查询指定的 TRACE_ID，确认能返回 span。结果保存到 `build/trace-recent.json`。

**[rollback.sh](scripts/tempo/rollback.sh)：回滚 Tempo 的 Helm release**

执行 `helm rollback tempo <REVISION>`，执行前要求确认数据格式兼容。只回滚 Helm 管理的资源；Kafka、RustFS、CRD 和 gateway 不会恢复。

### 5.3 [interactive-install.sh](scripts/tempo/interactive-install.sh)：串起整个流程

它把安装手册的第 1～13 步串起来执行：复用 render.py、preflight-check.sh 和 install.sh，其余步骤由它自己完成。每一步都可以跳过；修改共享平台之前会先请你确认。

| 步骤 | 做了什么 | 改动了什么 |
|---|---|---|
| 1 工具 | 检查所需工具是否存在，并请你确认当前集群就是目标集群 | 无 |
| 2 参数 | 读取 Prometheus CR、helm list、Service、节点和 StorageClass，给出候选项 | 无 |
| 5 存储 | 询问 Tempo 专用 Kafka / RustFS 的 PVC 大小 | 无 |
| 2.2 Grafana | 建立端口转发，读取已有数据源的 UID | 无 |
| 3 渲染 | 写入 `environment.local.json` → 调用 render.py | 只有本机文件 |
| 4 预检 | 调用 preflight-check.sh | 无 |
| 6 Secret | 创建 namespace；生成 RustFS 访问密钥；用 openssl 生成 gateway 的 CA 和证书；创建 2 个 Secret | Tempo namespace |
| 7 安装 | 调用 install.sh（部署 Kafka / RustFS、初始化 Topic 与 bucket、安装 Tempo），然后检查日志中的连接错误 | Tempo namespace |
| 8 抓取 | 显示 Prometheus 的选择器；需要时经你确认后给 Tempo namespace 加标签 | Tempo namespace 的标签 |
| 9 Remote Write | 检查开关；未开启时先显示 helm diff，确认后执行 upgrade | **Prometheus**（重启一次） |
| 10 Grafana | 为 sidecar 创建数据源 ConfigMap，或通过 API 创建数据源，然后做健康检查 | **Grafana**（新增一个数据源） |
| 11 Operator | 确认 webhook 的失败策略为 Ignore 后安装 Operator；创建 Instrumentation | **集群级**（CRD / RBAC / webhook） |
| 12 注入 | 给业务 namespace 加标签，给你选中的 Deployment 加注解，并确认 agent 已注入 | **业务服务**（各滚动重启一次） |
| 13 验证 | 轮询 gateway 指标直到收到 span，再轮询 Prometheus 直到出现 Service Graph 指标，并列出每条调用边 | 无 |

凭据和证书保存在 `build/secrets/`；不含密码的进度保存在 `build/install-state.env`。脚本退出时会关闭所有端口转发。