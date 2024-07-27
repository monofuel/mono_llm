import
  std/[unittest, options, os],
  mono_llm, jsony, vertex_leap


suite "mono_llm":
  var monoLLM: MonoLLM
  test "init":

    var config = MonoLLMConfig()

    let credentialPath = os.getEnv("GOOGLE_APPLICATION_CREDENTIALS", "")
    if credentialPath == "":
      let credStr = readFile("tests/service_account.json")
      config.gcpCredentials = option(fromJson(credStr, GCPCredentials))

    monoLLM = newMonoLLM(config)
    assert monoLLM.ollama != nil
    assert monoLLM.openai != nil
    assert monoLLM.vertexai != nil
    