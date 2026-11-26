using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using Unity.Profiling;
using Unity.Profiling.LowLevel;
using Unity.Profiling.LowLevel.Unsafe;
using UnityEngine;
using UnityEngine.UI;

public sealed partial class UiEffectsPlayCheck
{
    private const int TargetFps = 60;
    private const int WarmupFrames = 120;
    private const int MeasuredFrames = 480;
    private const string CanvasMarker = "Canvas.BuildBatch";

    [Serializable]
    private sealed class ReviewReport
    {
        public int width;
        public int height;
        public Rect safeArea;
        public bool deviceSafeArea;
        public string[] captures;
    }

    [Serializable]
    private sealed class ProfileReport
    {
        public string model;
        public string os;
        public string graphicsApi;
        public int width;
        public int height;
        public int targetFps;
        public ProfilePair[] pairs;
    }

    [Serializable]
    private sealed class ProfilePair
    {
        public ProfileRun off;
        public ProfileRun on;
    }

    [Serializable]
    private sealed class ProfileRun
    {
        public Metric cpu;
        public Metric mainThread;
        public Metric renderThread;
        public Metric mainThreadPresentWait;
        public Metric gpu;
        public Metric canvas;
        public Metric frame;
        public double overBudgetPercent;
    }

    [Serializable]
    private sealed class Metric
    {
        public int samples;
        public double p95Ms;
    }

    private readonly List<Text> essentialLabels = new();
    private readonly Vector3[] corners = new Vector3[4];
    private GameObject screenOwner;
    private bool lightTheme;
    private bool profilingDevice;

    private void OnApplicationPause(bool paused)
    {
        if (paused) InterruptDeviceProfile();
    }

    private void OnApplicationFocus(bool focused)
    {
        if (!focused) InterruptDeviceProfile();
    }

    private void InterruptDeviceProfile()
    {
        if (!profilingDevice) return;
        profilingDevice = false;
        File.WriteAllText(Path.Combine(output, "failure.txt"),
            "Android interrupted profiling. Unlock the phone and keep the fixture in the foreground for a fresh run.");
        Application.Quit(1);
    }

    private IEnumerator ReviewMobile(bool android, bool motionFrames)
    {
        Application.targetFrameRate = TargetFps;
        yield return new WaitForSecondsRealtime(0.5f);
        var area = android ? Screen.safeArea : new Rect(12, 24, Screen.width - 24, Screen.height - 76);
        foreach (bool light in new[] { false, true })
        {
            SetUpScreen(light, area);
            yield return null;
            // Unity assigns graphic depth when it renders a newly created Canvas for the first time.
            yield return new WaitForEndOfFrame();
            foreach (bool reduced in new[] { false, true })
            {
                reducedMotion = reduced;
                CancelEffects();
                Click(confirmButton);
                Click(abilityButton);
                Click(revealButton);
                SamplePeak(reduced);
                VerifySafePlacement(area);
                yield return new WaitForEndOfFrame();
                SaveCapture($"{(light ? "light" : "dark")}-{(reduced ? "reduced" : "standard")}-peak.png");
            }
        }

        File.WriteAllText(Path.Combine(output, "review.json"), JsonUtility.ToJson(new ReviewReport
        {
            width = Screen.width, height = Screen.height, safeArea = area,
            deviceSafeArea = android, captures = captures.ToArray()
        }, true));
        if (motionFrames)
            yield return ReviewMotion(area);
        if (android)
            yield return ProfileDevice(area);
    }

    private void VerifySafePlacement(Rect area)
    {
        Canvas.ForceUpdateCanvases();
        foreach (var control in new[] { confirmButton, abilityButton, revealButton, skipButton })
            VerifyInside(control.GetComponent<RectTransform>(), area);
        VerifyInside(readyIcon.rectTransform, area);
        foreach (var label in essentialLabels)
        {
            VerifyInside(label.rectTransform, area);
            Require(label.preferredWidth <= label.rectTransform.rect.width + 0.5f &&
                label.preferredHeight <= label.rectTransform.rect.height + 0.5f,
                $"'{label.text}' does not fit its label at {Screen.width}x{Screen.height}.");
        }
        Require(readyLabel.text == "READY" && amount.text == "+250", "The persistent result must remain visible.");
    }

