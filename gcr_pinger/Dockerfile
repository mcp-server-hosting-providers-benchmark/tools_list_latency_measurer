FROM node:22-alpine

WORKDIR /app

# Pas de dépendances npm — uniquement des modules Node.js built-in + fetch API (Node 22)
COPY package.json pinger.js ./

# Env vars injectées par Cloud Run Jobs (auto) :
#   CLOUD_RUN_JOB, CLOUD_RUN_EXECUTION, CLOUD_RUN_TASK_INDEX
#
# Env vars à définir dans la config du job :
#   GCS_BUCKET     nom du bucket GCS cible, ex. "mcp-benchmark-results"
#   PINGER_LABEL   ex. "paris_fr"
#   GCR_REGION     ex. "europe-west9"

CMD ["node", "pinger.js"]
