# === CLAUDE CODE MULTI-PROVIDER SWITCHER ===
# Source this file from your shell rc. Assumes 'claude' is in your PATH.
# https://gist.github.com/spideynolove/13785891385ed6916619ebb991b490b9
# Each function body is ( ) not { }: the exports stay in a subshell and do not leak into your shell.
# Feature notes below were measured against each endpoint on 2026-11-18 (Claude Code 2.1.327).

# Settings shared by every non-Anthropic endpoint.
_claude_thirdparty_common() {
    unset ANTHROPIC_API_KEY
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 # also turns off telemetry, error reports, autoupdater
    export API_TIMEOUT_MS=600000                      # long thinking turns can be slow to start
}

# chatdnp settings shared by every agent. The URL comes from CHATDNP_BASE_URL, so the
# internal host name is not in these files. Set it to the LiteLLM base URL without /v1;
# a trailing / or /v1 is removed. Call it only inside a ( ) function body: when a
# variable is not set, it stops that subshell.
_chatdnp_env() {
    : "${CHATDNP_API_KEY:?CHATDNP_API_KEY is not set}"
    : "${CHATDNP_BASE_URL:?CHATDNP_BASE_URL is not set (the LiteLLM base URL, without /v1)}"
    CHATDNP_BASE_URL=${CHATDNP_BASE_URL%/}
    CHATDNP_BASE_URL=${CHATDNP_BASE_URL%/v1}
    export CHATDNP_BASE_URL
}

# --- z.ai (GLM) Coding Plan ---
# Usage: glm
# Measured: 1M context, max_tokens capped at 131072, output_config.effort honoured
# (low/high/max; Claude Code levels map onto them), thinking cannot be disabled,
# prompt caching is implicit and works (cache reads seen in real sessions). GLM-5.3-FlashX is not on the plan.
# The [1m] suffix makes Claude Code use a 1M window; it is removed before the request is sent.
# Vision: glm-5.3 (opus/fable, the default) is text-only. It cannot read PDFs, and z.ai silently
# drops images pasted into the prompt, so the model invents a description. Images that the Read
# tool returns do work. glm-5.3-flash (sonnet/haiku) is multimodal: for screenshots or PDFs,
# run /model sonnet or start with: glm --model sonnet
glm() (
    : "${ZAI_API_KEY:?ZAI_API_KEY is not set}"
    _claude_thirdparty_common
    export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
    export ANTHROPIC_AUTH_TOKEN="${ZAI_API_KEY}"
    export ANTHROPIC_DEFAULT_FABLE_MODEL="glm-5.3[1m]"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.3[1m]"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.3-flash[1m]"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5.3-flash[1m]"
    export ANTHROPIC_MODEL="opus"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS=131072
    export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 # send /effort to GLM; z.ai default is max
    command claude --settings '{"showThinkingSummaries": true, "alwaysThinkingEnabled": true}' "$@"
)

# --- chatdnp (internal LiteLLM proxy) ---
# Usage: chatdnp
# Measured: 262144 context and max_tokens, cache_control honoured (cache reads reported),
# thinking on by default, adaptive thinking accepted, unknown betas accepted.
# The model supports effort low/medium/xhigh. LiteLLM validates output_config.effort
# (minimal/low/medium/high/xhigh/max/none) and forwards it. maxEffortLevel clamps
# /effort max down to xhigh; effortLevel is the start level and /effort can still change it.
# Do not set MAX_THINKING_TOKENS: it switches off adaptive thinking.
chatdnp() (
    _chatdnp_env
    m=Qwen3.8-Flash-Next-anthropic
    _claude_thirdparty_common
    export ANTHROPIC_BASE_URL="$CHATDNP_BASE_URL"
    export ANTHROPIC_AUTH_TOKEN="${CHATDNP_API_KEY}"
    export ANTHROPIC_MODEL=$m
    export ANTHROPIC_DEFAULT_FABLE_MODEL=$m
    export ANTHROPIC_DEFAULT_OPUS_MODEL=$m
    export ANTHROPIC_DEFAULT_SONNET_MODEL=$m
    export ANTHROPIC_DEFAULT_HAIKU_MODEL=$m
    export CLAUDE_CODE_SUBAGENT_MODEL=$m
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW=262144
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS=65536
    export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 # model ID is unknown to Claude Code, so force effort on
    command claude --settings '{"showThinkingSummaries": true, "alwaysThinkingEnabled": true, "effortLevel": "xhigh", "maxEffortLevel": "xhigh"}' "$@"
)

