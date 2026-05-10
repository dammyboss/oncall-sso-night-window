#!/usr/bin/env python3
"""
Nebula grader: OnCall / Keycloak / Istio overnight SSO task.
Seven equal-weight behavioral subscores per HARDENING-DESIGN §3 + §10.
Each check is an independent functional probe (no cascade — design §10.2).
"""
from __future__ import annotations

import base64
import json
import os
import re
import shlex
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Optional, Tuple

from apex_arena._types import GradingResult

SUBKEYS = [
    "keycloak_session_idle",
    "keycloak_redirect_authorize",
    "keycloak_refresh",
    "istio_anonymous_AND_admin",
    "ttl_runtime",
    "grafana_token_flow",
    "escalation_window",
]
WEIGHT = 1.0 / len(SUBKEYS)


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, str(default)))
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


# Bound worst-case runtime so MCP grade_problem cannot appear to hang for hours.
MAX_KC_PASSWORD_CANDIDATES = max(4, _env_int("NEBULA_MAX_KC_PASSWORD_CANDIDATES", 8))
KC_CLUSTER_PHASE_SEC = max(15.0, _env_float("NEBULA_KC_CLUSTER_PHASE_SEC", 90.0))
KC_JOB_PHASE_SEC = max(30.0, _env_float("NEBULA_KC_JOB_PHASE_SEC", 120.0))
GRADE_WALL_CLOCK_SEC = max(180.0, _env_float("NEBULA_GRADE_BUDGET_SEC", 600.0))
KC_ADMIN_TOKEN_HTTP_TIMEOUT = max(5, _env_int("NEBULA_KC_TOKEN_HTTP_TIMEOUT", 12))
ISTIO_HTTP_ATTEMPTS = max(3, _env_int("NEBULA_ISTIO_HTTP_ATTEMPTS", 7))
ISTIO_HTTP_BACKOFF_BASE_SEC = max(0.2, _env_float("NEBULA_ISTIO_HTTP_BACKOFF_BASE_SEC", 1.0))
GRAFANA_HTTP_ATTEMPTS = max(3, _env_int("NEBULA_GRAFANA_HTTP_ATTEMPTS", 6))
GRAFANA_HTTP_BACKOFF_BASE_SEC = max(0.2, _env_float("NEBULA_GRAFANA_HTTP_BACKOFF_BASE_SEC", 0.7))
ESCALATION_DB_ATTEMPTS = max(2, _env_int("NEBULA_ESCALATION_DB_ATTEMPTS", 4))
ESCALATION_DB_BACKOFF_BASE_SEC = max(0.2, _env_float("NEBULA_ESCALATION_DB_BACKOFF_BASE_SEC", 0.8))


def _wait_deploy_rollout(ns: str, deploy_name: str) -> None:
    """Best-effort rollout wait before runtime pod/env verification."""
    if not ns or not deploy_name:
        return
    qns = shlex.quote(ns)
    qd = shlex.quote(deploy_name)
    run_cmd(
        f"kubectl rollout status deploy/{qd} -n {qns} --timeout=120s",
        timeout=145,
    )


KEYCLOAK_NS = "keycloak"
KEYCLOAK_REALM = "devops"
# Default; discover_oncall_namespace() prefers env, then bleater, oncall, cluster-wide.
ONCALL_NS = "bleater"
GRAFANA_NS = "monitoring"
ONCALL_PUBLIC_HOST = "oncall.devops.local"

_oncall_ns_cached: Optional[str] = None
_oncall_ns_discovery_ran = False
ONCALL_CLIENT_ID = "oncall"
# Must match the OnCall Grafana OAuth callback path for this build (see Nebula task #986).
REDIRECT_PROBE = "https://oncall.devops.local/oauth/callback/complete/grafana-oauth/"

# When the admin token is obtained via kubectl port-forward, keep the forward alive for
# subsequent admin/auth HTTP calls (ClusterIP is often unreachable from the grader host).
_KC_ADMIN_PF_PROC: Optional[subprocess.Popen] = None
_KC_ADMIN_PF_BASE: Optional[str] = None

# Filled once per grade() for Keycloak inspect shared by aggregate + atomic helpers; cleared per grade().
_kc_oauth_inspect_cache: Optional[dict[str, Any]] = None

# Cap ClusterIP URL attempts (reduces timing-sensitive fan-out).
_KC_CLUSTER_BASE_CAP = max(1, _env_int("NEBULA_KC_CLUSTER_BASE_CAP", 2))
_KC_PF_READY_SEC = max(3.0, _env_float("NEBULA_KC_PF_READY_SEC", 22.0))

_ONCALL_TTL_ACK = "ACKNOWLEDGE_TOKEN_TTL_SECONDS"
_ONCALL_TTL_PUB = "INCIDENT_PUBLIC_TOKEN_TTL_SECONDS"
# Exact acknowledge / public link TTL target (seconds); documented in overnight-runbook.
_ONCALL_TTL_TARGET_SEC = max(60, _env_int("NEBULA_ONCALL_TTL_TARGET_SEC", 7200))
_REQUIRE_TTL_CONFIGMAP_ONLY = (_env_int("NEBULA_REQUIRE_TTL_CONFIGMAP_ONLY", 1) == 1)
_REQUIRE_TTL_ENGINE_CELERY_MATCH = (_env_int("NEBULA_REQUIRE_TTL_ENGINE_CELERY_MATCH", 1) == 1)
_APPROVED_TTL_CM_BY_DEPLOY = {
    "oncall-engine": "oncall-runtime-policy",
    "oncall-celery": "oncall-worker-runtime-policy",
}
_ENGINE_TTL_DIAGNOSTIC_CMS = {"oncall-runtime-shadow", "incident-ack-link-policy"}
_APPROVED_GRAFANA_SECRET_BY_DEPLOY = {
    "oncall-engine": "oncall-runtime-auth",
    "oncall-celery": "oncall-worker-runtime-auth",
}
_GRAFANA_TOKEN_KEYS = {"GRAFANA_API_KEY", "GRAFANA_TOKEN", "grafana_token"}
# Minimum escalation step wait and repeat interval (minutes); documented in task.yaml.
_ESCALATION_MIN_WAIT_MINUTES = 20


def _kc_cleanup_admin_portforward() -> None:
    global _KC_ADMIN_PF_PROC, _KC_ADMIN_PF_BASE
    proc = _KC_ADMIN_PF_PROC
    _KC_ADMIN_PF_PROC = None
    _KC_ADMIN_PF_BASE = None
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
    except OSError:
        pass


def log(msg: str) -> None:
    print(f"[DEBUG] {msg}", file=sys.stderr)


def run_cmd(cmd: str, timeout: int = 120) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"


def kubectl_json(args: str, timeout: int = 60) -> Any:
    rc, out, _ = run_cmd(
        f"kubectl {args} -o json",
        timeout=timeout,
    )
    if rc != 0 or not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def _namespace_has_oncall_engine(ns: str) -> bool:
    data = kubectl_json(f"get deploy -n {ns}")
    if not data:
        return False
    for item in data.get("items") or []:
        name = (item.get("metadata") or {}).get("name", "").lower()
        if "oncall" in name and "engine" in name:
            return True
    return False


def _discover_oncall_namespace_impl() -> str:
    """Resolve OnCall namespace: env override if it contains an oncall+engine deploy, else bleater/oncall, else cluster scan."""
    for envk in ("NEBULA_ONCALL_NAMESPACE", "ONCALL_NAMESPACE", "ONCALL_NS"):
        raw = (os.environ.get(envk) or "").strip()
        if not raw:
            continue
        if _namespace_has_oncall_engine(raw):
            log(f"OnCall namespace from {envk}={raw}")
            return raw
        log(f"Ignoring {envk}={raw}: no Deployment matching oncall+engine")
    # Avoid cluster-scope APIs (namespaces list, deployments -A) since some runners forbid them.
    for cand in ("bleater", "oncall"):
        if _namespace_has_oncall_engine(cand):
            log(f"OnCall namespace discovered: {cand}")
            return cand
    log("OnCall namespace not discovered (no oncall+engine Deployment)")
    return ""


def discover_oncall_namespace() -> str:
    global _oncall_ns_cached, _oncall_ns_discovery_ran
    if _oncall_ns_discovery_ran:
        return _oncall_ns_cached or ""
    _oncall_ns_discovery_ran = True
    _oncall_ns_cached = _discover_oncall_namespace_impl()
    return _oncall_ns_cached or ""


def reset_oncall_namespace_cache() -> None:
    """Clear cached OnCall namespace and Keycloak OAuth inspect state (for tests / repeated grade runs)."""
    global _oncall_ns_cached, _oncall_ns_discovery_ran, _kc_oauth_inspect_cache
    _kc_cleanup_admin_portforward()
    _kc_oauth_inspect_cache = None
    _oncall_ns_cached = None
    _oncall_ns_discovery_ran = False


def _kc_reset_oauth_inspect_for_new_grade() -> None:
    """Fresh Keycloak inspect each grade(); keep OnCall namespace cache within the run."""
    global _kc_oauth_inspect_cache
    _kc_cleanup_admin_portforward()
    _kc_oauth_inspect_cache = None


def _secret_has_pg_password_keys(raw: dict) -> bool:
    if not raw:
        return False
    for k in (
        "password",
        "postgres-password",
        "postgresql-password",
        "postgresql-postgres-password",
        "db-password",
    ):
        v = raw.get(k)
        if v and len(str(v).strip()) > 0:
            return True
    return False


def discover_oncall_postgres_secret_name(ns: str) -> str:
    """Match common Helm / OnCall DB secret names and password key shapes."""
    data = kubectl_json(f"get secret -n {ns}")
    if not data:
        return ""
    skip_name = re.compile(
        r"tls|grafana|redis|rabbit|jwt|oauth|istio|keycloak|basic-auth", re.I
    )
    skip_type = re.compile(r"kubernetes\.io/tls|helm\.sh/release", re.I)
    want_name = re.compile(
        r"postgres|oncall.*(db|sql|pg)|database|jdbc|-pg-|pgsql", re.I
    )
    for sec in data.get("items") or []:
        meta = sec.get("metadata") or {}
        name = str(meta.get("name") or "")
        name_lc = name.lower()
        st = str(sec.get("type") or "")
        if skip_type.search(st):
            continue
        if skip_name.search(name_lc):
            continue
        if not want_name.search(name_lc):
            continue
        raw = sec.get("data") or {}
        if _secret_has_pg_password_keys(raw):
            return name
    return ""


def _keycloak_http_like_service(name: str) -> bool:
    """True for IdP HTTP services; false for keycloak-postgresql, exporters, etc."""
    n = name.lower()
    if "keycloak" not in n:
        return False
    for bad in (
        "postgres",
        "postgresql",
        "jdbc",
        "exporter",
        "pooler",
        "metrics",
        "database",
        "redis",
        "rabbit",
        "mysql",
        "maria",
        "proxy",
    ):
        if bad in n:
            return False
    return True


def discover_keycloak_namespace() -> str:
    """Prefer a Keycloak IdP Service (not postgres sidecars); ClusterIP first, then headless."""
    data = kubectl_json("get svc -A")
    if not data or "items" not in data:
        return KEYCLOAK_NS
    headless_ns = ""
    for svc in data["items"]:
        name = str((svc.get("metadata") or {}).get("name", ""))
        if name != "keycloak":
            continue
        spec = svc.get("spec") or {}
        ip = spec.get("clusterIP")
        ns = str((svc.get("metadata") or {}).get("namespace") or KEYCLOAK_NS)
        if ip and ip != "None":
            return ns
        if not headless_ns:
            headless_ns = ns
    for svc in data["items"]:
        name = str((svc.get("metadata") or {}).get("name", ""))
        if not _keycloak_http_like_service(name):
            continue
        spec = svc.get("spec") or {}
        ip = spec.get("clusterIP")
        ns = str((svc.get("metadata") or {}).get("namespace") or KEYCLOAK_NS)
        if ip and ip != "None":
            return ns
        if not headless_ns:
            headless_ns = ns
    return headless_ns or KEYCLOAK_NS


def discover_keycloak_base_urls(namespace: Optional[str] = None) -> list[str]:
    """All plausible Keycloak base URLs (ClusterIP + endpoint pod IPs + https on 8443)."""
    ns = namespace or discover_keycloak_namespace()
    data = kubectl_json(f"get svc -n {ns}")
    if not data or "items" not in data:
        return []
    out: list[str] = []
    for svc in data["items"]:
        name = (svc.get("metadata") or {}).get("name", "")
        if "keycloak" not in name.lower():
            continue
        ip = (svc.get("spec") or {}).get("clusterIP")
        if not ip or ip == "None":
            continue
        ports: set[int] = set()
        for p in (svc.get("spec") or {}).get("ports") or []:
            pp = int(p.get("port") or 0)
            if pp > 0:
                ports.add(pp)
        if not ports:
            ports.add(8080)
        for port in sorted(ports):
            out.append(f"http://{ip}:{port}")
            if port in (8443, 443):
                out.append(f"https://{ip}:{port}")
        if 8443 not in ports:
            out.append(f"https://{ip}:8443")

    # Headless / no ClusterIP: probe ready pod IPs from Endpoints (same path many Nebula shells use).
    for svc in data["items"]:
        name = (svc.get("metadata") or {}).get("name", "")
        if "keycloak" not in name.lower():
            continue
        sn = (svc.get("metadata") or {}).get("name")
        if not sn:
            continue
        ep = kubectl_json(f"get endpoints {sn} -n {ns}")
        for sub in (ep or {}).get("subsets") or []:
            for addr in sub.get("addresses") or []:
                pip = (addr.get("ip") or "").strip()
                if not pip:
                    continue
                sub_ports = sub.get("ports") or []
                if not sub_ports:
                    out.append(f"http://{pip}:8080")
                    out.append(f"https://{pip}:8443")
                    continue
                for pp in sub_ports:
                    pnum = int(pp.get("port") or 8080)
                    out.append(f"http://{pip}:{pnum}")
                    if pnum in (8443, 443):
                        out.append(f"https://{pip}:{pnum}")
                if not any(int((x.get("port") or 0)) == 8443 for x in sub_ports):
                    out.append(f"https://{pip}:8443")
    return list(dict.fromkeys(out))


def discover_keycloak_base(namespace: Optional[str] = None) -> Optional[str]:
    urls = discover_keycloak_base_urls(namespace)
    return urls[0] if urls else None


