using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.VFX;
using Object = UnityEngine.Object;

namespace VfxCreator.Editor
{
    [Serializable]
    internal sealed class CaptureSettings
    {
        public int size;
        public int fps;
        public float duration;
        public float framing;
        public float cameraPitch;
        public float travel;
        public float arc;
        public int seed;
    }

    [Serializable]
    internal sealed class GraphEvent
    {
        public int frame;
        public string name;
    }

    [Serializable]
    internal sealed class CaptureManifest
    {
        public CaptureSettings settings;
        public Color32 background;
        public int frames;
        public int visibleFrames;
        public int clippedFrames;
        public int peakParticles;
        public int peakTrailPoints;
        public GraphEvent[] graphEvents;
        public string[] notes;
    }

    internal static class Render
    {
        internal static IEnumerator Capture(GameObject prefab, CaptureSettings settings, GraphEvent[] schedule, string output,
            Action<CaptureManifest> complete)
        {
            if (settings == null || settings.fps < 1 || settings.size < 32 || settings.duration <= 0)
                throw new ArgumentException("Invalid capture settings.");
            Directory.CreateDirectory(output);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(0.32f, 0.34f, 0.39f);
            var lamp = new GameObject("Preview light").AddComponent<Light>();
            lamp.type = LightType.Directional;
            lamp.intensity = 0.85f;
            lamp.transform.rotation = Quaternion.Euler(45, -25, 0);
            var camera = new GameObject("VFX capture camera").AddComponent<Camera>();
            var cameraRotation = Quaternion.Euler(settings.cameraPitch, 0, 0);
            camera.transform.SetPositionAndRotation(cameraRotation * new Vector3(0, 0, -12), cameraRotation);
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.037f, 0.043f, 0.060f);
            camera.orthographic = true;
            camera.orthographicSize = settings.framing * 0.5f;
            camera.aspect = 1;
            camera.nearClipPlane = 0.1f;
            camera.farClipPlane = 60;
            camera.allowHDR = true;
            var cameraData = camera.GetUniversalAdditionalCameraData();
            cameraData.renderPostProcessing = true;
            cameraData.requiresDepthTexture = true;
            var volume = new GameObject("Preview bloom").AddComponent<Volume>();
            volume.isGlobal = true;
            var profile = ScriptableObject.CreateInstance<VolumeProfile>();
            var bloom = profile.Add<Bloom>();
            bloom.threshold.Override(0.82f);
            bloom.intensity.Override(0.26f);
            volume.sharedProfile = profile;

