import
  std/[unittest, options, os, base64],
  mono_llm, jsony, vertex_leap

const
  TestModels = ["llama3.1:8b", "gpt-4o-mini", "gemini-1.5-flash"]
  TestProviders = [ChatProvider.ollama, ChatProvider.openai, ChatProvider.vertexai]
  TestImage = "tests/IMG_20180419_121142.jpg"
  TestImageUrl = "https://pbs.twimg.com/profile_banners/299424197/1554585063/1080x360"

let imageBase64 = readFile(TestImage).encode()

suite "mono_llm":
  var monoLLM: MonoLLM
  setup:
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

  test "chat tests":
    for i, model in TestModels:
      let chat = Chat(
        model: model,
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
          ChatMessage(role: Role.user, content: option("Hello, how are you?"))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      echo resp.message

  test "image+chat tests":
    for i, model in TestModels:
      if i == 1:
        # api formatting issue?
        continue
      let chat = Chat(
        model: model,
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
          ChatMessage(role: Role.user, content: option("how do you like this image?"), images: option(@[imageBase64]))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      echo resp.message

  test "image_url+chat tests":
    # TODO should test vertexAI with a google cloud storage url
    # currently fetching the image and passing it as base64

    for i, model in TestModels:
      let chat = Chat(
        model: model,
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
          ChatMessage(role: Role.user, content: option("how do you like this image?"), imageUrls: option(@[TestImageUrl]))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      echo resp.message

  test "image only tests":
    for i, model in TestModels:
      if i == 1:
        # openAI does not support base64 images via api
        continue
      if i == 2:
        # vertexAI seems to not like image-only messages
        continue
      let chat = Chat(
        model: model,
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
          ChatMessage(role: Role.user, images: option(@[imageBase64]))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      echo resp.message

  test "image_url only tests":

    for i, model in TestModels:
      if i == 2:
        # vertexAI seems to not like image-only messages
        continue
      let chat = Chat(
        model: model,
        provider: TestProviders[i],
        messages: @[
          ChatMessage(role: Role.system, content: option("You are longbeard the llama. Please respond as a pirate.")),
          ChatMessage(role: Role.user, imageUrls: option(@[TestImageUrl]))
        ],
      )
      let resp = monoLLM.generateChat(chat)
      echo resp.message