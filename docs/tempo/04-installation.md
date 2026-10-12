# 安装操作手册

本手册按顺序执行即可完成：Kafka/MinIO 准备 → Tempo 部署 → Collector 接入 → Prometheus 派生指标 → Grafana 数据源 → Java 业务自动注入 → 在 Grafana 查看 Trace 与 Service Graph → ES 日志关联。每一步都给出命令、预期结果和失败时的排查方向，**上一步预期结果未达成时不要进入下一步**。

## 交互式安装脚本

第 1～13 步可以用交互式脚本按顺序执行：

```bash
bash scripts/tempo/interactive-install.sh
```

- 脚本会自动探测参数、给出候选项让你选择，涉及集群级或共享平台的变更前会单独确认。
- 每一步都可以跳过（`s`）或退出（`q`）。进度保存在 `build/install-state.env`，重新运行时可以接着做。
- 脚本最后会在 Prometheus 中确认 `traces_service_graph_request_total` 已有数据，然后告诉你如何打开 Grafana 的 Service Graph。
- 第 14 步 ES 日志关联不在脚本中，按手册手工执行。
- 下面的手册是脚本每一步的详细说明；脚本某一步失败时，按对应章节排查。

## 0. 约定

- 所有命令在仓库根目录执行，Shell 为 Bash（Windows 用 Git Bash 或 WSL）。
- kubectl / Helm 直接使用运维机当前 kubeconfig 的默认 context，**不需要也不应在命令中传 `--context` / `--kube-context`**。执行前只需确认当前指向的是目标集群：

  ```bash
  kubectl cluster-info
  kubectl get nodes
  ```

- namespace 一律显式指定（`-n`），不依赖 kubeconfig 中的默认 namespace。
- Helm release 名固定为 `tempo`。
- 本项目**不安装** Kafka、MinIO、Prometheus、Grafana、Elasticsearch，只对它们做增量配置。手册中的**全部操作都由安装执行人一人完成**，包括这些平台上的配置；对共享平台的变更，按 [11-change-approval.md](11-change-approval.md) 先取得审批单号再执行。
- 文中 `<...>` 表示需要替换为实际值。

### 执行人需要具备的权限

| 对象 | 需要的权限 | 用于 |
|---|---|---|
| Kubernetes | 集群管理员（能创建 namespace、CRD、ClusterRole、Webhook，能 exec 进 Kafka / MinIO Pod，能读 monitoring namespace 的 Secret） | 全部步骤 |
| Kafka | 管理员 SASL 账号；Strimzi 管理时只需 Kubernetes 权限 | 第 5 步 |
| MinIO | root 账号（从其 Secret 读取） | 第 5 步 |
| Prometheus（kube-prometheus-stack） | 对 `monitoring` namespace 的 Helm release 执行 upgrade | 第 9 步 |
| Grafana | 服务器管理员账号（kube-prometheus-stack 自带 Grafana 时从 Secret 读取） | 第 2.2、10 步 |
| Elasticsearch（集群外） | 能修改 index template 的账号，以及 ES 的访问地址 | 第 14 步 |
| 业务 Deployment | 能修改业务 namespace 标签与 Deployment；或业务 GitOps 仓库的提交权限 | 第 11.3、12 步 |

后续步骤会用到的 Shell 变量，建议在一个终端里统一导出（值必须与 `environment.local.json` 一致）：

```bash
export TEMPO_NAMESPACE='tracemonitoring'
export MONITORING_NAMESPACE='monitoring'
export GRAFANA_NAMESPACE='monitoring'
export PROMETHEUS_RELEASE='<helm list -n monitoring 的 NAME 列>'
export OTEL_OPERATOR_NAMESPACE='opentelemetry-operator-system'
export DEMO_NAMESPACE=''        # 不部署示例应用时留空
```

`PROMETHEUS_RELEASE` 必须是 `helm list -n monitoring` 输出中 **NAME** 列的值（例如 `kube-prometheus-stack`），不是 CHART 列的 `kube-prometheus-stack-75.6.0`。填错会导致 ServiceMonitor 不被 Prometheus 选中、Remote Write 地址里的 Service 名也会错。确认方法：

```bash
helm list -n monitoring                  # 看 NAME 列；CHART 列才是 kube-prometheus-stack-75.6.0
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'; echo
```

第二条输出形如 `{"matchLabels":{"release":"kube-prometheus-stack"}}`，其中 `release` 的值就是要填的 `PROMETHEUS_RELEASE`。

## 总体步骤

执行顺序：**1 → 2 → 5 → 3 → 4 → 6 → 7 → … → 15**。第 5 步要放在第 3 步之前，因为 Kafka、MinIO 的参数要在第 5 步才能确定。

| 步骤 | 内容 | 完成标志 |
|---|---|---|
| 1 | 准备运维机工具 | 工具版本满足要求 |
| 2 | 收集并填写环境参数 | 除 Kafka/MinIO 外的参数已填 |
| 5 | 在集群内 Kafka 建 Topic/用户/ACL，在 MinIO 建 bucket/账号/策略 | Topic 3 分区 3 副本；Tempo 账号 canary 通过 |
| 3 | 渲染与静态检查 | 输出 `Rendered ... workloads` |
| 4 | 集群预检 | preflight 全部通过 |
| 6 | Namespace、gateway 证书与 Secret | 3 个 Secret 存在 |
| 7 | 安装 Tempo 与 Collector | 全部 Pod Ready |
| 8 | Prometheus 抓取与告警规则 | targets UP、规则加载 |
| 9 | 开启 Prometheus Remote Write 接收 | flag 为 true |
| 10 | Grafana 注册 Tempo 数据源 | Save & Test 成功 |
| 11 | 安装 OpenTelemetry Operator 并创建 Java Instrumentation | Operator Ready、Instrumentation 存在 |
| 12 | 现有 Java 业务开启自动注入并验证 Trace | Grafana 能查到业务 trace |
| 13 | 验证 Service Graph | Grafana 出现业务服务之间的边 |
| 14 | ELK 日志关联 | trace_id 可检索 |
| 15 | 全链验收、压测演练 | 按 06 / 03 / 09 完成 |

> 第 9、10 步必须在第 12 步业务开启注入**之前**完成。Remote Write 未开启时，metrics-generator 推送的样本会被 Prometheus 拒收并直接丢弃，不会补发，Service Graph 将是空的。

---

## 1. 准备运维机工具

| 工具 | 要求 | 检查命令 |
|---|---|---|
| kubectl | 与集群版本相差不超过一个小版本 | `kubectl version` |
| helm | 3.x，仓库验证版本 3.19.0 | `helm version` |
| python | 3.9+ | `python --version` |
| curl | 任意 | `curl --version` |
| docker / 企业构建流水线 | 仅在使用附录 B 示例应用时需要 | `docker version` |

```bash
python -m pip install -r scripts/tempo/requirements.txt
```

## 2. 收集并填写环境参数

```bash
cp environment.example.json environment.local.json
```

编辑 `environment.local.json`，所有 `<SET_ME>` 都要替换；端口保持 JSON 整数；**密码、密钥不写在此文件**（通过 Secret 提供）。各参数获取方法如下（更完整的约束见 [02-prerequisites.md](02-prerequisites.md)）：

| 参数 | 获取方法 |
|---|---|
| `TEMPO_NAMESPACE` | 为 Tempo 新建的专用 namespace，小写字母数字和 `-` |
| `DEMO_NAMESPACE` / `DEMO_IMAGE` | 只接入现有业务、不部署示例应用时，两个都填空字符串 `""`，render 会跳过示例清单；需要示例时见附录 B |
| `STORAGE_CLASS` | `kubectl get storageclass`，选支持 RWO 的那个 |
| `ZONE_A` / `ZONE_B` | `kubectl get nodes -L topology.kubernetes.io/zone`，取两个不同的值 |
| `KAFKA_BOOTSTRAP` / `KAFKA_TOPIC` / `KAFKA_SASL_MECHANISM` / `KAFKA_NAMESPACE` / `KAFKA_PORT` | 在第 5.2～5.4 步创建 Topic 和用户时确定；机制只能是 `PLAIN`、`SCRAM-SHA-256`、`SCRAM-SHA-512` |
| `MINIO_ENDPOINT` / `MINIO_BUCKET` / `MINIO_NAMESPACE` / `MINIO_PORT` | 在第 5.6～5.9 步确定；endpoint 形如 `minio.minio.svc.cluster.local:9000`，不含 `https://` |

Kafka、MinIO 的参数要到第 5 步才能确定，而 render 要求所有参数都已填好。因此**实际顺序是：第 1、2 步 → 第 5 步 → 回到第 3、4 步 → 第 6 步及以后**。
| `MONITORING_NAMESPACE` | `kubectl get prometheus -A`，取 Prometheus CR 所在 namespace |
| `PROMETHEUS_RELEASE` | `helm list -n "$MONITORING_NAMESPACE"`，取 kube-prometheus-stack 的 release 名；ServiceMonitor 会带 `release: <该值>` 标签 |
| `PROMETHEUS_REMOTE_WRITE_URL` | 见下方 2.1 |
| `PROMETHEUS_PORT` | Prometheus Pod 实际监听端口，kube-prometheus-stack 默认 `9090` |
| `GRAFANA_NAMESPACE` | `kubectl get pods -A -l app.kubernetes.io/name=grafana`，取所在 namespace |
| `PROMETHEUS_UID` / `ELASTICSEARCH_UID` | 见下方 2.2 |

