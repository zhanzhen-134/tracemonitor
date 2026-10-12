# 纯手工安装手册

本手册与 [04-installation.md](04-installation.md) 的目标相同：在现有集群上部署 Tempo，用 OpenTelemetry Operator 给现有 Java 业务自动注入 agent，最终在 Grafana 中看到 Service Graph。

区别在于：**不使用仓库中的任何脚本**（`render.py`、`install.sh`、`preflight-check.sh`、`validate.sh`、`interactive-install.sh`、`scripts/kafka/*.sh` 都不用），也**不需要 Python**。只使用：

- 仓库中的清单文件：`manifests/`、`integrations/`、`charts/tempo/values-production.yaml`、`charts/otel-operator/values.yaml`
- Chart 包：`charts/tempo/tempo-distributed-3.11.1.tgz`、OpenTelemetry Operator Chart、现有的 kube-prometheus-stack Chart
- 标准命令：`kubectl`、`helm`、`curl`、`openssl`、`sed`、`grep`、`base64`、`sha256sum`

每一步都写明命令、预期结果和失败时的排查方法。**上一步的预期结果没有达成时，不要进入下一步。**

---

## 0. 约定

### 0.1 执行环境

- Shell 为 Bash（Linux，或 Windows 上的 Git Bash / WSL），所有命令在**仓库根目录**执行。
- kubectl / Helm 使用当前 kubeconfig 的默认 context，命令中**不传** `--context` / `--kube-context`。namespace 一律用 `-n` 显式指定。
- 文中 `<...>` 表示需要替换为实际值。
- 所有操作由你一人执行，包括 Kafka、MinIO、Prometheus、Grafana、ES 上的操作。涉及共享平台的变更，先按 [11-change-approval.md](11-change-approval.md) 取得审批。

确认当前指向的是目标集群：

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

### 0.2 需要的权限

| 对象 | 权限 |
|---|---|
| Kubernetes | 集群管理员：创建 namespace / CRD / ClusterRole / Webhook；能 exec 进 Kafka、MinIO Pod；能读 monitoring namespace 的 Secret |
| Kafka | 管理员 SASL 账号；Kafka 由 Strimzi 管理时只需要 Kubernetes 权限 |
| MinIO | root 账号（从 MinIO 的 Secret 中读取） |
| Prometheus | 能对 monitoring namespace 中的 kube-prometheus-stack release 执行 helm upgrade |
| Grafana | 服务器管理员账号 |
| Elasticsearch | 能修改 index template 的账号（只有第 15 步需要） |
| 业务 Deployment | 能修改业务 namespace 标签和 Deployment |

### 0.3 工具

| 工具 | 要求 | 检查 |
|---|---|---|
| kubectl | 与集群版本相差不超过一个小版本 | `kubectl version --client` |
| helm | 3.x，验证版本 3.19.0 | `helm version` |
| curl、openssl、sed、grep、base64、sha256sum、diff | 系统自带即可 | `openssl version` |

### 0.4 变量

在一个终端中导出下面的变量，后续所有命令都在这个终端执行。值在第 2 步中逐项确认，先填已知的部分：

```bash
export TEMPO_NAMESPACE='tracemonitoring'
export MONITORING_NAMESPACE='monitoring'
export GRAFANA_NAMESPACE='monitoring'
export OTEL_OPERATOR_NAMESPACE='opentelemetry-operator-system'
export KAFKA_NAMESPACE='<Kafka 所在 namespace>'
export MINIO_NAMESPACE='<MinIO 所在 namespace>'
export KAFKA_TOPIC='tempo-traces'
export MINIO_BUCKET='tempo-traces'
mkdir -p work/secrets && chmod 700 work/secrets      # 工作目录，存放替换后的清单和凭据
```

`work/` 中会保存明文凭据，**不要提交到 Git**。如果仓库的 `.gitignore` 没有 `work/`，先把它加进去。

### 0.5 步骤总览

| 步骤 | 内容 | 完成标志 |
|---|---|---|
| 1 | 集群预检 | CRD 存在、权限足够 |
| 2 | 确定 Prometheus / Grafana / 集群参数 | 变量全部确定 |
| 3 | Kafka：Topic、用户、ACL | Topic 3 分区 3 副本 |
| 4 | MinIO：bucket、账号、策略 | Tempo 账号 canary 通过 |
| 5 | 准备清单：复制、替换占位符、校验 | 无残留占位符，helm template 通过 |
| 6 | Namespace、gateway 证书、Secret | 3 个 Secret 存在 |
| 7 | 安装 Tempo 与 otel-gateway | 全部 Pod Ready |
| 8 | Prometheus 抓取与告警规则 | targets UP |
| 9 | 开启 Prometheus Remote Write 接收 | flag 为 true |
| 10 | Grafana 注册 Tempo 数据源 | Save & test 成功 |
| 11 | 安装 OpenTelemetry Operator 与 Java Instrumentation | Operator Running |
| 12 | Java 业务开启注入 | Pod 中出现 agent init 容器 |
| 13 | 验证 Trace | 能查到业务 trace |
| 14 | 验证 Service Graph | Grafana 中出现服务之间的边 |
| 15 | ES 日志关联（可选） | trace_id 可检索 |
| 16 | 回退方法 | — |

> 第 9、10 步必须在第 12 步给业务开启注入**之前**完成。Remote Write 未开启时推送的指标会被丢弃、不会补发，Service Graph 会是空的。

---

## 1. 集群预检

```bash
kubectl version
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get storageclass
kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io
kubectl auth can-i create mutatingwebhookconfigurations.admissionregistration.k8s.io
kubectl auth can-i create statefulsets.apps -n "$TEMPO_NAMESPACE"
```

**预期**：

- ZONE 列为空（节点没有可用区标签）是正常的，第 2.3 步选择单可用区模式即可。
- 至少有一个 StorageClass。
- 两个 CRD 都存在（kube-prometheus-stack 会安装它们）。
- 三个 `auth can-i` 都输出 `yes`。

---

## 2. 确定参数

### 2.1 Prometheus release 与版本

```bash
helm list -n "$MONITORING_NAMESPACE"
kubectl -n "$MONITORING_NAMESPACE" get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'; echo
```

- 第二条输出形如 `{"matchLabels":{"release":"kube-prometheus-stack"}}`。其中 `release` 的值就是 `PROMETHEUS_RELEASE`，应与 `helm list` 中 **NAME** 列一致。
- **CHART 列**（如 `kube-prometheus-stack-75.6.0`）去掉前缀后就是 `KPS_VERSION`。

```bash
export PROMETHEUS_RELEASE='<release 名，例如 kube-prometheus-stack>'
export KPS_VERSION='<Chart 版本，例如 75.6.0>'
```

### 2.2 Prometheus Service 与 Remote Write 地址

```bash
kubectl -n "$MONITORING_NAMESPACE" get svc | grep -i prometheus
```

选择**名称以 `-prometheus` 结尾、CLUSTER-IP 不是 None、端口为 9090** 的 Service（不要选 `prometheus-operated`）：

```bash
export PROMETHEUS_SVC='<例如 kube-prometheus-stack-prometheus>'
export PROMETHEUS_PORT=9090
export PROMETHEUS_REMOTE_WRITE_URL="http://$PROMETHEUS_SVC.$MONITORING_NAMESPACE.svc.cluster.local:9090/api/v1/write"
echo "$PROMETHEUS_REMOTE_WRITE_URL"
```

### 2.3 可用区与 StorageClass

```bash
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get storageclass
```

**可用区模式**，二选一：

| 模式 | 适用情况 | 结果 |
|---|---|---|
| **单可用区（默认）** | 节点没有 zone 标签，或者都在同一个机房 | live-store 1 个 StatefulSet、3 个 Pod；不安装 rollout-operator；节点不需要打标签。某个 live-store 重启期间，对应分区最近几分钟的 trace 暂时查不到，恢复后从 Kafka 补回，不丢数据 |
| 双可用区 | 节点带有 `topology.kubernetes.io/zone` 标签，并且分布在两个真实的故障域（不同机房 / 机柜 / 电源） | live-store 每个可用区 3 个，共 6 个；额外安装 rollout-operator（CRD + webhook）；一个可用区整体故障时近期查询仍可用 |