    private void VerifyInside(RectTransform rect, Rect area)
    {
        rect.GetWorldCorners(corners);
        foreach (Vector3 corner in corners)
        {
            Vector2 pixel = RectTransformUtility.WorldToScreenPoint(null, corner);
            Require(pixel.x >= area.xMin && pixel.x <= area.xMax && pixel.y >= area.yMin && pixel.y <= area.yMax,
                $"'{rect.name}' falls outside the safe area {area}.");
        }
    }

    private IEnumerator ReviewMotion(Rect area)
    {
        // Advance the same Animator clips by a fixed 1/60 s between captures, independent of PNG write time.
        Time.captureFramerate = TargetFps;
        foreach (bool reduced in new[] { false, true })
        {
            SetUpScreen(reduced, area);
            reducedMotion = reduced;
            yield return null;
            foreach (var instance in new[] { confirm, cooldown, reward }) instance.UseManualTiming();
            var mode = reduced ? "reduced" : "standard";
            var sequences = new[] { "confirm", "ready", "reward", "overlap" };
            var controls = new[] { confirmButton, abilityButton, revealButton };
            for (int sequence = 0; sequence < sequences.Length; sequence++)
            {
                CancelEffects();
                string folder = $"motion/{mode}/{sequences[sequence]}";
                Directory.CreateDirectory(Path.Combine(output, folder));
                for (int frame = 0; frame < 90; frame++)
                {
                    if (sequence == 3) TriggerBusyFrame(frame);
                    else if (frame == 6) controls[sequence].onClick.Invoke();
                    yield return new WaitForEndOfFrame();
                    SaveCapture($"{folder}/{frame:D3}.png", false);
                    yield return null;
                }
            }
        }
        Time.captureFramerate = 0;
    }

    private IEnumerator ProfileDevice(Rect area)
    {
        SetUpScreen(false, area);
        reducedMotion = false;
        yield return null;
        profilingDevice = true;
        var pairs = new ProfilePair[3];
        for (int index = 0; index < pairs.Length; index++)
        {
            var pair = pairs[index] = new ProfilePair();
            // Alternate order to reduce the effect of warming up or thermal drift.
            bool firstOn = index % 2 != 0;
            yield return ProfilePass(firstOn, result => { if (firstOn) pair.on = result; else pair.off = result; });
            yield return ProfilePass(!firstOn, result => { if (firstOn) pair.off = result; else pair.on = result; });
        }
        profilingDevice = false;
        var report = new ProfileReport
        {
            model = SystemInfo.deviceModel, os = SystemInfo.operatingSystem,
            graphicsApi = SystemInfo.graphicsDeviceType.ToString(), width = Screen.width, height = Screen.height,
            targetFps = TargetFps, pairs = pairs
        };
        File.WriteAllText(Path.Combine(output, "profile.json"), JsonUtility.ToJson(report, true));
    }

