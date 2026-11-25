using System;
using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;
using Object = UnityEngine.Object;

namespace VfxCreator.Editor
{
    [Serializable]
    internal sealed class Limits
    {
        public float minForegroundIoU;
        public float maxMeanColorError = 1;
        public int maxOnsetFrameDelta = int.MaxValue;
        public int maxPeakFrameDelta = int.MaxValue;
        public int maxEndFrameDelta = int.MaxValue;
    }

    [Serializable]
    internal sealed class Comparison
    {
        public int frames;
        public int fps;
        public long changedPixels;
        public long totalPixels;
        public float foregroundIoU;
        public float meanColorError;
        public int referenceOnset = -1;
        public int referencePeak = -1;
        public int referenceEnd = -1;
        public int candidateOnset = -1;
        public int candidatePeak = -1;
        public int candidateEnd = -1;
        public bool hasLimits;
        public bool passedLimits;
        public FrameForeground[] timeline;
    }

    [Serializable]
    internal struct FrameForeground
    {
        public ForegroundBounds reference;
        public ForegroundBounds candidate;
    }

    [Serializable]
    internal struct ForegroundBounds
    {
        public int area;
        public int xMin;
        public int yMin;
        public int xMax;
        public int yMax;

        public void Include(int x, int y)
        {
            if (area++ == 0)
            {
                xMin = xMax = x;
                yMin = yMax = y;
                return;
            }
            xMin = Math.Min(xMin, x);
            yMin = Math.Min(yMin, y);
            xMax = Math.Max(xMax, x);
            yMax = Math.Max(yMax, y);
        }
    }

    internal static class Compare
    {
        internal static Comparison Captures(Request request)
        {
            var reference = LoadCapture(request.reference);
            var candidate = LoadCapture(request.candidate);
            if (JsonUtility.ToJson(reference.settings) != JsonUtility.ToJson(candidate.settings) || reference.frames != candidate.frames)
                throw new ArgumentException("Use the same camera, motion, duration, size, FPS and seed for both captures.");
            int size = reference.settings.size;
            var overview = new Comparison
            {
                frames = reference.frames, fps = reference.settings.fps,
                totalPixels = (long)reference.frames * size * size,
                timeline = new FrameForeground[reference.frames]
            };
            Directory.CreateDirectory(request.output);
            var first = new Texture2D(size, size, TextureFormat.RGB24, false);
            var second = new Texture2D(size, size, TextureFormat.RGB24, false);
            var strip = new Texture2D(size * 3, size, TextureFormat.RGB24, false);
            var pixels = new Color32[size * size * 3];
            long intersection = 0, union = 0, colorError = 0;
            int peakRef = 0, peakNew = 0;
            try
            {
                for (int frame = 0; frame < reference.frames; frame++)
                {
                    string file = Render.FrameName(frame);
                    var original = LoadFrame(first, Path.Combine(request.reference, file), size);
                    var rebuilt = LoadFrame(second, Path.Combine(request.candidate, file), size);
                    ref var foreground = ref overview.timeline[frame];
                    for (int row = 0; row < size; row++)
                    {
                        int start = row * size;
                        int stripStart = row * size * 3;
                        for (int column = 0; column < size; column++)
                        {
                            var a = original[start + column];
                            var b = rebuilt[start + column];
                            bool visibleA = Render.IsForeground(a, reference.background);
                            bool visibleB = Render.IsForeground(b, candidate.background);
                            if (visibleA) foreground.reference.Include(column, size - 1 - row);
                            if (visibleB) foreground.candidate.Include(column, size - 1 - row);
                            if (visibleA && visibleB) intersection++;
                            int dr = Math.Abs(a.r - b.r), dg = Math.Abs(a.g - b.g), db = Math.Abs(a.b - b.b);
                            if (dr + dg + db > 0) overview.changedPixels++;
                            if (visibleA || visibleB)
                            {
                                colorError += dr + dg + db;
                                union++;
                            }
                            pixels[stripStart + column] = a;
                            pixels[stripStart + column + size] = b;
                            pixels[stripStart + column + size * 2] = new Color32((byte)dr, (byte)dg, (byte)db, 255);
                        }
                    }
                    UpdateTiming(frame, foreground.reference.area, ref overview.referenceOnset, ref overview.referencePeak, ref overview.referenceEnd, ref peakRef);
                    UpdateTiming(frame, foreground.candidate.area, ref overview.candidateOnset, ref overview.candidatePeak, ref overview.candidateEnd, ref peakNew);
                    strip.SetPixels32(pixels);
                    strip.Apply();
                    File.WriteAllBytes(Path.Combine(request.output, file), strip.EncodeToPNG());
                }
            }
            finally
            {
                Object.DestroyImmediate(first);
                Object.DestroyImmediate(second);
                Object.DestroyImmediate(strip);
            }

            overview.foregroundIoU = union == 0 ? 0 : (float)(intersection / (double)union);
            overview.meanColorError = union == 0 ? 0 : (float)(colorError / (765.0 * union));
            if (!string.IsNullOrEmpty(request.limits))
            {
                var limits = JsonUtility.FromJson<Limits>(File.ReadAllText(request.limits));
                overview.hasLimits = true;
                overview.passedLimits = peakRef > 0 && peakNew > 0 &&
                    overview.foregroundIoU >= limits.minForegroundIoU && overview.meanColorError <= limits.maxMeanColorError &&
                    Math.Abs(overview.referenceOnset - overview.candidateOnset) <= limits.maxOnsetFrameDelta &&
                    Math.Abs(overview.referencePeak - overview.candidatePeak) <= limits.maxPeakFrameDelta &&
                    Math.Abs(overview.referenceEnd - overview.candidateEnd) <= limits.maxEndFrameDelta;
            }
            Pipeline.WriteJson(Path.Combine(request.output, "comparison.json"), overview);
            File.WriteAllText(Path.Combine(request.output, "index.html"), Html(overview), new UTF8Encoding(false));
            return overview;
        }

