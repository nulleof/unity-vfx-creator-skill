using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

public sealed partial class UiEffectsPlayCheck : MonoBehaviour
{
    [Serializable]
    public sealed class Effect
    {
        public string prefab;
        public Placement placement;
        public string idleState;
        public string standardState;
        public string reducedState;
        public float standardDurationSec;
        public float reducedDurationSec;
        public GameObject asset;
    }

    [Serializable]
    public sealed class Placement
    {
        public string order;
        public string clipping;
        public string retrigger;
    }

    [Serializable]
    private sealed class Report
    {
        public bool passed;
        public int confirmedClicks;
        public int width;
        public int height;
        public string[] captures;
    }

    private sealed class Instance
    {
        public Effect effect;
        public Animator animator;
        public CanvasGroup[] layers;
        private int startedFrame = -1;
        public bool Idle => animator.GetCurrentAnimatorStateInfo(0).IsName(effect.idleState);
        public bool Visible => layers.Any(layer => layer.alpha > 0.001f);

        public void Play(bool reduced)
        {
            if (effect.placement.retrigger == "ignoreWhilePlaying" && (!Idle || startedFrame == Time.frameCount)) return;
            animator.Play(reduced ? effect.reducedState : effect.standardState, 0, 0);
            startedFrame = Time.frameCount;
        }

        public void Cancel()
        {
            startedFrame = -1;
            animator.speed = 1;
            SetState(effect.idleState);
        }

        public void Sample(bool reduced, float seconds)
        {
            animator.speed = 0;
            float duration = reduced ? effect.reducedDurationSec : effect.standardDurationSec;
            SetState(reduced ? effect.reducedState : effect.standardState, seconds / duration);
        }

        public void UseManualTiming()
        {
            animator.updateMode = AnimatorUpdateMode.Normal;
        }

        private void SetState(string state, float normalizedTime = 0)
        {
            animator.Play(state, 0, normalizedTime);
            animator.Update(0);
        }
    }

    public Effect[] effects;
    private readonly List<string> captures = new();
    private GameObject screen;
    private Button confirmButton;
    private Button abilityButton;
    private Button revealButton;
    private Button skipButton;
    private Text readyLabel;
    private Text amount;
    private Text confirmLabel;
    private Image readyIcon;
    private Instance confirm;
    private Instance cooldown;
    private Instance reward;
    private Font font;
    private string output;
    private int confirmedClicks;
    private bool reducedMotion;
    private bool effectsEnabled = true;

    private IEnumerator Start()
    {
        Application.runInBackground = true;
        Application.targetFrameRate = 60;
        string[] args = Environment.GetCommandLineArgs();
        bool android = Application.platform == RuntimePlatform.Android;
        if (android) Screen.sleepTimeout = SleepTimeout.NeverSleep;
        output = android ? Path.Combine(Application.persistentDataPath, "ui-review") : args[Array.IndexOf(args, "-vfxUiReviewOutput") + 1];
        Directory.CreateDirectory(output);
        bool review = android || args.Contains("-vfxUiMobileReview");
        var steps = new Stack<IEnumerator>();
        steps.Push(review ? ReviewMobile(android, args.Contains("-vfxUiMotionFrames")) : Verify());
        while (steps.Count > 0)
        {
            object delay;
            try
            {
                var check = steps.Peek();
                if (!check.MoveNext())
                {
                    steps.Pop();
                    continue;
                }
                delay = check.Current;
            }
            catch (Exception error)
            {
                foreach (var step in steps) (step as IDisposable)?.Dispose();
                Debug.LogException(error);
                File.WriteAllText(Path.Combine(output, "failure.txt"), error.ToString());
                Application.Quit(1);
                yield break;
            }
            if (delay is IEnumerator nested && delay is not CustomYieldInstruction)
            {
                steps.Push(nested);
                continue;
            }
            yield return delay;
        }

        var report = new Report
        {
            passed = true, confirmedClicks = confirmedClicks, width = Screen.width,
            height = Screen.height, captures = captures.ToArray()
        };
        string completion = Path.Combine(output, "playback.json");
        File.WriteAllText(completion + ".tmp", JsonUtility.ToJson(report, true));
        File.Move(completion + ".tmp", completion);
        Application.Quit(0);
    }