    private IEnumerator ProfilePass(bool enabled, Action<ProfileRun> save)
    {
        effectsEnabled = enabled;
        foreach (var instance in new[] { confirm, cooldown, reward })
        {
            instance.animator.gameObject.SetActive(enabled);
            if (enabled) instance.Cancel();
        }
        readyLabel.text = "CHARGING";
        amount.text = "—";
        for (int frame = 0; frame < WarmupFrames; frame++)
        {
            TriggerBusyFrame(frame);
            yield return null;
        }

        var cpu = new List<double>(MeasuredFrames);
        var mainThread = new List<double>(MeasuredFrames);
        var renderThread = new List<double>(MeasuredFrames);
        var mainThreadPresentWait = new List<double>(MeasuredFrames);
        var gpu = new List<double>(MeasuredFrames);
        var canvas = new List<double>(MeasuredFrames);
        var frameTimes = new List<double>(MeasuredFrames);
        var timing = new FrameTiming[1];
        ulong latestFrame = 0;
        int late = 0;
        using var batches = RecordCanvasBatches();
        int previousBatchCount = 0;
        for (int frame = 0; frame < MeasuredFrames; frame++)
        {
            TriggerBusyFrame(frame);
            FrameTimingManager.CaptureFrameTimings();
            yield return null;
            if (FrameTimingManager.GetLatestTimings(1, timing) > 0 && timing[0].frameStartTimestamp > latestFrame)
            {
                latestFrame = timing[0].frameStartTimestamp;
                double cpuWork = Math.Max(timing[0].cpuMainThreadFrameTime, timing[0].cpuRenderThreadFrameTime);
                if (cpuWork > 0) cpu.Add(cpuWork);
                if (timing[0].cpuMainThreadFrameTime > 0) mainThread.Add(timing[0].cpuMainThreadFrameTime);
                if (timing[0].cpuRenderThreadFrameTime > 0) renderThread.Add(timing[0].cpuRenderThreadFrameTime);
                mainThreadPresentWait.Add(timing[0].cpuMainThreadPresentWaitTime);
                if (timing[0].gpuFrameTime > 0) gpu.Add(timing[0].gpuFrameTime);
            }
            if (batches.Valid)
            {
                int batchCount = batches.Count;
                canvas.Add(batchCount > previousBatchCount ? batches.LastValue / 1_000_000.0 : 0);
                previousBatchCount = batchCount;
            }
            double elapsedMs = Time.unscaledDeltaTime * 1000.0;
            frameTimes.Add(elapsedMs);
            if (elapsedMs > 1000.0 / TargetFps) late++;
        }
        // Treat a marker that the player never emitted as unavailable.
        if (batches.Valid && batches.Count == 0) canvas.Clear();
        save(new ProfileRun
        {
            cpu = Summarize(cpu), gpu = Summarize(gpu), canvas = Summarize(canvas), frame = Summarize(frameTimes),
            mainThread = Summarize(mainThread), renderThread = Summarize(renderThread),
            mainThreadPresentWait = Summarize(mainThreadPresentWait),
            overBudgetPercent = late * 100.0 / MeasuredFrames
        });
    }

    private static ProfilerRecorder RecordCanvasBatches()
    {
        var handles = new List<ProfilerRecorderHandle>();
        ProfilerRecorderHandle.GetAvailable(handles);
        foreach (var handle in handles)
        {
            var description = ProfilerRecorderHandle.GetDescription(handle);
            if (description.Name == CanvasMarker && description.UnitType == ProfilerMarkerDataUnit.TimeNanoseconds)
                return ProfilerRecorder.StartNew(description.Category, CanvasMarker, MeasuredFrames + 1,
                    ProfilerRecorderOptions.SumAllSamplesInFrame);
        }
        return default;
    }

    private static Metric Summarize(List<double> values)
    {
        values.Sort();
        return new Metric { samples = values.Count, p95Ms = values.Count == 0 ? 0 : values[(int)Math.Ceiling(values.Count * 0.95) - 1] };
    }

    private void TriggerBusyFrame(int frame)
    {
        if (frame % 120 == 119)
        {
            readyLabel.text = "CHARGING";
            amount.text = "—";
        }
        if (frame % 8 == 0) confirmButton.onClick.Invoke();
        if (frame % 12 == 0) abilityButton.onClick.Invoke();
        if (frame % 18 == 0) revealButton.onClick.Invoke();
    }

    private void CancelEffects()
    {
        confirm.Cancel();
        cooldown.Cancel();
        reward.Cancel();
    }
}
