using System;
using System.Collections;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace VfxCreator.Editor
{
    [Serializable]
    internal sealed class Request
    {
        public string action;
        public string response;
        public string output;
        public string prefab;
        public string id;
        public string title;
        public string brief;
        public string recipe;
        public string sourceRecipe;
        public string shader;
        public string resourceRoot;
        public string reference;
        public string candidate;
        public string limits;
        public bool metadataOnly;
        public bool renderAfterBuild;
        public CaptureSettings capture;
    }

    [Serializable]
    internal sealed class Receipt
    {
        public bool ok;
        public string error;
        public string version;
        public string prefab;
        public string recipe;
        public string capture;
        public string report;
        public string[] dependencies;
        public string[] notes;
        public bool visible;
        public bool hasLimits;
        public bool passedLimits;
    }

    internal static class Pipeline
    {
        public static void Execute()
        {
            string[] args = Environment.GetCommandLineArgs();
            int requestArgument = Array.IndexOf(args, "-vfxRequest");
            if (requestArgument < 0 || requestArgument + 1 >= args.Length) throw new ArgumentException("Pass -vfxRequest <json>.");
            var request = JsonUtility.FromJson<Request>(File.ReadAllText(args[requestArgument + 1]));
            var result = new Receipt { version = Application.unityVersion };
            IEnumerator capture = null;
            try
            {
                if (request.action != "compare" && !(GraphicsSettings.currentRenderPipeline?.GetType().FullName?.Contains(".Universal.") ?? false))
                    throw new InvalidOperationException("Configure the active Unity Quality settings with a Universal Render Pipeline asset.");
                switch (request.action)
                {
                    case "learn":
                        var source = LoadPrefab(request.prefab);
                        var recipe = Analyze.Prefab(source, request);
                        WriteJson(request.recipe, recipe);
                        result.prefab = request.prefab;
                        result.recipe = request.recipe;
                        result.notes = recipe.notes;
                        if (!request.metadataOnly) capture = Capture(request, result, source);
                        break;
                    case "build":
                        string prefab = Build.Prefab(JsonUtility.FromJson<Recipe>(File.ReadAllText(request.recipe)), request);
                        VerifyGenerated(prefab, result);
                        result.prefab = prefab;
                        result.recipe = request.sourceRecipe;
                        if (request.renderAfterBuild)
                        {
                            request.prefab = prefab;
                            capture = Capture(request, result, LoadPrefab(prefab));
                        }
                        break;
                    case "render":
                        var renderPrefab = LoadPrefab(request.prefab);
                        if (request.prefab.StartsWith("Assets/VfxCreatorGenerated/", StringComparison.Ordinal))
                            VerifyGenerated(request.prefab, result);
                        capture = Capture(request, result, renderPrefab);
                        break;
                    case "compare":
                        var comparison = Compare.Captures(request);
                        result.report = Path.Combine(request.output, "index.html");
                        result.hasLimits = comparison.hasLimits;
                        result.passedLimits = comparison.passedLimits;
                        break;
                    default:
                        throw new ArgumentException("Unknown command " + request.action);
                }
                if (capture != null)
                {
                    StartCapture(capture, request, result);
                    return;
                }
                result.ok = true;
            }
            catch (Exception exception)
            {
                result.error = exception.Message;
                Debug.LogException(exception);
            }
            Finish(request, result);
        }

        private static void StartCapture(IEnumerator capture, Request request, Receipt result)
        {
            void Update()
            {
                try
                {
                    if (capture.MoveNext())
                    {
                        EditorApplication.QueuePlayerLoopUpdate();
                        return;
                    }
                    result.ok = true;
                }
                catch (Exception exception)
                {
                    result.error = exception.Message;
                    Debug.LogException(exception);
                }
                EditorApplication.update -= Update;
                Finish(request, result);
            }
            EditorApplication.update += Update;
            EditorApplication.QueuePlayerLoopUpdate();
        }

        private static void Finish(Request request, Receipt result)
        {
            WriteJson(request.response, result);
            EditorApplication.Exit(result.ok ? 0 : 1);
        }

        private static GameObject LoadPrefab(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !path.StartsWith("Assets/", StringComparison.Ordinal) || !path.EndsWith(".prefab", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Pass a project-relative Assets/.../*.prefab path.");
            return AssetDatabase.LoadAssetAtPath<GameObject>(path) ??
                throw new FileNotFoundException("Unity could not load " + path);
        }

        private static IEnumerator Capture(Request request, Receipt result, GameObject source)
        {
            return Render.Capture(source, request.capture, request.output, capture =>
            {
                result.prefab = request.prefab;
                result.capture = request.output;
                result.visible = capture.visibleFrames > 0;
                result.notes = (result.notes ?? Array.Empty<string>()).Concat(capture.notes).ToArray();
                if (!result.visible) throw new InvalidOperationException("The capture contains no visible frames. Inspect " + request.output);
            });
        }

        private static void VerifyGenerated(string prefab, Receipt result)
        {
            var root = LoadPrefab(prefab);
            var paths = AssetDatabase.GetDependencies(prefab, true);
            string directory = Path.GetDirectoryName(prefab).Replace('\\', '/') + "/";
            var external = paths.Where(path => path.StartsWith("Assets/", StringComparison.Ordinal) && !path.StartsWith(directory, StringComparison.Ordinal)).ToArray();
            if (external.Length != 0) throw new InvalidOperationException("The prefab refers to external project assets: " + string.Join(", ", external));
            if (root.GetComponentsInChildren<MonoBehaviour>(true).Any(component => component == null))
                throw new InvalidOperationException("The prefab has a missing script.");
            foreach (var renderer in root.GetComponentsInChildren<Renderer>(true))
            foreach (var material in renderer.sharedMaterials)
            {
                if (material == null || material.shader == null || !material.shader.isSupported || ShaderUtil.ShaderHasError(material.shader))
                    throw new InvalidOperationException("The prefab has an invalid material on " + renderer.name);
            }
            result.dependencies = paths;
        }

        internal static void WriteJson(string path, object data)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            string partial = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(partial, JsonUtility.ToJson(data, true));
                if (!File.Exists(path)) File.Move(partial, path);
                else
                {
                    try { File.Replace(partial, path, null); }
                    catch (IOException) { File.Copy(partial, path, true); }
                }
            }
            finally
            {
                if (File.Exists(partial)) File.Delete(partial);
            }
        }
    }
}
