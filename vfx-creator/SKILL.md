---
name: vfx-creator
description: Create, adapt, learn and visually verify layered Unity URP effects from text or local reference packs. Use for particles, stylized projectiles, trails, impacts, magic, smoke, bursts and matching or improving the look of an effect.
---

# VFX Creator

This folder is the whole skill. Use PowerShell 7.4+ and an installed Unity editor. Run [the pipeline](scripts/vfx.ps1) using its full path from the target repo. Find the Unity root by `ProjectSettings/ProjectVersion.txt` and `Packages/manifest.json`.

## Create or adapt

1. Read [authoring](roles/author.md) and the [recipe format](references/recipes.md). Run `Find` with the brief. Choose a template by silhouette, motion and lifetime. Borrow individual layers or synthesize the defining shapes when the catalog only matches part of the effect.
2. Draft the action phases and their dominant shapes. Build under a draft ID and render with the intended camera and motion. Use the candidate's own frames and `capture.json` timeline to tune projected size, phase timing, motion and brightness against the brief.
3. Build the final prefab and render it. Check motion and key frames as described in [review](roles/review.md). Return the final recipe, prefab path, a preview or report, and any gameplay trigger or attachment requirements.

## Learn

Read [analysis](roles/analyze.md). Use `Inventory` to discover effects and nested archives. Group the effects by action, silhouette and timing so that variants can teach shared construction patterns. Use `Learn` on representative prefabs to collect structured metadata and local reference captures. Translate the visible behavior into editable layers and validate the reusable recipe in a clean project. Add useful, distinct recipes to `catalog/` with descriptive titles, aliases and layer names. Keep source asset content and reference frames outside the skill directory.

## Verify

For blind tests, let analysis prepare a source-free brief from the reference. Give a fresh authoring session this folder, the brief and a clean game project. Freeze the candidate recipe, prefab and capture before giving the reviewer reference frames. Review-guided revisions can follow as a separate pass. Evaluate visual similarity and record pixel differences alongside the qualitative result. See [review](roles/review.md).

When delegating, give analysis and review to sessions that can inspect Unity captures and timed frame evidence. Give authoring to a session that can build and iterate Unity recipes. Pass each role its own inputs as described in the role files.
