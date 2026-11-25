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
    errorData*: JsonNode
  JsonRpcNotification* = object
    rpcMethod*: string
    params*: JsonNode

proc idText*(idNode: JsonNode): JsonRpcId =
  ## A JSON-RPC `id` node as the text a response is matched by: a string as
  ## itself, an integer as its full decimal text, anything else as its JSON.
  ## An integer id is read with `getBiggestInt`, which is 64-bit on every
  ## target, never with `getInt`: under JS `int` is 32 bits and `getInt`
  ## raises a RangeDefect on an id past 2^31-1. It is never clamped either,
  ## since an id is an identity and clamping would merge distinct ids.
  case idNode.kind
  of JString: idNode.getStr("")
  of JInt: $idNode.getBiggestInt
  else: $idNode

proc wireInt32*(node: JsonNode; default = 0): int =
  ## A JSON integer read into an `int`, held to the 32-bit range that `int`
  ## holds on every target, or `default` when `node` is nil or not an integer.
  ## It is std/json's `getInt` without its RangeDefect: under JS `int` is 32
  ## bits, and `getInt` raises on a wire value such as `10000000000`, which
  ## aborted the whole read. Wire readers use it, never `getInt` or `.int`.
  if node.isNil or node.kind != JInt: default
  else: int(clamp(node.getBiggestInt.int64, int64(low(int32)), int64(high(int32))))

proc encodeRequest*(req: JsonRpcRequest): string =
  $(%*{"jsonrpc": "2.0", "id": req.id, "method": req.rpcMethod, "params": req.params})

proc encodeNotification*(notification: JsonRpcNotification): string =
  $(%*{"jsonrpc": "2.0", "method": notification.rpcMethod, "params": notification.params})

proc decodeResponse*(text: string): JsonRpcResponse =
  let node = parseJson(text)
  let idNode = node{"id"}
  if idNode != nil:
    result.id = idNode.idText
  if node.hasKey("error"):
    result.errorCode = node["error"]{"code"}.wireInt32(-32000)
    result.errorMessage = node["error"]{"message"}.getStr("ACP error")
    result.errorData = node["error"]{"data"}
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
    # We can't directly reference ``AcpServerError`` here without a
    # cyclic import; the call site in ``client.nim`` upgrades the
    # exception with code + data when appropriate. Keep this raise as
    # ``AcpError`` so existing callers continue to catch correctly.
    raise newException(AcpError, response.errorMessage)
