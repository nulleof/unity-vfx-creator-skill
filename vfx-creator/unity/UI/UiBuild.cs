using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;
using UnityEngine.UI;
using Object = UnityEngine.Object;

namespace VfxCreator.Editor
{
    internal static class UiBuild
    {
        private const string Idle = "Idle";
        private const string Standard = "Standard";
        private const string Reduced = "Reduced";
        private const string BaseLayer = "Base Layer.";

        [Serializable]
        private sealed class UiRequest
        {
            public Brief uiBrief;
            public UiRecipe uiRecipe;
        }

        [Serializable]
        private sealed class Brief
        {
            public int version;
            public string id;
            public string description;
            public string trigger;
            public string target;
            public Vector2 anchor;
            public Vector2 footprint;
            public string order;
            public string clipping;
            public string retrigger;
            public string reducedMotion;
        }

        [Serializable]
        private sealed class UiRecipe
        {
            public Layer[] layers;
        }

        [Serializable]
        private sealed class Layer
        {
            public string name;
            public string shape;
            public string color;
            public Vector2 size;
            public Pose[] standard;
            public ReducedTrack reduced;
        }

        [Serializable]
        private sealed class Pose
        {
            public float time;
            public Vector2 position;
            public float scale;
            public float opacity;

            internal Pose At(float time, float opacity)
            {
                return new Pose { time = time, position = position, scale = scale, opacity = opacity };
            }
        }

        [Serializable]
        private sealed class ReducedTrack
        {
            public Vector2 position;
            public float scale;
            public FadeKey[] keys;
        }

        [Serializable]
        private sealed class FadeKey
        {
            public float time;
            public float opacity;
        }

        [Serializable]
        private sealed class Handoff
        {
            public int version = 1;
            public string id;
            public string prefab;
            public string canvas = "screenSpaceOverlay";
            public Brief placement;
            public string idleState = BaseLayer + Idle;
            public string standardState = BaseLayer + Standard;
            public string reducedState = BaseLayer + Reduced;
            public float standardDurationSec;
            public float reducedDurationSec;
        }

        public static void Execute() => Pipeline.Execute(BuildEffect);

        private static void BuildEffect(string json, Request request, Receipt result)
        {
            var data = JsonUtility.FromJson<UiRequest>(json);
            var brief = data.uiBrief;
            var layers = data.uiRecipe.layers;
            using var staged = Build.StagePrefab(brief.id, request.stagingToken);
            var root = new GameObject(brief.id, typeof(RectTransform), typeof(Animator));
            try
            {
                SetRect((RectTransform)root.transform, Vector2.one * 0.5f, Vector2.one);
                if (brief.clipping == "target") root.AddComponent<RectMask2D>();
                var footprint = AddRect(root.transform, "Visuals");
                SetRect(footprint, brief.anchor, brief.footprint);

                var idle = new AnimationClip { name = Idle, frameRate = 60 };
                var standard = new AnimationClip { name = Standard, frameRate = 60 };
                var reduced = new AnimationClip { name = Reduced, frameRate = 60 };
                var sprites = new Dictionary<string, Sprite>(StringComparer.Ordinal);
                foreach (var layer in layers)
                {
                    if (!sprites.TryGetValue(layer.shape, out var sprite))
                    {
                        sprite = CreateSprite(staged.WorkPath, layer.shape);
                        sprites.Add(layer.shape, sprite);
                    }
                    var rect = AddRect(footprint, layer.name);
                    var graphic = rect.gameObject.AddComponent<Image>();
                    if (!ColorUtility.TryParseHtmlString(layer.color, out var color))
                        throw new ArgumentException($"Invalid color on '{layer.name}'.");
                    graphic.color = color;
                    graphic.sprite = sprite;
                    graphic.raycastTarget = false;
                    var group = rect.gameObject.AddComponent<CanvasGroup>();
                    group.alpha = 0;
                    group.blocksRaycasts = false;
                    group.interactable = false;

                    var rest = layer.standard[0].At(0, 0);
                    SetRect(rect, rest.position, layer.size);
                    rect.localScale = new Vector3(rest.scale, rest.scale, 1);
                    string path = AnimationUtility.CalculateTransformPath(rect, root.transform);
                    Animate(idle, path, layer.size, new[] { rest, rest.At(1f / 60, 0) });
                    Animate(standard, path, layer.size, layer.standard);
                    var fade = layer.reduced;
                    var reducedPoses = fade?.keys is not { Length: > 0 }
                        ? new[] { rest, rest.At(1f / 60, 0) }
                        : fade.keys.Select(key => new Pose
                        {
                            time = key.time, position = fade.position, scale = fade.scale, opacity = key.opacity
                        }).ToArray();
                    Animate(reduced, path, layer.size, reducedPoses);
                }

                foreach (var clip in new[] { idle, standard, reduced })
                    AssetDatabase.CreateAsset(clip, $"{staged.WorkPath}/{clip.name}.anim");
                var animator = root.GetComponent<Animator>();
                animator.runtimeAnimatorController = CreateController(staged.WorkPath, idle, standard, reduced);
                animator.updateMode = AnimatorUpdateMode.UnscaledTime;
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;

                var prefab = PrefabUtility.SaveAsPrefabAsset(root, staged.Path, out bool saved);
                if (!saved || prefab == null) throw new IOException("Unity could not save the UI prefab.");
                AssetDatabase.SaveAssets();
                Pipeline.VerifyGenerated(staged.Path, result);
                VerifyPrefab(prefab, layers.Length);

                var handoff = new Handoff
                {
                    id = brief.id, prefab = staged.PublishedPath, placement = brief,
                    standardDurationSec = standard.length, reducedDurationSec = reduced.length
                };
                string manifest = Path.Combine(request.output, "ui-effect.json");
                staged.Publish(() => Pipeline.WriteJson(manifest, handoff));
                result.prefab = staged.PublishedPath;
                result.recipe = request.sourceRecipe;
                result.effect = manifest;
                result.dependencies = AssetDatabase.GetDependencies(result.prefab, true);
            }
            finally
            {
                Object.DestroyImmediate(root);
            }
        }

