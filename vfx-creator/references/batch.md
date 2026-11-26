# Build an effect set

Use the [visual brief](visual-brief.md), [recipe format](recipes.md), [authoring guidance](../roles/author.md) and [review guidance](../roles/review.md).

1. Keep the user's list order and assign each effect a stable ID. Set shared palette, camera and scale from the request and project. Write a brief and editable recipe per effect, with its defining silhouette, timing and role in the set. Reuse layers where a family should look related. Set a capture long enough to see each effect's important phases.
2. Build all drafts in a separate URP project with the same Unity release as the target. Use the existing `Init` command when a compatible disposable project is needed. Keep drafts and captures in an ignored working directory. Open the batch gallery, then inspect the full frame sequence and `capture.json` around the moments that matter. Check contact and fade for an impact, appearance and sustained silhouette for an aura, and trajectory, taper and tail for a trail. When the brief gives a size or fade deadline, check the measured bounds or first clean frame. Use Play Mode when a brief requires verification of release or reuse. A successful build can still be clipped or fail the visual brief.
3. Revise only the effects that need it and build that subset once in the draft project. Give revision builds temporary IDs in copies of the briefs and keep the original IDs for delivery. Compare the revised captures with their briefs and keep the previous captures for context. If an effect still misses the brief, record the reason.
4. Build the accepted recipes in the game project with their original IDs. Check the final captures because the project's rendering settings may differ. Deliver a single summary in the original list order with a status, recipe, prefab, preview and `effect.json` for each delivered effect. Include the exact blocker for every unfinished entry. Link the final gallery for visual browsing and the draft or revision capture when it explains a blocker.

## BuildBatch command

Run the pipeline with a manifest and a fresh or empty output directory.

```powershell
& $vfx BuildBatch -Project '<unity-project>' -Manifest './batch-input.json' -Output './.vfx-work/batch-output'
```

```json
{
  "version": 1,
  "items": [
    { "recipe": "amber-impact.recipe.json", "effectBrief": "amber-impact.brief.json" },
    { "recipe": "wind-aura.recipe.json", "effectBrief": "wind-aura.brief.json", "resourceRoot": "textures" }
  ]
}
```

Paths in the manifest are relative to its directory. Absolute paths work too. If omitted, `resourceRoot` is the recipe's directory. Each output ID and capture settings come from its effect brief. A batch launches Unity once and runs the items in order. The timeout covers the whole Unity session and defaults to 60 minutes. Keep the target editor closed during the run.

Open `index.html` for key frames, measurements and playback manifests. `batch.json` and the returned object have the same ordered results. Check `ok` before treating a batch as complete. An item can be `succeeded`, `failed` or `interrupted`. Unity writes each completed receipt under `receipts/` before starting the next item. A recipe error or occupied ID affects its own item. Duplicate IDs invalidate the manifest before Unity launches. Use the per-item results and Unity log to diagnose a failure, then build the failed or interrupted subset in a fresh output directory. If an interrupted item already has a prefab, inspect it and its output before retrying. An occupied ID preserves the existing asset and GUID.
