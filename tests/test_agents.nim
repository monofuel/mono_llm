import
  std/[unittest, strformat, json, tables, strutils, options, os, base64],
  mono_llm, jsony, openai_leap

const
  TestAgentName = "test-agent"
  TestModel = "gpt-4o-mini"
  TestAddress = "localhost"
  TestPort = 8086.uint16

var
  preHookCount = 0
  postHookCount = 0
  functionCallCount = 0
  serverThread: Thread[void]
  gateway: OpenAIGateway

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
  result.name = TestAgentName
  result.systemPrompt = "You are longbeard the llama. Please respond as a pirate. You are also a loyal and trustworthy assistant to the user."

  let tool = ToolFunction(
    name: "get_flight_times",
    description: option("Get the flight times between two cities. This function may be called multiple times in parallel to get multiple flight times."),
    parameters: option(%*{
      "required": @["departure", "arrival"],
      "properties": {
        "departure": {
          "type": "string",
          "description": "The departure city (airport code)"
        },
        "arrival": {
          "type": "string",
          "description": "The arrival city (airport code)"
        }
      }
    })
  )
  result.addTool(tool, getFlightTimes)
  
  proc preAgentHook(req: JsonNode) =
    preHookCount += 1
  result.preAgentHook = preAgentHook

  proc postAgentHook(req: JsonNode, resp: JsonNode) =
    postHookCount += 1
  result.postAgentHook = postAgentHook

suite "llm agents":
  var openAI: OpenAiApi
  setup:
    openAI = newOpenAiApi(&"http://{TestAddress}:{TestPort}")

    gateway = newOpenAIGateway(
      "https://api.openai.com/v1",
      TestAddress,
      TestPort,
    )

    gateway.addAgent(newTestAgent())

    proc startGateway() {.thread.} =
      {.gcsafe.}:
        gateway.start()

    createThread(serverThread, startGateway)
    # HACK wait for the server to start
    sleep(1000)

  test "single tool":
    echo TestModel
    preHookCount = 0
    postHookCount = 0
    functionCallCount = 0
    let chat = CreateChatCompletionReq(
      model: TestAgentName & "/" & TestModel,
      messages: @[
        Message(
          role: "user", content: option(@[MessageContentPart(
            `type`: "text",
            text: option("What is the flight time from New York (NYC) to Los Angeles (LAX)?")
          )])
        )
      ],
    )
    let resp = openAI.createChatCompletion(chat)
    echo resp.choices[0].message.get.content
    assert preHookCount == 1
    assert postHookCount == 1
    assert functionCallCount == 1

  test "multi tool":
    preHookCount = 0
    postHookCount = 0
    functionCallCount = 0
    let chat = CreateChatCompletionReq(
      model: TestAgentName & "/" & TestModel,
      messages: @[
        Message(
          role: "user", content: option(@[MessageContentPart(
            `type`: "text",
            text: option("What is the flight time from New York (NYC) to Los Angeles (LAX), and then connecting Los Angeles (LAX) to Chicago (ORD)?")
          )])
        )
      ],
    )
    let resp = openAI.createChatCompletion(chat)
    echo resp.choices[0].message.get.content
    assert preHookCount == 1
    assert postHookCount == 1
    assert functionCallCount == 2