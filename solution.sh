#!/bin/bash
# Reference solution for oncall-sso-night-window. Reverses every breakage
# applied by setup.sh so the grader's 7 functional subscores all PASS.
# Runs as ubuntu via /home/ubuntu/.kube/config (Shivam Hard Rule 1).
set -e

export KUBECONFIG=/home/ubuntu/.kube/config

KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-nebula}"
ONCALL_NS="${ONCALL_NS:-bleater}"
ONCALL_ENGINE_DEPLOY="${ONCALL_ENGINE_DEPLOY:-oncall-engine}"
ONCALL_CELERY_DEPLOY="${ONCALL_CELERY_DEPLOY:-oncall-celery}"
GRAFANA_NS="${GRAFANA_NS:-monitoring}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# =============================================================================
# Phase 1: disable reconcilers (BEFORE any other fix — otherwise everything reverts)
# =============================================================================
log "Phase 1: scaling reconcilers to 0..."
kubectl scale deploy keycloak-realm-reconciler --replicas=0 -n kube-system 2>/dev/null || true
kubectl scale deploy ttl-policy-reconciler --replicas=0 -n kube-system 2>/dev/null || true
kubectl scale deploy escalation-policy-reconciler --replicas=0 -n kube-system 2>/dev/null || true
kubectl patch cronjob grafana-token-rotator -n "${GRAFANA_NS}" \
  --patch '{"spec":{"suspend":true}}' 2>/dev/null || true
log "Reconcilers disabled."

# =============================================================================
# Phase 2: fix Keycloak realm + client + audience mapper
# =============================================================================
log "Phase 2: fixing Keycloak..."
KC_INTERNAL_URL="http://keycloak.${KEYCLOAK_NS}.svc.cluster.local:8080"

# Phase 2.1: realm settings
kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master --user admin --password admin123

kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh update "realms/${KEYCLOAK_REALM}" \
    -s accessTokenLifespan=3600 \
    -s ssoSessionIdleTimeout=14400 \
    -s ssoSessionMaxLifespan=28800 \
    -s revokeRefreshToken=false \
    -s refreshTokenMaxReuse=0 \
    -s clientSessionIdleTimeout=14400

# Phase 2.2: clear realm Client Policy that rejects wildcards
kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- /bin/sh -c "
  /opt/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM}/client-policies/policies -b '{\"policies\":[]}' 2>/dev/null || true
  /opt/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM}/client-policies/profiles -b '{\"profiles\":[]}' 2>/dev/null || true
" || true

# Phase 2.3: fix OnCall client
ONCALL_CID=$(kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "${KEYCLOAK_REALM}" -q clientId=oncall \
    --fields id --format csv --noquotes 2>/dev/null \
  | tr -d '\r' | grep -E '^[0-9a-f-]+$' | head -1)

if [ -n "$ONCALL_CID" ]; then
  kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
    /opt/keycloak/bin/kcadm.sh update "clients/${ONCALL_CID}" -r "${KEYCLOAK_REALM}" \
      -s 'enabled=true' \
      -s 'directAccessGrantsEnabled=true' \
      -s 'standardFlowEnabled=true' \
      -s 'redirectUris=["https://oncall.devops.local/oauth/callback/complete/grafana-oauth/"]' \
      -s 'webOrigins=["https://oncall.devops.local"]' \
      -s 'attributes."use.refresh.tokens"=true' \
      -s 'attributes."oauth2.allow.refresh.token.reuse"=false' \
      -s 'attributes."client.refresh.token.rotation.policy"=ROTATE' \
      -s 'attributes."client.session.idle.timeout"=14400' \
      -s 'attributes."access.token.lifespan"=3600'

  # Re-add audience mapper if missing
  AUD_EXISTS=$(kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
    /opt/keycloak/bin/kcadm.sh get "clients/${ONCALL_CID}/protocol-mappers/models" -r "${KEYCLOAK_REALM}" \
      --fields name --format csv --noquotes 2>/dev/null \
    | grep -c '^oncall-audience$' || true)
  if [ "${AUD_EXISTS:-0}" = "0" ]; then
    kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
      /opt/keycloak/bin/kcadm.sh create "clients/${ONCALL_CID}/protocol-mappers/models" -r "${KEYCLOAK_REALM}" \
        -s name=oncall-audience \
        -s protocol=openid-connect \
        -s protocolMapper=oidc-audience-mapper \
        -s 'config."included.client.audience"=oncall' \
        -s 'config."id.token.claim"=false' \
        -s 'config."access.token.claim"=true'
  fi
  log "OnCall client fixed (UUID=${ONCALL_CID})"
