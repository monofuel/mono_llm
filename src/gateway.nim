import std/[strformat], mummy, mummy/routers

## OpenAI Compatible Gateway
## 
## This module provides a gateway to forward requests to an OpenAI compatible endpoint.
## Compiling and executing the gateway directly will give a simple proxy server that forwards requests to the OpenAI endpoint.
## The OpenAIGateway object can be extended for custom request handling.
##
## Use 'http://localhost:11434/v1' for local ollama endpoint.
## Use 'https://api.openai.com/v1' for official openai endpoint.

type OpenAIGateway* = ref object
  endpoint*: string   # OpenAI compatible endpoint to forward requests to
  address*: string    # Address to bind the gateway to
  port*: uint16       # Port to bind the gateway to

# TODO custom agents

proc createOpenAIGateway*(
  endpoint: string,
  address: string = "localhost",
  port: uint16 = 8085
): OpenAIGateway =
  result = OpenAIGateway(
    endpoint: endpoint,
    address: address,
    port: port
  )

proc healthHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "OK")

proc startOpenAIGateway*(gateway: OpenAIGateway) =
  echo "Starting OpenAI Gateway"

  # var router: Router
  # router.get("/_health", healthHandler)
  # router.get("/api/version", versionHandler)
  # router.get("/api/tags", tagsHandler)
  # router.post("/api/chat", chatHandler)
  # router.post("/api/generate", generateHandler)
  # # TODO /v1/chat/completions

  # let server = newServer(router)
  # echo "Serving on http://0.0.0.0:8085"
  # server.serve(Port(8085), "0.0.0.0")

  var router: Router
  router.get("/_health", healthHandler)
  echo &"Serving on http://{gateway.address}:{gateway.port}"
  let server = newServer(router)
  server.serve(Port(gateway.port), gateway.address)


when isMainModule:
  # TODO cli arguments
  let gateway = createOpenAIGateway("https://api.openai.com/v1")
  startOpenAIGateway(gateway)