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
KEYCLOAK_REALM="${KEYCLOAK_REALM:-nebula}"
ONCALL_NS="${ONCALL_NS:-bleater}"
ONCALL_ENGINE_DEPLOY="${ONCALL_ENGINE_DEPLOY:-oncall-engine}"
ONCALL_CELERY_DEPLOY="${ONCALL_CELERY_DEPLOY:-oncall-celery}"
GRAFANA_NS="${GRAFANA_NS:-monitoring}"
ONCALL_PUBLIC_HOST="${ONCALL_PUBLIC_HOST:-oncall.devops.local}"

# Postgres defaults (used by the four sibling ConfigMaps below). The Bitnami
# postgres chart used by the snapshot publishes both the secret and service
# under the same release name `bleater-postgresql`.
ONCALL_PG_SECRET_NAME="${ONCALL_PG_SECRET_NAME:-oncall-postgresql-external}"
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
    - 'wait_delay' must satisfy a
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
              SELECT id, step, wait_delay
              FROM alerts_escalationpolicy
              WHERE wait_delay IS NULL
                 OR wait_delay < INTERVAL '20 minutes'
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
    The relevant timing field is wait_delay (step = 0 rows).
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

# Diagnostic: which realms exist? (useful when realm name assumptions break)
log "Available realms:"
kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get realms --fields realm 2>&1 | head -30 || \
  log "WARN: realm list failed"

# Helper that runs a kcadm.sh command inside the Keycloak pod. The
# credentials cache lives in /opt/keycloak/.keycloak/kcadm.config so
# subsequent calls don't need to re-auth.
kcadm() {
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
    /opt/keycloak/bin/kcadm.sh "$@"
}

# Helpers that talk to the Keycloak admin REST API. The keycloak image
# does not ship with curl, so we use kubectl run to spawn a one-shot
# bitnami/kubectl:latest pod (cached by the Dockerfile skopeo stage —
# has curl + bash). Each call adds ~5s of pod startup but only runs a
# handful of times during setup.
KC_INTERNAL_URL="http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080"

kc_admin_token() {
  kubectl run kc-tok-$RANDOM --rm --restart=Never --quiet -i \
    --image=docker.io/bitnami/kubectl:latest --image-pull-policy=IfNotPresent \
    --command -- /bin/sh -c "
      curl -s -X POST ${KC_INTERNAL_URL}/realms/master/protocol/openid-connect/token \
        -d 'grant_type=password' -d 'client_id=admin-cli' \
        -d 'username=admin' -d 'password=admin123' \
      | sed -n 's/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p'" 2>/dev/null \
    | tr -d '\r\n '
}

kc_admin_put() {
  local path="$1"; local body="$2"
  local tok; tok=$(kc_admin_token)
  [ -n "$tok" ] || { echo "000"; return 1; }
  kubectl run kc-put-$RANDOM --rm --restart=Never --quiet -i \
    --image=docker.io/bitnami/kubectl:latest --image-pull-policy=IfNotPresent \
    --command -- /bin/sh -c "
      printf '%s' '$body' > /tmp/body.json
      curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -H 'Authorization: Bearer ${tok}' \
        -H 'Content-Type: application/json' \
        --data @/tmp/body.json \
        ${KC_INTERNAL_URL}${path}" 2>/dev/null
}

kc_admin_post() {
  local path="$1"; local body="$2"
  local tok; tok=$(kc_admin_token)
  [ -n "$tok" ] || { echo "000"; return 1; }
  kubectl run kc-post-$RANDOM --rm --restart=Never --quiet -i \
    --image=docker.io/bitnami/kubectl:latest --image-pull-policy=IfNotPresent \
    --command -- /bin/sh -c "
      printf '%s' '$body' > /tmp/body.json
      curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer ${tok}' \
        -H 'Content-Type: application/json' \
        --data @/tmp/body.json \
        ${KC_INTERNAL_URL}${path}" 2>/dev/null
}

kc_admin_delete() {
  local path="$1"
  local tok; tok=$(kc_admin_token)
  [ -n "$tok" ] || { echo "000"; return 1; }
  kubectl run kc-del-$RANDOM --rm --restart=Never --quiet -i \
    --image=docker.io/bitnami/kubectl:latest --image-pull-policy=IfNotPresent \
    --command -- /bin/sh -c "
      curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        -H 'Authorization: Bearer ${tok}' \
        ${KC_INTERNAL_URL}${path}" 2>/dev/null
}