            var target = new RenderTexture(settings.size, settings.size, 24, RenderTextureFormat.ARGB32);
            target.Create();
            camera.targetTexture = target;
            var image = new Texture2D(settings.size, settings.size, TextureFormat.RGB24, false);
            var manifest = new CaptureManifest
            {
                settings = settings, frames = Mathf.CeilToInt(settings.duration * settings.fps) + 1,
                graphEvents = schedule ?? Array.Empty<GraphEvent>()
            };
            try
            {
                ReadFrame(camera, target, image);
                manifest.background = image.GetPixels32()[0];
                var root = (GameObject)PrefabUtility.InstantiatePrefab(prefab);
                root.transform.position = Position(settings, 0);
                var systems = root.GetComponentsInChildren<ParticleSystem>();
                var graphs = root.GetComponentsInChildren<VisualEffect>().Where(effect => effect.enabled && effect.visualEffectAsset != null).ToArray();
                var eventsByFrame = PlanEvents(graphs, manifest.graphEvents, manifest.frames);
                var trails = root.GetComponentsInChildren<TrailRenderer>().Where(trail => trail.enabled).ToArray();
                var trailSamples = Array.ConvertAll(trails, trail => new Queue<Vector3>());
                var notes = new List<string>();
                foreach (var behavior in root.GetComponentsInChildren<MonoBehaviour>())
                    if (behavior != null) behavior.enabled = false;
                for (int i = 0; i < systems.Length; i++)
                {
                    systems[i].Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear);
                    systems[i].useAutoRandomSeed = false;
                    systems[i].randomSeed = unchecked((uint)(settings.seed + i * 104729));
                    var main = systems[i].main;
                    main.cullingMode = ParticleSystemCullingMode.AlwaysSimulate;
                }
                var emitters = systems.Where(system =>
                {
                    var parent = system.transform.parent;
                    return system.main.playOnAwake && (parent == null || parent.GetComponentInParent<ParticleSystem>() == null ||
                        !parent.GetComponentInParent<ParticleSystem>().main.playOnAwake);
                }).ToArray();
                foreach (var graph in graphs)
                {
                    graph.resetSeedOnPlay = false;
                    graph.startSeed = (uint)settings.seed;
                    if (manifest.graphEvents.Length > 0)
                    {
                        var names = new List<string>();
                        graph.visualEffectAsset.GetEvents(names);
                        string unusedEvent = "VfxCreatorPreview";
                        while (names.Contains(unusedEvent)) unusedEvent += "_";
                        graph.initialEventName = unusedEvent;
                    }
                    graph.Reinit();
                    graph.pause = true;
                }
                foreach (var trail in trails)
                {
                    trail.Clear();
                    trail.emitting = false;
                }
                foreach (var renderer in root.GetComponentsInChildren<Renderer>())
                foreach (var material in renderer.sharedMaterials)
                    if (material != null && (material.shader == null || !material.shader.isSupported || ShaderUtil.ShaderHasError(material.shader)))
                        notes.Add("Unsupported preview material on " + renderer.name);

