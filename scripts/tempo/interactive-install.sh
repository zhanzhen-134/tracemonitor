#!/usr/bin/env bash
# Interactive installer that follows docs/tempo/04-installation.md end to end:
# Kafka/MinIO preparation -> Tempo + otel-gateway -> Prometheus Remote Write -> Grafana datasource
# -> OpenTelemetry Operator Java injection -> verifies Service Graph series exist in Prometheus.
# Every step can be skipped; answers are saved to build/install-state.env so the script can be re-run.
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash: keep in-container paths untouched

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
mkdir -p build/secrets && chmod 700 build/secrets
STATE="$ROOT/build/install-state.env"
SECRETS="$ROOT/build/secrets"
PROM_LP=19090 GRAFANA_LP=13000 GW_LP=18888
OPERATOR_CHART_VERSION=0.96.0

STATE_VARS=(TEMPO_NAMESPACE MONITORING_NAMESPACE GRAFANA_NAMESPACE PROMETHEUS_RELEASE KPS_VERSION
  PROMETHEUS_SVC PROMETHEUS_SVC_PORT PROMETHEUS_PORT PROMETHEUS_REMOTE_WRITE_URL ZONE_A ZONE_B STORAGE_CLASS
  CHANGE_APPROVAL_ID OTEL_OPERATOR_NAMESPACE KAFKA_NAMESPACE KAFKA_BOOTSTRAP KAFKA_PORT KAFKA_TOPIC
  KAFKA_SASL_MECHANISM KAFKA_TLS MINIO_NAMESPACE MINIO_ENDPOINT MINIO_PORT MINIO_BUCKET MINIO_TLS
  GRAFANA_SVC GRAFANA_SVC_PORT GRAFANA_DEPLOY PROMETHEUS_UID ELASTICSEARCH_UID SAMPLING_RATIO INJECTED)

