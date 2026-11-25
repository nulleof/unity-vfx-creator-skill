using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.VFX;

namespace VfxCreator.Editor
{
    [Serializable]
    internal sealed class GraphAnalysis
    {
        public GraphSnapshot[] graphs;
    }

    [Serializable]
    internal sealed class GraphSnapshot
    {
        public string component;
        public string initialEvent;
        public string[] events;
        public string[] systems;
        public GraphParameter[] parameters;
    }

    [Serializable]
    internal sealed class GraphParameter
    {
        public string name;
        public string type;
        public string value;
    }

    internal static class Analyze
    {
        internal static Recipe Prefab(GameObject root, Request request, out GraphSnapshot[] graphs)
        {
            var systems = root.GetComponentsInChildren<ParticleSystem>(true).Where(system => EnabledInPrefab(system.transform, root.transform)).ToArray();
            var layers = systems.Select(system => ReadParticle(system, root.transform)).ToList();
            for (int index = 0; index < systems.Length; index++)
                layers[index].subEmitters = ReadSubEmitters(systems[index], systems);
            layers.AddRange(root.GetComponentsInChildren<TrailRenderer>(true)
                .Where(trail => trail.enabled && EnabledInPrefab(trail.transform, root.transform))
                .Select(trail => ReadTrail(trail, root.transform)));

            var notes = new List<string>();
            var motions = root.GetComponentsInChildren<MonoBehaviour>(true).Where(component => component != null)
                .Select(component => component.GetType().Name).Distinct().ToArray();
            if (motions.Length > 0)
                notes.Add("Interpret any timing or motion from these components in the preview and recipe: " + string.Join(", ", motions));
            if (root.GetComponentsInChildren<MonoBehaviour>(true).Any(component => component == null))
                notes.Add("The reference includes a missing script; inspect the visual comparison for behavior it may have supplied.");

            var snapshots = new List<GraphSnapshot>();
            foreach (var effect in root.GetComponentsInChildren<VisualEffect>(true))
            {
                if (!effect.enabled || !EnabledInPrefab(effect.transform, root.transform) || !effect.visualEffectAsset) continue;
                var properties = new List<VFXExposedProperty>();
                effect.visualEffectAsset.GetExposedProperties(properties);
                var snapshot = ReadGraph(effect, root.transform, properties);
                snapshots.Add(snapshot);
                notes.Add("VFX Graph systems: " + string.Join(", ", snapshot.systems) + ". Tune the particle approximation against the capture.");
                notes.Add("Exposed parameters: " + string.Join(", ", snapshot.parameters.Select(parameter => parameter.name + " (" + parameter.type + ")")));
                AddGraphApproximation(effect, root.transform, request, layers, properties);
            }
            graphs = snapshots.ToArray();
            if (layers.Count == 0) throw new InvalidOperationException("No active Particle Systems, Trail Renderers or VFX Graph components were found.");
            if (layers.Any(layer => layer.render == "Mesh"))
                notes.Add("Mesh emitters use newly generated geometry. Adjust the mask and silhouette against the reference.");
            foreach (var layer in layers) layer.RecordActiveModules();

            return new Recipe
            {
                id = request.id,
                title = request.title,
                description = request.brief,
                tags = Regex.Matches((request.title + " " + request.brief).ToLowerInvariant(), @"[\p{L}\p{Nd}]{3,}")
                    .Cast<Match>().Select(match => match.Value).Distinct().ToArray(),
                notes = notes.ToArray(),
                duration = request.capture.duration,
                seed = request.capture.seed,
                layers = layers.ToArray()
            };
        }

        private static bool EnabledInPrefab(Transform item, Transform root)
        {
            while (item != root)
            {
                if (!item.gameObject.activeSelf) return false;
                item = item.parent;
            }
            return true;
        }

        private static Layer BaseLayer(Transform item, Transform root)
        {
            var relative = root.worldToLocalMatrix * item.localToWorldMatrix;
            return new Layer { name = item.name, position = relative.GetColumn(3), euler = relative.rotation.eulerAngles, scale = relative.lossyScale };
        }