```bash
# 单可用区（默认）
export ZONE_MODE=single
export ZONE_VALUES=''

# 双可用区：改用下面四行
# export ZONE_MODE=multi
# export ZONE_A='<zone 1>'
# export ZONE_B='<zone 2>'
# export ZONE_VALUES='-f work/values-multi-zone.yaml'
```

**StorageClass**：选支持 RWO 的本地或块存储，例如 `local-path`。不要选业务专用的共享存储；NFS 类存储不建议用于 Tempo 的 WAL。

```bash
export STORAGE_CLASS='<StorageClass 名>'
```

### 2.4 Grafana 管理员账号与数据源 UID

```bash
kubectl -n "$GRAFANA_NAMESPACE" get svc,deploy | grep -i grafana
export GRAFANA_SVC='<grafana Service 名，通常为 <release>-grafana>'
export GRAFANA_DEPLOY='<grafana Deployment 名>'
export GRAFANA_ADMIN_USER=$(kubectl -n "$GRAFANA_NAMESPACE" get secret "$GRAFANA_SVC" -o jsonpath='{.data.admin-user}' | base64 -d)
export GRAFANA_ADMIN_PASSWORD=$(kubectl -n "$GRAFANA_NAMESPACE" get secret "$GRAFANA_SVC" -o jsonpath='{.data.admin-password}' | base64 -d)
echo "$GRAFANA_ADMIN_USER"
```

在**另一个终端**保持端口转发：

```bash
kubectl -n monitoring port-forward svc/<grafana Service 名> 3000:80
```

浏览器打开 `http://127.0.0.1:3000`，用上面的账号登录。进入 Connections → Data sources：

- 点开 URL 指向 `$PROMETHEUS_SVC` 的 Prometheus 数据源，浏览器地址 `/connections/datasources/edit/<UID>` 的最后一段即为 `PROMETHEUS_UID`。
- 同样方法取 Elasticsearch 数据源的 UID 作为 `ELASTICSEARCH_UID`。还没有 ES 数据源时，先填 `elasticsearch-not-configured`，不影响 Service Graph。

也可以用命令行查看（不需要 Python）：

```bash
curl -s -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" http://127.0.0.1:3000/api/datasources \
  | grep -o '"uid":"[^"]*","orgId":[0-9]*,"name":"[^"]*","type":"[^"]*"'
```

```bash
export PROMETHEUS_UID='<Prometheus 数据源 UID>'
export ELASTICSEARCH_UID='<ES 数据源 UID 或 elasticsearch-not-configured>'
```

---

## 3. Kafka：Topic、用户与 ACL

Tempo 只使用一个专用 Topic 和一个专用用户，不读写任何业务 Topic。先判断 Kafka 的部署方式：

```bash
kubectl get crd kafkas.kafka.strimzi.io && kubectl -n "$KAFKA_NAMESPACE" get kafka
kubectl -n "$KAFKA_NAMESPACE" get pods,svc
```

第一条有输出说明 Kafka 由 **Strimzi** 管理，按 3.1 执行；否则按 3.2 执行。

### 3.1 Strimzi

**① 确认 TLS + SCRAM 监听器和授权方式**

```bash
export KAFKA_CLUSTER=$(kubectl -n "$KAFKA_NAMESPACE" get kafka -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$KAFKA_NAMESPACE" get kafka "$KAFKA_CLUSTER" \
  -o jsonpath='{range .spec.kafka.listeners[*]}{.name}{" port="}{.port}{" type="}{.type}{" tls="}{.tls}{" auth="}{.authentication.type}{"\n"}{end}'
kubectl -n "$KAFKA_NAMESPACE" get kafka "$KAFKA_CLUSTER" -o jsonpath='authorization={.spec.kafka.authorization.type}{"\n"}'
kubectl -n "$KAFKA_NAMESPACE" get kafka "$KAFKA_CLUSTER" -o jsonpath='topicOperator={.spec.entityOperator.topicOperator}{"\n"}userOperator={.spec.entityOperator.userOperator}{"\n"}'
```

需要满足三个条件：

- 有一个 `type=internal tls=true auth=scram-sha-512` 的监听器，记下它的端口。
- topicOperator 和 userOperator 都有输出（为 `{}` 也算），否则 KafkaTopic / KafkaUser 不会生效。
- 记下 authorization 的值：`simple` 时需要创建 ACL；为空时跳过 ACL。

**没有合适的监听器时**：执行 `kubectl -n "$KAFKA_NAMESPACE" edit kafka "$KAFKA_CLUSTER"`，在 `spec.kafka.listeners` 中加入下面的配置。保存后**所有 broker 会滚动重启**，应在低峰期执行，并等待全部 Pod 恢复 Running：

```yaml
- name: tlsscram
  port: 9094
  type: internal
  tls: true
  authentication:
    type: scram-sha-512
```

不要为了 Tempo 去开启 `simple` 授权：开启后，现有没有 ACL 的业务客户端会被拒绝访问。

```bash
export KAFKA_PORT='<监听器端口，例如 9093>'
export KAFKA_BOOTSTRAP="$KAFKA_CLUSTER-kafka-bootstrap.$KAFKA_NAMESPACE.svc.cluster.local:$KAFKA_PORT"
export KAFKA_SASL_MECHANISM='SCRAM-SHA-512'
```

**② 确认 broker 数量**

```bash
kubectl -n "$KAFKA_NAMESPACE" get pods -l strimzi.io/cluster="$KAFKA_CLUSTER" -L strimzi.io/broker-role,strimzi.io/kind
```

broker 至少 3 个才能使用 3 副本。少于 3 个时，把下面清单中的 `replicas` 改为 broker 数，`min.insync.replicas` 改为 1；这样的环境不满足生产高可用。

**③ 创建 KafkaTopic 和 KafkaUser**

新建文件 `work/secrets/kafka-tempo.yaml`，把 `<KAFKA_NAMESPACE>`、`<KAFKA_CLUSTER>` 替换为实际值。authorization 为空时，删除 `KafkaUser` 中整个 `authorization:` 段：

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
    - resource: {type: group, name: tempo-live-store, patternType: literal}   # 双可用区模式：改为 tempo-live-store-zone-a、tempo-live-store-zone-b 两条
      operations: [Read, Describe]
