import std/json
import std/strutils
import nim_acp/types

type
  JsonRpcId* = string
  JsonRpcRequest* = object
    id*: JsonRpcId
    rpcMethod*: string
    params*: JsonNode
  JsonRpcResponse* = object
    id*: JsonRpcId
    result*: JsonNode
    errorCode*: int
    errorMessage*: string
  JsonRpcNotification* = object
    rpcMethod*: string
    params*: JsonNode

proc encodeRequest*(req: JsonRpcRequest): string =
  $(%*{"jsonrpc": "2.0", "id": req.id, "method": req.rpcMethod, "params": req.params})

proc encodeNotification*(notification: JsonRpcNotification): string =
  $(%*{"jsonrpc": "2.0", "method": notification.rpcMethod, "params": notification.params})

proc decodeResponse*(text: string): JsonRpcResponse =
  let node = parseJson(text)
  result.id = node{"id"}.getStr("")
  if node.hasKey("error"):
    result.errorCode = node["error"]{"code"}.getInt(-32000)
    result.errorMessage = node["error"]{"message"}.getStr("ACP error")
  else:
    result.result = node{"result"}

proc decodeRequest*(text: string): JsonRpcRequest =
  let node = parseJson(text)
  JsonRpcRequest(
    id: node{"id"}.getStr(""),
    rpcMethod: node{"method"}.getStr(""),
    params: node{"params"})

proc decodeNotification*(text: string): JsonRpcNotification =
  let node = parseJson(text)
  JsonRpcNotification(rpcMethod: node{"method"}.getStr(""), params: node{"params"})

proc frame*(message: string): string =
  message & "\n"

proc splitFrames*(buffer: string): seq[string] =
  for line in buffer.splitLines:
    if line.len > 0:
      result.add line

proc raiseIfError*(response: JsonRpcResponse) =
  if response.errorMessage.len > 0:
    raise newException(AcpError, response.errorMessage)