### 2.1 确定 PROMETHEUS_REMOTE_WRITE_URL

格式：`http://<Prometheus Service>.<MONITORING_NAMESPACE>.svc.cluster.local:<端口>/api/v1/write`。

```bash
kubectl -n "$MONITORING_NAMESPACE" get svc | grep -i prometheus
```

kube-prometheus-stack 通常有两个与 Prometheus 相关的 Service：

- 名称以 `-prometheus` 结尾、类型为 ClusterIP、端口 9090 的那个：**使用这个**。release 名为 `kube-prometheus-stack` 时它叫 `kube-prometheus-stack-prometheus`；release 名为其他值（如 `kps`）时叫 `kps-kube-prometheus-prometheus`。以 `get svc` 的实际输出为准。
- `prometheus-operated`（Headless，CLUSTER-IP 为 None）：不要使用。

本环境示例（release 为 `kube-prometheus-stack` 时）：

```text
http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
```

下文用 `$PROMETHEUS_SVC` 表示这个 Service 名：

```bash
export PROMETHEUS_SVC='<上面确认的 Service 名>'
```

注意：

- Tempo 的 NetworkPolicy 只放行到 `MONITORING_NAMESPACE` 的 `PROMETHEUS_PORT` 出口。Prometheus 不在集群内、或要经过 Ingress/HTTPS 访问时，必须先修改 `manifests/tempo/networkpolicy.yaml` 的出口规则并评审。
- Prometheus 有多个副本时，通过 Service 写入只会落到其中一个副本；用 `kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.replicas}'` 确认副本数；大于 1 时，Grafana 查询可能落到没有数据的副本，Service Graph 时有时无，此时应评估改用 Thanos Receive / Mimir 等统一写入点。
- Remote Write 需要认证时，按 [05-integration.md](05-integration.md) 在 `metricsGenerator.config.storage.remote_write` 增加认证配置，不要把密码写进 URL。

### 2.2 确定 PROMETHEUS_UID 与 ELASTICSEARCH_UID

这是 Grafana 中**现有** Prometheus / Elasticsearch 数据源的 UID。Service Graph 依赖 `PROMETHEUS_UID` 正确。

**① 连接 Grafana 并取得管理员账号**（kube-prometheus-stack 自带的 Grafana）

```bash
kubectl -n "$GRAFANA_NAMESPACE" get svc,deploy | grep -i grafana
export GRAFANA_SVC='<上面输出的 grafana Service 名，通常为 <release>-grafana>'
export GRAFANA_DEPLOY='<grafana Deployment 名，通常与 Service 同名>'
export GRAFANA_ADMIN_USER=$(kubectl -n "$GRAFANA_NAMESPACE" get secret "$GRAFANA_SVC" -o jsonpath='{.data.admin-user}' | base64 -d)
export GRAFANA_ADMIN_PASSWORD=$(kubectl -n "$GRAFANA_NAMESPACE" get secret "$GRAFANA_SVC" -o jsonpath='{.data.admin-password}' | base64 -d)

# 单独终端保持运行
kubectl -n "$GRAFANA_NAMESPACE" port-forward "svc/$GRAFANA_SVC" 3000:80
```

```bash
export GRAFANA_URL=http://127.0.0.1:3000
curl -s -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/health"
```

**预期**：返回 `"database": "ok"`。如果 Secret 中没有 `admin-user` 键，说明管理员账号由其他方式管理（如 `grafana.admin.existingSecret`），可以用 `helm -n "$MONITORING_NAMESPACE" get values "$PROMETHEUS_RELEASE" | grep -A3 admin` 查看。

**② 查询 UID**

```bash
curl -s -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/datasources" \
  | python -c 'import json,sys; [print(d["uid"], d["type"], d["name"], d["url"]) for d in json.load(sys.stdin)]'
```

- `type` 为 `prometheus`、URL 指向 2.1 中那个 Prometheus Service 的一行，其 uid 作为 `PROMETHEUS_UID`。
- `type` 为 `elasticsearch` 的一行，其 uid 作为 `ELASTICSEARCH_UID`。如果 Grafana 中还没有 ES 数据源，先按第 14.1 步添加，再回来填写。

也可以在 UI 中查看：Connections → Data sources → 点开数据源，浏览器地址 `/connections/datasources/edit/<UID>` 的最后一段即 UID。

