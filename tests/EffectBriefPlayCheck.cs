using System;
using System.Collections;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

[InitializeOnLoad]
public static class EffectBriefPlayCheck
{
    private const string ManifestKey = "VfxCreatorEffectBriefPlayCheck";
    private static IEnumerator checks;

    [Serializable]
    private sealed class Inputs
    {
        public string[] effects;
        public string motionPrefab;
    }

    [Serializable]
    private sealed class Effect
    {
        public string prefab;
        public string mode;
        public string[] startEmitters;
    }

    static EffectBriefPlayCheck()
    {
        EditorApplication.playModeStateChanged += state =>
        {
            if (state != PlayModeStateChange.EnteredPlayMode) return;
            string manifest = SessionState.GetString(ManifestKey, string.Empty);
            if (string.IsNullOrEmpty(manifest)) return;
            SessionState.EraseString(ManifestKey);
            Application.runInBackground = true;
            Time.captureFramerate = 60;
            checks = Verify(manifest);
            EditorApplication.update += Update;
        };
    }

    public static void Run()
    {
        string[] args = Environment.GetCommandLineArgs();
        int index = Array.IndexOf(args, "-vfxPlayCheck");
        SessionState.SetString(ManifestKey, args[index + 1]);
        EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
        EditorApplication.EnterPlaymode();
    }

    private static void Update()
    {
        try
        {
            if (checks.MoveNext()) return;
            Debug.Log("Effect brief Play Mode checks passed.");
            EditorApplication.Exit(0);
        }
        catch (Exception error)
        {
            Debug.LogException(error);
            EditorApplication.Exit(1);
        }
    }

    private static IEnumerator Verify(string manifest)
    {
        var inputs = JsonUtility.FromJson<Inputs>(File.ReadAllText(manifest));
        foreach (string path in inputs.effects)
        {
            var effect = JsonUtility.FromJson<Effect>(File.ReadAllText(path));
            var root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(effect.prefab));
            var systems = root.GetComponentsInChildren<ParticleSystem>();
            Require(systems.All(system => !system.useAutoRandomSeed), "A legacy recipe enabled automatic seeding.");
            var trails = root.GetComponentsInChildren<TrailRenderer>();
            var emitters = effect.startEmitters.Select(address =>
            {
                Transform node = root.transform;
                foreach (string index in address.Split('/')) node = node.GetChild(int.Parse(index));
                return node.GetComponent<ParticleSystem>();
            }).ToArray();

            foreach (object step in Wait(0.05f)) yield return step;
            Require(systems.All(system => !system.main.playOnAwake && !system.IsAlive(false)),
                effect.mode + " particles started automatically.");
            Require(trails.All(trail => !trail.emitting), effect.mode + " trails started automatically.");
            Start(emitters, systems, trails);
            switch (effect.mode)
            {
                case "oneShot":
                    var subEmitter = systems.Single(system => !emitters.Contains(system));
                    foreach (object step in Wait(0.07f)) yield return step;
                    Require(emitters.Any(system => system.particleCount > 0), "The contact flash did not start.");
                    Require(subEmitter.particleCount == 0, "A sub-emitter played before its trigger.");
                    foreach (object step in Wait(0.15f)) yield return step;
                    Require(subEmitter.particleCount > 0, "The death sub-emitter did not emit.");
                    foreach (object step in Wait(0.45f)) yield return step;
                    Require(emitters.All(system => !system.IsAlive(true)), "The contact flash did not finish.");
                    break;
                case "loop":
                    foreach (object step in Wait(0.9f)) yield return step;
                    Require(emitters.Any(system => system.particleCount > 0), "Aura did not sustain across a loop.");
                    Stop(systems, trails);
                    Require(systems.Any(system => system.particleCount > 0), "Aura particles were cleared immediately.");
                    foreach (object step in Wait(0.55f)) yield return step;
                    Require(systems.All(system => !system.IsAlive(false)), "Aura did not settle after stop.");
                    break;
                case "trail":
                    foreach (object step in Move(root.transform, 12)) yield return step;
                    Require(trails.All(trail => trail.positionCount > 2), "Moving the prefab did not produce a trail.");
                    Require(NativeTrailIsVisible(trails), "The native TrailRenderer produced no visible pixels in Play Mode.");
                    Stop(systems, trails);
                    foreach (object step in Wait(trails.Max(trail => trail.time) + 0.1f)) yield return step;
                    Require(!NativeTrailIsVisible(trails), "A stopped trail did not fade.");
                    root.transform.position = new Vector3(10, 0, 0);
                    Start(emitters, systems, trails);
                    Require(trails.All(trail => trail.positionCount == 0), "Restart kept old trail geometry.");
                    foreach (object step in Move(root.transform, 8)) yield return step;
                    foreach (var trail in trails)
                    {
                        var positions = new Vector3[trail.positionCount];
                        trail.GetPositions(positions);
                        Require(positions.Length > 2 && positions.All(position => position.x >= 9.9f),
                            "Restart produced no trail or connected to an old position.");
                    }
                    break;
                default:
                    throw new InvalidOperationException("Unexpected effect mode " + effect.mode);
            }
            Debug.Log("Verified playback: " + effect.prefab);
            Object.Destroy(root);
        }

