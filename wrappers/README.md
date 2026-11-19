# Coding agent wrappers for alternative LLM endpoints

`wrapper.sh` defines shell functions that start a coding agent with an LLM endpoint other than its default. Each function sets the endpoint, the model, the context window and the reasoning effort for one run only. The functions do not change the configuration files of the agents.

## Endpoints

| Prefix | Endpoint | Models | Variables |
|---|---|---|---|
| `glm` | z.ai GLM Coding Plan | `glm-5.3` (text only), `glm-5.3-flash` (text and images) | `ZAI_API_KEY` |
| `chatdnp` | DNP LiteLLM proxy (internal network) | `Qwen3.8-Flash-Next` (text and images) | `CHATDNP_API_KEY`, `CHATDNP_BASE_URL` |

`CHATDNP_BASE_URL` is the base URL of the LiteLLM proxy, without `/v1`. Ask a DNP member for the value. The URL is not in these files because the repository is public.

For z.ai, use a Coding Plan key. z.ai keeps Coding Plan keys and standard API keys separate.

## Functions

| Agent | z.ai | chatdnp | Effort |
|---|---|---|---|
| Claude Code | `glm` | `chatdnp` | `/effort` |
| Codex | `glm_codex` | `chatdnp_codex` | `-c model_reasoning_effort=low` |
| pi | `glm_pi` | `chatdnp_pi` | `--thinking low` |
| omp (oh-my-pi) | `glm_omp` | `chatdnp_omp` | `--thinking low` |
| opencode | `glm_opencode` | `chatdnp_opencode` | `-m zai-wrap/glm-5.3#low` |

Supported effort levels: `low`, `high` and `max` for GLM; `low`, `medium` and `xhigh` for Qwen.

All arguments go to the agent. For example: `glm_codex exec "message"` or `chatdnp_opencode run "message"`.

## Install

1. Install the agents that you use. The Codex functions also need `jq`.
2. Set the variables in your environment. Do not write them into these files.
3. Add this line to `~/.bashrc` or `~/.zshrc`:

   ```bash
   source /path/to/wrappers/wrapper.sh
   ```

## Images

`glm-5.3` is text only. Claude Code with `glm` uses it by default, and z.ai drops images that you paste into the prompt. The model then invents a description. To work with screenshots or PDFs, select `glm-5.3-flash`:

- Claude Code: `/model sonnet` or `glm --model sonnet`
- Codex: `glm_codex -m glm-5.3-flash`
- pi and omp: `--model zai/glm-5.3-flash`
- opencode: `-m zai-wrap/glm-5.3-flash`

## How the keys are handled

The functions read the keys from your environment. No key goes on a command line, where other users of the computer could see it with `ps`, and no key goes in a file.

## Files

- `wrapper.sh`: the shell functions. Source it; do not run it.
- `harness/providers.ts`: the provider extension that pi and omp load with `-e`.
- `harness/opencode-*.json`: the provider configuration that opencode merges through `OPENCODE_CONFIG_CONTENT`.

The comments in `wrapper.sh` record the endpoint features that were measured and the reasons for each setting.
