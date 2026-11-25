# VFX Creator

VFX Creator is a portable Codex skill for building editable, layered visual effects in Unity URP from a text brief and a catalog of reusable recipes. It can also inspect local effect packages, learn recipes from prefabs, and render captures for review.

The installable skill is the complete [`vfx-creator/`](vfx-creator/) directory. The repository also contains development checks and evaluation scripts.

## Features

- Create particle and trail effects as editable Unity prefabs.
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