kc_admin_get() {
  local path="$1"
  local tok; tok=$(kc_admin_token)
  [ -n "$tok" ] || return 1
  kubectl run kc-get-$RANDOM --rm --restart=Never --quiet -i \
    --image=docker.io/bitnami/kubectl:latest --image-pull-policy=IfNotPresent \
    --command -- /bin/sh -c "
      curl -s -H 'Authorization: Bearer ${tok}' \
        ${KC_INTERNAL_URL}${path}" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 6.1 — Realm-level breakages on realm 'nebula'
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
  || log "WARN: Failed to update realm-level breakages (continuing)"
log "Realm breakages applied: accessTokenLifespan=30, ssoSessionIdleTimeout=60, ssoSessionMaxLifespan=1800, revokeRefreshToken=true, refreshTokenMaxReuse=0, clientSessionIdleTimeout=30"

# ----------------------------------------------------------------------------
# 6.1.5 — Ensure the 'oncall' OAuth client exists in the realm
# Phase 0 found the snapshot's nebula realm has no 'oncall' client by default.
# Create it idempotently (existing client → kcadm errors with 'already exists',
# which we ignore). The client breakages below will then flip its attributes
# to the broken state.
# ----------------------------------------------------------------------------
log "Ensuring 'oncall' OAuth client exists in realm '${KEYCLOAK_REALM}'..."
kcadm create clients -r "${KEYCLOAK_REALM}" \
  -s clientId=oncall \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=true \
  -s serviceAccountsEnabled=false \
  -s secret=oncall-test-secret-123 \
  -s 'redirectUris=["https://oncall.devops.local/oauth/callback/complete/grafana-oauth/"]' \
  -s 'webOrigins=["https://oncall.devops.local"]' \
  >/dev/null 2>&1 || log "WARN: oncall client create skipped (likely already exists, OK)"

# Ensure the client secret is what we expect (idempotent — kcadm regenerate-secret
# would change it; we just patch it back to the canonical value).
ONCALL_CID_PRECREATE=$(kcadm get clients -r "${KEYCLOAK_REALM}" -q clientId=oncall \
  --fields id --format csv --noquotes 2>/dev/null \
  | tr -d '\r' | grep -E '^[0-9a-f-]+$' | head -1)
if [ -n "$ONCALL_CID_PRECREATE" ]; then
  kcadm update "clients/${ONCALL_CID_PRECREATE}" -r "${KEYCLOAK_REALM}" \
    -s secret=oncall-test-secret-123 \
    -s enabled=true \
    >/dev/null 2>&1 || true

  # Add the audience mapper so JWTs include 'oncall' in aud. Idempotent —
  # check if a mapper with name 'oncall-audience' already exists; if not, create.
  EXISTING_AUD=$(kcadm get "clients/${ONCALL_CID_PRECREATE}/protocol-mappers/models" \
    -r "${KEYCLOAK_REALM}" --format csv --fields name --noquotes 2>/dev/null \
    | grep -c '^oncall-audience$' || true)
  if [ "${EXISTING_AUD:-0}" = "0" ]; then
    kcadm create "clients/${ONCALL_CID_PRECREATE}/protocol-mappers/models" \
      -r "${KEYCLOAK_REALM}" \
      -s name=oncall-audience \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-audience-mapper \
      -s 'config."included.client.audience"=oncall' \
      -s 'config."id.token.claim"=false' \
      -s 'config."access.token.claim"=true' \
      >/dev/null 2>&1 || log "WARN: failed to create audience mapper (continuing)"
    log "Created OnCall audience mapper"
  else
    log "OnCall audience mapper already exists"
  fi
  log "OnCall client ready (UUID=${ONCALL_CID_PRECREATE})"
else
  log "WARN: OnCall client still missing after create attempt"
fi

# ----------------------------------------------------------------------------
# 6.2 — Look up OnCall client UUID (idempotent — client must already exist
# from the snapshot baseline)
# ----------------------------------------------------------------------------
log "Diagnostic: list all clients in realm '${KEYCLOAK_REALM}':"
kcadm get clients -r "${KEYCLOAK_REALM}" --fields clientId,id 2>&1 | head -80 || \
  log "WARN: client list failed"

log "Looking up OnCall client UUID in realm '${KEYCLOAK_REALM}'..."
ONCALL_CID=""
ONCALL_LOOKUP_WAIT=0
until [ -n "$ONCALL_CID" ]; do
  ONCALL_CID=$(kcadm get "clients" -r "${KEYCLOAK_REALM}" -q clientId=oncall \
                 --fields id --format csv --noquotes 2>/dev/null \
                 | tr -d '\r' | grep -E '^[0-9a-f-]+$' | head -1)
  if [ -z "$ONCALL_CID" ]; then
    if [ $ONCALL_LOOKUP_WAIT -ge 30 ]; then
      log "WARN: OnCall client (clientId=oncall) not found in realm '${KEYCLOAK_REALM}' after 30s — skipping client-level breakages (continuing)"
      break
    fi
    sleep 3
    ONCALL_LOOKUP_WAIT=$((ONCALL_LOOKUP_WAIT + 3))
  fi
done

if [ -z "$ONCALL_CID" ]; then
  log "Skipping client-level breakages (will need correct clientId)"
  ONCALL_CID="MISSING"
else
  log "OnCall client UUID: ${ONCALL_CID}"
fi

# ----------------------------------------------------------------------------
# 6.3 — OnCall client breakages: directAccessGrantsEnabled, standardFlowEnabled,
# redirectUris (7 wrong/wildcard entries — none is the exact deployed callback),
# webOrigins (mixed valid+invalid), and 5 client attributes.
# Uses direct admin REST PUT to /admin/realms/nebula/clients/{id} so we can set
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

if [ "$ONCALL_CID" != "MISSING" ]; then
  CLIENT_PUT_HTTP=$(kc_admin_put "/admin/realms/${KEYCLOAK_REALM}/clients/${ONCALL_CID}" "$ONCALL_CLIENT_BODY_COMPACT")
  case "$CLIENT_PUT_HTTP" in
    20*|204) log "OnCall client breakages applied (HTTP ${CLIENT_PUT_HTTP})" ;;
    *) log "WARN: OnCall client PUT failed with HTTP ${CLIENT_PUT_HTTP} (continuing)" ;;
  esac
