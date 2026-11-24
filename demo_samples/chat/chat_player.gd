extends Player
## A chat participant: the player scene's root. A script that extends Player runs on the server
## and every client; its public variables are the server's and replicate to everyone.

## Shown as "Bob is typing…" to the others. Set by the server (room.gd) when this player's
## window says so through the Typing remote.
var typing := false
