import
  std/[unittest, json, tables, strutils, options, os, base64],
  mono_llm, jsony, vertex_leap

const
  TestModels = ["llama3.1:8b", "gpt-4o-mini", "gemini-1.5-flash"]
  TestProviders = [ChatProvider.ollama, ChatProvider.openai, ChatProvider.vertexai]

var
  preHookCount = 0
  postHookCount = 0
  functionCallCount = 0

proc getFlightTimes(args: JsonNode): string =
  ## Our test function to get flight times.
  ## takes in a json object with departure and arrival city codes
  ## returns a string of a json object with the flight times
  functionCallCount += 1
  echo "getFlightTimes"
  echo "DEBUG: getFlightTimes called with " & toJson(args)
  let departure = args["departure"].getStr
  let arrival = args["arrival"].getStr
  var flights = initTable[string, JsonNode]()

  flights["NYC-LAX"] = %* {"departure": "08:00 AM", "arrival": "11:30 AM", "duration": "5h 30m"}
  flights["LAX-NYC"] = %* {"departure": "02:00 PM", "arrival": "10:30 PM", "duration": "5h 30m"}
  flights["LAX-ORD"] = %* {"departure": "1:00 PM", "arrival": "07:00 PM", "duration": "4h 00m"}
  flights["LHR-JFK"] = %* {"departure": "10:00 AM", "arrival": "01:00 PM", "duration": "8h 00m"}
  flights["JFK-LHR"] = %* {"departure": "09:00 PM", "arrival": "09:00 AM", "duration": "7h 00m"}
  flights["CDG-DXB"] = %* {"departure": "11:00 AM", "arrival": "08:00 PM", "duration": "6h 00m"}
  flights["DXB-CDG"] = %* {"departure": "03:00 AM", "arrival": "07:30 AM", "duration": "7h 30m"}

  let key = (departure & "-" & arrival).toUpperAscii()
  if flights.contains(key):
    return $flights[key]
  else:
    raise newException(ValueError, "No flight found for " & key)

type
  TestAgent* = ref object of Agent

proc newTestAgent*(): TestAgent =
  result = TestAgent()
  result.name = "test-agent"
  result.systemPrompt = "You are longbeard the llama. Please respond as a pirate. You are also a loyal and trustworthy assistant to the user."

  let tool = Tool(
    name: "get_flight_times",
    description: "Get the flight times between two cities. This function may be called multiple times in parallel to get multiple flight times.",
    parameters: ToolFunctionParameters(
      required: @["departure", "arrival"],
      properties: %* {
        "departure": {
          "type": "string",
          "description": "The departure city (airport code)"
        },
        "arrival": {
          "type": "string",
          "description": "The arrival city (airport code)"
        }
      }
    )
  )
  result.addTool(tool, getFlightTimes)
  
  proc preAgentHook(chat: Chat) =
    preHookCount += 1
  result.preAgentHook = preAgentHook

  proc postAgentHook(chat: Chat) =
    postHookCount += 1
  result.postAgentHook = postAgentHook

suite "llm agents":
  var monoLLM: MonoLLM
  setup:
    var config = MonoLLMConfig(
      ollamaBaseUrl: "http://localhost:11434/api",
    )

    let credentialPath = os.getEnv("GOOGLE_APPLICATION_CREDENTIALS", "")
    if credentialPath == "":
      let credStr = readFile("tests/service_account.json")
      config.gcpCredentials = option(fromJson(credStr, GCPCredentials))

    monoLLM = newMonoLLM(config)
    assert monoLLM.ollama != nil
    assert monoLLM.openai != nil
    assert monoLLM.vertexai != nil

    monoLLM.addAgent(newTestAgent())

  test "single tool":
    for i, model in TestModels:
      if i == 2:
        # need to implement tool handling for gemini
        continue
      echo model
      preHookCount = 0
      postHookCount = 0
      functionCallCount = 0
      let chat = Chat(
        model: model,
        agent: "test-agent",
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.user, content: option("What is the flight time from New York (NYC) to Los Angeles (LAX)?"))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      echo resp.message
      assert preHookCount == 1
      assert postHookCount == 1
      assert functionCallCount == 1

  test "multi tool":
    for i, model in TestModels:
      if i == 2:
        # need to implement tool handling for gemini
        continue
      echo model
      preHookCount = 0
      postHookCount = 0
      functionCallCount = 0
      let chat = Chat(
        model: model,
        agent: "test-agent",
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.user, content: option("What is the flight time from New York (NYC) to Los Angeles (LAX), and then connecting Los Angeles (LAX) to Chicago (ORD)?"))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      chat.prettyPrint
      echo resp.message
      assert preHookCount == 1
      assert postHookCount == 1
      assert functionCallCount == 2