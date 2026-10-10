# 按顺序安装

所有命令在仓库根目录执行，Shell 为 Bash。使用 kubectl/Helm 当前 kubeconfig context，无需额外设置 context 参数；先设 `TEMPO_NAMESPACE`，命令显式指定 namespace。Helm release 固定名 `tempo`。示例不会自动修改现有平台。

```bash
export TEMPO_NAMESPACE='<目标 namespace>'
python -m pip install -r scripts/tempo/requirements.txt
cp environment.example.json environment.local.json
# 编辑参数；端口保持 JSON 整数，Secret 不在此文件填写
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
helm search repo grafana-community/tempo-distributed --versions
helm show chart charts/tempo/tempo-distributed-3.11.1.tgz
python scripts/tempo/render.py environment.local.json
```

渲染执行 lint/template，校验包 SHA256、8 个新架构 target、镜像版本和参数。预期 `Rendered ... workloads`，否则先修复，不得直接部署。

| 步骤 | 目的 / 文件与命令 | 预期结果 / 失败排查 |
|---|---|---|
| 1 环境清单 | 按 02 填参数并记录平台版本 | 无占位符；查 DNS、UID、broker advertised listeners |
| 2 集群预检 | `bash scripts/tempo/preflight-check.sh` | 两 AZ、SC、CRD 存在且 RBAC 允许；检查 context/配额/CNI |
| 3 依赖检查 | 按 05 执行 Kafka describe、S3 canary、Prometheus flags | 凭据/网络/容量正常；查 TLS SAN/CA/ACL/策略 |
| 4 Namespace/Secret | 执行下方准备命令 | 对象位于正确 namespace；查权限与证书格式 |
| 5 MinIO | 平台方按 05 建独立 Bucket/账号 | canary PUT/GET/DELETE 通过；查 policy |
| 6 Kafka | 平台方执行 scripts/kafka/create-topic.sh | Topic 分区数、RF=3、ISR>=2；查 broker 容量和 ACL |
| 7 Values | 审阅 build/charts/tempo/values-production.yaml 与 build/tempo-rendered.yaml | 外部依赖引用正确；无密码、无旧组件 |
| 8 Tempo | GATEWAY_MODE=reuse 时运行 install.sh 先部署 Tempo | `helm status` deployed，Pod Ready；查 Kafka/MinIO/调度 |
| 9 Gateway | 新建时 GATEWAY_MODE=new 重跑 install.sh；复用时审核合并 pipeline | Collector Ready；查证书/OTLP/exporter |
| 10 示例 | 构建并填写 DEMO_IMAGE；apply build/manifests/python-otel-demo/deployment.yaml | 两服务返回同一 ID；查 client mTLS/namespace label |
| 11 摄取 | demo /call，记录 ID；执行 validate.sh | 近期查询有跨服务 span；查队列/分区 |
| 12 持久化 | 06 的 backend-only 查询 | 同一 ID 从 MinIO 查出；查 builder/对象权限 |
| 13 抓取与规则 | Chart ServiceMonitor + manifests/tempo/prometheusrule.yaml | targets UP、规则载入；查双层 selector |
| 14 派生指标 | 05 的 Remote Write 最小变更，确认后再启用流量 | span metrics 可查；查 receiver、WAL、时间偏差 |
| 15 Grafana | 增量注册 build/integrations/grafana/datasources.yaml | Save & Test 成功；查查询端口和网络 |
| 16 ELK | 合并 mapping/data link，05 的日志查询 | trace_id 可检索；查 ingestion pipeline/time field |
| 17 全链验收 | 执行 06 全部检查并保存证据 | trace/metrics/log 全部通过；任何缺项不验收 |
| 18 压测演练 | 按 03/09，低风险窗口执行 | 达成约定 SLO/RPO/RTO；不满足则调参重测 |

第 13/14 步应在业务全面接入前完成；Collector 队列不能替代依赖准备。已存在 Gateway 时，禁止 `apply` 新的同名工作负载覆盖现网。

## 准备 Namespace 与 Secret

批准 namespace 和 rollout-operator 变更后：

```bash
kubectl -n "$TEMPO_NAMESPACE" apply -f build/manifests/tempo/namespace.yaml
# 由企业密钥系统写入受限临时文件 credentials.env（chmod 600，不入 Git）
# 包含 KAFKA_USERNAME、KAFKA_PASSWORD、MINIO_ACCESS_KEY、MINIO_SECRET_KEY
kubectl -n "$TEMPO_NAMESPACE" create secret generic tempo-credentials --from-env-file="$CREDENTIALS_FILE"
kubectl -n "$TEMPO_NAMESPACE" create secret generic tempo-ca \
  --from-file=kafka-ca.crt="$KAFKA_CA_FILE" --from-file=minio-ca.crt="$MINIO_CA_FILE"
kubectl -n "$TEMPO_NAMESPACE" create secret generic otel-gateway-tls \
  --from-file=ca.crt="$OTEL_CLIENT_CA_FILE" --from-file=tls.crt="$OTEL_SERVER_CERT_FILE" --from-file=tls.key="$OTEL_SERVER_KEY_FILE"
```

