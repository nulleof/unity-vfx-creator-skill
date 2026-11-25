using System;
using UnityEngine;

namespace VfxCreator.Editor
{
    internal static class Masks
    {
        internal static byte[] Generate(TextureRecipe recipe, int seed)
        {
            int tile = Mathf.Clamp(recipe.resolution, 16, 512);
            int columns = Mathf.Clamp(recipe.tilesX, 1, 16);
            int rows = Mathf.Clamp(recipe.tilesY, 1, 16);
            if (Mathf.Max(columns, rows) * tile > 2048) tile = 2048 / Mathf.Max(columns, rows);
            int width = tile * columns, height = tile * rows;
            var pixels = new Color32[width * height];
            var random = new System.Random(seed);
            float offset = (float)random.NextDouble() * 70;
            for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                float u = 2 * (x % tile + 0.5f) / tile - 1;
                float v = 2 * (y % tile + 0.5f) / tile - 1;
                float frame = ((rows - 1 - y / tile) * columns + x / tile) / (float)Mathf.Max(1, columns * rows - 1);
                float mask = Sample(recipe, u, v, frame, offset);
                pixels[y * width + x] = new Color32(255, 255, 255, (byte)Mathf.RoundToInt(255 * Mathf.Clamp01(mask)));
            }
            var texture = new Texture2D(width, height, TextureFormat.RGBA32, false);
            try
            {
                texture.SetPixels32(pixels);
                texture.Apply();
                return texture.EncodeToPNG();
            }
            finally { UnityEngine.Object.DestroyImmediate(texture); }
        }

        private static float Sample(TextureRecipe recipe, float u, float v, float frame, float offset)
        {
            float radius = Mathf.Sqrt(u * u + v * v);
            float angle = Mathf.Atan2(v, u);
            float detail = Mathf.Clamp01(recipe.detail);
            float softEdge = 1 - Mathf.SmoothStep(0, 1, Mathf.InverseLerp(0.74f, 1, radius));
            float noise = Fbm(u * 2.7f + offset + frame * 0.66f, v * 2.7f + offset - frame * 0.7f);
            float falloff = Mathf.Max(0.2f, recipe.falloff);
            switch (recipe.kind)
            {
                case "smoke":
                    float warped = Mathf.Clamp01(1 - radius + (noise - 0.5f) * 1.25f * detail);
                    return Mathf.Pow(warped, falloff * 0.63f) * softEdge * (0.4f + 0.7f * noise);
                case "curl":
                    float curl = Mathf.Sin(angle * 1.8f - radius * 13 + noise * 2.9f + frame * 1.8f);
                    float contour = Mathf.InverseLerp(0.71f, 0.10f, radius + (noise - 0.5f) * 0.55f);
                    return Mathf.SmoothStep(0, 1, contour) * Mathf.SmoothStep(0, 1, (curl + 0.62f) * 1.15f);
                case "crescent":
                    float facing = (u + v) * 0.7071f;
                    float cross = (v - u) * 0.7071f;
                    float outer = 0.86f - Mathf.Sqrt(facing * facing * 1.0f + cross * cross * 0.82f);
                    float tooth = Mathf.Cos(Mathf.Atan2(cross, facing) * 13) * detail * 0.10f;
                    float inside = Mathf.Sqrt((facing - 0.41f) * (facing - 0.41f) + cross * cross * 1.17f);
                    return Mathf.SmoothStep(0, 1, outer * (9 + falloff * 3)) *
                        Mathf.SmoothStep(0, 1, (inside - 0.59f + tooth) * 14);
                case "ring":
                    float band = Mathf.Abs(radius - (0.67f + detail * (noise - 0.5f) * 0.22f + frame * 0.1f));
                    return Mathf.Exp(-band * band * 140) * (0.72f + 0.28f * Mathf.Cos(angle * 4 + offset));
                case "star":
                    float rays = Mathf.Pow(0.5f + 0.5f * Mathf.Cos(angle * Mathf.Clamp(recipe.spokes, 2, 16) + radius * detail), 12);
                    float core = Mathf.Exp(-radius * radius * 28 * falloff);
                    return (core + 0.86f * rays * Mathf.Pow(Mathf.Clamp01(1 - radius), 1.35f)) * softEdge;
                case "wirestar":
                    return WireStar(new Vector2(u, v), detail, falloff);
                case "spark":
                    return Mathf.Exp(-u * u * (24 + falloff * 14)) * Mathf.Pow(Mathf.Clamp01(1 - Mathf.Abs(v)), 1.4f);
                case "streak":
                    return Mathf.Exp(-v * v * falloff * 3) * Mathf.SmoothStep(0, 1, Mathf.Clamp01(5 * (1 - Mathf.Abs(u)))) *
                        Mathf.Clamp01(0.65f + noise * detail);
                case "flame":
                    float height = (v + 1) * 0.5f;
                    float envelope = Mathf.Max(0.03f, Mathf.Sin(height * Mathf.PI) * (0.72f - 0.43f * height));
                    float lean = Mathf.Sin(height * 3 + frame * 4 + offset) * detail * height * 0.34f;
                    return Mathf.Clamp01(1 - Mathf.Abs(u - lean) / envelope) * Mathf.Sin(height * Mathf.PI) * (0.5f + noise * 0.75f);
                case "bubble":
                    return (Mathf.Exp(-Mathf.Pow((radius - 0.72f) * 17, 2)) * (0.22f + 0.75f * Mathf.Clamp01(v + 0.4f)) +
                        Mathf.Exp(-((u + 0.26f) * (u + 0.26f) + (v - 0.38f) * (v - 0.38f)) * 110)) * softEdge;
                default:
                    return Mathf.Pow(Mathf.Clamp01(1 - radius * radius), falloff * 2.6f) * softEdge;
            }
        }

        private static float WireStar(Vector2 point, float detail, float falloff)
        {
            float silhouette = 2, crossing = 2;
            for (int spoke = 0; spoke < 5; spoke++)
            {
                float angle = Mathf.PI * (0.5f + 0.4f * spoke);
                var tip = Direction(angle) * 0.87f;
                var inner = Direction(angle + Mathf.PI / 5) * 0.31f;
                var next = Direction(angle + 2 * Mathf.PI / 5) * 0.87f;
                silhouette = Mathf.Min(silhouette, Mathf.Min(SegmentDistance(point, tip, inner), SegmentDistance(point, inner, next)));
                crossing = Mathf.Min(crossing, SegmentDistance(point, tip, Direction(angle + 4 * Mathf.PI / 5) * 0.87f));
            }
            float sharpness = 65 + falloff * 14;
            return Mathf.Exp(-silhouette * sharpness) + detail * 0.72f * Mathf.Exp(-crossing * sharpness);
        }

        private static Vector2 Direction(float angle) => new Vector2(Mathf.Cos(angle), Mathf.Sin(angle));

        private static float SegmentDistance(Vector2 point, Vector2 first, Vector2 second)
        {
            var edge = second - first;
            return Vector2.Distance(point, first + edge * Mathf.Clamp01(Vector2.Dot(point - first, edge) / edge.sqrMagnitude));
        }

        private static float Fbm(float x, float y)
        {
            return Mathf.PerlinNoise(x, y) * 0.58f + Mathf.PerlinNoise(x * 2.08f + 4, y * 2.08f) * 0.29f +
                Mathf.PerlinNoise(x * 4.23f, y * 4.23f + 9) * 0.13f;
        }
    }
}
