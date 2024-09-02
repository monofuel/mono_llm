
import
  std/[os, tables, options, json, strutils, sequtils, strformat, base64],
  jsony, curly, llama_leap, vertex_leap, openai_leap

let curlPool = newCurlPool(4)

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
  ToolCall* = ref object
    name*: string
    arguments*: string # JSON string of arguments
  ChatMessage* = ref object
    role*: Role
    name*: Option[string]
    content*: Option[string]           # either content, image, or imageUrl must be set
    images*: Option[seq[string]]       # sequence of base64 encoded images
    imageUrls*: Option[seq[string]]    # sequence of urls to images
    toolCalls*: Option[seq[ToolCall]]  # Tools the LLM is calling
  ChatExample* = ref object
    input*: ChatMessage
    output*: ChatMessage
  ToolFunctionParameters* = object
    properties*: JsonNode  # JSON Schema of arguments
    required*: seq[string] # arguments that are required
  Tool* = ref object
    name*: string
    description*: string
    parameters*: ToolFunctionParameters
  ToolImpl* = proc (args: JsonNode): string
  Chat* = ref object
    model*: string                      # model:version
    agent*: string                      # agent name
    provider*: ChatProvider             # openai, ollama, vertexai
    params*: ChatParams = ChatParams()
    messages*: seq[ChatMessage]
    tools*: seq[Tool]
  ChatResp* = ref object
    message*: string
    inputTokens*: int
    outputTokens*: int
    totalTokens*: int
  EmbeddingVector* = seq[float64]

type
  Agent* = ref object of RootObj
    name*: string
    systemPrompt*: string              # default system prompt. may be overridden at runtime
    tools: seq[Tool]                   # Tool name to Tool API spec
    toolFns: Table[string, ToolImpl]   # Tool name to actual procedure
    preAgentHook*: proc (chat: Chat)   # Any logic to append a RAG to the system prompt can happen here
    postAgentHook*: proc (chat: Chat)  # any follow up logic like saving memmories or updating the agent state can happen here

type MonoLLM* = ref object
  ollama*: OllamaAPI
  openai*: OpenAIAPI
  vertexai*: VertexAIAPI
  agents*: Table[string, Agent]

proc addAgent*(llm: MonoLLM, agent: Agent) = 
  llm.agents[agent.name] = agent


proc addTool*(agent: Agent, tool: Tool, fn: ToolImpl) =
  agent.tools.add(tool)
  agent.toolFns[tool.name] = fn

proc `$`*(c: Chat): string =
  result = &"""
# {c.model}
{toJson(c.params)}
"""
  for m in c.messages:
    result.add(&"""
role: {m.role}
content: {m.content}
""")

proc prettyPrint*(ch: Chat) =
  echo "-----------------"
  var result = "ChatHistory:\n"
  result.add "  Model: " & $ch.model & "\n"
  result.add "  Provider: " & $ch.provider & "\n"
  result.add "  Messages:\n"
  for msg in ch.messages:
    result.add "    Role: " & $msg.role & "\n"
    if msg.content.isSome:
      result.add "    Content: " & msg.content.get & "\n"
    # TODO images
  echo result

proc copy*(original: Chat): Chat =
  let json = toJson(original)
  result = fromJson(json, Chat)

proc systemMessage*(ch: Chat): string =
  if ch.messages[0].role != Role.system:
    raise newException(Exception, &"first message is not a system message")
  result = ch.messages[0].content.get

proc lastMessage*(ch: Chat): string =
  result = ch.messages[ch.messages.len - 1].content.get



type MonoLLMConfig* = object
  ollamaBaseUrl*: string
  gcpCredentials*: Option[GCPCredentials]
  openAIKey*: string

proc newMonoLLM*(config: MonoLLMConfig): MonoLLM =
  result = MonoLLM()
  # Default to using localhost ollama w/o credentials
  result.ollama = newOllamaApi(baseUrl = config.ollamaBaseUrl)


  if config.openAIKey != "":
    result.openai = newOpenAiApi(apiKey = config.openAIKey)
  if getEnv("OPENAI_API_KEY").len > 0:
    # openai_leap loads from OPENAI_API_KEY by default
    result.openai = newOpenAiApi()
  

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



