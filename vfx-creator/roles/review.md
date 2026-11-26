# Review render and integration

Inputs are the brief, completed prefab and its clean-project capture. For blind reconstruction, wait for the candidate to be frozen before opening the reference. Check that reference and candidate use the same camera, duration, resolution, sampling and seed, plus the same preview trajectory where applicable. Compare draft and final for new variants.

For a gameplay prefab, check the defining shape, scale, palette and read time from the brief's camera. Review the onset, peak and decay of a one-shot, several steady-state samples of a loop, or the tapered path of a trail. Inspect `effect.json` alongside the prefab and use the [playback sequence](../references/visual-brief.md#playback-in-unity) to check start, stop and reuse in Play Mode when available. The capture uses stepped simulation, so inspect the runtime lifecycle in Play Mode before claiming it has been verified there.

Render against a dark background. Inspect motion at speed and onset, peak, and fade frames. Run `Compare` for side-by-side frames, absolute differences, foreground IoU, color error and onset/peak/end timing. Check the import receipt for dependencies and any missing shader or script. A clean-project render with no visible output is a failure.

Use the foreground-area plot and pixel bounds to check alignment and scale. For each beat, record the onset, peak, end and projected width and height on representative frames. Check for quiet intervals and late shapes that outlast the flash. For a loop, report visible-frame coverage and typical silhouette area after buildup, then inspect motion across several cycles. For a moving effect, check trajectory, width and wake persistence at matched times. Check for clipping before attributing a size difference to the recipe.

Use the report to verify silhouette, changes in speed, palette, layer relationships and dissipation. Give frame or time evidence for the largest mismatches. Initial similarity is a human decision. Record per-case numeric limits after approval for regression checks, and report pixel equality independently. Keep the blind result available if a later revision uses the reference directly.
