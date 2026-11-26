# VFX Creator

The installable deliverable is the entire `vfx-creator` folder. Keep project-specific commands, evaluation fixtures and paths outside it. Test a copy from another game project before changing installation instructions.

Use Unity 6000.6.8f1 and URP for reference captures. Track recipes, schemas, scripts and small evaluation manifests. Keep reference packages, their imported assets, frames and Unity caches in ignored working directories. Treat reference packages as read-only.

The roles in the skill handle analysis, authoring and review. For a blind reconstruction, give authoring a new session containing the brief, skill and catalog. Give the reference frames to review after the candidate prefab has been exported.

Run `pwsh -File tests/Test-VfxCreator.ps1` for the local workflow smoke test. See the README for the Unity integration and the five-pack evaluation.

The repository owner authorizes agents to create local Git commits automatically after completing and verifying a task. Stage only the changes that belong to that task and use a descriptive commit message. After each completed and verified skill improvement iteration, confirm the outgoing commits belong to that iteration, then publish them with a normal push to `origin/master` without asking again. Verify the remote commit after the push. Other pushes and history rewrites require a separate request.