    private IEnumerator Verify()
    {
        SetUpScreen();
        yield return null;
        AssertIdle(confirm, cooldown, reward);
        Canvas.ForceUpdateCanvases();
        Require(confirm.layers[0].GetComponent<Image>().canvasRenderer.absoluteDepth > confirmLabel.canvasRenderer.absoluteDepth,
            "Confirmation must layer above the button label.");
        Require(cooldown.layers[0].GetComponent<Image>().canvasRenderer.absoluteDepth < readyIcon.canvasRenderer.absoluteDepth,
            "Cooldown contour must layer below the icon.");
        Require(reward.layers[0].GetComponent<Image>().canvasRenderer.absoluteDepth < amount.canvasRenderer.absoluteDepth,
            "Reward halo must layer below the amount.");

        Click(confirmButton);
        yield return new WaitForEndOfFrame();
        Require(confirmedClicks == 1 && confirm.Visible, "Confirmation must start on the click.");
        yield return new WaitForSecondsRealtime(0.07f);
        float earlier = Progress(confirm);
        Click(confirmButton, 0.19f);
        yield return new WaitForEndOfFrame();
        Require(confirmedClicks == 2 && earlier > 0 && Progress(confirm) < earlier,
            "A rapid click through the visible glint must restart the same confirmation instance.");

        Click(abilityButton);
        yield return new WaitForSecondsRealtime(0.07f);
        earlier = Progress(cooldown);
        Click(abilityButton);
        Require(earlier > 0 && Progress(cooldown) >= earlier && readyLabel.text == "READY",
            "The cooldown effect must ignore a duplicate while preserving the ready state.");

        Click(revealButton);
        Click(confirmButton);
        yield return new WaitForEndOfFrame();
        Require(confirm.Visible && cooldown.Visible && reward.Visible && amount.text == "+250",
            "Overlapping feedback must leave the reward amount readable immediately.");

        SamplePeak(false);
        var clippedLayer = (RectTransform)confirm.layers[0].transform;
        Vector2 clipMin = clippedLayer.anchorMin;
        Vector2 clipMax = clippedLayer.anchorMax;
        clippedLayer.anchorMin = Vector2.one * 4;
        clippedLayer.anchorMax = Vector2.one * 5;
        Canvas.ForceUpdateCanvases();
        Require(clippedLayer.GetComponent<Image>().canvasRenderer.cull, "Target mask must cull a layer outside the button.");
        clippedLayer.anchorMin = clipMin;
        clippedLayer.anchorMax = clipMax;
        var inherited = cooldown.layers[0].GetComponent<Image>();
        Require(!inherited.canvasRenderer.cull, "Inherited clipping must keep the in-bounds contour visible.");
        Vector2 inheritedMin = inherited.rectTransform.anchorMin;
        Vector2 inheritedMax = inherited.rectTransform.anchorMax;
        inherited.rectTransform.anchorMin = Vector2.one * 5;
        inherited.rectTransform.anchorMax = Vector2.one * 6;
        Canvas.ForceUpdateCanvases();
        Require(inherited.canvasRenderer.cull, "The ancestor mask must clip the inherited layer.");
        inherited.rectTransform.anchorMin = inheritedMin;
        inherited.rectTransform.anchorMax = inheritedMax;
        SamplePeak(false);
        yield return new WaitForEndOfFrame();
        SaveCapture("standard-peak.png");

        Click(skipButton);
        Require(reward.Idle && !reward.Visible && amount.text == "+250", "Skipping must clear only the reward animation.");
        Require(confirm.Visible && cooldown.Visible, "Skipping a reveal must leave overlapping effects playing.");
        yield return new WaitForEndOfFrame();
        SaveCapture("skipped-reveal.png");

        Click(revealButton);
        yield return null;
        yield return new WaitForEndOfFrame();
        Require(reward.Visible, "A skipped reveal must be replayable.");
        confirm.animator.speed = 1;
        cooldown.animator.speed = 1;
        yield return new WaitForSecondsRealtime(reward.effect.standardDurationSec + 0.10f);
        AssertIdle(confirm, cooldown, reward);
        Click(revealButton);
        yield return new WaitForEndOfFrame();
        Require(reward.Visible, "A completed reveal must be replayable.");
        CloseScreen();
        yield return null;
        screen.SetActive(true);
        yield return null;
        AssertIdle(confirm, cooldown, reward);
        Require(amount.text == "+250" && readyLabel.text == "READY", "Reopening must preserve persistent UI values.");

        reducedMotion = true;
        Time.timeScale = 0;
        Click(confirmButton);
        Click(abilityButton);
        Click(revealButton);
        yield return new WaitForEndOfFrame();
        foreach (var instance in new[] { confirm, cooldown, reward })
        {
            Require(instance.animator.GetCurrentAnimatorStateInfo(0).IsName(instance.effect.reducedState) && instance.Visible,
                $"Reduced variant did not start for {instance.effect.prefab}.");
            var visible = instance.layers.First(layer => layer.alpha > 0);
            var rect = (RectTransform)visible.transform;
            Vector2 position = rect.anchorMin;
            Vector3 scale = rect.localScale;
            float alpha = visible.alpha;
            instance.Sample(true, instance.effect.reducedDurationSec / 2);
            Require(rect.anchorMin == position && rect.localScale == scale && visible.alpha < alpha && visible.alpha > 0,
                "Reduced motion must fade a fixed pose.");
        }
        SamplePeak(true);
        yield return new WaitForEndOfFrame();
        SaveCapture("reduced-peak.png");
        foreach (var instance in new[] { confirm, cooldown, reward }) instance.animator.speed = 1;
        yield return new WaitForSecondsRealtime(reward.effect.reducedDurationSec + 0.10f);
        AssertIdle(confirm, cooldown, reward);
        Require(Time.timeScale == 0 && amount.text == "+250" && readyLabel.text == "READY",
            "UI effects must clear while the game is paused and preserve the final game state.");
        Time.timeScale = 1;
        yield return new WaitForEndOfFrame();
        SaveCapture("settled.png");
    }

