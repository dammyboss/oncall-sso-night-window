# ==========================================================
# Stage 1: Pre-cache container images using skopeo
# This runs during image BUILD when internet is available.
# Each tar is copied into k3s's auto-import directory so it
# is available offline when reconciler/prober pods start at
# eval time. Mirrors the hpa-scaling-thrash pattern.
# ==========================================================
FROM quay.io/skopeo/stable:v1.21.0 AS image-fetcher

WORKDIR /images

# bitnami/kubectl:latest — used by the in-cluster reconciler Deployments
# (keycloak-realm-reconciler, ttl-policy-reconciler, escalation-policy-reconciler).
# Includes kubectl + curl + bash, which is everything the reconcilers need.
# Uses :latest because Bitnami restructured Docker Hub: numeric version tags
# (e.g. 1.30) are now under bitnamilegacy/, while :latest remains under bitnami/.
# Mirrors hpa-scaling-thrash's working pattern.
RUN skopeo copy \
    docker://bitnami/kubectl:latest \
    docker-archive:kubectl-latest.tar:bitnami/kubectl:latest

# curlimages/curl:8.5.0 — used by the bleater Istio prober pods
# (nebula-istio-prober-mesh, nebula-istio-prober-nomesh) that the istio
# subscore probes. Tiny (~10MB) and curl-only.
RUN skopeo copy \
    docker://curlimages/curl:8.5.0 \
    docker-archive:curl-8.5.0.tar:curlimages/curl:8.5.0

# ==========================================================
# Stage 2: Final task image
# ==========================================================
FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.1.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

ENV ALLOWED_NAMESPACES="default,bleater,keycloak,monitoring,istio-system"
ENV ENABLE_ISTIO_BLEATER=true

# Copy pre-fetched image tars into k3s's auto-import directory.
# k3s scans this directory on startup and loads images into containerd —
# no internet pull required at runtime.
COPY --from=image-fetcher /images/*.tar /var/lib/rancher/k3s/agent/images/