else
  log "WARN: skipping OnCall client breakages — ONCALL_CID=MISSING"
fi

# ----------------------------------------------------------------------------
# 6.4 — Delete the OnCall audience mapper (breakage 1.4).
# List all protocol mappers on the OnCall client; find the one of type
# oidc-audience-mapper that adds 'oncall' to the audience; DELETE it. If
# none exists (already deleted on a previous run), this is a no-op.
# ----------------------------------------------------------------------------
log "Removing OnCall audience mapper (breakage 1.4)..."
if [ "$ONCALL_CID" = "MISSING" ]; then
  log "WARN: skipping audience mapper deletion — ONCALL_CID=MISSING"
  MAPPERS_JSON=""
else
  MAPPERS_JSON=$(kc_admin_get "/admin/realms/${KEYCLOAK_REALM}/clients/${ONCALL_CID}/protocol-mappers/models" || true)
fi

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
#   PUT /admin/realms/nebula/client-policies/profiles  (registers the profile)
#   PUT /admin/realms/nebula/client-policies/policies  (binds the profile to
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
  || log "WARN: Failed to set responder password (continuing)"

log "Responder user ready (responder/responder123)."

# ============================================================================
# Section 8: P2.a keycloak-realm-reconciler (design §4 P2.a)
# Re-imports the OnCall client + realm settings every 30s. The ConfigMap
# holds the broken JSON; agent must edit either the ConfigMap or
# delete/scale the Deployment. Image: bitnami/kubectl:latest (pre-cached
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
      "realm": "nebula",
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
          image: bitnami/kubectl:latest
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set +e
              while true; do
                # Get admin token directly (curl ships in bitnami/kubectl:latest+)
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
                    http://keycloak.keycloak:8080/admin/realms/nebula

                  # Look up OnCall client UUID and re-PUT client-level breakages.
                  CID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
                    "http://keycloak.keycloak:8080/admin/realms/nebula/clients?clientId=oncall" \
                    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
                  if [ -n "$CID" ]; then
                    CLIENT_JSON=$(cat /etc/keycloak-template/client.json)
                    curl -s -o /dev/null -X PUT \
                      -H "Authorization: Bearer $ADMIN_TOKEN" \
                      -H "Content-Type: application/json" \
                      -d "$CLIENT_JSON" \
                      http://keycloak.keycloak:8080/admin/realms/nebula/clients/$CID
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
# Section 8/9: Istio breakages + prober pods + VAP P1.b (design §5.4 + §4 P1.b)
# ============================================================================
log "Applying Istio breakages..."

