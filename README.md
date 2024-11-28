# MonoLLM

- WIP - Incomplete and not ready for use


- LLM gateway project
- MonoLLM is an OpenAPI gateway for the OpenAI API
- you can directly execute `nim c -r src/mono_llm.nim --address=0.0.0.0 --logFile=test.txt` to get a simple openai proxy.

- you can also import the gateway package and extend it to create your own gateway with additional features
```nim
import mono_llm

let gateway = newOpenAIGateway("https://api.openai.com/v1", "0.0.0.0",8085)
startOpenAIGateway(gateway)
```

- model names are typically structured like `llama3.1:8b-instruct-fp16` 
- This gateway adds an abstraction of 'agents' that are model independant, and are selected with a `/` prefix. for example, `customAgent/llama3.1:8b-instruct-fp16` would use the `customAgent` agent to interact with the `llama3.1:8b-instruct-fp16` model.
- Each agent can be custom defined with nim code to do things like:
  - append (or replace) the system prompt
  - append context from a custom handler
  - add & fulfill custom tool calls
- The idea is that gateways can be used by arbitrary applications or even get chained together. A top level tool that injects it's own tools can use this gateway and get even more tools injected.

## Features

- [x] get/post
- [ ] streaming

- [x] defining agents
- [x] test pre-hook
  - context adding
  - chat history injection
- [x] adding tool calls
- [x] test post-hook

- [ ] handle tools from the client
  - the gateway should be smart and bubble up tool calls to the client if it doesn't know how to handle them
  - what to do when the AI asks for multiple gateway tools and multiple client tools? probably just return the one client tool, and let the client call back again. but then the gateway won't have the previous tool calls, hmm...
- [ ] RAG examples
  - could build some ready-to-go rag functions as part of the agent pre-hook