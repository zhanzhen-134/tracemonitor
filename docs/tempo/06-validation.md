# 验收与证据

发布必须分三层：本地静态验证、预生产运行验证、生产受控验收。本地通过不证明证书、ACL、网络、版本及容量可用。

1. 执行 `scripts/tempo/render.py`，保存 values/包 SHA256/渲染输出。用目标 Kubernetes 版本 kubeconform 校验内置资源；ServiceMonitor/PrometheusRule/rollout CRD 通过目标集群 `kubectl -n "$TEMPO_NAMESPACE" apply --dry-run=server -f <已审阅清单>` 验证。首次安装须先注册 CRD，再检查 CR。
2. 在有 Docker 的验证机提取 Collector ConfigMap 的 config.yaml；使用 `otel/opentelemetry-collector-contrib:0.135.0 validate --config=<挂载文件>` 校验，证书按最终路径只读挂载。Tempo 使用同版本镜像/真实配置在预生产启动全部 target，检查 unknown field、SASL、TLS、S3 与 RPC 日志；只执行 helm lint 无法验证应用配置。
3. `helm status tempo` 为 deployed；全部工作负载就绪、PVC Bound；必须包含 8 种 Tempo target，无 ingester/compactor。单可用区模式为一个 live-store StatefulSet（ordinal 0–2 各对应一个 partition，每个 ACTIVE partition 一个 owner）；双可用区模式为两个 live-store StatefulSet，每区 ordinal 0–2 对应相同 partition，ACTIVE partition 有两个 owner。builder 对 0–2 全覆盖。
4. 应用 namespace 加获批的 tracing-access=enabled 标签；部署两个 demo 服务，配置 mTLS。`kubectl -n "$DEMO_NAMESPACE" port-forward svc/demo-a 8080:8080`，另一个终端 `curl --fail http://127.0.0.1:8080/call`；保存响应 trace_id、下游 trace_id、开始/结束 epoch 秒。再调用 /error 确认错误状态。
5. `kubectl -n "$TEMPO_NAMESPACE" port-forward svc/tempo-query-frontend 3200:3200`；设 TEMPO_QUERY_URL=http://127.0.0.1:3200、TRACE_ID 后执行 validate.sh。允许 ingest 可见性延迟，最多按约定窗口重试；不能把空响应视为成功。

## 独立证明长期存储

等待 Block Builder 完成消费周期、S3 block 写入和 blocklist poll（默认分别约 5m 和 5m，但不可只按固定 sleep 判断）。检查 `tempo_block_builder_flushed_blocks` 增长、相关 partition offset 追平、MinIO 对象创建。随后使用 Querier 的调试 API 强制 **仅后端对象存储** 查询，不能把 mode 参数加在 Query Frontend 的公共路径上就假定生效：

```bash
# 单独终端保持此转发运行
kubectl -n "$TEMPO_NAMESPACE" port-forward svc/tempo-querier 3201:3200
# 在另一个终端执行
curl --fail --silent --show-error \
  "http://127.0.0.1:3201/querier/api/traces/$TRACE_ID?mode=blocks&start=$TRACE_START&end=$TRACE_END" \
  -o build/trace-backend.json
```

TRACE_START/END 为实际 trace 时间窗口 epoch 秒，可各放宽 60 秒。确认返回 span 非空、服务 A/B 的 span 与 parent 关系正确；同时保留近期查询和 backend-only 查询响应。默认 mode=all 查到不能证明 S3 可用。不要通过删除 Live Store PVC 来证明持久化。

## 指标、日志和界面

Prometheus `/api/v1/targets` 中 Tempo 与 Collector targets UP；规则列表存在本仓库 alert；查询入口 accepted/refused、exported/failed span、queue，以及 Kafka lag。采样/重复传输会影响计数，不能简单要求所有计数完全相等。
查询 span metrics 与 service graph；Grafana Service Map 有 demo-a→demo-b 边，TraceQL `{ resource.service.name = "demo-a" }` 返回目标 trace。`/error` trace 为 ERROR。指标查询 `sum(rate(traces_spanmetrics_calls_total[5m]))` 有结果，exemplar 启用时点击可跳到同一 trace。
在 ES 用 `trace_id:"<真实ID>"` 查询，得到两个服务日志；Trace→logs 打开相同 ID、合理时间窗口；日志返回 trace 依据实际 Grafana 能力验收。受限 namespace 无法绕过入口访问 Distributor；未受信客户端证书握手失败。

证据清单：版本/哈希、变更单、资源与 topic describe、TLS/ACL/S3 canary 结果、trace ID/时间窗口、recent/backend JSON、Prometheus 查询、Grafana 截图、ES 查询、压测报告、故障恢复耗时与丢失统计。真实 trace 可能含敏感信息，build 仅保存在受限目录，不提交 Git。