else
  log "WARN: oncall client not found"
fi

# Ensure responder password
kubectl exec -n "${KEYCLOAK_NS}" deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh set-password -r "${KEYCLOAK_REALM}" \
    --username responder --new-password responder123 2>/dev/null || true
log "Phase 2 complete."

# =============================================================================
# Phase 3: fix Istio
# =============================================================================
log "Phase 3: fixing Istio..."

for AP in bleater-deny-unauthenticated-ingestion bleater-ingress-authz-guard \
          bleater-public-api-shadow-deny bleater-v1-ack-webhook-deny \
          bleater-public-callback-allowlist bleater-public-api-principal-guard; do
  kubectl delete authorizationpolicy "$AP" -n "${ONCALL_NS}" --ignore-not-found
done
kubectl delete requestauthentication bleater-bogus-jwt-issuer -n "${ONCALL_NS}" --ignore-not-found

ENGINE_LABEL_KEY=""
ENGINE_LABEL_VAL=""
for K in app.kubernetes.io/component app app.kubernetes.io/name; do
  V=$(kubectl get deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" \
    -o jsonpath="{.spec.selector.matchLabels.${K//./\\.}}" 2>/dev/null)
  if [ -n "$V" ]; then
    ENGINE_LABEL_KEY="$K"; ENGINE_LABEL_VAL="$V"; break
  fi
done
[ -n "$ENGINE_LABEL_KEY" ] || { ENGINE_LABEL_KEY="app.kubernetes.io/name"; ENGINE_LABEL_VAL="oncall-engine"; }

kubectl apply -f - <<YAML
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: oncall-allow-anonymous-callbacks
  namespace: ${ONCALL_NS}
spec:
  selector:
    matchLabels:
      ${ENGINE_LABEL_KEY}: ${ENGINE_LABEL_VAL}
  action: ALLOW
  rules:
    - to:
        - operation:
            paths: ["/integrations/*", "/integrations/v1/*", "/public-api/*", "/public-api/v1/*"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: oncall-protect-internal-admin
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
            paths: ["/api/internal/*", "/api/internal/v1/*"]
YAML

# Remove the excludeInboundPorts annotation
kubectl patch deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" --type=json -p '
[{"op":"remove","path":"/spec/template/metadata/annotations/traffic.sidecar.istio.io~1excludeInboundPorts"}]
' 2>/dev/null || true
log "Phase 3 complete."

# =============================================================================
# Phase 4: fix TTL — clean envFrom on engine + drop celery inline TTL env
# =============================================================================
log "Phase 4: fixing TTL..."

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
              {"secretRef": {"name": "oncall-runtime-auth"}}
            ]
          }
        ]
      }
    }
  }
}
JSON
)" 2>/dev/null || true

# Remove engine settings-overrides volumeMount + volume (json patch)
kubectl patch deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" --type=json -p '
[{"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts"}]
' 2>/dev/null || true
kubectl patch deploy "${ONCALL_ENGINE_DEPLOY}" -n "${ONCALL_NS}" --type=json -p '
[{"op":"remove","path":"/spec/template/spec/volumes"}]
' 2>/dev/null || true

# Celery: rebuild env + envFrom — drop inline TTL=120
kubectl patch deploy "${ONCALL_CELERY_DEPLOY}" -n "${ONCALL_NS}" --type=strategic -p "$(cat <<'JSON'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "oncall",
            "env": [
              {"name": "GRAFANA_API_KEY", "valueFrom": {"secretKeyRef": {"name": "oncall-worker-runtime-auth", "key": "GRAFANA_API_KEY"}}}
            ],
            "envFrom": [
              {"configMapRef": {"name": "oncall-worker-runtime-policy"}},
              {"secretRef": {"name": "oncall-worker-runtime-auth"}}
            ]
          }
        ]
      }
    }
  }
}
JSON
)" 2>/dev/null || true
log "Phase 4 complete."

# =============================================================================
# Phase 5: fix Grafana — mint a real SA token (prefix oncall-runtime-) and
# write to BOTH runtime-auth Secrets so engine + celery share a working token
# =============================================================================
log "Phase 5: fixing Grafana..."

