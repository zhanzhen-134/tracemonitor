# 两服务验收示例

构建 `docker build -t <REGISTRY>/python-otel-demo:1.0.0 examples/python-otel-demo`，推送到企业仓库，扫描后在 `manifests/python-otel-demo/deployment.yaml` 替换镜像占位符。
`requirements.lock` 固定直接与传递依赖；生产构建还应补充企业审核的包哈希与镜像 digest。本示例只用于受控验收，未在生产集群运行。
先在测试 namespace 创建 `otel-client-tls`（ca.crt、tls.crt、tls.key），客户端证书由 Collector 信任的 CA 签发。
仅部署一次模板生成的 demo-a、demo-b；入口 `/call` 自动传播 W3C traceparent/tracestate，返回当前 Trace ID 和下游 ID，两者应相同。
`/error` 返回 500 并产生 ERROR span。stdout JSON 继续由原有日志采集链路进入 ELK。
`/healthz` 不记录 span。不要使用 gunicorn --preload，避免 fork 已启动的 SDK 导出线程。

Kafka 业务消息传播：producer 使用 `opentelemetry.propagate.inject(carrier)`，将字符串 carrier 编码为 UTF-8 Kafka headers；consumer 解码 headers，使用 `extract(carrier)` 并以该 context 开启 `SpanKind.CONSUMER` span。
批处理多个来源时用 Span Links 关联各消息 context，不能将多个 traceparent 合并为一个父节点。手动传播与 Kafka 自动埋点二选一，避免重复 span。
这属于业务 Kafka Topic 的传播，与 Tempo 自己使用的二进制摄取 Topic 完全独立。
