#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/SR6Glory/auto-dump-mysql.git"
TARGET_DIR="${HOME}/auto-dump-mysql"
BUN_BIN="${HOME}/.bun/bin"

# ── UI helpers ───────────────────────────────────────────────────────────
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
hr()     { printf "%s\n" "========================================================"; }

title="Auto setup and run • auto-dump-mysql"
printf "\033]0;%s\007" "$title" 2>/dev/null || true
hr
bold "[0] Start"
printf "     Repo   : %s\n" "$REPO_URL"
printf "     Target : %s\n" "$TARGET_DIR"
hr

# ── Command Line Tools ───────────────────────────────────────────────────
if ! xcode-select -p >/dev/null 2>&1; then
  yellow "[1] Xcode Command Line Tools not found — triggering install (a dialog may appear)…"
  xcode-select --install || true
  yellow "    Finish the install in the dialog, then re-run this script."
  exit 1
fi

# ── Homebrew ─────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  bold "[2] Homebrew not found — installing…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Add Homebrew to PATH for this shell session
if [[ -d "/opt/homebrew/bin" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -d "/usr/local/bin" ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
green "    Homebrew: $(brew --version | head -n1)"

# ── Node.js ──────────────────────────────────────────────────────────────
bold "[3] Node.js"
if command -v node >/dev/null 2>&1; then
  yellow "    Node found — upgrading (best effort)…"
  brew upgrade node || true
else
  yellow "    Installing Node…"
  brew install node
fi
green "    Node: $(node -v)"

# ── Bun ──────────────────────────────────────────────────────────────────
bold "[4] Bun"
if command -v bun >/dev/null 2>&1; then
  yellow "    Bun found — upgrading (best effort)…"
  brew upgrade bun || true
else
  yellow "    Installing Bun…"
  if ! brew install bun; then
    yellow "    Homebrew failed; using official installer…"
    curl -fsSL https://bun.sh/install | bash
  fi
fi
# Ensure PATH for bun in this process
if [[ -x "${BUN_BIN}/bun" ]]; then
  export PATH="${BUN_BIN}:$PATH"
fi
command -v bun >/dev/null 2>&1 || { red "    ERROR: bun not on PATH"; exit 1; }
green "    Bun: $(bun --version)"

# ── Git ──────────────────────────────────────────────────────────────────
bold "[5] Git"
if command -v git >/dev/null 2>&1; then
  yellow "    Git found — upgrading (best effort)…"
  brew upgrade git || true
else
  yellow "    Installing Git…"
  brew install git
fi
green "    $(git --version)"

# ── Repo (clone or pull) ─────────────────────────────────────────────────
bold "[6] Repository"
# If already inside the repo with same remote, use current dir
if [[ -d ".git" ]]; then
  CURR_REMOTE="$(git config --get remote.origin.url || true)"
  if [[ "$CURR_REMOTE" == "$REPO_URL" ]]; then
    TARGET_DIR="$(pwd)"
  fi
fi
printf "    Target: %s\n" "$TARGET_DIR"

if [[ -d "$TARGET_DIR/.git" ]]; then
  yellow "    Repo exists — pulling latest…"
  git -C "$TARGET_DIR" pull --ff-only
else
  yellow "    Cloning fresh copy…"
  git clone "$REPO_URL" "$TARGET_DIR"
fi

# ── bun install ──────────────────────────────────────────────────────────
bold "[7] Dependencies (bun install)"
pushd "$TARGET_DIR" >/dev/null
bun install

# ── .env prompting (required + optional) ─────────────────────────────────
ENV_FILE="$TARGET_DIR/.env"
[[ -f "$ENV_FILE" ]] || { yellow "[7.5] Creating .env"; : > "$ENV_FILE"; }

ensure_env() {
  # $1=KEY  $2=Prompt  $3=Example (optional)
  local key="$1" prompt="$2" example="${3:-}"
  local current
  current="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | sed -E "s/^${key}=//" || true)"
  if [[ -n "$current" ]]; then return 0; fi
  echo
  bold "    $prompt"
  [[ -n "$example" ]] && echo "    $example"
  local input=""
  while [[ -z "$input" ]]; do
    read -r -p "    > " input
    [[ -z "$input" ]] && echo "    (Required; please enter a value)"
  done
  tmp="${ENV_FILE}.tmp"
  { grep -Ev "^${key}=" "$ENV_FILE" 2>/dev/null || true; echo "${key}=${input}"; } > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

ensure_env_optional() {
  # $1=KEY  $2=Prompt  $3=Example (optional)
  local key="$1" prompt="$2" example="${3:-}"
  local current
  current="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | sed -E "s/^${key}=//" || true)"
  if [[ -n "$current" ]]; then return 0; fi
  echo
  bold "    $prompt"
  [[ -n "$example" ]] && echo "    $example"
  read -r -p "    (Leave blank if none) > " input || true
  tmp="${ENV_FILE}.tmp"
  { grep -Ev "^${key}=" "$ENV_FILE" 2>/dev/null || true; echo "${key}=${input}"; } > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

bold "[8] Configure .env (prompting only if missing)"
ensure_env "MYSQL_SOURCE"      "Enter MYSQL_SOURCE DSN"      "Example: user:pass@tcp(host:3306)/db?params"
ensure_env "MYSQL_DESTINATION" "Enter MYSQL_DESTINATION DSN" "Example: user:pass@tcp(host:3306)/db?params"
ensure_env_optional "EXCLUDE_TABLE" "Enter EXCLUDE_TABLE (comma-separated)" "Example: logs,temp_data"

# ── Run app ──────────────────────────────────────────────────────────────
bold "[9] Run app"
echo "    bun src/index.ts"
echo "    --------------------------------------------------------"
bun src/index.ts
code=$?
echo "    --------------------------------------------------------"
popd >/dev/null

if [[ $code -ne 0 ]]; then
  red "[X] App exited with code $code"
  exit "$code"
fi
green "[✔] Done. App finished successfully."
