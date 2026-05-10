#!/bin/bash
set -e

# ---------------------- [DONOT CHANGE ANYTHING BELOW] ---------------------------------- #
# Start supervisord if not already running (manages k3s, dockerd, dnsmasq)
echo "Ensuring supervisord is running..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 5

# Set kubeconfig for k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Wait for k3s to be ready (k3s can take 30-60 seconds to start)
echo "Waiting for k3s to be ready..."
MAX_WAIT=180
ELAPSED=0
until kubectl get nodes &>/dev/null; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    echo "Waiting for k3s... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "k3s is ready!"
# ---------------------- [DONOT CHANGE ANYTHING ABOVE] ---------------------------------- #

# ============================================================================
# Section 2: Variable defaults
# ============================================================================
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-devops}"
ONCALL_NS="${ONCALL_NS:-bleater}"
ONCALL_ENGINE_DEPLOY="${ONCALL_ENGINE_DEPLOY:-oncall-engine}"
ONCALL_CELERY_DEPLOY="${ONCALL_CELERY_DEPLOY:-oncall-celery}"
GRAFANA_NS="${GRAFANA_NS:-monitoring}"
ONCALL_PUBLIC_HOST="${ONCALL_PUBLIC_HOST:-oncall.devops.local}"

# Postgres defaults (used by the four sibling ConfigMaps below). The Bitnami
# postgres chart used by the snapshot publishes both the secret and service
# under the same release name `bleater-postgresql`.
ONCALL_PG_SECRET_NAME="${ONCALL_PG_SECRET_NAME:-bleater-postgresql}"
ONCALL_PG_SVC_NAME="${ONCALL_PG_SVC_NAME:-bleater-postgresql}"
ESCALATION_DB_PORT="${ESCALATION_DB_PORT:-5432}"
ESCALATION_DB_NAME="${ESCALATION_DB_NAME:-oncall}"
ESCALATION_DB_USER="${ESCALATION_DB_USER:-oncall}"
ESCALATION_PG_SECRET_KEY="${ESCALATION_PG_SECRET_KEY:-postgres-password}"
PSQL_JOB_IMAGE="${PSQL_JOB_IMAGE:-postgres:16-alpine}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ============================================================================
# Section 3: Service-readiness waits (verify snapshot baseline is healthy)
# ============================================================================
log "Waiting for snapshot services..."
kubectl wait --for=condition=available --timeout=180s deploy/keycloak -n "${KEYCLOAK_NS}" \
  || die "Keycloak deploy not available"
kubectl wait --for=condition=available --timeout=180s deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" \
  || die "oncall-engine deploy not available"
kubectl wait --for=condition=available --timeout=180s deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" \
  || die "oncall-celery deploy not available"
kubectl wait --for=condition=available --timeout=180s deploy/grafana -n "${GRAFANA_NS}" \
  || die "Grafana deploy not available"

# Postgres is a StatefulSet in some snapshots, Deployment in others. Try both.
if kubectl get statefulset bleater-postgresql -n "${ONCALL_NS}" >/dev/null 2>&1; then
    kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=180s sts/bleater-postgresql -n "${ONCALL_NS}" \
      || die "bleater-postgresql StatefulSet not ready"
elif kubectl get deploy bleater-postgresql -n "${ONCALL_NS}" >/dev/null 2>&1; then
    kubectl wait --for=condition=available --timeout=180s deploy/bleater-postgresql -n "${ONCALL_NS}" \
      || die "bleater-postgresql Deployment not available"
else
    log "WARN: bleater-postgresql not found — escalation phase may fail"
fi

# Istio CRDs available?
kubectl api-resources --api-group=security.istio.io --no-headers >/dev/null 2>&1 \
  || die "Istio security.istio.io CRDs not available; ENABLE_ISTIO_BLEATER setup may have failed"

log "Snapshot services ready."

# ============================================================================
# Section 4: Correction C3 — kube-system RBAC grant for ubuntu
# (fanout-ring-restoration precedent; verified by Phase 0.3 RBAC probe)
# ============================================================================
log "Granting ubuntu limited kube-system access (correction C3 — fanout-ring-restoration precedent)..."
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ubuntu-ns-manager
  namespace: kube-system
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch", "update", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    verbs: ["patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-ns-manager-binding
  namespace: kube-system