        private static Layer ReadParticle(ParticleSystem system, Transform root)
        {
            var layer = BaseLayer(system.transform, root);
            var main = system.main;
            layer.duration = main.duration;
            layer.loop = main.loop;
            layer.prewarm = main.prewarm;
            layer.worldSpace = main.simulationSpace != ParticleSystemSimulationSpace.Local;
            layer.playOnAwake = main.playOnAwake;
            layer.maxParticles = main.maxParticles;
            layer.delay = Curve.Read(main.startDelay);
            layer.lifetime = Curve.Read(main.startLifetime);
            layer.speed = Curve.Read(main.startSpeed);
            layer.size = Curve.Read(main.startSize);
            layer.rotation = Curve.Read(main.startRotation);
            layer.gravity = Curve.Read(main.gravityModifier);
            layer.startColor = Palette.Read(main.startColor);

            var emission = system.emission;
            if (emission.enabled)
            {
                layer.rate = Curve.Read(emission.rateOverTime);
                layer.distanceRate = Curve.Read(emission.rateOverDistance);
                var bursts = new ParticleSystem.Burst[emission.burstCount];
                emission.GetBursts(bursts);
                layer.bursts = Array.ConvertAll(bursts, burst => new Burst
                {
                    time = burst.time, count = Curve.Read(burst.count), cycles = burst.cycleCount,
                    interval = burst.repeatInterval, probability = burst.probability
                });
            }
            var shape = system.shape;
            if (shape.enabled)
            {
                layer.shape = new Shape
                {
                    type = shape.shapeType.ToString(), radius = shape.radius, thickness = shape.radiusThickness,
                    angle = shape.angle, length = shape.length, arc = shape.arc,
                    position = shape.position, euler = shape.rotation, scale = shape.scale,
                    randomDirection = shape.randomDirectionAmount, sphericalDirection = shape.sphericalDirectionAmount
                };
            }
            var color = system.colorOverLifetime;
            if (color.enabled) layer.colorOverLife = Palette.Read(color.color);
            var size = system.sizeOverLifetime;
            if (size.enabled) layer.sizeOverLife = Curve.Read(size.size);
            var spin = system.rotationOverLifetime;
            if (spin.enabled) layer.spinOverLife = Curve.Read(spin.z);
            var velocity = system.velocityOverLifetime;
            if (velocity.enabled)
            {
                layer.velocityX = Curve.Read(velocity.x);
                layer.velocityY = Curve.Read(velocity.y);
                layer.velocityZ = Curve.Read(velocity.z);
                layer.velocityWorldSpace = velocity.space == ParticleSystemSimulationSpace.World;
            }
            var noise = system.noise;
            if (noise.enabled)
            {
                layer.noise = noise.strength.Evaluate(0.5f, 0.5f);
                layer.noiseFrequency = noise.frequency;
            }
            var renderer = system.GetComponent<ParticleSystemRenderer>();
            if (renderer != null)
            {
                layer.render = renderer.renderMode.ToString();
                layer.alignment = renderer.alignment.ToString();
                layer.lengthScale = renderer.lengthScale;
                layer.velocityScale = renderer.velocityScale;
                layer.sortBias = renderer.sortingFudge;
                layer.maxScreenSize = renderer.maxParticleSize;
                ReadMaterial(layer, renderer.sharedMaterial);
            }
            var sheet = system.textureSheetAnimation;
            if (sheet.enabled && sheet.mode == ParticleSystemAnimationMode.Grid)
            {
                layer.texture.tilesX = sheet.numTilesX;
                layer.texture.tilesY = sheet.numTilesY;
                layer.texture.frameOverLife = Curve.Read(sheet.frameOverTime);
                layer.texture.animateFrameCurve = true;
            }
            var trail = system.trails;
            if (trail.enabled)
            {
                layer.trail = new Trail
                {
                    time = trail.lifetime.Evaluate(0.5f, 0.5f), ratio = trail.ratio,
                    minDistance = trail.minVertexDistance, worldSpace = trail.worldSpace,
                    dieWithParticles = trail.dieWithParticles, inheritParticleColor = trail.inheritParticleColor,
                    ribbon = trail.mode == ParticleSystemTrailMode.Ribbon, ribbons = trail.ribbonCount,
                    width = Curve.Read(trail.widthOverTrail), color = Palette.Read(trail.colorOverTrail),
                    colorOverLife = Palette.Read(trail.colorOverLifetime)
                };
            }
            return layer;
        }