    private void SetUpScreen(bool light = false, Rect? safeArea = null)
    {
        lightTheme = light;
        essentialLabels.Clear();
        if (screenOwner)
        {
            screenOwner.SetActive(false);
            Destroy(screenOwner);
        }
        screenOwner = new GameObject("Overlay pilot screen");
        font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        var camera = new GameObject("Backdrop camera").AddComponent<Camera>();
        camera.transform.SetParent(screenOwner.transform, false);
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = ColorOf(light ? "#EAF0F7" : "#0E1828");
        new GameObject("Event System", typeof(EventSystem)).transform.SetParent(screenOwner.transform, false);
        var canvas = new GameObject("Overlay Canvas", typeof(RectTransform), typeof(Canvas),
            typeof(CanvasScaler), typeof(GraphicRaycaster));
        canvas.transform.SetParent(screenOwner.transform, false);
        canvas.GetComponent<Canvas>().renderMode = RenderMode.ScreenSpaceOverlay;
        var scaler = canvas.GetComponent<CanvasScaler>();
        scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
        scaler.referenceResolution = new Vector2(480, 854);
        Rect area = safeArea ?? new Rect(0, 0, Screen.width, Screen.height);
        var content = Rect(canvas.transform, "Safe area", area.xMin / Screen.width, area.yMin / Screen.height,
            area.xMax / Screen.width, area.yMax / Screen.height);
        screen = content.gameObject;

        Label(content, "Outpost inventory", 36, 0.07f, 0.87f, 0.93f, 0.96f, TextAnchor.MiddleLeft);
        Label(content, "LOADOUT", 15, 0.07f, 0.82f, 0.93f, 0.87f, TextAnchor.MiddleLeft);
        var menu = Panel(content, "Loadout panel", light ? "#D5E0EC" : "#1A2940", 0.06f, 0.66f, 0.94f, 0.82f);
        confirmButton = AddButton(menu, "Equip button", light ? "#A5DBCD" : "#225750", 0.13f, 0.25f, 0.87f, 0.76f);
        confirmLabel = Label(confirmButton.transform, "Equip", 27, 0, 0, 1, 1);
        confirm = Mount(effects[0], confirmButton.transform);
        confirmButton.onClick.AddListener(() =>
        {
            confirmedClicks++;
            if (effectsEnabled) confirm.Play(reducedMotion);
        });

        Label(content, "ABILITY HUD", 15, 0.07f, 0.58f, 0.93f, 0.63f, TextAnchor.MiddleLeft);
        var hud = Panel(content, "Ability panel", light ? "#D5E0EC" : "#1A2940", 0.06f, 0.43f, 0.94f, 0.58f);
        hud.gameObject.AddComponent<RectMask2D>();
        abilityButton = AddButton(hud, "Ability button", light ? "#B5CADE" : "#253E5D", 0.17f, 0.25f, 0.31f, 0.72f);
        readyIcon = Panel(abilityButton.transform, "Ability icon", light ? "#37668A" : "#91CAE5", 0.32f, 0.32f, 0.68f, 0.68f).GetComponent<Image>();
        readyIcon.rectTransform.localRotation = Quaternion.Euler(0, 0, 45);
        readyLabel = Label(hud, "CHARGING", 24, 0.42f, 0.25f, 0.93f, 0.73f, TextAnchor.MiddleLeft);
        cooldown = Mount(effects[1], abilityButton.transform);
        abilityButton.onClick.AddListener(() =>
        {
            readyIcon.color = ColorOf(light ? "#165D74" : "#AFF3FF");
            readyLabel.text = "READY";
            if (effectsEnabled) cooldown.Play(reducedMotion);
        });

        Label(content, "MISSION REWARD", 15, 0.07f, 0.36f, 0.93f, 0.41f, TextAnchor.MiddleLeft);
        var rewardPanel = Panel(content, "Reward panel", light ? "#D5E0EC" : "#1A2940", 0.06f, 0.08f, 0.94f, 0.36f);
        var card = Panel(rewardPanel, "Reward card", light ? "#F1D7A9" : "#4A3526", 0.23f, 0.39f, 0.77f, 0.78f);
        amount = Label(card, "—", 36, 0, 0, 1, 1);
        reward = Mount(effects[2], card);
        revealButton = AddButton(rewardPanel, "Reveal button", light ? "#E6C895" : "#5A4530", 0.15f, 0.08f, 0.49f, 0.27f);
        Label(revealButton.transform, "Reveal", 20, 0, 0, 1, 1);
        revealButton.onClick.AddListener(() =>
        {
            amount.text = "+250";
            if (effectsEnabled) reward.Play(reducedMotion);
        });
        skipButton = AddButton(rewardPanel, "Skip button", light ? "#BFCEDF" : "#293A52", 0.51f, 0.08f, 0.85f, 0.27f);
        Label(skipButton.transform, "Skip", 20, 0, 0, 1, 1);
        skipButton.onClick.AddListener(reward.Cancel);
    }