        private static RectTransform AddRect(Transform parent, string name)
        {
            var child = (RectTransform)new GameObject(name, typeof(RectTransform)).transform;
            child.SetParent(parent, false);
            return child;
        }

        private static void SetRect(RectTransform rect, Vector2 center, Vector2 size)
        {
            rect.anchorMin = center - size * 0.5f;
            rect.anchorMax = center + size * 0.5f;
            rect.pivot = Vector2.one * 0.5f;
            rect.offsetMin = Vector2.zero;
            rect.offsetMax = Vector2.zero;
        }

        private static Sprite CreateSprite(string folder, string shape)
        {
            string path = $"{folder}/{shape}.png";
            var recipe = new TextureRecipe { kind = shape, spokes = 4, detail = 0 };
            File.WriteAllBytes(path, Masks.Generate(recipe, 1729));
            AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport);
            var importer = (TextureImporter)AssetImporter.GetAtPath(path);
            importer.textureType = TextureImporterType.Sprite;
            importer.spriteImportMode = SpriteImportMode.Single;
            importer.alphaIsTransparency = true;
            importer.mipmapEnabled = false;
            importer.wrapMode = TextureWrapMode.Clamp;
            importer.textureCompression = TextureImporterCompression.Uncompressed;
            var settings = new TextureImporterSettings();
            importer.ReadTextureSettings(settings);
            settings.spriteMeshType = SpriteMeshType.FullRect;
            importer.SetTextureSettings(settings);
            importer.SaveAndReimport();
            return AssetDatabase.LoadAssetAtPath<Sprite>(path) ??
                throw new IOException($"Could not import the generated sprite '{path}'.");
        }

        private static void Animate(AnimationClip clip, string path, Vector2 size, Pose[] poses)
        {
            Vector2 half = size * 0.5f;
            Bind(clip, path, typeof(RectTransform), "m_AnchorMin.x", poses, pose => pose.position.x - half.x);
            Bind(clip, path, typeof(RectTransform), "m_AnchorMin.y", poses, pose => pose.position.y - half.y);
            Bind(clip, path, typeof(RectTransform), "m_AnchorMax.x", poses, pose => pose.position.x + half.x);
            Bind(clip, path, typeof(RectTransform), "m_AnchorMax.y", poses, pose => pose.position.y + half.y);
            Bind(clip, path, typeof(RectTransform), "m_LocalScale.x", poses, pose => pose.scale);
            Bind(clip, path, typeof(RectTransform), "m_LocalScale.y", poses, pose => pose.scale);
            Bind(clip, path, typeof(CanvasGroup), "m_Alpha", poses, pose => pose.opacity);
        }

        private static void Bind(AnimationClip clip, string path, Type component, string property, Pose[] poses, Func<Pose, float> value)
        {
            var curve = new AnimationCurve(poses.Select(pose => new Keyframe(pose.time, value(pose))).ToArray());
            for (int index = 0; index < curve.length; index++)
            {
                AnimationUtility.SetKeyLeftTangentMode(curve, index, AnimationUtility.TangentMode.Linear);
                AnimationUtility.SetKeyRightTangentMode(curve, index, AnimationUtility.TangentMode.Linear);
            }
            AnimationUtility.SetEditorCurve(clip, EditorCurveBinding.FloatCurve(path, component, property), curve);
        }

        private static AnimatorController CreateController(string folder, AnimationClip idle, AnimationClip standard, AnimationClip reduced)
        {
            var controller = AnimatorController.CreateAnimatorControllerAtPath($"{folder}/Effect.controller");
            var machine = controller.layers[0].stateMachine;
            var idleState = machine.AddState(Idle);
            idleState.motion = idle;
            idleState.writeDefaultValues = false;
            machine.defaultState = idleState;
            foreach (var clip in new[] { standard, reduced })
            {
                var state = machine.AddState(clip.name);
                state.motion = clip;
                state.writeDefaultValues = false;
                var transition = state.AddTransition(idleState);
                transition.hasExitTime = true;
                transition.exitTime = 1;
                transition.hasFixedDuration = true;
                transition.duration = 0;
                transition.offset = 0;
            }
            return controller;
        }

        private static void VerifyPrefab(GameObject prefab, int layerCount)
        {
            var images = prefab.GetComponentsInChildren<Image>();
            if (images.Length != layerCount || images.Any(image => !image.sprite || image.raycastTarget))
                throw new InvalidOperationException("The UI prefab has missing sprites or interactive effect graphics.");
            var animator = prefab.GetComponent<Animator>();
            var controller = animator.runtimeAnimatorController;
            if (!controller || controller.animationClips.Length != 3 ||
                controller.animationClips.Any(clip => clip.length <= 0 || clip.isLooping))
                throw new InvalidOperationException("The UI prefab needs three valid non-looping animation clips.");
        }
    }
}
