#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/k8s"
NAMESPACE="fastapi-test"
ARGOCD_NAMESPACE="argocd"
APP_NAME="fastapi-test"
PID_FILE="$SCRIPT_DIR/.start.pids"
TMP_CONFIG="$SCRIPT_DIR/.app-config.local.yaml"

log() { echo "[stop] $*"; }

# ── Kill tracked background processes ────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
  while IFS= read -r pid; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "Killing PID $pid..."
      kill "$pid" 2>/dev/null || true
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
fi

# Kill any stray kubectl port-forward, proxy, or backstage processes by pattern
pkill -f "kubectl proxy --port=8001" 2>/dev/null || true
pkill -f "kubectl port-forward service/fastapi.*$NAMESPACE" 2>/dev/null || true
pkill -f "kubectl port-forward service/argocd-server" 2>/dev/null || true
pkill -f "backstage-cli repo start" 2>/dev/null || true

# ── Delete ArgoCD Application first (prevents selfHeal re-creating resources) ─
if command -v kubectl &>/dev/null; then
  if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    log "Deleting ArgoCD Application '$APP_NAME'..."
    kubectl delete -f "$K8S_DIR/argocd.yaml" --ignore-not-found=true
  fi

  # ── Delete the k8s resources ───────────────────────────────────────────────
  # ArgoCD with prune=true removes them on Application delete, but we also
  # delete explicitly as a safety net in case ArgoCD hasn't pruned yet.
  log "Deleting k8s manifests..."
  kubectl delete -f "$K8S_DIR/service.yaml" --ignore-not-found=true
  kubectl delete -f "$K8S_DIR/deployment.yaml" --ignore-not-found=true
  log "Done. Namespace '$NAMESPACE' retained (delete manually if needed)."
else
  log "kubectl not found, skipping k8s cleanup."
fi

# ── Clean up temp config ──────────────────────────────────────────────────────
rm -f "$TMP_CONFIG"

log "Stopped."
