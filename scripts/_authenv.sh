# _authenv.sh — the ONE shell copy of the alternate-auth / routing / proxy / shell-injection
# env vars a Claude turn launched under account-bank isolation must NOT inherit. Mirrors
# isolated_refresh.py `_STRIP_ENV` (the Python canonical). Sourced by lib.sh (ping) and
# bin/claude (shim). Keep the two lists in sync.
#
# Why: a home is authoritative via its file-based OAuth credential. An inherited
# ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / Bedrock/Vertex routing var would make the turn
# authenticate/bill through THAT identity instead of the pinned home — defeating isolation
# (and, at seed time, verifying-and-publishing a home against the wrong billing identity).
# shellcheck shell=bash
ACCOUNT_BANK_AUTH_ENV_VARS="ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_DEFAULT_HEADERS \
ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
CLAUDE_CODE_API_KEY_HELPER AWS_BEARER_TOKEN_BEDROCK CLOUD_ML_REGION GOOGLE_APPLICATION_CREDENTIALS \
HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy BASH_ENV ENV CDPATH"

# _auth_env_u_args — print ` -u VAR` for each var, for use as `env $(_auth_env_u_args) <cmd>`.
_auth_env_u_args() {
    local v
    for v in $ACCOUNT_BANK_AUTH_ENV_VARS; do printf ' -u %s' "$v"; done
}

# strip_auth_env_exec <cmd> [args...] — exec <cmd> with the alt-auth vars removed. Any vars
# the caller intentionally set (CLAUDE_CONFIG_DIR, CLAUDE_ACCT_SHIM) are NOT in the list, so
# they pass through untouched.
strip_auth_env_exec() {
    exec /usr/bin/env $(_auth_env_u_args) "$@"
}
