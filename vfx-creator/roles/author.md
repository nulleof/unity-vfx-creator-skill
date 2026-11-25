# Author an effect

Inputs are the brief, relevant catalog recipes and a clean Unity URP project. Return a draft and a final prefab, their recipes and render directories. A blind run receives no pack, source path or reference frames.

Keep phases synchronized around a single recognizable action. Establish duration, silhouette, trajectory and scale in the draft. For the final, make shape, emission and decay readable independently. Use detailed procedural textures and unequal layer timings before adding more particles. Preserve identifiable aspects of the requested effect when changing its color or scale.

The editor bridge creates its own URP materials and masks. If a procedural mask misses an important shape, generate an original PNG from the recipe's prose, with transparent background and clear edges. Pass it using `-ResourceRoot` and record the relative PNG path in the texture recipe. A project receiving the prefab uses the copied texture in the prefab's output folder.

For externally triggered impacts or world-space trails, attach the corresponding prefab or named child to the gameplay event or moving transform as described by the brief. The preview rig can drive test motion and timing.