# Engine label discovery — the snapshot's oncall-engine deployment uses some
# label set we'll discover at run time.
ENGINE_LABEL_KEY=""
ENGINE_LABEL_VAL=""
for K in app.kubernetes.io/component app app.kubernetes.io/name; do
  V=$(kubectl get deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" \
    -o jsonpath="{.spec.selector.matchLabels.${K//./\\.}}" 2>/dev/null)
  if [ -n "$V" ]; then
    ENGINE_LABEL_KEY="$K"; ENGINE_LABEL_VAL="$V"; break
  fi
done
[ -n "$ENGINE_LABEL_KEY" ] || { ENGINE_LABEL_KEY="app.kubernetes.io/name"; ENGINE_LABEL_VAL="oncall-engine"; log "WARN: falling back to ${ENGINE_LABEL_KEY}=${ENGINE_LABEL_VAL}"; }
log "Engine selector: ${ENGINE_LABEL_KEY}=${ENGINE_LABEL_VAL}"

# 4 DENY AuthorizationPolicies on /integrations/* and /public-api/*
kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: bleater-deny-unauthenticated-ingestion
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: DENY
  rules:
    - from:
        - source:
            notRequestPrincipals: ["*"]
      to:
        - operation:
            paths: ["/integrations/*", "/integrations/v1/*"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: bleater-ingress-authz-guard
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: DENY
  rules:
    - to:
        - operation:
            paths: ["/integrations/v1/*", "/public-api/*"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: bleater-public-api-shadow-deny
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: DENY
  rules:
    - to:
        - operation:
            paths: ["/public-api/v1/*"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: bleater-v1-ack-webhook-deny
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: DENY
  rules:
    - to:
        - operation:
            paths: ["/api/v1/ack/*", "/integrations/v1/webhook/*"]
YAML
log "4 DENY AuthorizationPolicies applied"

# 2 ALLOW-only AuthorizationPolicies that require requestPrincipals
kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: bleater-public-callback-allowlist
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["*"]
      to:
        - operation:
            paths: ["/integrations/*"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: bleater-public-api-principal-guard
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["*"]
      to:
        - operation:
            paths: ["/public-api/*"]
YAML
log "2 ALLOW-only requestPrincipals AuthorizationPolicies applied"

# RequestAuthentication with bogus JWKS
kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: bleater-bogus-jwt-issuer
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  jwtRules:
    - issuer: "https://nonexistent.devops.local/"
      jwksUri: "https://nonexistent.devops.local/jwks.json"
YAML
log "Bogus RequestAuthentication applied"

# excludeInboundPorts annotation on engine deploy + rollout restart engine + celery
log "Patching oncall-engine pod template with excludeInboundPorts annotation..."
kubectl patch deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" --type=strategic \
  -p '{"spec":{"template":{"metadata":{"annotations":{"traffic.sidecar.istio.io/excludeInboundPorts":"8080"}}}}}' \
  >/dev/null 2>&1 || log "WARN: engine annotation patch failed (continuing)"

log "Rolling restart engine + celery to manifest sidecar injection..."
kubectl rollout restart deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" >/dev/null 2>&1 || true
kubectl rollout restart deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" >/dev/null 2>&1 || true
kubectl rollout status deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" --timeout=180s 2>/dev/null || \
  log "WARN: oncall-engine rollout did not finish in 180s"
kubectl rollout status deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" --timeout=180s 2>/dev/null || \
  log "WARN: oncall-celery rollout did not finish in 180s"

# 2 prober pods (mesh + nomesh) for the istio_anonymous_AND_admin grader probe
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: nebula-istio-prober-mesh
  namespace: ${ONCALL_NS}
  labels:
    nebula.io/role: mtls-prober
spec:
  containers:
    - name: curl
      image: docker.io/curlimages/curl:8.5.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
  restartPolicy: Always
---
apiVersion: v1
kind: Pod
metadata:
  name: nebula-istio-prober-nomesh
  namespace: ${ONCALL_NS}
  labels:
    nebula.io/role: mtls-prober
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  containers:
    - name: curl
      image: docker.io/curlimages/curl:8.5.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
  restartPolicy: Always
YAML
kubectl wait --for=condition=Ready --timeout=120s pod/nebula-istio-prober-mesh -n "${ONCALL_NS}" 2>/dev/null \
  || log "WARN: mesh prober not Ready in 120s"
kubectl wait --for=condition=Ready --timeout=120s pod/nebula-istio-prober-nomesh -n "${ONCALL_NS}" 2>/dev/null \
  || log "WARN: nomesh prober not Ready in 120s"
log "Prober pods deployed (mesh + nomesh)"

# VAP P1.b — feature-gated; non-fatal
if kubectl api-resources 2>/dev/null | grep -q validatingadmissionpolicies; then
  kubectl apply -f - 2>&1 <<'YAML' || log "WARN: VAP P1.b apply failed (continuing)"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: oncall-sso-empty-allow-policy-deny
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["security.istio.io"]
        apiVersions: ["v1", "v1beta1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["authorizationpolicies"]
  validations:
    - expression: |
        !(object.metadata.namespace == 'bleater') ||
        (has(object.spec) && has(object.spec.rules) && size(object.spec.rules) > 0)
      message: "AuthorizationPolicy in bleater must scope rules; empty rules and empty spec are blocked"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: oncall-sso-empty-allow-policy-deny-binding
spec:
  policyName: oncall-sso-empty-allow-policy-deny
  validationActions: [Deny]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: nebula-istio-policy-shape-guard
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["security.istio.io"]
        apiVersions: ["v1", "v1beta1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["authorizationpolicies"]
  validations:
    - expression: |
        !(object.metadata.namespace == 'bleater') ||
        (has(object.spec) && has(object.spec.rules) && size(object.spec.rules) > 0)
      message: "AuthorizationPolicy must scope rules"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: nebula-istio-policy-shape-guard-binding
spec:
  policyName: nebula-istio-policy-shape-guard
  validationActions: [Deny]
YAML
  log "VAP P1.b applied (empty AuthorizationPolicy spec deny)"
else
  log "WARN: VAP unavailable, skipping P1.b"
fi

log "Istio section complete."

# ============================================================================
# Section 10/11: TTL breakages + reconciler P2.b + settings-overrides Secret
# (design §5.5 + §4 P2.b)
# ============================================================================
log "Applying TTL breakages..."

# Approved + decoy ConfigMaps
kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall-runtime-policy
  namespace: ${ONCALL_NS}
data:
  ACKNOWLEDGE_TOKEN_TTL_SECONDS: "7200"
  INCIDENT_PUBLIC_TOKEN_TTL_SECONDS: "7200"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall-runtime-overrides
  namespace: ${ONCALL_NS}
data:
  ACKNOWLEDGE_TOKEN_TTL_SECONDS: "7200"
  INCIDENT_PUBLIC_TOKEN_TTL_SECONDS: "7200"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall-runtime-legacy
  namespace: ${ONCALL_NS}
data:
  ACKNOWLEDGE_TOKEN_TTL_SECONDS: "60"
  INCIDENT_PUBLIC_TOKEN_TTL_SECONDS: "60"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: incident-ack-link-policy
  namespace: ${ONCALL_NS}
data:
  ACKNOWLEDGE_TOKEN_TTL_SECONDS: "60"
  INCIDENT_PUBLIC_TOKEN_TTL_SECONDS: "60"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall-worker-runtime-policy
  namespace: ${ONCALL_NS}
data:
  ACKNOWLEDGE_TOKEN_TTL_SECONDS: "7200"
  INCIDENT_PUBLIC_TOKEN_TTL_SECONDS: "7200"
YAML
log "TTL ConfigMaps created"

# Engine settings-overrides Secret (breakage 5.5)
kubectl create secret generic oncall-settings-overrides -n "${ONCALL_NS}" \
  --from-literal='local_settings.py=ACKNOWLEDGE_TOKEN_TTL_SECONDS = 60' \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || \
  log "WARN: oncall-settings-overrides Secret create failed"

# Patch engine deployment: envFrom chain + volumeMount (last-wins → TTL=60)
kubectl patch deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" --type=strategic -p "$(cat <<'JSON'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "oncall",
            "envFrom": [
              {"configMapRef": {"name": "oncall-runtime-policy"}},
              {"configMapRef": {"name": "oncall-runtime-overrides"}},
              {"configMapRef": {"name": "incident-ack-link-policy"}},
              {"configMapRef": {"name": "oncall-runtime-legacy"}}
            ],
            "volumeMounts": [
              {
                "name": "settings-overrides",
                "mountPath": "/etc/oncall/local_settings.py",
                "subPath": "local_settings.py",
                "readOnly": true
              }
            ]
          }
        ],
        "volumes": [
          {
            "name": "settings-overrides",
            "secret": {"secretName": "oncall-settings-overrides"}
          }
        ]
      }
    }
  }
}
JSON
)" >/dev/null 2>&1 || log "WARN: engine TTL patch failed (continuing)"

# Patch celery deployment: inline env value=120 (env > envFrom)
kubectl patch deploy "${ONCALL_CELERY_DEPLOY}" -n "${ONCALL_NS}" --type=strategic -p "$(cat <<'JSON'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "oncall",
            "env": [
              {"name": "ACKNOWLEDGE_TOKEN_TTL_SECONDS", "value": "120"},
              {"name": "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS", "value": "120"}
            ],
            "envFrom": [
              {"configMapRef": {"name": "oncall-worker-runtime-policy"}}
            ]
          }
        ]
      }
    }
  }
}
JSON
)" >/dev/null 2>&1 || log "WARN: celery TTL patch failed (continuing)"