subjects:
  - kind: ServiceAccount
    name: ubuntu-user
    namespace: default
roleRef:
  kind: Role
  name: ubuntu-ns-manager
  apiGroup: rbac.authorization.k8s.io
YAML

# Disclose the access in /home/ubuntu/.allowed_namespaces (idempotent — only append if not already there)
if [ -f /home/ubuntu/.allowed_namespaces ] && \
   ! grep -q "kube-system has been granted" /home/ubuntu/.allowed_namespaces; then
    cat >> /home/ubuntu/.allowed_namespaces <<'APPEND'

# Additionally, limited write access to kube-system has been granted for diagnosing
# in-cluster automation that may be reapplying drift.
APPEND
fi

log "C3 RBAC grant + disclosure done."

# ============================================================================
# Section 5: Runbook ConfigMaps
# ============================================================================

# ----------------------------------------------------------------------------
# 5a — bleater/overnight-runbook (NEW symptom-level content per design §7)
# ----------------------------------------------------------------------------
log "Creating overnight-runbook ConfigMap (symptom-level only, no specific resource names)..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: overnight-runbook
  namespace: ${ONCALL_NS}
data:
  runbook: |
    Overnight acknowledge reliability — behavioral contracts:

    Keycloak / OAuth:
    - The idle responder flow depends on the effective Keycloak realm and
      OnCall client behavior. Symptoms are runtime, not config-shape.
    - Responders need at least 30 minutes of access-token validity after each
      login. Tokens with shorter lifespans are unsafe and will be rejected.
    - The OnCall integration system mints tokens via the password grant for
      its internal callbacks; this flow must remain enabled on the OnCall
      client.
    - The 'oncall' audience must be present on issued tokens; downstream
      services reject tokens missing it.
    - Register the deployed callback path safely; do not paper over with
      broad wildcards. Keycloak treats 'https://host/*' as a valid syntax,
      but our security policy explicitly rejects ambiguous redirect targets.
      Confirm both legitimate exact callback URIs are accepted AND wildcard
      redirect URIs are rejected.
    - Refresh-token rotation is required: each refresh must issue a NEW
      refresh-token, and the previous one must be invalidated. Refresh-token
      reuse — using the same refresh-token twice — must NOT be allowed; this
      is the secure default and must remain enabled.
    - Inspect realm settings AND OnCall client attributes; either layer can
      independently break the flow. CORS/web-origins must be a clean list of
      real origins, not placeholder syntax.

    Istio:
    - Public integration and public-API paths used by incident callbacks must
      reach the OnCall engine workload anonymously, without JWT.
    - Admin and internal-API paths (/api/internal/*) must remain protected;
      they must NOT be reachable anonymously.
    - The mesh must continue to enforce mutual TLS for application traffic;
      pods without sidecars must not reach the OnCall engine on the
      application port. Two diagnostic prober pods are deployed in 'bleater'
      (label nebula.io/role: mtls-prober); use them to test from inside
      and outside the mesh.
    - Inspect every AuthorizationPolicy AND RequestAuthentication that
      selects OnCall workloads — DENY policies, restrictive ALLOW/JWT
      policies, and bogus JWKS-issuing RequestAuthentications can all break
      the flow.
    - Do not remove unrelated security controls. Narrow only the policy
      behavior that blocks anonymous incident callback paths.
    - An empty AuthorizationPolicy spec is rejected by an admission policy;
      shape your fixes to scope rules to specific paths.

    OnCall TTL:
    - The acknowledge / public-link runtime TTL must be 7200 seconds.
    - Verify the value at runtime via 'kubectl exec' printenv on engine and
      celery pods AND via Django settings reflection inside the running
      engine container.
    - Any override layer — additional ConfigMaps in envFrom (which may
      last-wins-override an approved policy), inline 'env:' entries on a
      container (which always override envFrom), or settings-overrides
      Secrets mounted into the OnCall image — that defines a different value
      will undo the runtime contract.
    - Engine and celery TTLs must agree. They are wired through different
      mechanisms; fixing one does not fix the other.

    Grafana:
    - Both approved runtime-auth Secrets (engine-side and worker-side) must
      hold the SAME Grafana service-account token; the worker calls the
      engine API on every incident callback, and the worker's
      GRAFANA_API_KEY must authenticate against the same Grafana service
      account that the engine uses.
    - Mint one Grafana service-account token; write it to both Secrets.
    - Validate from running pods, not stored objects alone. The
      'valueFrom.secretKeyRef' mechanism is part of 'env', which has higher
      precedence than 'envFrom'; this matters when multiple credential
      sources overlap.
    - Service accounts whose name does not start with the approved prefix
      may be deleted by an existing token-rotation job; check the rotator's
      configuration before naming a new service account.

    Escalation:
    - Escalation policy timing is stored in PostgreSQL, not Deployment env.
    - Inspect the alerts_escalationpolicy table.
    - 'wait_delay' AND 'repeat_escalations_rate' must each satisfy a
      20-minute responder-recovery floor across every effective row,
      including rows currently NULL.
    - Use ConfigMap escalation-db-access for connection details and
      escalation-repair-template for an example diagnostic Job.
    - If your UPDATE is rejected with 'business floor exceeded', inspect
      table triggers — a non-policy enforcement may be intercepting your
      writes.
    - Some breakages may be re-applied periodically; verify your fix is
      stable across at least 30 seconds.
EOF
log "overnight-runbook created."

# ----------------------------------------------------------------------------
# 5b — Four sibling ConfigMaps preserved verbatim from v318 setup.sh
# (incident-handoff-notes, escalation-db-access, escalation-repair-template,
#  escalation-storage-notes)
# ----------------------------------------------------------------------------

# escalation-db-access — DB access metadata (verbatim from v318)
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

# escalation-repair-template — diagnostic starter Job (verbatim from v318)
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

# incident-handoff-notes — symptom-led handoff notes (verbatim from v318)
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

# escalation-storage-notes — escalation storage hints (verbatim from v318)
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

# ============================================================================
# Section 6: Keycloak realm + client breakages (design §5.1, §5.2, §5.3)
# Applies all breakages 1.1–1.5, 2.1–2.4, 3.1–3.4 idempotently. Uses
# kcadm.sh inside the Keycloak pod for auth + realm/user mutations, and
# direct admin REST API (curl + bearer) for fields kcadm.sh can't reach
# cleanly (e.g. nested attributes, client-policies CRUD).
# ============================================================================
log "Applying Keycloak realm + client breakages..."

# Wait for the Keycloak admin endpoint to be reachable inside the pod.
# (deploy/keycloak is already 'available' from Section 3, but the admin
# REST API can lag behind the readiness probe by a few seconds.)
KC_POD_WAIT=0
until kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
        /opt/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080 --realm master \
        --user admin --password admin123 >/dev/null 2>&1; do
  if [ $KC_POD_WAIT -ge 120 ]; then
    die "Keycloak admin endpoint did not become ready after 120s"
  fi
  sleep 3
  KC_POD_WAIT=$((KC_POD_WAIT + 3))
done
log "kcadm.sh admin auth OK (after ${KC_POD_WAIT}s)"

# Helper that runs a kcadm.sh command inside the Keycloak pod. The
# credentials cache lives in /opt/keycloak/.keycloak/kcadm.config so
# subsequent calls don't need to re-auth.
kcadm() {
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
    /opt/keycloak/bin/kcadm.sh "$@"
}

# Helper that grabs a fresh admin bearer token for direct REST calls.
# Uses curl from inside the keycloak pod (curl ships in the upstream
# keycloak image).
kc_admin_token() {
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- /bin/sh -c '
    curl -s -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
      -d "grant_type=password" -d "client_id=admin-cli" \
      -d "username=admin" -d "password=admin123" \
      | sed -n "s/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p"'
}

# Helper that PUTs a JSON body to the admin REST API. Args: PATH JSON
kc_admin_put() {
  local path="$1"; local body="$2"
  local tok
  tok=$(kc_admin_token)
  [ -n "$tok" ] || die "Failed to obtain Keycloak admin token"
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- /bin/sh -c "
    curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H 'Authorization: Bearer ${tok}' \
      -H 'Content-Type: application/json' \
      -d '${body}' \
      http://localhost:8080${path}"
}

# Helper that POSTs JSON to the admin REST API. Args: PATH JSON
kc_admin_post() {
  local path="$1"; local body="$2"
  local tok
  tok=$(kc_admin_token)
  [ -n "$tok" ] || die "Failed to obtain Keycloak admin token"
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- /bin/sh -c "
    curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Authorization: Bearer ${tok}' \
      -H 'Content-Type: application/json' \
      -d '${body}' \
      http://localhost:8080${path}"
}

# Helper that DELETEs a path on the admin REST API. Args: PATH
kc_admin_delete() {
  local path="$1"
  local tok
  tok=$(kc_admin_token)
  [ -n "$tok" ] || die "Failed to obtain Keycloak admin token"
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- /bin/sh -c "
    curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H 'Authorization: Bearer ${tok}' \
      http://localhost:8080${path}"
}

# Helper that GETs a path and returns the body. Args: PATH
kc_admin_get() {
  local path="$1"
  local tok
  tok=$(kc_admin_token)
  [ -n "$tok" ] || die "Failed to obtain Keycloak admin token"
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- /bin/sh -c "
    curl -s -H 'Authorization: Bearer ${tok}' \
      http://localhost:8080${path}"
}

# ----------------------------------------------------------------------------
# 6.1 — Realm-level breakages on realm 'devops'
# Breakages 1.2, 1.3, 1.5, 3.2, 3.4 + ssoSessionMaxLifespan tightening.
# Use kcadm.sh update which performs a partial PUT (idempotent).
# ----------------------------------------------------------------------------
log "Applying realm-level breakages on realm '${KEYCLOAK_REALM}'..."
kcadm update "realms/${KEYCLOAK_REALM}" \
  -s accessTokenLifespan=30 \
  -s ssoSessionIdleTimeout=60 \
  -s ssoSessionMaxLifespan=1800 \
  -s revokeRefreshToken=true \
  -s refreshTokenMaxReuse=0 \
  -s clientSessionIdleTimeout=30 \
  || die "Failed to update realm-level breakages"
log "Realm breakages applied: accessTokenLifespan=30, ssoSessionIdleTimeout=60, ssoSessionMaxLifespan=1800, revokeRefreshToken=true, refreshTokenMaxReuse=0, clientSessionIdleTimeout=30"

# ----------------------------------------------------------------------------
# 6.2 — Look up OnCall client UUID (idempotent — client must already exist
# from the snapshot baseline)
# ----------------------------------------------------------------------------
log "Looking up OnCall client UUID in realm '${KEYCLOAK_REALM}'..."
ONCALL_CID=""
ONCALL_LOOKUP_WAIT=0
until [ -n "$ONCALL_CID" ]; do
  ONCALL_CID=$(kcadm get "clients" -r "${KEYCLOAK_REALM}" -q clientId=oncall \
                 --fields id --format csv --noquotes 2>/dev/null \
                 | tr -d '\r' | grep -E '^[0-9a-f-]+$' | head -1)
  if [ -z "$ONCALL_CID" ]; then
    if [ $ONCALL_LOOKUP_WAIT -ge 60 ]; then
      die "OnCall client (clientId=oncall) not found in realm '${KEYCLOAK_REALM}' after 60s"
    fi
    sleep 3
    ONCALL_LOOKUP_WAIT=$((ONCALL_LOOKUP_WAIT + 3))
  fi
done
log "OnCall client UUID: ${ONCALL_CID}"

# ----------------------------------------------------------------------------
# 6.3 — OnCall client breakages: directAccessGrantsEnabled, standardFlowEnabled,
# redirectUris (7 wrong/wildcard entries — none is the exact deployed callback),
# webOrigins (mixed valid+invalid), and 5 client attributes.
# Uses direct admin REST PUT to /admin/realms/devops/clients/{id} so we can set
# nested 'attributes' fields in one shot.
# ----------------------------------------------------------------------------
log "Applying OnCall client breakages (directAccessGrantsEnabled=false, standardFlowEnabled=false, redirectUris, webOrigins, 5 attributes)..."

ONCALL_CLIENT_BODY=$(cat <<'JSON'
{
  "clientId": "oncall",
  "directAccessGrantsEnabled": false,
  "standardFlowEnabled": false,
  "redirectUris": [
    "https://oncall.devops.local/*",
    "http://oncall.devops.local",
    "https://oncall.devops.local/invalid/callback",
    "https://oncall.devops.local",
    "https://oncall/cb",
    "https://oncall.devops.local/something",
    "https://oncall.devops.local/oauth/callback/complete/grafana-oauth"
  ],
  "webOrigins": ["+", "*", "http://oncall.devops.local"],
  "attributes": {
    "use.refresh.tokens": "false",
    "oauth2.allow.refresh.token.reuse": "false",
    "client.refresh.token.rotation.policy": "NONE",
    "client.session.idle.timeout": "30",
    "access.token.lifespan": "30"
  }
}
JSON
)

# Compact the JSON onto a single line so it fits cleanly on the curl -d arg
# inside the keycloak pod's /bin/sh -c heredoc. (Keycloak accepts pretty or
# compact JSON; compact is safer for shell-quoting.)
ONCALL_CLIENT_BODY_COMPACT=$(printf '%s' "$ONCALL_CLIENT_BODY" | tr -d '\n' | tr -s ' ')

CLIENT_PUT_HTTP=$(kc_admin_put "/admin/realms/${KEYCLOAK_REALM}/clients/${ONCALL_CID}" "$ONCALL_CLIENT_BODY_COMPACT")
case "$CLIENT_PUT_HTTP" in
  20*|204) log "OnCall client breakages applied (HTTP ${CLIENT_PUT_HTTP})" ;;
  *) die "OnCall client PUT failed with HTTP ${CLIENT_PUT_HTTP}" ;;
esac

# ----------------------------------------------------------------------------
# 6.4 — Delete the OnCall audience mapper (breakage 1.4).
# List all protocol mappers on the OnCall client; find the one of type
# oidc-audience-mapper that adds 'oncall' to the audience; DELETE it. If
# none exists (already deleted on a previous run), this is a no-op.
# ----------------------------------------------------------------------------
log "Removing OnCall audience mapper (breakage 1.4)..."
MAPPERS_JSON=$(kc_admin_get "/admin/realms/${KEYCLOAK_REALM}/clients/${ONCALL_CID}/protocol-mappers/models" || true)

# Parse the mappers list with python3 (always present in the keycloak image
# baseline for our use? — fall back to sed if not). We use a portable shell
# pipeline with sed/awk to extract the audience-mapper id.
AUDIENCE_MAPPER_IDS=$(printf '%s' "$MAPPERS_JSON" \
  | tr ',' '\n' \
  | awk 'BEGIN{RS="\\{"; FS="\""}
         /oidc-audience-mapper/ {
           for(i=1;i<=NF;i++){ if($i=="id"){ print $(i+2); break } }
         }')

if [ -z "$AUDIENCE_MAPPER_IDS" ]; then
  # Fallback: try to find any mapper whose name matches the typical naming
  # ('audience mapper' or 'oncall-audience' or contains 'audience').
  AUDIENCE_MAPPER_IDS=$(printf '%s' "$MAPPERS_JSON" \
    | tr ',' '\n' \
    | awk 'BEGIN{RS="\\{"; FS="\""}
           /[Aa]udience/ && /protocolMapper/ {
             for(i=1;i<=NF;i++){ if($i=="id"){ print $(i+2); break } }
           }')
fi

if [ -n "$AUDIENCE_MAPPER_IDS" ]; then
  echo "$AUDIENCE_MAPPER_IDS" | while IFS= read -r MID; do
    [ -z "$MID" ] && continue
    DELETE_HTTP=$(kc_admin_delete "/admin/realms/${KEYCLOAK_REALM}/clients/${ONCALL_CID}/protocol-mappers/models/${MID}")
    case "$DELETE_HTTP" in
      20*|204|404) log "Deleted OnCall audience mapper ${MID} (HTTP ${DELETE_HTTP})" ;;
      *) log "WARN: failed to delete audience mapper ${MID} (HTTP ${DELETE_HTTP})" ;;
    esac
  done
else
  log "No OnCall audience mapper found (already deleted on a previous run — OK)"
fi

# ----------------------------------------------------------------------------
# 6.5 — Realm-level Client Policy with secure-redirect-uris-enforcer-executor
# that explicitly rejects redirect URIs containing '*' (breakage 2.4).
# Uses two PUTs:
#   PUT /admin/realms/devops/client-policies/profiles  (registers the profile)
#   PUT /admin/realms/devops/client-policies/policies  (binds the profile to
#     client_id=oncall via clientId-list condition)
# Both endpoints are PUT (replace), which is idempotent.
# ----------------------------------------------------------------------------
log "Registering realm-level Client Policy with secure-redirect-uris-enforcer-executor (breakage 2.4)..."

CLIENT_PROFILES_BODY='{"profiles":[{"name":"oncall-strict-redirect-profile","description":"Strict redirect URI enforcement for OnCall (rejects wildcard URIs)","executors":[{"executor":"secure-redirect-uris-enforcer","configuration":{"allowed-redirect-uris":["https://oncall.devops.local/oauth/callback/complete/grafana-oauth/"]}}]}]}'

PROFILES_HTTP=$(kc_admin_put "/admin/realms/${KEYCLOAK_REALM}/client-policies/profiles" "$CLIENT_PROFILES_BODY")
case "$PROFILES_HTTP" in
  20*|204) log "Client profile registered (HTTP ${PROFILES_HTTP})" ;;
  *) log "WARN: client-policies/profiles PUT returned HTTP ${PROFILES_HTTP} (continuing)" ;;
esac

CLIENT_POLICIES_BODY='{"policies":[{"name":"oncall-strict-redirect-policy","description":"Bind oncall-strict-redirect-profile to client_id=oncall","enabled":true,"conditions":[{"condition":"client-access-type","configuration":{"type":["confidential","public"]}},{"condition":"client-roles","configuration":{"roles":[]}},{"condition":"clientId-list","configuration":{"clients":["oncall"]}}],"profiles":["oncall-strict-redirect-profile"]}]}'

POLICIES_HTTP=$(kc_admin_put "/admin/realms/${KEYCLOAK_REALM}/client-policies/policies" "$CLIENT_POLICIES_BODY")
case "$POLICIES_HTTP" in
  20*|204) log "Client policy bound to clientId=oncall (HTTP ${POLICIES_HTTP})" ;;
  *) log "WARN: client-policies/policies PUT returned HTTP ${POLICIES_HTTP} (continuing)" ;;
esac

log "Keycloak realm + client breakages complete (1.1–1.5, 2.1–2.4, 3.1–3.4)."

# ============================================================================
# Section 7: Responder test user (design §5.1 probe dependency)
# Idempotent: if user already exists, just reset password.
# ============================================================================
log "Creating/updating responder test user in realm '${KEYCLOAK_REALM}'..."

# create returns non-zero when user exists; swallow that.
kcadm create users -r "${KEYCLOAK_REALM}" \
  -s username=responder \
  -s email=responder@devops.local \
  -s enabled=true \
  -s emailVerified=true >/dev/null 2>&1 || true

# Always reset the password (idempotence — agent-facing fix may also
# create users, so password must converge to responder123).
kcadm set-password -r "${KEYCLOAK_REALM}" \
  --username responder --new-password responder123 \
  || die "Failed to set responder password"

log "Responder user ready (responder/responder123)."

# ============================================================================
# Section 8: P2.a keycloak-realm-reconciler (design §4 P2.a)
# Re-imports the OnCall client + realm settings every 30s. The ConfigMap
# holds the broken JSON; agent must edit either the ConfigMap or
# delete/scale the Deployment. Image: bitnami/kubectl:1.30 (pre-cached
# at SHA 1a62432). Curl ships in bitnami/kubectl 1.30+, so we drop the
# inner 'kubectl run kc-token-helper' pattern from the design sketch
# and curl directly from the reconciler container.
# ============================================================================
log "Deploying keycloak-realm-reconciler in kube-system..."

kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-oncall-client-template
  namespace: kube-system
data:
  client.json: |
    {
      "clientId": "oncall",
      "directAccessGrantsEnabled": false,
      "standardFlowEnabled": false,
      "redirectUris": [
        "https://oncall.devops.local/*",
        "http://oncall.devops.local",
        "https://oncall.devops.local/invalid/callback",
        "https://oncall.devops.local",
        "https://oncall/cb",
        "https://oncall.devops.local/something",
        "https://oncall.devops.local/oauth/callback/complete/grafana-oauth"
      ],
      "webOrigins": ["+", "*", "http://oncall.devops.local"],
      "attributes": {
        "use.refresh.tokens": "false",
        "oauth2.allow.refresh.token.reuse": "false",
        "client.refresh.token.rotation.policy": "NONE",
        "client.session.idle.timeout": "30",
        "access.token.lifespan": "30"
      }
    }
  realm.json: |
    {
      "realm": "devops",
      "accessTokenLifespan": 30,
      "ssoSessionIdleTimeout": 60,
      "ssoSessionMaxLifespan": 1800,
      "revokeRefreshToken": true,
      "refreshTokenMaxReuse": 0,
      "clientSessionIdleTimeout": 30
    }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keycloak-realm-reconciler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: keycloak-realm-reconciler
  namespace: kube-system
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: keycloak-realm-reconciler
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: keycloak-realm-reconciler
subjects:
  - kind: ServiceAccount
    name: keycloak-realm-reconciler
    namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak-realm-reconciler
  namespace: kube-system
  labels:
    nebula.io/role: reconciler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-realm-reconciler
  template:
    metadata:
      labels:
        app: keycloak-realm-reconciler
    spec:
      serviceAccountName: keycloak-realm-reconciler
      containers:
        - name: reconciler
          image: bitnami/kubectl:1.30
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set +e
              while true; do
                # Get admin token directly (curl ships in bitnami/kubectl:1.30+)
                ADMIN_TOKEN=$(curl -s -X POST \
                  http://keycloak.keycloak:8080/realms/master/protocol/openid-connect/token \
                  -d 'grant_type=password' \
                  -d 'client_id=admin-cli' \
                  -d 'username=admin' \
                  -d 'password=admin123' \
                  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

                if [ -n "$ADMIN_TOKEN" ]; then
                  # Re-PUT realm-level breakages every cycle.
                  REALM_JSON=$(cat /etc/keycloak-template/realm.json)
                  curl -s -o /dev/null -X PUT \
                    -H "Authorization: Bearer $ADMIN_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "$REALM_JSON" \
                    http://keycloak.keycloak:8080/admin/realms/devops

                  # Look up OnCall client UUID and re-PUT client-level breakages.
                  CID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
                    "http://keycloak.keycloak:8080/admin/realms/devops/clients?clientId=oncall" \
                    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
                  if [ -n "$CID" ]; then
                    CLIENT_JSON=$(cat /etc/keycloak-template/client.json)
                    curl -s -o /dev/null -X PUT \
                      -H "Authorization: Bearer $ADMIN_TOKEN" \
                      -H "Content-Type: application/json" \
                      -d "$CLIENT_JSON" \
                      http://keycloak.keycloak:8080/admin/realms/devops/clients/$CID
                  fi
                fi
                sleep 30
              done
          volumeMounts:
            - name: template
              mountPath: /etc/keycloak-template
      volumes:
        - name: template
          configMap:
            name: keycloak-oncall-client-template
YAML

log "Waiting for keycloak-realm-reconciler to become available..."
kubectl wait --for=condition=available --timeout=180s \
  deploy/keycloak-realm-reconciler -n kube-system \
  || die "keycloak-realm-reconciler did not become available"

log "keycloak-realm-reconciler ready."

# ============================================================================
# Section 9: Final cleanup
# ============================================================================
log "Final cleanup — clearing events..."
kubectl delete events --all -A >/dev/null 2>&1 || true

log "setup.sh complete (Phase 3+4: Keycloak breakages 1.1–1.5, 2.1–2.4, 3.1–3.4 applied + responder user + reconciler running)."
