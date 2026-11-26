using System;
using System.Collections.Generic;
using UnityEngine;

namespace VfxCreator.Editor
{
    [Serializable]
    internal sealed class Recipe
    {
        public int version = 1;
        public string id;
        public string title;
        public string description;
        public string[] tags = Array.Empty<string>();
        public string[] notes = Array.Empty<string>();
        public float duration = 1;
        public int seed = 1729;
        public bool randomizeOnPlay;
        public Layer[] layers = Array.Empty<Layer>();
    }

    [Serializable]
    internal sealed class Layer
    {
        public string name;
        public string phase = "body";
        public string kind = "particles";
        public string[] enabledModules;
        public Vector3 position;
        public Vector3 euler;
        public Vector3 scale = Vector3.one;
        public float duration = 1;
        public bool loop;
        public bool prewarm;
        public bool worldSpace;
        public bool playOnAwake = true;
        public int maxParticles = 512;
        public Curve delay = Curve.Constant(0);
        public Curve lifetime = Curve.Constant(0.35f);
        public Curve speed = Curve.Constant(0);
        public Curve size = Curve.Constant(0.25f);
        public Curve rotation = Curve.Constant(0);
        public AxisCurves rotation3D;
        public Curve gravity = Curve.Constant(0);
        public Curve rate = Curve.Constant(0);
        public Curve distanceRate = Curve.Constant(0);
        public Burst[] bursts = Array.Empty<Burst>();
        public Shape shape;
        public Palette startColor = Palette.Constant(Color.white);
        public Palette colorOverLife;
        public Curve sizeOverLife;
        public Curve spinOverLife;
        public AxisCurves spinOverLife3D;
        public Curve velocityX;
        public Curve velocityY;
        public Curve velocityZ;
        public bool velocityWorldSpace;
        public float noise;
        public float noiseFrequency = 0.7f;
        public string render = "Billboard";
        public string alignment = "View";
        public float lengthScale = 1;
        public float velocityScale;
        public float sortBias;
        public float maxScreenSize;
        public TextureRecipe texture = new TextureRecipe();
        public string blend = "add";
        public Color tint = Color.white;
        public float glow = 1;
        public float softness;
        public Trail trail;
        public SubEmitter[] subEmitters = Array.Empty<SubEmitter>();

        public bool Uses(string module) => enabledModules != null && Array.IndexOf(enabledModules, module) >= 0;

        public void RecordActiveModules()
        {
            var enabled = new List<string>();
            if (shape != null) enabled.Add(nameof(shape));
            if (colorOverLife != null) enabled.Add(nameof(colorOverLife));
            if (sizeOverLife != null) enabled.Add(nameof(sizeOverLife));
            if (rotation3D != null) enabled.Add(nameof(rotation3D));
            if (spinOverLife != null) enabled.Add(nameof(spinOverLife));
            if (spinOverLife3D != null) enabled.Add(nameof(spinOverLife3D));
            if (velocityX != null) enabled.Add(nameof(velocityX));
            if (velocityY != null) enabled.Add(nameof(velocityY));
            if (velocityZ != null) enabled.Add(nameof(velocityZ));
            if (trail != null) enabled.Add(nameof(trail));
            enabledModules = enabled.ToArray();
        }
    }

    [Serializable]
    internal sealed class AxisCurves
    {
        public Curve x;
        public Curve y;
        public Curve z;

        internal static AxisCurves Read(ParticleSystem.MinMaxCurve x, ParticleSystem.MinMaxCurve y, ParticleSystem.MinMaxCurve z)
            => new AxisCurves { x = Curve.Read(x), y = Curve.Read(y), z = Curve.Read(z) };
    }

    [Serializable]
    internal sealed class Burst
    {
        public float time;
        public Curve count = Curve.Constant(1);
        public int cycles = 1;
        public float interval = 0.01f;
        public float probability = 1;
    }