log "Rolling restart engine + celery to apply TTL breakages..."
kubectl rollout restart deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" >/dev/null 2>&1 || true
kubectl rollout restart deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" >/dev/null 2>&1 || true
kubectl rollout status deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" --timeout=180s 2>/dev/null || \
  log "WARN: engine TTL rollout did not finish"
kubectl rollout status deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" --timeout=180s 2>/dev/null || \
  log "WARN: celery TTL rollout did not finish"

# TTL reconciler P2.b
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ttl-policy-reconciler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ttl-policy-reconciler
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch", "update"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "patch", "update", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ttl-policy-reconciler
subjects:
  - kind: ServiceAccount
    name: ttl-policy-reconciler
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: ttl-policy-reconciler
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ttl-policy-reconciler
  namespace: kube-system
spec:
  replicas: 1
  selector: {matchLabels: {app: ttl-policy-reconciler}}
  template:
    metadata: {labels: {app: ttl-policy-reconciler}}
    spec:
      serviceAccountName: ttl-policy-reconciler
      containers:
        - name: reconciler
          image: docker.io/bitnami/kubectl:latest
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set +e
              while true; do
                # Re-create settings-overrides Secret with broken local_settings.py
                kubectl create secret generic oncall-settings-overrides -n bleater \
                  --from-literal='local_settings.py=ACKNOWLEDGE_TOKEN_TTL_SECONDS = 60' \
                  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
                # Re-patch engine envFrom with legacy + ack-link CMs in chain
                kubectl patch deploy oncall-engine -n bleater --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"oncall","envFrom":[{"configMapRef":{"name":"oncall-runtime-policy"}},{"configMapRef":{"name":"oncall-runtime-overrides"}},{"configMapRef":{"name":"incident-ack-link-policy"}},{"configMapRef":{"name":"oncall-runtime-legacy"}}]}]}}}}' >/dev/null 2>&1
                # Re-patch celery inline env back to 120
                kubectl patch deploy oncall-celery -n bleater --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"oncall","env":[{"name":"ACKNOWLEDGE_TOKEN_TTL_SECONDS","value":"120"},{"name":"INCIDENT_PUBLIC_TOKEN_TTL_SECONDS","value":"120"}]}]}}}}' >/dev/null 2>&1
                sleep 30
              done