```

```bash
kubectl apply --dry-run=server -f work/secrets/kafka-tempo.yaml
kubectl apply -f work/secrets/kafka-tempo.yaml
kubectl -n "$KAFKA_NAMESPACE" wait kafkatopic/tempo-traces kafkauser/tempo --for=condition=Ready --timeout=5m
```

**预期**：两个资源都输出 `condition met`。

如果集群的 Strimzi 版本较新，只提供 `kafka.strimzi.io/v1`，把两处 `apiVersion` 改为 `kafka.strimzi.io/v1`。用 `kubectl get crd kafkausers.kafka.strimzi.io -o jsonpath='{.spec.versions[*].name}'` 查看支持的版本。

**④ 取出凭据和 CA**

```bash
{
  echo "KAFKA_USERNAME=tempo"
  echo "KAFKA_PASSWORD=$(kubectl -n "$KAFKA_NAMESPACE" get secret tempo -o jsonpath='{.data.password}' | base64 -d)"
} > work/secrets/kafka.env
kubectl -n "$KAFKA_NAMESPACE" get secret "$KAFKA_CLUSTER-cluster-ca-cert" -o jsonpath='{.data.ca\.crt}' | base64 -d > work/secrets/kafka-ca.crt
chmod 600 work/secrets/*
openssl x509 -in work/secrets/kafka-ca.crt -noout -subject -enddate
```

完成后跳到 3.3。

### 3.2 非 Strimzi（Bitnami Chart / 自建）

所有命令在 broker Pod 内执行，运维机不需要安装 Kafka CLI。

**① 找到 broker Pod、CLI 路径和监听器**

```bash
kubectl -n "$KAFKA_NAMESPACE" get pods
export KAFKA_POD='<broker Pod 名，例如 kafka-controller-0>'
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- sh -c 'env | grep -iE "LISTENERS|SASL|SECURITY_PROTOCOL|AUTHORIZER"'
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- sh -c 'ls /opt/bitnami/kafka/bin/kafka-topics.sh /opt/kafka/bin/kafka-topics.sh 2>/dev/null'
```

```bash
export KBIN='<上面输出的目录，例如 /opt/bitnami/kafka/bin>'
export KAFKA_BS_IN_POD='<Pod 内可用的 SASL_SSL 监听器 host:port，例如 localhost:9093>'
```

Windows Git Bash 会把 `/opt/...` 这类参数改写成 Windows 路径，先执行 `export MSYS_NO_PATHCONV=1`。

**② 在 Pod 内写入管理员客户端配置**

管理员账号是安装 Kafka 时设置的 SASL 用户。Bitnami 的账号一般在 `<release>-user-passwords` Secret 中，用 `kubectl -n "$KAFKA_NAMESPACE" get secret` 查找。

```bash
kubectl -n "$KAFKA_NAMESPACE" exec -i "$KAFKA_POD" -- sh -c 'umask 077; cat > /tmp/admin.properties' <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="<管理员用户>" password="<管理员密码>";
ssl.truststore.type=PEM
ssl.truststore.location=<Pod 内 PEM 格式 CA 文件路径>
EOF
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- "$KBIN/kafka-topics.sh" \
  --bootstrap-server "$KAFKA_BS_IN_POD" --command-config /tmp/admin.properties --list
```

**预期**：列出现有的 Topic。

**③ 检查 broker 消息大小上限**

```bash
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- "$KBIN/kafka-configs.sh" \
  --bootstrap-server "$KAFKA_BS_IN_POD" --command-config /tmp/admin.properties \
  --describe --entity-type brokers --entity-default --all | grep -E 'message.max.bytes|replica.fetch.max.bytes'
```

两项都 ≥ 16000000 时跳过。否则调大；这个设置对所有 Topic 生效，不需要重启 broker：

```bash
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- "$KBIN/kafka-configs.sh" \
  --bootstrap-server "$KAFKA_BS_IN_POD" --command-config /tmp/admin.properties \
  --alter --entity-type brokers --entity-default \
  --add-config message.max.bytes=16000000,replica.fetch.max.bytes=16000000
```

**④ 创建 Tempo 用户、Topic 和 ACL**

```bash
export KAFKA_TEMPO_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
KX="kubectl -n $KAFKA_NAMESPACE exec $KAFKA_POD --"
KARGS="--bootstrap-server $KAFKA_BS_IN_POD --command-config /tmp/admin.properties"

$KX "$KBIN/kafka-configs.sh" $KARGS --alter --entity-type users --entity-name tempo \
  --add-config "SCRAM-SHA-512=[password=$KAFKA_TEMPO_PASSWORD]"

$KX "$KBIN/kafka-topics.sh" $KARGS --create --topic tempo-traces --partitions 3 --replication-factor 3 \
  --config min.insync.replicas=2 --config retention.ms=86400000 \
  --config cleanup.policy=delete --config max.message.bytes=16000000

$KX "$KBIN/kafka-acls.sh" $KARGS --add --allow-principal User:tempo \
  --operation Read --operation Write --operation Describe --topic tempo-traces
for g in block-builder metrics-generator tempo-live-store; do   # 双可用区模式：tempo-live-store 换成 tempo-live-store-zone-a tempo-live-store-zone-b
  $KX "$KBIN/kafka-acls.sh" $KARGS --add --allow-principal User:tempo --operation Read --operation Describe --group "$g"
done

$KX "$KBIN/kafka-topics.sh" $KARGS --describe --topic tempo-traces
```

- Kafka 没有开启授权时，ACL 命令会报错，跳过即可。
- 使用 PLAIN 机制的 Kafka 不能用命令创建用户，需要在 broker 的 JAAS 配置中加上 tempo 用户并滚动重启 broker。

**⑤ 保存凭据和 CA，删除 Pod 内的管理员配置**

```bash
printf 'KAFKA_USERNAME=tempo\nKAFKA_PASSWORD=%s\n' "$KAFKA_TEMPO_PASSWORD" > work/secrets/kafka.env
kubectl -n "$KAFKA_NAMESPACE" exec "$KAFKA_POD" -- cat '<Pod 内 CA 文件路径>' > work/secrets/kafka-ca.crt
chmod 600 work/secrets/*
$KX rm -f /tmp/admin.properties
```

```bash
export KAFKA_BOOTSTRAP='<Kafka Service 名>.<KAFKA_NAMESPACE>.svc.cluster.local:<SASL_SSL 端口>'
export KAFKA_PORT='<broker 的 SASL_SSL 容器端口>'
export KAFKA_SASL_MECHANISM='SCRAM-SHA-512'
```

### 3.3 Kafka 只有明文监听器时

Tempo 默认使用 TLS 连接 Kafka。如果只能使用明文（需要评估安全要求）：

- 第 5 步替换完占位符后，编辑 `work/values-production.yaml` 的 `tempo.structuredConfig.ingest.kafka`：把 `tls_enabled: true` 改为 `false`，并删除 `tls_ca_path` 这一行。
- 连 SASL 也没有时，`KAFKA_SASL_MECHANISM` 填 `PLAIN`，`work/secrets/kafka.env` 中两项都留空：`KAFKA_USERNAME=`、`KAFKA_PASSWORD=`。
- 执行 `echo '# not used' > work/secrets/kafka-ca.crt` 作为占位文件。

---

## 4. MinIO：bucket、账号与策略

### 4.1 找到 MinIO Pod 和 root 账号

```bash
kubectl -n "$MINIO_NAMESPACE" get pods,svc
export MINIO_POD='<MinIO 服务端 Pod 名>'
kubectl -n "$MINIO_NAMESPACE" get pod "$MINIO_POD" \
  -o jsonpath='{range .spec.containers[0].env[*]}{.name}{" <- "}{.valueFrom.secretKeyRef.name}{"/"}{.valueFrom.secretKeyRef.key}{.value}{"\n"}{end}' \
  | grep -iE 'ROOT|ACCESS|SECRET'
```

输出会显示 root 用户名和密码所在的 Secret 和 key，例如 `MINIO_ROOT_USER <- minio/root-user`：

```bash
export MINIO_ROOT_USER=$(kubectl -n "$MINIO_NAMESPACE" get secret '<Secret 名>' -o jsonpath='{.data.<用户 key>}' | base64 -d)
export MINIO_ROOT_PASSWORD=$(kubectl -n "$MINIO_NAMESPACE" get secret '<Secret 名>' -o jsonpath='{.data.<密码 key>}' | base64 -d)
```

使用 MinIO Operator 时，账号在 Pod 内的 `$MINIO_CONFIG_ENV_FILE` 文件中，可以用 `kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- sh -c 'cat $MINIO_CONFIG_ENV_FILE'` 查看。

### 4.2 S3 地址与 TLS

```bash
kubectl -n "$MINIO_NAMESPACE" get svc            # S3 API Service，端口通常为 9000
kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- sh -c 'ls /etc/minio/certs /opt/bitnami/minio/certs /tmp/certs 2>/dev/null'
```

```bash
export MINIO_ENDPOINT='<S3 Service 名>.<MINIO_NAMESPACE>.svc.cluster.local:9000'   # 不含 https://
export MINIO_PORT=9000                                                             # S3 容器端口
```

证书目录中有 `public.crt` 说明启用了 TLS，按下面的命令取 CA；把 `<证书目录>` 换成实际目录：

```bash
# 有 CAs/ 子目录时取其中的 CA；没有时取 public.crt（自签证书本身就是 CA）
kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- sh -c 'cat <证书目录>/CAs/*.crt 2>/dev/null || cat <证书目录>/public.crt' > work/secrets/minio-ca.crt
kubectl -n "$MINIO_NAMESPACE" exec "$MINIO_POD" -- cat '<证书目录>/public.crt' > work/secrets/minio-public.crt
openssl verify -CAfile work/secrets/minio-ca.crt work/secrets/minio-public.crt
openssl x509 -in work/secrets/minio-public.crt -noout -ext subjectAltName
```

**预期**：

- `openssl verify` 输出 `OK`。
- SAN 中包含 `MINIO_ENDPOINT` 中的 Service 名。

如果 `verify` 失败，而且证书由集群 CA 签发（MinIO Operator 的自动证书就是这种情况），改用集群 CA：`kubectl -n "$MINIO_NAMESPACE" get cm kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > work/secrets/minio-ca.crt`，再重新 verify。

**MinIO 未启用 TLS 时**：

- 执行 `echo '# not used' > work/secrets/minio-ca.crt` 作为占位文件。
- 第 5 步替换完占位符后，编辑 `work/values-production.yaml` 的 `storage.trace.s3`：把 `insecure: false` 改为 `true`，并删除 `tls_ca_path` 一行。

### 4.3 创建 bucket、策略和 Tempo 账号

在 MinIO Pod 内使用镜像自带的 `mc`。如果 Pod 中没有 `mc`，用 `kubectl -n "$MINIO_NAMESPACE" run tempo-mc --image=<企业仓库中的 mc 镜像> --restart=Never --command -- sleep 3600` 启动一个临时 Pod，并把下面的 `$MINIO_POD` 换成 `tempo-mc`，用完后删除。

```bash
export MSYS_NO_PATHCONV=1      # 仅 Windows Git Bash 需要
MX="kubectl -n $MINIO_NAMESPACE exec -i $MINIO_POD -- env MC_CONFIG_DIR=/tmp/.mc"
export MINIO_URL="https://$MINIO_ENDPOINT"     # 未启用 TLS 时为 http://

# 让 mc 信任 CA（未启用 TLS 时跳过）
kubectl -n "$MINIO_NAMESPACE" exec -i "$MINIO_POD" -- sh -c 'mkdir -p /tmp/.mc/certs/CAs && cat > /tmp/.mc/certs/CAs/ca.crt' < work/secrets/minio-ca.crt

$MX mc alias set admin "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
$MX mc admin info admin
$MX mc admin user list admin          # 确认没有名为 tempo 的用户，已有时 user add 会重置它的密钥
```

```bash
$MX mc mb --ignore-existing admin/tempo-traces

sed 's/<MINIO_BUCKET>/tempo-traces/g' integrations/minio/policy.json \
  | kubectl -n "$MINIO_NAMESPACE" exec -i "$MINIO_POD" -- sh -c 'cat > /tmp/tempo-policy.json'
$MX mc admin policy create admin tempo-rw /tmp/tempo-policy.json

export MINIO_TEMPO_SECRET="$(openssl rand -base64 30 | tr -d '/+=')"
$MX mc admin user add admin tempo "$MINIO_TEMPO_SECRET"
$MX mc admin policy attach admin tempo-rw --user tempo
```

较老的 `mc` 不支持 `policy create` / `policy attach`，分别改用 `mc admin policy add admin tempo-rw /tmp/tempo-policy.json` 和 `mc admin policy set admin tempo-rw user=tempo`。

### 4.4 用 Tempo 账号验证

```bash
$MX mc alias set tempo "$MINIO_URL" tempo "$MINIO_TEMPO_SECRET"
$MX sh -c 'echo tempo-probe > /tmp/probe.txt'
$MX mc cp /tmp/probe.txt tempo/tempo-traces/_acceptance/probe.txt
$MX mc cat tempo/tempo-traces/_acceptance/probe.txt
$MX mc rm tempo/tempo-traces/_acceptance/probe.txt
```

**预期**：写入、读取（输出 `tempo-probe`）和删除都成功。

保存凭据，清理 Pod 内的临时文件：

```bash
printf 'MINIO_ACCESS_KEY=tempo\nMINIO_SECRET_KEY=%s\n' "$MINIO_TEMPO_SECRET" > work/secrets/minio.env
chmod 600 work/secrets/*
$MX rm -rf /tmp/.mc /tmp/tempo-policy.json /tmp/probe.txt
```

---

## 5. 准备清单

仓库中的清单和 values 文件包含 `<TEMPO_NAMESPACE>` 这样的占位符，需要替换为实际值。**先复制到 `work/` 再修改，不要改仓库中的原文件。**

### 5.1 复制

```bash
cp charts/tempo/values-production.yaml work/
cp -r manifests/tempo manifests/otel-gateway manifests/otel-instrumentation work/
mkdir -p work/grafana && cp integrations/grafana/datasources.yaml work/grafana/
rm -f work/tempo/secret.example.yaml         # 仅说明结构，不使用
[ "$ZONE_MODE" = multi ] && cp charts/tempo/values-multi-zone.yaml work/   # 仅双可用区模式
```

### 5.2 替换占位符

确认第 2～4 步的变量都已导出：

```bash
for v in TEMPO_NAMESPACE MONITORING_NAMESPACE GRAFANA_NAMESPACE KAFKA_NAMESPACE MINIO_NAMESPACE \
         STORAGE_CLASS ZONE_MODE KAFKA_BOOTSTRAP KAFKA_TOPIC KAFKA_SASL_MECHANISM KAFKA_PORT \
         MINIO_ENDPOINT MINIO_BUCKET MINIO_PORT PROMETHEUS_REMOTE_WRITE_URL PROMETHEUS_RELEASE PROMETHEUS_PORT \
         PROMETHEUS_UID ELASTICSEARCH_UID; do
  printf '%-28s %s\n' "$v" "${!v:-<未设置>}"
done
```

**预期**：没有 `<未设置>`。双可用区模式下还要确认 `ZONE_A`、`ZONE_B` 已设置且不同。

执行替换。分隔符用 `|`，因为 URL 中含有 `/`：

```bash
find work -path work/secrets -prune -o -type f \( -name '*.yaml' -o -name '*.json' \) -print | xargs sed -i \
  -e "s|<TEMPO_NAMESPACE>|$TEMPO_NAMESPACE|g" \
  -e "s|<MONITORING_NAMESPACE>|$MONITORING_NAMESPACE|g" \
  -e "s|<GRAFANA_NAMESPACE>|$GRAFANA_NAMESPACE|g" \
  -e "s|<KAFKA_NAMESPACE>|$KAFKA_NAMESPACE|g" \
  -e "s|<MINIO_NAMESPACE>|$MINIO_NAMESPACE|g" \
  -e "s|<STORAGE_CLASS>|$STORAGE_CLASS|g" \
  -e "s|<ZONE_A>|$ZONE_A|g" \
  -e "s|<ZONE_B>|$ZONE_B|g" \
  -e "s|<KAFKA_BOOTSTRAP>|$KAFKA_BOOTSTRAP|g" \
  -e "s|<KAFKA_TOPIC>|$KAFKA_TOPIC|g" \
  -e "s|<KAFKA_SASL_MECHANISM>|$KAFKA_SASL_MECHANISM|g" \
  -e "s|<KAFKA_PORT>|$KAFKA_PORT|g" \
  -e "s|<MINIO_ENDPOINT>|$MINIO_ENDPOINT|g" \
  -e "s|<MINIO_BUCKET>|$MINIO_BUCKET|g" \
  -e "s|<MINIO_PORT>|$MINIO_PORT|g" \
  -e "s|<PROMETHEUS_REMOTE_WRITE_URL>|$PROMETHEUS_REMOTE_WRITE_URL|g" \
  -e "s|<PROMETHEUS_RELEASE>|$PROMETHEUS_RELEASE|g" \
  -e "s|<PROMETHEUS_PORT>|$PROMETHEUS_PORT|g" \
  -e "s|<PROMETHEUS_UID>|$PROMETHEUS_UID|g" \
  -e "s|<ELASTICSEARCH_UID>|$ELASTICSEARCH_UID|g"

grep -rn '<[A-Z][A-Z0-9_]*>' work --exclude-dir=secrets && echo '仍有占位符未替换' || echo '占位符已全部替换'
```

**预期**：输出 `占位符已全部替换`。

注意：values 中的 `${KAFKA_USERNAME}`、`${MINIO_SECRET_KEY}` 等**不是占位符**，不要替换。它们由 Tempo 启动时从 Secret 读取。

各文件中的占位符如下，不用 sed、改为手工编辑时可以参照：

| 文件 | 占位符 |
|---|---|
| `work/values-production.yaml` | STORAGE_CLASS、KAFKA_SASL_MECHANISM、KAFKA_BOOTSTRAP、KAFKA_TOPIC、MINIO_ENDPOINT、MINIO_BUCKET、PROMETHEUS_REMOTE_WRITE_URL、PROMETHEUS_RELEASE |
| `work/values-multi-zone.yaml`（仅双可用区模式） | ZONE_A、ZONE_B |
| `work/tempo/namespace.yaml` | TEMPO_NAMESPACE |
| `work/tempo/networkpolicy.yaml` | TEMPO_NAMESPACE、MONITORING_NAMESPACE、GRAFANA_NAMESPACE、KAFKA_NAMESPACE、KAFKA_PORT、MINIO_NAMESPACE、MINIO_PORT、PROMETHEUS_PORT |
| `work/tempo/prometheusrule.yaml` | TEMPO_NAMESPACE（多处）、PROMETHEUS_RELEASE |
| `work/otel-gateway/*.yaml` | TEMPO_NAMESPACE；servicemonitor.yaml 还有 PROMETHEUS_RELEASE；networkpolicy.yaml 还有 MONITORING_NAMESPACE |
| `work/otel-instrumentation/instrumentation-java.yaml` | TEMPO_NAMESPACE |
| `work/grafana/datasources.yaml` | TEMPO_NAMESPACE、PROMETHEUS_UID、ELASTICSEARCH_UID |

### 5.3 Kafka / MinIO 明文时修改 values

如果第 3.3 或 4.2 步确定使用明文，现在编辑 `work/values-production.yaml`：

```yaml
tempo:
  structuredConfig:
    ingest:
      kafka:
        tls_enabled: false          # Kafka 明文：true 改为 false，并删除下一行 tls_ca_path
storage:
  trace:
    s3:
      insecure: true                # MinIO 明文：false 改为 true，并删除 tls_ca_path 一行
```

### 5.4 调整采样率（可选）

`work/otel-instrumentation/instrumentation-java.yaml` 中 `sampler.argument` 默认为 `'0.2'`（20%）。业务流量很小、希望尽快看到 Service Graph 时，可以先改成 `'1'`，验证完成后改回去。

### 5.5 校验 Chart 包并渲染检查

```bash
sha256sum charts/tempo/tempo-distributed-3.11.1.tgz
grep sha256 charts/tempo/versions.json
```

**预期**：两个值相同（`6e02759562a012706c26d5c862380cbce2db6281124476d81884518f03b41038`）。不同说明包被改动过，停止安装。

```bash
helm lint charts/tempo/tempo-distributed-3.11.1.tgz -f work/values-production.yaml $ZONE_VALUES
helm template tempo charts/tempo/tempo-distributed-3.11.1.tgz -n "$TEMPO_NAMESPACE" \
  -f work/values-production.yaml $ZONE_VALUES > work/tempo-rendered.yaml
grep -c 'name: tempo-live-store' work/tempo-rendered.yaml

grep -o -- '-target=[a-z-]*' work/tempo-rendered.yaml | sort -u
grep -n -A3 'processors:' work/tempo-rendered.yaml | sed -n 1,4p
grep -n -A2 'remote_write:' work/tempo-rendered.yaml
```

**预期**：

- `helm lint` 输出 `1 chart(s) linted, 0 chart(s) failed`。
- target 共 8 个：backend-scheduler、backend-worker、block-builder、distributor、live-store、metrics-generator、querier、query-frontend，没有 ingester 和 compactor。
- 单可用区模式：只有一个 `tempo-live-store` StatefulSet，没有 `tempo-rollout-operator`。双可用区模式：有 `tempo-live-store-zone-a` 和 `tempo-live-store-zone-b`，并有 `tempo-rollout-operator`。
- processors 中包含 `service-graphs`。
- remote_write 的 url 是第 2.2 步确定的地址。

---

## 6. Namespace、gateway 证书与 Secret

### 6.1 Namespace

```bash
kubectl apply -f work/tempo/namespace.yaml
```

### 6.2 生成 otel-gateway 证书

gateway 的 4317 / 4318 端口使用 mTLS，启动时必须挂载服务端证书。Java agent 走的是 4319 明文端口，但证书仍然必须存在：

```bash
cd work/secrets
openssl req -x509 -newkey rsa:4096 -nodes -days 1095 -subj "/CN=otel-gateway-ca" \
  -keyout otel-ca.key -out otel-ca.crt
openssl req -newkey rsa:2048 -nodes -subj "/CN=otel-gateway" \
  -keyout otel-server.key -out otel-server.csr
printf 'subjectAltName=DNS:otel-gateway,DNS:otel-gateway.%s.svc,DNS:otel-gateway.%s.svc.cluster.local\nextendedKeyUsage=serverAuth\n' \
  "$TEMPO_NAMESPACE" "$TEMPO_NAMESPACE" > otel-server.ext
openssl x509 -req -in otel-server.csr -CA otel-ca.crt -CAkey otel-ca.key -CAcreateserial \
  -days 365 -extfile otel-server.ext -out otel-server.crt
openssl x509 -in otel-server.crt -noout -ext subjectAltName
chmod 600 ./*
cd ../..
```

**预期**：SAN 中包含 `otel-gateway.<TEMPO_NAMESPACE>.svc.cluster.local`。

### 6.3 创建 Secret

```bash
cat work/secrets/kafka.env work/secrets/minio.env > work/secrets/credentials.env
chmod 600 work/secrets/credentials.env

kubectl -n "$TEMPO_NAMESPACE" create secret generic tempo-credentials \
  --from-env-file=work/secrets/credentials.env
kubectl -n "$TEMPO_NAMESPACE" create secret generic tempo-ca \
  --from-file=kafka-ca.crt=work/secrets/kafka-ca.crt \
  --from-file=minio-ca.crt=work/secrets/minio-ca.crt
kubectl -n "$TEMPO_NAMESPACE" create secret generic otel-gateway-tls \
  --from-file=ca.crt=work/secrets/otel-ca.crt \
  --from-file=tls.crt=work/secrets/otel-server.crt \
  --from-file=tls.key=work/secrets/otel-server.key

kubectl -n "$TEMPO_NAMESPACE" describe secret tempo-credentials tempo-ca otel-gateway-tls | grep -E '^Name:|bytes'
```

**预期**：

- `tempo-credentials` 有 4 个 key：KAFKA_USERNAME、KAFKA_PASSWORD、MINIO_ACCESS_KEY、MINIO_SECRET_KEY。Kafka 无 SASL 时，前两个为 0 bytes。
- `tempo-ca` 有 2 个 key，`otel-gateway-tls` 有 3 个 key。

Secret 已存在需要重建时，先执行 `kubectl -n "$TEMPO_NAMESPACE" delete secret <名称>` 再创建。

---

## 7. 安装 Tempo 与 otel-gateway

### 7.1 Tempo 的 NetworkPolicy

先创建 NetworkPolicy，让 Tempo Pod 从启动开始就受到网络限制：

```bash
kubectl -n "$TEMPO_NAMESPACE" apply --dry-run=server -f work/tempo/networkpolicy.yaml
kubectl -n "$TEMPO_NAMESPACE" apply -f work/tempo/networkpolicy.yaml
```

### 7.2 用 Helm 安装 Tempo

```bash
helm upgrade --install tempo charts/tempo/tempo-distributed-3.11.1.tgz \
  -n "$TEMPO_NAMESPACE" -f work/values-production.yaml $ZONE_VALUES --wait --timeout 20m
```

安装过程中，可以在另一个终端用 `kubectl -n "$TEMPO_NAMESPACE" get pods -w` 观察。

**预期**：

- 命令输出 `STATUS: deployed`。
- `kubectl -n "$TEMPO_NAMESPACE" get pods` 中全部 Pod Ready：distributor、querier、query-frontend、live-store（单可用区模式为 `tempo-live-store-0`～`2`；双可用区模式为 zone-a、zone-b 各 3 个，并多出 rollout-operator）、block-builder、backend-scheduler、backend-worker、metrics-generator。
- `kubectl -n "$TEMPO_NAMESPACE" get pvc` 全部为 `Bound`。

| 失败现象 | 排查 |
|---|---|
| Pod `Pending` | `kubectl -n "$TEMPO_NAMESPACE" describe pod <pod>`：资源不足、StorageClass 不对；双可用区模式下还可能是 zone 标签与 ZONE_A / ZONE_B 不匹配 |
| Pod `CrashLoopBackOff` | `kubectl -n "$TEMPO_NAMESPACE" logs <pod> --previous`：`SASL authentication failed` 是 Kafka 账号问题，`x509` 是 CA 或 SAN 问题，`AccessDenied` 是 MinIO 策略问题 |
| live-store 长时间不 Ready | 正在追 Kafka 消费进度，或连不上 Kafka；查看日志 |
| Helm 超时 | 修复上面的问题后，重新执行同一条 `helm upgrade --install` |

### 7.3 告警规则与 otel-gateway

```bash
kubectl -n "$TEMPO_NAMESPACE" apply --dry-run=server -f work/tempo/prometheusrule.yaml -f work/otel-gateway/
kubectl -n "$TEMPO_NAMESPACE" apply -f work/tempo/prometheusrule.yaml -f work/otel-gateway/
kubectl -n "$TEMPO_NAMESPACE" rollout status deployment/otel-gateway --timeout=5m
kubectl -n "$TEMPO_NAMESPACE" get pods -l app.kubernetes.io/name=otel-gateway
```

**预期**：3 个 otel-gateway Pod Running。

以后修改 `work/otel-gateway/configmap.yaml` 并重新 apply 后，要执行 `kubectl -n "$TEMPO_NAMESPACE" rollout restart deployment/otel-gateway`，配置才会生效。

---

## 8. Prometheus 抓取与告警规则

```bash
kubectl -n "$MONITORING_NAMESPACE" get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}{"\n"}{.items[0].spec.serviceMonitorNamespaceSelector}{"\n"}{.items[0].spec.ruleSelector}{"\n"}'
kubectl -n "$TEMPO_NAMESPACE" get servicemonitor,prometheusrule --show-labels
```

**预期**：

- selector 中的 `release` 与 ServiceMonitor / PrometheusRule 上的 `release` 标签一致。
- namespaceSelector 为空（`{}`）表示选择所有 namespace。如果它要求某个标签，执行 `kubectl label namespace "$TEMPO_NAMESPACE" <key>=<value>`。

在另一个终端执行 `kubectl -n monitoring port-forward svc/<Prometheus Service 名> 9090:9090`，然后打开 `http://127.0.0.1:9090/targets`，1～2 分钟后应能看到 tempo 和 otel-gateway 的 target，状态为 UP。

这一步只影响 Tempo 自身的监控，不影响 Service Graph。

---

## 9. 开启 Prometheus Remote Write 接收

Service Graph 指标是 Tempo 的 metrics-generator 通过 Remote Write **推送**给 Prometheus 的，所以 Prometheus 必须开启接收功能。

### 9.1 检查当前状态

保持第 8 步的 9090 端口转发，执行：

```bash
curl -s http://127.0.0.1:9090/api/v1/status/flags | grep -o '"web.enable-remote-write-receiver":"[a-z]*"'
```

输出 `"true"` 时跳到 9.3；输出 `"false"` 时执行 9.2。

### 9.2 开启

判断 Prometheus 是否由 GitOps 管理：

```bash
kubectl -n "$MONITORING_NAMESPACE" get prometheus -o yaml | grep -iE 'argocd|fluxcd'
```

有输出说明由 GitOps 管理：在 GitOps 仓库的 values 中加入 `prometheus.prometheusSpec.enableRemoteWriteReceiver: true` 并同步，然后跳到 9.3。

没有输出时，用 Helm 修改。**必须使用现网相同的 Chart 版本和现有 values**，只叠加这一项：

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm -n "$MONITORING_NAMESPACE" get values "$PROMETHEUS_RELEASE" -o yaml > work/prometheus-before.yaml

helm template "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
  -n "$MONITORING_NAMESPACE" -f work/prometheus-before.yaml > work/prometheus-current.yaml
helm template "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
  -n "$MONITORING_NAMESPACE" -f work/prometheus-before.yaml \
  -f integrations/prometheus/values-remote-write.yaml > work/prometheus-after.yaml
diff work/prometheus-current.yaml work/prometheus-after.yaml
```

审阅 diff：Prometheus 资源中应该**只多出** `enableRemoteWriteReceiver: true`。webhook 证书、`caBundle` 这类每次渲染都随机生成的内容可以忽略。确认后执行：

```bash
helm -n "$MONITORING_NAMESPACE" upgrade "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" -f work/prometheus-before.yaml -f integrations/prometheus/values-remote-write.yaml
kubectl -n "$MONITORING_NAMESPACE" get pods -w      # 等待 prometheus-* Pod 重启完成后 Ctrl+C
```

Prometheus 会滚动重启，约 1～2 分钟内无法抓取和查询。重启后之前的端口转发会断开，重新执行 port-forward，再执行 9.1。**预期**：输出 `"true"`。

`work/prometheus-before.yaml` 是回退时使用的原始 values，要保留。

### 9.3 确认 Tempo 推送成功

```bash
kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=10m | grep -iE 'remote|error' | tail -n 20
```

**预期**：没有持续出现下面的错误：

| 错误 | 原因 |
|---|---|
| `404` / `remote write receiver needs to be enabled` | receiver 没有开启 |
| `no such host` | `PROMETHEUS_REMOTE_WRITE_URL` 中的 Service 名错误。改正后重新替换 `work/values-production.yaml` 并重新执行 7.2 |
| `i/o timeout` | 被 NetworkPolicy 拦截：检查 monitoring namespace 是否有默认拒绝的入口策略 |

---

## 10. Grafana 注册 Tempo 数据源

`work/grafana/datasources.yaml` 定义了 UID 为 `tempo` 的 Tempo 数据源，已经配置了 Service Graph 所需的 `serviceMap.datasourceUid` 和 `nodeGraph`。按 Grafana 的部署方式任选一种注册方法。

### 方式 A：kube-prometheus-stack 自带的 Grafana（sidecar 自动加载，推荐）

查看 sidecar 监听的标签：

```bash
kubectl -n "$GRAFANA_NAMESPACE" get deploy "$GRAFANA_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}{range .spec.template.spec.initContainers[*]}init:{.name}{"\n"}{end}'
kubectl -n "$GRAFANA_NAMESPACE" get deploy "$GRAFANA_DEPLOY" \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="grafana-sc-datasources")].env[*]}{.name}={.value}{"\n"}{end}'
```

- 第一条输出中有 `grafana-sc-datasources` 时，说明 sidecar 以普通容器运行，新的数据源会自动加载。
- 输出为 `init:grafana-sc-datasources` 时，说明它是 initContainer，创建 ConfigMap 后需要重启 Grafana。
- 第二条输出中 `LABEL` / `LABEL_VALUE` 默认为 `grafana_datasource` / `1`。

```bash
kubectl -n "$GRAFANA_NAMESPACE" create configmap tempo-datasource \
  --from-file=tempo-datasource.yaml=work/grafana/datasources.yaml
kubectl -n "$GRAFANA_NAMESPACE" label configmap tempo-datasource grafana_datasource=1
# 只有 sidecar 是 initContainer 时才需要：
# kubectl -n "$GRAFANA_NAMESPACE" rollout restart deployment/"$GRAFANA_DEPLOY"
```

通常 1 分钟内生效。

### 方式 B：文件 provisioning

把 `work/grafana/datasources.yaml` 放到 Grafana 的 `provisioning/datasources/` 目录，然后重启 Grafana，或者调用：

```bash
curl -s -X POST -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
  http://127.0.0.1:3000/api/admin/provisioning/datasources/reload
```

### 方式 C：在 UI 中手工创建

Connections → Data sources → Add data source → Tempo：

1. Name 填 `Tempo`；URL 填 `http://tempo-query-frontend.<TEMPO_NAMESPACE>.svc.cluster.local:3200`。
2. Additional settings → **Service graph** → Data source：选择第 2.4 步确定的 Prometheus。
3. **Node graph**：打开 Enable node graph。
4. 点击 Save & test。

### 验证

Grafana → Connections → Data sources → Tempo → **Save & test**。

**预期**：

- 显示 `Data source successfully connected`。
- Additional settings 中 Service graph 的数据源显示为你的 Prometheus。

| 失败现象 | 排查 |
|---|---|
| 列表中没有 Tempo | 方式 A：`kubectl -n "$GRAFANA_NAMESPACE" logs deploy/"$GRAFANA_DEPLOY" -c grafana-sc-datasources` 查看 sidecar 是否加载了文件 |
| Save & test 超时 | Grafana 不在 `GRAFANA_NAMESPACE`，被 Tempo 的 NetworkPolicy 拦截 |

---

## 11. 安装 OpenTelemetry Operator 与 Java Instrumentation

### 11.1 检查是否已安装

```bash
kubectl get deploy -A -l app.kubernetes.io/name=opentelemetry-operator
```

有输出说明已有 Operator：镜像版本 ≥ 0.135.0 时直接复用，跳到 11.3；否则先评估升级的影响。

### 11.2 安装 Operator

Operator 会安装 CRD、ClusterRole 和一个对全集群 Pod 创建都生效的 webhook。`charts/otel-operator/values.yaml` 已经把 Pod 注入 webhook 的失败策略设为 `Ignore`：Operator 故障时 Pod 照常创建，只是不注入 agent。

集群访问不了 ghcr.io 时，先把 `ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator:0.135.0` 和 `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:1.33.6` 同步到企业镜像仓库，并修改 `charts/otel-operator/values.yaml` 与 `work/otel-instrumentation/instrumentation-java.yaml` 中的镜像地址。

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update open-telemetry
helm template otel-operator open-telemetry/opentelemetry-operator --version 0.96.0 \
  -n "$OTEL_OPERATOR_NAMESPACE" -f charts/otel-operator/values.yaml > work/otel-operator-rendered.yaml
grep -n -B2 -A12 'name: mpod.kb.io' work/otel-operator-rendered.yaml | grep failurePolicy
```

**预期**：输出 `failurePolicy: Ignore`。如果是 `Fail`，停止安装并检查 values。

```bash
helm upgrade --install otel-operator open-telemetry/opentelemetry-operator --version 0.96.0 \
  -n "$OTEL_OPERATOR_NAMESPACE" --create-namespace -f charts/otel-operator/values.yaml --wait --timeout 10m
kubectl -n "$OTEL_OPERATOR_NAMESPACE" get pods
kubectl get crd instrumentations.opentelemetry.io
```

**预期**：operator Pod Running，CRD 存在。

### 11.3 创建 Java Instrumentation

```bash
kubectl -n "$TEMPO_NAMESPACE" apply --dry-run=server -f work/otel-instrumentation/instrumentation-java.yaml
kubectl -n "$TEMPO_NAMESPACE" apply -f work/otel-instrumentation/instrumentation-java.yaml
kubectl -n "$TEMPO_NAMESPACE" get instrumentation java \
  -o jsonpath='endpoint={.spec.exporter.endpoint}{"\n"}sampler={.spec.sampler}{"\n"}'
```

**预期**：

- endpoint 为 `http://otel-gateway.<TEMPO_NAMESPACE>.svc.cluster.local:4319`。
- sampler 为 `parentbased_traceidratio`，比例为第 5.4 步设置的值。

Instrumentation 只在 Pod **创建时**生效。以后修改它（例如调整采样率），需要重启业务 Pod 才会生效。

---

## 12. Java 业务开启注入

注入会**滚动重启**所选的 Deployment，应在业务允许的窗口执行。Service Graph 的边需要调用双方都注入，所以建议先选 2～3 个**互相调用**的服务。

### 12.1 放通业务 namespace

```bash
export BIZ_NAMESPACE='<业务 namespace>'
kubectl label namespace "$BIZ_NAMESPACE" tracing-access=enabled --overwrite
kubectl -n "$BIZ_NAMESPACE" get networkpolicy
```

如果业务 namespace 中有限制出口的 NetworkPolicy，需要补一条规则，放行到 `$TEMPO_NAMESPACE` namespace 中 `app.kubernetes.io/name=otel-gateway` 的 TCP 4319。

### 12.2 给 Deployment 加注解

```bash
kubectl -n "$BIZ_NAMESPACE" get deploy
export BIZ_DEPLOYMENT='<Deployment 名>'

kubectl -n "$BIZ_NAMESPACE" patch deployment "$BIZ_DEPLOYMENT" --type=merge -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"instrumentation.opentelemetry.io/inject-java\":\"$TEMPO_NAMESPACE/java\"}}}}}"
kubectl -n "$BIZ_NAMESPACE" rollout status deployment/"$BIZ_DEPLOYMENT" --timeout=10m
```

对每个要接入的服务重复执行。

- Pod 中有多个容器时，再加注解 `instrumentation.opentelemetry.io/container-names: "<Java 容器名>"`，只给业务容器注入。
- 由 Helm 或 GitOps 管理的业务，应把注解写到它们的 values 或仓库中；直接 patch 的注解会在下次发布时被覆盖。
- 已经使用其他 Java agent（SkyWalking、Pinpoint 等）的服务不要注入。

### 12.3 确认注入成功

```bash
kubectl -n "$BIZ_NAMESPACE" get pods
export BIZ_POD='<该 Deployment 新建的 Pod 名>'
kubectl -n "$BIZ_NAMESPACE" get pod "$BIZ_POD" -o jsonpath='{.spec.initContainers[*].name}{"\n"}'
kubectl -n "$BIZ_NAMESPACE" get pod "$BIZ_POD" \
  -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(OTEL_|JAVA_TOOL_OPTIONS)'
kubectl -n "$BIZ_NAMESPACE" logs "$BIZ_POD" | grep -i 'opentelemetry-javaagent' | sed -n 1,3p
```

**预期**：

- init 容器中有 `opentelemetry-auto-instrumentation-java`。
- 环境变量中有 `JAVA_TOOL_OPTIONS=...-javaagent:...`，以及 `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-gateway...:4319`。
- 应用日志中有 `opentelemetry-javaagent - version: 1.33.6`。

| 失败现象 | 排查 |
|---|---|
| 没有 init 容器 | 注解的值写错（应为 `<TEMPO_NAMESPACE>/java`），或 Operator 没有运行：`kubectl -n "$OTEL_OPERATOR_NAMESPACE" logs deploy/otel-operator-opentelemetry-operator` |
| init 容器 `ImagePullBackOff` | 业务 namespace 拉不到 Java agent 镜像 |
| 应用日志中有 `Failed to export spans` | 检查业务 namespace 的标签和出口 NetworkPolicy |

---

## 13. 验证 Trace

先通过业务入口对已注入的服务发起正常请求，持续 3～5 分钟。采样率为 20% 时，一次请求不一定会产生 trace，需要多发几次。

### 13.1 gateway 是否收到数据

```bash
# 终端 2，保持运行
kubectl -n tracemonitoring port-forward deploy/otel-gateway 8888:8888
```

```bash
curl -s http://127.0.0.1:8888/metrics | grep -E '^otelcol_receiver_accepted_spans.*otlp/plaintext|^otelcol_exporter_sent_spans'
```

**预期**：`receiver="otlp/plaintext"` 的计数大于 0，并且持续增长；`otelcol_exporter_sent_spans` 也在增长。

### 13.2 Tempo 中能否查到

```bash
# 终端 3，保持运行
kubectl -n tracemonitoring port-forward svc/tempo-query-frontend 3200:3200
```

```bash
curl -s -G http://127.0.0.1:3200/api/search --data-urlencode 'q={resource.service.name="<业务服务名>"}' --data-urlencode 'limit=5'
```

**预期**：返回的 JSON 中有 `"traceID":"..."`。取其中一个 ID 查询完整 trace：

```bash
export TRACE_ID='<32 位 traceID>'
curl -s "http://127.0.0.1:3200/api/traces/$TRACE_ID" | grep -o '"spanId"' | wc -l
```

**预期**：输出大于 0（为 span 数量）。

也可以在 Grafana → Explore → Tempo 中用 TraceQL `{ resource.service.name = "<业务服务名>" }` 查询。

---

## 14. 验证 Service Graph

### 14.1 Prometheus 中是否有指标

流量开始约 1 分钟后，在 Prometheus UI（`http://127.0.0.1:9090/graph`）或 Grafana Explore（选 Prometheus 数据源）中查询：

```promql
sum by (client, server) (rate(traces_service_graph_request_total[5m]))
```

**预期**：返回已注入服务之间的调用对，例如 `client="order-service", server="inventory-service"`。

没有数据时按下表排查：

| 检查 | 方法 |
|---|---|
| span 指标是否存在 | 查询 `sum by (service) (rate(traces_spanmetrics_calls_total[5m]))`。有数据说明 Remote Write 正常，问题在边的配对 |
| 有 span 指标但没有边 | 调用双方没有都注入，或者请求没有经过两个已注入的服务 |
| 两者都没有 | 重复 9.1 和 9.3；检查 metrics-generator 日志中的 Kafka 错误 |
| 业务流量在开启 Remote Write 之前产生 | 旧数据不会补发，重新产生流量 |

### 14.2 在 Grafana 中查看

Grafana → Explore → 数据源选 **Tempo** → Query type 选 **Service Graph** → 时间范围选 `Last 15 minutes` → Run query。

**预期**：

- 已注入的服务显示为节点，调用关系显示为带方向的边；数据库、Redis 等依赖显示为虚拟节点。
- 节点上显示请求速率和错误率。

| 现象 | 处理 |
|---|---|
| 提示需要配置 service graph 数据源 | `PROMETHEUS_UID` 错误：改正 `work/grafana/datasources.yaml` 后重新执行第 10 步 |
| 页面空白，但 14.1 有数据 | 时间范围不对，或 Service Graph 关联的 Prometheus 不是接收 Remote Write 的那个 |

没有流量 15 分钟后指标会过期，Service Graph 随之变空。

---

## 15. ES 日志关联（可选）

这一步不影响 Trace 和 Service Graph。完整说明见 [04-installation.md](04-installation.md) 第 14 步；下面是不使用 Python 的操作方式。

```bash
export ES_URL='<https://es.example.com:9200>'
export ES_AUTH='<用户>:<密码>'
export ES_CA='<ES CA 文件路径>'
es() { curl -sS --cacert "$ES_CA" -u "$ES_AUTH" -H 'Content-Type: application/json' "$@"; }
```

1. **业务日志带上 trace_id**：文本日志需要在 Logback pattern 中加入 `trace_id=%X{trace_id} span_id=%X{span_id}`（业务配置变更）；JSON 日志一般已经包含这两个字段。
2. **创建 component template 和 ingest pipeline**：

   ```bash
   es -X PUT "$ES_URL/_component_template/trace-fields" -d "{\"template\":{\"mappings\":$(cat integrations/elk/mapping.json)}}"
   es -X PUT "$ES_URL/_ingest/pipeline/trace-id-extract" -d '{"processors":[{"grok":{"field":"message","patterns":["trace_id=(?<trace_id>[0-9a-f]{32}) span_id=(?<span_id>[0-9a-f]{16})"],"ignore_missing":true,"ignore_failure":true}}]}'
   ```

3. **修改业务日志的 index template**：
   1. 找到模板名：`es "$ES_URL/_cat/templates?v"`。
   2. 备份原模板：`es "$ES_URL/_index_template/<模板名>" > work/es-template-before.json`。
   3. 新建 `work/es-template-after.json`：内容为备份文件中 `index_template` 字段的值（即去掉外层的 `{"index_templates":[{"name":...,"index_template": ... }]}`）。
   4. 在其中的 `composed_of` 数组末尾加上 `"trace-fields"`。
   5. 文本日志还要在 `template.settings.index` 中加入 `"final_pipeline": "trace-id-extract"`。如果已经有 `final_pipeline`，不要覆盖它，改为在那个 pipeline 末尾加一个 `{"pipeline":{"name":"trace-id-extract"}}` 处理器。
   6. 提交：`es -X PUT "$ES_URL/_index_template/<模板名>" -d @work/es-template-after.json`。
4. **滚动到新索引**：`es -X POST "$ES_URL/<data stream 或写别名>/_rollover"`，新索引才会使用新的 mapping。
5. **Grafana 中配置 ES → Tempo 跳转**：ES 数据源 → Data links → Add，Field 填 `trace_id`，打开 Internal link 并选择 Tempo，Query 填 `${__value.raw}`。
6. **验证**：在 Tempo 中打开一条 trace，点击 Logs for this span，应能跳转到对应的日志。

---

## 16. 回退

按与安装相反的顺序执行。每一项都可以单独回退：

| 对象 | 回退命令 / 操作 |
|---|---|
| 业务注入 | `kubectl -n <ns> patch deployment <name> --type=json -p '[{"op":"remove","path":"/spec/template/metadata/annotations/instrumentation.opentelemetry.io~1inject-java"}]'`（会再滚动重启一次） |
| 业务 namespace 标签 | `kubectl label namespace <ns> tracing-access-` |
| Instrumentation | `kubectl -n "$TEMPO_NAMESPACE" delete instrumentation java`（先回退所有业务注入） |
| Operator | `helm -n "$OTEL_OPERATOR_NAMESPACE" uninstall otel-operator`；CRD 会保留，确认无人使用后再删除 |
| Grafana 数据源 | 方式 A：`kubectl -n "$GRAFANA_NAMESPACE" delete configmap tempo-datasource`；方式 C：在 UI 中删除 |
| Prometheus Remote Write | `helm -n "$MONITORING_NAMESPACE" upgrade "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" -f work/prometheus-before.yaml` |
| otel-gateway 与告警规则 | `kubectl -n "$TEMPO_NAMESPACE" delete -f work/otel-gateway/ -f work/tempo/prometheusrule.yaml` |
| Tempo | `helm -n "$TEMPO_NAMESPACE" uninstall tempo`；PVC 默认保留，确认不再需要后再删除 |
| NetworkPolicy / Secret / namespace | `kubectl delete namespace "$TEMPO_NAMESPACE"`（会删除其中的全部资源，包括 PVC） |
| MinIO | `mc admin user remove admin tempo`、`mc admin policy remove admin tempo-rw`；确认不再需要历史 trace 后执行 `mc rb --force admin/tempo-traces` |
| Kafka | Strimzi：`kubectl delete -f work/secrets/kafka-tempo.yaml`；非 Strimzi：在 broker Pod 内执行 `kafka-acls.sh --remove`、`kafka-topics.sh --delete --topic tempo-traces`、`kafka-configs.sh --alter --entity-type users --entity-name tempo --delete-config SCRAM-SHA-512` |

全部完成后，把 `work/secrets/` 中需要长期保存的 CA 私钥等文件转存到企业密钥系统，然后删除 `work/` 目录。