                float delta = 1f / settings.fps;
                if (graphs.Length > 0)
                {
                    ReadFrame(camera, target, image);
                    yield return null;
                }
                int highestAlive = 0;
                var sample = new ParticleSystem.Particle[1];
                string firstParticle = null;
                for (int frame = 0; frame < manifest.frames; frame++)
                {
                    float progress = Mathf.Min(1, frame * delta / settings.duration);
                    root.transform.position = Position(settings, progress);
                    foreach (var particle in emitters) particle.Simulate(delta, true, frame == 0, false);
                    manifest.peakParticles = Math.Max(manifest.peakParticles, systems.Sum(system => system.particleCount));
                    if (firstParticle == null && manifest.peakParticles > 0)
                    {
                        var owner = systems.First(system => system.particleCount > 0);
                        if (owner.GetParticles(sample, 1) > 0)
                        {
                            Vector3 world = owner.main.simulationSpace == ParticleSystemSimulationSpace.World ?
                                sample[0].position : owner.transform.TransformPoint(sample[0].position);
                            firstParticle = $"First live particle at {camera.WorldToViewportPoint(world):F2}, size {sample[0].GetCurrentSize(owner):F3}, tint {sample[0].GetCurrentColor(owner)}.";
                        }
                    }
                    if (eventsByFrame.TryGetValue(frame, out var scheduled))
                        foreach (var item in scheduled) item.graph.SendEvent(item.name);
                    foreach (var graph in graphs) graph.Simulate(delta, 1);
                    for (int i = 0; i < trails.Length; i++)
                    {
                        if (progress <= 0.75f) trailSamples[i].Enqueue(trails[i].transform.position);
                        if (trailSamples[i].Count > Mathf.CeilToInt(trails[i].time * settings.fps) ||
                            (progress > 0.75f && trailSamples[i].Count > 0))
                            trailSamples[i].Dequeue();
                        trails[i].Clear();
                        if (trailSamples[i].Count > 0) trails[i].AddPositions(trailSamples[i].ToArray());
                        manifest.peakTrailPoints = Math.Max(manifest.peakTrailPoints, trails[i].positionCount);
                    }
                    yield return null;
                    ReadFrame(camera, target, image);
                    foreach (var graph in graphs) highestAlive = Math.Max(highestAlive, graph.aliveParticleCount);
                    var pixels = image.GetPixels32();
                    if (pixels.Any(pixel => IsForeground(pixel, manifest.background))) manifest.visibleFrames++;
                    if (TouchesEdge(pixels, settings.size, manifest.background)) manifest.clippedFrames++;
                    File.WriteAllBytes(Path.Combine(output, FrameName(frame)), image.EncodeToPNG());
                }
                if (graphs.Length > 0 && manifest.visibleFrames == 0)
                    notes.Add($"VFX Graph produced no visible pixels in batch capture (peak live particles reported: {highestAlive}).");
                if (manifest.visibleFrames == 0 && firstParticle != null) notes.Add(firstParticle);
                manifest.notes = notes.Distinct().ToArray();
                Pipeline.WriteJson(Path.Combine(output, "capture.json"), manifest);
                complete(manifest);
            }
            finally
            {
                Object.DestroyImmediate(image);
                camera.targetTexture = null;
                target.Release();
                Object.DestroyImmediate(target);
                Object.DestroyImmediate(profile);
            }
        }

        private static Dictionary<int, List<(VisualEffect graph, string name)>> PlanEvents(VisualEffect[] graphs,
            GraphEvent[] schedule, int frames)
        {
            var result = new Dictionary<int, List<(VisualEffect, string)>>();
            if (schedule.Length == 0) return result;
            var targets = new Dictionary<string, List<VisualEffect>>(StringComparer.Ordinal);
            foreach (var graph in graphs)
            {
                var names = new List<string>();
                graph.visualEffectAsset.GetEvents(names);
                foreach (string name in names.Distinct())
                {
                    if (!targets.TryGetValue(name, out var entries))
                        targets.Add(name, entries = new List<VisualEffect>());
                    entries.Add(graph);
                }
            }
            foreach (var item in schedule)
            {
                if (item == null || item.frame < 0 || item.frame >= frames || string.IsNullOrWhiteSpace(item.name))
                    throw new ArgumentException($"Graph events require a name and a frame from 0 to {frames - 1}.");
                if (!targets.TryGetValue(item.name, out var effects))
                    throw new ArgumentException($"Unknown graph event '{item.name}'. Available events: {string.Join(", ", targets.Keys)}");
                if (!result.TryGetValue(item.frame, out var events))
                    result.Add(item.frame, events = new List<(VisualEffect, string)>());
                foreach (var graph in effects) events.Add((graph, item.name));
            }
            return result;
        }

        private static bool TouchesEdge(Color32[] pixels, int size, Color32 background)
        {
            int lastRow = (size - 1) * size;
            for (int i = 0; i < size; i++)
                if (IsForeground(pixels[i], background) || IsForeground(pixels[lastRow + i], background) ||
                    IsForeground(pixels[i * size], background) || IsForeground(pixels[i * size + size - 1], background))
                    return true;
            return false;
        }

        private static Vector3 Position(CaptureSettings settings, float progress)
        {
            float travel = Mathf.Clamp01(progress / 0.75f);
            return new Vector3((travel - 0.5f) * settings.travel, Mathf.Sin(travel * Mathf.PI) * settings.arc, 0);
        }

        private static void ReadFrame(Camera camera, RenderTexture target, Texture2D image)
        {
            var request = new RenderPipeline.StandardRequest { destination = target };
            if (!RenderPipeline.SupportsRenderRequest(camera, request))
                throw new InvalidOperationException("The active URP renderer does not support camera render requests.");
            RenderPipeline.SubmitRenderRequest(camera, request);
            var previous = RenderTexture.active;
            try
            {
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0, false);
                image.Apply();
            }
            finally { RenderTexture.active = previous; }
        }

        internal static string FrameName(int frame) => $"frame-{frame:D4}.png";
        internal static bool IsForeground(Color32 pixel, Color32 background) => Difference(pixel, background) > 15;
        internal static int Difference(Color32 first, Color32 second) =>
            Math.Max(Math.Abs(first.r - second.r), Math.Max(Math.Abs(first.g - second.g), Math.Abs(first.b - second.b)));
    }
}