    [Serializable]
    internal sealed class Shape
    {
        public string type = "Sphere";
        public float radius = 0.12f;
        public float thickness = 1;
        public float angle = 20;
        public float arc = 360;
        public float length = 1;
        public Vector3 position;
        public Vector3 euler;
        public Vector3 scale = Vector3.one;
        public float randomDirection;
        public float sphericalDirection;
    }

    [Serializable]
    internal sealed class TextureRecipe
    {
        public string kind = "glow";
        public string png;
        public int resolution = 128;
        public int tilesX = 1;
        public int tilesY = 1;
        public float falloff = 2;
        public float detail = 0.4f;
        public int spokes = 6;
        public Curve frameOverLife;
        public bool animateFrameCurve;
    }

    [Serializable]
    internal sealed class Trail
    {
        public float time = 0.22f;
        public float ratio = 1;
        public float minDistance = 0.04f;
        public bool worldSpace;
        public bool dieWithParticles = true;
        public bool inheritParticleColor = true;
        public bool ribbon;
        public int ribbons = 1;
        public int corners = 4;
        public int caps = 3;
        public Curve width = Curve.Ramp(1, 0);
        public Palette color;
        public Palette colorOverLife;
    }

    [Serializable]
    internal sealed class SubEmitter
    {
        public int layer;
        public string trigger;
        public string inherit;
        public float chance = 1;
    }

    [Serializable]
    internal sealed class Curve
    {
        public string mode = "constant";
        public float min;
        public float max;
        public float multiplier = 1;
        public Key[] minKeys;
        public Key[] keys;

        public static Curve Constant(float value) => new Curve { min = value, max = value };
        public static Curve Ramp(float from, float to) => new Curve
        {
            mode = "curve",
            keys = new[] { new Key { value = from }, new Key { time = 1, value = to } }
        };

        public static Curve Read(ParticleSystem.MinMaxCurve curve)
        {
            return new Curve
            {
                mode = curve.mode.ToString(),
                min = curve.constantMin,
                max = curve.constantMax,
                multiplier = curve.curveMultiplier,
                minKeys = curve.mode == ParticleSystemCurveMode.TwoCurves ? ReadKeys(curve.curveMin) : null,
                keys = curve.mode == ParticleSystemCurveMode.Curve || curve.mode == ParticleSystemCurveMode.TwoCurves
                    ? ReadKeys(curve.curveMax) : null
            };
        }

        public static Curve Read(AnimationCurve curve, float multiplier)
        {
            return new Curve { mode = "curve", keys = ReadKeys(curve), multiplier = multiplier };
        }

        private static Key[] ReadKeys(AnimationCurve curve)
        {
            if (curve == null) return Array.Empty<Key>();
            return Array.ConvertAll(curve.keys, key => new Key
            {
                time = key.time,
                value = key.value,
                tangentIn = float.IsInfinity(key.inTangent) ? 0 : key.inTangent,
                tangentOut = float.IsInfinity(key.outTangent) ? 0 : key.outTangent,
                stepIn = float.IsPositiveInfinity(key.inTangent),
                stepOut = float.IsPositiveInfinity(key.outTangent),
                weightIn = key.inWeight,
                weightOut = key.outWeight,
                weighted = (int)key.weightedMode
            });
        }

        private static AnimationCurve ToAnimation(Key[] source)
        {
            if (source == null || source.Length == 0) return AnimationCurve.Linear(0, 1, 1, 1);
            var frames = Array.ConvertAll(source, key => new Keyframe(key.time, key.value,
                key.stepIn ? float.PositiveInfinity : key.tangentIn, key.stepOut ? float.PositiveInfinity : key.tangentOut,
                key.weightIn, key.weightOut) { weightedMode = (WeightedMode)key.weighted });
            return new AnimationCurve(frames);
        }

        public AnimationCurve Animation()
        {
            return string.Equals(mode, "constant", StringComparison.OrdinalIgnoreCase)
                ? AnimationCurve.Linear(0, max, 1, max) : ToAnimation(keys);
        }

