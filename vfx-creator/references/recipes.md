# Recipe version 1

Every recipe is one JSON file in `catalog/`. Required fields are `version: 1`, `id`, `title`, `description` and `layers`. IDs use lowercase letters, digits and hyphens. Give `tags` recognizable synonyms in the languages used for briefs. `duration` is in seconds and `seed` controls procedural textures and particle initialization.

Each layer describes its `name`, `phase`, local transform and `kind` (`particles` or `trail`). Positions, sizes and distances use Unity world units, euler rotations use degrees and particle rotations use radians.

- Particle timing fields are `duration`, `delay`, `lifetime`, `loop`, `prewarm`, `playOnAwake`, `bursts`, `rate`, and `distanceRate`. Burst entries can specify `time`, `count`, `cycles`, `interval` and `probability`.
- Shape settings include `type` (a Unity shape name), `radius`, `thickness`, `angle`, `arc`, `length`, local transform and random/spherical direction. Motion fields include curves for `speed`, `size`, `gravity`, `rotation`, `sizeOverLife`, `spinOverLife` and per-axis velocity, plus `noise` and `noiseFrequency`. `subEmitters` link to other layer indices using `layer`, `trigger`, `inherit` and `chance`.
- `startColor` and `colorOverLife` use palette objects. A constant palette is `{"max":{"r":1,"g":0.4,"b":0.1,"a":1}}`. A gradient uses `mode: "gradient"`, `gradient.colors` and `gradient.alpha`, each an array of time/value pairs with times normalized between 0 and 1. Palette modes also include `twoColors`, `twoGradients` and `randomColor`.
- A constant curve is `{"max": 0.25}`. Use `mode: "twoConstants"` with min/max for ranges, or `mode: "curve"`, `multiplier: 1` and `keys` with time/value pairs and optional tangents. `twoCurves` uses both `minKeys` and `keys`.
- Material fields are `tint` (RGBA), `blend` (`add` or `alpha`), `glow` and optional depth fade `softness`. Texture kinds are `glow`, `star`, `spark`, `ring`, `smoke`, `curl`, `crescent`, `streak`, `flame` and `bubble`. Control them with `resolution`, `falloff`, `detail` and `spokes`. Specify `tilesX`, `tilesY` and `frameOverLife` for animated textures or `png` for an original image relative to `-ResourceRoot`.
- A `trail` object configures lifetime, width and color. On particle layers it controls particle trails; on trail layers it controls a Trail Renderer that a gameplay transform or the preview rig moves. The renderer also accepts a render mode, camera alignment and stretch settings.

Layers default to billboard particles. Specify at least one burst or a nonzero rate to emit visible particles. Set longer action timing explicitly on the recipe and use `-Duration` for the capture window. Build outputs live in `Assets/VfxCreatorGenerated/<id>/`; use a distinct ID for a draft or a revision whose prefab needs to coexist with the previous one.

An analyzer export includes `enabledModules` because Unity's JSON serializer expands empty module objects. When editing an exported recipe, update that list along with the corresponding module fields. When authoring a recipe by hand, omit the list and the builder enables the modules present in the JSON.

Reference and rebuilt captures use the same `-Size`, `-Framing`, `-Fps`, `-Duration`, `-Travel`, `-Arc` and `-Seed`. For a moving Trail Renderer, set a nonzero `-Travel` or `-Arc`. A limit file can specify `minForegroundIoU`, `maxMeanColorError`, `maxOnsetFrameDelta`, `maxPeakFrameDelta` and `maxEndFrameDelta` after visual approval.