proc generateOpenAIChat(llm: MonoLLM, chat: Chat, tools: seq[Tool] = @[], toolFns: Table[string, ToolImpl]): ChatResp =
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
        let imageUrl = ImageUrlPart(
          url: url
        )
        contentParts.add(MessageContentPart(
          `type`: "image_url",
          image_url: option(imageUrl)
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

  var gptTools: seq[openai_leap.ToolCall]
  for tool in tools:
    gptTools.add(openai_leap.ToolCall(
      `type`: "function",
      function: openai_leap.ToolFunction(
        name: tool.name,
        description: option(tool.description),
        parameters: option(%* {
          "type": "object",
          "properties": tool.parameters.properties,
          "required": tool.parameters.required
          }
        )
      )
    ))


  var toolsOption = none(seq[openai_leap.ToolCall])
  if gptTools.len > 0:
    toolsOption = option(gptTools)
  var req = CreateChatCompletionReq(
    model: chat.model,
    messages: messages,
    tools: toolsOption,
    toolChoice: if gptTools.len > 0: option(% "auto") else: none(JsonNode),
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


  var resp = llm.openai.createChatCompletion(req)

  var resultMessage = ""

  
  while resp.choices[0].message.tool_calls.isSome and resp.choices[0].message.tool_calls.get.len > 0:
    resultMessage.add(resp.choices[0].message.content)
    let toolMsg = resp.choices[0].message
    messages.add(openai_leap.Message(
      role: $Role.assistant,
      tool_calls: toolMsg.tool_calls,
      content: option(@[
        MessageContentPart(
          `type`: "text",
          text: option(resp.choices[0].message.content)
        )
      ])
    ))

    for toolCallReq in toolMsg.tool_calls.get:
      # Iterate over the tool call requests and execute the tool functions
      # TODO: it would be nice to handle these calls in parallel
      let toolFunc = toolCallReq.function
      let toolFn = toolFns[toolFunc.name]
      let toolFuncArgs = fromJson(toolFunc.arguments)
      try:
        let toolResult = toolFn(toolFuncArgs) # execute the provided tool function
        messages.add(Message(
            role: "tool",
            content: option(
              @[MessageContentPart(`type`: "text", text: option(
                toolResult
              ))]
              ),
            tool_call_id: option(toolCallReq.id)
          ))
      except CatchableError as e:
        # if the tool function fails, we should return an error message
        messages.add(Message(
          role: "tool",
          content: option(
            @[MessageContentPart(`type`: "text", text: option(
              "Error executing tool function: " & e.msg
            ))]
          ),
          tool_call_id: option(toolCallReq.id)
        ))

    req = CreateChatCompletionReq(
      model: chat.model,
      messages: messages,
      tools: option(gptTools),
      toolChoice: if gptTools.len > 0: option(% "auto") else: none(JsonNode),
    )

    resp = llm.openai.createChatCompletion(req)

  resultMessage.add(resp.choices[0].message.content)

  # TODO token counting needs to be improved for tool calls
  result = ChatResp(
    message: resultMessage,
    inputTokens: resp.usage.prompt_tokens,
    outputTokens: resp.usage.total_tokens - resp.usage.prompt_tokens,
    totalTokens: resp.usage.total_tokens,
  )


proc generateVertexAIChat(llm: MonoLLM, chat: Chat, tools: seq[Tool] = @[], toolFns: Table[string, ToolImpl]): ChatResp =
  # primarily focused on gemini pro
  # chat bison / palm 2 have different features, but I don't think we need to support them going forward
  var req = GeminiProRequest()

  if chat.messages[0].role == Role.system:
    let systemPrompt = chat.messages[0].content.get

    req.systemInstruction = option(
      GeminiProSystemInstruction(
        role: $Role.system, # this field is ignored by the API
        parts: @[GeminiProContentPart(
          text: option(systemPrompt))
          ]
      )
    )

  for msg in chat.messages:
    if msg.role == Role.system:
      continue
    
    # TODO should not assume image/jpeg
    var parts: seq[GeminiProContentPart]
    if msg.content.isSome:
      parts.add(GeminiProContentPart(text: option(msg.content.get)))
      # NB. vertexAI does not like it when there is an image part but no text parts

    if msg.imageUrls.isSome:
      for url in msg.imageUrls.get:
        # Gemini Pro only supports image urls from GCS
        if url.startsWith("gs://"):
          parts.add(GeminiProContentPart(
            fileData: option(GeminiProFileData(
              mimeType: "image/jpeg",
              fileUri: url
            ))
          ))
        else:
          # if we are given a non-gcs url, fetch the image and upload it base64 instead
          let img = curlPool.get(url)
          let imgbase64 = img.body.encode()
          parts.add(GeminiProContentPart(
            inlineData: option(GeminiProInlineData(
              mimeType: "image/jpeg",
              data: imgbase64
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
  # TODO tool usage

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


proc generateOllamaChat(llm: MonoLLM, chat: Chat, tools: seq[Tool] = @[], toolFns: Table[string, ToolImpl]): ChatResp =

  var messages: seq[llama_leap.ChatMessage]

  for msg in chat.messages:

    var images = msg.images
    if msg.imageUrls.isSome:
      if images.isNone:
        images = option[seq[string]](@[])
      for url in msg.imageUrls.get:
        ## fetch the image and add base64 to images
        let img = curlPool.get(url)
        images.get.add(img.body.encode())

    messages.add(llama_leap.ChatMessage(
      role: $msg.role,
      content: msg.content,
      images: msg.images
    ))

  var ollamaTools: seq[llama_leap.Tool]
  for tool in tools:
    ollamaTools.add(llama_leap.Tool(
      `type`: "function",
      function: llama_leap.ToolFunction(
        name: tool.name,
        description: tool.description,
        parameters: llama_leap.ToolFunctionParameters(
          `type`: "object",
          properties: tool.parameters.properties,
          required: tool.parameters.required
        )
      )
    ))

  let req = ChatReq(
    model: chat.model,
    messages: messages,
    tools: ollamaTools,
    format: if chat.params.json.isSome and chat.params.json.get:
      option("json") else: none(string),
    options: option(ModelParameters(
      seed: chat.params.seed,
      temperature: chat.params.temperature,
      top_p: chat.params.top_p,
      top_k: chat.params.top_k,
    ))
  )

  var resp = llm.ollama.chat(req)

  var resultMessage = ""

  # tool handling
  while resp.message.tool_calls.len > 0:
    resultMessage.add(resp.message.content.get)
    messages.add(llama_leap.ChatMessage(
      role: $Role.assistant,
      content: option(resp.message.content.get)
    ))

    for call in resp.message.tool_calls:
      # Iterate over the tool call requests and execute the tool functions
      # TODO: it would be nice to handle these calls in parallel
      let toolFunc = call.function
      let toolFn = toolFns[toolFunc.name]
      let toolFuncArgs = toolFunc.arguments
      try:
        let toolResult = toolFn(toolFuncArgs) # execute the provided tool function
        messages.add(llama_leap.ChatMessage(
          role: $Role.tool,
          content: option(toolResult)
        ))
      except CatchableError as e:
        # if the tool function fails, we should return an error message
        messages.add(llama_leap.ChatMessage(
          role: $Role.tool,
          content: option("Error executing tool function: " & e.msg)
        ))

    let req = ChatReq(
      model: chat.model,
      messages: messages,
      tools: ollamaTools,
      format: if chat.params.json.isSome and chat.params.json.get:
        option("json") else: none(string),
      options: option(ModelParameters(
        seed: chat.params.seed,
        temperature: chat.params.temperature,
        top_p: chat.params.top_p,
        top_k: chat.params.top_k,
      ))
    )
    resp = llm.ollama.chat(req)
  resultMessage.add(resp.message.content.get)
  result = ChatResp(
    message: resultMessage,
    inputTokens: resp.prompt_eval_count,
    outputTokens: resp.eval_count - resp.prompt_eval_count,
    totalTokens: resp.eval_count
  )

proc guessProvider*(model: string): ChatProvider =
  if model.contains("gpt"):
    return ChatProvider.openai
  elif model.contains("gemini") or model.contains("gecko"):
    return ChatProvider.vertexai
  elif model.contains("llama") or
    model.contains("nomic-embed-text"):
    return ChatProvider.ollama
  else:
    raise newException(Exception, &"Could not guess provider for model {model}, please provide in chat object")

proc generateChat*(llm: MonoLLM, chat: Chat): ChatResp =

  var agent = none(Agent)

  if llm.agents.hasKey(chat.agent):
    agent = option(llm.agents[chat.agent])

    if chat.messages.len > 0 and chat.messages[0].role != Role.system and agent.get.systemPrompt != "":
      chat.messages.insert( ChatMessage(
        role: Role.system,
        content: option(agent.get.systemPrompt)
      ), 0)


  if chat.provider == ChatProvider.invalid_provider:
    chat.provider = guessProvider(chat.model)

  if agent.isSome and agent.get.preAgentHook != nil:
    agent.get.preAgentHook(chat)

  var tools: seq[Tool]
  if agent.isSome:
    tools = agent.get.tools

  var toolFns: Table[string, ToolImpl]
  if agent.isSome:
    toolFns = agent.get.toolFns

  # TODO tool handling
  case chat.provider:
    of ChatProvider.ollama:
      result = llm.generateOllamaChat(chat, tools, toolFns)
    of ChatProvider.openai:
      result = llm.generateOpenAIChat(chat, tools, toolFns)
    of ChatProvider.vertexai:
      result = llm.generateVertexAIChat(chat, tools, toolFns)
    else:
      raise newException(Exception, &"Could not find model chat handler {chat.provider}")

  # mutate the provided chat object with the response
  let chatResp = ChatMessage(
    role: Role.assistant,
    content: option(result.message)
  )
  chat.messages.add(chatResp)

  if agent.isSome and agent.get.postAgentHook != nil:
    agent.get.postAgentHook(chat)



proc generateEmbeddings*(llm: MonoLLM, model: string, prompt: string, p: ChatProvider = ChatProvider.invalid_provider): EmbeddingVector =
  if prompt == "":
    raise newException(Exception, "Empty prompt for getEmbedding")

  var provider = p
  if provider == ChatProvider.invalid_provider:
    provider = guessProvider(model)

  case provider:
    of ChatProvider.ollama:
      let resp = llm.ollama.generateEmbeddings(model, prompt)
      result = resp.embedding
    of ChatProvider.openai:
      let resp = llm.openai.generateEmbeddings(model, prompt)
      result = resp.data[0].embedding
    of ChatProvider.vertexai:
      result = llm.vertexai.geckoTextEmbed(model, prompt)

    else:
      raise newException(Exception, &"Could not find model {model} embedding handler {provider}")
