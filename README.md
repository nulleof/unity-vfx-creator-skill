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

## Contribute recipes

Add recipe JSON files to `vfx-creator/catalog/`. Use descriptive IDs, titles, aliases and layer names, and keep recipes free of copied source assets. Store source packages, imported assets, reference frames, Unity caches and generated evaluation output in ignored working directories such as `.vfx-work/`.

## License

This repository is available under the [MIT License](LICENSE). Third-party Unity packages and assets used as evaluation references are not included and remain under their owners' licenses.
