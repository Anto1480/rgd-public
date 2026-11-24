# RemoteFunction

**Inherits:** Node < Object

**Where you find it:** A node you add anywhere in your level or player scene (*Add Node ▸ RemoteFunction*). Script: `addons/rgd/runtime/remote_function.gd`.

Request/response between a client and the server, exactly like Roblox's RemoteFunction.

## Description

Request/response between a client and the server, exactly like Roblox's RemoteFunction.

```gdscript
# server
$BuyItem.on_server_invoke = func(player: Player, item_id: int) -> bool:
    return await shop.try_buy(player, item_id)
# client
var ok = await $BuyItem.invoke_server(42)
```
[b]Handle calls without boilerplate:[/b] in a script that `extends RemoteFunction` (it runs
on the server and on clients), write `_on_server_invoke(player, ...)` (and, rarely,
`_on_client_invoke(...)`); RGD uses them when no handler Callable is set.
```gdscript
# get_price.gd, on a RemoteFunction node in your level
extends RemoteFunction

func _on_server_invoke(player: Player, item: String) -> int:
    return Shop.price_for(player, item)
```
Waits forever by default (like Roblox); set `timeout` to give up. If the other side
hasn't set its handler yet, the call waits up to `HANDLER_WAIT` seconds for it. A
call always finishes: a timeout, a missing handler, a disconnect, a wrong argument count,
the session ending or this node being freed (a scene change) resolve it to null, so code
awaiting it never hangs.

## Tutorials

- [RemoteFunctions](../guide.md#6-remotefunctions-ask-and-wait-for-an-answer)

## Properties

| Type | Name | Default |
|---|---|---|
| Callable | [on_server_invoke](#on_server_invoke) |  |
| Callable | [on_client_invoke](#on_client_invoke) |  |
| float | [timeout](#timeout) | `0.0` |
| int | [rate_limit](#rate_limit) | `60` |

## Methods

| Returns | Method |
|---|---|
| Variant | [invoke_server](#invoke_server)(...args: Array) |
| Variant | [invoke_client](#invoke_client)(player: Player, ...args: Array) |

## Constants

- **HANDLER_WAIT** = `10.0` — Seconds a call waits for the other side to set its handler (e.g. a UI that isn't ready yet).

## Property Descriptions

### on_server_invoke

`Callable on_server_invoke`

Server handler: func(player: Player, ...args) -> Variant. May await.

### on_client_invoke

`Callable on_client_invoke`

Client handler for invoke_client: func(...args) -> Variant. May await. (Risky in Roblox terms: the server waits on a client that might never answer.)

### timeout

`@export float timeout = 0.0`

Seconds to wait for an answer. 0 = wait forever.

### rate_limit

`@export int rate_limit = 60`

Max calls per second per player (server side). Extra calls are dropped.

## Method Descriptions

### invoke_server

`Variant invoke_server(...args: Array)`

Client → server. Use with await: `var r = await remote.invoke_server(...)`.

```gdscript
var price: int = await $GetPrice.invoke_server("sword")
```

### invoke_client

`Variant invoke_client(player: Player, ...args: Array)`

Server → client. Use with await.

```gdscript
# Ask one player's game which language it uses.
var lang = await $GetLanguage.invoke_client(player)
```

[Back to the API reference](../api.md)
