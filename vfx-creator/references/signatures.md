# Visual signatures for recipe search

Pass a JSON object to `Find -Brief <text> -Signature <json>`. Include the fields that the brief specifies. Any field may be omitted.

| Field | Accepted values |
| --- | --- |
| `mode` | `oneShot`, `loop`, `trail` |
| `silhouette` | `star`, `ring`, `vortex`, `cloud`, `crescent`, `specks`, `angular`, `orb`, `beam`, `column`, `text`, `ribbon`, `figurative` |
| `motion` | `hold`, `travel`, `expand`, `contract`, `rotate`, `drift`, `sweep`, `rise`, `fall` |
| `beatCount` | Positive integer counting distinct visual phases |
| `visibleDurationSec` | Positive finite number in seconds for an effect with an observable end |

Describe the dominant shape and movement. Use `travel` for a moving effect center, `drift` for the gradual motion of dispersed marks, and `trail` when the effect must leave a renderer-driven wake. A continuous effect can omit duration. In a preview with a visible end, duration counts one sample interval per frame from the first through the last visible frame, including gaps between phases.

Search prefers more matching categorical fields and then fewer conflicts. It breaks ties by distance in phase count, distance in duration, keyword score, and recipe ID. The result includes the recipe path and the keyword score. A text-only request uses keyword scoring.

The [catalog signatures](../catalog-signatures.json) describe previews of the stock recipes. A recipe without a signature is searchable by text. Add a signature under its recipe ID after previewing its shape, movement and timing.