        private static SubEmitter[] ReadSubEmitters(ParticleSystem system, ParticleSystem[] systems)
        {
            var result = new List<SubEmitter>();
            var subEmitters = system.subEmitters;
            if (!subEmitters.enabled) return result.ToArray();
            for (int index = 0; index < subEmitters.subEmittersCount; index++)
            {
                var target = Array.IndexOf(systems, subEmitters.GetSubEmitterSystem(index));
                if (target < 0) continue;
                result.Add(new SubEmitter
                {
                    layer = target, trigger = subEmitters.GetSubEmitterType(index).ToString(),
                    inherit = subEmitters.GetSubEmitterProperties(index).ToString(),
                    chance = subEmitters.GetSubEmitterEmitProbability(index)
                });
            }
            return result.ToArray();
        }

        private static Layer ReadTrail(TrailRenderer renderer, Transform root)
        {
            var layer = BaseLayer(renderer.transform, root);
            layer.kind = "trail";
            layer.phase = "trail";
            layer.trail = new Trail
            {
                time = renderer.time,
                minDistance = renderer.minVertexDistance,
                width = Curve.Read(renderer.widthCurve, renderer.widthMultiplier),
                color = new Palette { mode = "gradient", gradient = Ramp.Read(renderer.colorGradient) },
                corners = renderer.numCornerVertices, caps = renderer.numCapVertices
            };
            ReadMaterial(layer, renderer.sharedMaterial);
            layer.texture.kind = "streak";
            return layer;
        }

        private static void ReadMaterial(Layer layer, Material material)
        {
            if (material == null || material.shader == null) return;
            var identity = (material.name + " " + material.shader.name).ToLowerInvariant();
            Texture texture = null;
            foreach (string property in new[] { "_BaseMap", "_MainTex", "_BaseColorMap", "_Texture" })
            {
                if (!material.HasProperty(property)) continue;
                texture = material.GetTexture(property);
                if (texture != null) break;
            }
            var textureHint = (layer.name + " " + texture?.name + " " + identity).ToLowerInvariant();
            var mask = "glow";
            if (Regex.IsMatch(textureHint, "smoke|cloud|dust|steam")) mask = "smoke";
            else if (Regex.IsMatch(textureHint, "ring|shockwave|ripple|circle|wave")) mask = "ring";
            else if (Regex.IsMatch(textureHint, "trail|streak|line|slash|ribbon")) mask = "streak";
            else if (Regex.IsMatch(textureHint, "flash|flare|star|shine")) mask = "star";
            else if (Regex.IsMatch(textureHint, "spark|debris|fragment|shard")) mask = "spark";
            else if (Regex.IsMatch(textureHint, "fire|flame")) mask = "flame";
            else if (Regex.IsMatch(textureHint, "bubble|liquid|splat")) mask = "bubble";
            layer.texture.kind = mask;
            foreach (string property in new[] { "_BaseColor", "_TintColor", "_Color" })
            {
                if (!material.HasProperty(property)) continue;
                layer.tint = material.GetColor(property);
                break;
            }
            bool additive = identity.Contains("additive") || (material.HasProperty("_DstBlend") &&
                Mathf.RoundToInt(material.GetFloat("_DstBlend")) == (int)BlendMode.One);
            layer.blend = additive ? "add" : "alpha";
            layer.glow = additive ? 1.35f : 1;
        }

        private static GraphSnapshot ReadGraph(VisualEffect effect, Transform root, List<VFXExposedProperty> properties)
        {
            var events = new List<string>();
            effect.visualEffectAsset.GetEvents(events);
            var systems = new List<string>();
            effect.GetParticleSystemNames(systems);
            return new GraphSnapshot
            {
                component = effect.transform == root ? root.name : AnimationUtility.CalculateTransformPath(effect.transform, root),
                initialEvent = effect.initialEventName,
                events = events.Distinct().OrderBy(name => name, StringComparer.Ordinal).ToArray(),
                systems = systems.ToArray(),
                parameters = properties.Select(property => new GraphParameter
                {
                    name = property.name, type = property.type.Name, value = ReadGraphValue(effect, property.name)
                }).ToArray()
            };
        }