        public ParticleSystem.MinMaxCurve Unity()
        {
            switch ((mode ?? "").ToLowerInvariant())
            {
                case "twoconstants": return new ParticleSystem.MinMaxCurve(min, max);
                case "curve": return new ParticleSystem.MinMaxCurve(multiplier, ToAnimation(keys));
                case "twocurves": return new ParticleSystem.MinMaxCurve(multiplier, ToAnimation(minKeys), ToAnimation(keys));
                default: return new ParticleSystem.MinMaxCurve(max);
            }
        }
    }

    [Serializable]
    internal sealed class Key
    {
        public float time;
        public float value;
        public float tangentIn;
        public float tangentOut;
        public bool stepIn;
        public bool stepOut;
        public float weightIn;
        public float weightOut;
        public int weighted;
    }

    [Serializable]
    internal sealed class Palette
    {
        public string mode = "color";
        public Color min = Color.white;
        public Color max = Color.white;
        public Ramp gradient;
        public Ramp gradientMin;

        public static Palette Constant(Color color) => new Palette { min = color, max = color };

        public static Palette Read(ParticleSystem.MinMaxGradient color)
        {
            return new Palette
            {
                mode = color.mode.ToString(), min = color.colorMin, max = color.colorMax,
                gradient = Ramp.Read(color.gradientMax), gradientMin = Ramp.Read(color.gradientMin)
            };
        }

        public Gradient Gradient()
        {
            if (gradient?.alpha?.Length > 0 || gradient?.colors?.Length > 0) return gradient.Unity();
            return new Gradient
            {
                colorKeys = new[] { new GradientColorKey(max, 0), new GradientColorKey(max, 1) },
                alphaKeys = new[] { new GradientAlphaKey(max.a, 0), new GradientAlphaKey(max.a, 1) }
            };
        }

        public ParticleSystem.MinMaxGradient Unity()
        {
            switch ((mode ?? "").ToLowerInvariant())
            {
                case "twocolors": return new ParticleSystem.MinMaxGradient(min, max);
                case "gradient": return new ParticleSystem.MinMaxGradient(Gradient());
                case "twogradients": return new ParticleSystem.MinMaxGradient(gradientMin?.Unity() ?? Gradient(), Gradient());
                case "randomcolor": return new ParticleSystem.MinMaxGradient(Gradient()) { mode = ParticleSystemGradientMode.RandomColor };
                default: return new ParticleSystem.MinMaxGradient(max);
            }
        }
    }

    [Serializable]
    internal sealed class Ramp
    {
        public string mode;
        public ColorStop[] colors;
        public AlphaStop[] alpha;

        public static Ramp Read(Gradient gradient)
        {
            if (gradient == null) return null;
            return new Ramp
            {
                mode = gradient.mode.ToString(),
                colors = Array.ConvertAll(gradient.colorKeys, key => new ColorStop { time = key.time, value = key.color }),
                alpha = Array.ConvertAll(gradient.alphaKeys, key => new AlphaStop { time = key.time, value = key.alpha })
            };
        }

        public Gradient Unity()
        {
            var gradient = new Gradient();
            if (Enum.TryParse(mode, true, out GradientMode gradientMode)) gradient.mode = gradientMode;
            if (colors?.Length > 0) gradient.colorKeys = Array.ConvertAll(colors, key => new GradientColorKey(key.value, key.time));
            else gradient.colorKeys = new[] { new GradientColorKey(Color.white, 0), new GradientColorKey(Color.white, 1) };
            if (alpha?.Length > 0) gradient.alphaKeys = Array.ConvertAll(alpha, key => new GradientAlphaKey(key.value, key.time));
            return gradient;
        }
    }

    [Serializable]
    internal sealed class ColorStop
    {
        public float time;
        public Color value;
    }

    [Serializable]
    internal sealed class AlphaStop
    {
        public float time;
        public float value;
    }
}