        private static CaptureManifest LoadCapture(string path) =>
            JsonUtility.FromJson<CaptureManifest>(File.ReadAllText(Path.Combine(path, "capture.json")));

        private static Color32[] LoadFrame(Texture2D texture, string path, int size)
        {
            if (!texture.LoadImage(File.ReadAllBytes(path)) || texture.width != size || texture.height != size)
                throw new InvalidDataException("Invalid frame " + path);
            return texture.GetPixels32();
        }

        private static void UpdateTiming(int frame, int area, ref int onset, ref int peak, ref int end, ref int peakArea)
        {
            if (area == 0) return;
            if (onset < 0) onset = frame;
            end = frame;
            if (area <= peakArea) return;
            peak = frame;
            peakArea = area;
        }

        private static string Html(Comparison data)
        {
            int peak = Math.Max(0, data.referencePeak);
            string status = !data.hasLimits ? "Awaiting visual approval" : data.passedLimits ? "Within approved limits" : "Exceeded approved limits";
            string iou = data.foregroundIoU.ToString("P1", CultureInfo.InvariantCulture);
            string color = data.meanColorError.ToString("P1", CultureInfo.InvariantCulture);
            return @"<!doctype html>
<html lang=""en""><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1"">
<title>VFX Creator comparison</title>
<style>
body{margin:2rem auto;max-width:1200px;padding:0 1rem;background:#141722;color:#ebeef6;font:16px system-ui}
header{display:flex;gap:1rem;align-items:baseline;flex-wrap:wrap} h1{font-size:1.5rem;margin:0}
img{width:100%;display:block;background:#0b0c11} .labels{display:grid;grid-template-columns:repeat(3,1fr);text-align:center;margin:.7rem 0}
button,input{accent-color:#76c9ff} #frame{width:min(75%,850px)} p{line-height:1.5}
canvas{display:block;width:100%;height:105px;background:#0b0c11;cursor:pointer} .reference{color:#72dcf1} .candidate{color:#ffaf79}
</style>
<header><h1>VFX comparison</h1><span>" + status + @"</span></header>
<p>Foreground overlap " + iou + @" · Color error " + color + @" · Changed pixels " + data.changedPixels + " / " + data.totalPixels + @"<br>
Onset / peak / end frames — reference " + data.referenceOnset + " / " + data.referencePeak + " / " + data.referenceEnd +
                ", candidate " + data.candidateOnset + " / " + data.candidatePeak + " / " + data.candidateEnd + @"</p>
<div class=""labels""><span>Reference / draft</span><span>Candidate</span><span>Pixel difference</span></div>
<img alt=""Reference, candidate and absolute pixel differences"" id=""preview"" src=""" + Render.FrameName(peak) + @""">
<p><button id=""play"">Play</button> <input type=""range"" aria-label=""Frame"" id=""frame"" min=""0"" max=""" + (data.frames - 1) +
                @""" value=""" + peak + @"""> <output id=""time""></output></p>
<p>Foreground area in pixels · <span class=""reference"">Reference</span> · <span class=""candidate"">Candidate</span></p>
<canvas id=""area"" width=""1000"" height=""105"" aria-label=""Foreground area by frame""></canvas>
<p id=""bounds""></p>
<script>
const slider = document.querySelector('#frame'), image = document.querySelector('#preview');
const time = document.querySelector('#time'), button = document.querySelector('#play');
const chart = document.querySelector('#area'), plot = chart.getContext('2d'), bounds = document.querySelector('#bounds');
const timeline = " + JsonUtility.ToJson(data) + @".timeline;
const largest = Math.max(1, ...timeline.map(({reference, candidate}) => Math.max(reference.area, candidate.area)));
const fps = " + data.fps + @"; let timer;
const x = frame => frame * (chart.width - 1) / Math.max(1, timeline.length - 1);
function draw(frame) {
  plot.clearRect(0, 0, chart.width, chart.height);
  for (const [key, color] of [['reference', '#72dcf1'], ['candidate', '#ffaf79']]) {
    plot.beginPath();
    timeline.forEach((entry, i) => {
      const y = chart.height - 1 - entry[key].area * (chart.height - 6) / largest;
      if (i === 0) plot.moveTo(x(i), y); else plot.lineTo(x(i), y);
    });
    plot.strokeStyle = color;
    plot.lineWidth = 2;
    plot.stroke();
  }
  plot.beginPath();
  plot.moveTo(x(frame), 0);
  plot.lineTo(x(frame), chart.height);
  plot.strokeStyle = '#ebeef6';
  plot.lineWidth = 1;
  plot.stroke();
}
function describe(box) {
  if (!box.area) return 'no visible pixels';
  return box.area + ' px · bounds (' + box.xMin + ', ' + box.yMin + ')–(' + box.xMax + ', ' + box.yMax + ')';
}
function update() {
  const frame = Number(slider.value);
  image.src = 'frame-' + slider.value.padStart(4, '0') + '.png';
  time.value = (frame / fps).toFixed(2) + ' s';
  const entry = timeline[frame];
  bounds.textContent = 'Reference: ' + describe(entry.reference) + ' | Candidate: ' + describe(entry.candidate);
  draw(frame);
}
chart.addEventListener('click', event => {
  const rect = chart.getBoundingClientRect();
  slider.value = Math.round((event.clientX - rect.left) / rect.width * (timeline.length - 1));
  update();
});
slider.addEventListener('input', update);
button.addEventListener('click', () => {
  if (timer) { clearInterval(timer); timer = null; button.textContent = 'Play'; return; }
  button.textContent = 'Pause';
  timer = setInterval(() => { slider.value = (Number(slider.value) + 1) % (Number(slider.max) + 1); update(); }, 1000 / fps);
});
update();
</script></html>";
        }
    }
}
