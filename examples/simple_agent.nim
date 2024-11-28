import std/[json, options], mono_llm

# Simple agent example for mono_llm
# agents can be called with any model, like "test-agent/gpt-4o-mini" or "test-agent/gpt-4o"

const 
  TestAgentName = "test-agent"

let
  endpoint = "https://api.openai.com/v1"
  address = "localhost"
  port = 8090.uint16
  logFile = "gateway.log"

let gateway = newOpenAIGateway(
  endpoint,
  address,
  port,
  logFile
)

proc neurotoxinInjector*(args: JsonNode): string =
  let enabled = args["enabled"].getBool
  if enabled:
    result = "neurotoxin release mechanism enabled"
  else:
    result = "neurotoxin release mechanism disabled"
  echo result

type
  TestAgent* = ref object of Agent

proc newTestAgent*(): TestAgent =
  result = TestAgent()
  result.name = TestAgentName
  result.systemPrompt = "You are longbeard the llama. Please respond as a pirate. You are also a loyal and trustworthy assistant to the user."

  let tool = ToolFunction(
    name: "neurotoxin_injector",
    description: option("Toggle the neurotoxin release mechanism in the facility"),
    parameters: option(%*{
      "type": "object",
      "required": @["enabled"],
      "properties": {
        "enabled": {
          "type": "boolean",
          "description": "Whether to enable the neurotoxin release mechanism"
        },
      }
    })
  )
  result.addTool(tool, neurotoxinInjector)
  
  proc preAgentHook(req: JsonNode) =
    echo "preAgentHook"
  result.preAgentHook = preAgentHook

  proc postAgentHook(req: JsonNode, resp: JsonNode) =
    echo "postAgentHook"
  result.postAgentHook = postAgentHook


gateway.addAgent(newTestAgent())

gateway.start()