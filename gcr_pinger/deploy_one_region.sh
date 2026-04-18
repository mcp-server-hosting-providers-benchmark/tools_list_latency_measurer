#!/usr/bin/env bash
# deploy_one_region.sh
# Déploie ou met à jour un Cloud Run Job pour une région.
# N'inclut pas de Cloud Scheduler — l'orchestrateur sera ajouté séparément.
#
# Usage :
#   ./deploy_one_region.sh <pinger_label> <gcr_region>
#
# Exemple :
#   ./deploy_one_region.sh paris_fr europe-west9
#   ./deploy_one_region.sh tokyo_jp asia-northeast1

set -euo pipefail

LABEL="${1:?Usage: deploy_one_region.sh <pinger_label> <gcr_region>}"
REGION="${2:?Usage: deploy_one_region.sh <pinger_label> <gcr_region>}"

PROJECT_ID="tools-list-latency-pingers"
IMAGE="europe-west9-docker.pkg.dev/${PROJECT_ID}/mcp-pingers/pinger:latest"
GCS_BUCKET="mcp-benchmark-results"
JOB_NAME="mcp-pinger-${LABEL//_/-}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

log "Déploiement de ${LABEL} dans ${REGION}..."

if gcloud run jobs describe "${JOB_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  log "Mise à jour du job ${JOB_NAME}..."
  gcloud run jobs update "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --image="${IMAGE}" \
    --set-env-vars="PINGER_LABEL=${LABEL},GCR_REGION=${REGION},GCS_BUCKET=${GCS_BUCKET}" \
    --memory="512Mi" \
    --cpu="1" \
    --task-timeout="300s" \
    --max-retries=1 \
    --quiet
else
  log "Création du job ${JOB_NAME}..."
  gcloud run jobs create "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --image="${IMAGE}" \
    --set-env-vars="PINGER_LABEL=${LABEL},GCR_REGION=${REGION},GCS_BUCKET=${GCS_BUCKET}" \
    --memory="512Mi" \
    --cpu="1" \
    --task-timeout="300s" \
    --max-retries=1 \
    --quiet
fi

log "${LABEL} (${REGION}) déployé."
log "Pour tester : gcloud run jobs execute ${JOB_NAME} --region=${REGION} --project=${PROJECT_ID}"