YAML
kubectl wait --for=condition=available --timeout=180s deploy/ttl-policy-reconciler -n kube-system \
  || log "WARN: ttl-policy-reconciler not available"
log "TTL reconciler ready"

log "TTL section complete."

# ============================================================================
# Section 12/13: Grafana breakages + token-rotator CronJob + VAP P1.a
# (design §5.6 + §4 P1.a)
# ============================================================================
log "Applying Grafana breakages..."

# Stale runtime-auth Secrets — engine and worker get DIFFERENT invalid tokens
ENGINE_STALE_TOKEN="glsa_invalid_engine_$(date +%s)_deadbeef"
WORKER_STALE_TOKEN="glsa_invalid_worker_$(date +%s)_deadbeef"
SHADOW_STALE_TOKEN="glsa_shadow_invalid_$(date +%s)_cafebabe"
LEGACY_STALE_TOKEN="glsa_legacy_invalid_$(date +%s)_baadcafe"

kubectl create secret generic oncall-runtime-auth -n "${ONCALL_NS}" \
  --from-literal=GRAFANA_API_KEY="${ENGINE_STALE_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
kubectl create secret generic oncall-worker-runtime-auth -n "${ONCALL_NS}" \
  --from-literal=GRAFANA_API_KEY="${WORKER_STALE_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
kubectl create secret generic oncall-runtime-auth-shadow -n "${ONCALL_NS}" \
  --from-literal=GRAFANA_API_KEY="${SHADOW_STALE_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
kubectl create secret generic oncall-worker-grafana-legacy -n "${ONCALL_NS}" \
  --from-literal=GRAFANA_API_KEY="${LEGACY_STALE_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
log "Grafana auth Secrets created (engine + worker + shadow + legacy)"

# Engine envFrom: oncall-runtime-auth FIRST then shadow LAST (last-wins → engine sees shadow)
kubectl patch deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" --type=strategic -p "$(cat <<'JSON'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "oncall",
            "envFrom": [
              {"configMapRef": {"name": "oncall-runtime-policy"}},
              {"configMapRef": {"name": "oncall-runtime-overrides"}},
              {"configMapRef": {"name": "incident-ack-link-policy"}},
              {"configMapRef": {"name": "oncall-runtime-legacy"}},
              {"secretRef": {"name": "oncall-runtime-auth"}},
              {"secretRef": {"name": "oncall-runtime-auth-shadow"}}
            ]
          }
        ]
      }
    }
  }
}
JSON
)" >/dev/null 2>&1 || log "WARN: engine Grafana envFrom patch failed"

# Celery: valueFrom (env, wins) to oncall-worker-runtime-auth + envFrom of legacy (decoy)
kubectl patch deploy "${ONCALL_CELERY_DEPLOY}" -n "${ONCALL_NS}" --type=strategic -p "$(cat <<'JSON'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "oncall",
            "env": [
              {"name": "ACKNOWLEDGE_TOKEN_TTL_SECONDS", "value": "120"},
              {"name": "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS", "value": "120"},
              {"name": "GRAFANA_API_KEY", "valueFrom": {"secretKeyRef": {"name": "oncall-worker-runtime-auth", "key": "GRAFANA_API_KEY"}}}
            ],
            "envFrom": [
              {"configMapRef": {"name": "oncall-worker-runtime-policy"}},
              {"secretRef": {"name": "oncall-worker-grafana-legacy"}}
            ]
          }
        ]
      }
    }
  }
}
JSON
)" >/dev/null 2>&1 || log "WARN: celery Grafana env patch failed"

log "Rolling restart engine + celery to apply Grafana breakages..."
kubectl rollout restart deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" >/dev/null 2>&1 || true
kubectl rollout restart deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" >/dev/null 2>&1 || true
kubectl rollout status deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" --timeout=180s 2>/dev/null || \
  log "WARN: engine Grafana rollout did not finish"
kubectl rollout status deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" --timeout=180s 2>/dev/null || \
  log "WARN: celery Grafana rollout did not finish"

# Grafana token rotator CronJob (in monitoring ns)
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rotator-config
  namespace: monitoring
