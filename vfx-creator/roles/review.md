# Review render and integration

Inputs are the completed prefab and its clean-project capture. Reconstruction additionally uses a reference capture with the same camera, duration, resolution, sampling step and seed. Compare draft and final for new variants.

Render against a dark background. Inspect motion at speed and onset, peak, and fade frames. Run `Compare` for side-by-side frames, absolute differences, foreground IoU, color error and onset/peak/end timing. Check the import receipt for dependencies and any missing shader or script. A clean-project render with no visible output is a failure.

Initial similarity is a human decision. Use the report to verify silhouette, changes in speed, palette, layer relationships and dissipation. Record per-case numeric limits after approval for regression checks. Pixel equality is reported independently.
