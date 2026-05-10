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
# Section 6: Final cleanup
# ============================================================================
log "Final cleanup — clearing events..."
kubectl delete events --all -A >/dev/null 2>&1 || true

log "Skeleton setup.sh complete (no breakages applied)."
