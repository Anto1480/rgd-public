class_name RGDProtocol
## Wire protocol constants (plan section 7).

## 2: OWNER_PROPS, view ticks on client remotes, inline resources.
## 3: join data in HELLO, PING/PONG used, CUSTOM (Game.send_message).
const VERSION := 3

## Channel 0: reliable (handshake, spawns, property diffs, remotes).
const CH_RELIABLE := 0
## Channel 1: unreliable ordered (transform streams).
const CH_STREAM := 1
## Channels requested from ENet (custom channels are 1-based on top of the system ones).
const ENET_CHANNELS := 2

## Message types: the first byte of every RGD packet.
enum Msg {
	HELLO = 1,
	WELCOME,
	REJECT,
	SNAPSHOT_BEGIN,
	SNAPSHOT_END,
	WORLD_MAP,
	SPAWN_SCENE,
	SPAWN_NODE,
	DESPAWN,
	PLACE,
	PROPS,
	XFORM_BATCH,
	OWNED_STATE,
	REMOTE_EVENT,
	INVOKE,
	INVOKE_RESULT,
	CHANGE_SCENE,
	PING,
	PONG,
	STRING_DEF,
	CORRECTION,
	OWNER,
	STREAM_OUT,
	OWNER_PROPS,
	CUSTOM,
}
