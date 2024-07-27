
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
  ChatProvider* = enum
    invalid_provider,
    openai = "openai",
    ollama = "ollama",
    vertexai = "vertexai"
  ChatParams* = ref object
    seed*: Option[int] = option(839106)
    temperature*: Option[float32] = option(0.0f)
    top_p*: Option[float32] = option(0.9f)
    top_k*: Option[int] = option(40)
    json*: Option[bool] = option(false) # request json response (remember to also prompt for json)
  ChatMessage* = ref object
    role*: Role
    content*: string
    name*: Option[string]
    images*: Option[seq[string]]    # sequence of base64 encoded images
    imageUrls*: Option[seq[string]] # sequence of urls to images
  ChatExample* = ref object
    input*: ChatMessage
    output*: ChatMessage
  Chat* = ref object
    model*: string         # agent/model:version
    provider*: ChatProvider             # openai, ollama, vertexai
    params*: ChatParams = ChatParams()
    messages*: seq[ChatMessage]
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

proc estTokenCount(charCount: int): int =
  # each token is about 4 characters
  # add a buffer of 2%
  result = int((charCount / 4) * 1.02)

proc newMonoLLM*(): MonoLLM =
  let config = MonoLLMConfig(
    ollamaBaseUrl: "",
    gcpCredentials: none(GCPCredentials)
  )
  result = newMonoLLM(config)



proc generateOpenAIChat(llm: MonoLLM, modelname: string, chat: Chat): ChatResp =
  echo "TODO"

proc generateVertexAIChat(llm: MonoLLM, modelname: string, chat: Chat): ChatResp =
  echo "TODO"

proc generateOllamaChat(llm: MonoLLM, modelname: string, chat: Chat): ChatResp =

  var messages: seq[llama_leap.ChatMessage]

  for msg in chat.messages:
    messages.add(llama_leap.ChatMessage(
      role: $msg.role,
      content: msg.content,
      images: msg.images
    ))

  let req = ChatReq(
    model: modelname,
    messages: messages,
    format: if chat.params.json.isSome and chat.params.json.get:
      option("json") else: none(string),
    options: option(ModelParameters(
      seed: chat.params.seed,
      temperature: chat.params.temperature,
      top_p: chat.params.top_p,
      top_k: chat.params.top_k,
    ))
  )
  let resp = llm.ollama.chat(req)

  result = ChatResp(
    message: resp.message.content,
    inputTokens: resp.prompt_eval_count,
    outputTokens: resp.eval_count - resp.prompt_eval_count,
    totalTokens: resp.eval_count
  )

# TODO work out a tool usage interface
# TODO work out a dynamic rag interface

proc generateChat*(llm: MonoLLM, chat: Chat, debugPrint: bool = true): ChatResp =

  # checks around token usage and limits
  var msgCharSum = 0
  var imageCount = 0
  for msg in chat.messages:
    msgCharSum += msg.content.len
    if msg.imageUrls.isSome:
      imageCount += msg.imageUrls.get.len
  let tokenEst = estTokenCount(msgCharSum)
  if debugPrint:
    if tokenEst > 0:
      echo &"DEBUG: chat: {chat.model}, tokens: {tokenEst}"
    if imageCount > 0:
      echo &"DEBUG: chat: {chat.model}, images: {imageCount}"

  # TODO could make a provider guessing system
  # gpt -> openai, gemini -> vertex, llama -> ollama

  # TODO adding new message to chat object

  case chat.provider:
    of ChatProvider.ollama:
      return llm.generateOllamaChat(chat.model, chat)
    of ChatProvider.openai:
      return llm.generateOpenAIChat(chat.model, chat)
    of ChatProvider.vertexai:
      return llm.generateVertexAIChat(chat.model, chat)
    else:
      raise newException(Exception, &"Could not find model chat handler {chat.provider}")


# proc generateEmbeddings*(model: string, provider: string,
#     prompt: string): EmbeddingVector =
#   if prompt == "":
#     raise newException(Exception, "Empty prompt for getEmbedding")
#   # TODO handle non ollama models
#   let resp = ollama.generateEmbeddings($model, prompt)
#   result = resp.embedding