# === CODEX CLI WRAPPERS ===
# Both endpoints serve the OpenAI Responses API that Codex needs (wire_api="responses").
# Codex needs a catalog entry for a model that it does not know. An entry must contain
# base_instructions (the Codex system prompt). _codex_catalog builds the catalog at each launch.
# It copies the prompt from the first built-in model that uses the classic tool set
# (no tool_mode), so the prompt always matches the installed Codex version. Requires jq.
# The -c overrides do not change ~/.codex/config.toml.

# Usage: _codex_catalog <name> <jq array of model specs>  -> prints the path of the catalog file
_codex_catalog() {
    local dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-wrap" out tmp
    out="$dir/codex-$1.models.json"
    mkdir -p "$dir" && tmp=$(mktemp "$dir/.codex-$1.XXXXXX") || return 1
    if command codex debug models | jq --argjson specs "$2" '
        ([.models[] | select(has("tool_mode") | not) | select(.base_instructions)][0]
            // error("no built-in Codex model with the classic tool set; update _codex_catalog")) as $ref
        | ($ref.base_instructions | sub("a coding agent based on GPT-[0-9]+(\\.[0-9]+)*"; "a coding agent")) as $prompt
        | {low: "Fast responses with lighter reasoning", medium: "Balanced speed and reasoning depth",
           high: "Deeper reasoning for complex problems", xhigh: "Extra-deep reasoning for the hardest problems",
           max: "Maximum reasoning depth"} as $desc
        | {models: [$specs | to_entries[] | .key as $i | .value | {
            slug, display_name: .name, description: .desc,
            default_reasoning_level: .default,
            supported_reasoning_levels: [.levels[] | {effort: ., description: $desc[.]}],
            shell_type: "unified_exec", visibility: "list", supported_in_api: true, priority: ($i + 1),
            support_verbosity: false, truncation_policy: {mode: "tokens", limit: 10000},
            experimental_supported_tools: [], context_window: .ctx, max_context_window: .ctx,
            effective_context_window_percent: 95, input_modalities: .input,
            base_instructions: $prompt}]}' >"$tmp"; then
        mv -f "$tmp" "$out" && printf '%s\n' "$out"
    else
        rm -f "$tmp"; return 1
    fi
}

# Usage: _codex_run <provider id> <base_url> <key env var> <catalog> <model> <effort> [codex args...]
_codex_run() {
    local id=$1 url=$2 key=$3 cat=$4 model=$5 effort=$6
    shift 6
    command codex \
        -c model_provider="$id" \
        -c "model_providers.$id={name=\"$id\", base_url=\"$url\", env_key=\"$key\", wire_api=\"responses\"}" \
        -c model_catalog_json="\"$cat\"" \
        -c model="$model" \
        -c model_reasoning_effort="$effort" \
        -c web_search=disabled \
        -c check_for_update_on_startup=false \
        "$@"
}

# --- z.ai (GLM) Coding Plan, Responses API at /api/v1 (not /api/anthropic or /paas/v4) ---
# Usage: glm_codex [codex args...]    for images: glm_codex -m glm-5.3-flash
# glm-5.3 is text-only. Effort levels: low/high/max (z.ai default max).
glm_codex() (
    : "${ZAI_API_KEY:?ZAI_API_KEY is not set}"
    cat=$(_codex_catalog zai '[
        {"slug": "glm-5.3", "name": "GLM-5.3", "desc": "z.ai GLM-5.3, text only",
         "levels": ["low", "high", "max"], "default": "max", "ctx": 1048576, "input": ["text"]},
        {"slug": "glm-5.3-flash", "name": "GLM-5.3-Flash", "desc": "z.ai GLM-5.3-Flash, multimodal",
         "levels": ["low", "high", "max"], "default": "max", "ctx": 1048576, "input": ["text", "image"]}
    ]') || exit 1
    _codex_run zai https://api.z.ai/api/v1 ZAI_API_KEY "$cat" glm-5.3 max "$@"
)

# --- chatdnp (internal LiteLLM proxy), Responses API at /v1 ---
# Usage: chatdnp_codex [codex args...]
# Uses the Qwen3.8-Flash-Next model group (the -anthropic group is for the Messages API).
# Effort levels: low/medium/xhigh.
chatdnp_codex() (
    _chatdnp_env
    cat=$(_codex_catalog chatdnp '[
        {"slug": "Qwen3.8-Flash-Next", "name": "Qwen3.8-Flash-Next", "desc": "chatdnp Qwen3.8-Flash-Next",
         "levels": ["low", "medium", "xhigh"], "default": "xhigh", "ctx": 262144, "input": ["text", "image"]}
    ]') || exit 1
    _codex_run chatdnp "$CHATDNP_BASE_URL/v1" CHATDNP_API_KEY "$cat" \
        Qwen3.8-Flash-Next xhigh "$@"
)

# === PI, OMP AND OPENCODE WRAPPERS ===
# Provider definitions are in harness/ next to this file. These functions do not change
# ~/.pi, ~/.omp or ~/.config/opencode. Your settings, sessions, skills, MCP servers and
# plugins still load. All four functions use the Anthropic Messages API on both endpoints.
# opencode2 is a shim that runs opencode, so the opencode functions cover it.
_CLAUDE_WRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)

