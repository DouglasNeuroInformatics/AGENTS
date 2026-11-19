# Coding agent wrappers for alternative LLM endpoints

`wrapper.sh` defines one shell function per coding agent. Each function starts the agent with an LLM endpoint other than its default:

```bash
<agent>_wrapper <endpoint> [agent arguments...]

claude_wrapper chatdnp
codex_wrapper zai exec "message"
pi_wrapper nim --thinking low
opencode_wrapper chatdnp run "message"
```

The function sets the endpoint, the models, the context window and the reasoning effort for that one run. It does not change the configuration files of the agent. Run a function with no endpoint to see the list of endpoints.

## Endpoints

The endpoints are defined in `endpoints.json`.

| Endpoint | Service | Main model | Fast model | Variables |
|---|---|---|---|---|
| `zai` | z.ai GLM Coding Plan | `glm-5.3` (text only) | `glm-5.3-flash` | `ZAI_API_KEY` |
| `chatdnp` | DNP LiteLLM proxy (internal network) | `Qwen3.8-Flash-Next` | (same) | `CHATDNP_API_KEY`, `CHATDNP_BASE_URL` |
| `nim` | NVIDIA NIM hosted API | `moonshotai/kimi-k3.1-pro` | `nvidia/nemotron-3.5-super-vl-120b-a12b` | `NVIDIA_API_KEY` |

- For `zai`, use a Coding Plan key. z.ai keeps Coding Plan keys and standard API keys separate.
- `CHATDNP_BASE_URL` is the base URL of the LiteLLM proxy, without `/v1`. Ask a DNP member for the value. The URL is not in these files because the repository is public.

## Agents

Each agent can use an endpoint only if the endpoint serves an API that the agent speaks:

| Function | Agent | API used | `zai` | `chatdnp` | `nim` |
|---|---|---|---|---|---|
| `claude_wrapper` | Claude Code | Anthropic Messages | ✅ | ✅ | ❌ |
| `codex_wrapper` | Codex | OpenAI Responses | ✅ | ✅ | ❌ |
| `pi_wrapper` | pi | first of: Anthropic, Responses, Chat Completions | ✅ | ✅ | ✅ |
| `omp_wrapper` | omp (oh-my-pi) | first of: Anthropic, Responses, Chat Completions | ✅ | ✅ | ✅ |
| `opencode_wrapper` | opencode (and opencode2) | first of: Anthropic, Chat Completions | ✅ | ✅ | ✅ |

The hosted NIM API serves only Chat Completions. If you use an endpoint that an agent cannot speak, the function stops and tells you which APIs the endpoint serves.

## Reasoning effort

The functions start each model at its highest supported effort level. To change it:

| Agent | Example |
|---|---|
| Claude Code | `/effort low`, or `--effort low` |
| Codex | `-c model_reasoning_effort=low` |
| pi, omp | `--thinking low` |
| opencode | `-m zai-wrap/glm-5.3#low`, or switch variants in the interface |

The supported levels of each model are in `endpoints.json`. The functions hide the other levels, or clamp them to a supported level.

## Install

1. Install `jq` and the agents that you use.
2. Set the variables in your environment. Do not write them into these files.
3. Add this line to `~/.bashrc` or `~/.zshrc`:

   ```bash
   source /path/to/wrappers/wrapper.sh
   ```

In bash, the Tab key completes endpoint names.

## Images

`zai/glm-5.3` is text only. z.ai drops images that you paste into the prompt, and the model then invents a description. For screenshots or PDFs with `zai`, select `glm-5.3-flash`:

- Claude Code: `/model sonnet`, or `claude_wrapper zai --model sonnet`
- Codex: `codex_wrapper zai -m glm-5.3-flash`
- pi and omp: `--model zai/glm-5.3-flash`
- opencode: `-m zai-wrap/glm-5.3-flash`

The `chatdnp` and `nim` models accept images.

## Add an endpoint

Add an entry to `endpoints.json`:

```json
"myendpoint": {
  "description": "Short description",
  "key_env": "MYENDPOINT_API_KEY",
  "url_env": ["MYENDPOINT_BASE_URL"],
  "api": {
    "anthropic": "{env:MYENDPOINT_BASE_URL}",
    "responses": "{env:MYENDPOINT_BASE_URL}/v1",
    "chat": "{env:MYENDPOINT_BASE_URL}/v1"
  },
  "main": "model-a",
  "fast": "model-b",
  "models": [
    {
      "id": "model-a",
      "ids": { "anthropic": "model-a-anthropic" },
      "name": "Model A",
      "input": ["text", "image"],
      "context": 262144,
      "max_output": 65536,
      "efforts": ["low", "medium", "high"]
    }
  ],
  "notes": ["What you measured, and when."]
}
```

| Field | Meaning |
|---|---|
| `key_env` | The variable that holds the API key. |
| `url_env` | Optional. Variables that hold URLs. A trailing `/` or `/v1` is removed, and `{env:VAR}` in any string is replaced by the value. |
| `api` | The base URL of each API that the endpoint serves. Give only the APIs that work. `anthropic` is without `/v1`. `responses` and `chat` include `/v1`. |
| `main`, `fast` | Model IDs. Claude Code uses `fast` for Sonnet and Haiku, and opencode uses it for background tasks. |
| `ids` | Optional. A different model ID for one API, for example when a proxy has a separate model name for the Anthropic API. |
| `efforts` | The effort levels that the model accepts, from `low`, `medium`, `high`, `xhigh` and `max`, in this order. The last one is the default. Use `[]` when effort has no effect. |

Measure before you add an entry: check which API paths respond, the context and output limits, which effort values the endpoint accepts, and whether images work.

## Add an agent

Add an `<agent>_wrapper` function to `wrapper.sh`. Call `_wrap_load "$1"` first. Then read the endpoint with `_wrap_get '<jq filter>'`, and get the URL of the API that the agent needs with `_wrap_need_api <agent> <api>`.

## How the keys are handled

The functions read the keys from your environment. No key goes on a command line, where other users of the computer could see it with `ps`, and no key goes in a file.

## Files

- `wrapper.sh`: the shell functions. Source it; do not run it.
- `endpoints.json`: the endpoints, models, limits and the measured notes.
- `harness/providers.ts`: the provider extension that pi and omp load with `-e`.

The Codex function writes its model catalog to `~/.cache/claude-wrap/` at each launch.
