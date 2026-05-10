#!/bin/bash
set -euo pipefail

# Nebula/Apex runs supervisord — do not start services here.
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
KEYCLOAK_DEPLOYMENT="${KEYCLOAK_DEPLOYMENT:-keycloak}"
KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak}"
# Pod selector for port-forward (falls back to Service if no pod). Matches typical chart labels.
KEYCLOAK_POD_SELECTOR="${KEYCLOAK_POD_SELECTOR:-app=keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-devops}"
ONCALL_CLIENT_ID="${ONCALL_CLIENT_ID:-oncall}"

# Real OnCall workloads live in bleater (not a synthetic "oncall" namespace). Never create namespaces here.
ONCALL_NS="${ONCALL_NS:-bleater}"
ONCALL_ENGINE_DEPLOY="${ONCALL_ENGINE_DEPLOY:-oncall-engine}"
ONCALL_CELERY_DEPLOY="${ONCALL_CELERY_DEPLOY:-oncall-celery}"
# Optional: PostgreSQL secret override (must exist in ONCALL_NS).
ONCALL_PG_SECRET="${ONCALL_PG_SECRET:-}"
MONITORING_NS="${MONITORING_NS:-monitoring}"

PSQL_JOB_IMAGE="${PSQL_JOB_IMAGE:-postgres:16-alpine}"
ESCALATION_JOB_NAME="${ESCALATION_JOB_NAME:-nebula-escalation-seed-8m}"

NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-360}"
NEBULA_NODE_NAME="${NEBULA_NODE_NAME:-}"
# In hosted/non-root runs, kubelet restart attempts are usually forbidden; keep recovery opt-in.
NEBULA_STRICT_NODE_READY="${NEBULA_STRICT_NODE_READY:-}"
# Hosted Apex runs are often non-root/RBAC-limited; node-ready/kubelet handling is local-debug only.
# Default to skipping node-ready wait unless explicitly enabled.
NEBULA_SKIP_NODE_READY_WAIT="${NEBULA_SKIP_NODE_READY_WAIT:-1}"

# Realistic mesh policy name (not task-scoped); grader detects DENY shape + path patterns.
ISTIO_MESH_DENY_POLICY="${ISTIO_MESH_DENY_POLICY:-bleater-deny-unauthenticated-ingestion}"
ISTIO_MESH_DENY_POLICY_SECOND="${ISTIO_MESH_DENY_POLICY_SECOND:-bleater-ingress-authz-guard}"
ISTIO_MESH_DENY_POLICY_THIRD="${ISTIO_MESH_DENY_POLICY_THIRD:-bleater-public-api-shadow-deny}"
ISTIO_MESH_DENY_POLICY_FOURTH="${ISTIO_MESH_DENY_POLICY_FOURTH:-bleater-v1-ack-webhook-deny}"
ISTIO_PUBLIC_ALLOWLIST_TRAP="${ISTIO_PUBLIC_ALLOWLIST_TRAP:-bleater-public-callback-allowlist}"
ISTIO_PUBLIC_ALLOWLIST_TRAP_SECOND="${ISTIO_PUBLIC_ALLOWLIST_TRAP_SECOND:-bleater-public-api-principal-guard}"
# Best-effort wait for injection (many eval clusters have no sidecar webhook — do not block setup for long).
ISTIO_SIDECAR_WAIT_SEC="${ISTIO_SIDECAR_WAIT_SEC:-90}"
TTL_POLICY_ENGINE_CM="${TTL_POLICY_ENGINE_CM:-oncall-runtime-policy}"
TTL_POLICY_CELERY_CM="${TTL_POLICY_CELERY_CM:-oncall-worker-runtime-policy}"
TTL_POLICY_ENGINE_AUX_CM="${TTL_POLICY_ENGINE_AUX_CM:-oncall-runtime-overrides}"
TTL_POLICY_CELERY_AUX_CM="${TTL_POLICY_CELERY_AUX_CM:-oncall-worker-overrides}"
TTL_POLICY_ENGINE_SHADOW_CM="${TTL_POLICY_ENGINE_SHADOW_CM:-oncall-runtime-shadow}"
TTL_POLICY_CELERY_SHADOW_CM="${TTL_POLICY_CELERY_SHADOW_CM:-oncall-worker-shadow}"
TTL_POLICY_ENGINE_EDGE_CM="${TTL_POLICY_ENGINE_EDGE_CM:-incident-ack-link-policy}"
TTL_POLICY_CELERY_EDGE_CM="${TTL_POLICY_CELERY_EDGE_CM:-worker-incident-link-policy}"
TTL_POLICY_CELERY_LEGACY_CM="${TTL_POLICY_CELERY_LEGACY_CM:-oncall-worker-runtime-legacy}"
GRAFANA_AUTH_ENGINE_SECRET="${GRAFANA_AUTH_ENGINE_SECRET:-oncall-runtime-auth}"
GRAFANA_AUTH_CELERY_SECRET="${GRAFANA_AUTH_CELERY_SECRET:-oncall-worker-runtime-auth}"
GRAFANA_ENVFROM_ENGINE_SECRET="${GRAFANA_ENVFROM_ENGINE_SECRET:-oncall-engine-grafana-sidecar}"
GRAFANA_ENVFROM_CELERY_SECRET="${GRAFANA_ENVFROM_CELERY_SECRET:-oncall-worker-grafana-sidecar}"
GRAFANA_ENGINE_EDGE_SECRET="${GRAFANA_ENGINE_EDGE_SECRET:-oncall-engine-plugin-auth}"
GRAFANA_CELERY_EDGE_SECRET="${GRAFANA_CELERY_EDGE_SECRET:-oncall-worker-plugin-auth}"
GRAFANA_CELERY_LEGACY_SECRET="${GRAFANA_CELERY_LEGACY_SECRET:-oncall-worker-grafana-legacy}"
GRAFANA_ENGINE_RUNTIME_SHADOW_SECRET="${GRAFANA_ENGINE_RUNTIME_SHADOW_SECRET:-oncall-runtime-auth-shadow}"
GRAFANA_CELERY_RUNTIME_SHADOW_SECRET="${GRAFANA_CELERY_RUNTIME_SHADOW_SECRET:-oncall-worker-runtime-auth-shadow}"

WRONG_OAUTH_REDIRECT="${WRONG_OAUTH_REDIRECT:-https://oncall.devops.local/invalid/oauth-callback}"
STALE_GRAFANA_TOKEN="${STALE_GRAFANA_TOKEN:-glsa_invalid_nebula_00000000deadbeefcafe}"
REDIRECT_PROBE_URL="${REDIRECT_PROBE_URL:-https://oncall.devops.local/oauth/callback/complete/grafana-oauth/}"

# Admin API only via localhost kubectl port-forward (stable; avoids ClusterIP connection refused).
# Use a high local port: 8080 collides with common host listeners; Nebula may set KEYCLOAK_PF_LOCAL_PORT=8080 — override if needed.
KEYCLOAK_PF_LOCAL_PORT="${KEYCLOAK_PF_LOCAL_PORT:-18080}"
# auto = pod port-forward first (stable backend), then service if pod PF logs errors. service|pod = no fallback.
KEYCLOAK_PF_VIA="${KEYCLOAK_PF_VIA:-auto}"
# Pod Ready is not enough — wait for HTTP inside Keycloak container before port-forward (seconds).
KEYCLOAK_HTTP_WAIT_SEC="${KEYCLOAK_HTTP_WAIT_SEC:-240}"
# Keycloak under load after many eval runs often needs >300s; retries + restart recover stuck rollouts.
KEYCLOAK_ROLLOUT_TIMEOUT_SEC="${KEYCLOAK_ROLLOUT_TIMEOUT_SEC:-900}"
KEYCLOAK_READY_RETRIES="${KEYCLOAK_READY_RETRIES:-4}"
# Never hang forever on stuck kubelet: kubectl exec timeout (must be < Nebula task timeout).
KEYCLOAK_EXEC_REQUEST_TIMEOUT="${KEYCLOAK_EXEC_REQUEST_TIMEOUT:-12s}"
# Hard cap for OIDC polling (nested curls × long max-time can exceed Nebula 1800s otherwise).
KEYCLOAK_OIDC_WAIT_MAX_SEC="${KEYCLOAK_OIDC_WAIT_MAX_SEC:-300}"
KC_PF_PID=""
KC_LOCAL_BASE=""
# Set by wait_keycloak_oidc_local (e.g. "" or "/auth") so token/admin URLs match KC_HTTP_RELATIVE_PATH.
KC_HTTP_PREFIX=""
# Set to 1 when Keycloak answers on https://127.0.0.1:PORT (TLS on forwarded port); adds curl -k for admin API.
KC_TLS_INSECURE=""
# Host + forwarded proto used for admin/token HTTP (hostname-strict Keycloak rejects 127.0.0.1 without Host).
KC_FORWARD_HOST=""
KC_FORWARD_PROTO="http"

log() { echo "[setup] $*"; }
warn() { echo "[setup] WARN: $*" >&2; }
die() { echo "[setup] ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" &>/dev/null || die "required command not found: $1"
}

curl_kc() {
  local url="$1" fwd=()
  shift
  kc_ensure_portforward_alive
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    fwd+=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  fi
  if [[ "${KC_TLS_INSECURE:-}" == "1" ]]; then
    curl -fsSk "${fwd[@]}" "$@" "${url}"
  else
    curl -fsS "${fwd[@]}" "$@" "${url}"
  fi
}

