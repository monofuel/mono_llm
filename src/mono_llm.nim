
import
  std/[os, options, strformat],
  jsony, llama_leap, vertex_leap, openai_leap

# These mono_llm types are an intermediate representation that is converted for each API
type
  Role* = enum
    invalid_role,
    system = "system",
    user = "user",
    tool = "tool",
    assistant = "assistant"
  ChatParams* = ref object
    seed*: Option[int] = option(839106)
    temperature*: Option[float32] = option(0.0f)
    top_p*: Option[float32] = option(0.9f)
    top_k*: Option[int] = option(40)
    json*: Option[bool] = option(false) # request json response (remember to also prompt for json)
  AIChatMessage* = ref object
    role*: Role
    content*: string
    name*: Option[string]
    images*: Option[seq[string]]    # sequence of base64 encoded images
    imageUrls*: Option[seq[string]] # sequence of urls to images
  ChatExample* = ref object
    input*: AIChatMessage
    output*: AIChatMessage
  Chat* = ref object
    model*: string         # agent/model:version
    params*: ChatParams = ChatParams()
    context *: seq[string] # context to include up to the size limit
    examples*: seq[AIChatMessage]
    messages*: seq[AIChatMessage]
  ChatResp* = ref object
    message*: string
    inputTokens*: int
    outputTokens*: int
    totalTokens*: int

type MonoLLM* = ref object
  ollama*: OllamaAPI
  openai*: OpenAIAPI
  vertexai*: VertexAIAPI

proc `$`*(c: Chat): string =
  result = &"""
# {c.model}
{toJson(c.params)}
"""
  # TODO context + examples
  for m in c.messages:
    result.add(&"""
role: {m.role}
content: {m.content}
""")

type MonoLLMConfig* = object
  ollamaBaseUrl*: string
  gcpCredentials*: Option[GCPCredentials]

proc newMonoLLM*(config: MonoLLMConfig): MonoLLM =
  result = MonoLLM()
  # Default to using localhost ollama w/o credentials
  result.ollama = newOllamaApi(baseUrl = config.ollamaBaseUrl)

  # openai_leap loads from OPENAI_API_KEY by default
  if getEnv("OPENAI_API_KEY").len > 0:
    result.openai = newOpenAIApi()

  if config.gcpCredentials.isSome:
    result.vertexai = newVertexAIApi(credentials = config.gcpCredentials)
  elif getEnv("GOOGLE_APPLICATION_CREDENTIALS").len > 0:
    # vertexAI loads from GOOGLE_APPLICATION_CREDENTIALS by default
    result.vertexai = newVertexAIApi()

  if result.ollama != nil:
    echo "initialized ollama"
  if result.openai != nil:
    echo "initialized openai"
  if result.vertexai != nil:
    echo "initialized vertexai"

proc newMonoLLM*(): MonoLLM =
  let config = MonoLLMConfig(
    ollamaBaseUrl: "",
    gcpCredentials: none(GCPCredentials)
  )
  result = newMonoLLM(config)