# --- pi and omp ---
# harness/providers.ts registers the zai and chatdnp providers for each run (-e).
# Switch models in the session with /model, for example zai/glm-5.3-flash for images.
# Effort: --thinking low|high|max (GLM) or low|medium|xhigh (Qwen).
glm_pi() (
    : "${ZAI_API_KEY:?ZAI_API_KEY is not set}"
    command pi -e "$_CLAUDE_WRAP_DIR/harness/providers.ts" --model zai/glm-5.3 --thinking max "$@"
)
chatdnp_pi() (
    _chatdnp_env
    command pi -e "$_CLAUDE_WRAP_DIR/harness/providers.ts" \
        --model chatdnp/Qwen3.8-Flash-Next-anthropic --thinking xhigh "$@"
)
glm_omp() (
    : "${ZAI_API_KEY:?ZAI_API_KEY is not set}"
    command omp -e "$_CLAUDE_WRAP_DIR/harness/providers.ts" --model zai/glm-5.3 --thinking max "$@"
)
chatdnp_omp() (
    _chatdnp_env
    command omp -e "$_CLAUDE_WRAP_DIR/harness/providers.ts" \
        --model chatdnp/Qwen3.8-Flash-Next-anthropic --thinking xhigh "$@"
)

# --- opencode ---
# OPENCODE_CONFIG_CONTENT merges harness/opencode-<provider>.json into your normal config.
# --standalone is required: the shared background service does not see these variables.
# The z.ai provider ID is zai-wrap, not zai: a key saved with `opencode auth` for the
# built-in Z.AI provider would replace the key from ZAI_API_KEY.
# Effort is a model variant: -m zai-wrap/glm-5.3#low, or cycle variants in the TUI.
# For images with GLM: -m zai-wrap/glm-5.3-flash
# Usage: glm_opencode [args]   or   glm_opencode run [flags] "message"
_opencode_run() {
    local cfg=$1
    shift
    OPENCODE_CONFIG_CONTENT=$(<"$_CLAUDE_WRAP_DIR/harness/opencode-$cfg.json") || return 1
    export OPENCODE_CONFIG_CONTENT
    if [ "${1-}" = run ]; then
        shift
        command opencode run --standalone "$@"
    else
        command opencode --standalone "$@"
    fi
}
glm_opencode() (
    : "${ZAI_API_KEY:?ZAI_API_KEY is not set}"
    _opencode_run zai "$@"
)
chatdnp_opencode() (
    _chatdnp_env
    _opencode_run chatdnp "$@"
)