data:
  approved_prefix: "oncall-runtime-"
  notes: |
    The grafana-token-rotator CronJob deletes any Grafana service account
    whose name does NOT start with the approved prefix above. Mint Grafana
    service accounts using a name that starts with oncall-runtime- to avoid
    being nuked.
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: grafana-token-rotator
  namespace: monitoring
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: rotator
              image: docker.io/bitnami/kubectl:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set +e
                  GRAFANA_URL="http://grafana.monitoring.svc.cluster.local:3000"
                  PFX=$(kubectl get cm grafana-rotator-config -n monitoring -o jsonpath='{.data.approved_prefix}')
                  # Best-effort: delete service accounts whose name doesn't start with PFX.
                  # Uses Grafana admin API with admin/admin (snapshot baseline).
                  SAS=$(curl -s -u admin:admin "${GRAFANA_URL}/api/serviceaccounts/search?perpage=100&page=1")
                  echo "$SAS" | tr ',' '\n' | grep -oE '"id":[0-9]+,"name":"[^"]*"' | while read line; do
                    SAID=$(echo "$line" | grep -oE '"id":[0-9]+' | grep -oE '[0-9]+')
                    SANAME=$(echo "$line" | grep -oE '"name":"[^"]*"' | sed 's/"name":"//;s/"$//')
                    case "$SANAME" in
                      "${PFX}"*) ;;
                      *) curl -s -u admin:admin -X DELETE "${GRAFANA_URL}/api/serviceaccounts/${SAID}" >/dev/null ;;
                    esac
                  done
YAML
log "Grafana token-rotator CronJob deployed"

# VAP P1.a — feature-gated; non-fatal so setup.sh continues even if CEL rejects
if kubectl api-resources 2>/dev/null | grep -q validatingadmissionpolicies; then
  kubectl apply -f - 2>&1 <<'YAML' || log "WARN: VAP P1.a apply failed (continuing)"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: oncall-sso-grafana-token-format
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["secrets"]
  validations:
    - expression: |
        !(object.metadata.namespace == 'bleater' &&
          (object.metadata.name == 'oncall-runtime-auth' ||
           object.metadata.name == 'oncall-worker-runtime-auth')) ||
        (has(object.data) && has(object.data.GRAFANA_API_KEY) &&
         object.data.GRAFANA_API_KEY.startsWith('Z2xzYV8'))
      message: "GRAFANA_API_KEY in approved runtime-auth Secrets must start with 'glsa_'"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: oncall-sso-grafana-token-format-binding
spec:
  policyName: oncall-sso-grafana-token-format
  validationActions: [Deny]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: nebula-secret-shape-guard
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["secrets"]
  validations:
    - expression: |
        !(object.metadata.namespace == 'bleater' &&
          (object.metadata.name == 'oncall-runtime-auth' ||
           object.metadata.name == 'oncall-worker-runtime-auth')) ||
        (has(object.data) && has(object.data.GRAFANA_API_KEY) &&
         object.data.GRAFANA_API_KEY.startsWith('Z2xzYV8'))
      message: "GRAFANA_API_KEY format guard"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: nebula-secret-shape-guard-binding
spec:
  policyName: nebula-secret-shape-guard
  validationActions: [Deny]
YAML
  log "VAP P1.a apply attempted (any errors are non-fatal — see above)"
else
  log "WARN: VAP unavailable, skipping P1.a"
fi

log "Grafana section complete."

# ============================================================================
# Section 14/15: Postgres escalation breakages + trigger + reconciler P2.c
# (design §5.7 + §4 P2.c + P4)
# ============================================================================
log "Applying Postgres escalation breakages..."

