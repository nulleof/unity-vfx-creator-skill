# Visual brief version 1

A brief describes one effect with one attachment and playback mode. The caller owns the gameplay event and supplies the intended look. Describe timing in seconds and scale in Unity world units when known. Include silhouette, palette, motion, when the effect should read, and how much space it can cover.

```json
{
  "version": 1,
  "id": "frost-status-aura",
  "description": "A thin mint ring 1.2 Unity units across, with sparse rising ice chips. Readable from above. Fade within half a second of status removal.",
  "mode": "loop",
  "attachment": {
    "anchor": "Follow the affected character's feet",
    "orientation": "Align the prefab's local Y to world up"
  },
  "capture": { "cameraPitch": 48, "framing": 2.5, "duration": 2 }
}
```

`version`, `id`, `description`, `mode` and both attachment strings are required. IDs use 1–64 lowercase letters, digits and hyphens, beginning with a letter or digit. The attachment tells the caller how to position and rotate the prefab.

Use `Build -Recipe <path> -EffectBrief <path>` to build and capture the effect. The optional `capture` object accepts `size` (384 pixels square by default), `fps` (30), `duration` (1.2 seconds), `framing` (3 world units across the orthographic view), `cameraPitch` (0 degrees), `travel` (0 units along X), `arc` (0 units along Y), and `seed` (1729). A trail needs nonzero `travel` or `arc`. Set the output ID in the brief. If supplying `-Output`, use a new or empty directory. Keep the final recipe and any original texture resources so the effect can be rebuilt.

The command returns `prefab`, `recipe`, `capture` and `effect` paths. The capture contains ordered PNG frames and `capture.json` with per-frame measurements. Trail previews draw the sampled path with the trail's material, width and color profile. The prefab uses Unity's `TrailRenderer` to follow actual movement.

`effect.json` contains `version`, `id`, the project-relative `prefab`, `mode`, `attachment` and `startEmitters`. Each emitter address is a slash-separated sequence of zero-based child indices from the prefab root. For example, `0/2` resolves with `root.GetChild(0).GetChild(2).GetComponent<ParticleSystem>()`. Resolve addresses against the exported prefab's hierarchy. A trail with no particle accents has an empty emitter list.

During authoring, the recipe's `playOnAwake` flags select which particle systems the caller should start directly. The default selects a particle layer. Linked sub-emitters are excluded automatically. The exported effect has its automatic particle startup and trail emission turned off.

## Playback in Unity

1. Acquire or instantiate the effect and place it at the brief's attachment. Before reuse, run `Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear)` on each particle system in the instance. With trail emission off, call `Clear()` on each `TrailRenderer` before enabling emission at the new position.
2. On the gameplay event, call `Play(false)` once on each system in `startEmitters`. For a trail, enable `emitting` on all trail renderers and move the prefab with its attachment. The prefab's child sub-emitters are driven by their parent systems.
3. A `oneShot` completes after `IsAlive(true)` is false on the start emitters. For a `loop` or `trail`, call `Stop(false, ParticleSystemStopBehavior.StopEmitting)` on the instance's particle systems at the end of the event. For a trail, also set `emitting = false`, keep the effect object alive for the longest `TrailRenderer.time`, and let remaining particles finish. If the attachment disappears, keep the world transform as the effect fades. Return the instance to its pool or release it once playback is complete.

A `oneShot` needs at least one start emitter and uses non-looping particle systems. A `loop` needs at least one looping start emitter. A `trail` needs a `TrailRenderer` layer and can use particle accents. Particle System trails inside a particle layer are available to all three modes.