    private static Instance Mount(Effect effect, Transform target)
    {
        var instance = Instantiate(effect.asset, target, false);
        if (effect.placement.order == "belowContent") instance.transform.SetAsFirstSibling();
        else instance.transform.SetAsLastSibling();
        var animator = instance.GetComponent<Animator>();
        Require(animator && animator.updateMode == AnimatorUpdateMode.UnscaledTime, "Expected unscaled UI animation.");
        Require((instance.GetComponent<RectMask2D>() != null) == (effect.placement.clipping == "target"),
            "Prefab clipping must follow the handoff.");
        return new Instance { effect = effect, animator = animator, layers = instance.GetComponentsInChildren<CanvasGroup>() };
    }

    private static void Click(Button button, float horizontal = 0.5f)
    {
        Canvas.ForceUpdateCanvases();
        var rect = (RectTransform)button.transform;
        var location = new Vector2(Mathf.Lerp(rect.rect.xMin, rect.rect.xMax, horizontal), rect.rect.center.y);
        var pointer = new PointerEventData(EventSystem.current)
        {
            position = RectTransformUtility.WorldToScreenPoint(null, rect.TransformPoint(location)),
            button = PointerEventData.InputButton.Left
        };
        var hits = new List<RaycastResult>();
        EventSystem.current.RaycastAll(pointer, hits);
        Require(hits.Count > 0 && ExecuteEvents.GetEventHandler<IPointerClickHandler>(hits[0].gameObject) == button.gameObject,
            $"Pointer raycast to '{button.name}' hit {(hits.Count == 0 ? "no graphic" : hits[0].gameObject.name)}.");
        ExecuteEvents.ExecuteHierarchy(hits[0].gameObject, pointer, ExecuteEvents.pointerDownHandler);
        ExecuteEvents.Execute(button.gameObject, pointer, ExecuteEvents.pointerUpHandler);
        ExecuteEvents.Execute(button.gameObject, pointer, ExecuteEvents.pointerClickHandler);
    }

