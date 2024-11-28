import mono_llm

# Simple logging proxy example for mono_llm

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


gateway.start()