        VerifyMotion(inputs.motionPrefab);
    }

    private static void VerifyMotion(string prefab)
    {
        var root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(prefab));
        foreach (var system in root.GetComponentsInChildren<ParticleSystem>())
        {
            var velocity = system.velocityOverLifetime;
            var mode = Enum.Parse<ParticleSystemCurveMode>(system.name);
            Require(velocity.enabled && velocity.x.mode == mode && velocity.y.mode == mode && velocity.z.mode == mode,
                "Velocity axes did not preserve " + mode);
            float expectedX = mode == ParticleSystemCurveMode.Curve || mode == ParticleSystemCurveMode.TwoCurves ? 0.2f : 0;
            foreach (float sample in new[] { 0f, 0.4f, 1f })
            {
                Require(Mathf.Approximately(velocity.x.Evaluate(sample, 0.35f), expectedX) &&
                    Mathf.Approximately(velocity.z.Evaluate(sample, 0.65f), 0),
                    "Normalizing Velocity axes changed an authored constant or an implicit zero.");
            }
        }

        var rock = root.GetComponentsInChildren<ParticleSystem>().Single(system => system.name == "TwoConstants");
        var spin = rock.rotationOverLifetime;
        Require(rock.useAutoRandomSeed && rock.main.startRotation3D && spin.enabled && spin.separateAxes,
            "The mesh did not retain its variation and three-dimensional rotation settings.");
        var particle = new ParticleSystem.Particle[1];
        uint firstSeed = 0;
        Vector3 firstOrientation = default;
        bool changedSeed = false, changedOrientation = false;
        for (int play = 0; play < 3; play++)
        {
            rock.Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear);
            rock.Play(false);
            rock.Simulate(0.03f, false, false, false);
            Require(rock.GetParticles(particle) == 1, "The restarted mesh did not emit.");
            Vector3 orientation = particle[0].rotation3D;
            if (play == 0)
            {
                firstSeed = rock.randomSeed;
                firstOrientation = orientation;
            }
            else
            {
                changedSeed |= rock.randomSeed != firstSeed;
                changedOrientation |= (orientation - firstOrientation).sqrMagnitude > 1;
            }

            rock.Simulate(0.1f, false, false, false);
            Require(rock.GetParticles(particle) == 1 &&
                Mathf.Abs(particle[0].rotation3D.x - orientation.x) > 1 &&
                Mathf.Abs(particle[0].rotation3D.y - orientation.y) > 1,
                "The mesh did not tumble on both configured axes.");
        }
        Require(changedSeed && changedOrientation, "Restarting the same mesh did not vary the seed and initial orientation.");
        Object.Destroy(root);
    }

    private static void Start(ParticleSystem[] emitters, ParticleSystem[] systems, TrailRenderer[] trails)
    {
        foreach (var system in systems) system.Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear);
        foreach (var trail in trails)
        {
            trail.emitting = false;
            trail.Clear();
            trail.emitting = true;
        }
        foreach (var system in emitters) system.Play(false);
    }

    private static void Stop(ParticleSystem[] systems, TrailRenderer[] trails)
    {
        foreach (var system in systems) system.Stop(false, ParticleSystemStopBehavior.StopEmitting);
        foreach (var trail in trails) trail.emitting = false;
    }

    private static bool NativeTrailIsVisible(TrailRenderer[] trails)
    {
        var camera = new GameObject("Trail check camera").AddComponent<Camera>();
        camera.enabled = false;
        camera.transform.position = new Vector3(0.8f, 0, -6);
        camera.orthographic = true;
        camera.orthographicSize = 1.2f;
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = Color.black;
        var target = RenderTexture.GetTemporary(192, 192, 24);
        var image = new Texture2D(192, 192, TextureFormat.RGB24, false);
        var previous = RenderTexture.active;
        try
        {
            var rendered = ReadPixels();
            foreach (var trail in trails) trail.forceRenderingOff = true;
            var background = ReadPixels();
            return rendered.Where((pixel, index) => Math.Abs(pixel.r - background[index].r) > 15 ||
                Math.Abs(pixel.g - background[index].g) > 15 || Math.Abs(pixel.b - background[index].b) > 15).Any();
        }
        finally
        {
            foreach (var trail in trails) trail.forceRenderingOff = false;
            RenderTexture.active = previous;
            RenderTexture.ReleaseTemporary(target);
            Object.Destroy(image);
            Object.Destroy(camera.gameObject);
        }

        Color32[] ReadPixels()
        {
            RenderPipeline.SubmitRenderRequest(camera, new RenderPipeline.StandardRequest { destination = target });
            RenderTexture.active = target;
            image.ReadPixels(new Rect(0, 0, 192, 192), 0, 0);
            return image.GetPixels32();
        }
    }

    private static IEnumerable Move(Transform root, int frames)
    {
        for (int frame = 0; frame < frames; frame++)
        {
            root.position += Vector3.right * 0.13f;
            foreach (object step in Wait(1f / 60)) yield return step;
        }
    }

    private static IEnumerable Wait(float seconds)
    {
        float end = Time.time + seconds;
        do { yield return null; } while (Time.time < end);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
