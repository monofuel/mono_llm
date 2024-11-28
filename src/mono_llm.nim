import std/[strformat, options, tables, json, parseopt, envvars, strutils],
  curly, jsony, mummy, mummy/routers, openai_leap

## OpenAI Compatible Gateway
## 
## This module provides a gateway to forward requests to an OpenAI compatible endpoint.
## Compiling and executing the gateway directly will give a simple proxy server that forwards requests to the OpenAI endpoint.
## The OpenAIGateway object can be extended for custom request handling.
##
## Use 'http://localhost:11434/v1' for local ollama endpoint.
## Use 'https://api.openai.com/v1' for official openai endpoint.
## 
## This gateway does not handle authorization. clients must provide a bearer token in the Authorization header.

export openai_leap.ToolFunction

type
  ToolImpl* = proc (args: JsonNode): string {.gcsafe.}
  PreHook* = proc (req: JsonNode) {.gcsafe.}
  PostHook* = proc (req: JsonNode, resp: JsonNode) {.gcsafe.}
  Agent* = ref object of RootObj
    name*: string
    systemPrompt*: string                 # default system prompt if not set in request
    overrideSystemPrompt*: bool           # whether to override the system prompt if set in request
    appendSystemPrompt*: bool             # whether to append the system prompt if set in request
    tools: seq[openai_leap.ToolFunction]  # Tool name to Tool API spec
    toolFns: Table[string, ToolImpl]      # Tool name to actual procedure
    preAgentHook*: PreHook                # Any logic to append a RAG to the system prompt can happen here
    postAgentHook*: PostHook              # any follow up logic like saving memories
  OpenAIGateway* = ref object
    openAI*: OpenAiApi
    agents*: Table[string, Agent]
    endpoint: string                      # OpenAI compatible endpoint to forward requests to
    address: string                       # Address to bind the gateway to
    port: uint16                          # Port to bind the gateway to
    logFile: string
  ApiGatewayError* = object of CatchableError

proc addAgent*(gw: OpenAIGateway, agent: Agent) = 
  gw.agents[agent.name] = agent

proc addTool*(agent: Agent, tool: openai_leap.ToolFunction, fn: ToolImpl) =
  agent.tools.add(tool)
  agent.toolFns[tool.name] = fn

proc newOpenAIGateway*(
  endpoint: string,
  address: string = "localhost",
  port: uint16 = 8085,
  logFile = ""
): OpenAIGateway =
  result = OpenAIGateway(
    endpoint: endpoint,
    address: address,
    port: port,
    logFile: logFile
  )
  # Ensure we do not accidentally use a local API key
  delEnv("OPENAI_API_KEY")
  result.openAI = newOpenAiApi(
    endpoint,
  )

proc logRequest(gateway: OpenAIGateway, req: Request, resp: Response) =
  if gateway.logFile == "":
    return
  var logBlock = &"""
# Req {req.httpMethod} {req.path}
{req.headers}
---
{req.body}
# Resp {resp.code}
{resp.headers}
---
{resp.body}
"""
  let file = open(gateway.logFile, fmAppend)
  file.write(logBlock)
  file.close()

proc healthHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "OK")

