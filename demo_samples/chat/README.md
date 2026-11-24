# Sample 2: Chat (no characters)

A chat room built on RGD **without any game in it**: no characters, no spawn points, no 3D. It stress-tests the player model ("every player has a character") and shows what you have to work around when a player is just a person with a window. Nothing in the engine was changed for it.

![Bob's chat window](../../docs/images/chat.png)

## Run it

**From the editor:** open `room.tscn`. In the Play Test dropdown choose **Host + clients** and **2** or more, then press **Play Test**.

**Like a real app:** run `menu.tscn` in two windows (*Debug ▸ Customize Run Instances…* ▸ 2). Enter a name, then **Host** in one window and **Join** in the other.

**Commands:** `/me <action>` · `/w <name> <message>` (whisper) · `/name <new name>` · `/topic <text>` (host only) · `/leave` (back to the menu) · `/help`

## How it works

| File | Runs on | What it does |
|---|---|---|
| `room.tscn` | | The level: just a `Node` with three remotes: `Say` (RemoteEvent, both ways), `Typing` (RemoteEvent), `History` (RemoteFunction). `Say` and `Typing` are connected to `room.gd` in the scene (Node ▸ Signals). Its metadata picks this sample's player scene and menu. |
| `room.gd` | **server** | Checks every message (type, length, rate), runs the commands, keeps the last 50 messages, and sends messages out. `topic` is a public variable, so it replicates. |
| `say.gd` (on `Say`) | **clients** | `extends RemoteEvent`: `_on_client_event(entry)` hands each message to your chat window. |
| `history.gd` (on `History`) | **server** | `extends RemoteFunction`: `_on_server_invoke` returns the kept messages. |
| `player.tscn` | | A `Player` with **no character**: its root script `chat_player.gd` and the chat window as its `ui`. |
| `chat_player.gd` | **server and every client** | `extends Player`: `typing`, set by the server, read directly by every window (`player.typing`). |
| `chat_ui.gd` | **this player** | The chat window: shows messages, sends what you type, shows who's online and typing. |
| `menu.gd` | each player | Name + Host / Join. |

A message's trip: your window calls `Say.fire_server("hi")`. The server cleans the text, stamps it with an id and the time, stores it, and calls `Say.fire_all_clients(entry)`. Every window then shows it.

## Limitations found, and the workarounds used

These are what this sample ran into. When it was first written, each was handled in the sample's own code without engine changes. Since then the engine fixed three of them (#2, #3, #5, marked below). The sample keeps its workarounds where they're still useful.

| # | Limitation | What happens | Workaround in this sample |
|---|---|---|---|
| 1 | **Players without characters** | Works. `character` stays empty, and no spawn points are needed. RGD logs no warnings. | — |
| 2 | **Messages sent right as someone joins** ~~are lost for them~~ *fixed in the engine* | The server spawns a joining player's scene right after sending them the world, so a broadcast at that moment ("Bob joined") reaches Bob before his chat window exists. RGD used to drop it. Remote events now wait in a queue until something handles them (like Roblox). | The window **pulls** the history with a `RemoteFunction` once it's ready, which covers anything from before it opened (say.gd skips messages until then). Every message has an **id**, so one that arrives twice shows once. |
| 3 | **Display names** ~~aren't unique~~ *are made unique by the engine* (and can contain spaces) | RGD now renames a second "Bob" to "Bob2" on join (setting `rgd/players/unique_names`, on by default). Names can still contain spaces, which breaks `/w`. | The room replaces spaces with `_` on join and checks uniqueness again. |
| 4 | **Clients can't write their own state** | A player's `typing` flag can't be set by that player directly. | It's a variable of the player's `extends Player` script (the server's value), set by the server when the client sends `Typing.fire_server(true)`. |
| 5 | **The remote rate limit** ~~is silent~~ *now warns the sender* (debug builds) | `rate_limit` (default 60/s) drops extra calls on the server. Debug builds now also warn on the *sending* machine. Players of a release build still aren't told. | The room has its own, friendlier limit (one message per 0.3 s) and tells the sender "Slow down a little." |
| 6 | **No host migration** | If the host leaves, the room closes for everyone ("the host left"). | None: run a dedicated server for a room that should stay up (the `sample_chat_server` test does). |
| 7 | **A dedicated server has no host player** | Nobody has peer id 1, so "host only" commands have nobody to allow. | `/topic` simply stays locked. A real app would add its own admin list. |
| 8 | **History only lives in the server's memory** | Restarting the host clears it. | None (save it with a `.server.gd` script if you need it). |
| 9 | **Names in old messages don't change** | After `/name`, earlier messages keep the old name. | That's on purpose: each message stores the name it was sent with. |
| 10 | **Text formatting injection** | `RichTextLabel.append_text()` would let `[color=red]` in a message (or a name) restyle the chat. | Messages are drawn with `add_text()`, which never parses BBCode. |
| 11 | **Replicated arrays are resent whole** | A public `var history: Array` would replicate, but every new message would resend all 50 to everyone. | History goes through the `History` RemoteFunction instead: once per joining player. |
| 12 | **A rename only changes `display_name`** | The `Player` node keeps its original node name (and path). | Code identifies players by `user_id` or the `Player` object, never by node name. |

## Tested

- `tests/integration/scenarios/sample_chat.gd`: a host and two clients, one joining 5 seconds late. It checks:
  - the late joiner's history arrives exactly once, without the whisper
  - whispers stay private
  - `/me`, `/name` and `/topic` work, and the typing indicator shows up for others
  - spam is limited
  - BBCode shows as plain text and long messages are cut to 300 characters
- `tests/integration/scenarios/sample_chat_server.gd`: a dedicated server. There's no host player and the topic stays locked; two clients joining as "Twin" become `Twin` and `Twin2`.
