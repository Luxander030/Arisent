## Collision layers (emulating Source collision groups). Names are also set in
## project.godot so they show up in the inspector.
class_name PhysicsLayers
extends RefCounted

const WORLD := 1 << 0        ## terrain, buildings, static props, walls, ice
const PLAYER := 1 << 1
const NPC := 1 << 2
const PROP := 1 << 3         ## interactive physics props (solid, pushable)
const DEBRIS := 1 << 4       ## gibs / small clutter: collide with the world only
const RAGDOLL := 1 << 5
const DYNAMIC := 1 << 6      ## moving platforms, doors (AnimatableBody3D)
const PUSHAWAY := 1 << 7     ## clutter the player walks through but nudges (Source pushaway)
const PROJECTILE := 1 << 8
const HITBOX := 1 << 9
const TRIGGER := 1 << 10
const EDITOR_PICK := 1 << 19 ## editor-only picking shapes (never collide in the game)

const PLAYER_MASK := WORLD | NPC | PROP | DYNAMIC
const PROP_MASK := WORLD | PLAYER | NPC | PROP | DYNAMIC | PUSHAWAY | DEBRIS
const DEBRIS_MASK := WORLD
const PUSHAWAY_MASK := WORLD | PROP | DEBRIS | PUSHAWAY
## What a hitscan trace hits.
const TRACE_MASK := WORLD | PROP | DYNAMIC | HITBOX | RAGDOLL