# Seed alerts_escalationpolicy + create trigger via one-shot Job
kubectl apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: escalation-seed-job
  namespace: ${ONCALL_NS}
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: psql
          image: docker.io/library/postgres:16-alpine
          imagePullPolicy: IfNotPresent
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${ONCALL_PG_SECRET_NAME}
                  key: ${ESCALATION_PG_SECRET_KEY}
          command: ["/bin/sh", "-c"]
          args:
            - |
              psql -h ${ONCALL_PG_SVC_NAME} -p ${ESCALATION_DB_PORT} \
                -U ${ESCALATION_DB_USER} -d ${ESCALATION_DB_NAME} <<'SQL'
              -- The OnCall snapshot's alerts_escalationpolicy already has 8 rows
              -- attached to the 3 baseline escalation chains. We don't INSERT new
              -- rows (the schema has NOT NULL escalation_chain_id, public_primary_key,
              -- and other Django-managed columns we don't have safe defaults for).
              -- Instead, mutate the existing wait-step rows (step=0) to unsafe
              -- wait_delay values (= 5 min) and ensure all 8 rows have NULL or
              -- short wait_delay. The schema does NOT have repeat_escalations_rate
              -- so no checks against that column.

              -- Drop any stale trigger from a previous setup
              DROP TRIGGER IF EXISTS enforce_min_floor_trigger ON alerts_escalationpolicy;
              DROP FUNCTION IF EXISTS enforce_min_floor() CASCADE;

              -- Force unsafe wait_delays:
              --   - All step=0 (wait) rows -> wait_delay = '5 minutes' (below 20-min floor)
              --   - All non-wait rows already have NULL wait_delay -> leave NULL (also unsafe per grader)
              UPDATE alerts_escalationpolicy
                SET wait_delay = INTERVAL '5 minutes'
                WHERE step = 0;

              -- Create the BEFORE UPDATE trigger that blocks wait_delay > 15 minutes
              CREATE OR REPLACE FUNCTION enforce_min_floor() RETURNS TRIGGER AS \$\$
              BEGIN
                IF NEW.wait_delay IS NOT NULL AND NEW.wait_delay > INTERVAL '15 minutes' THEN
                  RAISE EXCEPTION 'business floor exceeded: wait_delay above 15 minutes is rejected by policy compliance trigger';
                END IF;
                RETURN NEW;
              END;
              \$\$ LANGUAGE plpgsql;

              CREATE TRIGGER enforce_min_floor_trigger
                BEFORE UPDATE ON alerts_escalationpolicy
                FOR EACH ROW EXECUTE FUNCTION enforce_min_floor();
              SQL
YAML

log "Waiting for escalation seed Job..."
kubectl wait --for=condition=complete --timeout=120s job/escalation-seed-job -n "${ONCALL_NS}" 2>/dev/null \
  || log "WARN: escalation seed Job did not complete in 120s (continuing)"

# Append trigger hint to escalation-storage-notes ConfigMap
EXISTING_NOTES=$(kubectl get cm escalation-storage-notes -n "${ONCALL_NS}" -o jsonpath='{.data.notes}' 2>/dev/null)
TRIGGER_HINT=$'\n\nIf your UPDATE is rejected with \'business floor exceeded\', inspect table\ntriggers — a non-policy enforcement may be intercepting your writes.'
if [ -n "$EXISTING_NOTES" ] && ! printf '%s' "$EXISTING_NOTES" | grep -q 'business floor exceeded'; then
  COMBINED_NOTES="${EXISTING_NOTES}${TRIGGER_HINT}"
  kubectl patch cm escalation-storage-notes -n "${ONCALL_NS}" --type=merge \
    -p "$(printf '{"data":{"notes":%s}}' "$(printf '%s' "$COMBINED_NOTES" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")" \
    >/dev/null 2>&1 || log "WARN: escalation-storage-notes patch failed"
fi

# Escalation reconciler P2.c — runs in kube-system. Volume-mounting Secrets
# across namespaces is not supported in K8s, so we read the PG password from
# the bleater Secret HERE (during setup), decode it, and inject it as a literal
# env value into the reconciler Deployment. The agent's solve path still works:
# they scale/delete the kube-system Deployment to stop the reverts.
PG_PW_PLAIN=$(kubectl get secret "${ONCALL_PG_SECRET_NAME}" -n "${ONCALL_NS}" \
  -o jsonpath='{.data.'"${ESCALATION_PG_SECRET_KEY}"'}' 2>/dev/null | base64 -d)
[ -n "$PG_PW_PLAIN" ] || log "WARN: could not read PG password from ${ONCALL_NS}/${ONCALL_PG_SECRET_NAME}"

kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: escalation-policy-reconciler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: escalation-policy-reconciler-secret
  namespace: ${ONCALL_NS}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: escalation-policy-reconciler-secret
  namespace: ${ONCALL_NS}
subjects:
  - kind: ServiceAccount
    name: escalation-policy-reconciler
    namespace: kube-system
roleRef:
  kind: Role
  name: escalation-policy-reconciler-secret
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: escalation-policy-reconciler
  namespace: kube-system
spec:
  replicas: 1
  selector: {matchLabels: {app: escalation-policy-reconciler}}
  template:
    metadata: {labels: {app: escalation-policy-reconciler}}
    spec:
      serviceAccountName: escalation-policy-reconciler
      containers:
        - name: reconciler
          image: docker.io/library/postgres:16-alpine
          imagePullPolicy: IfNotPresent
          env:
            - name: PGHOST
              value: ${ONCALL_PG_SVC_NAME}.${ONCALL_NS}.svc.cluster.local
            - name: PGPORT
              value: "${ESCALATION_DB_PORT}"
            - name: PGUSER
              value: ${ESCALATION_DB_USER}
            - name: PGDATABASE
              value: ${ESCALATION_DB_NAME}
            - name: PGPASSWORD
              value: "${PG_PW_PLAIN}"
          command: ["/bin/sh", "-c"]
          args:
            - |
              # Step is integer in OnCall's schema (0 = wait). Reset all
              # wait-step rows to 5 minutes (below 20 min floor) every cycle.
              while true; do
                psql -c "
                  UPDATE alerts_escalationpolicy
                  SET wait_delay = INTERVAL '5 minutes'
                  WHERE step = 0;
                " >/dev/null 2>&1
                sleep 30
              done
YAML
kubectl wait --for=condition=available --timeout=180s deploy/escalation-policy-reconciler -n kube-system 2>/dev/null \
  || log "WARN: escalation-policy-reconciler not available"
log "Escalation reconciler ready"

log "Postgres section complete."

# ============================================================================
# Section 16: Final cleanup
# ============================================================================
log "Final cleanup — clearing events..."
kubectl delete events --all -A >/dev/null 2>&1 || true

log "setup.sh complete: Keycloak + Istio + TTL + Grafana + Postgres breakages + reconcilers all applied."
