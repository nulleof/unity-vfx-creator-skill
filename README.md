# VFX Creator

Переносимый скилл Codex для создания редактируемых Unity URP-префабов из текстового брифа и пополняемого каталога рецептов.

## Установка

Скопируй папку `vfx-creator` целиком в `.agents/skills/` проекта Unity. В новой сессии Codex попроси, например, «$vfx-creator сделай короткую ледяную вспышку с длинным следом и искрами при попадании». Понадобятся PowerShell 7.4+ и установленный Unity Editor той версии, которая указана в `ProjectSettings/ProjectVersion.txt`. Для команд сборки и захвата целевой проект должен быть закрыт в редакторе. Если Unity установлена вне обычных путей Hub, передай путь к исполняемому файлу через `-Editor`.

Результат лежит в `Assets/VfxCreatorGenerated/<id>/Effect.prefab` вместе с его материалами, текстурами и шейдером. В сцене префаб можно редактировать обычными средствами Unity. В составных эффектах фазы видны в иерархии. Для привязки к событиям игры можно отдельно использовать дочерние фазы. Preview-движение Trail Renderer задаётся через `-Travel` и `-Arc`, а в игре его перемещает объект, к которому он прикреплён.

## Разработка и пополнение

Из корня репозитория прогоняй инструменты через `pwsh`. Пути `.vfx-work` предназначены для локальных результатов и Unity-кэшей.

```powershell
$vfx = './vfx-creator/scripts/vfx.ps1'
& $vfx Init -Version 6000.6.8f1 -Project .vfx-work/reference -ReferenceStand
& $vfx Inventory -Source C:/WORK/Effects -ExpandNested
& $vfx Learn -Project .vfx-work/reference -Source 'C:/WORK/Effects/AAA Stylized Projectiles Vol1 v3.0.0.unitypackage' `
    -Prefab 'Flash 7' -Id 'warm-flash' -Title 'Lilac layered flash' `
    -Brief 'A compact lilac flash with pink sparks' -Recipe .vfx-work/warm-flash.json -Output .vfx-work/flash-reference
& $vfx Find -Brief 'вспышка с искрами'
& $vfx Build -Project 'C:/Games/MyGame' -Recipe .vfx-work/warm-flash.json `
    -Id 'warm-flash-v1' -RenderAfterBuild -Output .vfx-work/flash-candidate
& $vfx Compare -Project .vfx-work/reference -Reference .vfx-work/flash-reference `
    -Candidate .vfx-work/flash-candidate -Output .vfx-work/flash-report
```

Проверь и доработай новый рецепт по видео и кадрам. Затем добавь JSON в каталог, чтобы он находился по коротким описаниям в новых сессиях. Для VFX Graph автоматически извлекаются параметры и грубая структура. Роль разбора уточняет композицию по рендеру. Если пакет завязан на скрипт демонстрационной сцены или материал другого рендер-пайплайна, настрой движение и совместимый материал в эталонном проекте перед сравнением.

## Проверка

`pwsh -File tests/Test-VfxCreator.ps1` проверяет переносимые файлы и поиск по брифу. С `-SourceRoot` тест также проверяет инвентаризацию паков. Параметр `-UnityProject` дополнительно собирает и рендерит эффект в указанном чистом URP-проекте. [Сценарии восстановления](evals/cases.json) задают пять стартовых примеров, шестой пример пополнения и параметры захвата.

`evals/Invoke-Reconstruction.ps1` запускает этапы `Reference`, `Candidate`, `Review` и `Variant`. Передай `-ReferenceProject` и `-SourceRoot` для эталонов, `-CleanProject` для сборки. Сценарий сборки стартует в новом локальном процессе с текстом и каталогом. Необязательный параметр `-FreshCodex` отправляет бриф и краткие описания рецептов в отдельную модельную сессию Codex CLI для выбора рецепта. Отчёты доступны в `<ResultsRoot>/reports/index.html`.

Первичная визуальная приёмка использует интерактивный локальный HTML-отчёт. Для более поздних прогонов можно передать утверждённый файл допусков через `Compare -Limits`. Машиночитаемый результат доступен в `comparison.json`.
