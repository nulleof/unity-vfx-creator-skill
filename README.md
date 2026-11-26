# VFX Creator

VFX Creator is a portable Codex skill for building editable, layered visual effects in Unity URP from a text brief and a catalog of reusable recipes. It can also inspect local effect packages, learn recipes from prefabs, and render captures for review.

The installable skill is the complete [`vfx-creator/`](vfx-creator/) directory. The repository also contains development checks and evaluation scripts.

See the [roadmap](ROADMAP.md) for planned work on mobile UI effects.

## Features

- Create particle and trail effects as editable Unity prefabs.
- Build and preview a gameplay prefab from a visual brief, with a JSON handoff for playback.
- Build editable uGUI Overlay feedback with standard and reduced-motion clips and a JSON handoff.
- Design and preview a set of effects together, then build the accepted prefabs in one Unity session.
- Find a starting recipe from a brief, then adapt or combine layers.
- Generate textures, materials and shaders used by the effect.
- Inventory local `.unitypackage` files and nested archives; learn recipe metadata from selected prefabs.
- Render previews and compare a candidate against a reference capture.
- Keep reusable recipes in a small JSON catalog.

Build output is written to `Assets/VfxCreatorGenerated/<id>/`. Composite effects keep their phases as separate child objects, so they can be inspected or triggered independently in a game.

## Requirements

- Codex with skills enabled.
- PowerShell 7.4 or later.
- Unity Editor installed. The target project must include URP and its Unity version must match the installed Editor. Reference captures in this repository use Unity `6000.6.8f1`.
- Close the target project in Unity while running build or capture commands.

## Install

Copy the whole `vfx-creator` directory into the Unity project's `.agents/skills/` directory. The resulting path should be `.agents/skills/vfx-creator/`.

Then open a new Codex session in that Unity project and try a request such as:

> `$vfx-creator Create a short icy flash with a long trail and impact sparks.`

For example, the generated prefab will be at `Assets/VfxCreatorGenerated/<id>/Effect.prefab`, alongside its materials, textures and shader. Open it in Unity to edit it. A Trail Renderer preview can use `-Travel` and `-Arc`; at runtime, move the GameObject that owns the trail.

If Unity is installed outside a standard Unity Hub location, pass its executable path with `-Editor`.

## Use the pipeline

Run the pipeline from the root of a Unity project or pass `-Project` explicitly:

```powershell
$vfx = './.agents/skills/vfx-creator/scripts/vfx.ps1'

# Find a recipe that resembles the request.
& $vfx Find -Brief 'a compact lilac flash with pink sparks'

# Build and render that recipe in the current Unity project.
& $vfx Build -Project . -Recipe './.agents/skills/vfx-creator/catalog/warm-flash.json' `
    -Id 'warm-flash-preview' -RenderAfterBuild
```

The pipeline also includes `Inventory`, `Learn`, `Render` and `Compare` actions. Run `& $vfx <Action> -?` for the parameters of an action. For a recipe-format reference, see [`vfx-creator/references/recipes.md`](vfx-creator/references/recipes.md). For workflow guidance, see [`vfx-creator/SKILL.md`](vfx-creator/SKILL.md).

Use [visual signatures](vfx-creator/references/signatures.md) to prioritize shape, motion and timing when selecting an editable recipe.

```powershell
& $vfx Find -Brief 'a brief pale glint that quickly contracts' `
    -Signature '{"mode":"oneShot","silhouette":"star","motion":"contract","visibleDurationSec":0.5}'
```

For a prefab you can trigger in gameplay, provide a [visual brief](vfx-creator/references/visual-brief.md) alongside the authored recipe.

```powershell
& $vfx Build -Project . -Recipe './effects/frost-aura-recipe.json' `
    -EffectBrief './effects/frost-aura-brief.json'
