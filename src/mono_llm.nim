import std/[strformat, tables, json, parseopt, envvars, strutils],
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

type
  ToolImpl* = proc (args: JsonNode): string
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

proc createOpenAIGateway*(
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

proc startOpenAIGateway*(gateway: OpenAIGateway) =
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

  proc chatHandler(request: Request) =
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

    var agent: Agent
    if agentName != "":
      agent = gateway.agents[agentName]

      if agent.systemPrompt != "":
        # find the system prompt first message
        var systemPrompt: openai_leap.Message
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

      agent.preAgentHook(reqJson)

    if reqJson.hasKey("stream") and reqJson["stream"].getBool:
      raise newException(ApiGatewayError, "Streaming not supported")
      # streaming
      # TODO figure this out
      # let stream = openAI.postStream(api, "/chat/completions", reqBody, Opts(bearerToken: bearerToken, organization: organization))
      # send the headers
      # openai headers will include:
      # Content-Type: text/event-stream; charset=utf-8
      # Transfer-Encoding: chunked
      # request.respond(resp.code, resp.headers)

    else:
      # not streaming
      let resp = openAI.post("/chat/completions", request.body, Opts(bearerToken: bearerToken, organization: organization))
      request.respond(resp.code, resp.headers, resp.body)
      gateway.logRequest(request, resp)
      agent.postAgentHook(reqJson, fromJson(resp.body))

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

  echo address
  let gateway = createOpenAIGateway(
    endpoint,
    address,
    port,
    logFile
    )
  startOpenAIGateway(gateway)