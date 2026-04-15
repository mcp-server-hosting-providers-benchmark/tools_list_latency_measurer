#!/usr/bin/env bash
# measure_and_push.sh
# Lance une mesure tools/list puis pousse le fichier résultat sur la branche data du repo.
# Appelé par launchd toutes les 2h.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$REPO_DIR/results"
LOG="$REPO_DIR/logs/tools_list.log"
WORKTREE="$REPO_DIR/.data_branch"

# Chemins complets requis car launchd n'a pas le PATH utilisateur
NODE=/Users/nico/.nvm/versions/node/v24.14.0/bin/node
GIT=/usr/bin/git

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# 1. Lancer la mesure
log "Démarrage de la mesure tools/list"
"$NODE" "$REPO_DIR/tools_list_measurement.js" --jitter 300

# 2. Trouver le fichier le plus récent dans results/
NEW_FILE=$(ls -t "$RESULTS_DIR"/tools_list_*.json 2>/dev/null | head -1)
if [ -z "$NEW_FILE" ]; then
  log "ERREUR : aucun fichier résultat trouvé dans $RESULTS_DIR"
  exit 1
fi
FILENAME="$(basename "$NEW_FILE")"
log "Fichier à pousser : $FILENAME"

# 3. Pousser sur la branche data
cd "$REPO_DIR"
"$GIT" config user.name "macbook-pinger"
"$GIT" config user.email "macbook-pinger@local"

"$GIT" fetch origin data 2>>"$LOG"

# Créer le worktree sur la branche data
rm -rf "$WORKTREE"
if "$GIT" ls-remote --exit-code origin data >/dev/null 2>&1; then
  "$GIT" worktree add "$WORKTREE" origin/data -b data_push_mac 2>>"$LOG" || \
  "$GIT" worktree add "$WORKTREE" data 2>>"$LOG"
else
  "$GIT" worktree add --orphan -b data "$WORKTREE" 2>>"$LOG"
fi

# Vérifier si le fichier est déjà présent (évite les doublons)
if [ -f "$WORKTREE/$FILENAME" ]; then
  log "Fichier déjà présent sur data — rien à pousser"
  "$GIT" worktree remove --force "$WORKTREE"
  exit 0
fi

cp "$NEW_FILE" "$WORKTREE/"
"$GIT" -C "$WORKTREE" add "$FILENAME"
"$GIT" -C "$WORKTREE" commit -m "result: $FILENAME"

for attempt in 1 2 3; do
  if "$GIT" -C "$WORKTREE" push origin HEAD:data 2>>"$LOG"; then
    log "Poussé sur data (tentative $attempt)"
    break
  fi
  log "Push rejeté, rebase et retry ($attempt/3)"
  "$GIT" -C "$WORKTREE" pull --rebase origin data 2>>"$LOG"
done

"$GIT" worktree remove --force "$WORKTREE"
log "Terminé"
