import std/[strformat, parseopt, envvars, strutils],
  curly, mummy, mummy/routers, openai_leap

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
  OpenAIGateway* = ref object
    openAI*: OpenAiApi
    endpoint: string     # OpenAI compatible endpoint to forward requests to
    address: string      # Address to bind the gateway to
    port: uint16         # Port to bind the gateway to
    logFile: string
  ApiGatewayError* = object of CatchableError

# TODO custom agents
# TODO logging

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
{req.body}
# Resp {resp.code}
{resp.body}
"""
  writeFile(gateway.logFile, logBlock)


proc healthHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "OK")

proc startOpenAIGateway*(gateway: OpenAIGateway) =
  echo "Starting OpenAI Gateway"
  var router: Router
  let openAI = gateway.openAI

  proc modelHandler(request: Request) =
    ## proxy GET /models
    echo "GET /models"
    var headers: Httpheaders
    if request.headers["Authorization"] == "":
      request.respond(401, headers, "Unauthorized")

    var apiKey = request.headers["Authorization"]
    apiKey.removePrefix("Bearer ")
    let organization = request.headers["Organization"]
    let resp = openAI.get("/models", apiKey, organization)
    request.respond(resp.code, resp.headers, resp.body)
    gateway.logRequest(request, resp)


  router.get("/_health", healthHandler)
  router.get("/models", modelHandler)
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