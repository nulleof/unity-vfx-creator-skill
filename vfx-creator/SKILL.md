---
name: vfx-creator
description: Deliver ready-to-play Unity URP VFX prefabs from visual briefs or plain text, with a preview and playback instructions. Use for gameplay impacts, projectile trails, status auras, particles, magic, smoke and bursts, or to learn and verify effects from local reference packs.
---

# VFX Creator

This folder is the whole skill. Use PowerShell 7.4+ and an installed Unity editor. Run [the pipeline](scripts/vfx.ps1) using its full path from the target repo. Find the Unity root by `ProjectSettings/ProjectVersion.txt` and `Packages/manifest.json`.

## Create or adapt

1. Read the [visual brief and playback format](references/visual-brief.md), [authoring](roles/author.md) and the [recipe format](references/recipes.md). A short request is enough. Fill gaps in the brief yourself, respecting the caller's stated intent. Decide which moment the player should notice most, what makes it read from the gameplay camera, and what can vary between plays. Design the effect and hand it back for the calling chat to connect to gameplay.
2. Plan the defining moment and silhouette, then run `Find` with the description and the [visual signature](references/signatures.md) fields supported by the brief. Reuse helpful layers and synthesize the defining shapes where needed. Build a draft with `Build -Recipe <path> -EffectBrief <path>` under a distinct ID.
3. Review the draft at gameplay speed and on the frames around the strongest moment. For effects with visual variation, inspect three plays with the same camera and different seeds. Tune projected size, timing, motion and contrast. Build under the requested final ID and inspect the final capture as described in [review](roles/review.md). Return the editable recipe, prefab, preview and `effect.json` with runtime playback instructions.

## Learn

Read [analysis](roles/analyze.md). Use `Inventory` to discover effects and nested archives. Group the effects by action, silhouette and timing so that variants can teach shared construction patterns. Use `Learn` on representative prefabs to collect structured metadata and local reference captures. Translate the visible behavior into editable layers and validate the reusable recipe in a clean project. Add useful, distinct recipes to `catalog/` with descriptive titles, aliases and layer names. Keep source asset content and reference frames outside the skill directory.

## Verify

For blind tests, let analysis prepare a source-free brief from the reference. Give a fresh authoring session this folder, the brief and a clean game project. Freeze the candidate recipe, prefab and capture before giving the reviewer reference frames. Review-guided revisions can follow as a separate pass. Evaluate visual similarity and record pixel differences alongside the qualitative result. See [review](roles/review.md).

When delegating, give analysis and review to sessions that can inspect Unity captures and timed frame evidence. Give authoring to a session that can build and iterate Unity recipes. Pass each role its own inputs as described in the role files.