        private static string ReadGraphValue(VisualEffect effect, string name)
        {
            var culture = CultureInfo.InvariantCulture;
            if (effect.HasFloat(name)) return effect.GetFloat(name).ToString("G9", culture);
            if (effect.HasInt(name)) return effect.GetInt(name).ToString(culture);
            if (effect.HasUInt(name)) return effect.GetUInt(name).ToString(culture);
            if (effect.HasBool(name)) return effect.GetBool(name) ? "true" : "false";
            if (effect.HasVector2(name)) return effect.GetVector2(name).ToString("G9", culture);
            if (effect.HasVector3(name)) return effect.GetVector3(name).ToString("G9", culture);
            if (effect.HasVector4(name)) return effect.GetVector4(name).ToString("G9", culture);
            if (effect.HasAnimationCurve(name)) return JsonUtility.ToJson(Curve.Read(effect.GetAnimationCurve(name), 1));
            if (effect.HasGradient(name)) return JsonUtility.ToJson(Ramp.Read(effect.GetGradient(name)));
            return "";
        }

        private static void AddGraphApproximation(VisualEffect effect, Transform root, Request request, List<Layer> layers,
            List<VFXExposedProperty> properties)
        {
            Color tint = new Color(0.38f, 0.25f, 1, 1);
            var colorProperty = properties.FirstOrDefault(property => property.type == typeof(Vector4) &&
                (property.name.Contains("Color", StringComparison.OrdinalIgnoreCase) || property.name.Contains("Tint", StringComparison.OrdinalIgnoreCase)));
            if (colorProperty.name != null && effect.HasVector4(colorProperty.name))
                tint = effect.GetVector4(colorProperty.name);

            float Number(string parameter, float fallback) => effect.HasFloat(parameter) ? effect.GetFloat(parameter) : fallback;
            bool smokeGraph = effect.HasFloat("SmokeSize") && effect.HasFloat("SmokeLifetime");
            float seconds = request.capture.duration;
            var masks = smokeGraph ? new[] { "curl", "smoke" } : new[] { "star", "smoke", "spark", "ring" };
            foreach (string mask in masks)
            {
                var layer = BaseLayer(effect.transform, root);
                layer.name = "Graph " + mask;
                bool smoke = mask == "smoke" || mask == "curl";
                layer.phase = smoke ? "fade" : "impact";
                layer.duration = seconds;
                layer.lifetime = Curve.Constant(smoke ? Mathf.Max(0.02f, Number("SmokeLifetime", seconds * 0.75f)) : seconds * 0.35f);
                layer.size = Curve.Constant(smoke ? Mathf.Max(0.02f, Number("SmokeSize", 0.52f)) : mask == "ring" ? 1.1f : mask == "spark" ? 0.065f : 0.52f);
                layer.sizeOverLife = smoke || mask == "ring" ? Curve.Ramp(0.25f, 1.7f) : Curve.Ramp(1, 0.22f);
                if (smoke && effect.HasAnimationCurve("SizeOverLife"))
                    layer.sizeOverLife = Curve.Read(effect.GetAnimationCurve("SizeOverLife"), 1);
                layer.speed = Curve.Constant(smoke ? 0.5f : mask == "spark" ? 2.1f : 0);
                if (smoke && effect.HasVector3("SmokeVelocity"))
                {
                    Vector3 velocity = effect.GetVector3("SmokeVelocity");
                    layer.velocityX = Curve.Constant(velocity.x);
                    layer.velocityY = Curve.Constant(velocity.y);
                    layer.velocityZ = Curve.Constant(velocity.z);
                }
                layer.shape = new Shape { radius = Mathf.Max(0.001f, Number("Radius", 0.08f)) };
                layer.bursts = new[] { new Burst { count = Curve.Constant(smoke ? 7 : mask == "spark" ? 15 : 1) } };
                layer.texture.kind = mask;
                layer.blend = smoke ? "alpha" : "add";
                layer.tint = tint;
                layer.colorOverLife = FadingPalette();
                if (smoke && effect.HasGradient("SmokeGradient"))
                    layer.colorOverLife = new Palette { mode = "gradient", gradient = Ramp.Read(effect.GetGradient("SmokeGradient")) };
                layers.Add(layer);
            }
        }

        private static Palette FadingPalette() => new Palette
        {
            mode = "gradient",
            gradient = new Ramp
            {
                alpha = new[] { new AlphaStop { value = 1 }, new AlphaStop { time = 0.35f, value = 0.76f }, new AlphaStop { time = 1 } }
            }
        };
    }
}
