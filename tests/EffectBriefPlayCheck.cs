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
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

[InitializeOnLoad]
public static class EffectBriefPlayCheck
{
    private const string ManifestKey = "VfxCreatorEffectBriefPlayCheck";
    private static IEnumerator checks;
    private static string successMessage;

    [Serializable]
    private sealed class Inputs
    {
        public string[] effects;
        public string motionPrefab;
        public string gameplayScene;
        public string gameplayOutput;
        public ArtDirectionCase[] artDirection;
    }

    [Serializable]
    private sealed class ArtDirectionCase
    {
        public string label;
        public string effect;
        public float actorWidth;
        public float eventTime;
        public float duration;
        public float framing;
        public float cameraPitch;
        public float travel;
        public float arc;
        public int[] frames;
    }

    [Serializable]
    private sealed class ArtDirectionPlay
    {
        public string context;
        public int seed;
        public bool resetClean;
        public bool played;
        public bool cleared;
        public float clearedAt = -1;
        public float stoppedAt = -1;
    }

    [Serializable]
    private sealed class ArtDirectionReport
    {
        public ArtDirectionPlay[] plays;
    }

    [Serializable]
    private sealed class Effect
    {
        public string id;
        public string prefab;
        public string mode;
        public string[] startEmitters;
    }

    [Serializable]
    private sealed class GameplayCapture
    {
        public string scene;
        public string camera;
        public int width;
        public int height;
        public string urpAsset;
        public bool cameraPostProcessing;
        public GameplaySample[] samples;
    }