    private void CloseScreen()
    {
        confirm.Cancel();
        cooldown.Cancel();
        reward.Cancel();
        screen.SetActive(false);
    }

    private void SamplePeak(bool reduced)
    {
        confirm.Sample(reduced, 0.035f);
        cooldown.Sample(reduced, reduced ? 0.035f : 0.085f);
        reward.Sample(reduced, reduced ? 0.04f : 0.13f);
    }

    private static void AssertIdle(params Instance[] instances)
    {
        foreach (var instance in instances)
            Require(instance.Idle && !instance.Visible, $"Unexpected residue on {instance.effect.prefab}.");
    }

    private static float Progress(Instance instance) => instance.animator.GetCurrentAnimatorStateInfo(0).normalizedTime;

    private void SaveCapture(string name, bool record = true)
    {
        var texture = new Texture2D(Screen.width, Screen.height, TextureFormat.RGB24, false);
        var previous = RenderTexture.active;
        try
        {
            RenderTexture.active = null;
            texture.ReadPixels(new Rect(0, 0, Screen.width, Screen.height), 0, 0, false);
            File.WriteAllBytes(Path.Combine(output, name), texture.EncodeToPNG());
            if (record) captures.Add(name);
        }
        finally
        {
            RenderTexture.active = previous;
            Destroy(texture);
        }
    }

    private Text Label(Transform parent, string text, int size, float left, float bottom, float right, float top,
        TextAnchor alignment = TextAnchor.MiddleCenter)
    {
        var label = Rect(parent, text, left, bottom, right, top).gameObject.AddComponent<Text>();
        label.font = font;
        label.fontStyle = FontStyle.Bold;
        label.fontSize = size;
        label.text = text;
        label.color = ColorOf(lightTheme ? "#14243A" : "#F2F5FB");
        label.alignment = alignment;
        label.raycastTarget = false;
        essentialLabels.Add(label);
        return label;
    }

    private static Button AddButton(Transform parent, string name, string color, float left, float bottom, float right, float top)
    {
        var rect = Panel(parent, name, color, left, bottom, right, top);
        var image = rect.GetComponent<Image>();
        image.raycastTarget = true;
        var button = rect.gameObject.AddComponent<Button>();
        button.targetGraphic = image;
        button.transition = Selectable.Transition.None;
        return button;
    }

    private static RectTransform Panel(Transform parent, string name, string color, float left, float bottom, float right, float top)
    {
        var rect = Rect(parent, name, left, bottom, right, top);
        var image = rect.gameObject.AddComponent<Image>();
        image.color = ColorOf(color);
        image.raycastTarget = false;
        return rect;
    }

    private static RectTransform Rect(Transform parent, string name, float left, float bottom, float right, float top)
    {
        var rect = (RectTransform)new GameObject(name, typeof(RectTransform)).transform;
        rect.SetParent(parent, false);
        rect.anchorMin = new Vector2(left, bottom);
        rect.anchorMax = new Vector2(right, top);
        rect.offsetMin = Vector2.zero;
        rect.offsetMax = Vector2.zero;
        return rect;
    }

    private static Color ColorOf(string hex)
    {
        ColorUtility.TryParseHtmlString(hex, out var color);
        return color;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