wait_endpoints() {
  local svc="$1" ns="$2" timeout="${3:-180}"
  local elapsed=0
  while (( elapsed < timeout )); do
    local addrs
    addrs=$(kubectl get endpoints "$svc" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
    if [[ -n "${addrs// /}" ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  die "endpoints for ${ns}/${svc} did not get addresses within ${timeout}s"
}

wait_keycloak_workload() {
  local tmo="${KEYCLOAK_ROLLOUT_TIMEOUT_SEC}s"
  local tries="${KEYCLOAK_READY_RETRIES}"
  local i
  if kubectl get "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" &>/dev/null; then
    log "Keycloak deployment: ${tries} attempt(s), ${tmo} per kubectl wait (override KEYCLOAK_ROLLOUT_TIMEOUT_SEC / KEYCLOAK_READY_RETRIES)"
    for i in $(seq 1 "${tries}"); do
      log "Waiting for deployment/${KEYCLOAK_DEPLOYMENT} Available (attempt ${i}/${tries})..."
      if kubectl wait --for=condition=Available "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" --timeout="${tmo}"; then
        kubectl rollout status "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" --timeout=180s 2>/dev/null || true
        return 0
      fi
      warn "deployment/${KEYCLOAK_DEPLOYMENT} not Available after attempt ${i}/${tries}"
      kubectl get pods -n "${KEYCLOAK_NS}" -l "${KEYCLOAK_POD_SELECTOR}" -o wide 2>/dev/null || true
      kubectl describe "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" 2>/dev/null | tail -n 70 || true
      if (( i < tries )); then
        warn "rollout restart deployment/${KEYCLOAK_DEPLOYMENT} then retrying..."
        kubectl rollout restart "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" >/dev/null 2>&1 || true
        sleep 20
      fi
    done
    kubectl get events -n "${KEYCLOAK_NS}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true
    die "deployment/${KEYCLOAK_DEPLOYMENT} did not become Available after ${tries} attempts (${tmo} each)"
  elif kubectl get "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" &>/dev/null; then
    log "Keycloak statefulset: ${tries} attempt(s), ${tmo} per rollout status"
    for i in $(seq 1 "${tries}"); do
      log "Waiting for statefulset/${KEYCLOAK_DEPLOYMENT} rollout (attempt ${i}/${tries})..."
      if kubectl rollout status "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" --timeout="${tmo}"; then
        return 0
      fi
      warn "statefulset/${KEYCLOAK_DEPLOYMENT} rollout not complete (attempt ${i}/${tries})"
      kubectl get pods -n "${KEYCLOAK_NS}" -l "${KEYCLOAK_POD_SELECTOR}" -o wide 2>/dev/null || true
      if (( i < tries )); then
        kubectl rollout restart "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" >/dev/null 2>&1 || true
        sleep 20
      fi
    done
    kubectl describe "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" 2>/dev/null | tail -n 70 || true
    die "statefulset/${KEYCLOAK_DEPLOYMENT} did not roll out after ${tries} attempts"
  else
    die "Neither deployment/${KEYCLOAK_DEPLOYMENT} nor statefulset/${KEYCLOAK_DEPLOYMENT} in ${KEYCLOAK_NS}"
  fi
}

wait_keycloak_pod_ready() {
  local tmo="${KEYCLOAK_ROLLOUT_TIMEOUT_SEC}s"
  local tries="${KEYCLOAK_READY_RETRIES}"
  local i
  log "Waiting for Keycloak pods Ready (-l ${KEYCLOAK_POD_SELECTOR}) in ${KEYCLOAK_NS} (${tries} x ${tmo})..."
  for i in $(seq 1 "${tries}"); do
    if kubectl wait --for=condition=Ready "pod" -l "${KEYCLOAK_POD_SELECTOR}" -n "${KEYCLOAK_NS}" --timeout="${tmo}"; then
      log "Keycloak pod(s) Ready"
      return 0
    fi
    warn "Keycloak pods not Ready (attempt ${i}/${tries})"
    kubectl get pods -n "${KEYCLOAK_NS}" -l "${KEYCLOAK_POD_SELECTOR}" -o wide 2>/dev/null || true
    if (( i < tries )); then
      sleep 15
    fi
  done
  kubectl describe pods -n "${KEYCLOAK_NS}" -l "${KEYCLOAK_POD_SELECTOR}" 2>/dev/null | tail -n 120 || true
  die "Keycloak pods not Ready (namespace ${KEYCLOAK_NS}, selector ${KEYCLOAK_POD_SELECTOR}) after ${tries} attempts"
}

# kubectl exec into Keycloak container (uses -c when sidecars exist).
_kc_exec_keycloak_pod() {
  local pod="$1" ctr="$2" rt="${KEYCLOAK_EXEC_REQUEST_TIMEOUT:-12s}"
  shift 2
  if [[ -n "${ctr}" ]]; then
    kubectl --request-timeout="${rt}" exec -n "${KEYCLOAK_NS}" -c "${ctr}" "${pod}" -- "$@"
  else
    kubectl --request-timeout="${rt}" exec -n "${KEYCLOAK_NS}" "${pod}" -- "$@"
  fi
}

# True when Keycloak accepts HTTP(S) or TCP inside the workload container (Quarkus: mgmt :9000; app :8080; TLS :8443).
kc_probe_keycloak_http_inside_pod() {
  local pod="$1" ctr="$2" remote port path code pip s
  local -a kc_paths
  remote=$(kc_keycloak_remote_port_for_pod "${pod}" "${ctr}")
  [[ -z "${remote}" || "${remote}" == "null" ]] && remote=8080
  pip=$(kubectl get pod "${pod}" -n "${KEYCLOAK_NS}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)

  for port in "${remote}" 8080 9000 8443; do
    [[ -z "${port}" ]] && continue
    if [[ "$port" == "9000" ]]; then
      kc_paths=(/q/health/ready /q/health/live /q/health /health/ready)
    else
      kc_paths=(/realms/master / /health/ready /q/health/ready /health /auth/realms/master)
    fi
    for path in "${kc_paths[@]}"; do
      for s in http https; do
        if [[ "$s" == "https" ]]; then
          code=$(_kc_exec_keycloak_pod "${pod}" "${ctr}" curl -sSk -o /dev/null -w '%{http_code}' \
            --connect-timeout 2 --max-time 9 "https://127.0.0.1:${port}${path}" 2>/dev/null || echo "000")
        else
          code=$(_kc_exec_keycloak_pod "${pod}" "${ctr}" curl -sS -o /dev/null -w '%{http_code}' \
            --connect-timeout 2 --max-time 9 "http://127.0.0.1:${port}${path}" 2>/dev/null || echo "000")
        fi
        code="${code//$'\r'/}"
        code="${code//$'\n'/}"
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
          return 0
        fi
      done
      if [[ -n "${pip}" ]]; then
        code=$(_kc_exec_keycloak_pod "${pod}" "${ctr}" curl -sS -o /dev/null -w '%{http_code}' \
          --connect-timeout 2 --max-time 9 "http://${pip}:${port}${path}" 2>/dev/null || echo "000")
        code="${code//$'\r'/}"
        code="${code//$'\n'/}"
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
          return 0
        fi
      fi
    done
  done

  for port in "${remote}" 8080 9000; do
    [[ -z "${port}" ]] && continue
    for path in /realms/master /q/health/ready /health/ready /; do
      code=$(_kc_exec_keycloak_pod "${pod}" "${ctr}" sh -c \
        "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 9 http://127.0.0.1:${port}${path}" 2>/dev/null || echo "000")
      code="${code//$'\r'/}"
      code="${code//$'\n'/}"
      [[ "$code" =~ ^[23][0-9][0-9]$ ]] && return 0
      code=$(_kc_exec_keycloak_pod "${pod}" "${ctr}" bash -lc \
        "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 9 http://127.0.0.1:${port}${path}" 2>/dev/null || echo "000")
      code="${code//$'\r'/}"
      code="${code//$'\n'/}"
      [[ "$code" =~ ^[23][0-9][0-9]$ ]] && return 0
    done
  done

  for port in "${remote}" 8080 9000 8443; do
    [[ -z "${port}" ]] && continue
    if _kc_exec_keycloak_pod "${pod}" "${ctr}" bash -lc "timeout 3 bash -c 'echo >/dev/tcp/127.0.0.1/${port}'" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

_kc_first_keycloak_pod() {
  local sel pod
  for sel in "${KEYCLOAK_POD_SELECTOR}" "app.kubernetes.io/name=keycloak" "app.kubernetes.io/component=keycloak"; do
    pod=$(kubectl get pods -n "${KEYCLOAK_NS}" -l "$sel" -o json 2>/dev/null | jq -r '
      [.items[]?
        | select(.metadata.deletionTimestamp == null)
        | select((.status.phase // "") == "Running")
        | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)
      ]
      | sort_by(.metadata.creationTimestamp)
      | reverse
      | .[0].metadata.name // empty
    ')
    [[ -n "${pod}" && "${pod}" != "null" ]] && { echo "$pod"; return 0; }
  done

  kubectl get pods -n "${KEYCLOAK_NS}" -o json 2>/dev/null | jq -r '
    [.items[]?
      | select(.metadata.deletionTimestamp == null)
      | select((.metadata.name // "") | ascii_downcase | test("keycloak"))
      | select((.metadata.name // "") | ascii_downcase | test("postgres|postgresql|operator") | not)
      | select((.status.phase // "") == "Running")
      | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)
    ]
    | sort_by(.metadata.creationTimestamp)
    | reverse
    | .[0].metadata.name // empty
  '
}

wait_keycloak_application_listening() {
  local pod ctr elapsed=0 max="${KEYCLOAK_HTTP_WAIT_SEC}"
  pod="$(_kc_first_keycloak_pod)"
  [[ -n "${pod}" ]] || die "No Keycloak pod matched -l ${KEYCLOAK_POD_SELECTOR} in ${KEYCLOAK_NS}"
  ctr=$(kc_pf_container_name "${pod}")
  log "Waiting for Keycloak HTTP/mgmt (8080/9000/8443, pod IP) inside ${pod}${ctr:+ (container ${ctr})} (up to ${max}s)..."
  while (( elapsed < max )); do
    if kc_probe_keycloak_http_inside_pod "${pod}" "${ctr}"; then
      log "Keycloak HTTP responds inside pod"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "Keycloak did not open HTTP inside pod within ${max}s (kubectl logs -n ${KEYCLOAK_NS} deployment/${KEYCLOAK_DEPLOYMENT})"
}

kc_workload_json() {
  if kubectl get "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" &>/dev/null; then
    kubectl get "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" -o json
  else
    kubectl get "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" -o json
  fi
}

# Prefer Keycloak workload env; small fixed secret name list only (no cluster-wide scrape).
kc_admin_password() {
  local pw
  pw=$(kc_workload_json | jq -r '
    .spec.template.spec.containers[]?.env[]?
    | select(.name != null and .value != null and (.value | tostring | length) > 0)
    | select(
        (.name | tostring | ascii_downcase) as $n |
        $n == "keycloak_admin_password"
        or $n == "kc_bootstrap_admin_password"
        or $n == "keycloak_http_password"
        or $n == "keycloak_password"
        or $n == "admin_password"
      )
    | .value' | head -1)
  if [[ -n "${pw}" && "${pw}" != "null" ]]; then
    echo "$pw"
    return 0
  fi

  local spec name key data
  for spec in \
    "keycloak:admin-password" \
    "keycloak:password" \
    "keycloak-admin:admin-password" \
    "keycloak-admin:password" \
    "keycloak-admin-secret:admin-password" \
    "credential-keycloak:password"; do
    name="${spec%%:*}"
    key="${spec#*:}"
    kubectl get secret "$name" -n "${KEYCLOAK_NS}" -o json &>/dev/null || continue
    data=$(kubectl get secret "$name" -n "${KEYCLOAK_NS}" -o json \
      | jq -r --arg k "$key" '.data[$k] // empty')
    [[ -z "$data" ]] && continue
    pw=$(echo "$data" | base64 -d 2>/dev/null || true)
    [[ -n "$pw" ]] && { echo "$pw"; return 0; }
  done

  return 1
}

kc_normalize_http_prefix() {
  local p="${1:-}"
  p="${p//$'\r'/}"
  p="${p//[[:space:]]/}"
  [[ -z "$p" || "$p" == "null" ]] && { echo ""; return 0; }
  [[ "${p}" != /* ]] && p="/${p}"
  p="${p%/}"
  echo "$p"
}

kc_http_prefix_from_cluster() {
  local json=""
  if kubectl get "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" &>/dev/null; then
    json=$(kubectl get "deployment/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" -o json 2>/dev/null || true)
  elif kubectl get "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" &>/dev/null; then
    json=$(kubectl get "statefulset/${KEYCLOAK_DEPLOYMENT}" -n "${KEYCLOAK_NS}" -o json 2>/dev/null || true)
  fi
  [[ -z "$json" ]] && { echo ""; return 0; }
  echo "$json" | jq -r '
    .spec.template.spec.containers[]?.env[]?
    | select(
        (.name | tostring | ascii_downcase) == "kc_http_relative_path"
        or (.name | tostring | ascii_downcase) == "keycloak_http_relative_path"
      )
    | .value // empty' | head -1
}

# Hostname only (no scheme/port/path) for Host: header when KC_HOSTNAME_STRICT is used.
kc_hostname_hint_from_cluster() {
  local v
  v=$(kc_workload_json 2>/dev/null | jq -r '
    .spec.template.spec.containers[]?.env[]?
    | select(
        (.name | tostring | ascii_downcase) == "kc_hostname"
        or (.name | tostring | ascii_downcase) == "keycloak_hostname"
        or (.name | tostring | ascii_downcase) == "keycloak_frontend_url"
      )
    | .value // empty' | head -1)
  [[ -z "$v" || "$v" == "null" ]] && { echo ""; return 0; }
  v="${v#https://}"
  v="${v#http://}"
  v="${v%%/*}"
  v="${v%%:*}"
  v="${v%%\?*}"
  echo "$v"
}

# When a pod has sidecars, port-forward must target the Keycloak container.
kc_pf_container_name() {
  local pod="$1" json name l pick
  json=$(kubectl get pod "${pod}" -n "${KEYCLOAK_NS}" -o json 2>/dev/null) || { echo ""; return 0; }
  local cnt
  cnt=$(echo "$json" | jq '[.spec.containers[]?] | length')
  (( cnt <= 1 )) && { echo ""; return 0; }
  pick=$(echo "$json" | jq -r '
    .spec.containers[]?
    | select((.name // "" | tostring | ascii_downcase | test("keycloak")))
    | .name' | head -1)
  [[ -n "${pick}" && "${pick}" != "null" ]] && { echo "${pick}"; return 0; }
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == "null" ]] && continue
    l="${name,,}"
    [[ "$l" == *istio-proxy* || "$l" == *linkerd-proxy* || "$l" == *vault-agent* || "$l" == *envoy* ]] && continue
    echo "$name"
    return 0
  done < <(echo "$json" | jq -r '.spec.containers[]?.name // empty')
  echo "$json" | jq -r '.spec.containers[0].name // empty'
}

kc_pick_keycloak_svc_port() {
  kubectl get svc "${KEYCLOAK_SVC}" -n "${KEYCLOAK_NS}" -o json 2>/dev/null | jq -r '
    .spec.ports as $ports
    | (
        ([$ports[]? | select((.name // "" | tostring | ascii_downcase | test("http")) and (.port != null)) | .port] | .[0])
        // ([$ports[]? | select(.port == 8080) | .port] | .[0])
        // ($ports[0].port // empty)
      )' | head -1
}

# Remote container port for pod-based port-forward (may differ from Service .port).
kc_keycloak_remote_port_for_pod() {
  local pod="$1" ctr="${2:-}" json
  json=$(kubectl get pod "${pod}" -n "${KEYCLOAK_NS}" -o json 2>/dev/null) || { echo ""; return; }
  echo "$json" | jq -r --arg ctr "$ctr" '
    (
      if ($ctr | length) > 0 then
        [.spec.containers[]? | select(.name == $ctr)]
      else
        [.spec.containers[]? | select((.name // "" | tostring | ascii_downcase | test("keycloak")))]
      end
    ) as $cs
    | if ($cs | length) == 0 then empty
      else
        ($cs[0].ports[]?
          | select((.name // "" | tostring | ascii_downcase | test("http")) and .containerPort != null)
          | .containerPort)
        // ($cs[0].ports[]? | select(.containerPort == 8080) | .containerPort)
        // ($cs[0].ports[0].containerPort // empty)
      end
  ' | head -1
}

kc_spawn_keycloak_portforward_once() {
  local mode="$1" svc_port pod _kc_ctr remote
  svc_port=$(kc_pick_keycloak_svc_port)
  [[ -z "$svc_port" || "$svc_port" == "null" ]] && svc_port=8080
  : > /tmp/nebula-kc-pf-setup.log
  if [[ "$mode" == "service" ]]; then
    kubectl port-forward -n "${KEYCLOAK_NS}" --address 127.0.0.1 "service/${KEYCLOAK_SVC}" "${KEYCLOAK_PF_LOCAL_PORT}:${svc_port}" \
      >>/tmp/nebula-kc-pf-setup.log 2>&1 &
    KC_PF_PID=$!
    echo "service/${KEYCLOAK_SVC}:${svc_port}" >/tmp/nebula-kc-pf-target.txt
    return 0
  fi
  pod="$(_kc_first_keycloak_pod)"
  [[ -z "${pod}" ]] && return 1
  _kc_ctr=$(kc_pf_container_name "${pod}")
  remote=$(kc_keycloak_remote_port_for_pod "${pod}" "${_kc_ctr}")
  [[ -z "$remote" || "$remote" == "null" ]] && remote="${svc_port}"
  if [[ -n "${_kc_ctr}" ]]; then
    kubectl port-forward -n "${KEYCLOAK_NS}" --address 127.0.0.1 --container "${_kc_ctr}" "pod/${pod}" "${KEYCLOAK_PF_LOCAL_PORT}:${remote}" \
      >>/tmp/nebula-kc-pf-setup.log 2>&1 &
  else
    kubectl port-forward -n "${KEYCLOAK_NS}" --address 127.0.0.1 "pod/${pod}" "${KEYCLOAK_PF_LOCAL_PORT}:${remote}" \
      >>/tmp/nebula-kc-pf-setup.log 2>&1 &
  fi
  KC_PF_PID=$!
  echo "pod/${pod}:${remote}" >/tmp/nebula-kc-pf-target.txt
  return 0
}

kc_local_root() {
  echo "${KC_LOCAL_BASE%/}${KC_HTTP_PREFIX:-}"
}

kc_admin_username() {
  local u
  u=$(kc_workload_json | jq -r '
    .spec.template.spec.containers[]?.env[]?
    | select(.name != null and .value != null and (.value | tostring | length) > 0)
    | select((.name | tostring | ascii_downcase) == "keycloak_admin")
    | .value' | head -1)
  if [[ -n "${u}" && "${u}" != "null" ]]; then
    echo "$u"
  else
    echo "admin"
  fi
}

kc_obtain_token() {
  local base="$1" pass="$2" user="$3"
  local raw tok kf=() fwd=()
  [[ "${KC_TLS_INSECURE:-}" == "1" ]] && kf+=(-k)
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    fwd+=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  fi
  raw=$(curl -sS "${kf[@]}" "${fwd[@]}" --connect-timeout 15 --max-time 60 -X POST "${base%/}${KC_HTTP_PREFIX:-}/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d "username=${user}" -d password="${pass}" || true)
  tok=$(echo "$raw" | jq -r '.access_token // empty' 2>/dev/null || true)
  [[ -n "$tok" && "$tok" != "null" ]] || return 1
  echo "$tok"
}

kc_stop_portforward() {
  if [[ -n "${KC_PF_PID:-}" ]] && kill -0 "${KC_PF_PID}" 2>/dev/null; then
    kill "${KC_PF_PID}" 2>/dev/null || true
    wait "${KC_PF_PID}" 2>/dev/null || true
  fi
  KC_PF_PID=""
  KC_HTTP_PREFIX=""
  KC_TLS_INSECURE=""
  KC_FORWARD_HOST=""
  KC_FORWARD_PROTO="http"
}

kc_ensure_portforward_alive() {
  # Self-heal transient kubectl port-forward drops during long setup phases.
  if [[ -n "${KC_PF_PID:-}" ]] && kill -0 "${KC_PF_PID}" 2>/dev/null; then
    if (echo >/dev/tcp/127.0.0.1/"${KEYCLOAK_PF_LOCAL_PORT}") 2>/dev/null; then
      return 0
    fi
  fi
  warn "Keycloak localhost port-forward is not healthy; restarting"
  kc_start_portforward
  wait_keycloak_oidc_local "${KC_LOCAL_BASE}" || die "Keycloak OIDC discovery failed after port-forward restart"
  kc_apply_hostname_hint_if_needed
  # Re-issue admin token after any PF restart: URL prefix / Host hints can change; stale token + jq on response breaks C2.
  if [[ -n "${KC_PASS:-}" && -n "${KC_USER:-}" ]]; then
    KC_TOKEN=$(kc_obtain_token "${KC_LOCAL_BASE}" "${KC_PASS}" "${KC_USER}") || \
      die "Keycloak admin token failed after port-forward restart"
  fi
}

kc_pf_log_has_forward_failure() {
  grep -qE "connection refused|error forwarding port|Unable to connect|dial tcp.*refused|lost connection|broken pipe|EOF" /tmp/nebula-kc-pf-setup.log 2>/dev/null
}

# Spawn PF, brief settle, verify process + log (returns 1 on failure).
_kc_portforward_spawn_and_stabilize() {
  local how="$1"
  kc_spawn_keycloak_portforward_once "${how}" || return 1
  sleep 6
  kill -0 "${KC_PF_PID}" 2>/dev/null || return 1
  if kc_pf_log_has_forward_failure; then
    return 1
  fi
  return 0
}

kc_start_portforward() {
  local w=0 target_line mode="${KEYCLOAK_PF_VIA:-auto}"
  kc_stop_portforward
  if [[ "$mode" == "pod" ]]; then
    _kc_portforward_spawn_and_stabilize pod || die "Keycloak pod port-forward failed (see /tmp/nebula-kc-pf-setup.log)"
  elif [[ "$mode" == "service" ]]; then
    _kc_portforward_spawn_and_stabilize service || die "Keycloak service port-forward failed (KEYCLOAK_PF_VIA=service; try auto)"
  else
    if ! _kc_portforward_spawn_and_stabilize pod; then
      warn "pod port-forward failed or logged errors; trying service/${KEYCLOAK_SVC}"
      kc_stop_portforward
      _kc_portforward_spawn_and_stabilize service || die "Keycloak port-forward failed (pod and service; see /tmp/nebula-kc-pf-setup.log)"
    fi
  fi
  while (( w < 60 )); do
    if (echo >/dev/tcp/127.0.0.1/"${KEYCLOAK_PF_LOCAL_PORT}") 2>/dev/null; then
      break
    fi
    sleep 1
    w=$((w + 1))
    kill -0 "${KC_PF_PID}" 2>/dev/null || die "kubectl port-forward died (log: /tmp/nebula-kc-pf-setup.log)"
  done
  target_line=$(cat /tmp/nebula-kc-pf-target.txt 2>/dev/null || echo "?")
  KC_LOCAL_BASE="http://127.0.0.1:${KEYCLOAK_PF_LOCAL_PORT}"
  log "Keycloak localhost port-forward started (pid ${KC_PF_PID} -> ${KC_LOCAL_BASE} -> ${target_line})"
}

wait_keycloak_oidc_local() {
  local _base="$1" n=0 url code hint p seen port scheme kextra curlbase hname hdr realm
  local -a realms hostnames
  local _deadline=$(( $(date +%s) + ${KEYCLOAK_OIDC_WAIT_MAX_SEC:-300} ))
  port="${KEYCLOAK_PF_LOCAL_PORT}"
  local -a prefixes=("" "/auth")
  hint=$(kc_normalize_http_prefix "$(kc_http_prefix_from_cluster)")
  if [[ -n "$hint" ]]; then
    seen=0
    for p in "${prefixes[@]}"; do
      [[ "$p" == "$hint" ]] && seen=1 && break
    done
    (( seen == 0 )) && prefixes+=("$hint")
  fi
  realms=("master")
  [[ "${KEYCLOAK_REALM}" != "master" && -n "${KEYCLOAK_REALM}" ]] && realms+=("${KEYCLOAK_REALM}")
  hostnames=("" "localhost" "127.0.0.1" "${KEYCLOAK_SVC}.${KEYCLOAK_NS}.svc.cluster.local" "${KEYCLOAK_SVC}.${KEYCLOAK_NS}.svc")
  hname=$(kc_hostname_hint_from_cluster)
  if [[ -n "$hname" ]]; then
    seen=0
    for p in "${hostnames[@]}"; do
      [[ "$p" == "$hname" ]] && seen=1 && break
    done
    (( seen == 0 )) && hostnames+=("$hname")
  fi
  KC_HTTP_PREFIX=""
  KC_TLS_INSECURE=""
  log "Polling OIDC via 127.0.0.1:${port} (wall-clock cap ${KEYCLOAK_OIDC_WAIT_MAX_SEC:-300}s; tight curl timeouts)..."
  while (( $(date +%s) < _deadline )); do
    for scheme in http https; do
      (( $(date +%s) >= _deadline )) && break
      kextra=(--http1.1)
      [[ "$scheme" == "https" ]] && kextra+=(-k)
      curlbase="${scheme}://127.0.0.1:${port}"
      for hname in "${hostnames[@]}"; do
        hdr=()
        if [[ -n "$hname" ]]; then
          hdr+=(-H "Host: ${hname}" -H "X-Forwarded-Proto: ${scheme}" -H "X-Forwarded-Host: ${hname}")
        fi
        for p in "${prefixes[@]}"; do
          for realm in "${realms[@]}"; do
            if (( $(date +%s) >= _deadline )); then
              break 4
            fi
            url="${curlbase}${p}/realms/${realm}/.well-known/openid-configuration"
            code=$(curl -sS "${kextra[@]}" "${hdr[@]}" -o /dev/null -w "%{http_code}" \
              --connect-timeout 3 --max-time 8 "$url" 2>/dev/null || echo "000")
            if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
              KC_HTTP_PREFIX="$p"
              KC_LOCAL_BASE="${curlbase}"
              [[ "$scheme" == "https" ]] && KC_TLS_INSECURE=1 || KC_TLS_INSECURE=""
              KC_FORWARD_HOST="${hname}"
              KC_FORWARD_PROTO="${scheme}"
              log "OIDC discovery OK (HTTP ${code}, realm=${realm}): ${url}"
              return 0
            fi
          done
        done
      done
    done
    sleep 2
    n=$((n + 1))
  done
  warn "kubectl port-forward log (tail): $(tail -25 /tmp/nebula-kc-pf-setup.log 2>/dev/null | tr '\n' ' ' || true)"
  die "OIDC discovery not reachable at http://127.0.0.1:${port} within ${KEYCLOAK_OIDC_WAIT_MAX_SEC:-300}s (see /tmp/nebula-kc-pf-setup.log)"
}

kc_apply_hostname_hint_if_needed() {
  local h
  [[ -n "${KC_FORWARD_HOST:-}" ]] && return 0
  h=$(kc_hostname_hint_from_cluster || true)
  [[ -z "${h}" || "${h}" == "null" ]] && return 0
  KC_FORWARD_HOST="${h}"
  if [[ "${KC_TLS_INSECURE:-}" == "1" ]]; then
    KC_FORWARD_PROTO="https"
  else
    KC_FORWARD_PROTO="http"
  fi
  log "Keycloak admin/token use Host: ${KC_FORWARD_HOST} (strict hostname / admin API)"
}

# Create task realm if Keycloak returns 404 (import still running or fresh cluster).
kc_ensure_realm_exists() {
  local root kf=() fwd=() code body
  root="$(kc_local_root)"
  [[ "${KC_TLS_INSECURE:-}" == "1" ]] && kf+=(-k)
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    fwd+=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  fi
  code=$(curl -sS "${kf[@]}" "${fwd[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 20 \
    -H "Authorization: Bearer ${KC_TOKEN}" "${root}/admin/realms/${KEYCLOAK_REALM}" || echo "000")
  [[ "$code" == "200" ]] && return 0
  if [[ "$code" != "404" ]]; then
    return 0
  fi
  log "Realm ${KEYCLOAK_REALM} not found via admin API; creating minimal realm"
  body=$(jq -n --arg r "${KEYCLOAK_REALM}" '{realm: $r, enabled: true, displayName: $r}')
  code=$(curl -sS "${kf[@]}" "${fwd[@]}" -o /dev/null -w "%{http_code}" -X POST "${root}/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" --data-binary "${body}" || echo "000")
  [[ "$code" == "201" || "$code" == "409" ]] || die "Could not create realm ${KEYCLOAK_REALM} (HTTP ${code})"
  return 0
}

kc_wait_realm_readable() {
  local base="$1" token="$2"
  local n=0 kf=() fwd=() _dl=$(( $(date +%s) + 420 ))
  [[ "${KC_TLS_INSECURE:-}" == "1" ]] && kf+=(-k)
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    fwd+=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  fi
  while (( $(date +%s) < _dl && n < 45 )); do
    local code
    code=$(curl -sS "${kf[@]}" "${fwd[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 4 --max-time 15 \
      -H "Authorization: Bearer ${token}" "${base%/}${KC_HTTP_PREFIX:-}/admin/realms/${KEYCLOAK_REALM}" || echo "000")
    [[ "$code" == "200" ]] && return 0
    log "Keycloak admin API not ready yet (HTTP ${code}); retrying..."
    sleep 3
    n=$((n + 1))
  done
  return 1
}

# PUT with same Host / TLS options as curl_kc (admin API).
_kc_admin_put_http_code() {
  local url="$1" datafile="$2"
  local kf=() fwd=()
  kc_ensure_portforward_alive
  [[ "${KC_TLS_INSECURE:-}" == "1" ]] && kf+=(-k)
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    fwd+=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  fi
  curl -sS "${kf[@]}" "${fwd[@]}" -o /dev/null -w "%{http_code}" -X PUT "${url}" \
    -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" --data-binary @"${datafile}" || echo "000"
}

# When devops realm was bootstrapped empty (or import missing), create the OnCall OIDC client so PATCH can run.
kc_ensure_oncall_client_exists() {
  local root kf=() fwd=() qcli clients_json cid code body
  kc_ensure_portforward_alive
  root="$(kc_local_root)"
  [[ "${KC_TLS_INSECURE:-}" == "1" ]] && kf+=(-k)
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    fwd+=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  fi
  qcli=$(jq -rn --arg c "${ONCALL_CLIENT_ID}" '$c|@uri')
  clients_json=$(curl -sS "${kf[@]}" "${fwd[@]}" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    "${root}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${qcli}" || true)
  cid=$(echo "$clients_json" | jq -r '.[0].id // empty')
  if [[ -n "$cid" && "$cid" != "null" ]]; then
    return 0
  fi
  log "Keycloak client ${ONCALL_CLIENT_ID} missing; creating public OIDC client"
  body=$(jq -n \
    --arg cid "${ONCALL_CLIENT_ID}" \
    '{
      clientId: $cid,
      name: $cid,
      enabled: true,
      publicClient: true,
      protocol: "openid-connect",
      standardFlowEnabled: true,
      directAccessGrantsEnabled: true,
      implicitFlowEnabled: false,
      serviceAccountsEnabled: false,
      redirectUris: [
        "https://oncall.devops.local/*",
        "https://oncall.devops.local/oauth/callback",
        "https://oncall.devops.local/oauth/callback/complete/grafana-oauth/",
        "https://oncall.devops.local/oauth/callback/complete/grafana-oauth/*"
      ],
      webOrigins: ["+", "https://oncall.devops.local"]
    }')
  code=$(curl -sS "${kf[@]}" "${fwd[@]}" -o /dev/null -w "%{http_code}" -X POST \
    "${root}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
    --data-binary "${body}" || echo "000")
  [[ "$code" == "201" ]] || die "Could not create Keycloak client ${ONCALL_CLIENT_ID} (HTTP ${code})"
}

# Prefer engine Deployment env secretKeyRef, then scan secrets for common PG name/key patterns.
_discover_pg_secret() {
  local ns="$1" engine_deploy="${2:-}" ref
  if [[ -n "${ONCALL_PG_SECRET:-}" ]]; then
    if kubectl get secret "${ONCALL_PG_SECRET}" -n "$ns" &>/dev/null; then
      echo "${ONCALL_PG_SECRET}"
      return 0
    fi
    die "ONCALL_PG_SECRET=${ONCALL_PG_SECRET} not found in namespace ${ns}"
  fi
  if [[ -n "$engine_deploy" ]]; then
    ref=$(kubectl get "deploy/${engine_deploy}" -n "$ns" -o json 2>/dev/null | jq -r '
      [
        (.spec.template.spec.containers[]?.env[]?
          | select(.valueFrom.secretKeyRef != null)
          | select(.name != null)
          | select((.name // "" | tostring | ascii_downcase | test("postgres|pgpass|database|jdbc|db_|sql|datasource")))
          | .valueFrom.secretKeyRef.name),
        (.spec.template.spec.containers[]?.envFrom[]? | .secretRef.name // empty)
      ] | .[] | select(type == "string" and length > 0)' | head -1)
    if [[ -n "$ref" && "$ref" != "null" ]] && kubectl get secret "$ref" -n "$ns" &>/dev/null; then
      echo "$ref"
      return 0
    fi
  fi
  kubectl get secret -n "$ns" -o json 2>/dev/null | jq -r '
    .items[]?
    | (.type | tostring) as $st
    | (.metadata.name // "" | tostring | ascii_downcase) as $sn
    | select($st | test("kubernetes.io/tls|helm.sh/release") | not)
    | select($sn | test("tls|grafana|redis|rabbit|jwt|oauth|istio|keycloak|basic-auth") | not)
    | select(
        ($sn | test("postgres"))
        or (($sn | test("oncall")) and (($sn | test("db")) or ($sn | test("sql")) or ($sn | test("pg"))))
        or ($sn | test("database"))
        or ($sn | test("jdbc"))
        or ($sn | test("-pg-"))
        or ($sn | test("pgsql"))
      )
    | select((.data // {}) as $d |
        (($d.password // empty | length) > 0)
        or (($d["postgres-password"] // empty | length) > 0)
        or (($d["postgresql-password"] // empty | length) > 0)
        or (($d["postgresql-postgres-password"] // empty | length) > 0)
        or (($d["db-password"] // empty | length) > 0)
      )
    | .metadata.name' | head -1
}

_discover_pg_svc() {
  local ns="$1"
  kubectl get svc -n "$ns" -o json 2>/dev/null | jq -r '
    .items[]?
    | (.metadata.name // "" | tostring | ascii_downcase) as $sn
    | select(.spec.clusterIP != null and .spec.clusterIP != "None")
    | select($sn | test("redis|rabbit") | not)
    | select(
        ($sn | test("postgres"))
        or (($sn | test("oncall")) and (($sn | test("db")) or ($sn | test("sql")) or ($sn | test("pg"))))
        or ($sn | test("-pg-"))
        or ($sn | test("pgsql"))
      )
    | .metadata.name' | head -1
}

# Wait for batch Job to finish. Return 0=Complete, 2=Failed, 1=timeout/missing.
# Avoid relying only on `kubectl wait --for=condition=complete`: failed Jobs never become Complete,
# and ttlSecondsAfterFinished can delete the Job before a long wait ends (then logs show NotFound).
_escalation_job_wait_done() {
  local ns="$1" job="$2" timeout="${3:-180}"
  local t=0 saw=0 comp fail
  while (( t < timeout )); do
    if kubectl get "job/${job}" -n "${ns}" &>/dev/null; then
      saw=1
      comp=$(kubectl get "job/${job}" -n "${ns}" -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Complete") | .status' | head -1)
      [[ "$comp" == "True" ]] && return 0
      fail=$(kubectl get "job/${job}" -n "${ns}" -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Failed") | .status' | head -1)
      [[ "$fail" == "True" ]] && return 2
    elif (( saw )); then
      log "Escalation Job ${job} disappeared while waiting (TTL/GC?)"
      return 1
    fi
    sleep 2
    t=$((t + 2))
  done
  return 1
}

# --- In-place OnCall corruption (existing ConfigMaps / Secrets / literals only; no task-* resources) ---
_nebula_deploy_envfrom_configmap_names() {
  kubectl get "deploy/$1" -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r '
    .spec.template.spec.containers[]?.envFrom[]?
    | select(.configMapRef != null)
    | .configMapRef.name // empty
  ' | sort -u
}

_nebula_deploy_ttl_configmapkeyref_names() {
  kubectl get "deploy/$1" -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r '
    .spec.template.spec.containers[]?.env[]?
    | select((.name // "") == "ACKNOWLEDGE_TOKEN_TTL_SECONDS" or (.name // "") == "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS")
    | .valueFrom.configMapKeyRef.name // empty
  ' | sort -u
}

_nebula_corrupt_ttl_in_existing_configmaps() {
  local dep="$1" low="${2:-1800}"
  local cm
  while IFS= read -r cm || [[ -n "${cm:-}" ]]; do
    [[ -z "${cm}" || "${cm}" == "null" ]] && continue
    kubectl get configmap "${cm}" -n "${ONCALL_NS}" &>/dev/null || continue
    kubectl patch configmap "${cm}" -n "${ONCALL_NS}" --type=merge \
      -p "{\"data\":{\"ACKNOWLEDGE_TOKEN_TTL_SECONDS\":\"${low}\",\"INCIDENT_PUBLIC_TOKEN_TTL_SECONDS\":\"${low}\"}}" \
      >/dev/null 2>&1 || true
  done < <(_nebula_deploy_envfrom_configmap_names "${dep}")
}

_nebula_corrupt_ttl_in_configmapkeyref_sources() {
  local dep="$1" low="${2:-1800}"
  local cm
  while IFS= read -r cm || [[ -n "${cm:-}" ]]; do
    [[ -z "${cm}" || "${cm}" == "null" ]] && continue
    kubectl get configmap "${cm}" -n "${ONCALL_NS}" &>/dev/null || continue
    kubectl patch configmap "${cm}" -n "${ONCALL_NS}" --type=merge \
      -p "{\"data\":{\"ACKNOWLEDGE_TOKEN_TTL_SECONDS\":\"${low}\",\"INCIDENT_PUBLIC_TOKEN_TTL_SECONDS\":\"${low}\"}}" \
      >/dev/null 2>&1 || true
  done < <(_nebula_deploy_ttl_configmapkeyref_names "${dep}")
}

_nebula_seed_ttl_policy_configmap() {
  local cm="$1" low="$2"
  kubectl create configmap "${cm}" -n "${ONCALL_NS}" \
    --from-literal=ACKNOWLEDGE_TOKEN_TTL_SECONDS="${low}" \
    --from-literal=INCIDENT_PUBLIC_TOKEN_TTL_SECONDS="${low}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
    || die "TTL policy ConfigMap apply failed: ${ONCALL_NS}/${cm}"
}

# Primary TTL break: dedicated policy ConfigMaps wired via envFrom.configMapRef (grader resolves envFrom CMs).
# Apply to every container: charts that put a sidecar/metrics/compat container first would otherwise leave
# the real oncall-celery/worker with no policy envFrom (and verify_oncall_ttl_broken_runtime finds no TTL vars).
_nebula_pin_ttl_envfrom_configmaps() {
  local dep="${1:?deployment required}"
  local cm1="${2:?primary ConfigMap required}"
  local cm2="${3:-}"

  if kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq \
    --arg cm1 "$cm1" \
    --arg cm2 "$cm2" '
    .spec.template.spec.containers |= map(
      . as $c |
      ($c.envFrom // []) as $e |
      ($e | map(((.configMapRef // {}).name // empty))) as $names |
      .envFrom = $e
        + (
            if ($cm1 != "" and (($names | index($cm1)) == null))
            then [{configMapRef:{name:$cm1}}]
            else []
            end
          )
        + (
            if ($cm2 != "" and (($names | index($cm2)) == null))
            then [{configMapRef:{name:$cm2}}]
            else []
            end
          )
    )
  ' | kubectl apply -f - >/dev/null 2>&1; then
    return 0
  fi

  warn "TTL envFrom pin apply failed for deployment/${dep}"
  return 1
}

_nebula_append_envfrom_configmap() {
  local dep="$1" cm="$2"
  [[ -n "${cm}" ]] || return 0
  if kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq --arg cm "$cm" '
    .spec.template.spec.containers |= map(
      . as $c |
      ($c.envFrom // []) as $e |
      ($e | map(((.configMapRef // {}).name // empty))) as $names |
      .envFrom = $e + (if ($names | index($cm)) == null then [{configMapRef:{name:$cm}}] else [] end)
    )
  ' | kubectl apply -f - >/dev/null 2>&1; then
    return 0
  fi
  warn "envFrom ConfigMap append failed for deployment/${dep} cm=${cm}"
  return 1
}

# Merge low TTL literals into every workload container. Charts often expose TTL only via envFrom
# ConfigMap keys; without matching env{} entries the old jq path was a no-op and pods had no vars.
_nebula_patch_literal_ttl_on_deploy() {
  local dep="$1" low="$2"
  kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq \
    --arg low "$low" '
    def ensure_ttl_env($env; $low):
      (($env // [])
      | map(
          if (.name == "ACKNOWLEDGE_TOKEN_TTL_SECONDS" or .name == "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS") then
            {name: .name, value: $low}
          else . end
        )) as $m
      | (if ($m | any(.name == "ACKNOWLEDGE_TOKEN_TTL_SECONDS")) then $m else $m + [{name:"ACKNOWLEDGE_TOKEN_TTL_SECONDS", value:$low}] end)
      | if any(.name == "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS") then . else . + [{name:"INCIDENT_PUBLIC_TOKEN_TTL_SECONDS", value:$low}] end;

    .spec.template.spec.containers |= map(. * {env: ensure_ttl_env(.env; $low)})
  ' | kubectl apply -f - >/dev/null || warn "TTL literal merge apply failed for deployment/${dep}"
}

# kubectl set env updates the live Deployment reliably when apply/json paths are finicky.
_nebula_kubectl_set_env_ttl_all_containers() {
  local dep="$1" low="$2" c
  while read -r c; do
    [[ -z "${c}" ]] && continue
    kubectl set env "deployment/${dep}" -n "${ONCALL_NS}" \
      "ACKNOWLEDGE_TOKEN_TTL_SECONDS=${low}" \
      "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS=${low}" \
      -c "${c}" --overwrite >/dev/null 2>&1 || true
  done < <(kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
}

_nebula_grafana_secret_names_from_deploy() {
  kubectl get "deploy/$1" -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r '
    [
      (.spec.template.spec.containers[]?.env[]?
        | select(.valueFrom.secretKeyRef != null)
        | .valueFrom.secretKeyRef.name // empty),
      (.spec.template.spec.containers[]?.envFrom[]?
        | select((.secretRef.name // "") | length > 0)
        | .secretRef.name)
    ] | unique[] | select(length > 0)
  '
  kubectl get secret -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r '
    .items[]?
    | (.data // {}) as $d
    | select(($d | has("grafana_token")) or ($d | has("GRAFANA_API_KEY")) or ($d | has("GRAFANA_TOKEN")))
    | .metadata.name // empty
  '
}

_nebula_patch_grafana_secret_stringdata() {
  local sec="$1" tok="$2"
  [[ -z "${sec}" ]] && return 1
  kubectl get secret "${sec}" -n "${ONCALL_NS}" &>/dev/null || return 1
  kubectl patch secret "${sec}" -n "${ONCALL_NS}" --type=merge \
    -p "$(jq -n --arg t "$tok" '{stringData:{GRAFANA_API_KEY:$t,GRAFANA_TOKEN:$t,grafana_token:$t}}')" \
    >/dev/null || return 1
  return 0
}

_nebula_seed_grafana_secret() {
  local sec="$1" tok="$2"
  kubectl create secret generic "${sec}" -n "${ONCALL_NS}" \
    --from-literal=grafana_token="${tok}" \
    --from-literal=GRAFANA_API_KEY="${tok}" \
    --from-literal=GRAFANA_TOKEN="${tok}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
    || die "Grafana auth Secret apply failed: ${ONCALL_NS}/${sec}"
}

_nebula_pin_grafana_secretkeyref() {
  local dep="$1" sec="$2"
  kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq --arg sec "$sec" '
    def force_graf($env):
      (($env // [])
      | map(select((.name // "") != "GRAFANA_API_KEY" and (.name // "") != "GRAFANA_TOKEN")))
      + [
          {name:"GRAFANA_API_KEY", valueFrom:{secretKeyRef:{name:$sec, key:"GRAFANA_API_KEY"}}},
          {name:"GRAFANA_TOKEN", valueFrom:{secretKeyRef:{name:$sec, key:"GRAFANA_TOKEN"}}}
        ];
    .spec.template.spec.containers |= map(. * {env: force_graf(.env)})
  ' | kubectl apply -f - >/dev/null 2>&1 || warn "Grafana secretKeyRef pin failed for deployment/${dep}"
}

_nebula_drop_grafana_secretkeyref() {
  local dep="$1"
  kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq '
    .spec.template.spec.containers |= map(
      . as $c |
      ($c.env // []) as $e |
      .env = ($e | map(select((.name // "") != "GRAFANA_API_KEY" and (.name // "") != "GRAFANA_TOKEN")))
    )
  ' | kubectl apply -f - >/dev/null 2>&1 || warn "Grafana secretKeyRef drop failed for deployment/${dep}"
}

_nebula_append_grafana_envfrom_secret() {
  local dep="$1" sec="$2"
  kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq --arg sec "$sec" '
    .spec.template.spec.containers |= map(
      . as $c |
      ($c.envFrom // []) as $e |
      ($e | map(.secretRef.name // empty)) as $names |
      .envFrom = $e
        + (if ($names | index($sec)) == null then [{secretRef:{name:$sec}}] else [] end)
    )
  ' | kubectl apply -f - >/dev/null 2>&1 || warn "Grafana envFrom secretRef append failed for deployment/${dep}"
}

# Remove any reusable literal Grafana token in Deployment initContainers/containers.
# Agents were copying a working init-container token; scrub it to enforce mint+wire behavior.
_nebula_scrub_grafana_literal_tokens_in_deploy() {
  local dep="$1" tok="$2"
  [[ -n "${dep}" && -n "${tok}" ]] || return 0
  kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json 2>/dev/null | jq --arg t "$tok" '
    def scrub_env($env):
      ($env // []) | map(
        if ((.name // "") == "GRAFANA_API_KEY" or (.name // "") == "GRAFANA_TOKEN" or (.name // "") == "grafana_token")
           and (.value? != null)
        then {name: .name, value: $t}
        else .
        end
      );
    .spec.template.spec.initContainers = ((.spec.template.spec.initContainers // []) | map(. * {env: scrub_env(.env)}))
    | .spec.template.spec.containers = ((.spec.template.spec.containers // []) | map(. * {env: scrub_env(.env)}))
  ' | kubectl apply -f - >/dev/null 2>&1 || warn "Grafana literal token scrub failed for deployment/${dep}"
}

# Charts often wire Grafana only via envFrom Secret; no GRAFANA_* rows in env{} — old jq was a no-op.
_nebula_patch_grafana_literal_env_on_deploy() {
  local dep="$1" tok="$2"
  kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq \
    --arg t "$tok" '
    def ensure_grafana_env($env; $t):
      (($env // [])
      | map(
          if .name == "GRAFANA_API_KEY" or .name == "GRAFANA_TOKEN" then {name: .name, value: $t}
          else . end
        )) as $m
      | (if ($m | any(.name == "GRAFANA_API_KEY")) then $m else $m + [{name:"GRAFANA_API_KEY", value:$t}] end)
      | if any(.name == "GRAFANA_TOKEN") then . else . + [{name:"GRAFANA_TOKEN", value:$t}] end;

    .spec.template.spec.containers |= map(. * {env: ensure_grafana_env(.env; $t)})
  ' | kubectl apply -f - >/dev/null || warn "Grafana literal merge apply failed for deployment/${dep}"
}

_nebula_kubectl_set_env_grafana_all_containers() {
  local dep="$1" tok="$2" c
  while read -r c; do
    [[ -z "${c}" ]] && continue
    kubectl set env "deployment/${dep}" -n "${ONCALL_NS}" \
      "GRAFANA_API_KEY=${tok}" \
      "GRAFANA_TOKEN=${tok}" \
      -c "${c}" --overwrite >/dev/null 2>&1 || true
  done < <(kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
}

# Without istio-proxy, AuthorizationPolicy CRs apply in config only — HTTP probes stay 200/404 (verify 0/8).
_nebula_ensure_istio_sidecar_on_oncall_workloads() {
  local ns="${ONCALL_NS}" rev
  kubectl get ns "${ns}" &>/dev/null || return 0
  rev=$(kubectl get pods -n istio-system -o json 2>/dev/null | jq -r '
    [.items[]?
      | select((.metadata.name // "") | test("istiod"))
      | (.metadata.labels // {})["istio.io/rev"] // empty
    ] | map(select(length > 0)) | .[0] // empty
  ')
  [[ -z "${rev}" ]] && rev=$(kubectl get pods -n istio-system --field-selector=status.phase=Running -o json 2>/dev/null \
    | jq -r '[.items[]? | (.metadata.labels // {})["istio.io/rev"] // empty] | map(select(length > 0)) | .[0] // empty')
  kubectl label namespace "${ns}" istio-injection=enabled --overwrite 2>/dev/null || true
  if [[ -n "${rev}" && "${rev}" != "null" ]]; then
    kubectl label namespace "${ns}" "istio.io/rev=${rev}" --overwrite 2>/dev/null || true
  fi
  for dep in "${ONCALL_ENGINE_DEPLOY}" "${ONCALL_CELERY_DEPLOY}"; do
    kubectl get "deploy/${dep}" -n "${ns}" &>/dev/null || continue
    kubectl get "deploy/${dep}" -n "${ns}" -o json \
      | jq '.spec.template.metadata.annotations = (.spec.template.metadata.annotations // {})
          | .spec.template.metadata.annotations["sidecar.istio.io/inject"] = "true"' \
      | kubectl apply -f - >/dev/null 2>&1 || warn "Istio: could not set sidecar.istio.io/inject on deployment/${dep}"
  done
  log "Istio: namespace ${ns} labeled for injection; engine/celery pod template annotated sidecar.istio.io/inject=true"
}

_nebula_running_engine_pod_has_istio_proxy() {
  kubectl get pods -n "${ONCALL_NS}" -o json 2>/dev/null | jq -e --arg d "${ONCALL_ENGINE_DEPLOY}" '
    [.items[]?
      | select(.status.phase == "Running")
      | select((.metadata.name // "") | ascii_downcase | contains($d | ascii_downcase))
      | .spec.containers[]?.name // empty
    ] | map(ascii_downcase) | any(. == "istio-proxy")
  ' >/dev/null 2>&1
}

_nebula_wait_oncall_engine_istio_proxy() {
  local t=0
  log "Waiting for istio-proxy on Running ${ONCALL_ENGINE_DEPLOY} pods (${ISTIO_SIDECAR_WAIT_SEC}s max)..."
  while (( t < ISTIO_SIDECAR_WAIT_SEC )); do
    if _nebula_running_engine_pod_has_istio_proxy; then
      log "istio-proxy is present on ${ONCALL_ENGINE_DEPLOY}"
      return 0
    fi
    sleep 5
    t=$((t + 5))
  done
  return 1
}

# When istio-proxy is absent, HTTP probes cannot show 403; still require the broken policy object to exist.
_verify_istio_seed_authorization_policy_present() {
  local _ok1=0 _ok2=0
  kubectl get "authorizationpolicy/${ISTIO_MESH_DENY_POLICY}" -n "${ONCALL_NS}" -o json 2>/dev/null | jq -e '
    (.spec.action // "") == "DENY"
    and (
      [.spec.rules[]? | .to[]? | (.operation.paths // [])[]? | tostring]
      | join(" ") | ascii_downcase
      | (test("integrations") and test("public-api"))
    )
  ' >/dev/null 2>&1 && _ok1=1 || true
  kubectl get "authorizationpolicy/${ISTIO_MESH_DENY_POLICY_SECOND}" -n "${ONCALL_NS}" -o json 2>/dev/null | jq -e '
    (.spec.action // "") == "DENY"
    and (
      [.spec.rules[]? | .to[]? | (.operation.paths // [])[]? | tostring]
      | join(" ") | ascii_downcase
      | (test("integrations") and test("public-api"))
    )
  ' >/dev/null 2>&1 && _ok2=1 || true
  [[ "${_ok1}" == "1" && "${_ok2}" == "1" ]]
}

# Match grader discover_oncall_service_url: score svc names (engine > grafana-oncall > oncall),
# support ClusterIP, headless + Endpoints, then engine pod IP fallback.
_setup_discover_engine_http_base() {
  local ns="${ONCALL_NS}" json name cluster_ip port pip ep_port
  json=$(kubectl get svc -n "${ns}" -o json 2>/dev/null) || return 1
  name=$(echo "$json" | jq -r '
    [.items[]?
      | .metadata.name as $n
      | ($n | ascii_downcase) as $l
      | select(($l | test("redis|rabbit|postgres|pgsql")) | not)
      | {name: $n, sc: (
          if ($l | contains("engine")) then 3
          elif ($l | contains("grafana-oncall")) then 2
          elif ($l | contains("oncall")) then 1
          else 0 end
        )}
    ]
    | map(select(.sc > 0))
    | if length == 0 then empty else sort_by(-.sc) | .[0].name end
  ')
  [[ -z "${name}" || "${name}" == "null" ]] && return 1
  cluster_ip=$(kubectl get svc "${name}" -n "${ns}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  port=$(kubectl get svc "${name}" -n "${ns}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
  port="${port:-8080}"
  if [[ -n "${cluster_ip}" && "${cluster_ip}" != "None" ]]; then
    echo "http://${cluster_ip}:${port}"
    return 0
  fi
  pip=$(kubectl get endpoints "${name}" -n "${ns}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  if [[ -n "${pip}" ]]; then
    ep_port=$(kubectl get endpoints "${name}" -n "${ns}" -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null)
    ep_port="${ep_port:-${port}}"
    echo "http://${pip}:${ep_port}"
    return 0
  fi
  _setup_discover_engine_http_base_pod_fallback || return 1
}

_setup_discover_engine_http_base_pod_fallback() {
  local ns="${ONCALL_NS}" pod pip port
  pod="$(_first_running_pod_setup "${ONCALL_ENGINE_DEPLOY}")"
  [[ -z "${pod}" ]] && return 1
  pip=$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.podIP}' 2>/dev/null)
  port=$(kubectl get pod "${pod}" -n "${ns}" -o json 2>/dev/null | jq -r '
    ([.spec.containers[]?.ports[]? | .containerPort // empty]
      | map(select(. == 8080 or . == 8000 or . == 3000)) | .[0])
    // ([.spec.containers[]?.ports[]? | .containerPort // empty] | .[0])
    // 8080
  ')
  [[ -z "${pip}" ]] && return 1
  port="${port:-8080}"
  echo "http://${pip}:${port}"
}

_setup_http_code() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 "$1" 2>/dev/null || echo "000")
  if [[ "${code}" == "000" || -z "${code}" ]] && [[ "$1" == http://* ]]; then
    code=$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 \
      "https://${1#http://}" 2>/dev/null || echo "000")
  fi
  echo "${code}"
}

# In-cluster GET to engine Service DNS (hits engine inbound + Istio RBAC). Prefer celery as client
# so traffic is pod→Service (not hairpin via same pod IP). If curl returns 000, try next workload.
_setup_http_code_from_engine_pod() {
  local url="$1" ns="${ONCALL_NS}" pod ctr d code
  local -a trydeps=("${ONCALL_CELERY_DEPLOY}" "${ONCALL_ENGINE_DEPLOY}")
  for d in "${trydeps[@]}"; do
    pod="$(_first_running_pod_setup "${d}")"
    [[ -z "${pod}" ]] && continue
    ctr="$(_nebula_deploy_first_container_name "${d}")"
    local -a xec=(kubectl exec -n "${ns}" "${pod}")
    [[ -n "${ctr}" ]] && xec+=(-c "${ctr}")
    if "${xec[@]}" -- sh -c 'command -v curl >/dev/null 2>&1' 2>/dev/null; then
      code="$("${xec[@]}" -- curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 "${url}" 2>/dev/null || echo "000")"
      [[ "${code}" != "000" ]] && { echo "${code}"; return; }
      continue
    fi
    if "${xec[@]}" -- sh -c 'command -v wget >/dev/null 2>&1' 2>/dev/null; then
      code="$("${xec[@]}" -- wget -q -S -O /dev/null "${url}" 2>&1 | awk '/HTTP\// { print $2; exit }' | head -1)"
      [[ -n "${code}" && "${code}" != "000" ]] && { echo "${code}"; return; }
      continue
    fi
    if "${xec[@]}" -- sh -c 'command -v python3 >/dev/null 2>&1' 2>/dev/null; then
      code="$("${xec[@]}" -- python3 -c 'import sys,urllib.request,urllib.error
u=sys.argv[1]
try:
    urllib.request.urlopen(u, timeout=12)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("000")' "${url}" 2>/dev/null || echo "000")"
      [[ "${code}" != "000" ]] && { echo "${code}"; return; }
    fi
  done
  echo "000"
}

_pod_printenv_setup() {
  local ns="$1" pod="$2" ctr="$3" key="$4"
  if [[ -n "${ctr}" ]]; then
    kubectl exec -n "${ns}" "${pod}" -c "${ctr}" -- printenv "${key}" 2>/dev/null || true
  else
    kubectl exec -n "${ns}" "${pod}" -- printenv "${key}" 2>/dev/null || true
  fi
}

_first_running_pod_setup() {
  local dep="$1"
  local sel
  sel="$(kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r '
    .spec.selector.matchLabels // {}
    | to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  ')"
  if [[ -n "${sel}" && "${sel}" != "null" ]]; then
    kubectl get pods -n "${ONCALL_NS}" -l "${sel}" -o json 2>/dev/null | jq -r '
      [.items[]?
        | select((.status.phase // "") == "Running")
        | select(.metadata.deletionTimestamp == null)
        | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)
      ] | sort_by(.metadata.creationTimestamp) | reverse | .[0].metadata.name // empty
    '
    return
  fi
  kubectl get pods -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r --arg d "$dep" '
    [.items[]?
      | select((.status.phase // "") == "Running")
      | select(.metadata.deletionTimestamp == null)
      | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)
      | select((.metadata.name // "") | ascii_downcase | contains($d | ascii_downcase))
    ] | sort_by(.metadata.creationTimestamp) | reverse | .[0].metadata.name // empty
  '
}

_first_container_setup() {
  local pod="$1"
  kubectl get pod "${pod}" -n "${ONCALL_NS}" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo ""
}

# Match grader: use Deployment template's first container for printenv (not Pod.containers[0], which
# can differ if admission reordering or extra containers appear in the live Pod).
_nebula_deploy_first_container_name() {
  kubectl get "deploy/$1" -n "${ONCALL_NS}" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || echo ""
}

verify_oncall_ttl_broken_runtime() {
  local pod dep c ack pub any_ctr attempt
  for dep in "${ONCALL_ENGINE_DEPLOY}" "${ONCALL_CELERY_DEPLOY}"; do
    any_ctr=0
    for attempt in $(seq 1 20); do
      pod="$(_first_running_pod_setup "${dep}")"
      [[ -n "${pod}" ]] || { sleep 3; continue; }
      any_ctr=0
      while read -r c; do
        [[ -z "${c}" ]] && continue
        ack="$(_pod_printenv_setup "${ONCALL_NS}" "${pod}" "${c}" "ACKNOWLEDGE_TOKEN_TTL_SECONDS" | tr -d '\r\n')"
        pub="$(_pod_printenv_setup "${ONCALL_NS}" "${pod}" "${c}" "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS" | tr -d '\r\n')"
        [[ -z "${ack}" && -z "${pub}" ]] && continue
        any_ctr=1
        [[ "${ack}" =~ ^[0-9]+$ && "${pub}" =~ ^[0-9]+$ ]] \
          || die "verify_oncall_ttl_broken_runtime: ${dep} pod ${pod} ctr=${c} incomplete TTL (ack=${ack} pub=${pub})"
        (( ack < 7200 && pub < 7200 )) \
          || die "verify_oncall_ttl_broken_runtime: ${dep} pod ${pod} ctr=${c} TTL not broken (ack=${ack} pub=${pub} need <7200)"
      done < <(kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
      (( any_ctr == 1 )) && break
      sleep 3
    done
    (( any_ctr == 1 )) || die "verify_oncall_ttl_broken_runtime: ${dep} pod ${pod:-<none>}: no container exposed TTL vars after rollout"
  done
  log "verify_oncall_ttl_broken_runtime: OK (every TTL-exposing container <7200s on engine+celery)"
}

verify_grafana_broken_runtime() {
  local pod dep c ga gt code gurl ip gport eng_tok any_ctr tok probed attempt
  declare -A _gf_seen_probe=()
  gurl=""
  ip="$(kubectl get svc -n "${MONITORING_NS}" grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  gport="$(kubectl get svc -n "${MONITORING_NS}" grafana -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "3000")"
  [[ -n "${ip}" ]] && gurl="http://${ip}:${gport}"

  eng_tok=""
  for dep in "${ONCALL_ENGINE_DEPLOY}" "${ONCALL_CELERY_DEPLOY}"; do
    any_ctr=0
    for attempt in $(seq 1 20); do
      pod="$(_first_running_pod_setup "${dep}")"
      [[ -n "${pod}" ]] || { sleep 3; continue; }
      any_ctr=0
      while read -r c; do
        [[ -z "${c}" ]] && continue
        ga="$(_pod_printenv_setup "${ONCALL_NS}" "${pod}" "${c}" "GRAFANA_API_KEY" | tr -d '\r\n')"
        gt="$(_pod_printenv_setup "${ONCALL_NS}" "${pod}" "${c}" "GRAFANA_TOKEN" | tr -d '\r\n')"
        [[ -z "${ga}" && -z "${gt}" ]] && continue
        any_ctr=1
        [[ -n "${ga}" && -n "${gt}" ]] || die "verify_grafana_broken_runtime: ${dep} pod ${pod} ctr=${c} incomplete GRAFANA_*"
        [[ "${ga}" == "${gt}" ]] || die "verify_grafana_broken_runtime: ${dep} pod ${pod} ctr=${c} GRAFANA_API_KEY != GRAFANA_TOKEN"
        if [[ "${dep}" == "${ONCALL_ENGINE_DEPLOY}" ]]; then
          [[ -z "${eng_tok}" ]] && eng_tok="${ga}"
          [[ "${ga}" == "${eng_tok}" ]] || die "verify_grafana_broken_runtime: engine ctr=${c} token differs from first engine token"
        else
          [[ -n "${eng_tok}" && "${ga}" == "${eng_tok}" ]] \
            || die "verify_grafana_broken_runtime: celery ctr=${c} token differs from engine token"
        fi
        if [[ -n "${gurl}" ]]; then
          tok="${ga}"
          probed="${_gf_seen_probe[${tok}]:-}"
          if [[ -z "${probed}" ]]; then
            _gf_seen_probe["${tok}"]=1
            code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${tok}" \
              --connect-timeout 3 --max-time 10 "${gurl}/api/org" 2>/dev/null || echo "000")"
            [[ "${code}" == "200" ]] && die "verify_grafana_broken_runtime: Grafana still accepts token (HTTP ${code}) dep=${dep} ctr=${c}"
          fi
        fi
      done < <(kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
      (( any_ctr == 1 )) && break
      sleep 3
    done
    (( any_ctr >= 1 )) || die "verify_grafana_broken_runtime: ${dep} pod ${pod:-<none>}: no container exposes GRAFANA_* after rollout"
  done
  log "verify_grafana_broken_runtime: OK (every Grafana-exposing container aligned; Grafana not 200)"
}

verify_istio_broken_state() {
  local base sname port int_base hits_ext hits_in p code hits attempt
  local -a istio_paths=(
    /integrations/v1/ /integrations/ /public-api/v1/ /public-api/
    /oncall/integrations/v1/ /oncall/integrations/ /oncall/public-api/ /oncall/public-api/v1/
  )
  base="$(_setup_discover_engine_http_base)" || die "verify_istio_broken_state: no engine service base"
  sname=$(kubectl get svc -n "${ONCALL_NS}" -o json 2>/dev/null | jq -r '
    [.items[]?
      | .metadata.name as $n
      | ($n | ascii_downcase) as $l
      | select(($l | test("redis|rabbit|postgres|pgsql")) | not)
      | {name: $n, sc: (
          if ($l | contains("engine")) then 3
          elif ($l | contains("grafana-oncall")) then 2
          elif ($l | contains("oncall")) then 1
          else 0 end
        )}
    ]
    | map(select(.sc > 0))
    | if length == 0 then empty else sort_by(-.sc) | .[0].name end
  ')
  [[ -z "${sname}" || "${sname}" == "null" ]] && sname="${ONCALL_ENGINE_DEPLOY}"
  port=$(kubectl get svc "${sname}" -n "${ONCALL_NS}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
  port="${port:-8080}"
  int_base="http://${sname}.${ONCALL_NS}.svc.cluster.local:${port}"

  for attempt in 1 2 3; do
    hits_ext=0
    hits_in=0
    for p in "${istio_paths[@]}"; do
      code="$(_setup_http_code "${base}${p}")"
      case "${code}" in 401|403|301|302|307|308) hits_ext=$((hits_ext + 1)) ;; *) ;; esac
    done
    for p in "${istio_paths[@]}"; do
      code="$(_setup_http_code_from_engine_pod "${int_base}${p}")"
      code="$(echo "${code}" | tr -d ' \r\n' | head -c 3)"
      case "${code}" in 401|403|301|302|307|308) hits_in=$((hits_in + 1)) ;; *) ;; esac
    done
    hits=$hits_ext
    (( hits_in > hits )) && hits=$hits_in
    if (( hits >= 4 )); then
      log "verify_istio_broken_state: OK (${hits}/8 effective; ext=${hits_ext} in-pod=${hits_in}; attempt=${attempt})"
      return 0
    fi
    (( attempt < 3 )) && sleep 5
  done
  if _nebula_running_engine_pod_has_istio_proxy; then
    die "verify_istio_broken_state: istio-proxy present but probes saw only ${hits}/8 blocked or redirected (ext=${hits_ext} in-pod=${hits_in}); check AuthorizationPolicy paths"
  fi
  _verify_istio_seed_authorization_policy_present \
    || die "verify_istio_broken_state: no istio-proxy and AuthorizationPolicy ${ISTIO_MESH_DENY_POLICY} missing or not DENY on integrations+public-api paths"
  log "verify_istio_broken_state: OK (AuthorizationPolicy ${ISTIO_MESH_DENY_POLICY} verified; no istio-proxy in cluster — HTTP 403 not expected)"
}

verify_keycloak_session_broken_state() {
  local tok realm idle max atl atl_n rm_idle rm_max off_idle off_max bad
  # Use main flow port-forward + KC_TOKEN; nested start/stop here tears down the tunnel and breaks the next admin API+jq.
  tok="${KC_TOKEN:-}"
  [[ -n "${tok}" ]] || die "verify_keycloak_session_broken_state: KC_TOKEN empty (main must obtain token first)"
  realm=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}" -H "Authorization: Bearer ${tok}") || true
  idle=$(echo "${realm}" | jq '.ssoSessionIdleTimeout // 0')
  max=$(echo "${realm}" | jq '.ssoSessionMaxLifespan // 0')
  rm_idle=$(echo "${realm}" | jq '.ssoSessionIdleTimeoutRememberMe // null')
  rm_max=$(echo "${realm}" | jq '.ssoSessionMaxLifespanRememberMe // null')
  off_idle=$(echo "${realm}" | jq '.offlineSessionIdleTimeout // null')
  off_max=$(echo "${realm}" | jq '.offlineSessionMaxLifespan // null')
  atl=$(echo "${realm}" | jq '.accessTokenLifespan')
  (( idle < 14400 )) || die "verify_keycloak_session_broken_state: idle ${idle} not <14400"
  bad=0
  [[ "${max}" =~ ^[0-9]+$ && "${idle}" =~ ^[0-9]+$ && "${max}" -lt "${idle}" ]] && bad=1
  atl_n=$(echo "${realm}" | jq 'try (.accessTokenLifespan | tonumber) catch null')
  [[ -n "${atl_n}" && "${atl_n}" != "null" && "${atl_n}" -le 900 ]] && bad=1
  # Hardened grader also treats missing accessTokenLifespan as broken.
  [[ "${atl}" == "null" ]] && bad=1
  [[ "${rm_idle}" == "0" || "${rm_max}" == "0" ]] && bad=1
  [[ -n "${off_idle}" && "${off_idle}" != "null" && "${off_idle}" -lt 28800 ]] && bad=1
  [[ -n "${off_max}" && "${off_max}" != "null" && "${off_max}" -lt 28800 ]] && bad=1
  (( bad == 1 )) || die "verify_keycloak_session_broken_state: realm max/idle/accessToken no longer failing checks"
  log "verify_keycloak_session_broken_state: OK"
}

verify_keycloak_client_refresh_broken_state() {
  local tok cid cj _urt _reuse _cs_idle _cs_max _off_idle
  tok="${KC_TOKEN:-}"
  [[ -n "${tok}" ]] || die "verify_keycloak_client_refresh_broken_state: KC_TOKEN empty (main must obtain token first)"
  cj=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients?clientId=$(jq -rn --arg c "${ONCALL_CLIENT_ID}" '$c|@uri')" \
    -H "Authorization: Bearer ${tok}")
  cid=$(echo "${cj}" | jq -r '.[0].id // empty')
  [[ -n "${cid}" ]] || die "verify_keycloak_client_refresh_broken_state: client id"
  cj=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${cid}" -H "Authorization: Bearer ${tok}")
  _cs_idle="$(echo "${cj}" | jq -r '(.attributes // {})["client.session.idle.timeout"] // ""')"
  _cs_max="$(echo "${cj}" | jq -r '(.attributes // {})["client.session.max.lifespan"] // ""')"
  _off_idle="$(echo "${cj}" | jq -r '(.attributes // {})["client.offline.session.idle.timeout"] // ""')"
  [[ "${_cs_idle}" =~ ^[0-9]+$ ]] || die "verify_keycloak_client_refresh_broken_state: client.session.idle.timeout missing/non-numeric"
  [[ "${_cs_max}" =~ ^[0-9]+$ ]] || die "verify_keycloak_client_refresh_broken_state: client.session.max.lifespan missing/non-numeric"
  [[ "${_off_idle}" =~ ^[0-9]+$ ]] \
    || die "verify_keycloak_client_refresh_broken_state: client.offline.session.idle.timeout missing/non-numeric"
  (( _cs_idle < 14400 )) || die "verify_keycloak_client_refresh_broken_state: client.session.idle.timeout not broken (<14400 required)"
  (( _cs_max < 28800 )) || die "verify_keycloak_client_refresh_broken_state: client.session.max.lifespan not broken (<28800 required)"
  (( _cs_max >= _cs_idle )) || die "verify_keycloak_client_refresh_broken_state: client.session.max.lifespan fell below idle timeout"
  (( _off_idle < 28800 )) \
    || die "verify_keycloak_client_refresh_broken_state: client.offline.session.idle.timeout not broken (<28800 required)"
  log "verify_keycloak_client_refresh_broken_state: OK"
}

verify_keycloak_callback_broken_state() {
  local tok cid cj
  tok="${KC_TOKEN:-}"
  [[ -n "${tok}" ]] || die "verify_keycloak_callback_broken_state: KC_TOKEN empty (main must obtain token first)"
  cj=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients?clientId=$(jq -rn --arg c "${ONCALL_CLIENT_ID}" '$c|@uri')" \
    -H "Authorization: Bearer ${tok}")
  cid=$(echo "${cj}" | jq -r '.[0].id // empty')
  [[ -n "${cid}" ]] || die "verify_keycloak_callback_broken_state: client id"
  cj=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${cid}" -H "Authorization: Bearer ${tok}")
  echo "${cj}" | jq -e '(.redirectUris // []) | any(type == "string" and . == "https://oncall.devops.local/oauth/callback/complete/grafana-oauth/")' >/dev/null \
    || die "verify_keycloak_callback_broken_state: exact deployed callback missing"
  echo "${cj}" | jq -e '(.redirectUris // []) | any(type == "string" and contains("*"))' >/dev/null \
    || die "verify_keycloak_callback_broken_state: wildcard redirect shortcut missing"
  echo "${cj}" | jq -e '(.redirectUris // []) | any(type == "string" and startswith("http://oncall.devops.local/"))' >/dev/null \
    || die "verify_keycloak_callback_broken_state: http redirect shortcut missing"
  echo "${cj}" | jq -e '((.rootUrl // "") | tostring | contains("/invalid"))' >/dev/null \
    || die "verify_keycloak_callback_broken_state: rootUrl did not move to invalid placeholder"
  echo "${cj}" | jq -e '((.baseUrl // "") | tostring | contains("invalid"))' >/dev/null \
    || die "verify_keycloak_callback_broken_state: baseUrl did not move to invalid placeholder"
  echo "${cj}" | jq -e '((.adminUrl // "") | tostring | contains("/invalid"))' >/dev/null \
    || die "verify_keycloak_callback_broken_state: adminUrl did not move to invalid placeholder"
  # C2 breaks redirects/callbacks only; standard flow may remain enabled on public clients in many Keycloak builds.
  log "verify_keycloak_callback_broken_state: OK"
}

verify_authorize_flow_broken() {
  local q body seen=0 _scheme _url _root
  local -a _auth_queries
  local -a _hdr=()
  q="response_type=code&client_id=${ONCALL_CLIENT_ID}&scope=openid&redirect_uri=$(jq -rn --arg u "${REDIRECT_PROBE_URL}" '$u|@uri')"
  _auth_queries=(
    "${q}"
    "${q}&prompt=login"
    "${q}&max_age=0"
    "${q}&display=popup"
    "${q}&ui_locales=en"
  )
  # Try public hostname first (may fail in locked-down hosted runners with no DNS/hosts write).
  for q in "${_auth_queries[@]}"; do
    for _scheme in https http; do
      body="$(curl -sSk --connect-timeout 5 --max-time 20 \
        "${_scheme}://keycloak.devops.local/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?${q}" 2>/dev/null || true)"
      [[ -n "${body}" ]] && seen=1
      if echo "${body}" | grep -qiE 'kc-form-login|id="kc-form-login"|kc-page-login|login-pf-page|login-pf-header'; then
        warn "verify_authorize_flow_broken: still seeing Keycloak login form (${_scheme})"
        return 1
      fi
    done
  done
  # If ingress IP is known, probe it with Host override (no /etc/hosts dependency).
  if [[ -n "${KEYCLOAK_ING_IP:-}" ]]; then
    for q in "${_auth_queries[@]}"; do
      for _scheme in http https; do
        body="$(curl -sSk --connect-timeout 5 --max-time 20 \
          -H "Host: keycloak.devops.local" -H "X-Forwarded-Host: keycloak.devops.local" \
          -H "X-Forwarded-Proto: ${_scheme}" \
          "${_scheme}://${KEYCLOAK_ING_IP}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?${q}" 2>/dev/null || true)"
        [[ -n "${body}" ]] && seen=1
        if echo "${body}" | grep -qiE 'kc-form-login|id="kc-form-login"|kc-page-login|login-pf-page|login-pf-header'; then
          warn "verify_authorize_flow_broken: still seeing Keycloak login form (${_scheme} via ingress IP)"
          return 1
        fi
      done
    done
  fi
  # Final fallback: local port-forward path (most reliable in hosted environments).
  # Reuse the main port-forward when present; only (re)start if it was torn down.
  if [[ -z "${KC_PF_PID:-}" ]] || ! kill -0 "${KC_PF_PID}" 2>/dev/null; then
    kc_start_portforward
    wait_keycloak_oidc_local "${KC_LOCAL_BASE}" || true
    kc_apply_hostname_hint_if_needed || true
  fi
  _root="$(kc_local_root)"
  if [[ -n "${KC_FORWARD_HOST:-}" ]]; then
    _hdr=(-H "Host: ${KC_FORWARD_HOST}" -H "X-Forwarded-Proto: ${KC_FORWARD_PROTO:-http}" -H "X-Forwarded-Host: ${KC_FORWARD_HOST}")
  else
    _hdr=()
  fi
  for q in "${_auth_queries[@]}"; do
    for _url in \
      "${_root}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?${q}" \
      "${KC_LOCAL_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?${q}" \
      "${KC_LOCAL_BASE}/auth/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?${q}"; do
      body="$(curl -sSk "${_hdr[@]}" --connect-timeout 5 --max-time 20 "${_url}" 2>/dev/null || true)"
      [[ -n "${body}" ]] && seen=1
      if echo "${body}" | grep -qiE 'kc-form-login|id="kc-form-login"|kc-page-login|login-pf-page|login-pf-header'; then
        warn "verify_authorize_flow_broken: still seeing Keycloak login form (localhost probe)"
        return 1
      fi
    done
  done
  if (( seen == 0 )); then
    warn "verify_authorize_flow_broken: empty authorize responses"
    return 1
  fi
  log "verify_authorize_flow_broken: OK (no healthy login form for deployed callback)"
}

verify_escalation_broken_state() {
  local jobn rnd
  rnd="${RANDOM}"
  jobn="nebula-verify-esc-${rnd}"
  kubectl delete job "${jobn}" -n "${ONCALL_NS}" --ignore-not-found >/dev/null 2>&1 || true
  # Do not set ttlSecondsAfterFinished here: some runners/cleanup controllers delete Jobs
  # aggressively which makes `kubectl wait` / `kubectl logs job/...` race and fail with NotFound.
  local _apply_out
  _apply_out="$(
    kubectl apply -f - <<VJOB 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${jobn}
  namespace: ${ONCALL_NS}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: ${PSQL_JOB_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: PGHOST
          value: "${PGHOST_FQDN}"
        - name: PGPORT
          value: "${ESCALATION_DB_PORT}"
        - name: PGDATABASE
          value: "${ESCALATION_DB_NAME}"
        - name: PGUSER
          value: "${ESCALATION_DB_USER}"
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: ${ONCALL_PG_SECRET_NAME}
              key: ${ESCALATION_PG_SECRET_KEY}
        command:
        - /bin/sh
        - -c
        - |
          set -e
          minm=\$(psql -t -A -v ON_ERROR_STOP=1 -c \
            "SELECT COALESCE(MIN(ROUND(EXTRACT(EPOCH FROM wait_delay)/60)),9999)::int FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL;")
          test "\${minm}" -lt 20
          ncol=\$(psql -t -A -v ON_ERROR_STOP=1 -c \
            "SELECT COUNT(*)::int FROM information_schema.columns WHERE table_schema='public' AND table_name='alerts_escalationpolicy' AND column_name='repeat_escalations_rate';")
          if [ "\${ncol}" = "1" ]; then
            nrows=\$(psql -t -A -v ON_ERROR_STOP=1 -c \
              "SELECT COUNT(*)::int FROM alerts_escalationpolicy WHERE repeat_escalations_rate IS NOT NULL;")
            if [ "\${nrows}" != "0" ]; then
              repmin=\$(psql -t -A -v ON_ERROR_STOP=1 -c \
                "SELECT COALESCE(MIN(CAST(substring(repeat_escalations_rate::text from '([0-9]+)') AS int)),99) FROM alerts_escalationpolicy WHERE repeat_escalations_rate IS NOT NULL;")
              test "\${repmin}" -lt 20
            fi
          fi
VJOB
  )" || { echo "${_apply_out}" >&2; die "verify_escalation_broken_state: job apply failed"; }

  # Ensure the Job object exists before waiting on it (avoid NotFound races).
  for _w in $(seq 1 20); do
    kubectl get "job/${jobn}" -n "${ONCALL_NS}" &>/dev/null && break
    sleep 1
  done
  kubectl get "job/${jobn}" -n "${ONCALL_NS}" &>/dev/null || {
    echo "${_apply_out}" >&2
    kubectl get events -n "${ONCALL_NS}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 >&2 || true
    die "verify_escalation_broken_state: job ${jobn} not found after apply"
  }

  kubectl wait --for=condition=complete "job/${jobn}" -n "${ONCALL_NS}" --timeout=120s \
    || {
      kubectl logs "job/${jobn}" -n "${ONCALL_NS}" --tail=120 2>&1 || true
      local _p
      _p="$(kubectl get pods -n "${ONCALL_NS}" -l "job-name=${jobn}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      [[ -n "${_p}" ]] && kubectl logs "pod/${_p}" -n "${ONCALL_NS}" --tail=120 2>&1 || true
      die "verify_escalation_broken_state: job failed"
    }
  kubectl delete job "${jobn}" -n "${ONCALL_NS}" --ignore-not-found >/dev/null 2>&1 || true
  log "verify_escalation_broken_state: OK (min wait <20m; repeat <20m when column+rows exist)"
}

discover_oncall_deployment_by_component() {
  local ns="$1"
  local component="$2"
  local fallback="$3"
  local dep=""

  dep="$(kubectl get deploy -n "$ns" -o json 2>/dev/null | jq -r --arg comp "$component" '
    .items[]?
    | select((.metadata.labels["app.kubernetes.io/name"] // "") == "oncall")
    | select((.metadata.labels["app.kubernetes.io/component"] // "") == $comp)
    | .metadata.name
  ' | head -1)"

  if [[ -n "$dep" && "$dep" != "null" ]]; then
    echo "$dep"
    return 0
  fi

  dep="$(kubectl get deploy -n "$ns" -o json 2>/dev/null | jq -r --arg comp "$component" '
    .items[]?
    | select((.spec.selector.matchLabels["app.kubernetes.io/name"] // "") == "oncall")
    | select((.spec.selector.matchLabels["app.kubernetes.io/component"] // "") == $comp)
    | .metadata.name
  ' | head -1)"

  if [[ -n "$dep" && "$dep" != "null" ]]; then
    echo "$dep"
    return 0
  fi

  if [[ -n "$fallback" ]] && kubectl get "deployment/${fallback}" -n "$ns" >/dev/null 2>&1; then
    echo "$fallback"
    return 0
  fi

  kubectl get deploy -n "$ns" -o json 2>/dev/null | jq -r --arg comp "$component" '
    .items[]?
    | (.metadata.name // "") as $n
    | select(($n | ascii_downcase | test("oncall")))
    | select(($n | ascii_downcase | test($comp)))
    | .metadata.name
  ' | head -1
}

wait_oncall_deployment_ready() {
  local ns="$1"
  local dep="$2"
  local selector
  local ready

  log "Waiting for deployment/${dep} in ${ns} before chaos injection..."

  kubectl rollout status "deployment/${dep}" -n "${ns}" --timeout=300s \
    || die "deployment ${ns}/${dep} rollout did not complete before setup chaos"

  kubectl wait --for=condition=Available "deployment/${dep}" -n "${ns}" --timeout=300s \
    || die "deployment ${ns}/${dep} was not Available before setup chaos"

  selector="$(kubectl get deploy "${dep}" -n "${ns}" -o json | jq -r '
    .spec.selector.matchLabels
    | to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  ')"

  ready="$(kubectl get pods -n "${ns}" -l "${selector}" -o json 2>/dev/null | jq '
    [.items[]?
      | select(.metadata.deletionTimestamp == null)
      | select(.status.phase == "Running")
      | select([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length > 0)
    ] | length
  ')"

  [[ "${ready:-0}" -ge 1 ]] \
    || die "deployment ${ns}/${dep} has no Ready running pods before setup chaos"
}

require_oncall_stack() {
  local ns eng cel sec svc probe_svc
  ns="${ONCALL_NS}"
  eng="$(discover_oncall_deployment_by_component "$ns" "engine" "${ONCALL_ENGINE_DEPLOY}")"
  cel="$(discover_oncall_deployment_by_component "$ns" "celery" "${ONCALL_CELERY_DEPLOY}")"
  kubectl get "ns/${ns}" &>/dev/null || die "namespace ${ns} missing (OnCall runs in bleater; set ONCALL_NS only if relocated)"
  [[ -n "$eng" ]] || die "could not discover OnCall engine Deployment in ${ns} by labels"
  [[ -n "$cel" ]] || die "could not discover OnCall celery Deployment in ${ns} by labels"
  kubectl get "deployment/${eng}" -n "${ns}" &>/dev/null \
    || die "deployment ${ns}/${eng} missing after discovery"
  kubectl get "deployment/${cel}" -n "${ns}" &>/dev/null \
    || die "deployment ${ns}/${cel} missing after discovery"
  wait_oncall_deployment_ready "$ns" "$eng"
  wait_oncall_deployment_ready "$ns" "$cel"
  log "OnCall stack: ${ns} deployments ${eng}, ${cel}"

  sec=$(_discover_pg_secret "$ns" "$eng")
  [[ -n "$sec" ]] || die "No PostgreSQL credential Secret in ${ns} (set ONCALL_PG_SECRET or ensure engine env secretKeyRef / postgres|db|sql secret with password keys)"
  log "Detected PostgreSQL Secret: ${ns}/${sec}"

  svc=$(_discover_pg_svc "$ns")
  [[ -n "$svc" ]] || die "No PostgreSQL ClusterIP Service in ${ns}"
  log "Detected PostgreSQL Service: ${ns}/${svc}"

  probe_svc=$(kubectl get svc -n "$ns" -o json 2>/dev/null | jq -r '
    .items[]?
    | (.metadata.name // "" | tostring | ascii_downcase) as $sn
    | select(.spec.clusterIP != null and .spec.clusterIP != "None")
    | select($sn | test("engine"))
    | select($sn | test("redis") | not)
    | select($sn | test("postgres") | not)
    | .metadata.name' | head -1)
  [[ -n "$probe_svc" ]] && log "Detected OnCall engine Service (mesh probe): ${ns}/${probe_svc}"

  export ONCALL_DISCOVERED_NS="$ns"
  export ONCALL_ENGINE_DEPLOY="$eng"
  export ONCALL_CELERY_DEPLOY="$cel"
  export ONCALL_PG_SECRET_NAME="$sec"
  export ONCALL_PG_SVC_NAME="$svc"
}

_all_nodes_ready_json() {
  kubectl get nodes -o json 2>/dev/null | jq -e '
    def ready_ok:
      ([.status.conditions[]? | select(.type == "Ready")] as $c
      | ($c | length) > 0 and ($c[0].status == "True"));
    (.items | length) > 0 and (.items | all(ready_ok))
  ' &>/dev/null
}

_ready_condition_unknown_present() {
  kubectl get nodes -o json 2>/dev/null | jq -e '
    [.items[]?.status.conditions[]? | select(.type == "Ready" and .status == "Unknown")] | length > 0
  ' &>/dev/null
}

_cluster_degraded_but_usable() {
  kubectl get namespace "${KEYCLOAK_NS}" &>/dev/null || return 1
  kubectl get namespace "${MONITORING_NS}" &>/dev/null || return 1
  local ep
  ep=$(kubectl get endpoints "${KEYCLOAK_SVC}" -n "${KEYCLOAK_NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  [[ -n "${ep// /}" ]] || return 1
  kubectl get ns bleater &>/dev/null && return 0
  kubectl get ns oncall &>/dev/null && return 0
  kubectl get deploy -A -o json 2>/dev/null | jq -e '
    [.items[]?
      | (.metadata.name // "" | tostring | ascii_downcase) as $n
      | select(($n | test("oncall")) and ($n | test("engine")))]
    | length > 0' &>/dev/null
}

wait_cluster_nodes_ready() {
  # Hosted Apex runs often deny node-level RBAC (get/list nodes). Treat node-readiness/kubelet
  # checks as local-debug only and avoid touching node APIs here.
  if kubectl get --raw='/readyz' >/dev/null 2>&1 || kubectl get --raw='/healthz' >/dev/null 2>&1; then
    log "Kubernetes API is reachable; skipping node-level readiness checks"
    return 0
  fi
  # Fallback for environments where /readyz is blocked but regular resource calls work.
  kubectl get namespace "${KEYCLOAK_NS}" >/dev/null 2>&1 && {
    log "Kubernetes API reachable via namespace read; skipping node-level readiness checks"
    return 0
  }
  die "Kubernetes API not reachable; cannot continue setup"
}

# --- main ---
need_cmd kubectl
need_cmd jq
need_cmd curl

wait_cluster_nodes_ready

kubectl get namespace "${KEYCLOAK_NS}" >/dev/null 2>&1 || die "namespace ${KEYCLOAK_NS} missing"
kubectl get namespace "${MONITORING_NS}" >/dev/null 2>&1 || die "namespace ${MONITORING_NS} missing"

require_oncall_stack
export ONCALL_NS="${ONCALL_DISCOVERED_NS}"
log "Namespaces OK: ${KEYCLOAK_NS}, ${ONCALL_NS}, ${MONITORING_NS}"
log "Incident cascade Layer A: visible symptom is idle re-auth bounce and slow acknowledge return"

wait_keycloak_workload
wait_keycloak_pod_ready
wait_keycloak_application_listening
log "Waiting for endpoints ${KEYCLOAK_NS}/${KEYCLOAK_SVC}..."
wait_endpoints "${KEYCLOAK_SVC}" "${KEYCLOAK_NS}" 180
log "Keycloak endpoints OK"

log "Skipping optional public ingress/DNS smoke checks for Keycloak; continuing with port-forward/admin API checks only"

KC_PASS=$(kc_admin_password) || die "Could not resolve Keycloak admin password from workload env / Keycloak secrets"
KC_USER=$(kc_admin_username)
log "Keycloak admin user: ${KC_USER}"

trap 'kc_stop_portforward 2>/dev/null || true' EXIT INT TERM
kc_start_portforward
wait_keycloak_oidc_local "${KC_LOCAL_BASE}"
kc_apply_hostname_hint_if_needed

KC_TOKEN=$(kc_obtain_token "${KC_LOCAL_BASE}" "${KC_PASS}" "${KC_USER}") || die "Keycloak admin token failed via localhost port-forward"
log "Keycloak admin token acquired"

kc_ensure_realm_exists
kc_wait_realm_readable "${KC_LOCAL_BASE}" "${KC_TOKEN}" || die "Keycloak admin API not readable for realm ${KEYCLOAK_REALM}"

REALM_JSON=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}" -H "Authorization: Bearer ${KC_TOKEN}")
echo "$REALM_JSON" | jq -e . >/dev/null || die "GET realm failed"
log "Incident cascade Layer B: session/auth baseline degraded after idle"
# Aggressively broken realm timings: very short idle, near-immediate access token, max<idle,
# and remember-me/offline fields undercutting overnight requirements.
echo "$REALM_JSON" | jq '
  .ssoSessionIdleTimeout = 600
  | .accessTokenLifespan = 30
  | .ssoSessionMaxLifespan = 300
  | del(.ssoSessionIdleTimeoutRememberMe)
  | del(.ssoSessionMaxLifespanRememberMe)
  | del(.offlineSessionIdleTimeout)
  | del(.offlineSessionMaxLifespan)
' > /tmp/nebula-realm.json
code=$(_kc_admin_put_http_code "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}" /tmp/nebula-realm.json)
[[ "$code" == "204" ]] || die "Realm PUT failed HTTP ${code}"
log "Realm patched (broken): idle 10m, access token 30s, and max lifespan below idle"
verify_keycloak_session_broken_state

kc_ensure_oncall_client_exists
Q_CLI=$(jq -rn --arg c "${ONCALL_CLIENT_ID}" '$c|@uri')
CLIENTS_JSON=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${Q_CLI}" -H "Authorization: Bearer ${KC_TOKEN}")
CID=$(echo "$CLIENTS_JSON" | jq -r '.[0].id // empty')
[[ -n "$CID" && "$CID" != "null" ]] || die "Keycloak client ${ONCALL_CLIENT_ID} not found"

CLIENT_JSON=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${CID}" -H "Authorization: Bearer ${KC_TOKEN}")
echo "$CLIENT_JSON" | jq -e . >/dev/null || die "GET client failed"

# Layer C1: break client refresh/session attributes only.
log "Incident cascade Layer C1: refresh/session continuation broken"
echo "$CLIENT_JSON" | jq '
  .attributes = (.attributes // {})
  | .attributes["use.refresh.tokens"] = "false"
  | .attributes["oauth2.allow.refresh.token.reuse"] = "false"
  | .attributes["client.session.idle.timeout"] = "0"
  | .attributes["client.session.max.lifespan"] = "0"
  | .attributes["client.offline.session.idle.timeout"] = "900"
' > /tmp/nebula-oncall-client-c1a.json
code=$(_kc_admin_put_http_code "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${CID}" /tmp/nebula-oncall-client-c1a.json)
[[ "$code" == "204" ]] || die "Client PUT (C1a refresh/session) failed HTTP ${code}"

CLIENT_JSON=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${CID}" -H "Authorization: Bearer ${KC_TOKEN}")
echo "$CLIENT_JSON" | jq -e . >/dev/null || die "GET client failed (after C1a)"

echo "$CLIENT_JSON" | jq '
  .attributes = (.attributes // {})
  | .attributes["use.refresh.tokens"] = "false"
  | .attributes["oauth2.allow.refresh.token.reuse"] = "false"
  | .attributes["client.session.idle.timeout"] = "600"
  | .attributes["client.session.max.lifespan"] = "1200"
  | .attributes["client.offline.session.idle.timeout"] = "900"
' > /tmp/nebula-oncall-client-c1.json
code=$(_kc_admin_put_http_code "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${CID}" /tmp/nebula-oncall-client-c1.json)
[[ "$code" == "204" ]] || die "Client PUT (C1 refresh/session) failed HTTP ${code}"
verify_keycloak_client_refresh_broken_state

# Layer C2: break callback/redirect + authorize (standard code flow off is a fair disclosed OAuth trap).
CLIENT_JSON_C2=$(curl_kc "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${CID}" -H "Authorization: Bearer ${KC_TOKEN}")
echo "$CLIENT_JSON_C2" | jq \
  --arg ur "${WRONG_OAUTH_REDIRECT}" \
  --arg root "https://oncall.devops.local/invalid/root" \
  --arg base "/invalid/callback-placeholder" \
  --arg admin "https://oncall.devops.local/invalid/admin" \
  '.redirectUris = (
      (
        (.redirectUris // [])
        | map(select(type == "string"))
      ) + [
        "https://oncall.devops.local/oauth/callback/complete/grafana-oauth/",
        "https://oncall.devops.local/oauth/callback/complete/grafana-oauth/*",
        "https://oncall.devops.local/complete/grafana-oauth/",
        "https://oncall.devops.local/*",
        "http://oncall.devops.local/oauth/callback/complete/grafana-oauth/",
        $ur,
        "https://oncall.devops.local/invalid/callback",
        "https://oncall.devops.local/oauth/callback"
      ] | unique
    )
    | .rootUrl = $root
    | .baseUrl = $base
    | .adminUrl = $admin
    | .webOrigins = [
        "+",
        "http://oncall.devops.local",
        "https://oncall.devops.local"
      ]
    | .standardFlowEnabled = false
  ' > /tmp/nebula-oncall-client-c2.json
code=$(_kc_admin_put_http_code "$(kc_local_root)/admin/realms/${KEYCLOAK_REALM}/clients/${CID}" /tmp/nebula-oncall-client-c2.json)
[[ "$code" == "204" ]] || die "Client PUT (C2 callback) failed HTTP ${code}"
log "Incident cascade Layer C2: callback/authorize continuation broken"
verify_keycloak_callback_broken_state
verify_authorize_flow_broken || warn "authorize probes still reached login form on some paths; callback poisoning is authoritative for this layer"

kc_stop_portforward
trap - EXIT INT TERM

kubectl get crd authorizationpolicies.security.istio.io &>/dev/null || die "Istio AuthorizationPolicy CRD missing"

_nebula_ensure_istio_sidecar_on_oncall_workloads
log "Incident cascade Layer D1: mesh authorization denies anonymous callback/integration flows"

for _ap in "${ISTIO_MESH_DENY_POLICY}" "${ISTIO_MESH_DENY_POLICY_SECOND}" "${ISTIO_MESH_DENY_POLICY_THIRD}" "${ISTIO_MESH_DENY_POLICY_FOURTH}"; do
  kubectl delete authorizationpolicy "${_ap}" -n "${ONCALL_NS}" --ignore-not-found >/dev/null 2>&1 || true
done

# DENY with only `to:` matches all sources for those paths (Istio: omitted `from` = any source).
# `notRequestPrincipals: ["*"]` often fails to match plaintext in-cluster probes when JWT
# request auth is not in use, yielding 0/8 in verify_istio_broken_state.
kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${ISTIO_MESH_DENY_POLICY}
  namespace: ${ONCALL_NS}
spec:
  action: DENY
  rules:
  - to:
    - operation:
        paths:
        - /integrations/*
        - /integrations/v1/*
        - /public-api/*
        - /public-api/v1/*
        - /oncall/integrations/*
        - /oncall/integrations/v1/*
        - /oncall/public-api/*
        - /oncall/public-api/v1/*
        - /integrations*
        - /public-api*
        - /oncall/integrations*
        - /oncall/public-api*
YAML
sleep 5
log "Istio mesh policy ${ISTIO_MESH_DENY_POLICY} applied (DENY all sources on integration + public-api path prefixes)"

kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${ISTIO_MESH_DENY_POLICY_SECOND}
  namespace: ${ONCALL_NS}
spec:
  action: DENY
  selector:
    matchLabels:
      app.kubernetes.io/name: oncall-engine
  rules:
  - from:
    - source:
        notRequestPrincipals: ["*"]
    to:
    - operation:
        paths:
        - /integrations/v1/*
        - /public-api/v1/*
        - /oncall/integrations/v1/*
        - /oncall/public-api/v1/*
  - to:
    - operation:
        paths:
        - /integrations/*
        - /public-api/*
        - /oncall/integrations/*
        - /oncall/public-api/*
YAML
sleep 3
log "Istio mesh policy ${ISTIO_MESH_DENY_POLICY_SECOND} applied (additional DENY guard for oncall-engine integration/public-api routes)"

kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${ISTIO_MESH_DENY_POLICY_THIRD}
  namespace: ${ONCALL_NS}
spec:
  action: DENY
  rules:
  - from:
    - source:
        notRequestPrincipals: ["*"]
    to:
    - operation:
        paths:
        - /integrations/*
        - /public-api/*
        - /oncall/integrations/*
        - /oncall/public-api/*
YAML
sleep 2
log "Istio mesh policy ${ISTIO_MESH_DENY_POLICY_THIRD} applied (shadow DENY for integrations/public-api)"

kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${ISTIO_MESH_DENY_POLICY_FOURTH}
  namespace: ${ONCALL_NS}
spec:
  action: DENY
  selector:
    matchLabels:
      app.kubernetes.io/name: oncall-engine
  rules:
  - to:
    - operation:
        paths:
        - /integrations/v1/*
        - /public-api/v1/*
        - /oncall/integrations/v1/*
        - /oncall/public-api/v1/*
YAML
sleep 2
log "Istio mesh policy ${ISTIO_MESH_DENY_POLICY_FOURTH} applied (v1 integration/public-api DENY guard)"

if kubectl get crd authorizationpolicies.security.istio.io >/dev/null 2>&1; then
  kubectl delete authorizationpolicy "${ISTIO_PUBLIC_ALLOWLIST_TRAP}" \
    -n "${ONCALL_NS}" --ignore-not-found >/dev/null 2>&1 || true
  ISTIO_ENGINE_SELECTOR_YAML="$(
    kubectl get "deploy/${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" -o json \
      | jq -r '
        .spec.selector.matchLabels
        | to_entries
        | map("      \(.key): \"" + (.value|tostring) + "\"")
        | join("\n")
      '
  )"
  [[ -n "${ISTIO_ENGINE_SELECTOR_YAML}" ]] || die "Could not derive Istio engine selector from deployment/${ONCALL_ENGINE_DEPLOY}"

  kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${ISTIO_PUBLIC_ALLOWLIST_TRAP}
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
${ISTIO_ENGINE_SELECTOR_YAML}
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals:
        - "*"
    to:
    - operation:
        paths:
        - /integrations/v1/*
        - /public-api/v1/*
        - /oncall/integrations/v1/*
        - /oncall/public-api/v1/*
YAML

  log "Istio public callback allowlist trap applied: ${ISTIO_PUBLIC_ALLOWLIST_TRAP}"

  kubectl delete authorizationpolicy "${ISTIO_PUBLIC_ALLOWLIST_TRAP_SECOND}" \
    -n "${ONCALL_NS}" --ignore-not-found >/dev/null 2>&1 || true

  kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${ISTIO_PUBLIC_ALLOWLIST_TRAP_SECOND}
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
${ISTIO_ENGINE_SELECTOR_YAML}
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals:
        - "*"
    to:
    - operation:
        paths:
        - /public-api/v1/*
        - /oncall/public-api/v1/*
YAML

  log "Istio public API principal guard trap applied: ${ISTIO_PUBLIC_ALLOWLIST_TRAP_SECOND}"
fi

verify_istio_broken_state

log "Incident cascade Layer D2: runtime TTL and Grafana source-of-truth are intentionally misaligned"
log "OnCall runtime break: corrupt existing ConfigMap/Secret + literal env sources (no synthetic task resources)"

_ttl_deps=("${ONCALL_ENGINE_DEPLOY}" "${ONCALL_CELERY_DEPLOY}")
for dep in "${_ttl_deps[@]}"; do
  kubectl get "deployment/${dep}" -n "${ONCALL_NS}" >/dev/null || die "deployment ${ONCALL_NS}/${dep} not found"
  # Near-immediate expiry to make TTL a critical fail unless every source is repaired.
  low_ttl=60
  [[ "${dep}" != "${ONCALL_ENGINE_DEPLOY}" ]] && low_ttl=120
  _nebula_corrupt_ttl_in_existing_configmaps "${dep}" "${low_ttl}"
  _nebula_corrupt_ttl_in_configmapkeyref_sources "${dep}" "${low_ttl}"
  if [[ "${dep}" == "${ONCALL_ENGINE_DEPLOY}" ]]; then
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_ENGINE_CM}" "${low_ttl}"
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_ENGINE_AUX_CM}" "${low_ttl}"

    # Diagnostic/decoy ConfigMaps only. They exist as clues but must not be active envFrom sources.
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_ENGINE_SHADOW_CM}" "${low_ttl}"
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_ENGINE_EDGE_CM}" "${low_ttl}"

    # Keep engine hard but not dead-weight:
    # seed canonical + one stale active source, then strip diagnostic shadows.
    _nebula_pin_ttl_envfrom_configmaps "${dep}" "${TTL_POLICY_ENGINE_CM}" "${TTL_POLICY_ENGINE_AUX_CM}" \
      || die "engine TTL envFrom pin failed on ${dep}"

    kubectl get "deployment/${dep}" -n "${ONCALL_NS}" -o json | jq \
      --arg cm "${TTL_POLICY_ENGINE_CM}" '
      .spec.template.spec.containers |= map(
        .env = (
          ((.env // [])
          | map(select(
              (.name // "") != "ACKNOWLEDGE_TOKEN_TTL_SECONDS"
              and (.name // "") != "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS"
            )))
          + [
              {
                name: "ACKNOWLEDGE_TOKEN_TTL_SECONDS",
                valueFrom: {
                  configMapKeyRef: {
                    name: $cm,
                    key: "ACKNOWLEDGE_TOKEN_TTL_SECONDS"
                  }
                }
              },
              {
                name: "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS",
                valueFrom: {
                  configMapKeyRef: {
                    name: $cm,
                    key: "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS"
                  }
                }
              }
            ]
        )
      )
    ' | kubectl apply -f - >/dev/null 2>&1 \
      || die "engine TTL explicit ConfigMapKeyRef wiring failed on ${dep}"

    # Defensive cleanup for reruns: remove diagnostic engine TTL ConfigMaps from active envFrom.
    kubectl get "deployment/${dep}" -n "${ONCALL_NS}" -o json | jq \
      --arg shadow "${TTL_POLICY_ENGINE_SHADOW_CM}" \
      --arg edge "${TTL_POLICY_ENGINE_EDGE_CM}" '
      del(
        .metadata.managedFields,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.creationTimestamp,
        .metadata.generation,
        .status
      )
      | .spec.template.spec.containers |= map(
          .envFrom = ((.envFrom // []) | map(
            select(
              ((((.configMapRef // {}).name) // "") != $shadow)
              and ((((.configMapRef // {}).name) // "") != $edge)
            )
          ))
        )
    ' | kubectl apply -f - >/dev/null 2>&1 \
      || die "engine diagnostic TTL envFrom cleanup failed on ${dep}"
  else
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_CELERY_CM}" "${low_ttl}"
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_CELERY_AUX_CM}" "${low_ttl}"
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_CELERY_SHADOW_CM}" "${low_ttl}"
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_CELERY_EDGE_CM}" "300"
    _nebula_seed_ttl_policy_configmap "${TTL_POLICY_CELERY_LEGACY_CM}" "180"
    _nebula_pin_ttl_envfrom_configmaps "${dep}" "${TTL_POLICY_CELERY_CM}" "${TTL_POLICY_CELERY_AUX_CM}" \
      || die "celery TTL envFrom pin failed on ${dep}"
    if ! kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq \
      --arg cm1 "${TTL_POLICY_CELERY_CM}" '
      .spec.template.spec.containers |= map(
        . as $c |
        ($c.env // []) as $e |
        .env = ($e
          | map(select((.name // "") != "ACKNOWLEDGE_TOKEN_TTL_SECONDS" and (.name // "") != "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS"))
          + [{name:"ACKNOWLEDGE_TOKEN_TTL_SECONDS", valueFrom:{configMapKeyRef:{name:$cm1, key:"ACKNOWLEDGE_TOKEN_TTL_SECONDS"}}}]
          + [{name:"INCIDENT_PUBLIC_TOKEN_TTL_SECONDS", valueFrom:{configMapKeyRef:{name:$cm1, key:"INCIDENT_PUBLIC_TOKEN_TTL_SECONDS"}}}]
        )
      )' | kubectl apply -f - >/dev/null 2>&1; then
      die "oncall-celery TTL: could not apply ACK/PUB configMapKeyRef to deployment containers (namespace=${ONCALL_NS})"
    fi
    kubectl get "deployment/${dep}" -n "${ONCALL_NS}" -o json | jq \
      --arg shadow "${TTL_POLICY_CELERY_SHADOW_CM}" \
      --arg edge "${TTL_POLICY_CELERY_EDGE_CM}" \
      --arg legacy "${TTL_POLICY_CELERY_LEGACY_CM}" '
      del(
        .metadata.managedFields,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.creationTimestamp,
        .metadata.generation,
        .status
      )
      | .spec.template.spec.containers |= map(
          .envFrom = ((.envFrom // []) | map(
            select(
              ((((.configMapRef // {}).name) // "") != $shadow)
              and ((((.configMapRef // {}).name) // "") != $edge)
              and ((((.configMapRef // {}).name) // "") != $legacy)
            )
          ))
        )
    ' | kubectl apply -f - >/dev/null 2>&1 \
      || die "celery diagnostic TTL envFrom cleanup failed on ${dep}"
  fi
  _ttl_cm_count="$( { _nebula_deploy_envfrom_configmap_names "${dep}"; _nebula_deploy_ttl_configmapkeyref_names "${dep}"; } | awk 'NF' | sort -u | wc -l | tr -d ' ' )"
  if [[ "${_ttl_cm_count}" == "0" ]]; then
    warn "TTL fallback avoided for ${dep}: no ConfigMap TTL sources found; keeping failure discoverable via runtime sources"
  else
    log "TTL break seeded in existing ConfigMap sources for ${dep} (envFrom/configMapKeyRef)"
  fi

  _gsecs=()
  while IFS= read -r _gs || [[ -n "${_gs:-}" ]]; do
    [[ -z "${_gs}" || "${_gs}" == "null" ]] && continue
    _gsecs+=("${_gs}")
  done < <(_nebula_grafana_secret_names_from_deploy "${dep}")
  _gdone=0
  if [[ "${dep}" == "${ONCALL_ENGINE_DEPLOY}" ]]; then
    _nebula_seed_grafana_secret "${GRAFANA_AUTH_ENGINE_SECRET}" "${STALE_GRAFANA_TOKEN}"
    _nebula_seed_grafana_secret "${GRAFANA_ENVFROM_ENGINE_SECRET}" "${STALE_GRAFANA_TOKEN}"
    _nebula_seed_grafana_secret "${GRAFANA_ENGINE_EDGE_SECRET}" "${STALE_GRAFANA_TOKEN}"
    _nebula_seed_grafana_secret "${GRAFANA_ENGINE_RUNTIME_SHADOW_SECRET}" "${STALE_GRAFANA_TOKEN}"
    _nebula_pin_grafana_secretkeyref "${dep}" "${GRAFANA_AUTH_ENGINE_SECRET}"
    _nebula_append_grafana_envfrom_secret "${dep}" "${GRAFANA_ENVFROM_ENGINE_SECRET}" \
      || warn "Grafana engine envFrom sidecar append failed for ${dep}"
    if kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq \
      --arg sec "${GRAFANA_ENGINE_EDGE_SECRET}" '
      del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .status)
      | .spec.template.spec.containers |= map(
          .env = ((.env // [])
            | map(select((.name // "") != "GRAFANA_TOKEN"))
            + [{name:"GRAFANA_TOKEN", valueFrom:{secretKeyRef:{name:$sec, key:"GRAFANA_TOKEN"}}}]
          )
        )
    ' | kubectl apply -f - >/dev/null 2>&1; then
      log "Grafana direct stale secretKeyRef injected on ${dep}"
    else
      warn "Grafana direct stale secretKeyRef injection skipped on ${dep}; approved stale runtime secret still keeps Grafana broken"
    fi
  else
    _nebula_seed_grafana_secret "${GRAFANA_AUTH_CELERY_SECRET}" "${STALE_GRAFANA_TOKEN}"
    _nebula_seed_grafana_secret "${GRAFANA_ENVFROM_CELERY_SECRET}" "${STALE_GRAFANA_TOKEN}"
    _nebula_seed_grafana_secret "${GRAFANA_CELERY_EDGE_SECRET}" "${STALE_GRAFANA_TOKEN}"
    # Celery must expose GRAFANA_* at runtime so setup verification can prove
    # the broken Grafana state exists. Do not rely only on envFrom here.
    _nebula_pin_grafana_secretkeyref "${dep}" "${GRAFANA_AUTH_CELERY_SECRET}" \
      || die "Grafana celery direct secretKeyRef pin failed on ${dep}"

    # Keep only one stale envFrom clue. More stale sources made Grafana dead weight.
    _nebula_append_grafana_envfrom_secret "${dep}" "${GRAFANA_ENVFROM_CELERY_SECRET}" \
      || warn "Grafana celery envFrom sidecar append failed for ${dep}"
    # After approved wiring: one extra direct secretKeyRef to a stale Secret wins last-writer on TOKEN.
    if kubectl get "deploy/${dep}" -n "${ONCALL_NS}" -o json | jq \
      --arg sec "${GRAFANA_CELERY_EDGE_SECRET}" '
      del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .status)
      | .spec.template.spec.containers |= map(
          .env = ((.env // [])
            | map(select((.name // "") != "GRAFANA_TOKEN"))
            + [{name:"GRAFANA_TOKEN", valueFrom:{secretKeyRef:{name:$sec, key:"GRAFANA_TOKEN"}}}]
          )
        )
    ' | kubectl apply -f - >/dev/null 2>&1; then
      log "Grafana direct stale secretKeyRef injected on ${dep} (celery)"
    else
      warn "Grafana direct stale secretKeyRef injection skipped on ${dep}; approved stale runtime secret still keeps Grafana broken"
    fi
  fi

  if [[ "${dep}" == "${ONCALL_ENGINE_DEPLOY}" ]]; then
    kubectl get "deploy/${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" -o json | jq -e '
      [
        .spec.template.spec.containers[]?.env[]?
        | select(.name == "GRAFANA_API_KEY" or .name == "GRAFANA_TOKEN")
      ] | length >= 2
    ' >/dev/null \
      || die "oncall-engine deployment does not declare both GRAFANA_API_KEY and GRAFANA_TOKEN before rollout"
  else
    kubectl get "deploy/${ONCALL_CELERY_DEPLOY}" -n "${ONCALL_NS}" -o json | jq -e '
      [
        .spec.template.spec.containers[]?.env[]?
        | select(.name == "GRAFANA_API_KEY" or .name == "GRAFANA_TOKEN")
      ] | length >= 2
    ' >/dev/null \
      || die "oncall-celery deployment does not declare both GRAFANA_API_KEY and GRAFANA_TOKEN before rollout"
  fi
  for _gs in "${_gsecs[@]}"; do
    [[ -z "${_gs}" ]] && continue
    if _nebula_patch_grafana_secret_stringdata "${_gs}" "${STALE_GRAFANA_TOKEN}"; then
      log "Grafana credential Secret patched in-place: ${ONCALL_NS}/${_gs} (${dep})"
      _gdone=1
    fi
  done
  # Prefer Secret-backed wiring; do not rely on literal env as the primary break path.
  # Fallback to literals only when no Secret-backed source exists at all on the workload.
  _gref_count="$(_nebula_grafana_secret_names_from_deploy "${dep}" | awk 'NF' | sort -u | wc -l | tr -d ' ')"
  if [[ "${_gref_count}" == "0" ]]; then
    _nebula_patch_grafana_literal_env_on_deploy "${dep}" "${STALE_GRAFANA_TOKEN}"
  fi
  # Scrub any literal token on initContainers/containers so a reusable working token cannot be copied.
  _nebula_scrub_grafana_literal_tokens_in_deploy "${dep}" "${STALE_GRAFANA_TOKEN}"
  if [[ "${_gref_count}" == "0" ]]; then
    log "Grafana: no secret-backed refs found after pinning; literal fallback used on ${dep}"
  elif ((_gdone == 0)); then
    log "Grafana: secretKeyRef/envFrom pinned + stale token seeded on dedicated sources for ${dep}"
  else
    log "Grafana: secret-backed refs present and discovered Secrets patched on ${dep}"
  fi
  log "Patched deployment ${dep}: in-place TTL + Grafana corruption"
done

for dep in "${_ttl_deps[@]}"; do
  kubectl rollout restart "deployment/${dep}" -n "${ONCALL_NS}" || die "rollout restart ${dep} failed"
  kubectl rollout status "deployment/${dep}" -n "${ONCALL_NS}" --timeout=300s || die "rollout status ${dep} timed out"
done
log "OnCall engine/celery restarted; runtime should carry broken TTL + Grafana materialization"
verify_oncall_ttl_broken_runtime
verify_grafana_broken_runtime

if ! _nebula_wait_oncall_engine_istio_proxy; then
  warn "istio-proxy not observed within ${ISTIO_SIDECAR_WAIT_SEC}s — cluster may not use sidecar injection; setup continues (verify_istio_broken_state will assert policy CR or HTTP probes)"
fi

# Escalation SQL: OnCall DB is oncall@<discovered PG svc> using postgres-password from discovered PG secret (same as bleater-postgresql + oncall-postgresql-external in Nebula).
ESCALATION_DB_PORT="${ESCALATION_DB_PORT:-5432}"
ESCALATION_DB_NAME="${ESCALATION_DB_NAME:-oncall}"
ESCALATION_DB_USER="${ESCALATION_DB_USER:-oncall}"
ESCALATION_PG_SECRET_KEY="${ESCALATION_PG_SECRET_KEY:-postgres-password}"
PGHOST_FQDN="${ONCALL_PG_SVC_NAME}.${ONCALL_NS}.svc.cluster.local"
_escalation_pg_secret_b64=$(kubectl get secret "${ONCALL_PG_SECRET_NAME}" -n "${ONCALL_NS}" -o json 2>/dev/null \
  | jq -r --arg k "${ESCALATION_PG_SECRET_KEY}" '.data[$k] // empty' || true)
[[ -n "${_escalation_pg_secret_b64}" ]] || die "Escalation: secret ${ONCALL_NS}/${ONCALL_PG_SECRET_NAME} missing .data.${ESCALATION_PG_SECRET_KEY} (need DB password for user ${ESCALATION_DB_USER})"

kubectl create configmap escalation-db-access -n "${ONCALL_NS}" \
  --from-literal=postgres_secret="${ONCALL_PG_SECRET_NAME}" \
  --from-literal=postgres_service="${ONCALL_PG_SVC_NAME}" \
  --from-literal=database="${ESCALATION_DB_NAME}" \
  --from-literal=user="${ESCALATION_DB_USER}" \
  --from-literal=table="alerts_escalationpolicy" \
  --from-literal=wait_column="wait_delay" \
  --from-literal=repeat_column="repeat_escalations_rate" \
  --dry-run=client -o yaml | kubectl apply -f -
log "Created ConfigMap escalation-db-access in ${ONCALL_NS} with DB access metadata"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: escalation-repair-template
  namespace: ${ONCALL_NS}
data:
  job.yaml: |
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: escalation-policy-repair
      namespace: ${ONCALL_NS}
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: psql
            image: ${PSQL_JOB_IMAGE}
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: REPLACE_WITH_POSTGRES_SECRET
                  key: postgres-password
                  optional: true
            command:
            - sh
            - -ec
            - |
              echo "Inspecting escalation policy timing..."
              psql -h REPLACE_WITH_POSTGRES_SERVICE -U oncall -d oncall -v ON_ERROR_STOP=1 <<'SQL'
              SELECT id, wait_delay, repeat_escalations_rate
              FROM alerts_escalationpolicy
              ORDER BY id;

              -- Repair target:
              -- Compare returned timing values against the 20-minute responder recovery floor.
              -- Normalize unsafe effective policy timing rows in PostgreSQL; do not patch Deployment env.
              -- The weakest effective timing row must satisfy the 20 minute floor.
              SQL
EOF
log "Created ConfigMap escalation-repair-template in ${ONCALL_NS} with starter Job manifest"

kubectl delete job "${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 \
  || kubectl delete job "${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" --ignore-not-found >/dev/null 2>&1 || true
for _w in $(seq 1 90); do
  kubectl get "job/${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" &>/dev/null || break
  sleep 1
done

log "Escalation Job: ns=${ONCALL_NS} host=${PGHOST_FQDN} port=${ESCALATION_DB_PORT} db=${ESCALATION_DB_NAME} user=${ESCALATION_DB_USER} secret=${ONCALL_PG_SECRET_NAME} key=${ESCALATION_PG_SECRET_KEY}"

kubectl apply -f - <<JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${ESCALATION_JOB_NAME}
  namespace: ${ONCALL_NS}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: ${PSQL_JOB_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: PGHOST
          value: "${PGHOST_FQDN}"
        - name: PGPORT
          value: "${ESCALATION_DB_PORT}"
        - name: PGDATABASE
          value: "${ESCALATION_DB_NAME}"
        - name: PGUSER
          value: "${ESCALATION_DB_USER}"
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: ${ONCALL_PG_SECRET_NAME}
              key: ${ESCALATION_PG_SECRET_KEY}
        - name: ESCALATION_META_NS
          value: "${ONCALL_NS}"
        command:
        - /bin/sh
        - -c
        - |
          set -e
          if ! psql -v ON_ERROR_STOP=1 -c "SELECT current_user, current_database();"; then
            echo "[escalation] validation query failed (password not shown)" >&2
            echo "[escalation] ns=\${ESCALATION_META_NS} host=\${PGHOST} port=\${PGPORT} db=\${PGDATABASE} user=\${PGUSER}" >&2
            exit 1
          fi
          psql -v ON_ERROR_STOP=1 -c "WITH m AS (SELECT MIN(wait_delay) AS min_wait FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL) UPDATE alerts_escalationpolicy p SET wait_delay = INTERVAL '8 minutes' FROM m WHERE p.wait_delay IS NOT NULL AND p.wait_delay = m.min_wait;"
          psql -v ON_ERROR_STOP=1 -c "WITH ranked AS (SELECT ctid, row_number() OVER (ORDER BY wait_delay NULLS LAST, ctid) AS rn FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL) UPDATE alerts_escalationpolicy p SET wait_delay = CASE WHEN ranked.rn = 1 THEN INTERVAL '4 minutes' WHEN ranked.rn = 2 THEN INTERVAL '5 minutes' WHEN ranked.rn = 3 THEN INTERVAL '6 minutes' WHEN ranked.rn = 4 THEN INTERVAL '9 minutes' WHEN ranked.rn = 5 THEN INTERVAL '3 minutes' ELSE p.wait_delay END FROM ranked WHERE p.ctid = ranked.ctid AND ranked.rn IN (1,2,3,4,5);"
          psql -v ON_ERROR_STOP=1 -c "DO \\\$plpgsql\\\$ DECLARE _has boolean; _minr int; BEGIN SELECT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema='public' AND c.table_name='alerts_escalationpolicy' AND c.column_name='repeat_escalations_rate') INTO _has; IF _has THEN SELECT MIN(CAST(substring(repeat_escalations_rate::text from '([0-9]+)') AS int)) INTO _minr FROM alerts_escalationpolicy WHERE repeat_escalations_rate IS NOT NULL AND repeat_escalations_rate::text ~ '([0-9]+)'; IF _minr IS NULL THEN UPDATE alerts_escalationpolicy SET repeat_escalations_rate='8m' WHERE ctid IN (SELECT ctid FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL ORDER BY wait_delay NULLS LAST LIMIT 1); ELSE UPDATE alerts_escalationpolicy SET repeat_escalations_rate='8m' WHERE repeat_escalations_rate IS NOT NULL AND CAST(substring(repeat_escalations_rate::text from '([0-9]+)') AS int)=_minr; END IF; UPDATE alerts_escalationpolicy SET repeat_escalations_rate='4m' WHERE ctid IN (SELECT ctid FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL ORDER BY wait_delay NULLS LAST, ctid OFFSET 0 LIMIT 1); UPDATE alerts_escalationpolicy SET repeat_escalations_rate='5m' WHERE ctid IN (SELECT ctid FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL ORDER BY wait_delay NULLS LAST, ctid OFFSET 1 LIMIT 1); UPDATE alerts_escalationpolicy SET repeat_escalations_rate='6m' WHERE ctid IN (SELECT ctid FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL ORDER BY wait_delay NULLS LAST, ctid OFFSET 2 LIMIT 1); UPDATE alerts_escalationpolicy SET repeat_escalations_rate='8m' WHERE ctid IN (SELECT ctid FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL ORDER BY wait_delay NULLS LAST, ctid OFFSET 3 LIMIT 1); UPDATE alerts_escalationpolicy SET repeat_escalations_rate='3m' WHERE ctid IN (SELECT ctid FROM alerts_escalationpolicy WHERE wait_delay IS NOT NULL ORDER BY wait_delay NULLS LAST, ctid OFFSET 4 LIMIT 1); END IF; END \\\$plpgsql\\\$;"
JOB

for _w in $(seq 1 60); do
  kubectl get "job/${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" &>/dev/null && break
  sleep 1
done
kubectl get "job/${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" &>/dev/null \
  || die "Escalation Job ${ESCALATION_JOB_NAME} not found in ${ONCALL_NS} after apply"

_esc_rc=0
_escalation_job_wait_done "${ONCALL_NS}" "${ESCALATION_JOB_NAME}" 180 || _esc_rc=$?
if ((_esc_rc == 0)); then
  :
elif ((_esc_rc == 2)); then
  kubectl logs "job/${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" --tail=200 2>&1 || true
  die "Escalation SQL Job failed: namespace=${ONCALL_NS} host=${PGHOST_FQDN} port=${ESCALATION_DB_PORT} database=${ESCALATION_DB_NAME} user=${ESCALATION_DB_USER} secret=${ONCALL_PG_SECRET_NAME} key=${ESCALATION_PG_SECRET_KEY} (see job logs above; password not logged)"
else
  kubectl logs "job/${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" --tail=200 2>&1 || true
  kubectl describe "job/${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" 2>&1 | tail -n 80 || true
  die "Escalation SQL Job failed (timeout): namespace=${ONCALL_NS} host=${PGHOST_FQDN} port=${ESCALATION_DB_PORT} database=${ESCALATION_DB_NAME} user=${ESCALATION_DB_USER} secret=${ONCALL_PG_SECRET_NAME} key=${ESCALATION_PG_SECRET_KEY} (see job logs above; password not logged)"
fi
log "Incident cascade Layer E: escalation remains too aggressive after auth/runtime fixes"
log "Escalation interval patched via Job (deterministic sub-20m wait_delay + repeat rows — simulates uneven escalation timing without RNG)"
verify_escalation_broken_state

kubectl delete job "${ESCALATION_JOB_NAME}" -n "${ONCALL_NS}" --ignore-not-found >/dev/null

kubectl create configmap escalation-db-access -n "${ONCALL_NS}" \
  --from-literal=postgres_secret="${ONCALL_PG_SECRET_NAME}" \
  --from-literal=postgres_service="${ONCALL_PG_SVC_NAME}" \
  --from-literal=database="${ESCALATION_DB_NAME}" \
  --from-literal=user="${ESCALATION_DB_USER}" \
  --from-literal=password_key="${ESCALATION_PG_SECRET_KEY}" \
  --from-literal=table="alerts_escalationpolicy" \
  --from-literal=wait_column="wait_delay" \
  --from-literal=repeat_column="repeat_escalations_rate" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Created ConfigMap escalation-db-access in ${ONCALL_NS} with DB access metadata"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: escalation-repair-template
  namespace: ${ONCALL_NS}
data:
  job.yaml: |
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: escalation-policy-repair
      namespace: ${ONCALL_NS}
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: psql
            image: ${PSQL_JOB_IMAGE}
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${ONCALL_PG_SECRET_NAME}
                  key: ${ESCALATION_PG_SECRET_KEY}
            command:
            - sh
            - -ec
            - |
              echo "Inspecting escalation policy timing..."
              psql -h ${ONCALL_PG_SVC_NAME} -U ${ESCALATION_DB_USER} -d ${ESCALATION_DB_NAME} -v ON_ERROR_STOP=1 <<'SQL'
              SELECT id, wait_delay, repeat_escalations_rate
              FROM alerts_escalationpolicy
              WHERE wait_delay IS NULL
                 OR wait_delay < INTERVAL '20 minutes'
                 OR repeat_escalations_rate IS NULL
                 OR repeat_escalations_rate < INTERVAL '20 minutes'
              ORDER BY id;

              -- Repair target:
              -- Rows returned here are below the responder recovery floor.
              -- Normalize policy timing in PostgreSQL; do not patch Deployment env.
              -- Every effective policy row must satisfy the 20 minute floor.
              SQL
EOF

log "Created ConfigMap escalation-repair-template in ${ONCALL_NS} with diagnostic starter Job"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: incident-handoff-notes
  namespace: ${ONCALL_NS}
data:
  summary: |
    Overnight responders say the acknowledge flow becomes unreliable after long idle periods.
    Some pages bounce through auth and return too late; others land on a 403 after login.
    Escalations are advancing before the first responder can finish the round trip.
    Escalation timing is persisted in the database, not only deployment env/config.
    Treat these notes as symptom guidance only; we did not isolate a single root cause.
EOF
log "Created ConfigMap incident-handoff-notes in ${ONCALL_NS} with symptom-led handoff notes"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: escalation-storage-notes
  namespace: ${ONCALL_NS}
data:
  notes: |
    Escalation timing is not only in Kubernetes.
    OnCall stores policy timing in PostgreSQL rows.
    Inspect table alerts_escalationpolicy.
    The relevant timing fields are wait_delay and, when present, repeat_escalations_rate.
    Values may be stored as PostgreSQL intervals.
    The weakest timing row must be at least 20 minutes.
    A short Kubernetes Job using the existing OnCall PostgreSQL Secret and Service is an acceptable repair method.
EOF
log "Created ConfigMap escalation-storage-notes in ${ONCALL_NS} with escalation storage hints"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: overnight-runbook
  namespace: ${ONCALL_NS}
data:
  runbook: |
    Overnight acknowledge reliability contract:

    Keycloak / OAuth:
    - The idle responder flow depends on the effective Keycloak realm and OnCall client session behavior, not only one timeout field.
    - The realm must support at least a 4-hour idle window and an 8-hour maximum SSO window, and the maximum must not undercut the idle window.
    Access tokens must remain usable across the full acknowledge handoff window. Lifetimes of 10 minutes or less are unsafe and will be rejected.
    - Inspect the realm JSON fields that can shorten the incident session window, including SSO idle/max, access-token lifetime, Remember-Me idle/max, and offline-session idle/max behavior. Any active realm or OnCall client setting used by this flow must preserve the 4-hour idle and 8-hour maximum responder window.
    - Inspect the OnCall client attributes separately. Refresh-token issuance, disabled refresh-token behavior, refresh-token reuse, and client/offline session overrides can still break the incident flow even when realm defaults look healthy.
    - Validate redirectUris together with rootUrl, baseUrl, adminUrl, and webOrigins. Unsafe placeholder URLs, wildcard origins, or HTTP origins can still cause redirect loops even when one redirect URI looks correct.
    - The deployed OnCall OAuth callback must be accepted through safe HTTPS client metadata consistent with the deployed callback and OnCall origin.
    - Confirm stale-session authorize behavior reaches the expected identity-provider re-auth step rather than failing before login.

    Istio:
    - Public integration and public API paths used by incident callbacks must reach the OnCall engine workload without being blocked by the mesh first.
    - Inspect every AuthorizationPolicy that selects the OnCall engine workload, not just the newest or most obvious policy.
    - Both DENY policies and restrictive ALLOW/allowlist policies can break this flow.
    - A healthy public callback path may return application-level 404, but it must not return 401/403, redirect before the app, or require a JWT principal before reaching the app.
    - Do not remove unrelated security controls. Narrow only the policy behavior that blocks anonymous incident callback paths.
    - Verify the public callback paths through the deployed service path after changes.

    TTL:
    - The acknowledge/public link lifetime is a strict 7200-second runtime contract on both OnCall runtime workloads.
    - The engine policy source for this incident is ConfigMap oncall-runtime-policy.
    - The worker/celery policy source for this incident is ConfigMap oncall-worker-runtime-policy.
    - Each workload must derive its live acknowledge/public TTL configuration from its corresponding approved policy source after rollout.
    - One-off Deployment literals or ConfigMap-only edits do not satisfy durable runtime repair.
    - Validate the effective TTL from the running engine and worker/celery workloads, not from stored Kubernetes objects alone.

    Grafana:
    - Grafana repair has two parts: normalize the effective runtime credential source, then verify that the active runtime credential authenticates to Grafana.
    - Engine must use the incident-approved runtime-auth Secret: oncall-runtime-auth.
    - Worker must use the incident-approved runtime-auth Secret: oncall-worker-runtime-auth.
    - Engine and worker must use these incident-approved runtime-auth Secrets in the OnCall namespace, not an older credential source that still appears in their env/envFrom chain.
    - Secret-backed wiring may use direct secretKeyRef entries or envFrom.secretRef from the approved runtime Secret; inline token values are not a durable repair.
    - Validate running pod Grafana environment after rollout. Secret data or Deployment YAML alone is not enough.
    - A successful Grafana API call is only accepted when it uses the active approved runtime credential through the same path OnCall uses.

    Escalation:
    - Escalation policy timing is stored in PostgreSQL, not Deployment env.
    - Inspect alerts_escalationpolicy in the OnCall PostgreSQL database.
    - wait_delay and repeat_escalations_rate must satisfy the 20-minute responder recovery floor across the effective policy set; the weakest effective policy row determines whether overnight recovery is safe.
    - Use ConfigMap escalation-db-access to find the PostgreSQL Secret, Service, database, table, and timing column names.
    - ConfigMap escalation-repair-template contains a diagnostic starter Job that shows how to connect to PostgreSQL and inspect policy timing rows.
    - The starter Job does not repair automatically; use the diagnostic output to determine and apply a durable database repair for unsafe policy timing rows.
EOF
log "Created ConfigMap overnight-runbook in ${ONCALL_NS} with exact operational expectations"
kubectl get configmap incident-handoff-notes -n "${ONCALL_NS}" >/dev/null \
  || die "Missing ConfigMap ${ONCALL_NS}/incident-handoff-notes after setup"
kubectl get configmap escalation-storage-notes -n "${ONCALL_NS}" >/dev/null \
  || die "Missing ConfigMap ${ONCALL_NS}/escalation-storage-notes after setup"
kubectl get configmap overnight-runbook -n "${ONCALL_NS}" >/dev/null \
  || die "Missing ConfigMap ${ONCALL_NS}/overnight-runbook after setup"
kubectl get configmap escalation-db-access -n "${ONCALL_NS}" >/dev/null \
  || die "Missing ConfigMap ${ONCALL_NS}/escalation-db-access after setup"
kubectl get configmap escalation-repair-template -n "${ONCALL_NS}" >/dev/null \
  || die "Missing ConfigMap ${ONCALL_NS}/escalation-repair-template after setup"
cleanup_kubernetes_events() {
  local ns
  for ns in default "${ONCALL_NS}" "${KEYCLOAK_NS}" "${MONITORING_NS}" istio-system; do
    [[ -n "${ns}" ]] || continue
    kubectl get ns "${ns}" >/dev/null 2>&1 || continue
    kubectl delete events --all -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete events.events.k8s.io --all -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
  done
}
cleanup_kubernetes_events
log "Deleted Kubernetes events in task namespaces to avoid chaos-sequence leakage"
log "Setup complete: layered broken baseline seeded and clue ConfigMaps verified"
exit 0