# Re-suspend the rotator while we work, but we've already done that in Phase 1.
GRAFANA_BASE="http://grafana.${GRAFANA_NS}.svc.cluster.local:3000"
SA_NAME="oncall-runtime-runtime-$(date +%s)"

NEW_TOKEN=$(kubectl run grafana-mint-$RANDOM --rm --restart=Never --quiet -i \
  --image=docker.io/bitnami/kubectl:latest --image-pull-policy=IfNotPresent \
  --command -- /bin/bash -c "
    set +e
    BASE='$GRAFANA_BASE'
    SA=\$(curl -s -u admin:admin -X POST -H 'Content-Type: application/json' \
      -d '{\"name\":\"$SA_NAME\",\"role\":\"Admin\"}' \
      \$BASE/api/serviceaccounts)
    SAID=\$(printf '%s' \"\$SA\" | sed -n 's/.*\"id\":\([0-9]*\).*/\1/p' | head -1)
    if [ -z \"\$SAID\" ]; then
      SAID=\$(curl -s -u admin:admin \"\$BASE/api/serviceaccounts/search?perpage=100&page=1&query=$SA_NAME\" \
        | sed -n 's/.*\"id\":\([0-9]*\),\"name\":\"$SA_NAME\".*/\1/p' | head -1)
    fi
    [ -z \"\$SAID\" ] && exit 1
    TOK=\$(curl -s -u admin:admin -X POST -H 'Content-Type: application/json' \
      -d '{\"name\":\"oncall-token-$(date +%s)\"}' \
      \$BASE/api/serviceaccounts/\$SAID/tokens)
    printf '%s' \"\$TOK\" | sed -n 's/.*\"key\":\"\\([^\"]*\\)\".*/\\1/p' | head -1
" 2>/dev/null)

NEW_TOKEN=$(printf '%s' "$NEW_TOKEN" | tr -d '\r\n ')
[ -n "$NEW_TOKEN" ] || { echo "ERROR: failed to mint Grafana token"; exit 1; }
log "Minted Grafana SA token (length=${#NEW_TOKEN})"

# Write SAME token to both Secrets
for SEC in oncall-runtime-auth oncall-worker-runtime-auth; do
  kubectl create secret generic "$SEC" -n "${ONCALL_NS}" \
    --from-literal=GRAFANA_API_KEY="${NEW_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
log "Phase 5 complete."

# =============================================================================
# Phase 6: rollout restart engine + celery so new env propagates
# =============================================================================
log "Phase 6: rollout restart engine + celery..."
kubectl rollout restart deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}"
kubectl rollout restart deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}"
kubectl rollout status deploy/${ONCALL_ENGINE_DEPLOY} -n "${ONCALL_NS}" --timeout=180s
kubectl rollout status deploy/${ONCALL_CELERY_DEPLOY} -n "${ONCALL_NS}" --timeout=180s
log "Phase 6 complete."

# =============================================================================
# Phase 7: fix Postgres — DROP TRIGGER + UPDATE rows >= 20 minutes
# =============================================================================
log "Phase 7: fixing Postgres escalation..."

kubectl delete job escalation-fix-job -n "${ONCALL_NS}" --ignore-not-found
kubectl apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: escalation-fix-job
  namespace: ${ONCALL_NS}
spec:
  ttlSecondsAfterFinished: 60
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
                  name: oncall-postgresql-external
                  key: postgres-password
          command: ["/bin/sh", "-c"]
          args:
            - |
              psql -h bleater-postgresql -U oncall -d oncall <<'SQL'
              DROP TRIGGER IF EXISTS enforce_min_floor_trigger ON alerts_escalationpolicy;
              -- OnCall's actual schema: only wait_delay (no repeat_escalations_rate),
              -- step is integer (0 = wait). Set every wait-step row to >= 20 min.
              UPDATE alerts_escalationpolicy
                SET wait_delay = INTERVAL '20 minutes'
                WHERE step = 0 AND (wait_delay IS NULL OR wait_delay < INTERVAL '20 minutes');
              SQL
YAML
kubectl wait --for=condition=complete --timeout=120s job/escalation-fix-job -n "${ONCALL_NS}"
log "Phase 7 complete."

log "solution.sh complete."
