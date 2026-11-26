# Shape and timing

Use this pass for a changing silhouette, several beats or prominent motion. Work at the camera and actor scale used by the game. Keep the actor, target or gameplay boundary in the preview when available.

1. Sketch the poses you need to read. Mark the action's origin, direction and contact. For a one-shot, sketch the opening, contact or release, widest pose, breakup and residue. For a sustained effect, use buildup, steady state and the first and last release poses. Use the same anchor across poses.
2. Build a grayscale block-in with the intended playback and size. Use a simple solid mass, a brighter focal mark and a quieter wake or residue where the brief calls for them. Play it once at speed. Sample the frames where scale, overlap, motion or timing are easiest to misread.
3. Make one measured correction. On the chosen frames, record the contact time, projected width against the actor, last readable silhouette and last residue. For a trail, also measure the head position against its moving anchor, the width just behind it and the time from stop to clear. The `capture.json` timeline measures all foreground together. Inspect the relevant pixels or render a layer in isolation when the halo or fragments skew its bounds. Record the changed timing, size or curve and check it in a new capture.
4. Finish the surfaces and accents. Use a flipbook for a specific change of outline or internal gaps, curves for scale and movement, and separately timed layers for flashes and residue. Review the full color effect at speed, at the gameplay zoom and on light and dark surfaces. Check that overlap leaves the actor and event readable.

## Worked examples

Each JSON is an editable version 1 recipe. Paths to PNGs are relative to the skill root, which should be passed as `-ResourceRoot`. Use the named frames as review targets and adjust them for the game's event schedule.

| Example | Key poses and layers | Common failure and correction |
| --- | --- | --- |
| [Verdigris contact arc](../examples/verdigris-arc.json) | At 0.07 s the motion starts to open. At 0.12 s a compact flash marks the fixed contact on the right. Around 0.19–0.25 s the opaque rim peaks and the flipbook separates into two pieces. At 0.42 s only falling flakes should remain. | A moving flash makes the point of contact ambiguous. Pin it to the target and time it independently of the maximum sweep. Preserve the dark inner edge on a light ground. |
| [Saffron foam front](../examples/saffron-front.json) | A pinched charge releases at 0.15 s. Around 0.40–0.48 s the crest has reached its broad pose and opens into bands. At 0.70 s the leading mass has gone and detached chips remain. A velocity curve advances the front while world-space residue occupies the earlier path. | Uniformly fading a static stripe reads as a blink. Move the front while its outline opens, then leave staggered chips on the route it passed. |
| [Prism dart and split wake](../examples/prism-dart.json) | At 0.30 s and 0.60 s, compare the violet head with the root and the width just behind it. The head is a short, faceted shape on the moving root. A wide plum wake and a thinner, shorter filament taper independently. With the example trajectory, stop at 0.90 s and inspect the last wake point through 1.14 s. | A broad or long wake can dominate after the head has gone. Shorten its history and taper it from the root toward the tail. Keep loose accents in world space. |

Use the examples as layer studies. For a paper or ink material, change the outline, contrast and breakup as well as the palette. Keep the event placement and the motion rules from the new brief.

## Review at gameplay scale

Judge four things independently and cite a time or frame. Readability covers the event, direction and footprint. Silhouette covers the main contour and its internal gaps. Rhythm covers the setup, strongest moment, transition and tail. Style covers whether the edges, material, motion and accents belong together. Treat a misleading event, direction or area as a gameplay failure even when the frame is attractive.

Further study is available in [Riot's gameplay clarity guide](https://www.leagueoflegends.com/en-us/news/dev/clarity-in-league/), [Keyser's timing block-ins](https://realtimevfx.com/t/block-ins-and-timing/29830), [Lyndon's VFX animation talk](https://media.gdcvault.com/gdc2018/presentations/Lyndon_Michael_ZipThwackPing.pdf) and [Octopo's cartoon effects curriculum](https://coloso.global/en/products/vfxstudio-octopostudio-us).
