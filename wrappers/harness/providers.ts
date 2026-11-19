// Provider definitions for pi and omp (oh-my-pi), loaded per run with `-e`.
// Used by the glm_pi, chatdnp_pi, glm_omp and chatdnp_omp functions in ../wrapper.sh.
//
// Each provider is registered only when its variables are set (chatdnp also needs
// CHATDNP_BASE_URL, which the wrapper functions check and normalize). The key is passed as
// a literal value, because pi reads "$VAR" and omp reads "VAR" for environment
// references, and both accept a literal key.
//
// Both endpoints use the Anthropic Messages API (measured 2026-11-18/19):
// - z.ai: 1M context, max_tokens <= 131072, effort low/high/max, thinking cannot be
//   turned off. glm-5.3 is text-only (images are dropped); glm-5.3-flash is multimodal.
// - chatdnp (LiteLLM): 262144 context, effort low/medium/xhigh, empty thinking signatures.
//
// Effort levels are declared twice, once per harness:
// - pi:  thinkingLevelMap (null hides a level)
// - omp: thinking.efforts with mode "anthropic-adaptive"

type Effort = "low" | "medium" | "high" | "xhigh" | "max";

const ALL: Effort[] = ["low", "medium", "high", "xhigh", "max"];

function model(id: string, name: string, efforts: Effort[], input: string[], contextWindow: number, maxTokens: number) {
	const map: Record<string, string | null> = { off: null, minimal: null };
	for (const level of ALL) map[level] = efforts.includes(level) ? level : null;
	return {
		id,
		name,
		reasoning: true,
		input,
		contextWindow,
		maxTokens,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		// Send thinking.type "adaptive" with output_config.effort; keep empty signatures on replay.
		compat: { forceAdaptiveThinking: true, allowEmptySignature: true },
		thinkingLevelMap: map, // pi
		thinking: { mode: "anthropic-adaptive", efforts, defaultLevel: efforts[efforts.length - 1] }, // omp
	};
}

export default function (pi: any) {
	const zaiKey = process.env.ZAI_API_KEY;
	if (zaiKey) {
		pi.registerProvider("zai", {
			baseUrl: "https://api.z.ai/api/anthropic",
			apiKey: zaiKey,
			api: "anthropic-messages",
			models: [
				model("glm-5.3", "GLM-5.3", ["low", "high", "max"], ["text"], 1048576, 131072),
				model("glm-5.3-flash", "GLM-5.3-Flash", ["low", "high", "max"], ["text", "image"], 1048576, 131072),
			],
		});
	}

	const chatdnpKey = process.env.CHATDNP_API_KEY;
	const chatdnpUrl = process.env.CHATDNP_BASE_URL?.replace(/\/+$/, "").replace(/\/v1$/, "");
	if (chatdnpKey && chatdnpUrl) {
		pi.registerProvider("chatdnp", {
			baseUrl: chatdnpUrl,
			apiKey: chatdnpKey,
			api: "anthropic-messages",
			models: [
				model("Qwen3.8-Flash-Next-anthropic", "Qwen3.8-Flash-Next", ["low", "medium", "xhigh"], ["text", "image"], 262144, 65536),
			],
		});
	}
}
