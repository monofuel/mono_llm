import
  std/[unittest, strformat, options, os, base64],
  mono_llm, jsony, openai_leap

const
  TestModel = "gpt-4o-mini"
  TestAddress = "localhost"
  TestPort = 8086.uint16
  TestImage = "tests/IMG_20180419_121142.jpg"
  TestImageUrl = "https://pbs.twimg.com/profile_banners/299424197/1554585063/1080x360"

let imageBase64 = readFile(TestImage).encode()

var
  serverThread: Thread[void]
  gateway: OpenAIGateway

suite "mono_llm":
  var openAI = newOpenAiApi(&"http://{TestAddress}:{TestPort}")
  gateway = newOpenAIGateway(
    "https://api.openai.com/v1",
    TestAddress,
    TestPort,
  )

  proc startGateway() {.thread.} =
    {.gcsafe.}:
      gateway.start()
  createThread(serverThread, startGateway)
  # HACK wait for the server to start
  sleep(1000)

  test "chat tests":
    let req = CreateChatCompletionReq(
        model: TestModel,
        messages: @[
          Message(
            role: "system",
            content:
              option(@[MessageContentPart(`type`: "text", text: option(
              "You are longbeard the llama. Please respond as a pirate."
              ))])
          ),
          Message(
            role: "user",
            content:
              option(@[MessageContentPart(`type`: "text", text: option(
              "Hello, how are you?"
              ))])
          )
        ],
      )

    let resp = openai.createChatCompletion(req)
    echo resp.choices[0].message.get.content

  test "image+chat tests":
    let req = CreateChatCompletionReq(
        model: TestModel,
        messages: @[
          Message(
            role: "system",
            content:
              option(@[MessageContentPart(`type`: "text", text: option(
              "You are longbeard the llama. Please respond as a pirate."
              ))])
          ),
          Message(
            role: "user",
            content:
              option(@[
                MessageContentPart(`type`: "text", text: option(
                  "how do you like this image?"
                )),
                MessageContentPart(`type`: "image_url", image_url: option(ImageUrlPart(url: TestImageUrl)))
              ]),
          )
        ],
      )

    let resp = openai.createChatCompletion(req)
    echo resp.choices[0].message.get.content

  test "image_url only tests":
    let req = CreateChatCompletionReq(
        model: TestModel,
        messages: @[
          Message(
            role: "system",
            content:
              option(@[MessageContentPart(`type`: "text", text: option(
              "You are longbeard the llama. Please respond as a pirate."
              ))])
          ),
          Message(
            role: "user",
            content:
              option(@[
                MessageContentPart(`type`: "image_url", image_url: option(ImageUrlPart(url: TestImageUrl)))
              ]),
          )
        ],
      )

    let resp = openai.createChatCompletion(req)
    echo resp.choices[0].message.get.content