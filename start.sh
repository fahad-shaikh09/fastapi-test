#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/k8s"
NAMESPACE="fastapi-test"
ARGOCD_NAMESPACE="argocd"
APP_NAME="fastapi-test"
SERVICE_NAME="fastapi"
LOCAL_PORT=8080
REMOTE_PORT=80
ARGOCD_LOCAL_PORT=8090
PID_FILE="$SCRIPT_DIR/.start.pids"
TMP_CONFIG="$SCRIPT_DIR/.app-config.local.yaml"

cleanup() {
  echo ""
  echo "Shutting down..."
  "$SCRIPT_DIR/stop.sh"
}
trap cleanup INT TERM EXIT

log() { echo "[start] $*"; }

# ── Find an available port starting from $1 ───────────────────────────────────
find_free_port() {
  local port="${1:-3000}"
  while lsof -iTCP:"$port" -sTCP:LISTEN -t &>/dev/null; do
    port=$((port + 1))
  done
  echo "$port"
}

# ── Prerequisites ────────────────────────────────────────────────────────────
for cmd in kubectl yarn node lsof; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed or not in PATH." >&2
    exit 1
  fi
done

# ── Confirm Kubernetes context ───────────────────────────────────────────────
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "(none)")
echo ""
echo "  Kubernetes context : $CURRENT_CONTEXT"
echo "  Target namespace   : $NAMESPACE"
echo ""
read -rp "Deploy to this context? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted. Switch context with: kubectl config use-context <name>"
  exit 0
fi

if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
  echo "ERROR: ArgoCD namespace '$ARGOCD_NAMESPACE' not found. Is ArgoCD installed?" >&2
  exit 1
fi

# ── Apply ArgoCD Application ─────────────────────────────────────────────────
log "Applying ArgoCD Application '$APP_NAME'..."
kubectl apply -f "$K8S_DIR/argocd.yaml"

# ── Wait for ArgoCD to sync and the app to become healthy ────────────────────
log "Waiting for ArgoCD Application '$APP_NAME' to sync and be healthy..."
TIMEOUT=180
ELAPSED=0
INTERVAL=5
while true; do
  SYNC=$(kubectl get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  HEALTH=$(kubectl get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

  log "  sync=$SYNC  health=$HEALTH"

  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    log "Application is synced and healthy."
    break
  fi

  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "ERROR: Timed out waiting for ArgoCD Application to become Synced+Healthy." >&2
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ── Start kubectl proxy for Backstage Kubernetes plugin ──────────────────────
log "Starting kubectl proxy on port 8001 for Backstage Kubernetes plugin..."
kubectl proxy --port=8001 &>/dev/null &
PROXY_PID=$!
echo "$PROXY_PID" > "$PID_FILE"
sleep 1
if ! kill -0 "$PROXY_PID" 2>/dev/null; then
  echo "ERROR: kubectl proxy failed to start." >&2
  exit 1
fi
log "kubectl proxy running (PID $PROXY_PID) at http://localhost:8001"

# ── Port-forward the service ─────────────────────────────────────────────────
log "Port-forwarding $SERVICE_NAME service: localhost:$LOCAL_PORT → $REMOTE_PORT..."
kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$REMOTE_PORT" -n "$NAMESPACE" &
PF_PID=$!
echo "$PF_PID" >> "$PID_FILE"

sleep 2
if ! kill -0 "$PF_PID" 2>/dev/null; then
  echo "ERROR: port-forward failed to start." >&2
  exit 1
fi
log "FastAPI service available at http://localhost:$LOCAL_PORT"

# ── Port-forward ArgoCD ──────────────────────────────────────────────────────
ARGOCD_LOCAL_PORT=$(find_free_port $ARGOCD_LOCAL_PORT)
log "Port-forwarding ArgoCD server: localhost:$ARGOCD_LOCAL_PORT → 443..."
kubectl port-forward service/argocd-server "$ARGOCD_LOCAL_PORT:443" -n "$ARGOCD_NAMESPACE" &
ARGOCD_PF_PID=$!
echo "$ARGOCD_PF_PID" >> "$PID_FILE"

sleep 2
if ! kill -0 "$ARGOCD_PF_PID" 2>/dev/null; then
  echo "ERROR: ArgoCD port-forward failed to start." >&2
  exit 1
fi
log "ArgoCD UI available at https://localhost:$ARGOCD_LOCAL_PORT"

# ── Find a free port for Backstage ───────────────────────────────────────────
BACKSTAGE_PORT=$(find_free_port 3000)
if [[ "$BACKSTAGE_PORT" -ne 3000 ]]; then
  log "Port 3000 is in use — using port $BACKSTAGE_PORT instead."
fi

# Write a temporary config override so Backstage uses the chosen port
cat > "$TMP_CONFIG" <<EOF
app:
  baseUrl: http://localhost:${BACKSTAGE_PORT}

backend:
  cors:
    origin: http://localhost:${BACKSTAGE_PORT}
EOF

# ── Start Backstage dev server ───────────────────────────────────────────────
log "Starting Backstage dev server (frontend: http://localhost:$BACKSTAGE_PORT, backend: http://localhost:7007)..."
yarn --cwd "$SCRIPT_DIR" start --config "$SCRIPT_DIR/app-config.yaml" --config "$TMP_CONFIG" &
BS_PID=$!
echo "$BS_PID" >> "$PID_FILE"

log "All services started. Press Ctrl+C to stop."
wait
