# Author an effect

Inputs are the brief, relevant catalog recipes and a clean Unity URP project. Return a draft and a final prefab, their recipes and render directories. A blind run receives no pack, source path or reference frames.

Keep phases synchronized around a single recognizable action. Establish duration, silhouette, trajectory and scale in the draft. For the final, make shape, emission and decay readable independently. Use detailed procedural textures and unequal layer timings before adding more particles. Preserve identifiable aspects of the requested effect when changing its color or scale.

For each visible layer, decide its onset, emitter duration, particle lifetime, location, direction of motion and change in size and opacity. Translate the brief's distances into world units at the requested camera angle. For example, decide whether a ring lies flat on the ground or faces the viewer before picking its renderer and size. Establish the large silhouette with a few readable shapes before adding small accents.

If enlarging a billboard fails to enlarge its rendered bounds, check its camera-relative size limit and adjust `maxScreenSize` on that layer. Use the view's intended framing when verifying the change.

For an effect with distinct beats, use independently timed layers for each beat. Give a delayed burst its own phase and check the last visible frame of the first beat, the start and peak of the next one, and the final fade. A long capture window does not require long particle lifetimes.

For a sustained effect, use looped, rate-based emission for moving accents and a continuously visible anchor such as a ground ring. Space bursts and lifetimes so overlapping cycles sustain the silhouette, or use prewarm for an effect that should start in steady state. Inspect a window after the initial buildup and compare several points across cycles for gaps, size drift and unwanted flashes.

The editor bridge creates its own URP materials and masks. If a procedural mask misses an important shape, generate an original PNG from the recipe's prose, with transparent background and clear edges. Pass it using `-ResourceRoot` and record the relative PNG path in the texture recipe. A project receiving the prefab uses the copied texture in the prefab's output folder.

For externally triggered impacts or world-space trails, attach the corresponding prefab or named child to the gameplay event or moving transform as described by the brief. The preview rig can drive test motion and timing.
