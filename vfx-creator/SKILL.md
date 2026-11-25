---
name: vfx-creator
description: Create, adapt, learn and visually verify layered Unity URP effects from text or local reference packs. Use for particles, stylized projectiles, trails, impacts, magic, smoke, bursts and matching or improving the look of an effect.
---

# VFX Creator

This folder is the whole skill. Use PowerShell 7.4+ and an installed Unity editor. Run [the pipeline](scripts/vfx.ps1) using its full path from the target repo. Find the Unity root by `ProjectSettings/ProjectVersion.txt` and `Packages/manifest.json`.

## Create or adapt

1. Read [authoring](roles/author.md) and the [recipe format](references/recipes.md). Run `Find` with the brief and inspect the closest recipes. If the brief describes a new effect family, look for reusable individual layers such as a timed core, a ribbon or a dissolving contour. Use the request's timing, camera, palette and changed properties to decide which layers to reuse or synthesize.
2. Write a draft recipe with the action phases and a simple visual per phase. Build it to its own output ID and render it. Refine the final recipe using measured curves and distinct core, contour, secondary motion and fade layers where the effect needs them.
3. Build the final prefab and render it. Check both movement and still frames as described in [review](roles/review.md). Return the prefab path, a preview or report, and any adjustment that affects integration.

## Learn

Read [analysis](roles/analyze.md). Use `Inventory` to discover effects and nested archives. Run `Learn` on a chosen prefab to collect structured metadata and a local reference capture. Inspect the capture and tune the candidate recipe before adding the JSON into `catalog/`. Use descriptive titles, aliases and layer names. Keep source asset content and reference frames outside the skill directory.

## Verify

For blind tests, give a fresh authoring session this folder, the text brief and a clean game project. Run comparison only after authoring has delivered the prefab. Evaluate reconstruction as visual similarity, and record pixel differences alongside the qualitative result. See [review](roles/review.md).
