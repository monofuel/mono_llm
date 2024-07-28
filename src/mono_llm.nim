
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
    name*: Option[string]
    content*: Option[string]        # either content, image, or imageUrl must be set
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



proc generateOpenAIChat(llm: MonoLLM, chat: Chat): ChatResp =
  var messages: seq[openai_leap.Message]
  for msg in chat.messages:

    var contentParts: seq[MessageContentPart]
    if msg.content.isSome:
      contentParts.add(MessageContentPart(
        `type`: "text",
        text: msg.content
      ))
    if msg.imageUrls.isSome:
      for url in msg.imageUrls.get:
        contentParts.add(MessageContentPart(
          `type`: "image_url",
          image_url: option(url)
        ))
    if msg.images.isSome:
      if msg.images.get.len > 0:
        # TODO implement non-url images for openai api
        # could either: run a web server and service the image, or use the 'create upload' api
        # would need to keep track of what images have been uploaded
        raise newException(Exception, "OpenAI image upload not implemented yet, please use image_url for now")

    messages.add(openai_leap.Message(
      role: $msg.role,
      content: option(contentParts)
    ))

  var req = CreateChatCompletionReq(
    model: chat.model,
    messages: messages,
  )

  req.seed = chat.params.seed
  req.top_p = chat.params.top_p
  # top_k?
  req.temperature = chat.params.temperature
  if chat.params.json.isSome and chat.params.json.get:
    req.response_format = option(
      ResponseFormatObj(
        `type`: "json"
      )
    )


  let resp = llm.openai.createChatCompletion(req)
  result = ChatResp(
    message: resp.choices[0].message.content,
    inputTokens: resp.usage.prompt_tokens,
    outputTokens: resp.usage.total_tokens - resp.usage.prompt_tokens,
    totalTokens: resp.usage.total_tokens,
  )




proc generateVertexAIChat(llm: MonoLLM, chat: Chat): ChatResp =
  # primarily focused on gemini pro
  # chat bison / palm 2 have different features, but I don't think we need to support them going forward

  # let req = GeminiProRequest(
  #   generationConfig: GeminiProGenerationConfig(
  #     temperature: 0.2,
  #     topP: 0.8,
  #     topK: 40
  #   ),
  #   contents: @[
  #     GeminiProContents(
  #       role: "user",
  #       parts: @[
  #         GeminiProContentPart(text: option(prompt))
  #       ]
  #     )
  #   ]
  # )

  # if system != "":
  #   req.systemInstruction = option(
  #     GeminiProSystemInstruction(
  #       parts: @[GeminiProContentPart(text: option(system))]
  #     )
  #   )
  # if image != "":
  #   let imgPart =
  #       GeminiProContentPart(
  #         fileData: option(GeminiProFileData(
  #           mimeType: "image/jpeg",
  #           fileUri: image
  #         ))
  #       )
  #   req.contents[0].parts.add(imgPart)

  var req = GeminiProRequest()

  if chat.messages[0].role == Role.system:
    let systemPrompt = chat.messages[0].content.get

    req.systemInstruction = option(
      GeminiProSystemInstruction(
        parts: @[GeminiProContentPart(text: option(systemPrompt))]
      )
    )

  for msg in chat.messages:
    if msg.role == Role.system:
      continue
    
    # TODO should not assume image/jpeg
    var parts: seq[GeminiProContentPart]
    if msg.content.isSome:
      parts.add(GeminiProContentPart(text: option(msg.content.get)))
    if msg.imageUrls.isSome:
      for url in msg.imageUrls.get:
        parts.add(GeminiProContentPart(
          fileData: option(GeminiProFileData(
            mimeType: "image/jpeg",
            fileUri: url
          ))
        ))
    if msg.images.isSome:
      for img in msg.images.get:
        parts.add(GeminiProContentPart(
          inlineData: option(GeminiProInlineData(
            mimeType: "image/jpeg",
            data: img
          ))
        ))
    req.contents.add(GeminiProContents(
      role: $msg.role,
      parts: parts
    ))

  # TODO were these 3 fields optional in vertexai api?
  req.generationConfig = GeminiProGenerationConfig(
    temperature: chat.params.temperature.get,
    topP: chat.params.top_p.get,
    topK: chat.params.top_k.get
  )
  
  # TODO safety settings

  let resp = llm.vertexai.geminiProGenerate(chat.model, req)

  var msg = ""
  for part in resp.candidates[0].content.parts:
    msg.add(part.text.get)
  result = ChatResp(
    message: msg,
    inputTokens: resp.usageMetadata.promptTokenCount,
    outputTokens: resp.usageMetadata.candidatesTokenCount,
    totalTokens: resp.usageMetadata.totalTokenCount,
  )


proc generateOllamaChat(llm: MonoLLM, chat: Chat): ChatResp =

  var messages: seq[llama_leap.ChatMessage]

  for msg in chat.messages:

    if msg.imageUrls.isSome:
      # TODO could perform this automatically by downloading image
      raise newException(Exception, "Ollama does not support image urls, please use base64 images")

    # TODO does this work for image-only messages?
    messages.add(llama_leap.ChatMessage(
      role: $msg.role,
      content: msg.content.get,
      images: msg.images
    ))

  let req = ChatReq(
    model: chat.model,
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
    if msg.content.isSome:
      msgCharSum += msg.content.get.len
    if msg.images.isSome:
      imageCount += msg.images.get.len
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
      return llm.generateOllamaChat(chat)
    of ChatProvider.openai:
      return llm.generateOpenAIChat(chat)
    of ChatProvider.vertexai:
      return llm.generateVertexAIChat(chat)
    else:
      raise newException(Exception, &"Could not find model chat handler {chat.provider}")


# proc generateEmbeddings*(model: string, provider: string,
#     prompt: string): EmbeddingVector =
#   if prompt == "":
#     raise newException(Exception, "Empty prompt for getEmbedding")
#   # TODO handle non ollama models
#   let resp = ollama.generateEmbeddings($model, prompt)
#   result = resp.embedding
