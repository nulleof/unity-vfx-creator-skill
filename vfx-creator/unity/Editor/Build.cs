using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace VfxCreator.Editor
{
    internal static class Build
    {
        private const string OutputRoot = "Assets/VfxCreatorGenerated";

        internal static StagedPrefab Stage(Recipe recipe, Request request, out EffectPlayback playback)
        {
            if (recipe.version != 1 || recipe.layers == null || recipe.layers.Length == 0)
                throw new ArgumentException("Expected a version 1 recipe with at least one layer.");
            string id = string.IsNullOrEmpty(request.id) ? recipe.id : request.id;
            var staged = StagePrefab(id, request.stagingToken);
            string work = staged.WorkPath;
            var root = new GameObject(string.IsNullOrWhiteSpace(recipe.title) ? id : recipe.title);
            try
            {
                string shaderPath = work + "/Layer.shader";
                File.WriteAllText(shaderPath, File.ReadAllText(request.shader).Replace("VfxCreator/URP Layer", "VfxCreator/" + id));
                AssetDatabase.ImportAsset(shaderPath, ImportAssetOptions.ForceSynchronousImport);
                var shader = AssetDatabase.LoadAssetAtPath<Shader>(shaderPath);
                if (shader == null || !shader.isSupported || ShaderUtil.ShaderHasError(shader))
                    throw new InvalidOperationException("The generated URP shader did not compile in this project.");
                var phases = new Dictionary<string, Transform>();
                var systems = new ParticleSystem[recipe.layers.Length];
                Mesh mesh = null;
                for (int index = 0; index < recipe.layers.Length; index++)
                {
                    var layer = recipe.layers[index] ?? throw new ArgumentException($"Missing layer {index}.");
                    string phase = string.IsNullOrWhiteSpace(layer.phase) ? "body" : layer.phase;
                    if (!phases.TryGetValue(phase, out Transform parent))
                    {
                        parent = new GameObject(phase).transform;
                        parent.SetParent(root.transform, false);
                        phases.Add(phase, parent);
                    }
                    var child = new GameObject(string.IsNullOrWhiteSpace(layer.name) ? $"Layer {index + 1}" : layer.name);
                    child.transform.SetParent(parent, false);
                    child.transform.SetLocalPositionAndRotation(layer.position, Quaternion.Euler(layer.euler));
                    child.transform.localScale = layer.scale;
                    string assetStem = $"{work}/layer-{index + 1:D2}";
                    var material = MaterialFor(layer, shader, assetStem, request.resourceRoot, recipe.seed + index);
                    if (layer.kind == "trail") AddTrail(child, layer, material);
                    else if (layer.kind == "particles")
                    {
                        if (layer.render == "Mesh" && mesh == null)
                        {
                            mesh = Geometry();
                            AssetDatabase.CreateAsset(mesh, work + "/fragment.asset");
                        }
                        systems[index] = AddParticles(child, layer, material, mesh, recipe, index);
                    }
                    else throw new ArgumentException($"Unknown layer kind '{layer.kind}'.");
                }
                ConnectSubEmitters(recipe, systems);
                playback = request.HasEffectBrief ? EffectPlayback.Prepare(root, recipe, systems, request) : null;
                var prefab = PrefabUtility.SaveAsPrefabAsset(root, staged.Path, out bool saved);
                if (!saved || prefab == null) throw new IOException("Unity could not save the prefab.");
                AssetDatabase.SaveAssets();
                return staged;
            }
            catch
            {
                staged.Dispose();
                throw;
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(root);
            }
        }

        internal static StagedPrefab StagePrefab(string id, string token)
        {
            if (!Regex.IsMatch(id ?? "", @"\A[a-z0-9][a-z0-9-]{0,63}\z"))
                throw new ArgumentException("The output id must contain 1–64 lowercase letters, digits or hyphens.");
            if (!AssetDatabase.IsValidFolder(OutputRoot)) AssetDatabase.CreateFolder("Assets", "VfxCreatorGenerated");
            string destination = OutputRoot + "/" + id;
            if (Directory.Exists(destination) || File.Exists(destination))
                throw new IOException($"'{destination}' already exists. Choose a new output ID to preserve prefab references.");
            Guid stagingToken = Guid.TryParseExact(token, "N", out Guid supplied) ? supplied : Guid.NewGuid();
            string work = OutputRoot + "/staging-" + stagingToken.ToString("N");
            AssetDatabase.CreateFolder(OutputRoot, Path.GetFileName(work));
            return new StagedPrefab(work, destination);
        }

        internal sealed class StagedPrefab : IDisposable
        {
            private readonly string work;
            private readonly string destination;

            internal StagedPrefab(string work, string destination)
            {
                this.work = work;
                this.destination = destination;
            }

            internal string WorkPath => work;
            internal string Path => work + "/Effect.prefab";
            internal string PublishedPath => destination + "/Effect.prefab";

            internal void Publish(Action complete = null)
            {
                string error = AssetDatabase.MoveAsset(work, destination);
                if (!string.IsNullOrEmpty(error)) throw new IOException(error);
                try
                {
                    complete?.Invoke();
                }
                catch
                {
                    AssetDatabase.DeleteAsset(destination);
                    throw;
                }
            }

            public void Dispose()
            {
                if (AssetDatabase.IsValidFolder(work)) AssetDatabase.DeleteAsset(work);
            }
        }

        private static Material MaterialFor(Layer layer, Shader shader, string stem, string resources, int seed)
        {
            var textureRecipe = layer.texture ?? new TextureRecipe();
            string texturePath = stem + ".png";
            if (string.IsNullOrEmpty(textureRecipe.png))
                File.WriteAllBytes(texturePath, Masks.Generate(textureRecipe, seed));
            else
            {
                string source = Path.GetFullPath(Path.Combine(resources, textureRecipe.png));
                string relative = Path.GetRelativePath(resources, source);
                if (relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) ||
                    Path.IsPathRooted(relative) || !source.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("Texture png must name an original PNG inside -ResourceRoot.");
                File.Copy(source, texturePath);
            }
            AssetDatabase.ImportAsset(texturePath, ImportAssetOptions.ForceSynchronousImport);
            var importer = AssetImporter.GetAtPath(texturePath) as TextureImporter ??
                throw new IOException($"Could not import '{texturePath}'.");
            importer.alphaSource = TextureImporterAlphaSource.FromInput;
            importer.alphaIsTransparency = true;
            importer.wrapMode = TextureWrapMode.Clamp;
            importer.mipmapEnabled = false;
            importer.textureCompression = TextureImporterCompression.Uncompressed;
            importer.SaveAndReimport();
            var material = new Material(shader) { name = layer.name + " material" };
            material.SetTexture("_BaseMap", AssetDatabase.LoadAssetAtPath<Texture2D>(texturePath));
            material.SetColor("_Tint", layer.tint);
            material.SetFloat("_Glow", Mathf.Max(0, layer.glow));
            material.SetFloat("_Softness", Mathf.Max(0, layer.softness));
            material.SetFloat("_DstBlend", (float)(layer.blend == "alpha" ? BlendMode.OneMinusSrcAlpha : BlendMode.One));
            AssetDatabase.CreateAsset(material, stem + ".mat");
            return material;
        }

        private static ParticleSystem AddParticles(GameObject child, Layer layer, Material material, Mesh mesh, Recipe recipe, int index)
        {
            var system = child.AddComponent<ParticleSystem>();
            system.Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear);
            system.randomSeed = unchecked((uint)(recipe.seed + index * 104729));
            system.useAutoRandomSeed = recipe.randomizeOnPlay;
            var main = system.main;
            main.duration = Mathf.Max(0.02f, layer.duration);
            main.loop = layer.loop;
            main.prewarm = layer.loop && layer.prewarm;
            main.playOnAwake = layer.playOnAwake;
            main.maxParticles = Mathf.Clamp(layer.maxParticles, 1, 30000);
            main.simulationSpace = layer.worldSpace ? ParticleSystemSimulationSpace.World : ParticleSystemSimulationSpace.Local;
            main.scalingMode = ParticleSystemScalingMode.Hierarchy;
            main.startDelay = layer.delay.Unity();
            main.startLifetime = layer.lifetime.Unity();
            main.startSpeed = layer.speed.Unity();
            main.startSize = layer.size.Unity();
            if (layer.Uses(nameof(Layer.rotation3D)))
            {
                var axes = layer.rotation3D;
                var (x, y, z) = MatchAxisModes(child.name, nameof(Layer.rotation3D), axes.x, axes.y, axes.z);
                main.startRotation3D = true;
                main.startRotationX = x;
                main.startRotationY = y;
                main.startRotationZ = z;
            }
            else
                main.startRotation = layer.rotation.Unity();
            main.startColor = layer.startColor.Unity();
            main.gravityModifier = layer.gravity.Unity();

            var emission = system.emission;
            emission.rateOverTime = layer.rate.Unity();
            emission.rateOverDistance = layer.distanceRate.Unity();
            emission.SetBursts(Array.ConvertAll(layer.bursts ?? Array.Empty<Burst>(), burst =>
                new ParticleSystem.Burst(burst.time, burst.count.Unity(), Mathf.Max(0, burst.cycles), Mathf.Max(0.001f, burst.interval))
                { probability = Mathf.Clamp01(burst.probability) }));
            ConfigureShape(system, layer.Uses(nameof(Layer.shape)) ? layer.shape : null, mesh);
            ConfigureMovement(system, layer);
            if (layer.Uses(nameof(Layer.trail))) ConfigureTrails(system, layer.trail);
            ConfigureSheet(system, layer.texture);

            var renderer = child.GetComponent<ParticleSystemRenderer>();
            renderer.sharedMaterial = material;
            if (Enum.TryParse(layer.render, true, out ParticleSystemRenderMode mode)) renderer.renderMode = mode;
            if (Enum.TryParse(layer.alignment, true, out ParticleSystemRenderSpace alignment)) renderer.alignment = alignment;
            renderer.lengthScale = layer.lengthScale;
            renderer.velocityScale = layer.velocityScale;
            renderer.sortingFudge = layer.sortBias;
            if (layer.maxScreenSize > 0) renderer.maxParticleSize = Mathf.Clamp01(layer.maxScreenSize);
            renderer.shadowCastingMode = ShadowCastingMode.Off;
            renderer.receiveShadows = false;
            if (renderer.renderMode == ParticleSystemRenderMode.Mesh) renderer.mesh = mesh;
            if (layer.Uses(nameof(Layer.trail))) renderer.trailMaterial = material;
            return system;
        }

        private static void ConfigureShape(ParticleSystem system, Shape source, Mesh mesh)
        {
            var shape = system.shape;
            shape.enabled = source != null;
            if (source == null) return;
            if (Enum.TryParse(source.type, true, out ParticleSystemShapeType type)) shape.shapeType = type;
            if (shape.shapeType == ParticleSystemShapeType.Mesh)
            {
                if (mesh != null) shape.mesh = mesh;
                else shape.shapeType = ParticleSystemShapeType.Sphere;
            }
            if (shape.shapeType == ParticleSystemShapeType.MeshRenderer || shape.shapeType == ParticleSystemShapeType.SkinnedMeshRenderer ||
                shape.shapeType == ParticleSystemShapeType.Sprite || shape.shapeType == ParticleSystemShapeType.SpriteRenderer)
                shape.shapeType = ParticleSystemShapeType.Sphere;
            shape.radius = Mathf.Max(0, source.radius);
            shape.radiusThickness = Mathf.Clamp01(source.thickness);
            shape.angle = source.angle;
            shape.arc = source.arc;
            shape.length = source.length;
            shape.position = source.position;
            shape.rotation = source.euler;
            shape.scale = source.scale;
            shape.randomDirectionAmount = source.randomDirection;
            shape.sphericalDirectionAmount = source.sphericalDirection;
        }

        private static void ConfigureMovement(ParticleSystem system, Layer layer)
        {
            if (layer.Uses(nameof(Layer.colorOverLife)))
            {
                var color = system.colorOverLifetime;
                color.enabled = true;
                color.color = layer.colorOverLife.Unity();
            }
            if (layer.Uses(nameof(Layer.sizeOverLife)))
            {
                var size = system.sizeOverLifetime;
                size.enabled = true;
                size.size = layer.sizeOverLife.Unity();
            }
            bool usesSpin3D = layer.Uses(nameof(Layer.spinOverLife3D));
            if (usesSpin3D || layer.Uses(nameof(Layer.spinOverLife)))
            {
                var rotation = system.rotationOverLifetime;
                if (usesSpin3D)
                {
                    var axes = layer.spinOverLife3D;
                    var (x, y, z) = MatchAxisModes(system.name, nameof(Layer.spinOverLife3D), axes.x, axes.y, axes.z);
                    rotation.separateAxes = true;
                    rotation.x = x;
                    rotation.y = y;
                    rotation.z = z;
                }
                else
                    rotation.z = layer.spinOverLife.Unity();
                rotation.enabled = true;
            }
            bool usesX = layer.Uses(nameof(Layer.velocityX));
            bool usesY = layer.Uses(nameof(Layer.velocityY));
            bool usesZ = layer.Uses(nameof(Layer.velocityZ));
            if (usesX || usesY || usesZ)
            {
                var velocity = system.velocityOverLifetime;
                var (x, y, z) = MatchAxisModes(system.name, "Velocity over Lifetime",
                    usesX ? layer.velocityX : null, usesY ? layer.velocityY : null, usesZ ? layer.velocityZ : null);
                velocity.space = layer.velocityWorldSpace ? ParticleSystemSimulationSpace.World : ParticleSystemSimulationSpace.Local;
                velocity.x = x;
                velocity.y = y;
                velocity.z = z;
                velocity.enabled = true;
            }
            if (layer.noise > 0)
            {
                var noise = system.noise;
                noise.enabled = true;
                noise.strength = new ParticleSystem.MinMaxCurve(layer.noise);
                noise.frequency = Mathf.Max(0.01f, layer.noiseFrequency);
            }
        }

        private static (ParticleSystem.MinMaxCurve x, ParticleSystem.MinMaxCurve y, ParticleSystem.MinMaxCurve z)
            MatchAxisModes(string layer, string module, Curve x, Curve y, Curve z)
        {
            var xCurve = x?.Unity() ?? new ParticleSystem.MinMaxCurve(0);
            var yCurve = y?.Unity() ?? new ParticleSystem.MinMaxCurve(0);
            var zCurve = z?.Unity() ?? new ParticleSystem.MinMaxCurve(0);
            var mode = ParticleSystemCurveMode.Constant;
            string firstAxis = null;

            void Match(string axis, ParticleSystemCurveMode candidate)
            {
                if (candidate == ParticleSystemCurveMode.Constant) return;
                if (firstAxis == null)
                {
                    mode = candidate;
                    firstAxis = axis;
                }
                else if (mode != candidate)
                    throw new ArgumentException($"Layer '{layer}': {module} curve modes conflict on {firstAxis} ({mode}) and {axis} ({candidate}).");
            }

            Match("X", xCurve.mode);
            Match("Y", yCurve.mode);
            Match("Z", zCurve.mode);
            return (PromoteConstant(xCurve, mode), PromoteConstant(yCurve, mode), PromoteConstant(zCurve, mode));
        }

        private static ParticleSystem.MinMaxCurve PromoteConstant(ParticleSystem.MinMaxCurve curve, ParticleSystemCurveMode mode)
        {
            if (curve.mode != ParticleSystemCurveMode.Constant) return curve;
            float value = curve.constant;
            switch (mode)
            {
                case ParticleSystemCurveMode.TwoConstants:
                    return new ParticleSystem.MinMaxCurve(value, value);
                case ParticleSystemCurveMode.Curve:
                    return new ParticleSystem.MinMaxCurve(1, AnimationCurve.Constant(0, 1, value));
                case ParticleSystemCurveMode.TwoCurves:
                    return new ParticleSystem.MinMaxCurve(1,
                        AnimationCurve.Constant(0, 1, value), AnimationCurve.Constant(0, 1, value));
                default:
                    return curve;
            }
        }

        private static void ConfigureTrails(ParticleSystem system, Trail source)
        {
            if (source == null) return;
            var trails = system.trails;
            trails.enabled = true;
            trails.mode = source.ribbon ? ParticleSystemTrailMode.Ribbon : ParticleSystemTrailMode.PerParticle;
            trails.ribbonCount = Mathf.Max(1, source.ribbons);
            trails.ratio = Mathf.Clamp01(source.ratio);
            trails.lifetime = new ParticleSystem.MinMaxCurve(Mathf.Max(0.001f, source.time));
            trails.minVertexDistance = Mathf.Max(0.001f, source.minDistance);
            trails.worldSpace = source.worldSpace;
            trails.dieWithParticles = source.dieWithParticles;
            trails.inheritParticleColor = source.inheritParticleColor;
            trails.widthOverTrail = source.width.Unity();
            if (source.color?.mode != null) trails.colorOverTrail = source.color.Unity();
            if (source.colorOverLife?.mode != null) trails.colorOverLifetime = source.colorOverLife.Unity();
        }

        private static void ConfigureSheet(ParticleSystem system, TextureRecipe source)
        {
            if (source == null || (source.tilesX <= 1 && source.tilesY <= 1)) return;
            var sheet = system.textureSheetAnimation;
            sheet.enabled = true;
            sheet.numTilesX = Mathf.Clamp(source.tilesX, 1, 16);
            sheet.numTilesY = Mathf.Clamp(source.tilesY, 1, 16);
            sheet.frameOverTime = (source.animateFrameCurve ? source.frameOverLife : Curve.Ramp(0, 0.999f)).Unity();
        }

        private static void AddTrail(GameObject child, Layer layer, Material material)
        {
            var source = layer.Uses(nameof(Layer.trail)) ? layer.trail : new Trail();
            var trail = child.AddComponent<TrailRenderer>();
            trail.sharedMaterial = material;
            trail.time = Mathf.Max(0.01f, source.time);
            trail.minVertexDistance = Mathf.Max(0.001f, source.minDistance);
            trail.numCornerVertices = source.corners;
            trail.numCapVertices = source.caps;
            trail.widthCurve = source.width.Animation();
            trail.widthMultiplier = source.width.multiplier;
            trail.colorGradient = (source.color ?? Palette.Constant(Color.white)).Gradient();
            trail.shadowCastingMode = ShadowCastingMode.Off;
            trail.receiveShadows = false;
        }

        private static void ConnectSubEmitters(Recipe recipe, ParticleSystem[] systems)
        {
            for (int index = 0; index < systems.Length; index++)
            {
                var system = systems[index];
                if (system == null) continue;
                var links = recipe.layers[index].subEmitters;
                if (links == null || links.Length == 0) continue;
                var module = system.subEmitters;
                module.enabled = true;
                foreach (var link in links)
                {
                    if (link.layer < 0 || link.layer >= systems.Length || systems[link.layer] == null || link.layer == index)
                        throw new ArgumentException($"Invalid sub-emitter index {link.layer} on layer {index}.");
                    var target = systems[link.layer];
                    if (system.transform.IsChildOf(target.transform)) throw new ArgumentException("Sub-emitter hierarchy contains a cycle.");
                    if (!target.transform.IsChildOf(system.transform)) target.transform.SetParent(system.transform, true);
                    var targetMain = target.main;
                    targetMain.playOnAwake = false;
                    Enum.TryParse(link.trigger, true, out ParticleSystemSubEmitterType trigger);
                    Enum.TryParse(link.inherit, true, out ParticleSystemSubEmitterProperties inherit);
                    module.AddSubEmitter(target, trigger, inherit, Mathf.Clamp01(link.chance));
                }
            }
        }

        private static Mesh Geometry()
        {
            var mesh = new Mesh { name = "Procedural shard" };
            mesh.vertices = new[] { new Vector3(0, 0.55f), new Vector3(-0.27f, -0.19f, -0.15f),
                new Vector3(0.20f, -0.33f, -0.09f), new Vector3(0.09f, -0.13f, 0.28f) };
            mesh.uv = new[] { new Vector2(0.5f, 1), new Vector2(0.12f, 0.35f), new Vector2(0.81f, 0.12f), new Vector2(0.62f, 0.4f) };
            mesh.triangles = new[] { 0, 1, 2, 0, 2, 3, 0, 3, 1, 1, 3, 2 };
            mesh.RecalculateNormals();
            mesh.RecalculateBounds();
            return mesh;
        }
    }
}