    [Serializable]
    private sealed class GameplaySample
    {
        public string effect;
        public string phase;
        public double timeSeconds;
        public double secondsSinceStop;
        public string frame;
        public int changedPixels;
        public int liveParticles;
        public Vector3 worldPosition;
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
            var inputs = ReadInputs(manifest);
            bool gameplay = !string.IsNullOrEmpty(inputs.gameplayScene);
            if (inputs.artDirection != null && inputs.artDirection.Length > 0)
            {
                checks = CheckArtDirection(inputs);
                successMessage = "Art direction Play Mode captures saved.";
            }
            else
            {
                checks = gameplay ? CaptureGameplay(inputs) : Verify(inputs);
                successMessage = gameplay ? "Effect brief gameplay captures saved." : "Effect brief Play Mode checks passed.";
            }
            EditorApplication.update += Update;
        };
    }

    public static void Run()
    {
        string[] args = Environment.GetCommandLineArgs();
        int index = Array.IndexOf(args, "-vfxPlayCheck");
        string manifest = args[index + 1];
        var inputs = ReadInputs(manifest);
        if (inputs.artDirection != null && inputs.artDirection.Length > 0)
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        else if (string.IsNullOrEmpty(inputs.gameplayScene))
            EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
        else
            EditorSceneManager.OpenScene(inputs.gameplayScene, OpenSceneMode.Single);
        SessionState.SetString(ManifestKey, manifest);
        EditorApplication.EnterPlaymode();
    }

    private static Inputs ReadInputs(string path) => JsonUtility.FromJson<Inputs>(File.ReadAllText(path));

    private static void Update()
    {
        try
        {
            if (checks.MoveNext()) return;
            Debug.Log(successMessage);
            EditorApplication.Exit(0);
        }
        catch (Exception error)
        {
            Debug.LogException(error);
            EditorApplication.Exit(1);
        }
    }

    private static IEnumerator Verify(Inputs inputs)
    {
        foreach (string path in inputs.effects)
        {
            var effect = JsonUtility.FromJson<Effect>(File.ReadAllText(path));
            var prefab = AssetDatabase.LoadAssetAtPath<GameObject>(effect.prefab);
            int created = 0;
            using var pool = new UnityEngine.Pool.ObjectPool<GameObject>(() =>
            {
                created++;
                return Object.Instantiate(prefab);
            }, root => root.SetActive(true), root => root.SetActive(false), root => Object.Destroy(root), maxSize: 1);

            const int plays = 10;
            for (int play = 0; play < plays; play++)
            {
                var root = pool.Get();
                var systems = root.GetComponentsInChildren<ParticleSystem>();
                var trails = root.GetComponentsInChildren<TrailRenderer>();
                var emitters = ResolveEmitters(effect, root.transform);
                root.transform.position = effect.mode == "trail" ? new Vector3(play * 10, 0, 0) : Vector3.zero;
                if (play == 0)
                {
                    foreach (var system in systems)
                    {
                        var main = system.main;
                        main.cullingMode = ParticleSystemCullingMode.AlwaysSimulate;
                    }
                    foreach (object step in Wait(0.05f)) yield return step;
                    Require(systems.All(system => !system.useAutoRandomSeed), "A legacy recipe enabled automatic seeding.");
                    Require(systems.All(system => !system.main.playOnAwake && !system.IsAlive(false)),
                        effect.mode + " particles started automatically.");
                    Require(trails.All(trail => !trail.emitting), effect.mode + " trails started automatically.");
                }

                Reset(systems, trails);
                Require(systems.All(system => system.particleCount == 0 && !system.IsAlive(false)) &&
                    trails.All(trail => !trail.emitting && trail.positionCount == 0),
                    $"{effect.mode} retained particles or trail positions before play {play + 1}.");
                Play(emitters, trails);
                foreach (object step in VerifyPlayback(effect, root, emitters, systems, trails, play + 1)) yield return step;
                pool.Release(root);
                foreach (object step in Wait(1f / 60)) yield return step;
            }
            Require(created == 1 && pool.CountActive == 0 && pool.CountInactive == 1,
                effect.mode + " did not reuse and return one instance.");
            Debug.Log($"Verified {plays} pooled plays: {effect.prefab}");
        }

        VerifyMotion(inputs.motionPrefab);
    }

    private static IEnumerable VerifyPlayback(Effect effect, GameObject root, ParticleSystem[] emitters,
        ParticleSystem[] systems, TrailRenderer[] trails, int play)
    {
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
                if (!emitters.Any(system => system.particleCount > 0))
                {
                    var states = emitters.Select(system => $"{system.name} time={system.time:F2} playing={system.isPlaying} emitting={system.isEmitting}");
                    throw new InvalidOperationException($"Aura did not sustain across a loop on play {play}. {string.Join(", ", states)}");
                }
                Stop(systems, trails);
                Require(systems.Any(system => system.particleCount > 0), "Aura particles were cleared immediately.");
                foreach (object step in Wait(0.55f)) yield return step;
                Require(systems.All(system => !system.IsAlive(false)), "Aura did not settle after stop.");
                break;
            case "trail":
                float startX = root.transform.position.x;
                foreach (object step in Move(root.transform, 12, Vector3.right * 0.13f)) yield return step;
                foreach (var trail in trails)
                {
                    var positions = new Vector3[trail.positionCount];
                    trail.GetPositions(positions);
                    Require(positions.Length > 2 && positions.All(position => position.x >= startX - 0.1f),
                        "The trail did not draw or connected to an old position.");
                }
                if (play == 1)
                    Require(NativeTrailIsVisible(trails), "The native TrailRenderer produced no visible pixels in Play Mode.");
                Stop(systems, trails);
                foreach (object step in Wait(trails.Max(trail => trail.time) + 0.1f)) yield return step;
                if (play == 1) Require(!NativeTrailIsVisible(trails), "A stopped trail did not fade.");
                break;
            default:
                throw new InvalidOperationException("Unexpected effect mode " + effect.mode);
        }
    }

    private static ParticleSystem[] ResolveEmitters(Effect effect, Transform root) => effect.startEmitters.Select(address =>
    {
        Transform node = root;
        foreach (string index in address.Split('/')) node = node.GetChild(int.Parse(index));
        return node.GetComponent<ParticleSystem>();
    }).ToArray();

    private static IEnumerator CaptureGameplay(Inputs inputs)
    {
        yield return null;
        Require(SceneManager.GetActiveScene().path == inputs.gameplayScene, "The requested gameplay scene is no longer active.");
        var camera = Camera.main;
        Require(camera != null, "The gameplay scene needs an active camera tagged MainCamera.");
        var floor = new Plane(Vector3.up, Vector3.zero);
        var ray = camera.ViewportPointToRay(new Vector3(0.5f, 0.5f));
        Require(floor.Raycast(ray, out float distance), "The gameplay camera must face the ground plane at Y = 0.");
        var center = ray.GetPoint(distance);
        var right = Vector3.ProjectOnPlane(camera.transform.right, Vector3.up).normalized;
        var player = GameObject.FindWithTag("Player") ?? GameObject.Find("Player");
        const int width = 960, height = 540;
        var report = new GameplayCapture
        {
            scene = inputs.gameplayScene,
            camera = camera.name,
            width = width,
            height = height,
            urpAsset = GraphicsSettings.currentRenderPipeline?.name,
            cameraPostProcessing = camera.TryGetComponent<UniversalAdditionalCameraData>(out var cameraData) &&
                cameraData.renderPostProcessing
        };
        var samples = new List<GameplaySample>();
        Directory.CreateDirectory(inputs.gameplayOutput);
        var target = RenderTexture.GetTemporary(width, height, 24);
        var image = new Texture2D(width, height, TextureFormat.RGB24, false);
        try
        {
            Require(RenderPipeline.SupportsRenderRequest(camera, new RenderPipeline.StandardRequest { destination = target }),
                "The gameplay camera does not support an off-screen render request.");
            ReadPixels(camera, target, image);
            foreach (string path in inputs.effects)
            {
                var effect = JsonUtility.FromJson<Effect>(File.ReadAllText(path));
                var anchor = center;
                anchor.y = effect.mode == "loop" ? 0.03f : 0.25f;
                if (effect.mode == "loop" && player != null)
                    anchor = new Vector3(player.transform.position.x, anchor.y, player.transform.position.z);
                if (effect.mode == "trail") anchor -= right * 0.78f;
                var root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(effect.prefab), anchor, Quaternion.identity);
                var systems = root.GetComponentsInChildren<ParticleSystem>();
                var trails = root.GetComponentsInChildren<TrailRenderer>();
                var renderers = root.GetComponentsInChildren<Renderer>();
                var hidden = renderers.Select(renderer => renderer.forceRenderingOff).ToArray();
                yield return null;
                Reset(systems, trails);
                double started = Time.timeAsDouble, stopped = -1;
                Play(ResolveEmitters(effect, root.transform), trails);
                switch (effect.mode)
                {
                    case "oneShot":
                        foreach (object step in Wait(0.07f)) yield return step;
                        Save("contact");
                        foreach (object step in Wait(0.15f)) yield return step;
                        Save("aftershock");
                        foreach (object step in Wait(0.18f)) yield return step;
                        Save("settled");
                        break;
                    case "loop":
                        foreach (object step in Wait(0.9f)) yield return step;
                        Save("sustained");
                        stopped = Time.timeAsDouble;
                        Stop(systems, trails);
                        foreach (object step in Wait(0.12f)) yield return step;
                        Save("releasing");
                        foreach (object step in Wait(0.43f)) yield return step;
                        Save("settled");
                        break;
                    case "trail":
                        foreach (object step in Move(root.transform, 12, right * 0.13f)) yield return step;
                        Save("moving");
                        stopped = Time.timeAsDouble;
                        Stop(systems, trails);
                        foreach (object step in Wait(0.12f)) yield return step;
                        Save("releasing");
                        foreach (object step in Wait(0.20f)) yield return step;
                        Save("settled");
                        break;
                    default:
                        throw new InvalidOperationException("Unexpected effect mode " + effect.mode);
                }
                Object.Destroy(root);
                yield return null;

                void Save(string phase)
                {
                    string frame = $"{effect.id}-{phase}.png";
                    var rendered = ReadPixels(camera, target, image);
                    File.WriteAllBytes(Path.Combine(inputs.gameplayOutput, frame), image.EncodeToPNG());
                    foreach (var renderer in renderers) renderer.forceRenderingOff = true;
                    Color32[] background;
                    try { background = ReadPixels(camera, target, image); }
                    finally
                    {
                        for (int i = 0; i < renderers.Length; i++) renderers[i].forceRenderingOff = hidden[i];
                    }
                    samples.Add(new GameplaySample
                    {
                        effect = effect.id,
                        phase = phase,
                        timeSeconds = Time.timeAsDouble - started,
                        secondsSinceStop = stopped < 0 ? -1 : Time.timeAsDouble - stopped,
                        frame = frame,
                        liveParticles = systems.Sum(system => system.particleCount),
                        worldPosition = root.transform.position,
                        changedPixels = rendered.Where((pixel, index) => PixelChanged(pixel, background[index])).Count()
                    });
                }
            }
        }
        finally
        {
            RenderTexture.ReleaseTemporary(target);
            Object.Destroy(image);
        }
        report.samples = samples.ToArray();
        File.WriteAllText(Path.Combine(inputs.gameplayOutput, "gameplay.json"), JsonUtility.ToJson(report, true));
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

    private static IEnumerator CheckArtDirection(Inputs inputs)
    {
        const int size = 384, fps = 60;
        var camera = new GameObject("Art direction camera").AddComponent<Camera>();
        camera.enabled = false;
        camera.orthographic = true;
        camera.clearFlags = CameraClearFlags.SolidColor;
        var target = RenderTexture.GetTemporary(size, size, 24);
        var image = new Texture2D(size, size, TextureFormat.RGB24, false);
        var shader = Shader.Find("Universal Render Pipeline/Unlit");
        Require(shader != null, "The gameplay stand needs the URP Unlit shader.");
        var floorMaterial = new Material(shader);
        var actorMaterial = new Material(shader) { color = new Color(0.22f, 0.58f, 0.71f) };
        var floor = GameObject.CreatePrimitive(PrimitiveType.Plane);
        floor.transform.position = new Vector3(0, -0.03f, 0);
        floor.GetComponent<Renderer>().sharedMaterial = floorMaterial;
        var actor = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        actor.GetComponent<Renderer>().sharedMaterial = actorMaterial;
        var contexts = new[] { "dark", "light", "overlap", "seed-41", "seed-859" };
        var seeds = new[] { 1729, 1729, 1729, 41, 859 };
        try
        {
            foreach (var item in inputs.artDirection)
            {
                var effect = JsonUtility.FromJson<Effect>(File.ReadAllText(item.effect));
                var prefab = AssetDatabase.LoadAssetAtPath<GameObject>(effect.prefab);
                Require(prefab != null, "Missing effect prefab for " + item.label);
                camera.orthographicSize = item.framing / 2;
                var rotation = Quaternion.Euler(item.cameraPitch, 0, 0);
                camera.transform.SetPositionAndRotation(rotation * new Vector3(0, 0, -12), rotation);
                actor.transform.localScale = new Vector3(item.actorWidth, item.actorWidth * 0.63f, item.actorWidth);
                float actorX = effect.mode == "loop" ? 0 : effect.mode == "trail" ? -item.travel * 0.5f : -item.actorWidth * 0.75f;
                actor.transform.position = new Vector3(actorX, item.actorWidth * 0.63f, 0.40f);
                var root = Object.Instantiate(prefab);
                var overlap = Object.Instantiate(prefab);
                overlap.SetActive(false);
                yield return null;
                var systems = root.GetComponentsInChildren<ParticleSystem>();
                var trails = root.GetComponentsInChildren<TrailRenderer>();
                var emitters = ResolveEmitters(effect, root.transform);
                var otherSystems = overlap.GetComponentsInChildren<ParticleSystem>(true);
                var otherTrails = overlap.GetComponentsInChildren<TrailRenderer>(true);
                var otherEmitters = ResolveEmitters(effect, overlap.transform);
                string directory = Path.Combine(inputs.gameplayOutput, item.label);
                var plays = new List<ArtDirectionPlay>();
                for (int play = 0; play < contexts.Length; play++)
                {
                    string context = contexts[play];
                    bool layered = context == "overlap";
                    floorMaterial.color = context == "light" ? new Color(0.69f, 0.63f, 0.51f) : new Color(0.10f, 0.13f, 0.17f);
                    camera.backgroundColor = floorMaterial.color;
                    string frames = Path.Combine(directory, context);
                    Directory.CreateDirectory(frames);
                    root.transform.position = ArtDirectionPosition(item, 0);
                    overlap.SetActive(layered);
                    overlap.transform.position = root.transform.position + new Vector3(-0.30f, 0.03f, 0.43f);
                    Reset(systems, trails);
                    Reset(otherSystems, otherTrails);
                    var result = new ArtDirectionPlay
                    {
                        context = context,
                        seed = seeds[play],
                        resetClean = systems.All(system => !system.IsAlive(false)) &&
                            trails.All(trail => !trail.emitting && trail.positionCount == 0)
                    };
                    for (int index = 0; index < systems.Length; index++)
                    {
                        systems[index].useAutoRandomSeed = false;
                        systems[index].randomSeed = (uint)(seeds[play] + index * 37);
                    }
                    if (layered) Play(otherEmitters, otherTrails);
                    foreach (object step in Wait(3f / fps)) yield return step;
                    Play(emitters, trails);
                    int started = Time.frameCount;
                    int last = Mathf.CeilToInt(item.duration * fps);
                    for (int frame = 0; frame <= last; frame++)
                    {
                        while (Time.frameCount - started < frame) yield return null;
                        float time = frame / (float)fps;
                        if (effect.mode != "oneShot" && result.stoppedAt < 0 && time >= item.eventTime)
                        {
                            result.stoppedAt = time;
                            Stop(systems, trails);
                            Stop(otherSystems, otherTrails);
                        }
                        root.transform.position = ArtDirectionPosition(item, time);
                        if (layered) overlap.transform.position = root.transform.position + new Vector3(-0.30f, 0.03f, 0.43f);
                        if (play == 0 || item.frames.Contains(frame))
                        {
                            ReadPixels(camera, target, image);
                            File.WriteAllBytes(Path.Combine(frames, $"frame-{frame:0000}.png"), image.EncodeToPNG());
                        }
                        else
                        {
                            // TrailRenderer can update its point history while rendering.
                            RenderPipeline.SubmitRenderRequest(camera, new RenderPipeline.StandardRequest { destination = target });
                        }
                        bool alive = systems.Any(system => system.particleCount > 0) || trails.Any(trail => trail.positionCount > 1);
                        result.played |= alive;
                        if (alive) result.clearedAt = -1;
                        else if (result.played && result.clearedAt < 0) result.clearedAt = time;
                    }
                    File.WriteAllText(Path.Combine(frames, "capture.json"), $"{{\"frames\":{last + 1},\"settings\":{{\"fps\":{fps}}}}}");
                    result.cleared = result.clearedAt >= 0;
                    plays.Add(result);
                }
                File.WriteAllText(Path.Combine(directory, "playback.json"),
                    JsonUtility.ToJson(new ArtDirectionReport { plays = plays.ToArray() }, true));
                Object.Destroy(root);
                Object.Destroy(overlap);
                yield return null;
            }
        }
        finally
        {
            RenderTexture.ReleaseTemporary(target);
            Object.Destroy(image);
            Object.Destroy(floorMaterial);
            Object.Destroy(actorMaterial);
        }
    }

    private static Vector3 ArtDirectionPosition(ArtDirectionCase item, float time)
    {
        if (item.travel <= 0) return Vector3.zero;
        float progress = Mathf.Clamp01(time / item.eventTime);
        return new Vector3((progress - 0.5f) * item.travel, Mathf.Sin(progress * Mathf.PI) * item.arc, 0);
    }

    private static void Reset(ParticleSystem[] systems, TrailRenderer[] trails)
    {
        foreach (var system in systems) system.Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear);
        foreach (var trail in trails)
        {
            trail.emitting = false;
            trail.Clear();
        }
    }

    private static void Play(ParticleSystem[] emitters, TrailRenderer[] trails)
    {
        foreach (var trail in trails) trail.emitting = true;
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
        try
        {
            var rendered = ReadPixels(camera, target, image);
            foreach (var trail in trails) trail.forceRenderingOff = true;
            var background = ReadPixels(camera, target, image);
            return rendered.Where((pixel, index) => PixelChanged(pixel, background[index])).Any();
        }
        finally
        {
            foreach (var trail in trails) trail.forceRenderingOff = false;
            RenderTexture.ReleaseTemporary(target);
            Object.Destroy(image);
            Object.Destroy(camera.gameObject);
        }
    }

    private static bool PixelChanged(Color32 first, Color32 second) => Math.Abs(first.r - second.r) > 15 ||
        Math.Abs(first.g - second.g) > 15 || Math.Abs(first.b - second.b) > 15;

    private static Color32[] ReadPixels(Camera camera, RenderTexture target, Texture2D image)
    {
        var previous = RenderTexture.active;
        try
        {
            RenderPipeline.SubmitRenderRequest(camera, new RenderPipeline.StandardRequest { destination = target });
            RenderTexture.active = target;
            image.ReadPixels(new Rect(0, 0, image.width, image.height), 0, 0);
            return image.GetPixels32();
        }
        finally { RenderTexture.active = previous; }
    }

    private static IEnumerable Move(Transform root, int frames, Vector3 step)
    {
        for (int frame = 0; frame < frames; frame++)
        {
            root.position += step;
            int movedAt = Time.frameCount;
            do { yield return null; } while (Time.frameCount == movedAt);
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