Collector 服务证书 SAN 必须含 `otel-gateway.<namespace>.svc.cluster.local`；应用使用不同的 client 证书。示例 Secret 仅说明结构，不能直接 apply。凭据 env 文件用完按企业流程清理，避免 shell history 写入实际密码。轮换后按组件逐步重启，旧凭据保留到消费者追平。

## 执行发布

```bash
export CHANGE_APPROVAL_ID='<审批单号>' GATEWAY_MODE='new' # 或 reuse
bash scripts/tempo/install.sh
helm -n "$TEMPO_NAMESPACE" status tempo
kubectl -n "$TEMPO_NAMESPACE" get pods,pvc
```

安装脚本不会替你创建 Kafka、MinIO、修改 Grafana 或 Prometheus。没有使用自动回滚：带状态组件/CRD 失败后需要先诊断，不能假设 --atomic 就能恢复外部状态。
首次安装的自定义资源需 CRD 先就绪；如 Helm discovery 报无匹配资源，由平台方先按包内 CRD 安装流程管理 CRD，再设置 rollout_operator.crds.enabled=false 并重新渲染。已有相同 CRD 时明确所有权，不能抢占其他 release。

新部署 NetworkPolicy 后，从未经授权 namespace 发起请求应失败，已授权 SDK/Grafana/Prometheus 应成功。为接入 namespace 加 `tracing-access=enabled` 标签属于现有资源变更，须由其负责人执行并记录。节点探针和 DNS 行为按 CNI 实测。

修改 Collector ConfigMap 不会自动热加载：`kubectl -n "$TEMPO_NAMESPACE" rollout restart deployment/otel-gateway`，观察旧 Pod 队列耗尽与终止时间；内存队列无法保证零丢失。

## 安装后查看效果

完成 Tempo/Collector 部署、Grafana 数据源注册，并产生测试请求后，就可以在现有 Grafana 查看链路。仅执行 `install.sh` 不会自动注册 Grafana 数据源、部署 demo 或产生业务流量，因此安装完成后页面暂时没有 trace 是正常的。服务图、指标和日志关联还分别依赖 Prometheus Remote Write 与原有 ELK 采集链路完成对接。

先按 `examples/python-otel-demo/README.md` 构建并推送镜像，将 DEMO_IMAGE、DEMO_NAMESPACE 写入 environment.local.json，重新执行 render。以下变量中的 namespace 必须与参数文件一致；示例使用专用测试 namespace，若已存在则跳过 create namespace。

```bash
export DEMO_NAMESPACE='<参数文件中的 DEMO_NAMESPACE>'
kubectl create namespace "$DEMO_NAMESPACE"
kubectl label namespace "$DEMO_NAMESPACE" tracing-access=enabled --overwrite
# 使用由 Collector 信任的客户端 CA 签发的客户端证书；CA_FILE 用于校验 Collector 服务端
kubectl -n "$DEMO_NAMESPACE" create secret generic otel-client-tls \
  --from-file=ca.crt="$OTEL_SERVER_CA_FILE" \
  --from-file=tls.crt="$OTEL_CLIENT_CERT_FILE" \
  --from-file=tls.key="$OTEL_CLIENT_KEY_FILE"
kubectl -n "$DEMO_NAMESPACE" apply -f build/manifests/python-otel-demo/deployment.yaml
kubectl -n "$DEMO_NAMESPACE" rollout status deployment/demo-a --timeout=5m
kubectl -n "$DEMO_NAMESPACE" rollout status deployment/demo-b --timeout=5m
kubectl -n "$DEMO_NAMESPACE" port-forward svc/demo-a 8080:8080
```

保持端口转发终端运行，在另一个终端执行：

```bash
curl --fail http://127.0.0.1:8080/call
# 连续产生一些请求，便于观察服务图和速率指标
for i in $(seq 1 20); do curl --fail --silent --show-error http://127.0.0.1:8080/call; sleep 1; done
```

预期响应包含 `trace_id` 和 `downstream.trace_id`，两者相同。进入现有 Grafana → Explore → 选择 Tempo 数据源，粘贴该 Trace ID 查询，应看到 demo-a 调用 demo-b 的链路、各 Span 的耗时和资源属性。也可以用 TraceQL `{ resource.service.name = "demo-a" }` 搜索，并选择覆盖测试时间的时间范围。异步消费存在可见性延迟，首次无结果时稍后重试，持续无结果按 07 排查。

指标与服务图需等待 generator 处理及 Remote Write 成功后再看；日志跳转还要求两个 demo 的 stdout 已被现有日志采集器送入 Elasticsearch。首次看到 trace 只说明基本链路可用，仍需按 06 执行后端存储查询，按 03/09 完成生产容量与故障验收。
