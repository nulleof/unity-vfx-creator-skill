# Visual brief version 1

A brief describes one effect with one attachment and playback mode. The caller owns the gameplay event and may supply any part of the intended look. Complete the brief from the request and available game context. Record authoring assumptions in the description when the caller leaves details open. Describe timing in seconds and scale in Unity world units when known.

Use these criteria to turn a short request into decisions:

- **Strongest moment.** For a hit or activation, choose the event that should get the player's attention. Specify when it happens and the change in size, contrast, speed or shape that makes it stand out. A multi-beat one-shot has one main accent. A sustained effect needs a readable appearance, stable identity and a deliberate release.
- **Silhouette and scale.** Set the main shape and its projected size relative to a character, target or gameplay area. Leave space around it so accents and the background do not obscure its read.
- **Rhythm and mass.** Set the relationship between anticipation, movement, contact and decay. Give the main body, trail, smoke and fragments timings that reflect their different weight and roles.
- **Visual character.** Use color, edge quality, light and movement to describe the same material or kind of energy. Put the strongest accent at the gameplay event.
- **Bounded variation.** Decide what changes between uses, such as initial orientation, spin, directions, ray lengths or accent timing. Keep the event time, point of contact and gameplay bounds precise.
- **Intentional asymmetry.** Natural flashes can use a dense core, a few dominant rays and shorter rays at uneven angles. Keep regular geometry when it communicates the intended material, pattern or status.

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