## 3. 渲染与静态检查

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
helm search repo grafana-community/tempo-distributed --versions
helm show chart charts/tempo/tempo-distributed-3.11.1.tgz
python scripts/tempo/render.py environment.local.json
```

**预期**：最后输出 `Rendered N workloads to .../build; no cluster changes made`。

渲染脚本会做这些检查：参数无占位符、包 SHA256 一致、8 个 Tempo target 齐全（无旧的 ingester/compactor）、镜像版本固定、`helm lint` 通过。生成的文件都在 `build/` 下（已被 Git 忽略）：

| 文件 | 用途 |
|---|---|
| `build/charts/tempo/values-production.yaml` | 安装 Tempo 使用的 values |
| `build/tempo-rendered.yaml` | 渲染结果，供审阅 |
| `build/manifests/**` | Tempo NetworkPolicy/规则、Collector、Java Instrumentation（`otel-instrumentation/`）、示例应用（DEMO 参数为空时不生成） |
| `build/integrations/grafana/datasources.yaml` | 第 10 步注册到 Grafana 的数据源 |
| `build/integrations/prometheus/values-remote-write.yaml` | 第 9 步 Prometheus 增量 values |

审阅要点：

```bash
# Service Graph 相关配置必须同时存在
grep -n -A3 'processors:' build/tempo-rendered.yaml          # 包含 span-metrics、service-graphs
grep -n -A2 'remote_write:' build/tempo-rendered.yaml        # url 为 2.1 确定的地址
grep -n 'datasourceUid' build/integrations/grafana/datasources.yaml  # 为 2.2 确定的 UID
```

**修改了 `environment.local.json` 后必须重新执行 render**，否则 `build/` 中仍是旧值。

## 4. 集群预检

```bash
bash scripts/tempo/preflight-check.sh
```

**预期**：输出节点及其 zone 标签、StorageClass、ServiceMonitor/PrometheusRule CRD 存在，`auth can-i` 均为 `yes`，最后打印 `Read-only preflight complete`。

| 失败现象 | 处理 |
|---|---|
| `Unresolved environment placeholders` | 参数文件仍有占位符，补齐后重新 render |
| namespace 断言失败 | `TEMPO_NAMESPACE` 与参数文件不一致 |
| CRD 不存在 | 集群未安装 Prometheus Operator（kube-prometheus-stack 会带上）；确认 `helm list -n monitoring` 中的 release 状态 |
| `auth can-i` 为 `no` | 当前 kubeconfig 用户权限不足，申请权限 |

## 5. 准备 Kafka 与 MinIO

Kafka 和 MinIO 都运行在本集群内。下面的命令通过 `kubectl exec` 在它们自己的 Pod 里执行，运维机**不需要**安装 Kafka CLI 或 `mc`。先导出两个 namespace：

```bash
export KAFKA_NAMESPACE='<Kafka 所在 namespace>'
export MINIO_NAMESPACE='<MinIO 所在 namespace>'
mkdir -p build/secrets && chmod 700 build/secrets     # 存放 CA 和凭据，build/ 已被 Git 忽略
```

### 5.1 识别 Kafka 部署方式

```bash
kubectl get crd kafkas.kafka.strimzi.io 2>/dev/null && kubectl -n "$KAFKA_NAMESPACE" get kafka
kubectl -n "$KAFKA_NAMESPACE" get pods,svc
```

- 第一条有输出：Kafka 由 **Strimzi** 管理，按 5.2 执行。Strimzi 会接管 Topic、用户和 ACL，必须通过它的 CR 创建，用 CLI 创建的可能被它覆盖或删除。
- 第一条没有输出（例如 Bitnami Chart 或自建 StatefulSet）：跳过 5.2，按 5.3 执行。

Tempo 默认要求 **TLS + SASL**（PLAIN 或 SCRAM）。如果现有 Kafka 只有明文监听器，见 5.4。

### 5.2 Kafka：Strimzi 方式

**① 确认有 TLS + SCRAM 监听器**

```bash
export KAFKA_CLUSTER=$(kubectl -n "$KAFKA_NAMESPACE" get kafka -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$KAFKA_NAMESPACE" get kafka "$KAFKA_CLUSTER" \
  -o jsonpath='{range .spec.kafka.listeners[*]}{.name}{" port="}{.port}{" tls="}{.tls}{" auth="}{.authentication.type}{"\n"}{end}'
kubectl -n "$KAFKA_NAMESPACE" get kafka "$KAFKA_CLUSTER" -o jsonpath='{.spec.kafka.authorization.type}'; echo
```

需要一个 `tls=true auth=scram-sha-512` 的 internal 监听器（通常端口 9093），并且 authorization 为 `simple`。

如果没有这样的监听器，需要在 Kafka CR 的 `spec.kafka.listeners` 中增加：

```yaml
- name: tlsscram
  port: 9094
  type: internal
  tls: true
  authentication:
    type: scram-sha-512
```

如果 authorization 为空，还要加 `spec.kafka.authorization: {type: simple}`。然后执行 `kubectl -n "$KAFKA_NAMESPACE" edit kafka "$KAFKA_CLUSTER"`。这会**滚动重启所有 broker**，应在低峰执行，并用 `kubectl -n "$KAFKA_NAMESPACE" get pods -w` 等待全部恢复 Running。

注意：开启 `simple` 授权后，**现有没有 ACL 的客户端会被拒绝访问**。如果现有 Kafka 没有开启授权，先确认现有业务的影响，或把 `superUsers` 设置好再开启。

**② 记录参数**

`environment.local.json` 中：

- `KAFKA_BOOTSTRAP` = `<KAFKA_CLUSTER>-kafka-bootstrap.<KAFKA_NAMESPACE>.svc.cluster.local:<监听器端口>`
- `KAFKA_PORT` = 监听器端口
- `KAFKA_SASL_MECHANISM` = `SCRAM-SHA-512`
- `KAFKA_TOPIC` = `tempo-traces`
- `KAFKA_NAMESPACE` = `$KAFKA_NAMESPACE`

**③ 创建 Topic 和用户（含 ACL）**

把 `<...>` 替换为实际值后保存为 `build/secrets/kafka-tempo.yaml`：

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: tempo-traces
  namespace: <KAFKA_NAMESPACE>
  labels:
    strimzi.io/cluster: <KAFKA_CLUSTER>
spec:
  partitions: 3
  replicas: 3
  config:
    min.insync.replicas: 2
    retention.ms: 86400000
    cleanup.policy: delete
    max.message.bytes: 16000000
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: tempo
  namespace: <KAFKA_NAMESPACE>
  labels:
    strimzi.io/cluster: <KAFKA_CLUSTER>
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
    - resource: {type: topic, name: tempo-traces, patternType: literal}
      operations: [Read, Write, Describe]
    - resource: {type: group, name: block-builder, patternType: literal}
      operations: [Read, Describe]
    - resource: {type: group, name: metrics-generator, patternType: literal}
      operations: [Read, Describe]
    - resource: {type: group, name: tempo-live-store-zone-a, patternType: literal}
      operations: [Read, Describe]
    - resource: {type: group, name: tempo-live-store-zone-b, patternType: literal}
      operations: [Read, Describe]
```

```bash
kubectl apply --dry-run=server -f build/secrets/kafka-tempo.yaml
kubectl apply -f build/secrets/kafka-tempo.yaml
kubectl -n "$KAFKA_NAMESPACE" wait kafkatopic/tempo-traces kafkauser/tempo --for=condition=Ready --timeout=3m
```

Strimzi 要求 broker 数至少为 3，才能满足 `replicas: 3`。用 `kubectl -n "$KAFKA_NAMESPACE" get pods -l strimzi.io/kind=Kafka` 确认 broker 数量。

**④ 取出凭据和 CA**

```bash
echo "KAFKA_USERNAME=tempo"                                                     >  build/secrets/credentials.env
echo "KAFKA_PASSWORD=$(kubectl -n "$KAFKA_NAMESPACE" get secret tempo -o jsonpath='{.data.password}' | base64 -d)" >> build/secrets/credentials.env
kubectl -n "$KAFKA_NAMESPACE" get secret "$KAFKA_CLUSTER-cluster-ca-cert" -o jsonpath='{.data.ca\.crt}' | base64 -d > build/secrets/kafka-ca.crt
chmod 600 build/secrets/*
```

完成后跳到 5.5。

### 5.3 Kafka：非 Strimzi（Bitnami / 自建）

**① 找到 broker Pod 和监听器**

```bash
export KAFKA_POD=$(kubectl -n "$KAFKA_NAMESPACE" get pods -o name | grep -iE 'kafka-(controller|broker)?-?0$|kafka-0$' | head -1)
echo "$KAFKA_POD"
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- sh -c 'env | grep -iE "LISTENERS|SASL|SECURITY_PROTOCOL"; ls /opt/bitnami/kafka/config 2>/dev/null'
```

从输出中找到协议为 `SASL_SSL` 的监听器及其端口；CLI 在 Bitnami 镜像中位于 `/opt/bitnami/kafka/bin/`，Apache 官方镜像中位于 `/opt/kafka/bin/`。下文用 `$KBIN` 表示：

```bash
export KBIN=/opt/bitnami/kafka/bin     # 或 /opt/kafka/bin
```

**② 准备管理员客户端配置**

管理员账号是安装 Kafka 时设置的 SASL 用户。Bitnami 的账号密码通常在 `<release>-user-passwords` Secret 中，可以用 `kubectl -n "$KAFKA_NAMESPACE" get secret` 查找。

在 Pod 内写入临时配置（只存在于 `/tmp`，用完删除）：

```bash
kubectl -n "$KAFKA_NAMESPACE" exec -i "$KAFKA_POD" -- sh -c 'umask 077; cat > /tmp/admin.properties' <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="<管理员用户>" password="<管理员密码>";
ssl.truststore.type=PEM
ssl.truststore.location=<Pod 内 CA 文件路径，如 /opt/bitnami/kafka/config/certs/kafka.truststore.pem>
EOF
export KAFKA_BOOTSTRAP_IN_POD='<broker 的 SASL_SSL 监听器 host:port>'
kx() { kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- "$@"; }
kx "$KBIN/kafka-topics.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties --list
```

最后一条能列出 Topic，说明管理员连接正常。

**③ 检查 broker 消息大小上限**

```bash
kx "$KBIN/kafka-configs.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties \
  --describe --entity-type brokers --entity-default --all | grep -E 'message.max.bytes|replica.fetch.max.bytes'
```

两项都 ≥ `16000000` 才能直接使用。否则先执行下面的命令调大，对全部 broker 生效，不需要重启：

```bash
kx "$KBIN/kafka-configs.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties \
  --alter --entity-type brokers --entity-default --add-config message.max.bytes=16000000,replica.fetch.max.bytes=16000000
```

**④ 创建 Tempo 用户（SCRAM）**

```bash
export KAFKA_TEMPO_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
kx "$KBIN/kafka-configs.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties \
  --alter --entity-type users --entity-name tempo --add-config "SCRAM-SHA-512=[password=$KAFKA_TEMPO_PASSWORD]"
```

使用 PLAIN 机制的 Kafka 无法用命令动态创建用户，需要在 broker 的 JAAS 配置中增加 tempo 用户，然后滚动重启 broker。

**⑤ 创建 Topic 和 ACL**

```bash
kx "$KBIN/kafka-topics.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties \
  --create --topic tempo-traces --partitions 3 --replication-factor 3 \
  --config min.insync.replicas=2 --config retention.ms=86400000 \
  --config cleanup.policy=delete --config max.message.bytes=16000000

kx "$KBIN/kafka-acls.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties \
  --add --allow-principal User:tempo --operation Read --operation Write --operation Describe --topic tempo-traces
for g in block-builder metrics-generator tempo-live-store-zone-a tempo-live-store-zone-b; do
  kx "$KBIN/kafka-acls.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties \
    --add --allow-principal User:tempo --operation Read --operation Describe --group "$g"
done
```

如果 Kafka 没有开启授权（没有配置 `authorizer.class.name`），ACL 命令会报错，可以跳过 ACL；此时任何认证用户都能访问该 Topic。

**⑥ 取出凭据和 CA，记录参数**

```bash
echo "KAFKA_USERNAME=tempo"                  >  build/secrets/credentials.env
echo "KAFKA_PASSWORD=$KAFKA_TEMPO_PASSWORD"  >> build/secrets/credentials.env
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- cat '<Pod 内 CA 文件路径>' > build/secrets/kafka-ca.crt
chmod 600 build/secrets/*
```

`environment.local.json` 中：

- `KAFKA_BOOTSTRAP`：`<Kafka Service 名>.<KAFKA_NAMESPACE>.svc.cluster.local:<SASL_SSL 端口>`
- `KAFKA_PORT`：broker 的 SASL_SSL **容器端口**
- `KAFKA_SASL_MECHANISM`：`SCRAM-SHA-512`
- `KAFKA_TOPIC`：`tempo-traces`
- `KAFKA_NAMESPACE`：Kafka 所在 namespace

### 5.4 Kafka 只有明文监听器时

Tempo 默认开启 Kafka TLS，有两种处理方式：

1. **推荐**：按 5.2 ① 或 broker 配置，增加 SASL_SSL 监听器。
2. 集群内明文（需评估安全基线）：编辑 [charts/tempo/values-production.yaml](../../charts/tempo/values-production.yaml) 的 `tempo.structuredConfig.ingest.kafka`，将 `tls_enabled` 改为 `false`，并删除 `tls_ca_path` 一行。
   - 如果连 SASL 也没有，`KAFKA_SASL_MECHANISM` 填 `PLAIN`，`credentials.env` 中 `KAFKA_USERNAME=`、`KAFKA_PASSWORD=` 都留空。
   - 创建 `tempo-ca` 时用任意 PEM 占位，例如 `cp build/secrets/minio-ca.crt build/secrets/kafka-ca.crt`。

### 5.5 Kafka 验证

```bash
# Strimzi
kubectl -n "$KAFKA_NAMESPACE" get kafkatopic tempo-traces -o jsonpath='{.status.conditions[0].type}{" partitions="}{.spec.partitions}{"\n"}'
# 非 Strimzi
kx "$KBIN/kafka-topics.sh" --bootstrap-server "$KAFKA_BOOTSTRAP_IN_POD" --command-config /tmp/admin.properties --describe --topic tempo-traces
kx rm -f /tmp/admin.properties     # 验证完成后删除 Pod 内的管理员配置
```

**预期**：3 个分区，每个分区 3 个副本，Isr 至少包含 2 个副本。Tempo 账号能否连通，由第 7 步 Tempo 启动日志验证；认证失败时会出现 `SASL authentication failed`。

### 5.6 识别 MinIO 并取得管理员凭据

```bash
kubectl -n "$MINIO_NAMESPACE" get pods,svc
export MINIO_POD=$(kubectl -n "$MINIO_NAMESPACE" get pods -o name | grep -i minio | grep -v console | head -1)
kubectl -n "$MINIO_NAMESPACE" get pod "${MINIO_POD#pod/}" -o jsonpath='{range .spec.containers[0].env[*]}{.name}{"="}{.valueFrom.secretKeyRef.name}{"/"}{.valueFrom.secretKeyRef.key}{"\n"}{end}' | grep -iE 'ROOT|ACCESS|SECRET'
```

输出会指出 root 用户和密码所在的 Secret 与 key。常见位置：

- Bitnami：`<release>` Secret 的 `root-user` / `root-password`
- 官方 Chart：`<release>` Secret 的 `rootUser` / `rootPassword`
- MinIO Operator：Tenant 的 env configuration Secret

```bash
export MINIO_ROOT_USER=$(kubectl -n "$MINIO_NAMESPACE" get secret '<Secret 名>' -o jsonpath='{.data.<用户 key>}' | base64 -d)
export MINIO_ROOT_PASSWORD=$(kubectl -n "$MINIO_NAMESPACE" get secret '<Secret 名>' -o jsonpath='{.data.<密码 key>}' | base64 -d)
```

确认 S3 API 端口和是否启用 TLS：

```bash
kubectl -n "$MINIO_NAMESPACE" get svc -o wide          # 找 S3 API 的 Service（端口通常为 9000）
kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- sh -c 'ls /etc/minio/certs /opt/bitnami/minio/certs 2>/dev/null'
```

证书目录中有 `public.crt` 说明启用了 TLS。

### 5.7 取得 MinIO CA

```bash
# 证书目录中有 CAs/ 时优先取 CA；没有时取 public.crt（自签证书本身即 CA）
kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- sh -c 'cat /etc/minio/certs/CAs/*.crt 2>/dev/null || cat /etc/minio/certs/public.crt' > build/secrets/minio-ca.crt
chmod 600 build/secrets/minio-ca.crt
openssl x509 -in build/secrets/minio-ca.crt -noout -subject -enddate
```

MinIO 证书的 SAN 必须包含 Tempo 将要使用的主机名，即 `MINIO_ENDPOINT` 中的 Service DNS 名。用下面的命令检查：

```bash
kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- cat /etc/minio/certs/public.crt | openssl x509 -noout -ext subjectAltName
```

**MinIO 未启用 TLS 时**：

- 编辑 [charts/tempo/values-production.yaml](../../charts/tempo/values-production.yaml) 的 `storage.trace.s3`，把 `insecure` 改为 `true`，并删除 `tls_ca_path` 一行。
- 创建 `tempo-ca` 时，`minio-ca.crt` 用任意 PEM 占位，例如 `cp build/secrets/kafka-ca.crt build/secrets/minio-ca.crt`。

### 5.8 MinIO：创建 bucket、账号与策略

在 MinIO Pod 内使用镜像自带的 `mc`。配置写在 `/tmp`，用完删除：

```bash
mx() { kubectl -n "$MINIO_NAMESPACE" exec -i "$MINIO_POD" -- env MC_CONFIG_DIR=/tmp/.mc "$@"; }
export MINIO_HOST='<S3 Service 名>.<MINIO_NAMESPACE>.svc.cluster.local:9000'
export MINIO_SCHEME=https     # 未启用 TLS 时为 http

# 让 mc 信任 CA（未启用 TLS 时跳过）
kubectl -n "$MINIO_NAMESPACE" exec -i "$MINIO_POD" -- sh -c 'mkdir -p /tmp/.mc/certs/CAs && cat > /tmp/.mc/certs/CAs/ca.crt' < build/secrets/minio-ca.crt

mx mc alias set admin "$MINIO_SCHEME://$MINIO_HOST" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mx mc admin info admin
```

**预期**：`mc admin info` 显示服务器状态为 online。

```bash
# bucket
mx mc mb --ignore-existing admin/tempo-traces
# 策略（render 已把 bucket 名填入）
sed 's/<MINIO_BUCKET>/tempo-traces/g' integrations/minio/policy.json \
  | kubectl -n "$MINIO_NAMESPACE" exec -i "$MINIO_POD" -- sh -c 'cat > /tmp/tempo-policy.json'
mx mc admin policy create admin tempo-rw /tmp/tempo-policy.json
# 用户
export MINIO_TEMPO_SECRET="$(openssl rand -base64 30 | tr -d '/+=')"
mx mc admin user add admin tempo "$MINIO_TEMPO_SECRET"
mx mc admin policy attach admin tempo-rw --user tempo
```

- 较老的 `mc` 没有 `policy create` / `policy attach` 子命令，对应改用 `mc admin policy add admin tempo-rw <文件>` 和 `mc admin policy set admin tempo-rw user=tempo`。
- 策略只允许访问 `tempo-traces` 这一个 bucket；参数文件中的 `MINIO_BUCKET` 也要填 `tempo-traces`。

### 5.9 MinIO：用 Tempo 账号做 canary

```bash
mx mc alias set tempo "$MINIO_SCHEME://$MINIO_HOST" tempo "$MINIO_TEMPO_SECRET"
mx sh -c 'echo tempo-probe > /tmp/probe.txt'
mx mc cp /tmp/probe.txt tempo/tempo-traces/_acceptance/probe.txt
mx mc cat tempo/tempo-traces/_acceptance/probe.txt
mx mc rm tempo/tempo-traces/_acceptance/probe.txt
mx mc ls tempo/                       # 只能看到 tempo-traces，看不到其他 bucket 的内容
```

**预期**：PUT、GET、DELETE 全部成功。

收尾：

```bash
echo "MINIO_ACCESS_KEY=tempo"                >> build/secrets/credentials.env
echo "MINIO_SECRET_KEY=$MINIO_TEMPO_SECRET"  >> build/secrets/credentials.env
chmod 600 build/secrets/credentials.env
mx rm -rf /tmp/.mc /tmp/tempo-policy.json /tmp/probe.txt
```

`environment.local.json` 中：

- `MINIO_ENDPOINT`：`$MINIO_HOST` 的值，不含 `https://`
- `MINIO_BUCKET`：`tempo-traces`
- `MINIO_PORT`：MinIO 的 S3 **容器端口**，通常为 `9000`
- `MINIO_NAMESPACE`：MinIO 所在 namespace

### 5.10 回到第 3 步重新渲染

Kafka、MinIO 参数确定后，执行 `python scripts/tempo/render.py environment.local.json`，再继续第 6 步。

## 6. 准备 Namespace、证书与 Secret

### 6.1 Namespace

```bash
kubectl -n "$TEMPO_NAMESPACE" apply -f build/manifests/tempo/namespace.yaml
```

### 6.2 生成 otel-gateway 证书

gateway 的 4317/4318 端口使用 mTLS，启动时必须挂载服务端证书。即使目前只用 4319 明文端口，也要生成。下面用 openssl 自建一个 CA（有效期 3 年），并签发服务端证书（有效期 1 年）：

```bash
cd build/secrets
openssl req -x509 -newkey rsa:4096 -nodes -days 1095 -subj "/CN=otel-gateway-ca" \
  -keyout otel-ca.key -out otel-ca.crt
openssl req -newkey rsa:2048 -nodes -subj "/CN=otel-gateway" \
  -keyout otel-server.key -out otel-server.csr
cat > otel-server.ext <<EOF
subjectAltName=DNS:otel-gateway,DNS:otel-gateway.$TEMPO_NAMESPACE.svc,DNS:otel-gateway.$TEMPO_NAMESPACE.svc.cluster.local
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in otel-server.csr -CA otel-ca.crt -CAkey otel-ca.key -CAcreateserial \
  -days 365 -extfile otel-server.ext -out otel-server.crt
openssl x509 -in otel-server.crt -noout -ext subjectAltName
chmod 600 ./*
cd ../..
```

**预期**：SAN 中包含 `otel-gateway.tracemonitoring.svc.cluster.local`。

`otel-ca.key` 用于以后签发客户端证书（附录 B 示例应用会用到），妥善保管。证书到期前需要重新签发，并重启 gateway。

### 6.3 创建 Secret

```bash
kubectl -n "$TEMPO_NAMESPACE" create secret generic tempo-credentials \
  --from-env-file=build/secrets/credentials.env

kubectl -n "$TEMPO_NAMESPACE" create secret generic tempo-ca \
  --from-file=kafka-ca.crt=build/secrets/kafka-ca.crt \
  --from-file=minio-ca.crt=build/secrets/minio-ca.crt

kubectl -n "$TEMPO_NAMESPACE" create secret generic otel-gateway-tls \
  --from-file=ca.crt=build/secrets/otel-ca.crt \
  --from-file=tls.crt=build/secrets/otel-server.crt \
  --from-file=tls.key=build/secrets/otel-server.key

kubectl -n "$TEMPO_NAMESPACE" get secret tempo-credentials tempo-ca otel-gateway-tls
```

**预期**：三个 Secret 均存在。`tempo-credentials` 应包含 4 个 key：`KAFKA_USERNAME`、`KAFKA_PASSWORD`、`MINIO_ACCESS_KEY`、`MINIO_SECRET_KEY`。可以用下面的命令确认：

```bash
kubectl -n "$TEMPO_NAMESPACE" get secret tempo-credentials -o jsonpath='{.data}' | python -c 'import json,sys; print(sorted(json.load(sys.stdin)))'
```

说明：

- otel-gateway 开放两类入口：4317/4318 为 mTLS，4319 为集群内明文 OTLP/HTTP，供 Operator 注入的 Java agent 使用（第 11 步）。
- `build/secrets/` 中的文件是明文凭据。全部步骤完成后，把 CA 私钥等需要长期保存的文件转存到企业密钥系统，然后删除该目录。

## 7. 安装 Tempo 与 Collector

```bash
export CHANGE_APPROVAL_ID='<审批单号>'
export GATEWAY_MODE='new'      # 新建 otel-gateway；已有可复用的 Gateway 时用 reuse
bash scripts/tempo/install.sh
```

`install.sh` 依次执行：校验 build 产物 → 检查 Secret → 部署 Tempo NetworkPolicy → `helm upgrade --install tempo`（`--wait`，最长 20 分钟）→ 部署 PrometheusRule →（`new` 模式）部署 otel-gateway。它**不会**创建 Kafka/MinIO、修改 Prometheus 或 Grafana。

验证：

```bash
helm -n "$TEMPO_NAMESPACE" status tempo
kubectl -n "$TEMPO_NAMESPACE" get pods,pvc
kubectl -n "$TEMPO_NAMESPACE" get statefulset tempo-metrics-generator
```

**预期**：

- `helm status` 为 `deployed`。
- 以下工作负载全部 Ready，PVC 全部 `Bound`：distributor、querier、query-frontend、live-store-zone-a、live-store-zone-b、block-builder、backend-scheduler、backend-worker、metrics-generator、rollout-operator、otel-gateway。

| 失败现象 | 排查方向 |
|---|---|
| Pod `Pending` | `kubectl describe pod`：资源不足、StorageClass、zone 标签与 nodeSelector 不匹配 |
| Pod `CrashLoopBackOff` | `kubectl logs <pod> --previous`：Kafka SASL/TLS、MinIO 证书/权限 |
| Live Store 长时间不 Ready | Kafka 消费 lag 未追平，见 [07-troubleshooting.md](07-troubleshooting.md) |
| Helm 报 CRD 无匹配资源 | 先单独安装包内 rollout-operator CRD：`tar -xzf charts/tempo/tempo-distributed-3.11.1.tgz -C build/ && kubectl apply --server-side -f build/tempo-distributed/charts/rollout-operator/charts/crds/crds/`，然后在 values 中设 `rollout_operator.crds.enabled=false`，重新 render 并再次执行 install.sh |

补充：

- `GATEWAY_MODE=reuse` 时不会部署 otel-gateway，需要把 `build/manifests/otel-gateway/configmap.yaml` 中的 traces pipeline 合并到现有 Gateway，并确认其 exporter 指向 `tempo-distributor.<TEMPO_NAMESPACE>.svc.cluster.local:4317`。
- 修改 Collector ConfigMap 不会自动热加载，需要执行 `kubectl -n "$TEMPO_NAMESPACE" rollout restart deployment/otel-gateway`。
- 安装没有使用自动回滚；带状态组件或 CRD 失败后先诊断，回滚见 [08-upgrade-rollback.md](08-upgrade-rollback.md)。

## 8. Prometheus 抓取与告警规则

Chart 已经创建了带 `release: <PROMETHEUS_RELEASE>` 标签的 ServiceMonitor，install.sh 也已经部署了 PrometheusRule。这一步确认现有 Prometheus 确实选中了它们：

```bash
kubectl -n "$TEMPO_NAMESPACE" get servicemonitor,prometheusrule
kubectl -n "$MONITORING_NAMESPACE" get prometheus -o yaml \
  | grep -A4 -E 'serviceMonitorSelector|serviceMonitorNamespaceSelector|ruleSelector|ruleNamespaceSelector'
```

**预期**：selector 匹配 `release: <PROMETHEUS_RELEASE>`，namespaceSelector 包含（或不限制）`TEMPO_NAMESPACE`。在 Prometheus UI 的 Status → Targets 中，tempo-* 与 otel-gateway 状态为 UP。不匹配时按下面处理：

- **release 标签不一致**：把 `environment.local.json` 的 `PROMETHEUS_RELEASE` 改成 selector 中的值，重新 render，再执行一次 `bash scripts/tempo/install.sh`（幂等，只会更新标签）。
- **namespaceSelector 要求特定标签**（例如 `{"matchLabels":{"monitoring":"enabled"}}`）：给 Tempo namespace 加上这个标签，`kubectl label namespace "$TEMPO_NAMESPACE" <key>=<value>`。
- 1～2 分钟后在 Prometheus UI（`kubectl -n monitoring port-forward "svc/$PROMETHEUS_SVC" 9090:9090` 后访问 `http://127.0.0.1:9090/targets`）确认。

## 9. 开启 Prometheus Remote Write 接收

Service Graph 和 span metrics 是 Tempo metrics-generator 通过 Remote Write 推送给 Prometheus 的，Prometheus 必须开启 receiver。

### 9.1 检查当前状态

```bash
# 单独终端保持运行
kubectl -n "$MONITORING_NAMESPACE" port-forward "svc/$PROMETHEUS_SVC" 9090:9090

# 另一个终端
curl -s http://127.0.0.1:9090/api/v1/status/flags | python -c \
  'import json,sys; print(json.load(sys.stdin)["data"].get("web.enable-remote-write-receiver"))'
```

输出 `true` 表示已开启，可以跳到 9.3；输出 `false` 或 `None` 时执行 9.2。

### 9.2 开启 receiver

使用**与现网相同的 Chart 版本和现有 values**，叠加增量文件，先 diff 再 upgrade。不能只传增量文件，否则其他值会回到默认：

```bash
helm -n "$MONITORING_NAMESPACE" list                     # 记录 CHART 列中的版本
helm -n "$MONITORING_NAMESPACE" get values "$PROMETHEUS_RELEASE" -o yaml > build/prometheus-before.yaml
kubectl -n "$MONITORING_NAMESPACE" get prometheus -o yaml > build/prometheus-cr-before.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
export KPS_VERSION='75.6.0'      # 与 helm list 的 CHART 列一致，不能升级 Chart 版本
helm template "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
  -n "$MONITORING_NAMESPACE" \
  -f build/prometheus-before.yaml -f build/integrations/prometheus/values-remote-write.yaml > build/prometheus-after.yaml
helm template "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
  -n "$MONITORING_NAMESPACE" -f build/prometheus-before.yaml > build/prometheus-current.yaml
# 审阅差异：Prometheus CR 中应只多出 enableRemoteWriteReceiver: true
# （admission webhook 证书等随机生成的内容每次渲染都不同，可以忽略）
diff build/prometheus-current.yaml build/prometheus-after.yaml
helm -n "$MONITORING_NAMESPACE" upgrade "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" -f build/prometheus-before.yaml -f build/integrations/prometheus/values-remote-write.yaml
```

由 GitOps（Argo CD / Flux）管理的 Prometheus，应在原 GitOps 仓库的 values 中加入 `prometheus.prometheusSpec.enableRemoteWriteReceiver: true` 并提交，不要直接 upgrade，否则会被同步回去。判断方法：`kubectl -n "$MONITORING_NAMESPACE" get prometheus -o yaml | grep -iE 'argocd|fluxcd'` 有输出即为 GitOps 管理。

upgrade 会让 Prometheus Pod 滚动重启，期间约 1～2 分钟无法抓取和查询。

完成后重复 9.1，**预期**输出 `true`。

### 9.3 确认 Tempo 推送成功

```bash
kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=10m | grep -iE 'remote|write' | tail -20
```

**预期**：没有持续出现 `403`、`404`、`connection refused`、`no such host` 等错误。

| 错误 | 原因 |
|---|---|
| `404` / `remote write receiver needs to be enabled` | receiver 未开启 |
| `no such host` | `PROMETHEUS_REMOTE_WRITE_URL` 中的 Service 名错误 |
| `i/o timeout` | NetworkPolicy 拦截：检查 Tempo 出口规则，以及监控 namespace 是否有默认拒绝的入口策略 |
| `401` / `403` | Prometheus 需要认证，按 05 配置 |

在没有流量之前，Prometheus 里查不到 `traces_*` 系列是正常的；第 13 步会再次验证。

## 10. Grafana 注册 Tempo 数据源

`build/integrations/grafana/datasources.yaml` 定义了 UID 为 `tempo` 的数据源，已包含 Service Graph 所需的配置：

- `serviceMap.datasourceUid`：指向 Prometheus。
- `nodeGraph.enabled: true`。
- Trace→Metrics、Trace→Logs 关联。

它只新增 Tempo 数据源，不覆盖已有数据源。按 Grafana 的部署方式**任选一种**注册方法：

### 方式 A：kube-prometheus-stack 自带 Grafana（sidecar 自动加载）

先确认 sidecar 已开启及其使用的标签（默认标签 `grafana_datasource`，值为 `"1"`）：

```bash
helm -n "$MONITORING_NAMESPACE" get values "$PROMETHEUS_RELEASE" --all -o yaml | grep -A8 'datasources:' | grep -E 'enabled|label'
```

创建带标签的 ConfigMap：

```bash
kubectl -n "$GRAFANA_NAMESPACE" create configmap tempo-datasource \
  --from-file=tempo-datasource.yaml=build/integrations/grafana/datasources.yaml \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_datasource=1 -o yaml \
  | kubectl -n "$GRAFANA_NAMESPACE" apply -f -
```

sidecar 检测到 ConfigMap 后会自动通知 Grafana 重新加载，通常 1 分钟内生效。sidecar 只监听特定 namespace 时（`searchNamespace`），ConfigMap 必须建在它监听的 namespace 中。

### 方式 B：文件 provisioning

把 `build/integrations/grafana/datasources.yaml` 放入 Grafana 的 `provisioning/datasources/` 目录（通过现有挂载或 GitOps），然后让 Grafana 重新加载，二选一：

```bash
# 使用 Grafana 服务器管理员账号（Service Account Token 不能调用此接口）
curl -s -X POST -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
  "$GRAFANA_URL/api/admin/provisioning/datasources/reload"
# 或者重启 Grafana
kubectl -n "$GRAFANA_NAMESPACE" rollout restart "deployment/$GRAFANA_DEPLOY"
```

### 方式 C：在 UI 手工配置

Connections → Data sources → Add data source → Tempo：

1. Name 填 `Tempo`，URL 填 `http://tempo-query-frontend.<TEMPO_NAMESPACE>.svc.cluster.local:3200`。
2. **Additional settings → Service graph → Data source**：选择现有 Prometheus。不配这一项，Service Graph 页会提示未配置。
3. **Node graph**：打开 Enable node graph。
4. Trace to metrics / Trace to logs：分别选择 Prometheus / Elasticsearch，日志查询使用 `trace_id:"${__span.traceId}"`。
5. 点击 Save & test。

### 验证

Grafana → Connections → Data sources → Tempo → 点击 **Save & test**。

**预期**：显示 `Data source successfully connected`，并且 Additional settings 中 Service graph 的数据源显示为现有 Prometheus。

| 失败现象 | 排查 |
|---|---|
| 连接超时 | Grafana 不在 `GRAFANA_NAMESPACE`，或 Grafana 在集群外，被 Tempo NetworkPolicy 拦截（只放行该 namespace 的 3200 端口） |
| 列表里没有 Tempo 数据源 | 方式 A 检查 ConfigMap 标签与 sidecar 日志；方式 B 检查文件路径并执行 reload |
| UID `tempo` 冲突 | 已存在同 UID 的数据源，先审查再决定是否替换 |

## 11. 安装 OpenTelemetry Operator 并创建 Java Instrumentation

现有 Java 业务不改代码、不改镜像，由 OpenTelemetry Operator 在 Pod 创建时自动注入 Java agent。整体链路：

```text
业务 Pod（注入的 Java agent）──OTLP/HTTP 明文 :4319──▶ otel-gateway ──▶ tempo-distributor ──▶ Tempo
                                                                      └─ metrics-generator ──Remote Write──▶ Prometheus ──▶ Grafana Service Graph
```

固定版本（与 Collector 0.135.0 对齐）：

| 组件 | 版本 / 镜像 |
|---|---|
| Helm Chart | `open-telemetry/opentelemetry-operator` 0.96.0 |
| Operator | `ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator:0.135.0` |
| Java agent | `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:1.33.6` |

集群无法访问 ghcr.io 时，先把以上两个镜像同步到企业镜像仓库，再修改 [charts/otel-operator/values.yaml](../../charts/otel-operator/values.yaml) 和 [manifests/otel-instrumentation/instrumentation-java.yaml](../../manifests/otel-instrumentation/instrumentation-java.yaml) 中的镜像地址，然后重新 render。Java agent 镜像会被**每个业务 namespace** 的 init 容器拉取，业务 namespace 必须有拉取该镜像的权限。

### 11.1 安装 Operator（集群级变更，需要审批）

Operator 会安装 CRD、ClusterRole 和全局的 admission webhook。本仓库的 values 已经做了以下设置：

- Pod 注入 webhook 的 `failurePolicy` 设为 `Ignore`。Operator 故障时，任何 namespace 的 Pod 都能正常创建，只是不注入 agent，**不会阻塞业务发布**。
- 使用自签证书，不依赖 cert-manager。
- 关闭 kube-rbac-proxy，减少镜像依赖。

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update open-telemetry

# 先渲染审阅：CRD、ClusterRole、MutatingWebhookConfiguration 中 mpod.kb.io 的 failurePolicy 为 Ignore
helm template otel-operator open-telemetry/opentelemetry-operator --version 0.96.0 \
  -n "$OTEL_OPERATOR_NAMESPACE" -f charts/otel-operator/values.yaml > build/otel-operator-rendered.yaml
grep -n -B2 -A12 'name: mpod.kb.io' build/otel-operator-rendered.yaml | grep failurePolicy

helm upgrade --install otel-operator open-telemetry/opentelemetry-operator --version 0.96.0 \
  -n "$OTEL_OPERATOR_NAMESPACE" --create-namespace \
  -f charts/otel-operator/values.yaml --wait --timeout 10m
```

验证：

```bash
helm -n "$OTEL_OPERATOR_NAMESPACE" status otel-operator
kubectl -n "$OTEL_OPERATOR_NAMESPACE" get pods
kubectl get crd instrumentations.opentelemetry.io
```

**预期**：release 为 `deployed`，operator Pod Running，CRD 存在。

集群已经装有 OpenTelemetry Operator 时**不要重复安装**。先用 `helm list -A | grep -i opentelemetry` 确认现有版本：版本 ≥ 0.135.0 时直接复用，跳到 11.2；版本过低时先评估升级对现有 Instrumentation 的影响。

### 11.2 创建 Java Instrumentation

Instrumentation 定义注入 agent 的行为。它创建在 `tracemonitoring` namespace 中，各业务 namespace 通过 `tracemonitoring/java` 跨 namespace 引用，**业务 namespace 不需要各自创建**。

```bash
kubectl -n "$TEMPO_NAMESPACE" apply --dry-run=server -f build/manifests/otel-instrumentation/instrumentation-java.yaml
kubectl -n "$TEMPO_NAMESPACE" apply -f build/manifests/otel-instrumentation/instrumentation-java.yaml
kubectl -n "$TEMPO_NAMESPACE" get instrumentation java -o yaml
```

主要配置：

| 配置 | 值 | 说明 |
|---|---|---|
| exporter endpoint | `http://otel-gateway.tracemonitoring.svc.cluster.local:4319` | gateway 的集群内明文 OTLP/HTTP 端口 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | 与 4319 端口协议一致 |
| sampler | `parentbased_traceidratio`，`0.2` | 入口服务按 20% 采样，下游继承上游决策，保证一条链路要么完整要么不采，Service Graph 边才完整。比例来自 [03-capacity-planning.md](03-capacity-planning.md) |
| propagators | `tracecontext,baggage` | W3C 标准传播 |
| `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `none` | gateway 只接收 traces；不关闭的话 agent 会持续报导出失败 |

注意事项：

- **采样比例**：流量很小的环境在初期验证时，可以把 `argument` 临时改为 `'1'`，验证完成后改回去。修改后需要重新 render、apply，并**重启业务 Pod**才会生效。Instrumentation 只在 Pod 创建时注入，修改它不会影响正在运行的 Pod。
- **敏感信息**：gateway 会删除 `db.statement`、认证头、Cookie，并去掉 `http.url` / `http.target` / `url.full` 中的查询参数。业务自定义的 span 属性仍需业务方自行避免写入敏感数据。

### 11.3 放通业务 namespace

只有带 `tracing-access=enabled` 标签的 namespace 才能访问 otel-gateway。这是对现有业务资源的变更，执行前记录变更：

```bash
export BIZ_NAMESPACE='<业务 namespace>'
kubectl label namespace "$BIZ_NAMESPACE" tracing-access=enabled --overwrite
```

如果业务 namespace 自己有默认拒绝出口的 NetworkPolicy，还要补一条出口规则，放行到 `tracemonitoring` namespace 中 `app.kubernetes.io/name=otel-gateway` 的 TCP 4319。

## 12. 现有 Java 业务开启自动注入并验证 Trace

### 12.1 给 Deployment 加注解

注入通过 Pod 模板上的注解触发，**会触发一次滚动重启**，应在业务允许的窗口执行。建议先选 2～3 个**互相调用**的服务（例如网关 → 订单 → 库存），这样 Service Graph 能直接看到边。

```bash
export BIZ_DEPLOYMENT='<业务 Deployment 名>'

kubectl -n "$BIZ_NAMESPACE" patch deployment "$BIZ_DEPLOYMENT" --type=merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"tracemonitoring/java"}}}}}'
kubectl -n "$BIZ_NAMESPACE" rollout status deployment/"$BIZ_DEPLOYMENT" --timeout=10m
```

- 由 GitOps 或 Helm 管理的业务，应在原仓库 / values 中加这个注解，不要直接 patch，否则下次发布会被覆盖。
- Pod 内有多个容器时，再加注解 `instrumentation.opentelemetry.io/container-names: "<Java 容器名>"`，只给业务容器注入。
- `service.name` 默认取 Deployment 名。如需自定义，在业务容器的环境变量里设置 `OTEL_SERVICE_NAME`，Operator 不会覆盖已有的值。
- 业务已经在使用其他 Java agent（SkyWalking、Pinpoint 等）时，不要同时注入，先评估冲突。
- agent 会增加约 50～100MB 内存和启动耗时。内存 limit 比较紧的服务，应先评估调高 limit 和启动探针时间。

### 12.2 确认注入成功

```bash
POD=$(kubectl -n "$BIZ_NAMESPACE" get pod -l '<业务 Pod 的 label selector>' -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$BIZ_NAMESPACE" get pod "$POD" -o jsonpath='{.spec.initContainers[*].name}'; echo
kubectl -n "$BIZ_NAMESPACE" get pod "$POD" -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(OTEL_|JAVA_TOOL_OPTIONS)'
kubectl -n "$BIZ_NAMESPACE" logs "$POD" | grep -i 'opentelemetry-javaagent' | head -3
```

**预期**：

- init 容器中有 `opentelemetry-auto-instrumentation-java`。
- 环境变量里有 `JAVA_TOOL_OPTIONS=... -javaagent:/otel-auto-instrumentation-java/javaagent.jar`、`OTEL_SERVICE_NAME`，以及 `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-gateway.tracemonitoring...:4319`。
- 应用日志中出现 `opentelemetry-javaagent - version: 1.33.6`。

| 现象 | 排查 |
|---|---|
| 没有 init 容器 | 注解写错（值必须是 `tracemonitoring/java`），或 Operator 没有运行。webhook 是 Ignore 模式，Operator 故障时会静默跳过注入；查 `kubectl -n "$OTEL_OPERATOR_NAMESPACE" logs deploy/otel-operator-opentelemetry-operator` |
| init 容器 `ImagePullBackOff` | 业务 namespace 拉不到 Java agent 镜像，同步到企业仓库或配置 imagePullSecret |
| 应用日志有 `Failed to export spans` | 网络不通：检查 namespace 标签、业务侧出口 NetworkPolicy |

### 12.3 产生流量并确认 gateway 收到数据

正常业务流量即可。如果是测试环境没有流量，就按业务正常入口发起几次调用，持续 3～5 分钟。

```bash
# 单独终端保持运行
kubectl -n "$TEMPO_NAMESPACE" port-forward deploy/otel-gateway 8888:8888
# 另一个终端
curl -s http://127.0.0.1:8888/metrics | grep -E 'otelcol_receiver_accepted_spans.*otlp/plaintext|otelcol_exporter_sent_spans'
```

**预期**：`receiver="otlp/plaintext"` 的 accepted 计数在增长，`otelcol_exporter_sent_spans` 也在增长。

### 12.4 在 Grafana 查看 Trace

Grafana → Explore → 数据源选 **Tempo** → Query type 选 `TraceQL`：

```text
{ resource.service.name = "<业务服务名>" }
```

时间范围选 `Last 15 minutes`。**预期**：能看到该服务的 trace。点开任意一条，可以看到入口 SERVER span、对下游的 CLIENT span、数据库 / Redis / MQ 调用，以及各 span 的耗时。

也可以用命令行按 ID 验证：从 Grafana 复制一个 Trace ID，然后执行：

```bash
kubectl -n "$TEMPO_NAMESPACE" port-forward svc/tempo-query-frontend 3200:3200   # 单独终端
export TEMPO_QUERY_URL=http://127.0.0.1:3200 TRACE_ID='<trace id>'
bash scripts/tempo/validate.sh
```

查不到时依次检查：

1. 12.3 中 gateway 是否收到数据。
2. gateway 日志：`kubectl -n "$TEMPO_NAMESPACE" logs deploy/otel-gateway --since=10m`。
3. [07-troubleshooting.md](07-troubleshooting.md)。

采样率为 20%，一次请求不一定会生成 trace，需要多发几次。

## 13. 验证 Service Graph

### 13.1 先在 Prometheus 确认指标

流量开始约 1 分钟后（generator 采集间隔 15s，加上配对等待 10s），在 Prometheus（第 9 步的 port-forward，或 Grafana Explore 选 Prometheus 数据源）中查询：

```promql
sum by (client, server) (rate(traces_service_graph_request_total[5m]))
sum by (service) (rate(traces_spanmetrics_calls_total[5m]))
```

**预期**：

- 第一条返回已注入服务之间的调用对，例如 `client="order-service", server="inventory-service"`。
- 第二条返回各服务的请求速率。

第一条为空时，Grafana 的 Service Graph 也一定为空，先按下表排查：

| 检查项 | 命令 / 方法 |
|---|---|
| receiver 是否开启 | 重复 9.1 |
| generator 是否推送报错 | 重复 9.3 |
| generator 是否在消费 Kafka | `kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=10m` 中无 Kafka 认证或 ACL 错误；ACL 包含 `metrics-generator` 消费组 |
| processors 是否生效 | `grep -n -A3 'processors:' build/tempo-rendered.yaml` 包含 `service-graphs` |
| 流量是否在 Remote Write 开启前产生 | 旧样本不会补发，重新产生流量即可 |
| 只有 span metrics、没有 service graph | 边需要调用双方**都已注入**：只注入了调用方时，下游没有 SERVER span，配不成边。数据库、Redis 等例外，会根据 CLIENT span 显示为虚拟节点 |

### 13.2 在 Grafana 查看

Grafana → Explore → 数据源选 **Tempo** → Query type 选 **Service Graph**，时间范围选 `Last 15 minutes` → Run query。

**预期**：

- 已注入的服务显示为节点，服务之间的调用显示为带方向的边。数据库、Redis 等下游依赖显示为虚拟节点。
- 节点上显示请求速率和错误率（红色比例）。
- 点击节点可以跳转到对应的 traces、请求速率和延迟查询。

| 现象 | 处理 |
|---|---|
| 提示需要配置 service graph 数据源 | Tempo 数据源的 `serviceMap.datasourceUid` 未配置或 UID 错误；按 2.2 核对 `PROMETHEUS_UID`，重新 render 后再执行第 10 步 |
| 页面空白，但 13.1 有数据 | 时间范围不覆盖流量时段；或 Service Graph 关联的 Prometheus 与 Remote Write 写入的不是同一个实例 |
| 只有节点没有边 | 调用双方没有都注入；或上游采样、下游未采样（检查是否有服务自己配置了独立的采样器） |
| 调用的是 HTTP 网关 / Ingress，没有出现在图中 | 网关本身没有埋点，Service Graph 会从第一个注入的服务开始画 |

指标在没有流量 15 分钟后会过期（`stale_duration`），隔一段时间再看时需要重新产生流量。

### 13.3 回退

单个服务回退：删除 Pod 模板上的注解，触发一次滚动重启后不再注入。

```bash
kubectl -n "$BIZ_NAMESPACE" patch deployment "$BIZ_DEPLOYMENT" --type=json \
  -p '[{"op":"remove","path":"/spec/template/metadata/annotations/instrumentation.opentelemetry.io~1inject-java"}]'
```

整体回退：

1. 先给所有服务去掉注解。
2. 删除 Instrumentation：`kubectl -n "$TEMPO_NAMESPACE" delete instrumentation java`。
3. 卸载 Operator：`helm -n "$OTEL_OPERATOR_NAMESPACE" uninstall otel-operator`。CRD 会保留；确认没有其他 Instrumentation / OpenTelemetryCollector 资源后，可以用 `kubectl delete crd instrumentations.opentelemetry.io opentelemetrycollectors.opentelemetry.io opampbridges.opentelemetry.io targetallocators.opentelemetry.io` 删除。

## 14. ELK 日志关联

Elasticsearch 在集群外。Tempo 与 Collector 都不直接访问 ES，本项目的 NetworkPolicy 也不涉及 ES。Trace→Logs 跳转是 Grafana 去查 ES，所以只需要 **Grafana 能访问 ES**，并且**日志里有 `trace_id` 字段**。本步骤不影响 Trace 和 Service Graph，可以晚于第 13 步单独进行。

```bash
export ES_URL='<https://es.example.com:9200>'
export ES_USER='<有 manage_index_templates / manage_pipeline 权限的账号>'
export ES_PASSWORD='<密码>'
export ES_CA='<ES CA 文件路径；ES 使用公共受信证书时设为空字符串>'
es() { curl -sS ${ES_CA:+--cacert "$ES_CA"} -u "$ES_USER:$ES_PASSWORD" -H 'Content-Type: application/json' "$@"; }
es "$ES_URL/_cluster/health?pretty"
```

**预期**：返回集群健康状态（green / yellow）。

### 14.1 Grafana 中的 ES 数据源

先用第 2.2 步 ② 的命令查看是否已有 `elasticsearch` 类型的数据源。已经有就跳到 14.2。

没有时，在 Grafana UI 中添加：

1. Connections → Data sources → Add data source → Elasticsearch。
2. URL 填 `$ES_URL`。认证选 Basic auth，填 ES 只读账号。ES 使用私有 CA 时，打开 With CA Cert 并粘贴 CA。
3. Index name 填业务日志的索引模式（例如 `logs-*`），Time field name 填 `@timestamp`。
4. 点击 Save & test。**预期**：显示连接成功。

记下浏览器地址中的 UID，填入 `ELASTICSEARCH_UID`，重新 render，然后重新执行第 10 步，让 Tempo 数据源的 Trace→Logs 指向它。

Save & test 超时说明 Grafana Pod 访问不到集群外的 ES。检查方法：

```bash
kubectl -n "$GRAFANA_NAMESPACE" exec "deploy/$GRAFANA_DEPLOY" -c grafana -- wget -qO- -T 5 "$ES_URL" ; echo "exit=$?"
```

返回 401 也说明网络是通的。如果连接超时，检查 monitoring namespace 的出口 NetworkPolicy，以及集群到 ES 的防火墙。

### 14.2 让业务日志带上 trace_id

Java agent 已经把 `trace_id`、`span_id` 放进了 Logback / Log4j2 的 MDC，但默认的日志格式不会输出它们。根据业务日志格式选择一种：

- **JSON 日志**（如 logstash-logback-encoder）：默认会输出全部 MDC 字段，日志中已经有 `trace_id`、`span_id`，跳到 14.3。
- **文本日志**：在日志 pattern 中加入 `trace_id=%X{trace_id} span_id=%X{span_id}`。例如 Logback：

  ```xml
  <pattern>%d{ISO8601} %-5level [%thread] %logger{36} trace_id=%X{trace_id} span_id=%X{span_id} - %msg%n</pattern>
  ```

  这一项需要修改业务的日志配置并重新发布。修改后，用 `kubectl -n "$BIZ_NAMESPACE" logs deploy/"$BIZ_DEPLOYMENT" | tail` 确认日志中出现了 32 位的 `trace_id`。没有被采样的请求，trace_id 也会输出，但 Tempo 中查不到对应的 trace。

### 14.3 在 ES 中提取字段并设置 mapping

在 ES 中完成：用 component template 固定字段类型；对文本日志，再用 ingest pipeline 从 `message` 中提取 trace_id。**不需要修改 Logstash / Filebeat。**

**① 找到业务日志使用的 index template**

```bash
es "$ES_URL/_cat/indices/<业务日志索引前缀>*?v&s=index:desc" | head -5
es "$ES_URL/_index_template" | python -c 'import json,sys; [print(t["name"], t["index_template"]["index_patterns"]) for t in json.load(sys.stdin)["index_templates"]]'
export ES_TEMPLATE='<index_patterns 能匹配业务日志索引的模板名>'
```

**② 检查字段是否已存在、类型是否冲突**

```bash
es "$ES_URL/<最新的业务日志索引>/_mapping/field/trace_id,span_id,@timestamp?pretty"
```

- 返回空，或者 `trace_id` 已经是 `keyword`：可以继续。
- `trace_id` 已经是 `text`：已有索引中的类型不能修改，新的 mapping 只对 rollover 之后的新索引生效。

**③ 创建 component template 与 ingest pipeline**

```bash
es -X PUT "$ES_URL/_component_template/trace-fields" -d "{\"template\":{\"mappings\":$(cat integrations/elk/mapping.json)}}"

# 只有文本日志需要；JSON 日志跳过这一条
es -X PUT "$ES_URL/_ingest/pipeline/trace-id-extract" -d '{
  "description": "Extract OpenTelemetry trace_id/span_id from log message",
  "processors": [
    {"grok": {"field": "message",
              "patterns": ["trace_id=(?<trace_id>[0-9a-f]{32}) span_id=(?<span_id>[0-9a-f]{16})"],
              "ignore_missing": true, "ignore_failure": true}}
  ]
}'
```

**④ 把它们挂到业务日志的 index template 上**

```bash
es "$ES_URL/_index_template/$ES_TEMPLATE" > build/es-template-before.json      # 备份，回退时使用
python - "$ES_TEMPLATE" <<'EOF' > build/es-template-after.json
import json, sys
t = json.load(open('build/es-template-before.json'))['index_templates'][0]['index_template']
t.setdefault('composed_of', [])
if 'trace-fields' not in t['composed_of']:
    t['composed_of'].append('trace-fields')
settings = t.setdefault('template', {}).setdefault('settings', {})
index = settings.setdefault('index', {})
if 'final_pipeline' in index or 'index.final_pipeline' in settings:
    sys.exit('final_pipeline already set; chain trace-id-extract into it manually')
index['final_pipeline'] = 'trace-id-extract'   # JSON logs: delete this line
print(json.dumps(t))
EOF
es -X PUT "$ES_URL/_index_template/$ES_TEMPLATE" -d @build/es-template-after.json
```

- 使用 `final_pipeline`，是为了不覆盖已有的 `default_pipeline`。
- 脚本提示 `final_pipeline` 已存在时，需要在已有的那个 pipeline 末尾加一个 `{"pipeline": {"name": "trace-id-extract"}}` 处理器。
- 使用旧式 `_template`（legacy）的集群，改为把 mapping 合并到 `_template/<名称>` 的 `mappings.properties` 中。

**⑤ 让新 mapping 生效**

template 只对新建的索引生效。可以等下一次自动 rollover / 按日期建新索引，也可以手动滚动：

```bash
es -X POST "$ES_URL/<data stream 或写别名>/_rollover"
```

回退方法：`es -X PUT "$ES_URL/_index_template/$ES_TEMPLATE" -d "$(python -c 'import json; print(json.dumps(json.load(open("build/es-template-before.json"))["index_templates"][0]["index_template"]))')"`。

### 14.4 在 ES 数据源中配置跳转回 Tempo

Grafana → Connections → Data sources → Elasticsearch → Data links → Add：

| 字段 | 值 |
|---|---|
| Field | `trace_id` |
| Internal link | 打开，选择 Tempo |
| Query | `${__value.raw}` |

点击 Save & test。如果 ES 数据源是通过 provisioning 创建的（UI 中无法编辑），在它的 provisioning 文件 `jsonData` 中加入 [05-integration.md](05-integration.md) 中的 `dataLinks` 片段，然后按第 10 步的方式重新加载。

### 14.5 验证

1. 在 Grafana Explore 选 ES 数据源，查询 `trace_id:*`，时间范围选最近 15 分钟。**预期**：有日志返回，且 `trace_id` 字段为 32 位十六进制。
2. 在 Tempo 中打开一条业务 trace，点击 span 上的 **Logs for this span**。**预期**：跳转到 ES，显示该 trace 的日志。
3. 在 ES 日志中点击 `trace_id` 字段旁的 Tempo 链接。**预期**：打开对应 trace。

## 15. 全链验收与压测

- 按 [06-validation.md](06-validation.md) 执行全部检查并保存证据，包括后端存储（MinIO）查询、告警规则、受限 namespace 访问被拒等。
- 按 [03-capacity-planning.md](03-capacity-planning.md) 和 [09-operations-runbook.md](09-operations-runbook.md)，在低风险窗口完成压测和故障演练。
- 首次看到 trace 和 Service Graph 只说明基本链路可用，不代表生产验收通过。

## 附录 A：能看到 Service Graph 的前提条件

| # | 条件 | 由谁保证 |
|---|---|---|
| 1 | 业务 Pod 已注入 Java agent，调用双方都产生 CLIENT / SERVER span，并通过 `traceparent` 传播 | 第 11、12 步 |
| 2 | 业务 namespace 有 `tracing-access=enabled` 标签，能访问 otel-gateway 的 4319 端口 | 第 11.3 步 |
| 3 | otel-gateway 把 trace 转发到 `tempo-distributor:4317` | 第 7 步（仓库配置已就绪） |
| 4 | metrics-generator 启用 `service-graphs` processor | 仓库配置已就绪，无需额外操作 |
| 5 | generator 能 Remote Write 到 Prometheus：URL 正确、receiver 已开启、网络放行 | 第 2.1 步、第 9 步 |
| 6 | Grafana 中 Tempo 数据源的 `serviceMap.datasourceUid` 指向同一个 Prometheus | 第 2.2 步、第 10 步 |
| 7 | 第 5、6 条完成**之后**才开启注入、产生流量 | 第 12 步 |

## 附录 B：可选的 Python 示例应用

不接入示例应用时可以跳过本附录。示例使用 mTLS 端口（4317），用来在没有业务流量的环境中验证 mTLS 接入。

1. 构建并推送镜像：`docker build -t <REGISTRY>/python-otel-demo:1.0.0 examples/python-otel-demo`，然后 push。
2. 在 `environment.local.json` 中填写 `DEMO_NAMESPACE`、`DEMO_IMAGE`，重新执行 `python scripts/tempo/render.py environment.local.json`。
3. 准备 namespace 和客户端证书：

   ```bash
   kubectl create namespace "$DEMO_NAMESPACE"
   kubectl label namespace "$DEMO_NAMESPACE" tracing-access=enabled --overwrite
   kubectl -n "$DEMO_NAMESPACE" create secret generic otel-client-tls \
     --from-file=ca.crt="$OTEL_SERVER_CA_FILE" \
     --from-file=tls.crt="$OTEL_CLIENT_CERT_FILE" \
     --from-file=tls.key="$OTEL_CLIENT_KEY_FILE"
   ```

4. 部署：

   ```bash
   kubectl -n "$DEMO_NAMESPACE" apply -f build/manifests/python-otel-demo/deployment.yaml
   kubectl -n "$DEMO_NAMESPACE" rollout status deployment/demo-a --timeout=5m
   kubectl -n "$DEMO_NAMESPACE" rollout status deployment/demo-b --timeout=5m
   ```

5. 产生流量：

   ```bash
   kubectl -n "$DEMO_NAMESPACE" port-forward svc/demo-a 8080:8080       # 单独终端
   for i in $(seq 1 300); do curl --fail --silent --show-error http://127.0.0.1:8080/call >/dev/null; sleep 1; done
   ```

   `/call` 返回的 `trace_id` 与 `downstream.trace_id` 应相同。

6. 验证：Service Graph 中应出现 `demo-a → demo-b` 的边；Prometheus 查询 `traces_service_graph_request_total{client="demo-a",server="demo-b"}` 有数据。