// Provider extension for pi and omp (oh-my-pi), loaded per run with `-e` by
// pi_wrapper and omp_wrapper in ../wrapper.sh.
//
// The wrapper loads one endpoint from ../endpoints.json and passes it in the environment:
//   WRAP_NAME           endpoint name, used as the provider name
//   WRAP_KEY_ENV        name of the variable that holds the API key
//   WRAP_ENDPOINT_JSON  the endpoint, with {env:VAR} already expanded
//
// The key is passed as a literal value, because pi reads "$VAR" and omp reads "VAR" for
// environment references, and both accept a literal key.
//
// The first API that the endpoint serves is used, in this order:
//   anthropic -> anthropic-messages, responses -> openai-responses, chat -> openai-completions
//
// Effort levels are declared twice, once per harness:
// - pi:  thinkingLevelMap (null hides a level)
// - omp: thinking.efforts ("anthropic-adaptive" mode for Anthropic, "effort" mode otherwise)

type Effort = "low" | "medium" | "high" | "xhigh" | "max";
type Api = "anthropic" | "responses" | "chat";

interface EndpointModel {
	id: string;
	ids?: Partial<Record<Api, string>>;
	name: string;
	input: ("text" | "image")[];
	context: number;
	max_output: number;
	efforts: Effort[];
	default_effort?: Effort;
}

interface Endpoint {
	api: Partial<Record<Api, string>>;
	models: EndpointModel[];
}

const ALL: Effort[] = ["low", "medium", "high", "xhigh", "max"];
const WIRE: Record<Api, string> = {
	anthropic: "anthropic-messages",
	responses: "openai-responses",
	chat: "openai-completions",
};

function toModel(m: EndpointModel, api: Api) {
	const reasoning = m.efforts.length > 0;
	const out: Record<string, unknown> = {
		id: m.ids?.[api] ?? m.id,
		name: m.name,
		reasoning,
		input: m.input,
		contextWindow: m.context,
		maxTokens: m.max_output,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	};
	if (api === "anthropic") {
		// Send thinking.type "adaptive" with output_config.effort; keep empty signatures on replay.
		out.compat = { forceAdaptiveThinking: true, allowEmptySignature: true };
	} else if (reasoning) {
		// omp detects some model families (for example Kimi) and remaps effort levels, which
		// sent "high" for medium. The endpoint's levels are measured, so send them unchanged.
		out.compat = { reasoningEffortMap: Object.fromEntries(m.efforts.map(e => [e, e])) };
	}
	if (reasoning) {
		const map: Record<string, string | null> = { off: null, minimal: null };
		for (const level of ALL) map[level] = m.efforts.includes(level) ? level : null;
		out.thinkingLevelMap = map; // pi
		out.thinking = {
			mode: api === "anthropic" ? "anthropic-adaptive" : "effort",
			efforts: m.efforts,
			defaultLevel: m.default_effort ?? m.efforts[m.efforts.length - 1],
		}; // omp
	}
	return out;
}

export default function (pi: any) {
	const name = process.env.WRAP_NAME;
	const keyEnv = process.env.WRAP_KEY_ENV;
	const json = process.env.WRAP_ENDPOINT_JSON;
	if (!name || !keyEnv || !json) return; // not started by pi_wrapper or omp_wrapper
	const key = process.env[keyEnv];
	if (!key) return;

	const ep = JSON.parse(json) as Endpoint;
	const api = (["anthropic", "responses", "chat"] as Api[]).find(a => ep.api[a]);
	if (!api) throw new Error(`endpoint ${name} serves no API that pi or omp can use`);

	pi.registerProvider(name, {
		baseUrl: ep.api[api],
		apiKey: key,
		api: WIRE[api],
		models: ep.models.map(m => toModel(m, api)),
	});
}