def _keycloak_internal_http_base(ns: str) -> str:
    """In-cluster HTTP base (Kubernetes DNS) for reachability checks."""
    data = kubectl_json(f"get svc -n {ns}")
    if not data:
        return ""
    for svc in data.get("items") or []:
        name = (svc.get("metadata") or {}).get("name", "")
        if "keycloak" not in name.lower():
            continue
        port = 8080
        for p in (svc.get("spec") or {}).get("ports") or []:
            port = int(p.get("port") or 8080)
            break
        return f"http://{name}.{ns}.svc.cluster.local:{port}"
    return ""


def _secret_password_candidates(ns: str) -> list[str]:
    data = kubectl_json(f"get secret -n {ns}")
    if not data:
        return []
    found: list[str] = []
    for sec in data.get("items") or []:
        st = sec.get("type") or ""
        if "tls" in st.lower() or "istio.io/key" in st.lower():
            continue
        for k, v in (sec.get("data") or {}).items():
            kl = k.lower()
            if not any(x in kl for x in ("password", "admin-pass", "secret", "credential")):
                continue
            if any(x in kl for x in ("tls", "crt", ".key", "keystore", "truststore", "jwt", "cookie")):
                continue
            try:
                raw = base64.b64decode(v).decode("utf-8", errors="replace").strip()
            except Exception:
                continue
            if len(raw) >= 4:
                found.append(raw)
    return list(dict.fromkeys(found))


def _workload_admin_password_candidates(ns: str) -> list[str]:
    found: list[str] = []
    for kind in ("deployment", "statefulset"):
        data = kubectl_json(f"get {kind} -n {ns}")
        if not data:
            continue
        for obj in data.get("items") or []:
            tpl = (obj.get("spec") or {}).get("template", {})
            for c in (tpl.get("spec") or {}).get("containers") or []:
                for env in c.get("env") or []:
                    en = (env.get("name") or "").lower()
                    val = env.get("value")
                    if not val or not isinstance(val, str):
                        continue
                    if any(
                        x in en
                        for x in (
                            "keycloak_admin",
                            "kc_bootstrap",
                            "bootstrap_admin",
                            "admin_password",
                            "keycloak_http_password",
                            "keycloak_password",
                        )
                    ):
                        found.append(val.strip())
    return list(dict.fromkeys(found))


def keycloak_running_pod(ns: str) -> str:
    data = kubectl_json(f"get pods -n {ns}")
    if not data:
        return ""
    best = ""
    for pod in data.get("items") or []:
        if (pod.get("status") or {}).get("phase") != "Running":
            continue
        name = (pod.get("metadata") or {}).get("name", "")
        if "keycloak" not in name.lower():
            continue
        return name
    for pod in data.get("items") or []:
        if (pod.get("status") or {}).get("phase") != "Running":
            continue
        return str((pod.get("metadata") or {}).get("name") or "")
    return ""


def _kc_token_pod_exec(ns: str, pod: str, username: str, password: str) -> str:
    if not pod or not password:
        return ""
    b64 = base64.b64encode(password.encode("utf-8")).decode("ascii")
    inner = (
        f"P=$(echo {b64} | base64 -d); "
        f'for port in 8080 9000; do '
        f"T=$(curl -sS --connect-timeout 3 --max-time 20 -X POST http://127.0.0.1:${{port}}/realms/master/protocol/openid-connect/token "
        f'-d "grant_type=password" -d "client_id=admin-cli" -d "username={username}" -d "password=$P" 2>/dev/null | jq -r ".access_token // empty"); '
        f'[[ -n "$T" && "$T" != "null" ]] && echo "$T" && exit 0; '
        f"done; "
        f"T=$(curl -sS -k --connect-timeout 3 --max-time 20 -X POST https://127.0.0.1:8443/realms/master/protocol/openid-connect/token "
        f'-d "grant_type=password" -d "client_id=admin-cli" -d "username={username}" -d "password=$P" 2>/dev/null | jq -r ".access_token // empty"); '
        f'echo "$T"'
    )
    rc, out, _ = run_cmd(
        f"kubectl exec -n {ns} {pod} -- bash -c {json.dumps(inner)}",
        timeout=60,
    )
    if rc != 0:
        return ""
    tok = (out or "").strip().splitlines()[-1] if out else ""
    if tok and tok != "null":
        return tok
    return ""


def _kc_keycloak_forward_headers(base_url: str) -> dict[str, str]:
    """Host / X-Forwarded-* when using raw IP or internal DNS so Keycloak matches token vhost."""
    fh = (
        os.environ.get("NEBULA_KC_PF_FORWARD_HOST")
        or os.environ.get("KC_FORWARD_HOST")
        or "keycloak.devops.local"
    )
    if not fh:
        return {}
    try:
        host = (urllib.parse.urlparse(base_url).hostname or "").lower().rstrip(".")
    except Exception:
        host = ""
    fh_l = fh.lower().rstrip(".")
    if not host or host == fh_l:
        return {}
    return {
        "Host": fh,
        "X-Forwarded-Proto": "https" if base_url.startswith("https://") else "http",
        "X-Forwarded-Host": fh,
    }


def _kc_keycloak_admin_request_headers(base_url: str, token: str) -> dict[str, str]:
    h: dict[str, str] = {"Authorization": f"Bearer {token}"}
    h.update(_kc_keycloak_forward_headers(base_url))
    return h


def kc_admin_token(base: str, password: str, username: str = "admin") -> str:
    if not base or not password:
        return ""
    data = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": username,
            "password": password,
        }
    ).encode()
    req = urllib.request.Request(
        f"{base.rstrip('/')}/realms/master/protocol/openid-connect/token",
        data=data,
        method="POST",
    )
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    for hk, hv in _kc_keycloak_forward_headers(base).items():
        req.add_header(hk, hv)
    ctx = None
    if base.startswith("https://"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(
            req, timeout=KC_ADMIN_TOKEN_HTTP_TIMEOUT, context=ctx
        ) as resp:
            body = json.loads(resp.read().decode())
        return str(body.get("access_token") or "")
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, OSError):
        return ""


def _collect_kc_password_candidates(ns: str) -> list[str]:
    """Keycloak workload env + secrets in the Keycloak namespace only (deterministic)."""
    candidates: list[str] = []
    candidates.extend(_workload_admin_password_candidates(ns))
    candidates.extend(_secret_password_candidates(ns))

    unique = []
    seen = set()
    for raw in candidates:
        val = (raw or "").strip()
        if not val or val in seen:
            continue
        seen.add(val)
        unique.append(val)

    return sorted(unique)


def _kc_local_port_ready(port: int, deadline_sec: float) -> bool:
    """Wait until something accepts TCP on 127.0.0.1:port (port-forward actually listening)."""
    deadline = time.monotonic() + max(0.5, deadline_sec)
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.35):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def _kc_admin_token_via_portforward(
    ns: str, users: tuple[str, ...], candidates: list[str]
) -> str:
    """Stable token path: kubectl port-forward to Keycloak svc, then admin-cli on localhost."""
    global _KC_ADMIN_PF_PROC, _KC_ADMIN_PF_BASE
    _kc_cleanup_admin_portforward()
    data = kubectl_json(f"get svc -n {ns}")
    if not data:
        return ""
    svc_name = ""
    port = 8080
    for svc in data.get("items") or []:
        name = str((svc.get("metadata") or {}).get("name") or "")
        if "keycloak" not in name.lower():
            continue
        spec = svc.get("spec") or {}
        svc_name = name
        for p in spec.get("ports") or []:
            port = int(p.get("port") or 8080)
            break
        break
    if not svc_name:
        return ""
    local_port = max(1024, _env_int("KEYCLOAK_PF_LOCAL_PORT", 18080))
    cmd = (
        f"kubectl port-forward -n {shlex.quote(ns)} "
        f"svc/{shlex.quote(svc_name)} {local_port}:{port}"
    )
    proc: Optional[subprocess.Popen] = None
    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not _kc_local_port_ready(local_port, _KC_PF_READY_SEC):
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
            log("kc_token port-forward local port never became ready")
            return ""
        base = f"http://127.0.0.1:{local_port}"
        # Prefer admin with each password before other bootstrap users (fewer attempts, less flake).
        for pwd in candidates:
            if not pwd:
                continue
            tok = kc_admin_token(base, pwd, "admin")
            if tok:
                _KC_ADMIN_PF_PROC = proc
                _KC_ADMIN_PF_BASE = base
                proc = None
                log("kc_token OK via localhost port-forward")
                return tok
        for user in users:
            if user == "admin":
                continue
            for pwd in candidates:
                if not pwd:
                    continue
                tok = kc_admin_token(base, pwd, user)
                if tok:
                    _KC_ADMIN_PF_PROC = proc
                    _KC_ADMIN_PF_BASE = base
                    proc = None
                    log("kc_token OK via localhost port-forward")
                    return tok
    except OSError as e:
        log(f"kc_token port-forward failed: {e!r}")
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
    return ""


def obtain_keycloak_admin_token(base: Optional[str]) -> str:
    """Prefer port-forward + small password set; bounded ClusterIP tries; last-resort pod exec."""
    ns = discover_keycloak_namespace()
    candidates = _collect_kc_password_candidates(ns)[:MAX_KC_PASSWORD_CANDIDATES]
    users = ("admin", "keycloak", "user")
    tok_pf = _kc_admin_token_via_portforward(ns, users, candidates)
    if tok_pf:
        return tok_pf
    internal = _keycloak_internal_http_base(ns)
    bases_all = discover_keycloak_base_urls(ns)
    if internal:
        bases_all = list(dict.fromkeys([internal] + bases_all))
    if base:
        bases_all = list(dict.fromkeys([base] + bases_all))
    bases = bases_all[:_KC_CLUSTER_BASE_CAP]
    t_cluster = time.monotonic()

    def _cluster_expired() -> bool:
        return (time.monotonic() - t_cluster) > KC_CLUSTER_PHASE_SEC

    log(
        f"kc_token cluster phase ns={ns} bases_try={len(bases)}/{len(bases_all)} "
        f"candidates={len(candidates)} budget_sec={KC_CLUSTER_PHASE_SEC}"
    )
    for b in bases:
        if _cluster_expired():
            log("kc_token cluster phase budget exceeded")
            break
        for pwd in candidates[:5]:
            if _cluster_expired():
                break
            tok = kc_admin_token(b, pwd, "admin")
            if tok:
                return tok
        for user in users:
            if user == "admin":
                continue
            if _cluster_expired():
                break
            for pwd in candidates[:5]:
                if _cluster_expired():
                    break
                tok = kc_admin_token(b, pwd, user)
                if tok:
                    return tok
    pod = keycloak_running_pod(ns)
    if pod:
        t_exec = time.monotonic()
        exec_budget = min(60.0, max(20.0, KC_JOB_PHASE_SEC))

        def _exec_expired() -> bool:
            return (time.monotonic() - t_exec) > exec_budget

        for pwd in candidates[:6]:
            if _exec_expired():
                log("kc_token pod exec budget exceeded")
                break
            tok = _kc_token_pod_exec(ns, pod, "admin", pwd)
            if tok:
                return tok
        for user in users:
            if user == "admin":
                continue
            if _exec_expired():
                log("kc_token pod exec budget exceeded")
                break
            for pwd in candidates[:6]:
                if _exec_expired():
                    break
                tok = _kc_token_pod_exec(ns, pod, user, pwd)
                if tok:
                    return tok
            if _exec_expired():
                log("kc_token pod exec budget exceeded")
                break
    return ""


def _kc_curl_pod_raw(
    ns: str, pod: str, token: Optional[str], path: str, extra_curl: str = ""
) -> Tuple[int, str]:
    """GET path on Keycloak loopback; path may include ?query (passed via env KPATH)."""
    kp = shlex.quote(path)
    if token:
        inner = (
            f"export KC_TOKEN={shlex.quote(token)}; export KPATH={kp}; "
            "for port in 8080 9000; do "
            f"code=$(curl -sS {extra_curl} -g -o /tmp/kc.out -w '%{{http_code}}' --connect-timeout 5 --max-time 35 "
            '-H "Authorization: Bearer $KC_TOKEN" "http://127.0.0.1:${port}${KPATH}" 2>/dev/null || echo 000); '
            'if [[ "$code" == "200" ]] || [[ "$code" == "204" ]]; then '
            "cat /tmp/kc.out 2>/dev/null; printf '\\nCODE:%s\\n' \"$code\"; exit 0; fi; "
            "done; printf '\\nCODE:000\\n'; exit 0"
        )
    else:
        inner = (
            f"export KPATH={kp}; "
            "for port in 8080 9000; do "
            f"code=$(curl -sS {extra_curl} -g -o /tmp/kc.out -w '%{{http_code}}' --connect-timeout 5 --max-time 35 "
            '"http://127.0.0.1:${port}${KPATH}" 2>/dev/null || echo 000); '
            'if [[ "$code" == "200" ]] || [[ "$code" == "302" ]] || [[ "$code" == "301" ]]; then '
            "cat /tmp/kc.out 2>/dev/null; printf '\\nCODE:%s\\n' \"$code\"; exit 0; fi; "
            "done; printf '\\nCODE:000\\n'; exit 0"
        )
    rc, out, _ = run_cmd(
        f"kubectl exec -n {ns} {pod} -- bash -ce {shlex.quote(inner)}",
        timeout=120,
    )
    if rc != 0 or not out:
        return -1, ""
    if "CODE:" not in out:
        return -1, out.strip()
    idx = out.rfind("CODE:")
    body = out[:idx].strip()
    tail = out[idx + 5 :].strip().splitlines()
    try:
        code = int(tail[0]) if tail else 0
    except ValueError:
        code = 0
    return code, body