proc start*(gateway: OpenAIGateway) =
  echo "Starting OpenAI Gateway"
  var router: Router
  let openAI = gateway.openAI

  # API handlers
  proc notFoundHandler(request: Request) =
    # if route not found, assume it's a valid request and forward to OpenAI
    echo &"UNHANDLED PROXY REQUEST: {request.httpMethod} {request.path}"
    var headers: Httpheaders
    if request.headers["Authorization"] == "":
      request.respond(401, headers, "Unauthorized")

    var bearerToken = request.headers["Authorization"]
    bearerToken.removePrefix("Bearer ")
    let organization = request.headers["Organization"]

    # TODO why do I have to do this? is mummy not handling gzip correctly or is open-webui not handling it correctly?
    request.headers["Accept-Encoding"] = ""

    if request.httpMethod == "GET":
      let resp = openAI.get(request.path, Opts(bearerToken: bearerToken, organization: organization))
      request.respond(resp.code, resp.headers, resp.body)
      echo &"UNHANDLED PROXY RESPONSE: {request.httpMethod} {request.path} {resp.code}"
      gateway.logRequest(request, resp)
    elif request.httpMethod == "POST":
      let resp = openAI.post(request.path, request.body, Opts(bearerToken: bearerToken, organization: organization))
      request.respond(resp.code, resp.headers, resp.body)
      echo &"UNHANDLED PROXY RESPONSE: {request.httpMethod} {request.path} {resp.code}"
      gateway.logRequest(request, resp)
    else:
      request.respond(404, headers, "Method Not found")

  proc modelHandler(request: Request) =
    ## proxy GET /models
    echo &"{request.httpMethod} {request.path}"
    var headers: Httpheaders
    if request.headers["Authorization"] == "":
      request.respond(401, headers, "Unauthorized")

    var bearerToken = request.headers["Authorization"]
    bearerToken.removePrefix("Bearer ")
    let organization = request.headers["Organization"]
    let resp = openAI.get("/models", Opts(bearerToken: bearerToken, organization: organization))

    request.headers["Accept-Encoding"] = ""
    request.respond(resp.code, resp.headers, resp.body)
    gateway.logRequest(request, resp)

  proc chatHandler(request: Request) {.gcsafe.} =
    ## proxy POST /chat/completions
    echo &"{request.httpMethod} {request.path}"
    var headers: HttpHeaders
    if request.headers["Authorization"] == "":
      request.respond(401, headers, "Unauthorized")

    var bearerToken = request.headers["Authorization"]
    bearerToken.removePrefix("Bearer ")
    let organization = request.headers["Organization"]

    request.headers["Accept-Encoding"] = ""

    let reqJson = fromJson(request.body)

    # insert our agent logic
    if not reqJson.hasKey("model"):
      raise newException(ApiGatewayError, "Model not specified")
    var agentName = ""
    var modelName = ""
    let fullModelName = reqJson["model"].str
    if fullModelName.contains("/"):
      agentName = fullModelName.split("/")[0]
      modelName = fullModelName.split("/")[1]
    else:
      modelname = fullModelName

    reqJson["model"] = %modelName

    var agent: Agent
    if agentName != "":
      agent = gateway.agents[agentName]

      if agent.systemPrompt != "":
        if not reqJson.hasKey("messages") or reqJson["messages"].len == 0:
          raise newException(ApiGatewayError, "Messages not specified")
        
        # check if the first message is the system prompt
        let firstMessage = reqJson["messages"][0]
        if firstMessage["role"].str == "system":
          if agent.overrideSystemPrompt:
            # override the system prompt
            firstMessage["content"] = %agent.systemPrompt
          elif agent.appendSystemPrompt:
            # append the system prompt
            if firstMessage["content"].kind == JString:
              # if content is a string, simply append the system prompt
              firstMessage["content"] &= %agent.systemPrompt
            else:
              # otherwise it will be an array of content parts text, image or audio
              if firstMessage["content"].kind != JArray:
                raise newException(ApiGatewayError, "Unsupported message content")
              # TODO I wonder if it's possible to include images or audio in the system prompt?
              let contentPart = firstMessage["content"][0]
              contentPart["text"] = %(contentPart["text"].str & agent.systemPrompt)
        else:
          # insert our special system prompt as the first message
          let promptMsg = %*{
            "role": "system",
            "content": agent.systemPrompt
          }
          var messages = reqJson["messages"].getElems
          messages.insert(promptMsg,0)
          reqJson["messages"] = %messages

      # inject tool calling
      var tools: seq[JsonNode]
      if  reqJson.hasKey("tools"):
        tools = reqJson["tools"].getElems
      for tool in agent.tools:
        tools.add(%*{
          "type": "function",
          "function": %tool,
        })
      if tools.len > 0:
        reqJson["tools"] = %tools

      if agent.preAgentHook != nil:
        agent.preAgentHook(reqJson)

    # streaming
    # TODO figure this out
    #if reqJson.hasKey("stream") and reqJson["stream"].getBool:
    # let stream = openAI.postStream(api, "/chat/completions", reqBody, Opts(bearerToken: bearerToken, organization: organization))
    # send the headers
    # openai headers will include:
    # Content-Type: text/event-stream; charset=utf-8
    # Transfer-Encoding: chunked
    # request.respond(resp.code, resp.headers)
    #else:

    # not streaming
    var respStr = ""
    var resp: Response
    var toolbatch: seq[ToolResp]
    while true:
      toolbatch = @[]
      resp = openAI.post("/chat/completions", toJson(reqJson), Opts(bearerToken: bearerToken, organization: organization))
      gateway.logRequest(request, resp)
      # handle the tool calls that the gateway agent added
      # TODO handle tools provided by the client, not just from the gateway
      let respMessage = fromJson(resp.body, openai_leap.CreateChatCompletionResp)
      if respMessage.choices[0].message.isNone:
        # TODO support respMessage.delta
        raise newException(ApiGatewayError, "No message in response")

      if respMessage.choices[0].message.get.tool_calls.isSome:
        toolbatch = respMessage.choices[0].message.get.tool_calls.get

      var messages = reqJson["messages"].getElems
      if respStr != "":
        respStr &= "\n"
      respStr &= respMessage.choices[0].message.get.content
      messages.add(%openai_leap.Message(
        role: "assistant",
        tool_calls: option(toolbatch),
        content: option(
          @[MessageContentPart(`type`: "text", text: option(
            respMessage.choices[0].message.get.content
          ))]
        )
      ))

      if toolBatch.len == 0:
        break


      for tool in toolbatch:
        # Iterate over the tool call requests and execute the tool functions
        # TODO: it would be nice to handle these calls in parallel
        let toolFunc = tool.function
        let toolFn = agent.toolFns[toolFunc.name]
        let toolFuncArgs = fromJson(toolFunc.arguments)
        try:
          echo &"calling tool: {toolFunc.name}"
          let toolResult = toolFn(toolFuncArgs) # execute the provided tool function
          let toolMsg = %openai_leap.Message(
            role: "tool",
            content: option(
              @[MessageContentPart(`type`: "text", text: option(
                toolResult
              ))]
              ),
            tool_call_id: option(tool.id)
          )
          messages.add(toolMsg)
        except CatchableError as e:
          raise newException(ApiGatewayError, "Tool function failed: " & e.msg)
      # Update the request with additional messages and tools
      reqJson["messages"] = %messages

    # finalize message
    let respJson = fromJson(resp.body)
    respJson["choices"][0]["message"]["content"] = %respStr
    echo &"FINAL RESPONSE: {respJson}"

    # TODO fix headers

    request.respond(resp.code, headers, toJson(respJson))
    if agent != nil and agent.postAgentHook != nil:
      agent.postAgentHook(reqJson, respJson)

  # setup routes
  router.get("/_health", healthHandler)
  router.get("/models", modelHandler)
  router.post("/chat/completions", chatHandler)
  router.notFoundHandler = notFoundHandler
  
  echo &"Serving on http://{gateway.address}:{gateway.port}"
  let server = newServer(router)
  server.serve(Port(gateway.port), gateway.address)

when isMainModule:

  var endpoint = "https://api.openai.com/v1"
  var address = "localhost"
  var port = 8085.uint16
  var logFile = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      discard
    of cmdLongOption, cmdShortOption:
      case key:
      of "endpoint":
        endpoint = val
      of "address":
        address = val
      of "port":
        port = parseInt(val).uint16
      of "logFile":
        logFile = val
    of cmdEnd:
      discard

  let gateway = newOpenAIGateway(
    endpoint,
    address,
    port,
    logFile
    )
  start(gateway)