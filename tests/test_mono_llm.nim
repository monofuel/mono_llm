import
  std/[unittest, options, os],
  mono_llm, jsony, vertex_leap

const
  OllamaTestModel = "llama3.1:8b"
  OpenAITestModel = "gpt-4o-mini"
  VertexAITestModel = "gemini-1.5-flash"

suite "mono_llm":
  var monoLLM: MonoLLM
  test "init":

    var config = MonoLLMConfig(
      ollamaBaseUrl: "http://localhost:11434/api",
    )

    let credentialPath = os.getEnv("GOOGLE_APPLICATION_CREDENTIALS", "")
    if credentialPath == "":
      let credStr = readFile("tests/service_account.json")
      config.gcpCredentials = option(fromJson(credStr, GCPCredentials))

    monoLLM = newMonoLLM(config)
    assert monoLLM.ollama != nil
    assert monoLLM.openai != nil
    assert monoLLM.vertexai != nil
  
  test "ollama":
    let chat = Chat(
      model: OllamaTestModel,
      provider: ChatProvider.ollama,
      messages: @[
        ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
        ChatMessage(role: Role.user, content: option("Hello, how are you?"))
      ],
    )
    let resp = monoLLM.generateChat(chat)
    echo resp.message

  test "openai":
    let chat = Chat(
      model: OpenAITestModel,
      provider: ChatProvider.openai,
      messages: @[
        ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
        ChatMessage(role: Role.user, content: option("Hello, how are you?"))
      ],
    )
    let resp = monoLLM.generateChat(chat)
    echo resp.message

  test "vertexai":
    let chat = Chat(
      model: VertexAITestModel,
      provider: ChatProvider.vertexai,
      messages: @[
        ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
        ChatMessage(role: Role.user, content: option("Hello, how are you?"))
      ],
    )
    let resp = monoLLM.generateChat(chat)
    echo resp.message