def http_json(
    url: str,
    method: str = "GET",
    headers: Optional[dict] = None,
    data: Optional[bytes] = None,
    timeout: int = 20,
    insecure_https: bool = False,
) -> Tuple[int, Any]:
    h = dict(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    ctx = None
    if insecure_https and url.startswith("https://"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read().decode(errors="replace")
            code = resp.getcode()
            try:
                return code, json.loads(raw)
            except json.JSONDecodeError:
                return code, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except (urllib.error.URLError, OSError):
        return -1, ""


def kc_admin_json(
    ns: str, base: Optional[str], pod: str, token: str, url_path: str
) -> Tuple[int, Any]:
    """GET admin JSON: localhost PF (if active), ClusterIP/HTTPS URLs, then Keycloak pod exec."""
    pf_first: list[str] = []
    if _KC_ADMIN_PF_BASE:
        pf_first.append(_KC_ADMIN_PF_BASE)
    bases = list(
        dict.fromkeys(
            pf_first + ([base] if base else []) + discover_keycloak_base_urls(ns)
        )
    )
    for b in bases:
        u = f"{b.rstrip('/')}{url_path}"
        code, data = http_json(
            u,
            headers=_kc_keycloak_admin_request_headers(b, token),
            insecure_https=b.startswith("https://"),
        )
        if code == 200:
            return code, data
    if pod:
        hc2, raw2 = _kc_curl_pod_raw(ns, pod, token, url_path)
        if hc2 == 200 and raw2:
            try:
                return 200, json.loads(raw2)
            except json.JSONDecodeError:
                return hc2, raw2
        return hc2, raw2
    return -1, ""


def _kc_authorize_flow_acceptable(body: str, final_url: str) -> Tuple[bool, str]:
    """True when authorize GET shows a normal login / auth continuation, not invalid_redirect / loop / JSON error."""
    bl = (body or "").lower()
    fu = (final_url or "").lower()
    if not bl.strip() and not fu:
        return False, "empty authorize response"
    if "invalid_request" in bl or "invalid_parameter" in bl:
        return False, "OAuth error (invalid_request / invalid_parameter) in authorize response"
    if "error_description" in bl and "error=" in bl:
        return False, "OAuth error payload (error + error_description) in authorize response"
    if "redirect_uri" in bl and "invalid" in bl:
        return False, "invalid redirect_uri in authorize response body"
    if "we are sorry" in bl and "invalid" in bl:
        return False, "Keycloak error page indicates invalid authorize request"
    if "too many redirects" in bl or "redirect loop" in bl:
        return False, "redirect-loop style message in authorize response"
    if bl[:900].strip().startswith("{") and '"error"' in bl[:900]:
        return False, "JSON OAuth error payload from authorize endpoint"
    # Harden: require a real login FORM signal, not generic HTML.
    has_kc_markers = (
        "kc-form-login" in bl
        or 'id="kc-form-login"' in bl
        or "kc-page-login" in bl
        or "login-pf-page" in bl
        or "login-pf-header" in bl
    )
    has_formish = "<form" in bl and "login-actions/authenticate" in bl
    has_user_field = (
        'name="username"' in bl
        or "name='username'" in bl
        or 'name="email"' in bl
        or "name='email'" in bl
    )
    has_password_field = (
        'type="password"' in bl
        or "type='password'" in bl
        or 'name="password"' in bl
        or "name='password'" in bl
    )
    if has_kc_markers and has_formish and has_user_field:
        return True, "Keycloak login form (expected step after idle / re-auth)"
    if has_formish and (has_user_field or has_password_field):
        return True, "Keycloak login authenticate form present"
    return False, (
        "authorize response missing Keycloak login form (need real re-auth entry, "
        "not generic HTML)"
    )


def _kc_authorize_once(
    ns: str,
    pod: str,
    base: Optional[str],
    auth_pf: list[str],
    extra_params: dict[str, str],
) -> Tuple[bool, str, str]:
    """One authorize GET; returns (ok, detail, auth_path for pod curl)."""
    qd: dict[str, str] = {
        "response_type": "code",
        "client_id": ONCALL_CLIENT_ID,
        "scope": "openid",
        "redirect_uri": REDIRECT_PROBE,
    }
    qd.update(extra_params)
    q = urllib.parse.urlencode(qd)
    auth_path = f"/realms/{KEYCLOAK_REALM}/protocol/openid-connect/auth?{q}"
    body = ""
    final = ""
    auth_bases = list(
        dict.fromkeys(auth_pf + ([base] if base else []) + discover_keycloak_base_urls(ns))
    )
    for b in auth_bases:
        auth_url = f"{b.rstrip('/')}{auth_path}"
        ctx = None
        if b.startswith("https://"):
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            req = urllib.request.Request(auth_url, method="GET")
            for hk, hv in _kc_keycloak_forward_headers(b).items():
                req.add_header(hk, hv)
            with urllib.request.urlopen(req, timeout=18, context=ctx) as resp:
                final = resp.geturl()
                body = resp.read().decode(errors="replace")
                break
        except urllib.error.HTTPError as e:
            final = e.geturl() or ""
            body = e.read().decode(errors="replace") if e.fp else ""
            break
        except (urllib.error.URLError, OSError):
            continue
    if not body and pod:
        _, raw = _kc_curl_pod_raw(ns, pod, None, auth_path)
        body = raw or ""
    if not body.strip():
        return False, (
            "Could not verify Keycloak authorize flow "
            "(no response from discovered bases or pod exec)"
        ), auth_path
    ok, detail = _kc_authorize_flow_acceptable(body, final)
    return ok, detail, auth_path


def _kc_probe_authorize_e2e(
    ns: str, pod: str, base: Optional[str], auth_pf: list[str]
) -> Tuple[bool, str]:
    """Authorize for REDIRECT_PROBE: default, forced login, max_age=0, popup, locale.

    Harden: require both an external-style HTTP probe (grader host) and an in-cluster probe
    (kubectl exec from an OnCall workload pod to the Keycloak Service DNS) to reach a real
    Keycloak login form for each variant.
    """
    probes: tuple[tuple[str, dict[str, str]], ...] = (
        ("default authorize", {}),
        ("prompt=login (forced re-auth)", {"prompt": "login"}),
        ("max_age=0 (OIDC stale session / re-auth)", {"max_age": "0"}),
        ("display=popup (alternate UI flow)", {"display": "popup"}),
        ("ui_locales=en (locale-specific flow)", {"ui_locales": "en"}),
    )
    details: list[str] = []

    def _authorize_in_cluster(auth_path: str) -> Tuple[bool, str]:
        # Use an OnCall pod as the client, so we exercise in-cluster DNS + proxy/hostname behavior.
        on_ns = discover_oncall_namespace() or ONCALL_NS
        client_pod = ""
        client_ctr = ""
        for dep in ("oncall-celery", "oncall-engine"):
            client_pod = _first_running_pod_for_deploy(on_ns, dep)
            if client_pod:
                client_ctr = _first_container_name(on_ns, dep) or ""
                break
        if not client_pod:
            return False, "no Running oncall pod available for in-cluster authorize probe"
        kc_internal = _keycloak_internal_http_base(ns)
        if not kc_internal:
            return False, "Keycloak Service DNS not discovered for in-cluster authorize probe"
        url = f"{kc_internal.rstrip('/')}{auth_path}"
        qns = shlex.quote(on_ns)
        qpod = shlex.quote(client_pod)
        cflag = f"-c {shlex.quote(client_ctr)} " if client_ctr.strip() else ""
        hdrs = (
            "-H 'Host: keycloak.devops.local' "
            "-H 'X-Forwarded-Host: keycloak.devops.local' "
            "-H 'X-Forwarded-Proto: https' "
        )
        # Prefer curl if present.
        rc, _, _ = run_cmd(
            f"kubectl exec -n {qns} {qpod} {cflag}-- sh -c 'command -v curl >/dev/null 2>&1'",
            timeout=25,
        )
        body = ""
        if rc == 0:
            rc2, out2, _ = run_cmd(
                f"kubectl exec -n {qns} {qpod} {cflag}-- sh -c "
                f"\"curl -sS -k {hdrs} --connect-timeout 5 --max-time 25 {shlex.quote(url)} 2>/dev/null\"",
                timeout=45,
            )
            if rc2 == 0 and out2:
                body = out2
        if not body:
            # Fallback: wget
            rc, _, _ = run_cmd(
                f"kubectl exec -n {qns} {qpod} {cflag}-- sh -c 'command -v wget >/dev/null 2>&1'",
                timeout=25,
            )
            if rc == 0:
                rc2, out2, _ = run_cmd(
                    f"kubectl exec -n {qns} {qpod} {cflag}-- sh -c "
                    f"\"wget -q -S -O - {shlex.quote(url)} 2>/dev/null | head -c 200000\"",
                    timeout=50,
                )
                if rc2 == 0 and out2:
                    body = out2
        if not body.strip():
            return False, "in-cluster authorize probe returned empty body"
        ok, detail = _kc_authorize_flow_acceptable(body, "")
        return ok, f"in-cluster: {detail}"

    for label, extra in probes:
        ok_ext, detail_ext, auth_path = _kc_authorize_once(ns, pod, base, auth_pf, extra)
        if not ok_ext:
            return False, f"{label} (external): {detail_ext}"
        ok_in, detail_in = _authorize_in_cluster(auth_path)
        if not ok_in:
            return False, f"{label} (in-cluster): {detail_in}"
        details.append(f"{detail_ext}; {detail_in}")
    return True, "; ".join(details)


def inspect_keycloak_oauth_state() -> dict[str, Any]:
    """
    Inspect the Keycloak realm and OnCall OAuth client once; return independent booleans for:
    - session_idle_ok (realm ssoSessionIdleTimeout >= 4h and max lifespan >= idle)
    - redirect_ok (client redirectUris include complete/grafana-oauth)
    - refresh_ok (OnCall client refresh-token + session attrs; realm idle/ATL/coherence scored under
      session_idle_ok without double-counting when the realm failure is only those limits)
    - authorize_ok (OIDC authorize for REDIRECT_PROBE: default, prompt=login, max_age=0,
      display=popup, ui_locales=en — each must show a normal Keycloak login step)

    Cached for the remainder of the current grade() so the four Keycloak checks share work.
    """
    global _kc_oauth_inspect_cache
    if _kc_oauth_inspect_cache is not None:
        return _kc_oauth_inspect_cache

    token_fail = (
        "Could not obtain Keycloak admin token (ClusterIP/HTTPS, port-forward, "
        "optional pod exec; users admin/keycloak/user; workload env + Secrets)"
    )
    no_kc = "Keycloak Service and running pod not found"

    state: dict[str, Any] = {
        "session_idle_ok": False,
        "redirect_ok": False,
        "refresh_ok": False,
        "authorize_ok": False,
        "msgs": {
            "session_idle": "",
            "redirect": "",
            "refresh": "",
            "authorize": "",
        },
    }
    msgs: dict[str, str] = state["msgs"]

    try:
        ns = discover_keycloak_namespace()
        base = discover_keycloak_base(ns)
        pod = keycloak_running_pod(ns)
        kc_urls = discover_keycloak_base_urls(ns)
        if not kc_urls and not pod and not _keycloak_internal_http_base(ns):
            for k in msgs:
                msgs[k] = no_kc
            _kc_oauth_inspect_cache = state
            return state

        token = obtain_keycloak_admin_token(base)

        realm_idle_sso: Optional[int] = None
        realm_refresh_block_reason: Optional[str] = None
        # When True, ``realm_refresh_block_reason`` only duplicates ``keycloak_session_idle`` realm
        # limits; ``keycloak_refresh_tokens`` still evaluates the OnCall client (no double-jeopardy).
        realm_refresh_dup_session_idle_only = False
        if token:
            code, realm = kc_admin_json(
                ns, base, pod, token, f"/admin/realms/{KEYCLOAK_REALM}"
            )
            if code != 200 or not isinstance(realm, dict):
                msgs["session_idle"] = (
                    f"Keycloak realm {KEYCLOAK_REALM} not readable (HTTP {code})"
                )
                realm_refresh_block_reason = (
                    f"Keycloak realm {KEYCLOAK_REALM} not readable for OAuth refresh usability (HTTP {code})"
                )
            else:
                # Harden: require explicit realm limits (missing/zero is treated as broken).
                idle_raw = realm.get("ssoSessionIdleTimeout")
                max_raw = realm.get("ssoSessionMaxLifespan")
                idle = int(idle_raw or 0)
                max_life = int(max_raw or 0)
                realm_idle_sso = idle
                atl_raw = realm.get("accessTokenLifespan")
                atl_val: Optional[int] = None
                if atl_raw is not None:
                    try:
                        atl_val = int(atl_raw)
                    except (TypeError, ValueError):
                        atl_val = None

                if idle_raw is None or idle == 0:
                    msgs["session_idle"] = (
                        "realm ssoSessionIdleTimeout must be explicitly configured (missing/0 is treated as broken)"
                    )
                    realm_refresh_block_reason = msgs["session_idle"]
                    realm_refresh_dup_session_idle_only = True
                elif max_raw is None or max_life == 0:
                    msgs["session_idle"] = (
                        "realm ssoSessionMaxLifespan must be explicitly configured (missing/0 is treated as broken)"
                    )
                    realm_refresh_block_reason = msgs["session_idle"]
                    realm_refresh_dup_session_idle_only = True
                elif idle < 14400:
                    msgs["session_idle"] = (
                        f"ssoSessionIdleTimeout is {idle}s; need >= 14400s (4h)"
                    )
                    realm_refresh_block_reason = (
                        f"realm ssoSessionIdleTimeout is {idle}s; overnight SSO + refresh requires >= 14400s (4h)"
                    )
                    realm_refresh_dup_session_idle_only = True
                elif max_life < 28800:
                    msgs["session_idle"] = (
                        f"ssoSessionMaxLifespan is {max_life}s; need >= 28800s (8h)"
                    )
                    realm_refresh_block_reason = msgs["session_idle"]
                    realm_refresh_dup_session_idle_only = True
                elif max_life < idle:
                    msgs["session_idle"] = (
                        f"ssoSessionMaxLifespan ({max_life}s) is below ssoSessionIdleTimeout "
                        f"({idle}s); realm SSO limits must allow the configured idle window "
                        "(raise max lifespan or lower idle — incoherent settings break overnight SSO)"
                    )
                    realm_refresh_block_reason = (
                        f"realm ssoSessionMaxLifespan ({max_life}s) is below ssoSessionIdleTimeout ({idle}s); "
                        f"incoherent realm SSO limits break overnight re-auth / refresh usability"
                    )
                    realm_refresh_dup_session_idle_only = True
                elif atl_raw is not None and atl_val is None:
                    msgs["session_idle"] = (
                        f"accessTokenLifespan is present but not a valid integer ({atl_raw!r}); "
                        "realm token lifetime must be parseable"
                    )
                    realm_refresh_block_reason = msgs["session_idle"]
                    realm_refresh_dup_session_idle_only = True
                elif atl_val is not None and atl_val <= 600:
                    msgs["session_idle"] = (
                        f"accessTokenLifespan is {atl_val}s; lifetimes of 10 minutes or less "
                        "are unsafe for the full acknowledge handoff"
                    )
                    realm_refresh_block_reason = msgs["session_idle"]
                    realm_refresh_dup_session_idle_only = True
                elif atl_raw is None:
                    msgs["session_idle"] = (
                        "realm accessTokenLifespan must be explicitly configured (missing is treated as broken)"
                    )
                    realm_refresh_block_reason = msgs["session_idle"]
                    realm_refresh_dup_session_idle_only = True
                else:
                    rm_idle_raw = realm.get("ssoSessionIdleTimeoutRememberMe")
                    rm_max_raw = realm.get("ssoSessionMaxLifespanRememberMe")
                    off_idle_raw = realm.get("offlineSessionIdleTimeout")
                    off_max_raw = realm.get("offlineSessionMaxLifespan")
                    rm_idle: Optional[int] = None
                    rm_max: Optional[int] = None
                    off_idle: Optional[int] = None
                    off_max: Optional[int] = None
                    try:
                        rm_idle = (
                            int(rm_idle_raw) if rm_idle_raw is not None and str(rm_idle_raw).strip() != "" else None
                        )
                    except (TypeError, ValueError):
                        rm_idle = None
                    try:
                        rm_max = (
                            int(rm_max_raw) if rm_max_raw is not None and str(rm_max_raw).strip() != "" else None
                        )
                    except (TypeError, ValueError):
                        rm_max = None
                    try:
                        off_idle = (
                            int(off_idle_raw) if off_idle_raw is not None and str(off_idle_raw).strip() != "" else None
                        )
                    except (TypeError, ValueError):
                        off_idle = None
                    try:
                        off_max = (
                            int(off_max_raw) if off_max_raw is not None and str(off_max_raw).strip() != "" else None
                        )
                    except (TypeError, ValueError):
                        off_max = None
                    if rm_idle is not None and rm_idle < idle:
                        msgs["session_idle"] = (
                            f"ssoSessionIdleTimeoutRememberMe ({rm_idle}s) undercuts ssoSessionIdleTimeout ({idle}s)"
                        )
                        realm_refresh_block_reason = msgs["session_idle"]
                        realm_refresh_dup_session_idle_only = True
                    elif rm_max is not None and rm_max < max_life:
                        msgs["session_idle"] = (
                            f"ssoSessionMaxLifespanRememberMe ({rm_max}s) undercuts ssoSessionMaxLifespan ({max_life}s)"
                        )
                        realm_refresh_block_reason = msgs["session_idle"]
                        realm_refresh_dup_session_idle_only = True
                    elif off_idle is not None and off_idle < 28800:
                        msgs["session_idle"] = (
                            f"offlineSessionIdleTimeout is {off_idle}s; need >= 28800s for overnight continuity"
                        )
                        realm_refresh_block_reason = msgs["session_idle"]
                        realm_refresh_dup_session_idle_only = True
                    elif off_max is not None and off_max < 28800:
                        msgs["session_idle"] = (
                            f"offlineSessionMaxLifespan is {off_max}s; need >= 28800s for overnight continuity"
                        )
                        realm_refresh_block_reason = msgs["session_idle"]
                        realm_refresh_dup_session_idle_only = True
                    else:
                        state["session_idle_ok"] = True
                        msgs["session_idle"] = (
                            f"Realm SSO session OK: idle={idle}s (>=4h), "
                            f"ssoSessionMaxLifespan={max_life}s (>= idle), "
                            f"accessTokenLifespan={atl_val if atl_val is not None else 'inherit'}s"
                        )

            q_cli = urllib.parse.quote(ONCALL_CLIENT_ID, safe="")
            c2, clients = kc_admin_json(
                ns,
                base,
                pod,
                token,
                f"/admin/realms/{KEYCLOAK_REALM}/clients?clientId={q_cli}",
            )
            if c2 != 200 or not isinstance(clients, list) or not clients:
                msgs["redirect"] = "oncall OAuth client not found in Keycloak"
                msgs["refresh"] = "oncall OAuth client not found in Keycloak"
            else:
                cid = clients[0].get("id")
                c3, client = kc_admin_json(
                    ns, base, pod, token, f"/admin/realms/{KEYCLOAK_REALM}/clients/{cid}"
                )
                if c3 != 200 or not isinstance(client, dict):
                    cm = "Could not load oncall client representation"
                    msgs["redirect"] = cm
                    msgs["refresh"] = cm
                else:
                    uris = [str(u or "").strip() for u in (client.get("redirectUris") or [])]
                    has_generic = any("complete/grafana-oauth" in u for u in uris)
                    has_deployed_callback = any(
                        "/oauth/callback/complete/grafana-oauth/" in u for u in uris
                    )
                    exact_needed = f"https://{ONCALL_PUBLIC_HOST}/oauth/callback/complete/grafana-oauth/"
                    has_exact = any(u == exact_needed for u in uris)
                    has_http_oncall = any(
                        u.startswith(f"http://{ONCALL_PUBLIC_HOST}/") for u in uris
                    )
                    oncall_wildcards = [
                        u for u in uris
                        if u.startswith(f"https://{ONCALL_PUBLIC_HOST}/") and "*" in u
                    ]
                    poisoned_meta = {
                        "rootUrl": "https://oncall.devops.local/invalid/root",
                        "baseUrl": "/invalid/callback-placeholder",
                        "adminUrl": "https://oncall.devops.local/invalid/admin",
                    }
                    if not has_generic:
                        msgs["redirect"] = (
                            "oncall client redirect URIs missing /complete/grafana-oauth/ "
                            "path for this OnCall build"
                        )
                    elif not has_deployed_callback:
                        msgs["redirect"] = (
                            "oncall client redirect URIs missing deployed callback pattern "
                            "/oauth/callback/complete/grafana-oauth/ required by current flow"
                        )
                    elif not has_exact:
                        msgs["redirect"] = (
                            f"oncall client redirect URIs must include the exact deployed callback "
                            f"{exact_needed!r} (wildcard-only entries are treated as a shortcut)"
                        )
                    elif has_http_oncall:
                        msgs["redirect"] = (
                            f"oncall client redirect URIs include insecure http:// entries for {ONCALL_PUBLIC_HOST}; "
                            "use https:// redirect URIs only for the deployed callback flow"
                        )
                    elif oncall_wildcards:
                        msgs["redirect"] = (
                            f"oncall client redirect URIs still include wildcard shortcut(s): {sorted(oncall_wildcards)}; "
                            "use exact deployed callback URIs instead of host/path wildcards"
                        )
                    else:
                        web_origins = [str(o or "").strip() for o in (client.get("webOrigins") or [])]
                        bad_web_origins = [
                            o for o in web_origins
                            if o == "+"
                            or o.startswith("http://")
                            or "*" in o
                        ]
                        expected_origin = f"https://{ONCALL_PUBLIC_HOST}"
                        if bad_web_origins:
                            msgs["redirect"] = (
                                f"oncall client webOrigins still include broad or insecure origin entries: "
                                f"{sorted(bad_web_origins)}; use the deployed HTTPS OnCall origin only"
                            )
                        elif expected_origin not in web_origins:
                            msgs["redirect"] = (
                                f"oncall client webOrigins must include deployed HTTPS origin {expected_origin!r}"
                            )
                        elif any(
                            str(client.get(k) or "").strip() == v for k, v in poisoned_meta.items()
                        ):
                            msgs["redirect"] = (
                                "oncall client metadata still points to known invalid callback placeholders "
                                "(rootUrl/baseUrl/adminUrl)"
                            )
                        else:
                            state["redirect_ok"] = True
                            msgs["redirect"] = (
                                "redirect URIs include deployed /oauth/callback/complete/grafana-oauth/ path"
                            )
                    attrs = client.get("attributes") or {}
                    urt = (attrs.get("use.refresh.tokens") or "").lower()
                    ore = (attrs.get("oauth2.allow.refresh.token.reuse") or "true").lower()
                    if realm_refresh_block_reason and not realm_refresh_dup_session_idle_only:
                        msgs["refresh"] = realm_refresh_block_reason
                    elif (
                        (sf := client.get("standardFlowEnabled")) is False
                        or (isinstance(sf, str) and str(sf).strip().lower() in ("false", "0"))
                    ):
                        msgs["refresh"] = (
                            "standardFlowEnabled is false; OAuth code flow (and refresh chain) broken"
                        )
                    elif urt == "false":
                        msgs["refresh"] = (
                            "use.refresh.tokens is false; oncall client disables refresh tokens"
                        )
                    elif ore == "false":
                        msgs["refresh"] = (
                            "oauth2.allow.refresh.token.reuse is false; refresh-token reuse disabled "
                            "(breaks re-authentication after idle)"
                        )
                    else:
                        need_max_sess = max(
                            28800, realm_idle_sso if realm_idle_sso is not None else 0
                        )

                        def _parse_client_sess_attr(
                            attr: str, raw: Any
                        ) -> Tuple[Optional[int], Optional[str]]:
                            if raw is None:
                                return None, None
                            s = str(raw).strip()
                            if s == "":
                                return None, None
                            try:
                                return int(s), None
                            except ValueError:
                                return None, (
                                    f"oncall client attribute {attr} is not a valid integer "
                                    f"seconds value when set (got {raw!r})"
                                )

                        c_idle, err_idle = _parse_client_sess_attr(
                            "client.session.idle.timeout",
                            attrs.get("client.session.idle.timeout"),
                        )
                        c_max, err_max = _parse_client_sess_attr(
                            "client.session.max.lifespan",
                            attrs.get("client.session.max.lifespan"),
                        )
                        c_offline_idle, err_offline_idle = _parse_client_sess_attr(
                            "client.offline.session.idle.timeout",
                            attrs.get("client.offline.session.idle.timeout"),
                        )
                        # Accept inherited realm behavior when the realm session bucket is already valid.
                        # Broken explicit client overrides still fail below.
                        if c_idle is None and state["session_idle_ok"]:
                            c_idle = realm_idle_sso or 14400

                        if c_max is None and state["session_idle_ok"]:
                            c_max = need_max_sess

                        if err_idle:
                            msgs["refresh"] = err_idle
                        elif err_max:
                            msgs["refresh"] = err_max
                        elif c_idle is None:
                            msgs["refresh"] = (
                                "client.session.idle.timeout is absent and realm session inheritance is not usable; "
                                "refresh continuity requires either valid inherited realm session behavior or a valid client override"
                            )
                        elif c_max is None:
                            msgs["refresh"] = (
                                "client.session.max.lifespan is absent and realm session inheritance is not usable; "
                                "refresh continuity requires either valid inherited realm session behavior or a valid client override"
                            )
                        elif c_idle == 0:
                            msgs["refresh"] = (
                                "client.session.idle.timeout is explicitly 0; client override breaks "
                                "per-session idle (inherit realm defaults or set >= 14400s)"
                            )
                        elif c_idle is not None and c_idle < 14400:
                            msgs["refresh"] = (
                                f"client.session.idle.timeout is {c_idle}s when explicitly set; "
                                f"need >= 14400s (4h overnight SSO target)"
                            )
                        elif c_max is not None and c_max == 0:
                            msgs["refresh"] = (
                                "client.session.max.lifespan is explicitly 0; client override caps OAuth "
                                "session lifetime and breaks refresh/SSO continuity "
                                "(inherit realm or set a positive maximum)"
                            )
                        elif c_max is not None and c_max < need_max_sess:
                            ri = (
                                realm_idle_sso
                                if realm_idle_sso is not None
                                else "n/a (realm unreadable)"
                            )
                            msgs["refresh"] = (
                                f"client.session.max.lifespan is {c_max}s when explicitly set; "
                                f"need >= {need_max_sess}s (max(28800s, realm ssoSessionIdleTimeout={ri}))"
                            )
                        elif c_max is not None and c_idle is not None and c_max < c_idle:
                            msgs["refresh"] = (
                                "client.session.max.lifespan is below client.session.idle.timeout; "
                                "client session overrides must satisfy max >= idle"
                            )
                        elif err_offline_idle:
                            msgs["refresh"] = err_offline_idle
                        elif c_offline_idle is not None and c_offline_idle < 28800:
                            msgs["refresh"] = (
                                f"client.offline.session.idle.timeout is {c_offline_idle}s when explicitly set; "
                                "need >= 28800s for overnight refresh continuity"
                            )
                        else:
                            state["refresh_ok"] = True
                            if state["session_idle_ok"]:
                                msgs["refresh"] = (
                                    "Overnight OAuth refresh path OK: realm SSO + accessTokenLifespan usable, "
                                    "standardFlow + refresh flags + client session overrides not broken"
                                )
                            else:
                                msgs["refresh"] = (
                                    "OnCall OAuth client refresh settings OK (standardFlow, refresh tokens, "
                                    "reuse, client session attrs); realm SSO limits scored separately "
                                    "under keycloak_session_idle"
                                )
        else:
            msgs["session_idle"] = token_fail
            msgs["redirect"] = token_fail
            msgs["refresh"] = token_fail

        auth_pf: list[str] = []
        if _KC_ADMIN_PF_BASE:
            auth_pf.append(_KC_ADMIN_PF_BASE)
        authorize_ok, auth_detail = _kc_probe_authorize_e2e(ns, pod, base, auth_pf)

        state["authorize_ok"] = authorize_ok
        if authorize_ok:
            msgs["authorize"] = (
                "Authorize flow OK for deployed /complete/grafana-oauth/ callback "
                f"({auth_detail})"
            )
        else:
            msgs["authorize"] = "deployed callback did not reach expected Keycloak login/re-auth flow"

        _kc_oauth_inspect_cache = state
        return state
    except Exception as e:
        err = f"Keycloak inspect exception: {e}"
        for k in msgs:
            if not msgs[k]:
                msgs[k] = err
        _kc_oauth_inspect_cache = state
        return state


def _kc_session_idle_admin_password() -> list[str]:
    """
    Discover Keycloak admin password candidates from the keycloak namespace per design §5.1 step 1.
    Tries secret names ['keycloak-db-secret', 'keycloak-credentials', 'keycloak'] in order,
    each with keys ['admin-password', 'KC_BOOTSTRAP_ADMIN_PASSWORD', 'admin_password', 'password'].
    Always appends 'admin123' (snapshot baseline) as the last fallback.
    """
    found: list[str] = []
    for sec_name in ("keycloak-db-secret", "keycloak-credentials", "keycloak"):
        data = kubectl_json(f"get secret {shlex.quote(sec_name)} -n keycloak")
        if not data:
            continue
        sec_data = (data.get("data") or {})
        for key in ("admin-password", "KC_BOOTSTRAP_ADMIN_PASSWORD", "admin_password", "password"):
            v = sec_data.get(key)
            if not v:
                continue
            try:
                raw = base64.b64decode(v).decode("utf-8", errors="replace").strip()
            except Exception:
                continue
            if raw and raw not in found:
                found.append(raw)
    if "admin123" not in found:
        found.append("admin123")
    return found


def _kc_session_idle_jwt_decode(token: str) -> dict[str, Any]:
    """Parse a JWT payload without verifying. Returns {} on parse error."""
    try:
        parts = token.split(".")
        if len(parts) < 2:
            return {}
        payload_b64 = parts[1]
        # urlsafe b64 with optional padding
        padded = payload_b64 + "=" * (-len(payload_b64) % 4)
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        return json.loads(raw.decode("utf-8", errors="replace"))
    except Exception:
        return {}


def check_keycloak_session_idle() -> Tuple[bool, str]:
    """
    Behavioral probe per HARDENING-DESIGN §5.1.

    8-step Direct-Grant + introspect + JWT-decode + sleep round-trip:
      1. Discover Keycloak admin password from cluster secrets.
      2. Acquire admin Bearer token via port-forward (sets _KC_ADMIN_PF_BASE).
      3. GET /admin/realms/devops/clients?clientId=oncall -> client UUID.
         GET /admin/realms/devops/clients/{cid}/client-secret -> client_secret.
      4. POST /realms/devops/protocol/openid-connect/token (password grant)
         using responder/responder123 -> access_token + refresh_token.
      5. POST /realms/devops/protocol/openid-connect/token/introspect
         -> {"active": true, "exp": <int>}.
      6. JWT-decode access_token; assert exp-iat >= 1800 seconds.
      7. JWT 'aud' claim must contain 'oncall' (audience mapper wired).
      8. time.sleep(25); re-introspect access_token; must still be active.

    No cascade: this function does not call any other check_* function.
    """
    try:
        # --- Step 1: discover admin password candidates -----------------------
        candidates = _kc_session_idle_admin_password()
        if not candidates:
            return False, "FAIL keycloak_session_idle: no admin password candidates discovered"

        # --- Step 2: obtain admin token (port-forward path) ------------------
        ns = "keycloak"
        users = ("admin", "keycloak", "user")
        admin_token = _kc_admin_token_via_portforward(ns, users, candidates)
        if not admin_token:
            # Fall back to the broader strategy (cluster-IP + pod exec).
            admin_token = obtain_keycloak_admin_token(None)
        if not admin_token:
            return (
                False,
                "FAIL keycloak_session_idle: could not acquire Keycloak admin token "
                "(port-forward + cluster + pod-exec all failed)",
            )

        # Resolve a base URL for realm endpoints. Prefer the active port-forward
        # since we know its admin token already worked there.
        base_url: Optional[str] = _KC_ADMIN_PF_BASE
        if not base_url:
            internal = _keycloak_internal_http_base(ns)
            cluster_urls = discover_keycloak_base_urls(ns)
            base_url = internal or (cluster_urls[0] if cluster_urls else None)
        if not base_url:
            return False, "FAIL keycloak_session_idle: no Keycloak base URL discoverable"
        base = base_url.rstrip("/")

        admin_headers = _kc_keycloak_admin_request_headers(base, admin_token)
        insecure = base.startswith("https://")

        # --- Step 3: discover OnCall client UUID + secret ---------------------
        list_url = f"{base}/admin/realms/devops/clients?clientId=oncall"
        code, body = http_json(list_url, headers=admin_headers, insecure_https=insecure)
        if code != 200 or not isinstance(body, list) or not body:
            snippet = json.dumps(body) if isinstance(body, (dict, list)) else str(body)[:200]
            return (
                False,
                f"FAIL keycloak_session_idle: list oncall client failed: HTTP {code} {snippet}",
            )
        cid = (body[0] or {}).get("id") or ""
        if not cid:
            return False, "FAIL keycloak_session_idle: oncall client lookup returned no id"

        secret_url = f"{base}/admin/realms/devops/clients/{cid}/client-secret"
        code, body = http_json(secret_url, headers=admin_headers, insecure_https=insecure)
        if code != 200 or not isinstance(body, dict):
            snippet = json.dumps(body) if isinstance(body, (dict, list)) else str(body)[:200]
            return (
                False,
                f"FAIL keycloak_session_idle: get client-secret failed: HTTP {code} {snippet}",
            )
        client_secret = str(body.get("value") or "")
        if not client_secret:
            return False, "FAIL keycloak_session_idle: oncall client_secret value is empty"

        # --- Step 4: password grant -> access_token + refresh_token -----------
        token_url = f"{base}/realms/devops/protocol/openid-connect/token"
        token_form = urllib.parse.urlencode(
            {
                "grant_type": "password",
                "client_id": "oncall",
                "client_secret": client_secret,
                "username": "responder",
                "password": "responder123",
                "scope": "openid",
            }
        ).encode("ascii")
        token_headers = {"Content-Type": "application/x-www-form-urlencoded"}
        code, body = http_json(
            token_url,
            method="POST",
            headers=token_headers,
            data=token_form,
            insecure_https=insecure,
        )
        if code != 200 or not isinstance(body, dict):
            snippet = json.dumps(body) if isinstance(body, (dict, list)) else str(body)[:200]
            return (
                False,
                f"FAIL keycloak_session_idle: token mint failed: HTTP {code} {snippet}",
            )
        access_token = str(body.get("access_token") or "")
        refresh_token = str(body.get("refresh_token") or "")
        if not access_token or not refresh_token:
            return (
                False,
                "FAIL keycloak_session_idle: token mint response missing access_token "
                "and/or refresh_token (check directAccessGrantsEnabled + use.refresh.tokens)",
            )

        # --- Step 5: introspect immediately after mint ------------------------
        introspect_url = (
            f"{base}/realms/devops/protocol/openid-connect/token/introspect"
        )

        def _introspect(tok: str) -> Tuple[int, Any]:
            form = urllib.parse.urlencode(
                {
                    "token": tok,
                    "client_id": "oncall",
                    "client_secret": client_secret,
                }
            ).encode("ascii")
            return http_json(
                introspect_url,
                method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                data=form,
                insecure_https=insecure,
            )

        code, body = _introspect(access_token)
        if code != 200 or not isinstance(body, dict) or not body.get("active"):
            snippet = json.dumps(body) if isinstance(body, (dict, list)) else str(body)[:200]
            return (
                False,
                f"FAIL keycloak_session_idle: introspect immediately after mint returned "
                f"active=false (HTTP {code} {snippet})",
            )

        # --- Step 6: JWT decode + lifetime assertion --------------------------
        claims = _kc_session_idle_jwt_decode(access_token)
        if not claims:
            return (
                False,
                "FAIL keycloak_session_idle: failed to decode access_token JWT payload",
            )
        try:
            iat = int(claims.get("iat"))
            exp = int(claims.get("exp"))
        except (TypeError, ValueError):
            return (
                False,
                "FAIL keycloak_session_idle: access_token missing/invalid iat or exp claims",
            )
        lifetime = exp - iat
        if lifetime < 1800:
            return (
                False,
                f"FAIL keycloak_session_idle: access_token exp-iat={lifetime}s < required "
                f"1800s (check accessTokenLifespan)",
            )

        # --- Step 7: aud claim must include 'oncall' --------------------------
        aud_raw = claims.get("aud")
        if isinstance(aud_raw, str):
            aud_list = [aud_raw]
        elif isinstance(aud_raw, list):
            aud_list = [str(a) for a in aud_raw]
        else:
            aud_list = []
        if "oncall" not in aud_list:
            return (
                False,
                "FAIL keycloak_session_idle: aud claim missing 'oncall' "
                f"(got {aud_list!r}; check audience mapper)",
            )

        # --- Step 8: sleep 25s + re-introspect same access_token --------------
        time.sleep(25)
        code, body = _introspect(access_token)
        if code != 200 or not isinstance(body, dict) or not body.get("active"):
            snippet = json.dumps(body) if isinstance(body, (dict, list)) else str(body)[:200]
            return (
                False,
                "FAIL keycloak_session_idle: access_token expired during 25s window "
                f"(check ssoSessionIdleTimeout / refresh policy; HTTP {code} {snippet})",
            )

        return (
            True,
            f"PASS keycloak_session_idle: token mint OK, exp-iat={lifetime}s, "
            "aud has oncall, still active after 25s",
        )
    except Exception as e:
        return False, f"FAIL keycloak_session_idle: exception: {e!r}"


def _oncall_engine_name_score(svc_name: str) -> int:
    nl = svc_name.lower()
    if "engine" in nl:
        return 3
    if "grafana-oncall" in nl:
        return 2
    if "oncall" in nl:
        return 1
    return 0


def _first_pod_http_port(pod: dict) -> int:
    for c in (pod.get("spec") or {}).get("containers") or []:
        for p in c.get("ports") or []:
            cport = p.get("containerPort")
            if not cport:
                continue
            cport_i = int(cport)
            pname = (p.get("name") or "").lower()
            if pname in ("http", "https", "http-web") or cport_i in (8080, 8000, 3000):
                return cport_i
        for p in c.get("ports") or []:
            if p.get("containerPort"):
                return int(p["containerPort"])
    return 8080


def discover_oncall_service_url() -> Optional[str]:
    """HTTP base for OnCall integration/public probes: ClusterIP, headless Endpoints, or engine pod IP."""
    ns = discover_oncall_namespace()
    if not ns:
        return None
    data = kubectl_json(f"get svc -n {ns}")
    best: Optional[tuple[int, str]] = None

    def consider(score: int, url: str) -> None:
        nonlocal best
        if best is None or score > best[0]:
            best = (score, url)

    if data and "items" in data:
        for svc in data["items"]:
            meta = svc.get("metadata") or {}
            name = str(meta.get("name") or "")
            sc = _oncall_engine_name_score(name)
            if sc <= 0:
                continue
            spec = svc.get("spec") or {}
            port = 8080
            for p in spec.get("ports") or []:
                port = int(p.get("port") or 8080)
                break
            ip = spec.get("clusterIP")
            if ip and ip != "None":
                consider(sc, f"http://{ip}:{port}")
                continue
            ep = kubectl_json(f"get endpoints {name} -n {ns}")
            for sub in (ep or {}).get("subsets") or []:
                addrs = sub.get("addresses") or []
                sub_ports = sub.get("ports") or []
                for addr in addrs:
                    pip = (addr.get("ip") or "").strip()
                    if not pip:
                        continue
                    if not sub_ports:
                        consider(sc, f"http://{pip}:{port}")
                        continue
                    for pp in sub_ports:
                        pnum = int(pp.get("port") or port)
                        consider(sc, f"http://{pip}:{pnum}")

    if best is None:
        pods = kubectl_json(f"get pods -n {ns}")
        for pod in (pods or {}).get("items") or []:
            if (pod.get("status") or {}).get("phase") != "Running":
                continue
            pip = (pod.get("status") or {}).get("podIP") or ""
            if not pip:
                continue
            pname = ((pod.get("metadata") or {}).get("name") or "").lower()
            labels = (pod.get("metadata") or {}).get("labels") or {}
            comp = (labels.get("app.kubernetes.io/component") or "").lower()
            if "celery" in pname or "redis" in pname or "rabbit" in pname:
                continue
            if "postgresql" in pname or "postgres" in pname:
                continue
            looks_engine = "engine" in pname or comp == "engine"
            if not looks_engine:
                continue
            pport = _first_pod_http_port(pod)
            consider(3, f"http://{pip}:{pport}")

    return best[1] if best else None


def _paths_list_from_rule(rule: dict) -> list[str]:
    """Collect HTTP paths from all `to.operation` blocks in a rule."""
    out: list[str] = []
    for op in rule.get("to") or []:
        paths = (op.get("operation") or {}).get("paths") or []
        for p in paths:
            if isinstance(p, str):
                out.append(p)
    return out


def restrictive_oncall_auth_policy_present() -> bool:
    """True while the task AuthorizationPolicy still DENYs unauthenticated traffic it should not."""
    ns = discover_oncall_namespace()
    if not ns:
        return False
    data = kubectl_json(f"get authorizationpolicy -n {ns}")
    if not data or "items" not in data:
        return False
    for pol in data["items"]:
        meta = pol.get("metadata") or {}
        if meta.get("name") != "task-oncall-require-jwt-everywhere":
            continue
        spec = pol.get("spec") or {}
        if spec.get("action") != "DENY":
            continue
        for rule in spec.get("rules") or []:
            from_entries = rule.get("from") or []
            if not from_entries:
                continue
            has_anon_deny = False
            for fr in from_entries:
                src = (fr or {}).get("source") or {}
                if src.get("notRequestPrincipals") == ["*"]:
                    has_anon_deny = True
                    break
            if not has_anon_deny:
                continue
            paths = _paths_list_from_rule(rule)
            if not paths:
                to = (rule.get("to") or [{}])[0].get("operation") or {}
                paths = to.get("paths") or []
            joined = " ".join(paths)
            if paths == ["/*"] or "/*" in joined:
                return True
            if "/oncall/integrations" in joined and "/oncall/public-api" in joined:
                return True
    return False


def _deny_anonymous_oncall_mesh_paths(ns: str) -> Optional[str]:
    """True if DENY can hit anonymous requests on integration/public-api or catch-all paths.

    Catches renamed clones of the task policy, including realistic DENY policies that
    scope only by ``to.operation.paths`` (no ``from`` => all sources, including anonymous).
    """
    data = kubectl_json(f"get authorizationpolicy -n {shlex.quote(ns)}")
    if not data:
        return None
    for pol in data.get("items") or []:
        meta = pol.get("metadata") or {}
        pname = str(meta.get("name") or "")
        spec = pol.get("spec") or {}
        if spec.get("action") != "DENY":
            continue
        for rule in spec.get("rules") or []:
            from_list = rule.get("from") or []
            applies_to_anonymous = False
            if not from_list:
                # Istio semantics: omitted `from` means all sources.
                applies_to_anonymous = True
            else:
                for fr in from_list:
                    src = (fr or {}).get("source") or {}
                    if src.get("notRequestPrincipals") == ["*"]:
                        applies_to_anonymous = True
                        break
            if not applies_to_anonymous:
                continue
            paths = _paths_list_from_rule(rule)
            if not paths:
                to = (rule.get("to") or [{}])[0].get("operation") or {}
                paths = [str(x) for x in (to.get("paths") or []) if isinstance(x, str)]
            for raw in paths:
                pl = str(raw).lower()
                if (
                    pl == "/*"
                    or "/oncall/integrations" in pl
                    or "/oncall/public-api" in pl
                    or "/integrations/" in pl
                    or "/public-api/" in pl
                ):
                    return (
                        f"AuthorizationPolicy/{pname} DENYs traffic to {raw!r} "
                        "(remove or narrow DENY rules on integration/public-api mesh paths)"
                    )
    return None


def _is_public_oncall_path(path: str) -> bool:
    p = str(path or "").lower()
    return (
        p == "/*"
        or "/integrations" in p
        or "/public-api" in p
        or "/oncall/integrations" in p
        or "/oncall/public-api" in p
    )


def _allow_authenticated_only_oncall_mesh_paths(ns: str) -> Optional[str]:
    data = kubectl_json(f"get authorizationpolicy -n {shlex.quote(ns)}")
    if not data:
        return None

    for pol in data.get("items") or []:
        meta = pol.get("metadata") or {}
        pname = str(meta.get("name") or "")
        spec = pol.get("spec") or {}

        if spec.get("action") != "ALLOW":
            continue

        for rule in spec.get("rules") or []:
            requires_jwt = any(
                ((fr or {}).get("source") or {}).get("requestPrincipals")
                for fr in (rule.get("from") or [])
            )
            if not requires_jwt:
                continue

            paths = _paths_list_from_rule(rule) or ["/*"]
            if any(_is_public_oncall_path(p) for p in paths):
                return (
                    f"AuthorizationPolicy/{pname} ALLOWs only authenticated requestPrincipals "
                    "on public integration/public-api callback paths; anonymous incident callbacks must be reachable"
                )

    return None


def _istio_coerce_probe_http_status(raw: str) -> str:
    """Normalize in-pod probe stdout: ``curl`` emits ``404``; ``wget -S`` may emit ``HTTP/1.1 404 …``."""
    t = (raw or "").strip()
    if not t:
        return ""
    last = t.splitlines()[-1].strip()
    if last.isdigit() and len(last) == 3:
        return last
    m = re.match(r"^HTTP/\d(?:\.\d)?\s+(\d{3})\b", last, re.IGNORECASE)
    if m:
        return m.group(1)
    m2 = re.search(r"\b(\d{3})\b", last)
    if m2:
        return m2.group(1)
    return last


def _first_container_name(ns: str, deploy_name: str) -> str:
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return ""
    containers = (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    )
    if not containers:
        return ""
    return str(containers[0].get("name") or "").strip()


def _deploy_workload_container_names(ns: str, deploy_name: str) -> list[str]:
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return []
    out: list[str] = []
    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        n = str(c.get("name") or "").strip()
        if n:
            out.append(n)
    return out


def _first_running_pod_for_deploy(ns: str, deploy_name: str) -> str:
    """Newest Ready non-terminating pod matching a Deployment selector."""
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return ""

    match = ((dep.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
    if not match:
        return ""

    label_sel = ",".join(f"{k}={v}" for k, v in sorted(match.items()))
    data = kubectl_json(f"get pods -n {shlex.quote(ns)} -l {shlex.quote(label_sel)}")
    if not data:
        return ""

    candidates: list[tuple[str, str]] = []
    for pod in data.get("items") or []:
        meta = pod.get("metadata") or {}
        status = pod.get("status") or {}

        if meta.get("deletionTimestamp") is not None:
            continue
        if status.get("phase") != "Running":
            continue

        ready = any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in (status.get("conditions") or [])
        )
        if not ready:
            continue

        name = str(meta.get("name") or "").strip()
        created = str(meta.get("creationTimestamp") or "")
        if name:
            candidates.append((created, name))

    candidates.sort(reverse=True)
    return candidates[0][1] if candidates else ""


def _pod_printenv(ns: str, pod: str, container: str, var: str) -> str:
    qns, qp, qv = shlex.quote(ns), shlex.quote(pod), shlex.quote(var)
    cflag = f"-c {shlex.quote(container)} " if container.strip() else ""
    rc, out, _ = run_cmd(
        f"kubectl exec -n {qns} {qp} {cflag}-- printenv {qv} 2>/dev/null",
        timeout=45,
    )
    return out.strip() if rc == 0 else ""


def _pod_grafana_key_pair(ns: str, pod: str, deploy_name: str) -> Tuple[str, str, str]:
    """First deployment container where running pod exposes both GRAFANA_* keys."""
    for ctr in _deploy_workload_container_names(ns, deploy_name):
        api = _pod_printenv(ns, pod, ctr, "GRAFANA_API_KEY")
        alt = _pod_printenv(ns, pod, ctr, "GRAFANA_TOKEN")
        if api.strip() and alt.strip():
            return ctr, api, alt
    ctr = _first_container_name(ns, deploy_name)
    if ctr:
        api = _pod_printenv(ns, pod, ctr, "GRAFANA_API_KEY")
        alt = _pod_printenv(ns, pod, ctr, "GRAFANA_TOKEN")
        if api.strip() and alt.strip():
            return ctr, api, alt
    return "", "", ""


def _ttl_parse_plain_int(raw: str) -> Optional[int]:
    t = str(raw or "").strip()
    if not t or not re.fullmatch(r"-?\d+", t):
        return None
    try:
        return int(t)
    except ValueError:
        return None


def _ttl_int_from_cm_data(cm: dict, key: str) -> Optional[int]:
    val = str(((cm.get("data") or {}).get(key) or "")).strip()
    return _ttl_parse_plain_int(val)


def _ttl_env_wiring_disallowed_reason(dep_name: str, dep: dict) -> Optional[str]:
    """Return failure reason when TTL vars are wired via inline env.value."""
    if not _REQUIRE_TTL_CONFIGMAP_ONLY:
        return None
    containers = (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    )
    for c in containers:
        cname = str(c.get("name") or "").strip() or "<unnamed>"
        for env in c.get("env") or []:
            en = str(env.get("name") or "")
            if en not in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
                continue
            if env.get("value") is not None:
                return (
                    f"{dep_name} container {cname!r}: {en} uses inline env.value; "
                    "TTL vars must come from ConfigMap-backed valueFrom/envFrom sources"
                )
    return None


def _ttl_effective_for_deploy(ns: str, deploy_name: str) -> Tuple[Optional[int], Optional[int]]:
    """Resolve effective ACK/PUB TTL mins from env/valueFrom/envFrom sources."""
    data = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not data:
        return None, None

    ack: Optional[int] = None
    pub: Optional[int] = None

    def take_ack(v: Optional[int]) -> None:
        nonlocal ack
        if v is not None:
            ack = v if ack is None else min(ack, v)

    def take_pub(v: Optional[int]) -> None:
        nonlocal pub
        if v is not None:
            pub = v if pub is None else min(pub, v)

    containers = (
        (data.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    )
    qns = shlex.quote(ns)
    for c in containers:
        for env in c.get("env") or []:
            en = str(env.get("name") or "")
            if en not in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
                continue
            if env.get("value") is not None:
                iv = _ttl_parse_plain_int(str(env.get("value") or ""))
                if en == _ONCALL_TTL_ACK:
                    take_ack(iv)
                else:
                    take_pub(iv)
                continue
            cmkr = (env.get("valueFrom") or {}).get("configMapKeyRef") or {}
            cmn = str(cmkr.get("name") or "").strip()
            if not cmn:
                continue
            key = str(cmkr.get("key") or en).strip() or en
            cm = kubectl_json(f"get cm/{shlex.quote(cmn)} -n {qns}")
            if not cm:
                continue
            iv = _ttl_int_from_cm_data(cm, key)
            if en == _ONCALL_TTL_ACK:
                take_ack(iv)
            else:
                take_pub(iv)
        for ef in c.get("envFrom") or []:
            cmn = str(((ef.get("configMapRef") or {}).get("name")) or "").strip()
            if not cmn:
                continue

            if deploy_name == "oncall-engine" and cmn in _ENGINE_TTL_DIAGNOSTIC_CMS:
                continue

            cm = kubectl_json(f"get cm/{shlex.quote(cmn)} -n {qns}")
            if not cm:
                continue
            take_ack(_ttl_int_from_cm_data(cm, _ONCALL_TTL_ACK))
            take_pub(_ttl_int_from_cm_data(cm, _ONCALL_TTL_PUB))

    return ack, pub


def _ttl_referenced_configmap_state_for_deploy(ns: str, deploy_name: str) -> Tuple[bool, str]:
    """
    Referenced TTL ConfigMaps must use exact target values.
    Only ConfigMaps referenced by deployment envFrom/configMapKeyRef are checked.
    """
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return False, f"Deployment {deploy_name} not found in namespace {ns}"
    refs: list[str] = []
    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        for ef in c.get("envFrom") or []:
            cmn = str(((ef.get("configMapRef") or {}).get("name")) or "").strip()
            if cmn and cmn not in refs:
                refs.append(cmn)
        for env in c.get("env") or []:
            en = str(env.get("name") or "")
            if en not in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
                continue
            cmkr = (env.get("valueFrom") or {}).get("configMapKeyRef") or {}
            cmn = str(cmkr.get("name") or "").strip()
            if cmn and cmn not in refs:
                refs.append(cmn)

    problems: list[str] = []
    for cmn in refs:
        if deploy_name == "oncall-engine" and cmn in _ENGINE_TTL_DIAGNOSTIC_CMS:
            continue

        cm = kubectl_json(f"get cm/{shlex.quote(cmn)} -n {shlex.quote(ns)}")
        if not cm:
            return False, f"{deploy_name}: referenced ConfigMap {cmn} not found"
        data = cm.get("data") or {}
        for key in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
            if key not in data:
                continue
            val = _ttl_parse_plain_int(str(data.get(key) or ""))
            if val is None:
                problems.append(f"{cmn}.{key}=<non-integer>; need exactly {_ONCALL_TTL_TARGET_SEC}")
            elif val != _ONCALL_TTL_TARGET_SEC:
                problems.append(f"{cmn}.{key}={val}; need exactly {_ONCALL_TTL_TARGET_SEC}")
    if problems:
        return False, f"{deploy_name}: " + " | ".join(problems)
    return True, f"{deploy_name} referenced TTL ConfigMaps resolve exactly to {_ONCALL_TTL_TARGET_SEC}"


def _ttl_source_normalized_for_deploy(ns: str, dep_name: str, dep: dict) -> Tuple[bool, str]:
    approved_cm = _APPROVED_TTL_CM_BY_DEPLOY.get(dep_name)
    if not approved_cm:
        return False, f"{dep_name}: no approved TTL ConfigMap mapping"

    found_keys = set()
    stale_refs: list[str] = []

    containers = (
        ((dep.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers")
        or []
    )

    for c in containers:
        # Valid style 1: explicit env[].valueFrom.configMapKeyRef
        for env in c.get("env") or []:
            name = str(env.get("name") or "")
            if name not in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
                continue

            if "value" in env:
                return False, f"{dep_name}: {name} uses inline env.value; must use ConfigMap-backed source"

            cmkr = (env.get("valueFrom") or {}).get("configMapKeyRef") or {}
            cm_name = str(cmkr.get("name") or "")
            cm_key = str(cmkr.get("key") or "")

            if cm_name != approved_cm or cm_key != name:
                return (
                    False,
                    f"{dep_name}: {name} must come from approved ConfigMap {approved_cm}/{name}; "
                    f"observed {cm_name}/{cm_key}",
                )

            found_keys.add(name)

        # Valid style 2: envFrom.configMapRef to approved ConfigMap
        for ef in c.get("envFrom") or []:
            cm_name = str(((ef.get("configMapRef") or {}).get("name")) or "").strip()
            if not cm_name:
                continue

            cm = kubectl_json(f"get cm/{shlex.quote(cm_name)} -n {shlex.quote(ns)}")
            if not cm:
                return False, f"{dep_name}: referenced ConfigMap {cm_name} not found"

            data = cm.get("data") or {}

            if dep_name == "oncall-engine" and cm_name in _ENGINE_TTL_DIAGNOSTIC_CMS:
                continue

            if cm_name == approved_cm:
                for key in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
                    if key in data:
                        val = _ttl_parse_plain_int(str(data.get(key) or ""))
                        if val != _ONCALL_TTL_TARGET_SEC:
                            return (
                                False,
                                f"{dep_name}: approved ConfigMap {approved_cm}.{key}={val}; "
                                f"need exactly {_ONCALL_TTL_TARGET_SEC}",
                            )
                        found_keys.add(key)
                continue

            if _ONCALL_TTL_ACK in data or _ONCALL_TTL_PUB in data:
                stale_refs.append(cm_name)

    missing = {_ONCALL_TTL_ACK, _ONCALL_TTL_PUB} - found_keys
    if missing:
        return False, f"{dep_name}: missing approved ConfigMap-backed TTL sources: {sorted(missing)}"

    if stale_refs:
        return (
            False,
            f"{dep_name}: stale active TTL ConfigMaps still define TTL keys: {sorted(set(stale_refs))}",
        )

    cm = kubectl_json(f"get cm/{shlex.quote(approved_cm)} -n {shlex.quote(ns)}")
    if not cm:
        return False, f"{dep_name}: approved TTL ConfigMap {approved_cm} not found"

    data = cm.get("data") or {}
    for key in (_ONCALL_TTL_ACK, _ONCALL_TTL_PUB):
        val = _ttl_parse_plain_int(str(data.get(key) or ""))
        if val != _ONCALL_TTL_TARGET_SEC:
            return False, f"{dep_name}: {approved_cm}.{key}={val}; need exactly {_ONCALL_TTL_TARGET_SEC}"

    return True, f"{dep_name}: TTL source normalized to approved ConfigMap {approved_cm}"


def _oncall_token_ttl_for_deploy(ns: str, dep_name: str) -> Tuple[bool, str]:
    """ACK/public TTL must equal exact target for one deployment in spec and runtime env."""
    dep = kubectl_json(f"get deploy/{shlex.quote(dep_name)} -n {shlex.quote(ns)}")
    if not dep:
        return False, f"Deployment {dep_name} not found in namespace {ns}"
    bad_shape = _ttl_env_wiring_disallowed_reason(dep_name, dep)
    if bad_shape:
        return False, bad_shape
    ok_norm, msg_norm = _ttl_source_normalized_for_deploy(ns, dep_name, dep)
    if not ok_norm:
        return False, msg_norm
    _wait_deploy_rollout(ns, dep_name)

    ack, pub = _ttl_effective_for_deploy(ns, dep_name)
    if ack is None or pub is None:
        return (
            False,
            f"{dep_name}: need both {_ONCALL_TTL_ACK} and {_ONCALL_TTL_PUB} in effective deployment config",
        )
    if ack != _ONCALL_TTL_TARGET_SEC or pub != _ONCALL_TTL_TARGET_SEC:
        return (
            False,
            f"{dep_name}: effective TTLs must be exactly {_ONCALL_TTL_TARGET_SEC}s "
            f"(observed {_ONCALL_TTL_ACK}={ack}, {_ONCALL_TTL_PUB}={pub})",
        )
    ok_refs, msg_refs = _ttl_referenced_configmap_state_for_deploy(ns, dep_name)
    if not ok_refs:
        return False, msg_refs

    rpod = _first_running_pod_for_deploy(ns, dep_name)
    if not rpod:
        return False, f"{dep_name}: no Running pod for deployment selector"

    ctr_names = _deploy_workload_container_names(ns, dep_name)
    if not ctr_names:
        fc = _first_container_name(ns, dep_name)
        ctr_names = [fc] if fc else []

    checked = False
    last_ack: Optional[int] = None
    last_pub: Optional[int] = None
    for ctr in ctr_names:
        ctn = str(ctr).strip()
        if not ctn:
            continue
        rack = _pod_printenv(ns, rpod, ctn, _ONCALL_TTL_ACK)
        rpub = _pod_printenv(ns, rpod, ctn, _ONCALL_TTL_PUB)
        if not rack.strip() and not rpub.strip():
            continue
        checked = True
        ri_ack = _ttl_parse_plain_int(rack)
        ri_pub = _ttl_parse_plain_int(rpub)
        last_ack, last_pub = ri_ack, ri_pub
        if ri_ack is None or ri_pub is None:
            return (
                False,
                f"{dep_name}: container {ctn!r} on pod {rpod} has non-integer runtime TTL(s) "
                f"(ack={rack!r}, pub={rpub!r})",
            )
        if ri_ack != _ONCALL_TTL_TARGET_SEC or ri_pub != _ONCALL_TTL_TARGET_SEC:
            return (
                False,
                f"{dep_name}: runtime TTL must be exactly {_ONCALL_TTL_TARGET_SEC} in container {ctn!r} on pod {rpod} "
                f"({_ONCALL_TTL_ACK}={ri_ack}, {_ONCALL_TTL_PUB}={ri_pub})",
            )

    if not checked:
        ctr = _first_container_name(ns, dep_name)
        rack = _pod_printenv(ns, rpod, ctr, _ONCALL_TTL_ACK)
        rpub = _pod_printenv(ns, rpod, ctr, _ONCALL_TTL_PUB)
        ri_ack = _ttl_parse_plain_int(rack)
        ri_pub = _ttl_parse_plain_int(rpub)
        if ri_ack is None or ri_pub is None:
            return (
                False,
                f"{dep_name}: running pod {rpod} missing runtime {_ONCALL_TTL_ACK}/{_ONCALL_TTL_PUB}",
            )
        if ri_ack != _ONCALL_TTL_TARGET_SEC or ri_pub != _ONCALL_TTL_TARGET_SEC:
            return (
                False,
                f"{dep_name}: runtime TTL must be exactly {_ONCALL_TTL_TARGET_SEC} on pod {rpod} "
                f"({_ONCALL_TTL_ACK}={ri_ack}, {_ONCALL_TTL_PUB}={ri_pub})",
            )
        last_ack, last_pub = ri_ack, ri_pub

    return (
        True,
        f"{dep_name} spec+runtime {_ONCALL_TTL_ACK}={ack}s/{last_ack}s {_ONCALL_TTL_PUB}={pub}s/{last_pub}s",
    )


def discover_grafana_base() -> Optional[str]:
    data = kubectl_json(f"get svc -n {GRAFANA_NS}")
    if not data:
        return None
    for svc in sorted(
        data.get("items") or [],
        key=lambda s: str((s.get("metadata") or {}).get("name") or ""),
    ):
        name = (svc.get("metadata") or {}).get("name", "")
        if "grafana" not in name.lower():
            continue
        ip = (svc.get("spec") or {}).get("clusterIP")
        if not ip or ip == "None":
            continue
        port = 3000
        for p in (svc.get("spec") or {}).get("ports") or []:
            port = int(p.get("port") or 3000)
            break
        return f"http://{ip}:{port}"
    return None


def _oncall_engine_deploy_name(ns: str) -> str:
    data = kubectl_json(f"get deploy -n {shlex.quote(ns)}")
    if not data:
        return "oncall-engine"
    for dep in data.get("items") or []:
        n = str((dep.get("metadata") or {}).get("name") or "")
        if n == "oncall-engine":
            return n
        low = n.lower()
        if "oncall" in low and "engine" in low:
            return n
    return "oncall-engine"


def _secret_data_key_b64(ns: str, secret_name: str, data_key: str) -> str:
    sec = kubectl_json(f"get secret/{shlex.quote(secret_name)} -n {shlex.quote(ns)}")
    if not sec:
        return ""
    raw = (sec.get("data") or {}).get(data_key)
    return str(raw or "").strip()


def _engine_wired_grafana_token(ns: str) -> Tuple[str, str, str]:
    """Resolve (deploy_name, provenance, token) from the oncall-engine Deployment only."""
    dname = _oncall_engine_deploy_name(ns)
    src, tok = _deploy_wired_grafana_token(ns, dname)
    return dname, src, tok


def _grafana_src_is_literal(src: str) -> bool:
    s = (src or "").lower()
    return "(literal)" in s or "literal" in s


def _deploy_wired_grafana_token(ns: str, dname: str) -> Tuple[str, str]:
    """Resolve (provenance, token) from one Deployment (literal or secretRef env)."""
    data = kubectl_json(f"get deploy/{shlex.quote(dname)} -n {shlex.quote(ns)}")
    if not data:
        return "", ""
    last_api = ""
    last_api_src = ""
    last_alt = ""
    last_alt_src = ""
    containers = (
        (data.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    )
    for c in containers:
        for env in c.get("env") or []:
            en = str(env.get("name") or "")
            if en == "GRAFANA_API_KEY":
                if env.get("value") is not None:
                    last_api = str(env.get("value") or "").strip()
                    last_api_src = f"{dname} GRAFANA_API_KEY (literal)"
                else:
                    ref = (env.get("valueFrom") or {}).get("secretKeyRef") or {}
                    sn, sk = ref.get("name"), ref.get("key")
                    if sn and sk:
                        b64 = _secret_data_key_b64(ns, str(sn), str(sk))
                        if b64:
                            try:
                                last_api = base64.b64decode(b64).decode(
                                    "utf-8", errors="replace"
                                ).strip()
                            except Exception:
                                last_api = ""
                            if last_api:
                                last_api_src = (
                                    f"{dname} GRAFANA_API_KEY -> Secret/{sn} key={sk}"
                                )
            elif en == "GRAFANA_TOKEN":
                if env.get("value") is not None:
                    last_alt = str(env.get("value") or "").strip()
                    last_alt_src = f"{dname} GRAFANA_TOKEN (literal)"
                else:
                    ref = (env.get("valueFrom") or {}).get("secretKeyRef") or {}
                    sn, sk = ref.get("name"), ref.get("key")
                    if sn and sk:
                        b64 = _secret_data_key_b64(ns, str(sn), str(sk))
                        if b64:
                            try:
                                last_alt = base64.b64decode(b64).decode(
                                    "utf-8", errors="replace"
                                ).strip()
                            except Exception:
                                last_alt = ""
                            if last_alt:
                                last_alt_src = (
                                    f"{dname} GRAFANA_TOKEN -> Secret/{sn} key={sk}"
                                )
    if last_api:
        return last_api_src, last_api
    if last_alt:
        return last_alt_src, last_alt

    approved = _APPROVED_GRAFANA_SECRET_BY_DEPLOY.get(dname, "")
    if approved:
        for c in containers:
            for ef in c.get("envFrom") or []:
                sec_name = str(((ef.get("secretRef") or {}).get("name")) or "").strip()
                if sec_name != approved:
                    continue

                api_b64 = _secret_data_key_b64(ns, approved, "GRAFANA_API_KEY")
                tok_b64 = _secret_data_key_b64(ns, approved, "GRAFANA_TOKEN")
                api = ""
                tok = ""

                if api_b64:
                    try:
                        api = base64.b64decode(api_b64).decode("utf-8", errors="replace").strip()
                    except Exception:
                        api = ""

                if tok_b64:
                    try:
                        tok = base64.b64decode(tok_b64).decode("utf-8", errors="replace").strip()
                    except Exception:
                        tok = ""

                if api and tok and api == tok:
                    return f"{dname} envFrom -> Secret/{approved}", api

    return "", ""


def _deploy_grafana_secretkeyref(ns: str, deploy_name: str, var: str) -> Tuple[str, str]:
    """Return (secretName, secretKey) for env[].valueFrom.secretKeyRef on one var, or ("","")."""
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return "", ""
    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        for env in c.get("env") or []:
            if str(env.get("name") or "") != var:
                continue
            ref = (env.get("valueFrom") or {}).get("secretKeyRef") or {}
            sn = str(ref.get("name") or "").strip()
            sk = str(ref.get("key") or "").strip()
            if sn and sk:
                return sn, sk
    return "", ""


def _deploy_envfrom_secret_names(ns: str, deploy_name: str) -> list[str]:
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return []
    names: list[str] = []
    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        for ef in c.get("envFrom") or []:
            sref = (ef.get("secretRef") or {})
            n = str(sref.get("name") or "").strip()
            if n and n not in names:
                names.append(n)
    return names


def _secret_key_decoded(ns: str, sec_name: str, key: str) -> str:
    b64 = _secret_data_key_b64(ns, sec_name, key)
    if not b64:
        return ""
    try:
        return base64.b64decode(b64).decode("utf-8", errors="replace").strip()
    except Exception:
        return ""


def _grafana_validate_envfrom_secrets_aligned(
    ns: str, deploy_name: str, expected_tok: str
) -> Tuple[bool, str]:
    """
    If a Deployment references envFrom secretRef(s) that define Grafana credential keys, those
    secrets must not carry conflicting values.
    """
    exp = (expected_tok or "").strip()
    if not exp:
        return False, "internal: empty expected Grafana token for envFrom validation"
    problems: list[str] = []
    for sec in _deploy_envfrom_secret_names(ns, deploy_name):
        ga = _secret_key_decoded(ns, sec, "GRAFANA_API_KEY")
        gt = _secret_key_decoded(ns, sec, "GRAFANA_TOKEN")
        gg = _secret_key_decoded(ns, sec, "grafana_token")
        if not (ga or gt or gg):
            continue
        if not ga or not gt:
            problems.append(
                f"Secret/{sec} (envFrom on {deploy_name}) must define both GRAFANA_API_KEY and GRAFANA_TOKEN"
            )
            continue
        if ga != gt:
            problems.append(
                f"Secret/{sec} (envFrom on {deploy_name}) has GRAFANA_API_KEY != GRAFANA_TOKEN"
            )
            continue
        if ga != exp:
            problems.append(
                f"Secret/{sec} (envFrom on {deploy_name}) Grafana token conflicts with wired token"
            )
            continue
        if gg and gg != exp:
            problems.append(
                f"Secret/{sec} (envFrom on {deploy_name}) grafana_token conflicts with wired token"
            )
            continue
    if problems:
        return False, " | ".join(problems)
    return True, f"{deploy_name} envFrom Secret sources OK"


def _grafana_source_normalized_for_deploy(ns: str, dep_name: str, dep: dict) -> Tuple[bool, str]:
    approved = _APPROVED_GRAFANA_SECRET_BY_DEPLOY.get(dep_name)
    if not approved:
        return False, f"{dep_name}: no approved Grafana Secret mapping"

    found = set()

    containers = (
        ((dep.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers")
        or []
    )

    for c in containers:
        # Valid style 1: explicit env[].valueFrom.secretKeyRef
        for env in c.get("env") or []:
            name = str(env.get("name") or "")
            if name not in ("GRAFANA_API_KEY", "GRAFANA_TOKEN"):
                continue

            if "value" in env:
                return False, f"{dep_name}: {name} uses inline env.value; must use Secret-backed source"

            skr = (env.get("valueFrom") or {}).get("secretKeyRef") or {}
            sec_name = str(skr.get("name") or "")
            sec_key = str(skr.get("key") or "")

            if sec_name != approved or sec_key != name:
                return (
                    False,
                    f"{dep_name}: {name} must come from approved Secret {approved}/{name}; "
                    f"observed {sec_name}/{sec_key}",
                )

            found.add(name)

        # Valid style 2: envFrom.secretRef to approved Secret
        for ef in c.get("envFrom") or []:
            sec_name = str(((ef.get("secretRef") or {}).get("name")) or "").strip()
            if not sec_name:
                continue

            sec = kubectl_json(f"get secret/{shlex.quote(sec_name)} -n {shlex.quote(ns)}")
            if not sec:
                return False, f"{dep_name}: referenced Secret {sec_name} not found"

            data = sec.get("data") or {}

            if sec_name == approved:
                for key in ("GRAFANA_API_KEY", "GRAFANA_TOKEN"):
                    if key in data:
                        found.add(key)

            # Do not fail only because a non-approved envFrom Secret remains.
            # Fairness: live runtime token + Grafana API checks decide whether
            # an old source actually affects the workload.

    missing = {"GRAFANA_API_KEY", "GRAFANA_TOKEN"} - found
    if missing:
        return False, f"{dep_name}: missing approved Secret-backed Grafana sources: {sorted(missing)}"

    return True, f"{dep_name}: Grafana source normalized to approved Secret {approved}"


def _deploy_declares_grafana_env(ns: str, deploy_name: str) -> bool:
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return False
    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        for env in c.get("env") or []:
            if str(env.get("name") or "") in ("GRAFANA_API_KEY", "GRAFANA_TOKEN"):
                return True
    return False


def _deploy_has_both_grafana_env_keys(ns: str, deploy_name: str) -> bool:
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return False

    names: set[str] = set()
    approved = _APPROVED_GRAFANA_SECRET_BY_DEPLOY.get(deploy_name, "")

    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        for env in c.get("env") or []:
            en = str(env.get("name") or "")
            if en in ("GRAFANA_API_KEY", "GRAFANA_TOKEN"):
                names.add(en)

        for ef in c.get("envFrom") or []:
            sec_name = str(((ef.get("secretRef") or {}).get("name")) or "").strip()
            if sec_name != approved:
                continue

            sec = kubectl_json(f"get secret/{shlex.quote(sec_name)} -n {shlex.quote(ns)}")
            data = (sec or {}).get("data") or {}
            if "GRAFANA_API_KEY" in data:
                names.add("GRAFANA_API_KEY")
            if "GRAFANA_TOKEN" in data:
                names.add("GRAFANA_TOKEN")

    return "GRAFANA_API_KEY" in names and "GRAFANA_TOKEN" in names


def _container_declares_grafana_env_in_deploy(
    ns: str, deploy_name: str, ctr_name: str
) -> bool:
    dep = kubectl_json(f"get deploy/{shlex.quote(deploy_name)} -n {shlex.quote(ns)}")
    if not dep:
        return False
    for c in (
        (dep.get("spec") or {}).get("template", {}).get("spec", {}).get("containers") or []
    ):
        if str(c.get("name") or "") != ctr_name:
            continue
        for env in c.get("env") or []:
            if str(env.get("name") or "") in ("GRAFANA_API_KEY", "GRAFANA_TOKEN"):
                return True
        return False
    return False


def _runtime_grafana_per_container_audit(
    ns: str,
    pod: str,
    deploy_name: str,
    expected_tok: str,
) -> Tuple[bool, str]:
    """Every container that declares or materializes Grafana creds must expose both keys matching expected."""
    exp = (expected_tok or "").strip()
    if not exp:
        return False, "internal: empty expected Grafana token"
    any_checked = False
    for ctr in _deploy_workload_container_names(ns, deploy_name):
        ctn = str(ctr).strip()
        if not ctn:
            continue
        ga = _pod_printenv(ns, pod, ctn, "GRAFANA_API_KEY").strip()
        gt = _pod_printenv(ns, pod, ctn, "GRAFANA_TOKEN").strip()
        decl = _container_declares_grafana_env_in_deploy(ns, deploy_name, ctn)
        if not decl and not ga and not gt:
            continue
        any_checked = True
        if not ga or not gt:
            return (
                False,
                f"deployment/{deploy_name} pod {pod} container {ctn!r}: incomplete Grafana credentials "
                "(both GRAFANA_API_KEY and GRAFANA_TOKEN must exist in runtime where either appears)",
            )
        if ga != gt:
            return (
                False,
                f"deployment/{deploy_name} pod {pod} container {ctn!r}: GRAFANA_API_KEY != GRAFANA_TOKEN",
            )
        if ga != exp:
            return (
                False,
                f"deployment/{deploy_name} pod {pod} container {ctn!r}: runtime Grafana token differs "
                "from wired Deployment credential (roll out all containers)",
            )
    if not any_checked:
        ctr, pod_api_tok, pod_alt_tok = _pod_grafana_key_pair(ns, pod, deploy_name)
        if not pod_api_tok or not pod_alt_tok:
            return (
                False,
                f"Running pod {pod} must expose both GRAFANA_API_KEY and GRAFANA_TOKEN "
                f"(checked containers: {_deploy_workload_container_names(ns, deploy_name)})",
            )
        if pod_api_tok.strip() != pod_alt_tok.strip():
            return (
                False,
                f"Running pod {pod} has conflicting GRAFANA_API_KEY and GRAFANA_TOKEN values",
            )
        if pod_api_tok.strip() != exp:
            return (
                False,
                f"Running pod {pod} Grafana token differs from wired Deployment credential",
            )
    return True, "per-container Grafana runtime OK"


def _grafana_validate_org_user_login(
    base: str, hdrs: dict[str, str], detail: str
) -> Tuple[bool, str]:
    """Require /api/org and /api/user (login). /api/user/orgs may be RBAC-limited."""
    last_err = ""
    for attempt in range(GRAFANA_HTTP_ATTEMPTS):
        code, _ = http_json(f"{base.rstrip('/')}/api/org", headers=hdrs)
        if code != 200:
            last_err = f"Grafana rejected token on /api/org (HTTP {code}) {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        code2, body = http_json(f"{base.rstrip('/')}/api/user", headers=hdrs)
        if code2 != 200:
            last_err = f"Grafana /api/user failed (HTTP {code2}) {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        if not isinstance(body, dict):
            last_err = f"Grafana /api/user returned non-JSON body {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        if not str(body.get("login") or "").strip():
            last_err = f"Grafana /api/user JSON missing non-empty 'login' {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        code3, body3 = http_json(f"{base.rstrip('/')}/api/user/orgs", headers=hdrs)
        if code3 in (403, 404):
            return True, ""
        if code3 != 200:
            last_err = (
                f"Grafana /api/user/orgs failed (HTTP {code3}) {detail}; "
                "need 200 with at least one org"
            )
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        if not isinstance(body3, list):
            last_err = f"Grafana /api/user/orgs returned non-JSON array {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        if len(body3) < 1:
            last_err = f"Grafana /api/user/orgs returned empty organization list {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        has_org_identity = any(
            isinstance(o, dict) and (o.get("orgId") or o.get("id") or o.get("name"))
            for o in body3
        )
        if not has_org_identity:
            last_err = f"Grafana /api/user/orgs response missing org identity fields {detail}"
            time.sleep(GRAFANA_HTTP_BACKOFF_BASE_SEC * (attempt + 1))
            continue
        return True, ""
    return False, last_err or f"Grafana HTTP validation failed after {GRAFANA_HTTP_ATTEMPTS} attempts {detail}"


def _grafana_api_call(base: str, api_key: str, token: str) -> bool:
    """True when runtime Grafana credentials authenticate to Grafana (org + user; orgs optional)."""
    if api_key == token:
        ok, _ = _grafana_validate_org_user_login(
            base,
            {"Authorization": f"Bearer {api_key}"},
            "runtime Grafana credential",
        )
        return ok
    ok_k, _ = _grafana_validate_org_user_login(
        base,
        {"Authorization": f"Bearer {api_key}"},
        "runtime GRAFANA_API_KEY",
    )
    ok_t, _ = _grafana_validate_org_user_login(
        base,
        {"Authorization": f"Bearer {token}"},
        "runtime GRAFANA_TOKEN",
    )
    return ok_k and ok_t


def _grafana_http_ok_for_distinct_container_tokens(
    ns: str,
    base: str,
    pod: str,
    deploy_name: str,
    role_label: str,
) -> Tuple[bool, str]:
    """Probe Grafana with each distinct bearer token found on any workload container (both keys required)."""
    seen: set[str] = set()
    for ctr in _deploy_workload_container_names(ns, deploy_name):
        ctn = str(ctr).strip()
        if not ctn:
            continue
        ga = _pod_printenv(ns, pod, ctn, "GRAFANA_API_KEY").strip()
        gt = _pod_printenv(ns, pod, ctn, "GRAFANA_TOKEN").strip()
        if not ga and not gt:
            continue
        if not ga or not gt:
            return (
                False,
                f"{role_label} pod {pod} container {ctn!r}: incomplete Grafana creds for live API probe",
            )
        if ga != gt:
            return (
                False,
                f"{role_label} pod {pod} container {ctn!r}: GRAFANA_API_KEY != GRAFANA_TOKEN",
            )
        if ga in seen:
            continue
        seen.add(ga)
        hdrs = {"Authorization": f"Bearer {ga}"}
        ok_g, err_g = _grafana_validate_org_user_login(
            base,
            hdrs,
            f"from {role_label} pod {pod} container {ctn!r}",
        )
        if not ok_g:
            return False, err_g
    if not seen:
        _, pod_api_tok, pod_alt_tok = _pod_grafana_key_pair(ns, pod, deploy_name)
        if not pod_api_tok or not pod_alt_tok:
            return (
                False,
                f"{role_label} pod {pod} must expose Grafana credentials "
                f"(checked containers: {_deploy_workload_container_names(ns, deploy_name)})",
            )
        if pod_api_tok.strip() != pod_alt_tok.strip():
            return (
                False,
                f"{role_label} pod {pod} has conflicting GRAFANA_API_KEY and GRAFANA_TOKEN",
            )
        tok = pod_api_tok.strip()
        hdrs = {"Authorization": f"Bearer {tok}"}
        ok_g, err_g = _grafana_validate_org_user_login(
            base, hdrs, f"; {role_label} pod {pod}"
        )
        if not ok_g:
            return False, err_g
        seen.add(tok)
    return True, f"Grafana HTTP OK ({role_label} pod {pod}; {len(seen)} distinct token(s) probed)"


def parse_repeat_minutes(val: str) -> Optional[float]:
    if not val:
        return None
    val = val.strip().strip('"').lower()
    m = re.match(r"^(\d+(?:\.\d+)?)\s*([mhs])$", val)
    if not m:
        return None
    num, unit = float(m.group(1)), m.group(2)
    if unit == "m":
        return num
    if unit == "h":
        return num * 60
    if unit == "s":
        return num / 60
    return None


def _pg_exec_oncall_db(ns: str, pod: str, sql: str, timeout: int = 60) -> str:
    passwords = ["oncall", ""]
    pg_sec = discover_oncall_postgres_secret_name(ns)
    if pg_sec:
        rc_p, pp, _ = run_cmd(
            f"kubectl get secret -n {ns} {shlex.quote(pg_sec)} -o jsonpath='{{.data.postgres-password}}' 2>/dev/null"
        )
        if rc_p == 0 and pp:
            _, dec, _ = run_cmd(f"echo {pp} | base64 -d", timeout=5)
            if dec:
                passwords.insert(0, dec)

    out = ""
    b64 = base64.b64encode(sql.encode()).decode("ascii")
    for pw in passwords:
        rc, o, _ = run_cmd(
            f"echo {b64} | base64 -d | kubectl exec -n {ns} {pod} -i -- "
            f"env PGPASSWORD={pw} psql -U oncall -d oncall -t -A 2>/dev/null",
            timeout=timeout,
        )
        if rc == 0 and o.strip():
            out = o
            break
        rc, o, _ = run_cmd(
            f"echo {b64} | base64 -d | kubectl exec -n {ns} {pod} -i -- "
            f"psql -U postgres -d oncall -t -A 2>/dev/null",
            timeout=timeout,
        )
        if rc == 0 and o.strip():
            out = o
            break
    return out.strip()


def _oncall_postgresql_pod_name(ns: str) -> str:
    """Running Postgres for OnCall (labels vary by chart: Bitnami, Helm subcharts, etc.)."""
    data = kubectl_json(f"get pods -n {ns}")
    if not data:
        return ""
    candidates: list[str] = []
    for pod in data.get("items") or []:
        if (pod.get("status") or {}).get("phase") != "Running":
            continue
        pname = str((pod.get("metadata") or {}).get("name") or "")
        pl = pname.lower()
        if "postgres-exporter" in pl or "pooler" in pl:
            continue
        labels = (pod.get("metadata") or {}).get("labels") or {}
        if labels.get("app.kubernetes.io/name") == "postgresql":
            candidates.append(pname)
        elif labels.get("app") in ("postgresql", "postgres"):
            candidates.append(pname)
        elif "postgresql" in pl:
            candidates.append(pname)
        elif pl.startswith("postgres-") or pl.startswith("oncall-postgresql"):
            candidates.append(pname)
    if not candidates:
        return ""
    candidates.sort()
    return candidates[0]


def _grading_all_zero(feedback: str) -> GradingResult:
    weights = {k: WEIGHT for k in SUBKEYS}
    return GradingResult(
        score=0.0,
        subscores={k: 0.0 for k in SUBKEYS},
        weights=weights,
        feedback=feedback,
    )


def grade(transcript: str) -> GradingResult:
    log(f"grade entry transcript_arg_type={type(transcript).__name__!s}")
    if transcript is None:
        log("grade exit error transcript is None")
        r = _grading_all_zero("Invalid args: transcript must not be None (use empty string or n/a)")
        reset_oncall_namespace_cache()
        return r

    _ = str(transcript)
    log(f"grade transcript_chars={len(_)}")
    _kc_reset_oauth_inspect_for_new_grade()

    checks: list[Tuple[str, Callable[[], Tuple[bool, str]]]] = [
        ("keycloak_session_idle", check_keycloak_session_idle),
        # other checks added in Phases 6, 7, 10, 13, 16, 19
        # ("keycloak_redirect_authorize", check_keycloak_redirect_authorize),
        # ("keycloak_refresh", check_keycloak_refresh),
        # ("istio_anonymous_AND_admin", check_istio_anonymous_AND_admin),
        # ("ttl_runtime", check_ttl_runtime),
        # ("grafana_token_flow", check_grafana_token_flow),
        # ("escalation_window", check_escalation_window),
    ]

    deadline = time.monotonic() + GRADE_WALL_CLOCK_SEC
    log(f"grade wall_clock_budget_sec={GRADE_WALL_CLOCK_SEC}")

    feedback = []
    subscores: dict[str, float] = {}
    for key, fn in checks:
        if time.monotonic() > deadline:
            log(f"grade budget exceeded before {key}")
            subscores[key] = 0.0
            feedback.append(
                f"SKIP {key}: grader wall-clock budget exceeded ({GRADE_WALL_CLOCK_SEC:g}s)"
            )
            continue
        log(f"check begin {key}")
        t0 = time.monotonic()
        try:
            ok, msg = fn()
        except Exception as e:
            log(f"check exception {key}: {e!r}")
            ok, msg = False, f"Exception: {e}"
        subscores[key] = 1.0 if ok else 0.0
        feedback.append(f"{'PASS' if ok else 'FAIL'} {key}: {msg}")
        log(f"check end {key} ok={ok} elapsed_sec={time.monotonic() - t0:.2f}")

    for k in SUBKEYS:
        if k not in subscores:
            subscores[k] = 0.0
            feedback.append(
                f"SKIP {k}: not implemented yet (Phase 5 only wires keycloak_session_idle)"
            )

    weights = {k: WEIGHT for k in SUBKEYS}
    score = sum(subscores[k] * weights[k] for k in SUBKEYS)
    log(f"grade exit score={score:.4f}")

    out = GradingResult(
        score=score,
        subscores=subscores,
        weights=weights,
        feedback=" | ".join(feedback),
    )
    reset_oncall_namespace_cache()
    return out


if __name__ == "__main__":
    r = grade("")
    print(json.dumps({"score": r.score, "subscores": r.subscores, "weights": r.weights, "feedback": r.feedback}))
