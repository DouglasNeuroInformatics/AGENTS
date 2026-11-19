# === CODING AGENT WRAPPERS FOR ALTERNATIVE LLM ENDPOINTS ===
# Source this file from your shell rc (bash or zsh). Requires jq.
#
#   <agent>_wrapper <endpoint> [agent arguments...]
#   claude_wrapper chatdnp            codex_wrapper zai exec "message"
#   pi_wrapper zai --thinking low     opencode_wrapper chatdnp run "message"
#
# Endpoints are defined in endpoints.json next to this file: key variable, URL variables,
# the APIs that the endpoint serves, models, limits and effort levels. To add an endpoint,
# add an entry there. To add an agent, add an <agent>_wrapper function below that reads
# the loaded endpoint with _wrap_get.
#
# Each agent function body is ( ) not { }: the exports stay in a subshell.
# API keys are read from the environment. No key goes on a command line or into a file.
# Measured endpoint features are recorded in the "notes" of each endpoint.

_WRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)
_WRAP_ENDPOINTS="$_WRAP_DIR/endpoints.json"

# --- shared helpers ---

# Usage: _wrap_load <endpoint>
# Checks the endpoint and its variables, then sets WRAP_NAME, WRAP_KEY_ENV and WRAP_EP
# (the endpoint as JSON, with {env:VAR} expanded and main_model/fast_model added).
# URL variables lose a trailing / or /v1 and are exported.
_wrap_load() {
    local name=${1-} var val
    command -v jq >/dev/null 2>&1 || { echo "wrapper: jq is required" >&2; return 1; }
    if [ -z "$name" ] || ! jq -e --arg n "$name" 'has($n)' "$_WRAP_ENDPOINTS" >/dev/null; then
        echo "usage: <agent>_wrapper <endpoint> [agent arguments...]" >&2
        echo "endpoints:" >&2
        jq -r 'to_entries[] | "  \(.key)\t\(.value.description)  [APIs: \(.value.api | keys | join(", "))]"' \
            "$_WRAP_ENDPOINTS" >&2
        return 1
    fi
    WRAP_NAME=$name
    WRAP_KEY_ENV=$(jq -r --arg n "$name" '.[$n].key_env' "$_WRAP_ENDPOINTS")
    if [ -z "$(printenv "$WRAP_KEY_ENV")" ]; then
        echo "wrapper: $WRAP_KEY_ENV is not set (API key for $name)" >&2
        return 1
    fi
    for var in $(jq -r --arg n "$name" '.[$n].url_env // [] | .[]' "$_WRAP_ENDPOINTS"); do
        val=$(printenv "$var")
        if [ -z "$val" ]; then
            echo "wrapper: $var is not set (base URL for $name, without /v1)" >&2
            return 1
        fi
        val=${val%/}
        val=${val%/v1}
        export "$var=$val"
    done
    WRAP_EP=$(jq --arg n "$name" '
        .[$n]
        | walk(if type == "string"
               then gsub("\\{env:(?<v>[A-Za-z0-9_]+)\\}"; $ENV[.v] // "")
               else . end)
        | . as $e
        | .main_model = first($e.models[] | select(.id == $e.main))
        | .fast_model = first($e.models[] | select(.id == ($e.fast // $e.main)))' "$_WRAP_ENDPOINTS")
}

# Usage: _wrap_get [jq options] <jq filter>   (reads the endpoint loaded by _wrap_load)
_wrap_get() {
    printf '%s' "$WRAP_EP" | jq -r "$@"
}

# Usage: _wrap_need_api <agent> <api>  -> prints the API base URL, or explains and fails
_wrap_need_api() {
    local url
    url=$(_wrap_get --arg a "$2" '.api[$a] // empty')
    if [ -z "$url" ]; then
        echo "wrapper: $1 needs the $2 API, but endpoint $WRAP_NAME serves only:" \
            "$(_wrap_get '.api | keys | join(", ")')" >&2
        return 1
    fi
    printf '%s\n' "$url"
}

# --- Claude Code (Anthropic Messages API) ---
# Opus and Fable map to the endpoint's main model, Sonnet and Haiku to its fast model.
# The context window comes from CLAUDE_CODE_AUTO_COMPACT_WINDOW; no [1m] suffix is needed.
# Claude Code sends effort only to models that it knows, so CLAUDE_CODE_ALWAYS_ENABLE_EFFORT
# is set. maxEffortLevel clamps /effort to the highest level that the main model supports.
# Do not set MAX_THINKING_TOKENS: it switches off adaptive thinking.
claude_wrapper() (
    _wrap_load "${1-}" || exit 1
    shift
    url=$(_wrap_need_api claude anthropic) || exit 1
    main=$(_wrap_get '.main_model | .ids.anthropic // .id')
    fast=$(_wrap_get '.fast_model | .ids.anthropic // .id')
    unset ANTHROPIC_API_KEY
    export ANTHROPIC_BASE_URL="$url"
    ANTHROPIC_AUTH_TOKEN=$(printenv "$WRAP_KEY_ENV")
    export ANTHROPIC_AUTH_TOKEN
    export ANTHROPIC_MODEL="$main"
    export ANTHROPIC_DEFAULT_FABLE_MODEL="$main" ANTHROPIC_DEFAULT_OPUS_MODEL="$main"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$fast" ANTHROPIC_DEFAULT_HAIKU_MODEL="$fast"
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=$(_wrap_get '.main_model.context')
    CLAUDE_CODE_MAX_OUTPUT_TOKENS=$(_wrap_get '.main_model.max_output')
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_OUTPUT_TOKENS
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 # also turns off telemetry, error reports, autoupdater
    export API_TIMEOUT_MS=600000                      # long thinking turns can be slow to start
    settings=$(_wrap_get -c '.main_model.efforts as $e
        | {showThinkingSummaries: true, alwaysThinkingEnabled: true}
        + (if ($e | length) > 0
           then {effortLevel: (.main_model.default_effort // $e[-1]), maxEffortLevel: $e[-1]}
           else {} end)')
    if [ "$(_wrap_get '.main_model.efforts | length')" -gt 0 ]; then
        export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1
    fi
    command claude --settings "$settings" "$@"
)

# --- Codex (OpenAI Responses API) ---
# Codex needs a catalog entry for a model that it does not know, and an entry must contain
# base_instructions (the Codex system prompt). _codex_catalog builds the catalog at each
# launch from the endpoint's models. It copies the prompt from the first built-in model with
# the classic tool set (no tool_mode), so the prompt matches the installed Codex version.
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
        rm -f "$tmp"
        return 1
    fi
}

codex_wrapper() (
    _wrap_load "${1-}" || exit 1
    shift
    url=$(_wrap_need_api codex responses) || exit 1
    specs=$(_wrap_get -c '[.models[] | (.efforts | if length > 0 then . else ["medium"] end) as $l | {
        slug: (.ids.responses // .id), name, desc: .name, levels: $l,
        default: (.default_effort // $l[-1]), ctx: .context, input}]')
    cat=$(_codex_catalog "$WRAP_NAME" "$specs") || exit 1
    model=$(_wrap_get '.main_model | .ids.responses // .id')
    effort=$(_wrap_get '.main_model | .default_effort // .efforts[-1] // "medium"')
    command codex \
        -c model_provider="$WRAP_NAME" \
        -c "model_providers.$WRAP_NAME={name=\"$WRAP_NAME\", base_url=\"$url\", env_key=\"$WRAP_KEY_ENV\", wire_api=\"responses\"}" \
        -c model_catalog_json="\"$cat\"" \
        -c model="$model" \
        -c model_reasoning_effort="$effort" \
        -c web_search=disabled \
        -c check_for_update_on_startup=false \
        "$@"
)

# --- pi and omp (Anthropic Messages, Responses or Chat Completions API) ---
# harness/providers.ts registers the loaded endpoint as provider <endpoint> for this run.
# It uses the first API that the endpoint serves, in this order: anthropic, responses, chat.
# Switch models in the session with /model, for example zai/glm-5.3-flash for images.
_pi_like_wrapper() {
    local bin=$1 model effort
    shift
    model=$(_wrap_get '. as $e | .main_model
        | if $e.api.anthropic then .ids.anthropic // .id
          elif $e.api.responses then .ids.responses // .id
          else .ids.chat // .id end')
    effort=$(_wrap_get '.main_model | .default_effort // .efforts[-1] // empty')
    WRAP_ENDPOINT_JSON=$WRAP_EP
    export WRAP_ENDPOINT_JSON WRAP_NAME WRAP_KEY_ENV
    command "$bin" -e "$_WRAP_DIR/harness/providers.ts" --model "$WRAP_NAME/$model" \
        ${effort:+--thinking "$effort"} "$@"
}
pi_wrapper() (
    _wrap_load "${1-}" || exit 1
    shift
    _pi_like_wrapper pi "$@"
)
omp_wrapper() (
    _wrap_load "${1-}" || exit 1
    shift
    _pi_like_wrapper omp "$@"
)

# --- opencode (Anthropic Messages or Chat Completions API) ---
# The provider configuration is built from the endpoint and merged into your normal config
# through OPENCODE_CONFIG_CONTENT. The key stays a {env:VAR} reference.
# The provider ID is <endpoint>-wrap: a key saved with `opencode auth` for a built-in
# provider of the same name (for example zai) would replace the key from the environment.
# --standalone is required: the shared background service does not see these variables.
# Effort is a model variant: -m zai-wrap/glm-5.3#low, or cycle variants in the TUI.
# opencode2 is a shim that runs opencode, so this function covers it.
opencode_wrapper() (
    _wrap_load "${1-}" || exit 1
    shift
    OPENCODE_CONFIG_CONTENT=$(_wrap_get -c --arg id "$WRAP_NAME-wrap" --arg key "$WRAP_KEY_ENV" '
        def kind: if .api.anthropic then "anthropic" elif .api.chat then "chat" else null end;
        kind as $k
        | if $k == null then error("opencode needs the anthropic or chat API; endpoint serves: \(.api | keys | join(", "))") else . end
        | . as $e
        | def mid: if $k == "anthropic" then .ids.anthropic // .id else .ids.chat // .id end;
          def eff($l): if $k == "anthropic" then {effort: $l} else {reasoningEffort: $l} end;
        {model: ($id + "/" + ($e.main_model | mid)),
         small_model: ($id + "/" + ($e.fast_model | mid)),
         provider: {($id): {
            npm: (if $k == "anthropic" then "@ai-sdk/anthropic" else "@ai-sdk/openai-compatible" end),
            name: $e.description,
            options: {baseURL: (if $k == "anthropic" then $e.api.anthropic + "/v1" else $e.api.chat end),
                      apiKey: ("{env:" + $key + "}")},
            models: ([$e.models[] | {key: mid, value: (
                {name, limit: {context: .context, output: .max_output},
                 attachment: (.input | index("image") != null),
                 reasoning: ((.efforts | length) > 0)}
                + (if (.efforts | length) > 0 then
                     {options: ((if $k == "anthropic" then {thinking: {type: "adaptive"}} else {} end)
                                + eff(.default_effort // .efforts[-1])),
                      variants: ([.efforts[] | {key: ., value: eff(.)}] | from_entries)}
                   else {} end))}] | from_entries)}}}') || exit 1
    export OPENCODE_CONFIG_CONTENT
    if [ "${1-}" = run ]; then
        shift
        command opencode run --standalone "$@"
    else
        command opencode --standalone "$@"
    fi
)

# --- tab completion of endpoint names (bash) ---
if [ -n "${BASH_VERSION-}" ] && command -v complete >/dev/null 2>&1; then
    _wrap_complete() {
        if [ "$COMP_CWORD" -eq 1 ]; then
            mapfile -t COMPREPLY < <(compgen -W "$(jq -r 'keys[]' "$_WRAP_ENDPOINTS" 2>/dev/null)" -- "${COMP_WORDS[1]}")
        fi
    }
    complete -o default -F _wrap_complete claude_wrapper codex_wrapper pi_wrapper omp_wrapper opencode_wrapper
fi
