# UI effects in Unity

Use this workflow for screen-space feedback attached to a uGUI control. The supported setup is Unity 6000.6.8f1, URP, and a Screen Space – Overlay Canvas with `com.unity.ugui` installed. Build from a closed project and open the exported clips in Unity's Animation window to edit or preview each layer.

## Author the brief and recipe

Pick the event and control first. Keep feedback for frequent events compact and immediate. Give a reward a larger accent, and give the player a way to skip it. Put important results in a persistent control state, icon, or label. Place the result and its controls inside the game's safe area and keep them legible at peak intensity. Use a stationary fade as the reduced-motion cue and avoid strobing or rapid high-contrast changes, including during repeated or overlapping plays.

A UI brief is a JSON object with these required fields. The [button brief](../examples/ui/ui-button-confirm.brief.json) is a complete example.

| Field | Value |
| --- | --- |
| `version`, `id` | Version `1` and a unique ID of 1–64 lowercase letters, digits or hyphens, starting with a letter or digit. |
| `description`, `trigger`, `target` | The intended appearance, game event and named UI control. |
| `anchor` | `{x, y}` from 0 to 1 along each axis, measured from the target's bottom-left. The effect area is centered here. |
| `footprint` | `{x, y}` between 0.01 and 4, giving the effect area's width and height as multiples of the target's width and height. Animation can extend beyond that area. |
| `order` | `aboveContent` or `belowContent`. The game uses this to set the prefab's sibling position relative to target content. |
| `clipping` | `target` clips to the mounted target rectangle. `inherit` uses clipping from the parent hierarchy. |
| `retrigger` | `restart` restarts the same instance from time zero. `ignoreWhilePlaying` waits for the instance to finish or be cancelled. |
| `reducedMotion` | Describe the stationary cue and the persistent UI state that carries the result. |

The UI recipe has `version: 1` and a `layers` array in back-to-front draw order. Each layer has a unique `name`, `shape` (`glow`, `ring`, `star`, or `spark`), `color` (`#RRGGBB`), `size`, and a `standard` track. Use letters, digits, spaces, underscores, and hyphens for the name, beginning with a letter or digit. `size` is `{x, y}` in fractions of the effect area, each between 0.01 and 4. Every `standard` key contains `time`, `position`, `scale`, and `opacity`. Position is `{x, y}` relative to the effect area, with `(0, 0)` at its bottom-left and `(1, 1)` at its top-right. Components can extend from -2 to 3 for travel beyond the area. Scale is a multiplier between 0 and 4.

A layer can also include `reduced` with a single fixed `position`, a fixed `scale` between 0.01 and 4, and `keys` containing only `time` and `opacity`. Layers without a reduced track are hidden in that clip. Each track starts at zero seconds, has strictly increasing times, lasts between 1/60 and 10 seconds, and ends with zero opacity. Opacity ranges from 0 to 1. Include a visible layer in each variant. Keys interpolate linearly. See the [button recipe](../examples/ui/ui-button-confirm.recipe.json), [ability recipe](../examples/ui/ui-cooldown-ready.recipe.json) and [reward recipe](../examples/ui/ui-reward-reveal.recipe.json).

## Build and connect

```powershell
$skill = './.agents/skills/vfx-creator'
$pilot = "$skill/examples/ui/ui-button-confirm"
& "$skill/scripts/vfx.ps1" BuildUi -Project . -UiBrief "$pilot.brief.json" -Recipe "$pilot.recipe.json"
```

The receipt points to the original `recipe`, the project-relative `prefab`, and the `effect` handoff `ui-effect.json`. The handoff gives `canvas`, `placement` (the UI brief), `idleState`, `standardState`, `reducedState`, `standardDurationSec` and `reducedDurationSec`. Choose a fresh ID for a draft or revision. If specifying `-Output`, use a fresh or empty directory. Keep the recipe and brief to rebuild the generated sprites, prefab and clips.

Instantiate one prefab under the target's `RectTransform`. The prefab stretches to that rectangle. If a layout group positions the target's children, mount the prefab inside a dedicated host sized to fill the target and excluded from that layout. Set the effect or host as the first or last sibling according to `placement.order`. For `inherit`, place the host inside the existing mask. Use the Canvas that owns the target's content and input.

At the game event, update the persistent UI state first. Queue the Animator state during input handling or `Update` so Unity samples it before rendering. Use the full state names from the handoff. Keep `lastStartFrame` on the effect instance, initialize it to `-1`, and use it to handle multiple events before Unity evaluates the next state.

```csharp
if (allowRestart || (lastStartFrame != Time.frameCount && animator.GetCurrentAnimatorStateInfo(0).IsName(idleState)))
{
    animator.Play(reducedMotion ? reducedState : standardState, 0, 0f);
    lastStartFrame = Time.frameCount;
}
```

Both variants return to the hidden `Idle` state automatically and animate even while the game is paused. For immediate clearing on skip or before hiding the UI, call `animator.Play(idleState, 0, 0f)` followed by `animator.Update(0f)` and reset `lastStartFrame` to `-1`. Leave the outcome visible until the game's UI state changes.

Review in the target Canvas at gameplay speed. Trigger several quick actions and play overlapping cues. Verify that taps still reach the controls, masks and sorting behave in context, the result stays readable, and closing and reopening the screen starts with a clean effect.