```

The brief sets the final ID, attachment, playback mode and preview camera. The build returns the prefab, recipe, capture and `effect.json` paths. Use the manifest to wire a one-shot, a sustained effect or a moving trail to the corresponding event.

For a screen-space UI effect, use a [UI brief and recipe](vfx-creator/references/ui-effects.md) in a Unity 6000.6.8f1 URP project with uGUI.

```powershell
$pilot = './.agents/skills/vfx-creator/examples/ui/ui-button-confirm'
& $vfx BuildUi -Project . -UiBrief "$pilot.brief.json" -Recipe "$pilot.recipe.json"
```

Mount the editable prefab under the target control in an Overlay Canvas. Use `ui-effect.json` for placement, repeat policy and Animator state names. The skill includes starting recipes for button confirmation, ability readiness and reward reveals.

For a set of effects, give the skill the full list in one request. It can preview the draft set, revise selected effects and build the accepted recipes together. To build prepared recipes and briefs directly, use the [batch workflow and manifest format](vfx-creator/references/batch.md).

```powershell
& $vfx BuildBatch -Project . -Manifest './effects/batch-input.json' -Output './.vfx-work/effect-set'
```

Open `index.html` for the preview gallery and `batch.json` for the result of each item.

## Develop and evaluate

Run the local workflow smoke check from the repository root:

```powershell
pwsh -File tests/Test-VfxCreator.ps1
```

To include local source-package inventory or a build and render in a clean URP project, pass `-SourceRoot` or `-UnityProject`:

```powershell
pwsh -File tests/Test-VfxCreator.ps1 -SourceRoot '<path-to-your-effect-packs>'
pwsh -File tests/Test-VfxCreator.ps1 -UnityProject '<path-to-a-clean-urp-project>'
```

Run the UI pilot in a disposable Unity 6000.6.8f1 URP project with uGUI. The fixture needs Windows Standalone build support and a desktop graphics session. It builds all three effects from a fresh copy of the skill and captures the composited menu and HUD in a local Player.

```powershell
pwsh -File tests/Test-UiEffects.ps1 -UnityProject '<path-to-a-disposable-urp-project>'
```

See `.vfx-work/ui-effect-tests-*/` for the playback report, logs and captures. The `compact/` and `tall/` folders contain peak composites in both themes and motion modes. Each `compact/motion/` sequence is a set of 60 FPS frames for reviewing individual effects and rapid overlapping feedback. Check the button, ability state and reward amount for readability throughout playback.

To run the same fixture on a portrait Android phone, install Unity's Android Build Support for 6000.6.8f1, put `adb` on your path, and connect and unlock the phone. Keep it in the foreground during sampling.

```powershell
pwsh -File tests/Test-UiEffects.ps1 -UnityProject '<path-to-a-disposable-urp-project>' -Android
pwsh -File tests/Invoke-UiEffectsAndroid.ps1 -Apk '<reported path to OverlayPilot.apk>'
```

Use `-Serial` when more than one Android device is connected. The development APK uses Vulkan on ARM64 and installs as `org.vfxcreator.overlayreview`. A pause or loss of focus interrupts profiling so measurements can be collected again from a fresh run. Results include native-resolution composites, the measured safe area, three paired runs with 480 frames per pass after warm-up, and the budget verdict. Each metric needs at least 432 samples per pass. The fixture budgets the p95 increase in every pair at 1 ms each for CPU and GPU and 0.5 ms for `Canvas.BuildBatch`. CPU takes the longer of the main and render thread times per frame. The report also records frame pacing against the 60 FPS target. Keep a metric open when the device cannot report it.

Use a disposable Unity 6000.6.8f1 URP project to build and preview the three [gameplay examples](evals/gameplay-briefs.json) from an installed copy, test failed builds, and verify playback in Play Mode.

```powershell
pwsh -File tests/Test-EffectBrief.ps1 -UnityProject '<path-to-a-disposable-urp-project>'
```

Pass `-GameplayScene 'Assets/Scenes/Arena.unity'` to also capture the three effects in that scene using its active `MainCamera`. The camera must face the ground plane at Y = 0. Studio frames, gameplay PNGs and their playback timings are saved under `.vfx-work/effect-brief-tests-*/`.

Studio `capture.json` records the URP Asset, color space, HDR and camera post-processing state, Volume mask and preview Bloom settings. `Compare` reports differences in those settings alongside the existing pixel metrics when both captures include them.

Run the batch checks from an installed copy in a disposable URP project. Add `-Benchmark` to compare twelve sequential and batched builds, or `-Interruption` to test timeout recovery and selective retry.

```powershell
pwsh -File tests/Test-VfxBatch.ps1 -UnityProject '<path-to-a-disposable-urp-project>'
```

To compare visual quality, give fresh authoring sessions the same three prompts and matched capture settings. Allow one round of revisions in each session using its own draft captures. Compare the final contact sheets anonymously after both sets of prefabs have been exported. [Batch quality prompts](evals/batch-quality.json)

The [visual quality cases](evals/visual-quality/cases.json) include an amber arc with a fading cinder layer and a wide wave with a breaking front. Build the two flipbook recipes in a disposable Unity 6000.6.8f1 URP project. The original PNGs sit beside their recipes. For gameplay review, place a reference object 0.8 world units wide in the effect's camera and inspect the sample times in the manifest.

```powershell
$project = '<path-to-a-disposable-urp-project>'
$fixtures = './evals/visual-quality'
foreach ($shape in 'arc', 'wave') {
    & ./vfx-creator/scripts/vfx.ps1 Build -Project $project -ResourceRoot $fixtures `
        -Recipe "$fixtures/$shape-flipbook.recipe.json" -EffectBrief "$fixtures/$shape-flipbook.brief.json"
}
```

### Shape and timing pilot

The [shape and timing guide](vfx-creator/references/shape-and-timing.md) includes an editable contact arc, moving front, and projectile wake. Each has an original shape asset. Configure a disposable Unity 6000.6.8f1 URP project with the installed skill. Build the grayscale block-ins, measured corrections, and final examples together. Use a fresh Unity project when repeating these IDs.

```powershell
$pilot = '.vfx-work/art-direction-pilot'
./evals/Invoke-ArtDirectionPilot.ps1 -UnityProject $project -Output $pilot
./evals/Invoke-ArtDirection.ps1 -Stage Capture -UnityProject $project -ResultsRoot $pilot `
    -PilotBatch "$pilot/build/batch.json"
```

Inspect `build/index.html` for the comparison and see the [measured pilot results](evals/art-direction-pilot-results.json). In `gameplay/`, Play Mode captures record the effect beside a scale actor on dark and light ground and during overlap. Two additional passes vary only the seed from the first pass. Each `playback.json` records pool-style reset, playback, scheduled stop and final clearance.

For the original-effects benchmark, freeze the whole starting skill and use a separate disposable project. [The case manifest](evals/art-direction-cases.json) registers six holdout briefs from different families than the pilot. Each arm gets the same brief and measured draft feedback, with one revision. Codex CLI authors the recipes in fresh sessions. FFmpeg encodes the anonymous pairs.

```powershell
$results = '.vfx-work/art-direction-benchmark'
./evals/Invoke-ArtDirection.ps1 -Stage Author -ResultsRoot $results -UnityProject $comparisonProject `
    -BaselineSkill '<frozen-vfx-creator-folder>'
./evals/Invoke-ArtDirection.ps1 -Stage Review -ResultsRoot $results
./evals/Invoke-ArtDirection.ps1 -Stage Capture -ResultsRoot $results -UnityProject $comparisonProject
./evals/Invoke-ArtDirection.ps1 -Stage Review -ResultsRoot $results
./evals/Invoke-ArtDirection.ps1 -Stage Summarize -ResultsRoot $results
```

Give reviewers only the per-case folders under `blind-review/`. They contain the brief, anonymous motion, contact sheets and playback evidence. Keep the authoring runs private until verdicts are recorded. The summary requires six verdicts, at least four preferences for the updated skill, zero critical failures for it, and successful startup, clearance and reuse in Play Mode. See the [first complete comparison](evals/art-direction-benchmark-results.json). Use the verdict and frame evidence to decide whether a recipe needs a better authored shape, an animated mesh for another view, or a different trail. Test Graph-specific features on the target URP configuration when a case requires them.

### Reconstruction and accuracy

[`evals/cases.json`](evals/cases.json) defines five reconstruction examples and one catalog-expansion example. `evals/Invoke-Reconstruction.ps1` supports `Reference`, `Candidate`, `Review` and `Variant` stages. It writes local captures and HTML reports under `.vfx-work/` by default. Reference packages are not included; provide source packages that you are allowed to use.

An optional accuracy evaluation is defined in [`evals/accuracy-cases.json`](evals/accuracy-cases.json). `evals/Invoke-Accuracy.ps1` captures the teleport and aura references, renders candidates and compares them. Candidate runs use four clean URP projects named `old-teleport`, `new-teleport`, `old-aura` and `new-aura` under the results directory. After the reference and render/compare stages, run:

```powershell
pwsh -File evals/Measure-Accuracy.ps1 -ResultsRoot '.vfx-work/accuracy'
```

The reports include frame comparisons and measures for teleport pulse timing and aura visibility and area. These evaluations need the referenced third-party packages and a working Unity installation; neither is distributed here.

### Corpus learning and blind benchmark

The corpus inventory records prefab, graph and scene paths, archive fingerprints, renderer evidence, groups of variants and candidate status. It scans nested packages and reuses the index for unchanged archives. Run it with the local package directory, then verify that the learning manifest covers the eligible families and keeps the control groups separate.

```powershell
pwsh -File evals/Invoke-CorpusInventory.ps1 -SourceRoot '<path-to-your-effect-packs>'
pwsh -File evals/Test-CorpusSplit.ps1 -Inventory '.vfx-work/corpus/inventory.json'
```

[`evals/corpus-learning.json`](evals/corpus-learning.json) selects one representative per family. [`evals/corpus-holdouts.json`](evals/corpus-holdouts.json) selects six control effects, one per source pack. Capture either set with `Invoke-CorpusCapture.ps1` and a disposable URP reference stand created by `vfx.ps1 Init -ReferenceStand`. Pass a separate `-ResultsRoot` when capturing the learning set. A capture can use a wider frame on the second attempt to fit the complete effect. For a graph that needs an explicit startup or hit, record its schedule in the manifest. If a stand has conflicting imported dependencies, capture the affected cases in a fresh stand.

```powershell
$results = '.vfx-work/corpus-iteration'
./evals/Invoke-CorpusCapture.ps1 -Project '<reference-stand>' `
    -SourceRoot '<path-to-your-effect-packs>' -ResultsRoot $results
./evals/Invoke-CorpusAuthors.ps1 -ResultsRoot $results -BaselineSkill '<frozen-vfx-creator-folder>'
./evals/Measure-CorpusBenchmark.ps1 -Stage Compare -ResultsRoot $results -Project '<comparison-project>'
```

Freeze the whole baseline skill before updating it. The author runner installs a disposable copy per run, builds a draft from the anonymous brief, shows the author their draft capture, then exports their final recipe and prefab. It uses Codex CLI and records token counts when returned. It can also run in `Prepare`, `Draft` and `Finalize` stages for fresh external author sessions. `Invoke-CorpusAuthors.ps1` resumes existing runs, so use a new results directory when changing recipes, briefs, model or capture settings.

After both candidates are exported, give the reviewer only the anonymous contact sheets and, when needed, the side-by-side sequences under `review/<case>/`. Contact sheets use `System.Drawing.Common` on Windows. Save the reviewer's preference as `review/<case>/verdict.json` with `preference` set to `A`, `B` or `tie` and optional `notes`. Run `Measure-CorpusBenchmark.ps1` again with `-Stage Summarize` to record the verdicts, paired metrics, capture problems and measured resources in `benchmark.json`. The benchmark passes with six comparable, reviewed pairs, at least four visual preferences for the updated skill, a median foreground IoU gain of at least 0.05 and a median color error increase of at most 0.02.

### Visual signatures

Generate a local coverage report for the 30 learning representatives after the reference captures are ready. It records first, largest and last visible frames, projected dimensions, and the screen-space centroid at each visible frame. It uses the existing capture timeline or, for older captures, reconstructs foreground data from PNGs on Windows. Pass `-CaptureSummary` if a case uses a capture outside the standard references directory, such as distortion on a checkerboard. For a legacy scene capture, supply a recording that ends on the clean static backdrop.
Pass `-TrialRoot '<learning-results>/reference-trials'` to include earlier invisible or clipped attempts.

```powershell
./evals/Measure-EffectSignatures.ps1 -Labels ./evals/corpus-signature-labels.json `
    -CaptureRoot '<learning-results>/references' -Output '.vfx-work/signatures/corpus.json'
```

For the search benchmark, prepare all six holdout captures in a fresh results directory and pass the same frozen skill folder as both branches. The structured branch receives queries from `evals/corpus-signature-queries.json`, which were written from the anonymous briefs. Both branches use the same feedback mode and supply their three highest-ranked recipes in order.

```powershell
./evals/Invoke-CorpusAuthors.ps1 -ResultsRoot $results -BaselineSkill $frozenSkill `
    -UpdatedSkill $frozenSkill -SignatureSearch
./evals/Measure-CorpusBenchmark.ps1 -Stage Compare -ResultsRoot $results `
    -Project '<comparison-project>' -SignatureSearch
```

Review the contact sheets in `blind-review/<case>/` after the paired candidates are exported. Save the verdict beside each sheet, then run `Measure-CorpusBenchmark.ps1 -SignatureSearch -Stage Summarize -ResultsRoot $results`. The report `signature-benchmark.json` uses the regular corpus pass threshold.

### Frame calibration pilot

[`evals/calibration-cases.json`](evals/calibration-cases.json) defines one rehearsal and three holdouts. Capture the cases with `Invoke-CorpusCapture.ps1 -Manifest ./evals/calibration-cases.json` and use a disposable reference stand per package. Check each capture for valid materials, visibility and framing before using the [measured briefs](evals/calibration-briefs.json). The brief manifest supplies `id`, `brief` and zero-based `draftSampleFrames` for each case. Include the reference's observed dimensions, trajectory or timing at those sample frames when adding cases.

```powershell
$manifest = './evals/calibration-cases.json'
$results = '.vfx-work/calibration-pilot'
./evals/Invoke-CorpusAuthors.ps1 -ResultsRoot $results -Manifest $manifest `
    -BriefManifest ./evals/calibration-briefs.json -BaselineSkill '<vfx-creator-at-6a6716e>' -MeasuredFeedback
./evals/Measure-CorpusBenchmark.ps1 -Stage Compare -ResultsRoot $results -Manifest $manifest `
    -Project '<comparison-project>' -Calibration
```

Start with `-CaseId 00` for a rehearsal. The measured arm receives the draft's measurements at the brief's sample frames and up to eight draft images. Review each pair from `blind-review/<case>/contact-sheet.png` and save `verdict.json` alongside it. Summarize with `-Calibration` to write `calibration.json`. A pilot pass requires three comparable and reviewed holdouts, with the updated skill both preferred visually and closer on the preset primary metric in at least two. Area errors are in pixels of foreground coverage. Trajectory error is centroid RMS distance in pixels, with the frame diagonal as the penalty for missing candidate foreground at a sampled time. The report tracks author, build and Unity queue times separately.

## Contribute recipes

Add recipe JSON files to `vfx-creator/catalog/`. Use descriptive IDs, titles, aliases and layer names, and keep recipes free of copied source assets. Store source packages, imported assets, reference frames, Unity caches and generated evaluation output in ignored working directories such as `.vfx-work/`.

## License

This repository is available under the [MIT License](LICENSE). Third-party Unity packages and assets used as evaluation references are not included and remain under their owners' licenses.
