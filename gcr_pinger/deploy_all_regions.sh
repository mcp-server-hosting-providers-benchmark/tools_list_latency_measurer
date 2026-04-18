#!/usr/bin/env bash
# deploy_all_regions.sh
# Construit l'image Docker du pinger, la pousse sur Artifact Registry,
# puis crée/met à jour les Cloud Run Jobs et leurs Cloud Scheduler dans chaque région.
#
# Prérequis :
#   gcloud auth login (fait)
#   gcloud config set project tools-list-latency-pingers (fait)
#   APIs activées : run, cloudscheduler, artifactregistry, secretmanager (fait)
#   Artifact Registry repo créé : mcp-pingers à europe-west9 (fait)
#
# Usage :
#   chmod +x deploy_all_regions.sh
#   ./deploy_all_regions.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
PROJECT_ID="tools-list-latency-pingers"
AR_REPO="europe-west9-docker.pkg.dev/${PROJECT_ID}/mcp-pingers"
IMAGE="${AR_REPO}/pinger:latest"
GCS_BUCKET="mcp-benchmark-results"

# Schedule : toutes les 2h aux heures paires UTC
CRON_SCHEDULE="0 */2 * * *"

# Timezone UTC pour tous les schedulers
SCHEDULER_TZ="Etc/UTC"

# Service account pour Cloud Scheduler → Cloud Run Jobs
SA_NAME="mcp-pinger-runner"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ── Régions (7 continents) ──────────────────────────────────────────────────────
# Format : "GCR_REGION PINGER_LABEL CONTINENT"

# Format : "JOB_REGION PINGER_LABEL CONTINENT SCHEDULER_REGION"
# SCHEDULER_REGION = région voisine si la région du job ne supporte pas Cloud Scheduler
declare -a REGIONS=(
  "australia-southeast1  sydney_au        oceania        australia-southeast1"
  "us-east1              virginia_us      north_america  us-east1"
  "us-west1              oregon_us        north_america  us-west1"
  "europe-west9          paris_fr         europe         europe-west3"
  "europe-central2       warsaw_pl        europe         europe-central2"
  "asia-east2            hong_kong_hk     asia           asia-east2"
  "asia-northeast1       tokyo_jp         asia           asia-northeast1"
  "asia-southeast1       singapore_sg     asia           asia-southeast1"
  "asia-south1           mumbai_in        asia           asia-south1"
  "southamerica-east1    sao_paulo_br     south_america  southamerica-east1"
  "me-west1              tel_aviv_il      middle_east    me-west1"
  "africa-south1         johannesburg_za  africa         europe-west1"
)

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

# ── Étape 1 : créer le bucket GCS si absent ────────────────────────────────────
log "Vérification du bucket GCS ${GCS_BUCKET}..."
if ! gcloud storage buckets describe "gs://${GCS_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud storage buckets create "gs://${GCS_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="us" \
    --uniform-bucket-level-access
  log "Bucket créé : gs://${GCS_BUCKET}"
else
  log "Bucket gs://${GCS_BUCKET} déjà présent — OK"
fi

# ── Étape 2 : créer le service account pour Cloud Scheduler ────────────────────
log "Vérification du service account ${SA_EMAIL}..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="MCP Pinger Runner (Cloud Scheduler → Cloud Run Jobs)" \
    --project="${PROJECT_ID}"
  log "Service account créé — attente propagation IAM..."
  sleep 15
else
  log "Service account déjà présent — OK"
fi

# Donner les droits d'exécution des Cloud Run Jobs au service account
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker" \
  --condition=None \
  --quiet

# Donner au compte de service par défaut de Compute l'accès en écriture au bucket GCS
# (Cloud Run Jobs utilisent le SA Compute par défaut sauf si on en précise un autre)
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/storage.objectCreator" \
  --quiet

# Lecture publique : GitHub Actions télécharge sans clé secrète
gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="allUsers" \
  --role="roles/storage.objectViewer" \
  --quiet

# ── Étape 3 : build & push via Cloud Build (pas besoin de Docker local) ────────
log "Build de l'image via Cloud Build..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gcloud builds submit "${SCRIPT_DIR}" \
  --tag="${IMAGE}" \
  --project="${PROJECT_ID}" \
  --quiet
log "Image poussée : ${IMAGE}"

# ── Étape 4 : déployer dans chaque région ──────────────────────────────────────
FAILED_REGIONS=()

deploy_region() {
  local REGION="$1" LABEL="$2" CONTINENT="$3" SCHEDULER_REGION="$4"
  local JOB_NAME="mcp-pinger-${LABEL//_/-}"
  local SCHEDULER_NAME="trigger-${JOB_NAME}"

  log "--- ${LABEL} (${REGION}) ---"

  # 4a. Créer ou mettre à jour le Cloud Run Job
  if gcloud run jobs describe "${JOB_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log "  Mise à jour du job ${JOB_NAME}..."
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
    log "  Création du job ${JOB_NAME}..."
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

  # 4b. URL de déclenchement du job via l'API Cloud Run
  local JOB_EXECUTE_URL="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"

  # 4c. Créer ou mettre à jour le Cloud Scheduler
  if gcloud scheduler jobs describe "${SCHEDULER_NAME}" --location="${SCHEDULER_REGION}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
    log "  Mise à jour du scheduler ${SCHEDULER_NAME}..."
    gcloud scheduler jobs update http "${SCHEDULER_NAME}" \
      --location="${SCHEDULER_REGION}" \
      --project="${PROJECT_ID}" \
      --schedule="${CRON_SCHEDULE}" \
      --time-zone="${SCHEDULER_TZ}" \
      --uri="${JOB_EXECUTE_URL}" \
      --http-method=POST \
      --oauth-service-account-email="${SA_EMAIL}" \
      --quiet
  else
    log "  Création du scheduler ${SCHEDULER_NAME}..."
    gcloud scheduler jobs create http "${SCHEDULER_NAME}" \
      --location="${SCHEDULER_REGION}" \
      --project="${PROJECT_ID}" \
      --schedule="${CRON_SCHEDULE}" \
      --time-zone="${SCHEDULER_TZ}" \
      --uri="${JOB_EXECUTE_URL}" \
      --http-method=POST \
      --oauth-service-account-email="${SA_EMAIL}" \
      --quiet
  fi

  log "  ${LABEL} OK"
}

for entry in "${REGIONS[@]}"; do
  read -r REGION LABEL CONTINENT SCHEDULER_REGION <<< "${entry}"
  deploy_region "${REGION}" "${LABEL}" "${CONTINENT}" "${SCHEDULER_REGION}" || {
    log "  ERREUR: ${LABEL} (${REGION}) ignoré — voir logs ci-dessus"
    FAILED_REGIONS+=("${LABEL}")
  }
done

# ── Résumé ─────────────────────────────────────────────────────────────────────
echo ""
log "Déploiement terminé — ${#REGIONS[@]} régions tentées"
echo ""
echo "Jobs tentés :"
for entry in "${REGIONS[@]}"; do
  read -r REGION LABEL CONTINENT SCHEDULER_REGION <<< "${entry}"
  echo "  ${LABEL} (${REGION})"
done
if [ ${#FAILED_REGIONS[@]} -gt 0 ]; then
  echo ""
  echo "Régions en ERREUR :"
  for r in "${FAILED_REGIONS[@]}"; do
    echo "  !! ${r}"
  done
fi
echo ""
echo "Vérification manuelle :"
echo "  gcloud run jobs list --project=${PROJECT_ID}"
echo "  gcloud scheduler jobs list --project=${PROJECT_ID}"