# ---------- output helpers ----------
if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' C=$'\e[36m' N=$'\e[0m'; else B= G= Y= R= C= N=; fi
info() { echo "${C}==>${N} $*"; }
ok()   { echo "${G}[OK]${N} $*"; }
warn() { echo "${Y}[注意]${N} $*"; }
err()  { echo "${R}[错误]${N} $*" >&2; }
die()  { err "$*"; exit 1; }
run()  { echo "${B}+ $*${N}"; "$@"; }

# ---------- input helpers ----------
ask() {         # ask VAR "prompt" [default]
  local var=$1 prompt=$2 def=${3:-} ans cur
  cur="${!var:-$def}"
  read -r -p "$prompt${cur:+ [$cur]}: " ans
  ans="${ans:-$cur}"
  while [[ -z "$ans" ]]; do read -r -p "$prompt（必填）: " ans; done
  printf -v "$var" '%s' "$ans"
}
ask_secret() {  # ask_secret VAR "prompt"
  local var=$1 ans
  read -r -s -p "$2: " ans; echo
  printf -v "$var" '%s' "$ans"
}
confirm() { local a; read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^[Yy] ]]; }
pick() {        # pick VAR "prompt" item...   -> sets VAR to the chosen item
  local var=$1 prompt=$2; shift 2
  local items=("$@") i n def=1
  ((${#items[@]})) || die "$prompt：没有可选项"
  for i in "${!items[@]}"; do
    [[ "${items[$i]}" == "${!var:-}" ]] && def=$((i+1))
    echo "  $((i+1))) ${items[$i]}"
  done
  while true; do
    read -r -p "$prompt [$def]: " n; n="${n:-$def}"
    [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#items[@]})) && break
    echo "请输入 1-${#items[@]}"
  done
  printf -v "$var" '%s' "${items[$((n-1))]}"
}

# ---------- tool helpers ----------
PY=
py() { "$PY" "$@" | tr -d '\r'; }
jq_py() { py -c 'import json,sys; d=json.load(sys.stdin); exec(sys.argv[1])' "$1"; }   # jq_py 'print(d["x"])'
save_state() {
  : > "$STATE"
  local v
  for v in "${STATE_VARS[@]}"; do
    if [[ -n "${!v:-}" ]]; then printf '%s=%q\n' "$v" "${!v}" >> "$STATE"; fi
  done
}
declare -A PF_PID=()
pf() {          # pf NAMESPACE TARGET LOCAL_PORT REMOTE_PORT
  local ns=$1 target=$2 lp=$3 rp=$4 i
  if [[ -n "${PF_PID[$lp]:-}" ]] && kill -0 "${PF_PID[$lp]}" 2>/dev/null; then return 0; fi
  kubectl -n "$ns" port-forward "$target" "$lp:$rp" > "build/pf-$lp.log" 2>&1 &
  PF_PID[$lp]=$!
  for i in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$lp/"; then return 0; fi
    sleep 1
  done
  cat "build/pf-$lp.log" >&2
  die "端口转发失败：$ns $target"
}
pf_stop() { local lp=$1; if [[ -n "${PF_PID[$lp]:-}" ]]; then kill "${PF_PID[$lp]}" 2>/dev/null || true; unset "PF_PID[$lp]"; fi; }
cleanup() { local p; for p in "${PF_PID[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

promq() { curl -sS --get --data-urlencode "query=$1" "http://127.0.0.1:$PROM_LP/api/v1/query"; }
gapi()  { curl -sS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }
secret_val() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.${3//./\\.}}" | base64 -d; }

step() {        # step ID "title" function
  local id=$1 title=$2 fn=$3 a
  echo
  echo "${B}========== 步骤 $id：$title ==========${N}"
  read -r -p "回车执行 / s 跳过 / q 退出: " a
  case "$a" in
    s|S) warn "已跳过步骤 $id"; return 0 ;;
    q|Q) save_state; info "已保存进度到 $STATE，重新运行脚本可继续"; exit 0 ;;
  esac
  "$fn"
  save_state
  ok "步骤 $id 完成"
}

# ====================================================================================
# 1. Tools and cluster
# ====================================================================================
s_tools() {
  local t
  for t in kubectl helm curl openssl base64 diff; do
    command -v "$t" >/dev/null || die "缺少命令：$t"
  done
  for t in python3 python; do
    if command -v "$t" >/dev/null && "$t" -c 'import sys; sys.exit(sys.version_info < (3,9))' 2>/dev/null; then PY=$t; break; fi
  done
  [[ -n "$PY" ]] || die "需要 Python 3.9+"
  if ! "$PY" -c 'import yaml' 2>/dev/null; then
    confirm "未安装 PyYAML，现在执行 pip install -r scripts/tempo/requirements.txt？" || die "需要 PyYAML"
    run "$PY" -m pip install -r scripts/tempo/requirements.txt
  fi
  kubectl version --client=true 2>/dev/null | sed -n 1p
  helm version --short
  info "当前 kubeconfig 指向的集群（使用默认 context，不传 --context）："
  kubectl cluster-info | sed -n 1,2p
  kubectl get nodes -o wide | sed -n 1,10p
  confirm "这是要安装的目标集群吗？" || die "请先切换 kubeconfig 默认 context 后再运行"
}

# ====================================================================================
# 2. Parameters
# ====================================================================================
s_params() {
  ask TEMPO_NAMESPACE "Tempo namespace" tracemonitoring
  ask MONITORING_NAMESPACE "Prometheus 所在 namespace" monitoring
  ask GRAFANA_NAMESPACE "Grafana 所在 namespace" monitoring
  ask OTEL_OPERATOR_NAMESPACE "OpenTelemetry Operator namespace" opentelemetry-operator-system
  ask CHANGE_APPROVAL_ID "变更审批单号"

  info "Helm releases in $MONITORING_NAMESPACE："
  helm -n "$MONITORING_NAMESPACE" list
  local sel
  sel=$(kubectl -n "$MONITORING_NAMESPACE" get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector.matchLabels.release}' 2>/dev/null || true)
  [[ -n "$sel" ]] && info "Prometheus serviceMonitorSelector 要求标签 release=$sel"
  ask PROMETHEUS_RELEASE "PROMETHEUS_RELEASE（helm list 的 NAME 列，不是 CHART 列）" "${sel:-${PROMETHEUS_RELEASE:-}}"
  if [[ -n "$sel" && "$sel" != "$PROMETHEUS_RELEASE" ]]; then
    warn "与 serviceMonitorSelector 的 release=$sel 不一致，Prometheus 将不会抓取 Tempo"
    confirm "仍然使用 $PROMETHEUS_RELEASE？" || PROMETHEUS_RELEASE=$sel
  fi
  export PROMETHEUS_RELEASE
  KPS_VERSION=$(helm -n "$MONITORING_NAMESPACE" list -o json | jq_py '
import os
r=[x for x in d if x["name"]==os.environ["PROMETHEUS_RELEASE"]]
c=r[0]["chart"] if r else ""
print(c[len("kube-prometheus-stack-"):] if c.startswith("kube-prometheus-stack-") else "")')
  if [[ -z "$KPS_VERSION" ]]; then
    warn "release $PROMETHEUS_RELEASE 不是 kube-prometheus-stack，第 9 步需要手工开启 Remote Write receiver"
  else
    ok "kube-prometheus-stack 版本 $KPS_VERSION"
  fi

  local svcs
  mapfile -t svcs < <(kubectl -n "$MONITORING_NAMESPACE" get svc -o json | jq_py '
for s in d["items"]:
    if s["spec"].get("clusterIP") in (None, "None"): continue
    ps=[p["port"] for p in s["spec"].get("ports",[]) if p["port"]==9090 or p.get("name")=="http-web"]
    if ps and "prometheus" in s["metadata"]["name"] and "operator" not in s["metadata"]["name"]:
        print(s["metadata"]["name"])')
  ((${#svcs[@]})) || die "在 $MONITORING_NAMESPACE 中没有找到 Prometheus 的 ClusterIP Service（端口 9090）"
  pick PROMETHEUS_SVC "选择 Prometheus Service（不要选 prometheus-operated）" "${svcs[@]}"
  PROMETHEUS_SVC_PORT=$(kubectl -n "$MONITORING_NAMESPACE" get svc "$PROMETHEUS_SVC" -o jsonpath='{.spec.ports[0].port}')
  ask PROMETHEUS_PORT "Prometheus 容器端口（NetworkPolicy 使用）" 9090
  PROMETHEUS_REMOTE_WRITE_URL="http://$PROMETHEUS_SVC.$MONITORING_NAMESPACE.svc.cluster.local:$PROMETHEUS_SVC_PORT/api/v1/write"
  ok "Remote Write 地址：$PROMETHEUS_REMOTE_WRITE_URL"

  local zones scs
  mapfile -t zones < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | tr -d '\r' | sed '/^$/d' | sort -u)
  if ((${#zones[@]} < 2)); then
    die "节点只有 ${#zones[@]} 个可用区（topology.kubernetes.io/zone）。生产配置要求两个不同可用区，见 docs/tempo/02-prerequisites.md"
  fi
  pick ZONE_A "选择 ZONE_A" "${zones[@]}"
  pick ZONE_B "选择 ZONE_B（必须与 ZONE_A 不同）" "${zones[@]}"
  [[ "$ZONE_A" != "$ZONE_B" ]] || die "ZONE_A 与 ZONE_B 不能相同"

  kubectl get storageclass
  mapfile -t scs < <(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | tr -d '\r')
  pick STORAGE_CLASS "选择 StorageClass（需支持 RWO）" "${scs[@]}"
}

# ====================================================================================
# 5a. Kafka
# ====================================================================================
kafka_write_creds() { umask 077; printf 'KAFKA_USERNAME=%s\nKAFKA_PASSWORD=%s\n' "$1" "$2" > "$SECRETS/kafka.env"; }

kafka_strimzi() {
  local cluster listeners authz ver brokers replicas minisr
  cluster=$(kubectl -n "$KAFKA_NAMESPACE" get kafka -o jsonpath='{.items[0].metadata.name}')
  info "Strimzi Kafka 集群：$cluster"
  kubectl -n "$KAFKA_NAMESPACE" get kafka "$cluster" -o json | jq_py '
for l in d["spec"]["kafka"].get("listeners",[]):
    print("  监听器 %-10s port=%-5s type=%-9s tls=%-5s auth=%s" % (l["name"], l["port"], l["type"], l.get("tls"), (l.get("authentication") or {}).get("type")))'
  mapfile -t listeners < <(kubectl -n "$KAFKA_NAMESPACE" get kafka "$cluster" -o json | jq_py '
for l in d["spec"]["kafka"].get("listeners",[]):
    if l.get("tls") and (l.get("authentication") or {}).get("type")=="scram-sha-512" and l["type"] in ("internal","cluster-ip"):
        print("%s:%s" % (l["name"], l["port"]))')
  if ((${#listeners[@]} == 0)); then
    die "没有 tls=true、auth=scram-sha-512 的 internal 监听器。按 docs/tempo/04-installation.md 第 5.2 步 ① 增加监听器（会滚动重启 broker）后重新运行本步骤"
  fi
  local l; pick l "选择 Tempo 使用的监听器" "${listeners[@]}"
  KAFKA_PORT=${l##*:}
  KAFKA_BOOTSTRAP="$cluster-kafka-bootstrap.$KAFKA_NAMESPACE.svc.cluster.local:$KAFKA_PORT"
  KAFKA_SASL_MECHANISM=SCRAM-SHA-512 KAFKA_TLS=true

  kubectl -n "$KAFKA_NAMESPACE" get kafka "$cluster" -o jsonpath='{.spec.entityOperator.topicOperator}{"|"}{.spec.entityOperator.userOperator}' | grep -q '^{.*}|{.*}$' \
    || die "Kafka CR 未启用 entityOperator 的 topicOperator / userOperator，无法用 KafkaTopic / KafkaUser 创建"
  authz=$(kubectl -n "$KAFKA_NAMESPACE" get kafka "$cluster" -o jsonpath='{.spec.kafka.authorization.type}')
  ver=$(kubectl get crd kafkausers.kafka.strimzi.io -o jsonpath='{.spec.versions[?(@.served==true)].name}' | tr ' ' '\n' | grep -E '^v1beta2$|^v1$' | sed -n 1p)
  brokers=$(kubectl -n "$KAFKA_NAMESPACE" get pods -l "strimzi.io/cluster=$cluster,strimzi.io/broker-role=true" -o name | wc -l)
  ((brokers > 0)) || brokers=$(kubectl -n "$KAFKA_NAMESPACE" get pods -l "strimzi.io/cluster=$cluster,strimzi.io/kind=Kafka" -o name | wc -l)
  replicas=$(( brokers >= 3 ? 3 : brokers )); minisr=$(( replicas >= 3 ? 2 : 1 ))
  ((brokers >= 3)) || warn "broker 只有 $brokers 个，Topic 副本数降为 $replicas，不满足生产 RF=3 要求"

  local acl=""
  if [[ "$authz" == simple ]]; then
    acl="  authorization:
    type: simple
    acls:
    - resource: {type: topic, name: $KAFKA_TOPIC, patternType: literal}
      operations: [Read, Write, Describe]"
    local g
    for g in block-builder metrics-generator tempo-live-store-zone-a tempo-live-store-zone-b; do
      acl+="
    - resource: {type: group, name: $g, patternType: literal}
      operations: [Read, Describe]"
    done
  else
    warn "Kafka 未开启 simple 授权，不创建 ACL（任何认证用户都能访问该 Topic）"
  fi
  cat > "$SECRETS/kafka-tempo.yaml" <<EOF
apiVersion: kafka.strimzi.io/$ver
kind: KafkaTopic
metadata:
  name: $KAFKA_TOPIC
  namespace: $KAFKA_NAMESPACE
  labels:
    strimzi.io/cluster: $cluster
spec:
  partitions: 3
  replicas: $replicas
  config:
    min.insync.replicas: $minisr
    retention.ms: 86400000
    cleanup.policy: delete
    max.message.bytes: 16000000
---
apiVersion: kafka.strimzi.io/$ver
kind: KafkaUser
metadata:
  name: tempo
  namespace: $KAFKA_NAMESPACE
  labels:
    strimzi.io/cluster: $cluster
spec:
  authentication:
    type: scram-sha-512
$acl
EOF
  cat "$SECRETS/kafka-tempo.yaml"
  confirm "在 $KAFKA_NAMESPACE 中创建以上 KafkaTopic / KafkaUser？" || die "已取消"
  run kubectl apply --dry-run=server -f "$SECRETS/kafka-tempo.yaml"
  run kubectl apply -f "$SECRETS/kafka-tempo.yaml"
  run kubectl -n "$KAFKA_NAMESPACE" wait "kafkatopic/$KAFKA_TOPIC" kafkauser/tempo --for=condition=Ready --timeout=5m
  kafka_write_creds tempo "$(secret_val "$KAFKA_NAMESPACE" tempo password)"
  secret_val "$KAFKA_NAMESPACE" "$cluster-cluster-ca-cert" ca.crt > "$SECRETS/kafka-ca.crt"
}

kafka_cli() {
  local pods pod kbin bs proto mech admin_user admin_pass ts tempo_pass kx
  mapfile -t pods < <(kubectl -n "$KAFKA_NAMESPACE" get pods -o name | tr -d '\r' | grep -i kafka || true)
  pick pod "选择一个 Kafka broker Pod" "${pods[@]}"
  kx() { kubectl -n "$KAFKA_NAMESPACE" exec -i "$pod" -- "$@"; }
  info "broker 监听器相关环境变量："
  kx sh -c 'env | grep -iE "LISTENERS|SASL|SECURITY_PROTOCOL|AUTHORIZER" || true'
  kbin=$(kx sh -c 'for d in /opt/bitnami/kafka/bin /opt/kafka/bin /usr/bin; do [ -x $d/kafka-topics.sh ] && echo $d && break; done' | tr -d '\r')
  [[ -n "$kbin" ]] || die "Pod 内未找到 kafka-topics.sh"
  ok "Kafka CLI 目录：$kbin"
  pick proto "Tempo 连接使用的监听器协议" SASL_SSL SASL_PLAINTEXT PLAINTEXT
  ask bs "Pod 内可用的该监听器地址 host:port（如 localhost:9093）"
  ask KAFKA_BOOTSTRAP "Tempo 使用的 bootstrap（<Service>.$KAFKA_NAMESPACE.svc.cluster.local:<端口>）"
  ask KAFKA_PORT "broker 容器端口（NetworkPolicy 使用）" "${KAFKA_BOOTSTRAP##*:}"
  KAFKA_TLS=false; [[ "$proto" == SASL_SSL ]] && KAFKA_TLS=true

  local conf="security.protocol=$proto"
  if [[ "$proto" != PLAINTEXT ]]; then
    pick mech "SASL 机制" SCRAM-SHA-512 SCRAM-SHA-256 PLAIN
    ask admin_user "Kafka 管理员用户名"
    ask_secret admin_pass "Kafka 管理员密码"
    local module=org.apache.kafka.common.security.scram.ScramLoginModule
    [[ "$mech" == PLAIN ]] && module=org.apache.kafka.common.security.plain.PlainLoginModule
    conf+=$'\n'"sasl.mechanism=$mech"$'\n'"sasl.jaas.config=$module required username=\"$admin_user\" password=\"$admin_pass\";"
  else
    mech=PLAIN
  fi
  if [[ "$KAFKA_TLS" == true ]]; then
    ask ts "Pod 内 PEM 格式 CA 文件路径（如 /opt/bitnami/kafka/config/certs/kafka.truststore.pem）"
    conf+=$'\n'"ssl.truststore.type=PEM"$'\n'"ssl.truststore.location=$ts"
  fi
  printf '%s\n' "$conf" | kx sh -c 'umask 077; cat > /tmp/tempo-admin.properties'
  local K=("--bootstrap-server" "$bs" "--command-config" /tmp/tempo-admin.properties)
  run kx "$kbin/kafka-topics.sh" "${K[@]}" --list >/dev/null || die "管理员连接 Kafka 失败，检查地址、账号和 CA"
  ok "管理员连接正常"

  kx "$kbin/kafka-configs.sh" "${K[@]}" --describe --entity-type brokers --entity-default --all 2>/dev/null \
    | grep -E ' (message.max.bytes|replica.fetch.max.bytes)=' || true
  if confirm "将 broker 默认 message.max.bytes / replica.fetch.max.bytes 调整为 16000000（已 ≥ 该值则选 N）？"; then
    run kx "$kbin/kafka-configs.sh" "${K[@]}" --alter --entity-type brokers --entity-default \
      --add-config message.max.bytes=16000000,replica.fetch.max.bytes=16000000
  fi

  KAFKA_SASL_MECHANISM=$mech
  if [[ "$proto" == PLAINTEXT ]]; then
    kafka_write_creds "" ""
  elif [[ "$mech" == PLAIN ]]; then
    warn "PLAIN 机制无法动态创建用户，请输入已在 broker JAAS 中配置好的 Tempo 账号"
    local u p; ask u "Tempo Kafka 用户名" tempo; ask_secret p "Tempo Kafka 密码"
    kafka_write_creds "$u" "$p"
  else
    tempo_pass=$(openssl rand -base64 24 | tr -d '/+=\r\n')
    echo "+ kafka-configs.sh --alter --entity-type users --entity-name tempo --add-config $mech=[password=***]"
    kx "$kbin/kafka-configs.sh" "${K[@]}" --alter --entity-type users --entity-name tempo \
      --add-config "$mech=[password=$tempo_pass]"
    kafka_write_creds tempo "$tempo_pass"
  fi

  if kx "$kbin/kafka-topics.sh" "${K[@]}" --describe --topic "$KAFKA_TOPIC" >/dev/null 2>&1; then
    warn "Topic $KAFKA_TOPIC 已存在，沿用（请确认分区数与副本数）"
  else
    run kx "$kbin/kafka-topics.sh" "${K[@]}" --create --topic "$KAFKA_TOPIC" --partitions 3 --replication-factor 3 \
      --config min.insync.replicas=2 --config retention.ms=86400000 --config cleanup.policy=delete --config max.message.bytes=16000000
  fi
  if [[ "$proto" != PLAINTEXT ]]; then
    if kx "$kbin/kafka-acls.sh" "${K[@]}" --list >/dev/null 2>&1; then
      run kx "$kbin/kafka-acls.sh" "${K[@]}" --add --allow-principal User:tempo \
        --operation Read --operation Write --operation Describe --topic "$KAFKA_TOPIC"
      local g
      for g in block-builder metrics-generator tempo-live-store-zone-a tempo-live-store-zone-b; do
        run kx "$kbin/kafka-acls.sh" "${K[@]}" --add --allow-principal User:tempo --operation Read --operation Describe --group "$g"
      done
    else
      warn "Kafka 未开启授权，跳过 ACL"
    fi
  fi
  kx "$kbin/kafka-topics.sh" "${K[@]}" --describe --topic "$KAFKA_TOPIC"
  if [[ "$KAFKA_TLS" == true ]]; then kx cat "$ts" | tr -d '\r' > "$SECRETS/kafka-ca.crt"; else echo '# not used' > "$SECRETS/kafka-ca.crt"; fi
  kx rm -f /tmp/tempo-admin.properties
}

kafka_manual() {
  ask KAFKA_BOOTSTRAP "Tempo 使用的 bootstrap host:port"
  ask KAFKA_PORT "broker 容器端口" "${KAFKA_BOOTSTRAP##*:}"
  pick KAFKA_SASL_MECHANISM "SASL 机制（无 SASL 选 PLAIN 并把用户名密码留空）" SCRAM-SHA-512 SCRAM-SHA-256 PLAIN
  pick KAFKA_TLS "是否 TLS" true false
  local u p f
  read -r -p "Tempo Kafka 用户名（无 SASL 直接回车）: " u
  ask_secret p "Tempo Kafka 密码（无 SASL 直接回车）"
  kafka_write_creds "$u" "$p"
  if [[ "$KAFKA_TLS" == true ]]; then ask f "Kafka CA 文件本地路径"; cp "$f" "$SECRETS/kafka-ca.crt"; else echo '# not used' > "$SECRETS/kafka-ca.crt"; fi
}

s_kafka() {
  kubectl get ns | grep -iE 'kafka|strimzi|mq' || true
  ask KAFKA_NAMESPACE "Kafka 所在 namespace"
  ask KAFKA_TOPIC "Tempo 专用 Topic 名" tempo-traces
  local mode
  if kubectl get crd kafkas.kafka.strimzi.io >/dev/null 2>&1 && [[ -n "$(kubectl -n "$KAFKA_NAMESPACE" get kafka -o name 2>/dev/null)" ]]; then
    info "检测到 Strimzi 管理的 Kafka"
    pick mode "Kafka 准备方式" "Strimzi（KafkaTopic / KafkaUser）" "已手工准备好，直接输入参数"
  else
    info "未检测到 Strimzi，将在 broker Pod 内执行 Kafka CLI"
    pick mode "Kafka 准备方式" "在 broker Pod 内用 CLI 创建" "已手工准备好，直接输入参数"
  fi
  case "$mode" in
    Strimzi*) kafka_strimzi ;;
    在*) kafka_cli ;;
    *) kafka_manual ;;
  esac
  chmod 600 "$SECRETS"/kafka*
  ok "Kafka：bootstrap=$KAFKA_BOOTSTRAP mechanism=$KAFKA_SASL_MECHANISM tls=$KAFKA_TLS topic=$KAFKA_TOPIC"
}

# ====================================================================================
# 5b. MinIO
# ====================================================================================
minio_write_creds() { umask 077; printf 'MINIO_ACCESS_KEY=%s\nMINIO_SECRET_KEY=%s\n' "$1" "$2" > "$SECRETS/minio.env"; }

s_minio() {
  kubectl get ns | grep -iE 'minio|s3|storage' || true
  ask MINIO_NAMESPACE "MinIO 所在 namespace"
  ask MINIO_BUCKET "Tempo 专用 bucket" tempo-traces
  local mode
  pick mode "MinIO 准备方式" "自动创建 bucket / 账号 / 策略" "已手工准备好，直接输入参数"
  if [[ "$mode" == 已* ]]; then
    local a s f
    ask MINIO_ENDPOINT "S3 endpoint host:port（不含 https://）"
    ask MINIO_PORT "MinIO 容器端口" "${MINIO_ENDPOINT##*:}"
    pick MINIO_TLS "是否 TLS" true false
    ask a "Tempo access key"; ask_secret s "Tempo secret key"
    minio_write_creds "$a" "$s"
    if [[ "$MINIO_TLS" == true ]]; then ask f "MinIO CA 文件本地路径"; cp "$f" "$SECRETS/minio-ca.crt"; else echo '# not used' > "$SECRETS/minio-ca.crt"; fi
    return
  fi

  local pods pod podjson ctr root_user root_pass svcs svc svcport certdir host scheme mcbin
  mapfile -t pods < <(kubectl -n "$MINIO_NAMESPACE" get pods -o name | tr -d '\r' | grep -iv console || true)
  pick pod "选择 MinIO 服务端 Pod" "${pods[@]}"
  podjson=$(kubectl -n "$MINIO_NAMESPACE" get "$pod" -o json)
  ctr=$(jq_py '
cs=d["spec"]["containers"]
m=[c["name"] for c in cs if "minio" in c["image"] and "/mc" not in c["image"]]
print(m[0] if m else cs[0]["name"])' <<<"$podjson")
  # root credentials: env value, env secretKeyRef, or operator config.env
  read -r root_user root_pass < <(jq_py '
import base64,subprocess
c=[c for c in d["spec"]["containers"] if c["name"]=="'"$ctr"'"][0]
def val(names):
    for e in c.get("env",[]):
        if e["name"] in names:
            if "value" in e: return e["value"]
            r=(e.get("valueFrom") or {}).get("secretKeyRef")
            if r:
                out=subprocess.run(["kubectl","-n",d["metadata"]["namespace"],"get","secret",r["name"],"-o","jsonpath={.data."+r["key"].replace(".","\\.")+"}"],capture_output=True,text=True).stdout
                return base64.b64decode(out).decode() if out else ""
    return ""
print(val(["MINIO_ROOT_USER","MINIO_ACCESS_KEY"]) or "-", val(["MINIO_ROOT_PASSWORD","MINIO_SECRET_KEY"]) or "-")' <<<"$podjson")
  if [[ "$root_user" == - || "$root_pass" == - ]]; then
    local envfile
    envfile=$(kubectl -n "$MINIO_NAMESPACE" exec "$pod" -c "$ctr" -- sh -c 'f=${MINIO_CONFIG_ENV_FILE:-}; [ -n "$f" ] && cat "$f"' 2>/dev/null | tr -d '\r' || true)
    root_user=$(sed -n 's/^export MINIO_ROOT_USER="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$envfile")
    root_pass=$(sed -n 's/^export MINIO_ROOT_PASSWORD="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$envfile")
  fi
  if [[ -z "$root_user" || "$root_user" == - ]]; then
    warn "未能自动取得 MinIO root 账号"
    ask root_user "MinIO root 用户名"; ask_secret root_pass "MinIO root 密码"
  else
    ok "已从 Pod 配置取得 MinIO root 账号：$root_user"
  fi

  mapfile -t svcs < <(kubectl -n "$MINIO_NAMESPACE" get svc -o json | jq_py '
for s in d["items"]:
    for p in s["spec"].get("ports",[]):
        if p["port"] in (9000,443,80) or "api" in (p.get("name") or "") or "s3" in (p.get("name") or ""):
            print("%s:%s" % (s["metadata"]["name"], p["port"])); break')
  pick svc "选择 S3 API Service:端口" "${svcs[@]}"
  svcport=${svc##*:}; svc=${svc%%:*}
  MINIO_ENDPOINT="$svc.$MINIO_NAMESPACE.svc.cluster.local:$svcport"
  ask MINIO_PORT "MinIO S3 容器端口（NetworkPolicy 使用）" 9000

  certdir=$(kubectl -n "$MINIO_NAMESPACE" exec "$pod" -c "$ctr" -- sh -c 'for d in /etc/minio/certs /opt/bitnami/minio/certs /tmp/certs "$HOME/.minio/certs"; do [ -f "$d/public.crt" ] && echo "$d" && break; done' | tr -d '\r' || true)
  if [[ -n "$certdir" ]]; then
    MINIO_TLS=true scheme=https
    kubectl -n "$MINIO_NAMESPACE" exec "$pod" -c "$ctr" -- sh -c "cat $certdir/CAs/*.crt 2>/dev/null || true" | tr -d '\r' > "$SECRETS/minio-ca.crt"
    kubectl -n "$MINIO_NAMESPACE" exec "$pod" -c "$ctr" -- cat "$certdir/public.crt" | tr -d '\r' > "$SECRETS/minio-public.crt"
    if [[ ! -s "$SECRETS/minio-ca.crt" ]]; then
      if [[ "$(openssl x509 -in "$SECRETS/minio-public.crt" -noout -subject | sed 's/^subject=//')" == "$(openssl x509 -in "$SECRETS/minio-public.crt" -noout -issuer | sed 's/^issuer=//')" ]]; then
        cp "$SECRETS/minio-public.crt" "$SECRETS/minio-ca.crt"
      else
        kubectl get cm kube-root-ca.crt -n "$MINIO_NAMESPACE" -o jsonpath='{.data.ca\.crt}' > "$SECRETS/minio-ca.crt"
      fi
    fi
    openssl verify -CAfile "$SECRETS/minio-ca.crt" "$SECRETS/minio-public.crt" || die "无法确定 MinIO 证书的 CA，请改用“已手工准备好”方式并提供 CA 文件"
    openssl x509 -in "$SECRETS/minio-public.crt" -noout -ext subjectAltName | grep -q "$svc" \
      || warn "MinIO 证书 SAN 中未包含 $svc，Tempo 连接时会证书校验失败，需要为 MinIO 重新签发证书"
  else
    MINIO_TLS=false scheme=http
    warn "MinIO 未启用 TLS，Tempo 将以明文访问（insecure: true）"
    echo '# not used' > "$SECRETS/minio-ca.crt"
  fi
  host="$scheme://$MINIO_ENDPOINT"

  # mc: inside the MinIO container if present, otherwise a temporary mc Pod
  local mpod=$pod mctr=$ctr
  mcbin=$(kubectl -n "$MINIO_NAMESPACE" exec "$pod" -c "$ctr" -- sh -c 'command -v mc || ls /opt/bitnami/minio-client/bin/mc 2>/dev/null' | tr -d '\r' || true)
  if [[ -z "$mcbin" ]]; then
    local img; ask img "MinIO 容器内没有 mc，输入可拉取的 mc 镜像（如 quay.io/minio/mc:RELEASE.<固定版本>）"
    run kubectl -n "$MINIO_NAMESPACE" run tempo-mc --image="$img" --restart=Never --command -- sleep 3600
    run kubectl -n "$MINIO_NAMESPACE" wait pod/tempo-mc --for=condition=Ready --timeout=3m
    mpod=pod/tempo-mc mctr=tempo-mc mcbin=mc
  fi
  mx() { kubectl -n "$MINIO_NAMESPACE" exec -i "$mpod" -c "$mctr" -- env MC_CONFIG_DIR=/tmp/.mc "$@"; }
  mx sh -c 'mkdir -p /tmp/.mc/certs/CAs && cat > /tmp/.mc/certs/CAs/ca.crt' < "$SECRETS/minio-ca.crt"
  mx "$mcbin" alias set admin "$host" "$root_user" "$root_pass" >/dev/null
  run mx "$mcbin" admin info admin
  run mx "$mcbin" mb --ignore-existing "admin/$MINIO_BUCKET"
  sed "s/<MINIO_BUCKET>/$MINIO_BUCKET/g" integrations/minio/policy.json | mx sh -c 'cat > /tmp/tempo-policy.json'
  mx "$mcbin" admin policy create admin tempo-rw /tmp/tempo-policy.json 2>/dev/null \
    || run mx "$mcbin" admin policy add admin tempo-rw /tmp/tempo-policy.json
  local tempo_secret
  tempo_secret=$(openssl rand -base64 30 | tr -d '/+=\r\n')
  echo "+ mc admin user add admin tempo ***"
  mx "$mcbin" admin user add admin tempo "$tempo_secret" >/dev/null
  mx "$mcbin" admin policy attach admin tempo-rw --user tempo 2>/dev/null \
    || mx "$mcbin" admin policy set admin tempo-rw user=tempo 2>/dev/null || true
  minio_write_creds tempo "$tempo_secret"

  info "用 Tempo 账号做 PUT / GET / DELETE canary"
  mx "$mcbin" alias set tempo "$host" tempo "$tempo_secret" >/dev/null
  mx sh -c 'echo tempo-probe > /tmp/probe.txt'
  run mx "$mcbin" cp /tmp/probe.txt "tempo/$MINIO_BUCKET/_acceptance/probe.txt"
  [[ "$(mx "$mcbin" cat "tempo/$MINIO_BUCKET/_acceptance/probe.txt" | tr -d '\r')" == tempo-probe ]] || die "canary 读取失败"
  run mx "$mcbin" rm "tempo/$MINIO_BUCKET/_acceptance/probe.txt"
  ok "canary 通过"
  mx rm -rf /tmp/.mc /tmp/tempo-policy.json /tmp/probe.txt
  if [[ "$mpod" == pod/tempo-mc ]]; then kubectl -n "$MINIO_NAMESPACE" delete pod tempo-mc --wait=false; fi
  chmod 600 "$SECRETS"/minio*
  ok "MinIO：endpoint=$MINIO_ENDPOINT bucket=$MINIO_BUCKET tls=$MINIO_TLS"
}

# ====================================================================================
# Grafana connection + datasource UIDs (needed before render)
# ====================================================================================
grafana_connect() {
  if [[ -z "${GRAFANA_SVC:-}" ]]; then
    GRAFANA_SVC=$(kubectl -n "$GRAFANA_NAMESPACE" get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    GRAFANA_DEPLOY=$(kubectl -n "$GRAFANA_NAMESPACE" get deploy -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi
  ask GRAFANA_SVC "Grafana Service 名" "${GRAFANA_SVC:-}"
  ask GRAFANA_DEPLOY "Grafana Deployment 名" "${GRAFANA_DEPLOY:-$GRAFANA_SVC}"
  GRAFANA_SVC_PORT=$(kubectl -n "$GRAFANA_NAMESPACE" get svc "$GRAFANA_SVC" -o jsonpath='{.spec.ports[0].port}')
  if [[ -z "${GRAFANA_ADMIN_USER:-}" ]]; then
    GRAFANA_ADMIN_USER=$(secret_val "$GRAFANA_NAMESPACE" "$GRAFANA_SVC" admin-user 2>/dev/null || true)
    GRAFANA_ADMIN_PASSWORD=$(secret_val "$GRAFANA_NAMESPACE" "$GRAFANA_SVC" admin-password 2>/dev/null || true)
    if [[ -z "$GRAFANA_ADMIN_USER" ]]; then
      ask GRAFANA_ADMIN_USER "Grafana 管理员用户名" admin; ask_secret GRAFANA_ADMIN_PASSWORD "Grafana 管理员密码"
    fi
  fi
  pf "$GRAFANA_NAMESPACE" "svc/$GRAFANA_SVC" "$GRAFANA_LP" "$GRAFANA_SVC_PORT"
  gapi "http://127.0.0.1:$GRAFANA_LP/api/datasources" | jq_py 'print(len(d))' >/dev/null \
    || die "Grafana API 认证失败，请检查管理员账号"
}

s_grafana_uids() {
  grafana_connect
  local ds proms ess
  ds=$(gapi "http://127.0.0.1:$GRAFANA_LP/api/datasources")
  mapfile -t proms < <(jq_py 'for x in d:
    if x["type"]=="prometheus": print("%s | %s | %s" % (x["uid"], x["name"], x["url"]))' <<<"$ds")
  mapfile -t ess < <(jq_py 'for x in d:
    if x["type"]=="elasticsearch": print("%s | %s | %s" % (x["uid"], x["name"], x["url"]))' <<<"$ds")
  info "应选择 URL 指向 $PROMETHEUS_SVC 的 Prometheus 数据源"
  local p; p=$(printf '%s\n' "${proms[@]}" | grep -m1 "$PROMETHEUS_SVC" || true)
  pick p "选择 Service Graph 使用的 Prometheus 数据源" "${proms[@]}"
  PROMETHEUS_UID=${p%% |*}
  if ((${#ess[@]})); then
    local e; pick e "选择 Trace→Logs 使用的 Elasticsearch 数据源" "${ess[@]}" "暂不配置"
    if [[ "$e" == 暂不配置 ]]; then ELASTICSEARCH_UID=elasticsearch-not-configured; else ELASTICSEARCH_UID=${e%% |*}; fi
  else
    warn "Grafana 中还没有 Elasticsearch 数据源，Trace→Logs 暂不可用（不影响 Service Graph），之后按手册第 14 步配置"
    ELASTICSEARCH_UID=elasticsearch-not-configured
  fi
  ok "PROMETHEUS_UID=$PROMETHEUS_UID ELASTICSEARCH_UID=$ELASTICSEARCH_UID"
}

# ====================================================================================
# 3/4. Render, adapt for plaintext dependencies, preflight
# ====================================================================================
s_render() {
  export KAFKA_TLS MINIO_TLS TEMPO_NAMESPACE STORAGE_CLASS KAFKA_BOOTSTRAP KAFKA_TOPIC KAFKA_SASL_MECHANISM MINIO_ENDPOINT MINIO_BUCKET \
    PROMETHEUS_REMOTE_WRITE_URL PROMETHEUS_RELEASE ZONE_A ZONE_B MONITORING_NAMESPACE GRAFANA_NAMESPACE \
    KAFKA_NAMESPACE MINIO_NAMESPACE PROMETHEUS_UID ELASTICSEARCH_UID KAFKA_PORT MINIO_PORT PROMETHEUS_PORT
  py - <<'EOF'
import json, os
example = json.load(open('environment.example.json', encoding='utf-8-sig'))
env = {}
for k, v in example.items():
    if k in ('DEMO_NAMESPACE', 'DEMO_IMAGE'):
        env[k] = ''
    elif isinstance(v, int):
        env[k] = int(os.environ[k])
    else:
        env[k] = os.environ[k]
json.dump(env, open('environment.local.json', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
EOF
  ok "已写入 environment.local.json"
  run py scripts/tempo/render.py environment.local.json
  # Plaintext in-cluster dependencies: adjust the rendered Tempo values (docs 5.4 / 5.7).
  py - <<'EOF'
import os, yaml
p = 'build/charts/tempo/values-production.yaml'
v = yaml.safe_load(open(p, encoding='utf-8'))
if os.environ['KAFKA_TLS'] != 'true':
    k = v['tempo']['structuredConfig']['ingest']['kafka']
    k['tls_enabled'] = False; k.pop('tls_ca_path', None)
    print('Kafka: TLS disabled in rendered values')
if os.environ['MINIO_TLS'] != 'true':
    s = v['storage']['trace']['s3']
    s['insecure'] = True; s.pop('tls_ca_path', None)
    print('MinIO: insecure (HTTP) in rendered values')
yaml.safe_dump(v, open(p, 'w', encoding='utf-8'), sort_keys=False, allow_unicode=True)
EOF
  grep -n -A3 'processors:' build/tempo-rendered.yaml | sed -n 1,4p
}

s_preflight() {
  export TEMPO_NAMESPACE
  run bash scripts/tempo/preflight-check.sh
}

# ====================================================================================
# 6. Namespace, gateway certificate, Secrets
# ====================================================================================
s_secrets() {
  run kubectl apply -f build/manifests/tempo/namespace.yaml
  if [[ ! -f "$SECRETS/otel-server.crt" ]]; then
    info "生成 otel-gateway CA 与服务端证书"
    (
      cd "$SECRETS"
      openssl req -x509 -newkey rsa:4096 -nodes -days 1095 -subj "/CN=otel-gateway-ca" -keyout otel-ca.key -out otel-ca.crt 2>/dev/null
      openssl req -newkey rsa:2048 -nodes -subj "/CN=otel-gateway" -keyout otel-server.key -out otel-server.csr 2>/dev/null
      printf 'subjectAltName=DNS:otel-gateway,DNS:otel-gateway.%s.svc,DNS:otel-gateway.%s.svc.cluster.local\nextendedKeyUsage=serverAuth\n' \
        "$TEMPO_NAMESPACE" "$TEMPO_NAMESPACE" > otel-server.ext
      openssl x509 -req -in otel-server.csr -CA otel-ca.crt -CAkey otel-ca.key -CAcreateserial -days 365 \
        -extfile otel-server.ext -out otel-server.crt 2>/dev/null
      chmod 600 ./*
    )
  fi
  [[ -f "$SECRETS/kafka.env" && -f "$SECRETS/minio.env" ]] || die "缺少 Kafka / MinIO 凭据，请先执行步骤 5"
  cat "$SECRETS/kafka.env" "$SECRETS/minio.env" > "$SECRETS/credentials.env"; chmod 600 "$SECRETS/credentials.env"
  apply_secret() { kubectl -n "$TEMPO_NAMESPACE" create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -; }
  apply_secret tempo-credentials --from-env-file="$SECRETS/credentials.env"
  apply_secret tempo-ca --from-file=kafka-ca.crt="$SECRETS/kafka-ca.crt" --from-file=minio-ca.crt="$SECRETS/minio-ca.crt"
  apply_secret otel-gateway-tls --from-file=ca.crt="$SECRETS/otel-ca.crt" \
    --from-file=tls.crt="$SECRETS/otel-server.crt" --from-file=tls.key="$SECRETS/otel-server.key"
  kubectl -n "$TEMPO_NAMESPACE" get secret tempo-credentials tempo-ca otel-gateway-tls
}

# ====================================================================================
# 7. Install Tempo + otel-gateway
# ====================================================================================
s_install() {
  export TEMPO_NAMESPACE CHANGE_APPROVAL_ID GATEWAY_MODE=new
  run bash scripts/tempo/install.sh
  kubectl -n "$TEMPO_NAMESPACE" get pods
  info "检查 Tempo 是否能连上 Kafka / MinIO（最近 5 分钟日志中的错误）"
  kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-block-builder --since=5m 2>/dev/null | grep -iE 'level=error|SASL|x509|AccessDenied' | tail -n 5 || true
  kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=5m 2>/dev/null | grep -iE 'level=error|SASL|x509' | tail -5 || true
}

# ====================================================================================
# 8. Prometheus scrape selectors (informational)
# ====================================================================================
s_scrape() {
  kubectl -n "$MONITORING_NAMESPACE" get prometheus -o json | jq_py '
p=d["items"][0]["spec"]
for k in ("serviceMonitorSelector","serviceMonitorNamespaceSelector","ruleSelector","ruleNamespaceSelector"):
    print("  %-32s %s" % (k, p.get(k)))'
  local nsl; nsl=$(kubectl -n "$MONITORING_NAMESPACE" get prometheus -o jsonpath='{.items[0].spec.serviceMonitorNamespaceSelector.matchLabels}')
  if [[ -n "$nsl" && "$nsl" != "{}" ]]; then
    warn "serviceMonitorNamespaceSelector 要求标签 $nsl"
    if confirm "给 $TEMPO_NAMESPACE 加上这些标签？"; then
      local kv
      for kv in $(jq_py 'print(" ".join("%s=%s" % i for i in d.items()))' <<<"$nsl"); do
        run kubectl label namespace "$TEMPO_NAMESPACE" "$kv" --overwrite
      done
    fi
  fi
  kubectl -n "$TEMPO_NAMESPACE" get servicemonitor,prometheusrule --show-labels
}

# ====================================================================================
# 9. Prometheus Remote Write receiver
# ====================================================================================
prom_connect() { pf "$MONITORING_NAMESPACE" "svc/$PROMETHEUS_SVC" "$PROM_LP" "$PROMETHEUS_SVC_PORT"; }
prom_flag() {    # call prom_connect first (port-forwards must start in the main shell, not in $(...))
  curl -sS "http://127.0.0.1:$PROM_LP/api/v1/status/flags" | jq_py 'print(d["data"].get("web.enable-remote-write-receiver","false"))'
}

s_remote_write() {
  local flag; prom_connect; flag=$(prom_flag)
  if [[ "$flag" == true ]]; then ok "Remote Write receiver 已开启"; else
    warn "Remote Write receiver 未开启（$flag）"
    if kubectl -n "$MONITORING_NAMESPACE" get prometheus -o yaml | grep -qiE 'argocd|fluxcd|kustomize.toolkit'; then
      warn "Prometheus 由 GitOps 管理：请在 GitOps 仓库的 values 中加入 prometheus.prometheusSpec.enableRemoteWriteReceiver: true 并同步"
      read -r -p "同步完成后按回车重新检查..." _
    else
      [[ -n "${KPS_VERSION:-}" ]] || die "非 kube-prometheus-stack，请手工开启 --web.enable-remote-write-receiver 后重新运行本步骤"
      run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
      run helm repo update prometheus-community >/dev/null
      helm -n "$MONITORING_NAMESPACE" get values "$PROMETHEUS_RELEASE" -o yaml > build/prometheus-before.yaml
      local H=(helm template "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" -n "$MONITORING_NAMESPACE" -f build/prometheus-before.yaml)
      "${H[@]}" > build/prometheus-current.yaml
      "${H[@]}" -f build/integrations/prometheus/values-remote-write.yaml > build/prometheus-after.yaml
      info "渲染差异（证书等随机内容可忽略，应能看到 enableRemoteWriteReceiver: true）："
      diff build/prometheus-current.yaml build/prometheus-after.yaml | grep -E '^[<>]' | grep -viE 'caBundle|tls\.(crt|key)|ca\.crt|checksum' | sed -n 1,20p || true
      confirm "执行 helm upgrade $PROMETHEUS_RELEASE（Prometheus 会滚动重启 1～2 分钟）？" || die "已取消"
      run helm -n "$MONITORING_NAMESPACE" upgrade "$PROMETHEUS_RELEASE" prometheus-community/kube-prometheus-stack \
        --version "$KPS_VERSION" -f build/prometheus-before.yaml -f build/integrations/prometheus/values-remote-write.yaml
      local cr; cr=$(kubectl -n "$MONITORING_NAMESPACE" get prometheus -o jsonpath='{.items[0].metadata.name}')
      pf_stop "$PROM_LP"; sleep 10
      run kubectl -n "$MONITORING_NAMESPACE" rollout status "statefulset/prometheus-$cr" --timeout=10m
    fi
    pf_stop "$PROM_LP"; prom_connect
    flag=$(prom_flag)
    [[ "$flag" == true ]] || die "receiver 仍未开启"
    ok "Remote Write receiver 已开启"
  fi
  info "metrics-generator 推送日志（最近 10 分钟，无 404/403/no such host 即正常）："
  kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=10m 2>/dev/null | grep -iE 'remote.?write|err' | tail -5 || true
}

# ====================================================================================
# 10. Grafana Tempo datasource
# ====================================================================================
s_grafana_ds() {
  grafana_connect
  local G="http://127.0.0.1:$GRAFANA_LP" existing sc label value scns
  existing=$(gapi "$G/api/datasources/uid/tempo" | jq_py 'print(d.get("type",""))' 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    warn "Grafana 中已有 uid=tempo 的数据源（type=$existing），将被更新"
    confirm "继续？" || die "已取消"
  fi
  # prints: LABEL LABEL_VALUE NAMESPACE(or -) KIND(container|init)
  sc=$(kubectl -n "$GRAFANA_NAMESPACE" get deploy "$GRAFANA_DEPLOY" -o json | jq_py '
s=d["spec"]["template"]["spec"]
for kind, cs in (("container", s.get("containers",[])), ("init", s.get("initContainers",[]))):
    for c in cs:
        if "datasource" in c["name"]:
            e={x["name"]:x.get("value","") for x in c.get("env",[])}
            print(e.get("LABEL","grafana_datasource"), e.get("LABEL_VALUE") or "1", e.get("NAMESPACE") or "-", kind)
            raise SystemExit')
  if [[ -n "$sc" ]]; then
    local kind
    read -r label value scns kind <<<"$sc"
    [[ "$scns" == - ]] && scns=""
    info "检测到 Grafana datasource sidecar（标签 $label=$value，监听 namespace：${scns:-本 namespace}）"
    local cmns=$GRAFANA_NAMESPACE
    if [[ -n "$scns" && "$scns" != ALL && ",$scns," != *",$GRAFANA_NAMESPACE,"* ]]; then cmns=${scns%%,*}; fi
    kubectl -n "$cmns" create configmap tempo-datasource \
      --from-file=tempo-datasource.yaml=build/integrations/grafana/datasources.yaml --dry-run=client -o yaml \
      | kubectl label --local -f - "$label=$value" -o yaml | kubectl -n "$cmns" apply -f -
    if [[ "$kind" == init ]]; then
      info "sidecar 以 initContainer 方式运行，需要重启 Grafana 才能加载"
      run kubectl -n "$GRAFANA_NAMESPACE" rollout restart "deployment/$GRAFANA_DEPLOY"
      run kubectl -n "$GRAFANA_NAMESPACE" rollout status "deployment/$GRAFANA_DEPLOY" --timeout=5m
      pf_stop "$GRAFANA_LP"; pf "$GRAFANA_NAMESPACE" "svc/$GRAFANA_SVC" "$GRAFANA_LP" "$GRAFANA_SVC_PORT"
    fi
    info "等待 sidecar 加载数据源（最长 3 分钟）"
    local i
    for i in $(seq 1 36); do
      [[ "$(gapi "$G/api/datasources/uid/tempo" | jq_py 'print(d.get("uid",""))' 2>/dev/null)" == tempo ]] && break
      sleep 5
    done
  else
    warn "未检测到 sidecar，通过 Grafana API 创建（Grafana 无持久化存储时，重启后需要重新运行本步骤）"
    local body
    body=$(py - <<'EOF'
import json, yaml
ds = yaml.safe_load(open('build/integrations/grafana/datasources.yaml', encoding='utf-8'))['datasources'][0]
print(json.dumps(ds).replace('$$', '$'))
EOF
)
    if [[ -n "$existing" ]]; then gapi -X PUT "$G/api/datasources/uid/tempo" -d "$body" >/dev/null
    else gapi -X POST "$G/api/datasources" -d "$body" >/dev/null; fi
  fi
  local ds; ds=$(gapi "$G/api/datasources/uid/tempo")
  [[ "$(jq_py 'print(d.get("uid",""))' <<<"$ds")" == tempo ]] || die "Grafana 中未出现 Tempo 数据源，检查 sidecar 日志：kubectl -n $GRAFANA_NAMESPACE logs deploy/$GRAFANA_DEPLOY -c grafana-sc-datasources"
  jq_py 'print("  url=%s serviceMap=%s nodeGraph=%s" % (d["url"], d["jsonData"].get("serviceMap"), d["jsonData"].get("nodeGraph")))' <<<"$ds"
  local health; health=$(gapi "$G/api/datasources/uid/tempo/health" || true)
  echo "  health: $health"
  [[ "$health" == *'"OK"'* ]] || warn "Tempo 数据源健康检查未通过：检查 Grafana 是否在 $GRAFANA_NAMESPACE、Tempo NetworkPolicy 是否放行该 namespace"
}

# ====================================================================================
# 11. OpenTelemetry Operator + Java Instrumentation
# ====================================================================================
s_operator() {
  local existing
  existing=$(kubectl get deploy -A -l app.kubernetes.io/name=opentelemetry-operator -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    warn "集群中已有 OpenTelemetry Operator："; echo "$existing"
    if confirm "复用现有 Operator（不安装新的）？"; then return 0; fi
  fi
  run helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
  run helm repo update open-telemetry >/dev/null
  helm template otel-operator open-telemetry/opentelemetry-operator --version "$OPERATOR_CHART_VERSION" \
    -n "$OTEL_OPERATOR_NAMESPACE" -f charts/otel-operator/values.yaml > build/otel-operator-rendered.yaml
  grep -A14 'name: mpod.kb.io' build/otel-operator-rendered.yaml | grep -q 'failurePolicy: Ignore' \
    || grep -B14 'name: mpod.kb.io' build/otel-operator-rendered.yaml | grep -q 'failurePolicy: Ignore' \
    || die "渲染结果中 Pod 注入 webhook 不是 Ignore，停止安装"
  ok "Pod 注入 webhook failurePolicy=Ignore（Operator 故障不阻塞建 Pod）"
  confirm "安装 OpenTelemetry Operator（集群级 CRD / RBAC / Webhook）？" || die "已取消"
  run helm upgrade --install otel-operator open-telemetry/opentelemetry-operator --version "$OPERATOR_CHART_VERSION" \
    -n "$OTEL_OPERATOR_NAMESPACE" --create-namespace -f charts/otel-operator/values.yaml --wait --timeout 10m
  kubectl -n "$OTEL_OPERATOR_NAMESPACE" get pods
}

s_instrumentation() {
  ask SAMPLING_RATIO "采样率（生产 0.2；流量很小、想尽快看到 Service Graph 可先用 1，验证后改回）" 0.2
  run kubectl -n "$TEMPO_NAMESPACE" apply --dry-run=server -f build/manifests/otel-instrumentation/instrumentation-java.yaml
  run kubectl -n "$TEMPO_NAMESPACE" apply -f build/manifests/otel-instrumentation/instrumentation-java.yaml
  run kubectl -n "$TEMPO_NAMESPACE" patch instrumentation java --type=merge \
    -p "{\"spec\":{\"sampler\":{\"argument\":\"$SAMPLING_RATIO\"}}}"
  kubectl -n "$TEMPO_NAMESPACE" get instrumentation java -o jsonpath='{.spec.exporter.endpoint}{"  sampler="}{.spec.sampler}{"\n"}'
}

# ====================================================================================
# 12. Inject Java business Deployments
# ====================================================================================
inject_one() {   # inject_one NS DEPLOY
  local ns=$1 dep=$2 info_json ctrs sel ctr patch pod
  info_json=$(kubectl -n "$ns" get deploy "$dep" -o json)
  jq_py '
m=d["metadata"]; a=m.get("annotations",{}); l=m.get("labels",{})
if l.get("app.kubernetes.io/managed-by")=="Helm" or any("argocd" in k or "fluxcd" in k for k in list(a)+list(l)):
    print("WARN")' <<<"$info_json" | grep -q WARN \
    && warn "$ns/$dep 由 Helm/GitOps 管理，直接 patch 的注解会在下次发布时被覆盖，长期应写入其 values / 仓库"
  mapfile -t ctrs < <(jq_py 'for c in d["spec"]["template"]["spec"]["containers"]: print(c["name"])' <<<"$info_json")
  patch="{\"instrumentation.opentelemetry.io/inject-java\":\"$TEMPO_NAMESPACE/java\""
  if ((${#ctrs[@]} > 1)); then
    pick ctr "$dep 有多个容器，选择 Java 业务容器" "${ctrs[@]}"
    patch+=",\"instrumentation.opentelemetry.io/container-names\":\"$ctr\""
  fi
  patch+="}"
  run kubectl -n "$ns" patch deployment "$dep" --type=merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":$patch}}}}"
  run kubectl -n "$ns" rollout status "deployment/$dep" --timeout=10m
  sel=$(jq_py 'print(",".join("%s=%s" % i for i in d["spec"]["selector"]["matchLabels"].items()))' <<<"$info_json")
  pod=$(kubectl -n "$ns" get pods -l "$sel" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  if kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.initContainers[*].name}' | grep -q opentelemetry-auto-instrumentation-java; then
    ok "$ns/$dep 已注入（Pod $pod）"
    INJECTED="${INJECTED:+$INJECTED }$ns/$dep"
  else
    warn "$ns/$dep 未注入：检查注解与 Operator 日志 kubectl -n $OTEL_OPERATOR_NAMESPACE logs deploy/otel-operator-opentelemetry-operator"
  fi
}

s_inject() {
  warn "注入会滚动重启所选 Deployment；Service Graph 的边需要调用双方都注入，请选择互相调用的 2～3 个服务"
  local ns deps sel d
  while true; do
    kubectl get ns --show-labels | grep -vE '^(kube-|default )' | awk '{print "  "$1"  "$NF}' | sed -n 1,40p
    ask ns "业务 namespace" "${ns:-}"
    run kubectl label namespace "$ns" tracing-access=enabled --overwrite
    if kubectl -n "$ns" get networkpolicy -o name 2>/dev/null | grep -q .; then
      warn "$ns 中有 NetworkPolicy；若限制出口，需要放行到 $TEMPO_NAMESPACE 的 otel-gateway TCP 4319"
      kubectl -n "$ns" get networkpolicy
    fi
    mapfile -t deps < <(kubectl -n "$ns" get deploy -o json | jq_py '
for x in d["items"]:
    imgs=",".join(c["image"].rsplit("/",1)[-1] for c in x["spec"]["template"]["spec"]["containers"])
    inj="（已注入）" if "instrumentation.opentelemetry.io/inject-java" in (x["spec"]["template"]["metadata"].get("annotations") or {}) else ""
    print("%s  [%s]%s" % (x["metadata"]["name"], imgs, inj))')
    ((${#deps[@]})) || { warn "$ns 中没有 Deployment"; continue; }
    local i; for i in "${!deps[@]}"; do echo "  $((i+1))) ${deps[$i]}"; done
    read -r -p "输入要注入的序号（空格分隔，如 1 3 4）: " sel
    for i in $sel; do
      [[ "$i" =~ ^[0-9]+$ ]] && ((i>=1 && i<=${#deps[@]})) || { warn "忽略无效序号 $i"; continue; }
      d=${deps[$((i-1))]%%  *}
      inject_one "$ns" "$d"
    done
    confirm "继续注入其他 namespace 的服务？" || break
  done
  [[ -n "${INJECTED:-}" ]] || die "没有任何服务注入成功"
}

# ====================================================================================
# 13. Verify: spans reach the gateway, Service Graph series reach Prometheus
# ====================================================================================
s_verify() {
  local i spans edges
  pf "$TEMPO_NAMESPACE" deploy/otel-gateway "$GW_LP" 8888
  info "请现在对已注入的业务发起正常请求（经业务入口调用，持续几分钟）。等待 gateway 收到 span（最长 10 分钟）"
  for i in $(seq 1 60); do
    spans=$(curl -s "http://127.0.0.1:$GW_LP/metrics" | { grep -E '^otelcol_receiver_accepted_spans.*otlp/plaintext' || true; } | awk '{s+=$NF} END {printf "%d", s}')
    if (( spans > 0 )); then ok "gateway 已收到 $spans 个 span"; break; fi
    printf '.'; sleep 10
  done
  echo
  (( spans > 0 )) || die "10 分钟内 gateway 没有收到 span：检查业务是否有流量、Pod 日志中的 Failed to export、namespace 标签与出口 NetworkPolicy"

  prom_connect
  info "等待 Service Graph 指标写入 Prometheus（最长 10 分钟）"
  for i in $(seq 1 60); do
    edges=$(promq 'sum by (client, server) (rate(traces_service_graph_request_total[5m]))' | jq_py '
for r in d["data"]["result"]: print("  %s -> %s  %.3f req/s" % (r["metric"].get("client"), r["metric"].get("server"), float(r["value"][1])))')
    [[ -n "$edges" ]] && break
    printf '.'; sleep 10
  done
  echo
  if [[ -z "$edges" ]]; then
    warn "还没有 Service Graph 指标，诊断信息："
    promq 'sum by (service) (rate(traces_spanmetrics_calls_total[5m]))' | jq_py '
for r in d["data"]["result"]: print("  span metrics: %s %.3f/s" % (r["metric"].get("service"), float(r["value"][1])))'
    kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=15m | grep -iE 'error|remote' | tail -10 || true
    echo "  - 有 span metrics 但没有边：调用双方没有都注入，或调用链未经过已注入的服务"
    echo "  - 两者都没有：检查上面 generator 日志中的 Remote Write / Kafka 错误（步骤 9、步骤 5）"
    die "Service Graph 未就绪"
  fi
  ok "Prometheus 中已有 Service Graph 数据："
  echo "$edges"
}

finish() {
  pf "$GRAFANA_NAMESPACE" "svc/$GRAFANA_SVC" "$GRAFANA_LP" "$GRAFANA_SVC_PORT" 2>/dev/null || true
  echo
  echo "${G}${B}安装完成。${N}在 Grafana 中查看 Service Graph："
  echo "  1. 浏览器打开 http://127.0.0.1:$GRAFANA_LP （脚本运行期间保持端口转发；之后可用："
  echo "     kubectl -n $GRAFANA_NAMESPACE port-forward svc/$GRAFANA_SVC 3000:$GRAFANA_SVC_PORT）"
  echo "  2. Explore → 数据源选 Tempo → Query type 选 Service Graph → 时间范围 Last 15 minutes → Run query"
  echo "  已注入的服务：${INJECTED:-无}"
  echo "  凭据与证书位于 build/secrets/，请转存到企业密钥系统后删除。ES 日志关联见手册第 14 步。"
  read -r -p "按回车结束脚本（同时关闭端口转发）..." _
}

# ====================================================================================
main() {
  echo "${B}Tempo + Service Graph 交互式安装${N}（对应 docs/tempo/04-installation.md）"
  if [[ -f "$STATE" ]] && confirm "发现上次的进度 $STATE，载入并继续？"; then
    # shellcheck disable=SC1090
    source "$STATE"
  fi
  s_tools
  step 2   "收集环境参数"                              s_params
  step 5a  "准备 Kafka（Topic / 用户 / ACL）"          s_kafka
  step 5b  "准备 MinIO（bucket / 账号 / 策略）"        s_minio
  step 2.2 "连接 Grafana，选择 Prometheus / ES 数据源"  s_grafana_uids
  step 3   "生成 environment.local.json 并渲染"        s_render
  step 4   "集群预检"                                  s_preflight
  step 6   "Namespace、gateway 证书与 Secret"          s_secrets
  step 7   "安装 Tempo 与 otel-gateway"                s_install
  step 8   "检查 Prometheus 抓取选择器"                s_scrape
  step 9   "开启 Prometheus Remote Write 接收"         s_remote_write
  step 10  "注册 Grafana Tempo 数据源"                 s_grafana_ds
  step 11a "安装 OpenTelemetry Operator"               s_operator
  step 11b "创建 Java Instrumentation"                 s_instrumentation
  step 12  "为 Java 业务开启自动注入"                  s_inject
  step 13  "验证 Service Graph 数据"                   s_verify
  save_state
  [[ -n "${GRAFANA_SVC:-}" ]] || grafana_connect
  finish
}
main "$@"
