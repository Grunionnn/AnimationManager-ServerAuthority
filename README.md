# AnimationManager-ServerAuthority
Animation registration, playback, and observation for a Humanoid's server-created Animator.

## Server authority integration

The consumer owns startup. Require the same shared simulation ModuleScript on the server and client, and create one manager per character on each side. The package does not create your character loaders or simulation loop. Requiring the package on both sides does not itself synchronize when its methods are called.

Configure `Workspace.AuthorityMode = Server` in Studio and follow [Roblox's server authority setup](https://create.roblox.com/docs/projects/server-authority). The Animator must be created on the server and replicated to the client. Call the constructor outside simulation: it waits for the Animator and preloads assets, which can yield. Initialize both sides with the same animation definitions.

`Play`, `Stop`, `StopAll`, and `AdjustSpeed` execute immediately and never create simulation bindings. Call them from the consumer's shared `RunService:BindToSimulation` callback. Each operation looks up the current track by animation ID; only `Play` loads a missing track. Use synchronized inputs and attributes to decide which operations to perform. See [Roblox's animation guidance](https://create.roblox.com/docs/projects/server-authority/techniques#writing-animation-code).

For example, place this initializer in a shared ModuleScript and invoke it from both loaders. This example expects `Core.Walk` and `Core.Idle` animations authored to loop:

```luau
local RunService = game:GetService("RunService")
local AnimationManager = require(path.To.AnimationManager)

return function(character, animationList, animationFolder)
    local root = character:WaitForChild("HumanoidRootPart")
    local manager = AnimationManager.new(character, animationList, animationFolder)

    local simulation = RunService:BindToSimulation(function()
        local velocity = root.AssemblyLinearVelocity
        local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
        if speed > 0.5 then
            manager:Stop("Idle", 0.15)
            manager:Play("Walk", 0.15)
            manager:AdjustSpeed("Walk", speed / 16)
        else
            manager:Stop("Walk", 0.15)
            manager:Play("Idle", 0.15)
        end
    end)

    -- The caller owns this binding and disconnects it when retiring the character.
    return function()
        simulation:Disconnect()
        manager:Destroy()
    end
end
```

For a one-shot animation, invoke `Play` on the simulated action transition, not every frame while a button stays down. Store previous-input/action state in attributes on a predicted instance so rollback can restore it. A plain Lua boolean or a queue drained once outside simulation will not replay correctly. Set up event subscriptions outside simulation as well.

## Sets and registration

- `LoadCore` and `LoadIndividualTrack` register animation definitions without creating tracks. Core definitions are registered by the constructor. Core/individual registration and removal are configuration operations; perform them outside the predicted simulation and keep configuration identical on both sides.
- `LoadSet` and `UnloadSet` configure the local set registry. Like core/individual registration, configure this outside predicted simulation and keep it identical on both sides. These Lua tables and `_currentSet` are not synchronized or rewound. For gameplay-dependent selection, keep authoritative selection in the consumer's synchronized state; this simple manager does not provide rollback-aware set switching.
- `OnSetChanged` is a local notification of explicit set changes, not a command transport or rollback notification. It does not emit an initial event when subscribed.
- Unloading removes registrations even when no track exists. Tracks still referenced by another group are retained. Unreferenced tracks are stopped and destroyed on `Ended`; already inactive, zero-weight tracks are destroyed immediately. Deferred cleanup rechecks registrations so unloading and reloading during the fade does not destroy a reclaimed track. This one-shot cleanup survives manager destruction.

## Track events and cleanup

`MarkerReached(name, markerName, callback)` and `OnTrackStopped(name, callback)` return an `RBXScriptConnection`, or `nil` if no track exists. They observe the current track only. Automatic reconnection is intentionally deferred: disconnect and subscribe again when that track is replaced. Do not treat these helpers as rollback-resilient gameplay events.

These are observational engine events, not an exactly-once, replayable gameplay timeline. They do not reconstruct markers that occurred before attachment, and rollback may repeat or invalidate predicted observations. Use them for presentation; derive authoritative damage and action timing from synchronized simulation state. Connect before starting playback when possible.

`GetLoadedTracks()` returns a snapshot of current track handles: a flat list plus core, set, and individual maps. Shared IDs may appear more than once in the flat list. Do not cache its results across simulation frames. `GetLength()` returns `nil` if no track is available; Roblox may report zero before an asset has loaded. `IsPlaying()` uses the actual `IsPlaying` property, so a stopped track fading out is not considered playing.

`Destroy()` disconnects observations, stops managed tracks, and makes subsequent playback calls inert. It is also called on character destruction or player removal. Predicted Humanoid death does not destroy the manager, because death may be rolled back. Consumers must disconnect their own simulation binding when retiring the character.

`BindRemote()` and automatic `AnimationEvent` creation have been removed. Drive gameplay animations from the same simulation logic on both sides.

## Regression checks

Import `tests/AnimationManager.spec.luau` as a ModuleScript in a Studio test place and call it outside simulation:

```luau
require(path.To.AnimationManagerTests)(require(path.To.AnimationManager))
```

The checks exercise missing tracks, repeated play/stop, shared IDs, existing-track subscriptions, local set changes, and idempotent destruction using fake tracks. They do not validate engine replication. Also test a server/client session with simulated latency, misprediction, and character respawn. Studio execution is required for those checks.

## Getting Started
To build the place from scratch, use:

```bash
rojo build -o "AnimationManager-ServerAuthority.rbxlx"
```

Next, open `AnimationManager-ServerAuthority.rbxlx` in Roblox Studio and start the Rojo server:

```bash
rojo serve
```

For more help, check out [the Rojo documentation](https://rojo.space/docs).
