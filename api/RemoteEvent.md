# RemoteEvent

**Inherits:** Node < Object

**Where you find it:** A node you add anywhere in your level or player scene (*Add Node ▸ RemoteEvent*). Script: `addons/rgd/runtime/remote_event.gd`.

One-way messages between clients and the server, exactly like Roblox's RemoteEvent.

## Description

One-way messages between clients and the server, exactly like Roblox's RemoteEvent.

```gdscript
# client
$OpenDoor.fire_server()
# server
$OpenDoor.on_server_event.connect(func(player: Player): is_open = not is_open)
```
Arguments can be plain data (numbers, strings, vectors, arrays, dictionaries...), replicated
nodes, and file-backed resources. Other objects arrive as null.

Like Roblox, events that arrive while nobody is connected wait in a queue (up to
`QUEUE_LIMIT` per side) and are delivered as soon as a listener connects. So a
player's UI still gets an event the server sent the moment they joined.

[b]Three ways to handle events[/b], use whichever you like:
- [b]Extend it.[/b] A script that `extends RemoteEvent` runs on the server and on clients
(no suffix needed), and RGD calls its `_on_server_event(player, ...)` and
`_on_client_event(...)` if you write them. No connecting, no boilerplate:
```gdscript
# buy.gd, on a RemoteEvent node in your level
extends RemoteEvent

func _on_server_event(player: Player, item: String) -> void:   # on the server
    if Shop.can_afford(player, item):
        Shop.give(player, item)
        fire_client(player, "bought", item)

func _on_client_event(what: String, item: String) -> void:     # on that player's machine
    print("You %s a %s" % [what, item])
```
- [b]The Signals tab.[/b] Select the node ▸ Node ▸ Signals ▸ `on_server_event` ▸ Connect,
pick a node whose script runs on the server (a level script), and add your arguments after
`player` in the generated method. `on_client_event` goes to a client script.
- [b]In code.[/b] `$Buy.on_server_event.connect(func(player: Player, item: String): ...)`.

## Tutorials

- [RemoteEvents](../guide.md#5-remoteevents-clients-ask-server-decides)
- [Recipes](../recipes.md)

## Properties

| Type | Name | Default |
|---|---|---|
| int | [rate_limit](#rate_limit) | `60` |

## Methods

| Returns | Method |
|---|---|
| void | [fire_server](#fire_server)(...args: Array) |
| void | [fire_client](#fire_client)(player: Player, ...args: Array) |
| void | [fire_all_clients](#fire_all_clients)(...args: Array) |

## Signals

**on_server_event**(player: Player)

Server: a client fired this event. Handlers get the sending `Player`, then the arguments spread out: `func(player: Player, item: String, amount: int)`.

**on_client_event**()

Client: the server fired this event to this machine. Handlers get the arguments spread out: `func(message: String, amount: int)`.

## Constants

- **QUEUE_LIMIT** = `64` — Events kept per side while nobody listens. Older ones are dropped beyond this.

## Property Descriptions

### rate_limit

`@export int rate_limit = 60`

Max fire_server calls per second per player (server side). Extra calls are dropped.

## Method Descriptions

### fire_server

`void fire_server(...args: Array)`

Client → server.

```gdscript
# In the player scene (runs on this player's machine):
get_tree().current_scene.get_node("Chat").fire_server("hello!")
```

### fire_client

`void fire_client(player: Player, ...args: Array)`

Server → one client.

```gdscript
# Only this player hears it.
$Notify.fire_client(player, "You found a secret!")
```

### fire_all_clients

`void fire_all_clients(...args: Array)`

Server → every client.

```gdscript
$Announce.fire_all_clients("%s won the round" % player.display_name)
```

[Back to the API reference](../api.md)
