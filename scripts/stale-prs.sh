#!/usr/bin/env bash
# Stale PR policy for the joinmason org.
# Warns at WARN_DAYS of inactivity, closes at CLOSE_DAYS.
# Drafts and PRs with exempt labels are skipped.
set -euo pipefail

ORG="${ORG:-joinmason}"
WARN_DAYS="${WARN_DAYS:-23}"
CLOSE_DAYS="${CLOSE_DAYS:-30}"
DRY_RUN="${DRY_RUN:-false}"
EXEMPT_LABELS="${EXEMPT_LABELS:-no-stale,keep-open}"

STALE_LABEL="stale"
STALE_COLOR="e4e669"

NOW=$(date -u +%s)
WARN_THRESHOLD=$((NOW - WARN_DAYS * 86400))
CLOSE_THRESHOLD=$((NOW - CLOSE_DAYS * 86400))
WARN_DATE=$(date -u -d "@${WARN_THRESHOLD}" +%Y-%m-%d)

WARNED=0
CLOSED=0
SKIPPED=0

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

ensure_label() {
  local repo=$1
  gh api "repos/${ORG}/${repo}/labels" -X POST \
    -f name="${STALE_LABEL}" \
    -f color="${STALE_COLOR}" \
    -f description="No activity for ${WARN_DAYS}+ days" \
    2>/dev/null || true
}

is_exempt() {
  local labels=$1
  IFS=',' read -ra exempt_list <<< "$EXEMPT_LABELS"
  for exempt in "${exempt_list[@]}"; do
    if echo "$labels" | jq -e --arg l "$exempt" 'any(. == $l)' > /dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

warn_pr() {
  local repo=$1 number=$2 author=$3 labels=$4
  local already_stale
  already_stale=$(echo "$labels" | jq -r 'any(. == "stale")')

  if [ "$already_stale" = "true" ]; then
    log "SKIP (already warned): ${ORG}/${repo}#${number}"
    ((SKIPPED++)) || true
    return
  fi

  log "WARN: ${ORG}/${repo}#${number} (@${author}) — closes in $((CLOSE_DAYS - WARN_DAYS)) days if no activity"
  if [ "$DRY_RUN" = "true" ]; then return; fi

  ensure_label "$repo"
  gh api "repos/${ORG}/${repo}/issues/${number}/labels" \
    -X POST --field "labels[]=${STALE_LABEL}" > /dev/null
  gh api "repos/${ORG}/${repo}/issues/${number}/comments" -X POST -f body="👋 @${author} — This PR has been inactive for **${WARN_DAYS}+ days** and is now marked as stale. It will be **automatically closed in $((CLOSE_DAYS - WARN_DAYS)) days** unless there is new activity.

To keep it open: push a commit, leave a comment, or add the \`no-stale\` label." > /dev/null

  ((WARNED++)) || true
}

close_pr() {
  local repo=$1 number=$2 author=$3

  log "CLOSE: ${ORG}/${repo}#${number} (@${author}) — inactive ${CLOSE_DAYS}+ days"
  if [ "$DRY_RUN" = "true" ]; then return; fi

  gh api "repos/${ORG}/${repo}/issues/${number}/comments" -X POST -f body="This PR has been **automatically closed** after **${CLOSE_DAYS} days** of inactivity.

To continue this work, reopen the PR or open a new one. Add the \`no-stale\` label to a PR to exempt it from this policy." > /dev/null
  gh api "repos/${ORG}/${repo}/pulls/${number}" \
    -X PATCH -f state=closed > /dev/null

  ((CLOSED++)) || true
}

log "Stale PR sweep — org: ${ORG} | warn: ${WARN_DAYS}d | close: ${CLOSE_DAYS}d | dry-run: ${DRY_RUN}"
log "Fetching open PRs with no activity since ${WARN_DATE}..."

prs=$(gh search prs \
  --owner "${ORG}" \
  --state open \
  --updated "<${WARN_DATE}" \
  --json number,repository,author,labels,isDraft,updatedAt \
  --limit 1000 2>/dev/null)

total=$(echo "$prs" | jq 'length')
log "Found ${total} candidate PR(s) (drafts will be skipped)"

while read -r pr; do
  number=$(echo "$pr" | jq -r '.number')
  repo=$(echo "$pr" | jq -r '.repository.name')
  author=$(echo "$pr" | jq -r '.author.login')
  updated_at=$(echo "$pr" | jq -r '.updatedAt')
  labels=$(echo "$pr" | jq -r '[.labels[].name]')

  if is_exempt "$labels"; then
    log "EXEMPT: ${ORG}/${repo}#${number}"
    ((SKIPPED++)) || true
    continue
  fi

  updated_epoch=$(date -d "$updated_at" +%s)

  if [ "$updated_epoch" -lt "$CLOSE_THRESHOLD" ]; then
    close_pr "$repo" "$number" "$author"
  else
    warn_pr "$repo" "$number" "$author" "$labels"
  fi
done < <(echo "$prs" | jq -c '.[] | select(.isDraft == false)')

log "Done — warned: ${WARNED} | closed: ${CLOSED} | skipped/exempt: ${SKIPPED}"
