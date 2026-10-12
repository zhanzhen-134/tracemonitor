#!/usr/bin/env bash
# Interactive installer that follows docs/tempo/04-installation.md end to end:
# dedicated Kafka + RustFS -> Tempo + otel-gateway -> Prometheus Remote Write -> Grafana datasource
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
  PROMETHEUS_SVC PROMETHEUS_SVC_PORT PROMETHEUS_PORT PROMETHEUS_REMOTE_WRITE_URL ZONE_MODE ZONE_A ZONE_B STORAGE_CLASS
  CHANGE_APPROVAL_ID OTEL_OPERATOR_NAMESPACE KAFKA_STORAGE_SIZE RUSTFS_STORAGE_SIZE
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
    if command -v "$t" >/dev/null && "$t" -c 'import sys; sys.exit(sys.version_info < (3,10))' 2>/dev/null; then PY=$t; break; fi
  done
  [[ -n "$PY" ]] || die "需要 Python 3.10+（验证版本 3.10.12）"
  info "使用 $("$PY" --version 2>&1 | tr -d '\r')"
  export PYTHON=$PY   # used by scripts/tempo/common.sh
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
  ZONE_MODE=single
  if ((${#zones[@]} >= 2)); then
    info "检测到 ${#zones[@]} 个可用区：${zones[*]}"
    if confirm "使用双可用区模式（live-store 分两组跨区部署，并安装 rollout-operator）？"; then
      ZONE_MODE=multi
      pick ZONE_A "选择 ZONE_A" "${zones[@]}"
      pick ZONE_B "选择 ZONE_B（必须与 ZONE_A 不同）" "${zones[@]}"
      [[ "$ZONE_A" != "$ZONE_B" ]] || die "ZONE_A 与 ZONE_B 不能相同"
    fi
  else
    info "节点没有可用区标签（或只有一个可用区），使用单可用区模式"
  fi
  if [[ "$ZONE_MODE" == single ]]; then
    ZONE_A='' ZONE_B=''
    warn "单可用区模式：live-store 共 3 个；某个 live-store 重启期间，对应分区最近几分钟的 trace 暂时查不到（不丢数据）"
  fi

  kubectl get storageclass
  mapfile -t scs < <(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | tr -d '\r')
  pick STORAGE_CLASS "选择 StorageClass（需支持 RWO）" "${scs[@]}"
}

# ====================================================================================
# 5. Dedicated Kafka and RustFS (sizes only; install.sh deploys them in the Tempo namespace)
# ====================================================================================
s_storage() {
  info "Tempo 使用部署在 $TEMPO_NAMESPACE 中的专用单节点 Kafka（tempo-kafka）和 RustFS（tempo-rustfs），与业务完全隔离"
  info "Kafka 保留 24 小时且每个分区上限 28GB（共约 84GB），PVC 应不小于 100Gi；RustFS 保存 30 天的 trace"
  ask KAFKA_STORAGE_SIZE "Kafka PVC 大小" 100Gi
  ask RUSTFS_STORAGE_SIZE "RustFS PVC 大小" 500Gi
  [[ "$KAFKA_STORAGE_SIZE" =~ ^[1-9][0-9]*(Gi|Ti)$ && "$RUSTFS_STORAGE_SIZE" =~ ^[1-9][0-9]*(Gi|Ti)$ ]] \
    || die "大小格式应为 100Gi / 1Ti"
  if [[ "${STORAGE_CLASS:-}" == local-path ]]; then
    warn "local-path 使用节点本地盘：请确认将要调度到的节点有足够空间（Kafka $KAFKA_STORAGE_SIZE + RustFS $RUSTFS_STORAGE_SIZE + Tempo 约 230GB）"
  fi
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
  export ZONE_A="${ZONE_A:-}" ZONE_B="${ZONE_B:-}"
  export TEMPO_NAMESPACE STORAGE_CLASS KAFKA_STORAGE_SIZE RUSTFS_STORAGE_SIZE \
    PROMETHEUS_REMOTE_WRITE_URL PROMETHEUS_RELEASE ZONE_A ZONE_B MONITORING_NAMESPACE GRAFANA_NAMESPACE \
    PROMETHEUS_UID ELASTICSEARCH_UID PROMETHEUS_PORT
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
  if [[ ! -f "$SECRETS/credentials.env" ]]; then
    info "生成 RustFS 访问密钥（RustFS 与 Tempo 共用，只有 Tempo 使用这个 RustFS）"
    ( umask 077
      printf 'RUSTFS_ACCESS_KEY=tempo-%s\nRUSTFS_SECRET_KEY=%s\n' \
        "$(openssl rand -hex 4)" "$(openssl rand -base64 30 | tr -d '/+=\r\n')" > "$SECRETS/credentials.env" )
  else
    info "沿用已有的 $SECRETS/credentials.env（RustFS 已用它初始化，不能更换）"
  fi
  apply_secret() { kubectl -n "$TEMPO_NAMESPACE" create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -; }
  apply_secret tempo-credentials --from-env-file="$SECRETS/credentials.env"
  apply_secret otel-gateway-tls --from-file=ca.crt="$SECRETS/otel-ca.crt" \
    --from-file=tls.crt="$SECRETS/otel-server.crt" --from-file=tls.key="$SECRETS/otel-server.key"
  kubectl -n "$TEMPO_NAMESPACE" get secret tempo-credentials otel-gateway-tls
}

# ====================================================================================
# 7. Install Tempo + otel-gateway
# ====================================================================================
s_install() {
  export TEMPO_NAMESPACE CHANGE_APPROVAL_ID GATEWAY_MODE=new
  run bash scripts/tempo/install.sh
  kubectl -n "$TEMPO_NAMESPACE" get pods
  info "Kafka Topic："
  kubectl -n "$TEMPO_NAMESPACE" exec tempo-kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --describe --topic tempo-traces 2>/dev/null | sed -n 1,4p || true
  info "检查 Tempo 是否能连上 Kafka / RustFS（最近 5 分钟日志中的错误）"
  kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-block-builder --since=5m 2>/dev/null | grep -iE 'level=error|AccessDenied|NoSuchBucket|connection refused' | tail -n 5 || true
  kubectl -n "$TEMPO_NAMESPACE" logs statefulset/tempo-metrics-generator --since=5m 2>/dev/null | grep -iE 'level=error|connection refused' | tail -n 5 || true
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
  step 5   "Tempo 专用 Kafka / RustFS 的存储大小"      s_storage
  step 2.2 "连接 Grafana，选择 Prometheus / ES 数据源"  s_grafana_uids
  step 3   "生成 environment.local.json 并渲染"        s_render
  step 4   "集群预检"                                  s_preflight
  step 6   "Namespace、gateway 证书与 Secret"          s_secrets
  step 7   "部署 Kafka / RustFS，安装 Tempo 与 otel-gateway" s_install
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
