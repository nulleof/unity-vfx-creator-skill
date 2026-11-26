using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

public static class UiEffectsPlayerBuild
{
    [Serializable]
    private sealed class Inputs
    {
        public string[] effects;
        public string scene;
        public string player;
        public string androidPlayer;
    }

    public static void Run()
    {
        string[] args = Environment.GetCommandLineArgs();
        var input = JsonUtility.FromJson<Inputs>(File.ReadAllText(args[Array.IndexOf(args, "-vfxUiPlayerInput") + 1]));
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var check = new GameObject("Overlay UI pilot").AddComponent<UiEffectsPlayCheck>();
        check.effects = input.effects.Select(path =>
        {
            var effect = JsonUtility.FromJson<UiEffectsPlayCheck.Effect>(File.ReadAllText(path));
            effect.asset = AssetDatabase.LoadAssetAtPath<GameObject>(effect.prefab);
            if (!effect.asset)
                throw new InvalidOperationException("Missing UI pilot prefab " + effect.prefab);
            return effect;
        }).ToArray();
        if (!EditorSceneManager.SaveScene(scene, input.scene))
            throw new IOException("Could not save the temporary Overlay pilot scene.");
        if (EditorUserBuildSettings.activeBuildTarget == BuildTarget.Android)
        {
            BuildAndroid(input);
            return;
        }
        Build(input.scene, input.player, BuildTarget.StandaloneWindows64, BuildOptions.None);
    }

    private static void BuildAndroid(Inputs input)
    {
        const string package = "org.vfxcreator.overlayreview";
        var target = UnityEditor.Build.NamedBuildTarget.Android;
        string identifier = PlayerSettings.GetApplicationIdentifier(target);
        var orientation = PlayerSettings.defaultInterfaceOrientation;
        var architectures = PlayerSettings.Android.targetArchitectures;
        bool outsideSafeArea = PlayerSettings.Android.renderOutsideSafeArea;
        bool automaticApi = PlayerSettings.GetUseDefaultGraphicsAPIs(BuildTarget.Android);
        var graphicsApis = PlayerSettings.GetGraphicsAPIs(BuildTarget.Android);
        bool bundle = EditorUserBuildSettings.buildAppBundle;
        try
        {
            PlayerSettings.SetApplicationIdentifier(target, package);
            PlayerSettings.defaultInterfaceOrientation = UIOrientation.Portrait;
            PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
            PlayerSettings.Android.renderOutsideSafeArea = true;
            PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android, false);
            PlayerSettings.SetGraphicsAPIs(BuildTarget.Android, new[] { GraphicsDeviceType.Vulkan });
            EditorUserBuildSettings.buildAppBundle = false;
            Build(input.scene, input.androidPlayer, BuildTarget.Android, BuildOptions.Development);
        }
        finally
        {
            EditorUserBuildSettings.buildAppBundle = bundle;
            PlayerSettings.SetGraphicsAPIs(BuildTarget.Android, graphicsApis);
            PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android, automaticApi);
            PlayerSettings.Android.renderOutsideSafeArea = outsideSafeArea;
            PlayerSettings.Android.targetArchitectures = architectures;
            PlayerSettings.defaultInterfaceOrientation = orientation;
            PlayerSettings.SetApplicationIdentifier(target, identifier);
        }
    }

    private static void Build(string scene, string player, BuildTarget target, BuildOptions options)
    {
        var build = BuildPipeline.BuildPlayer(new BuildPlayerOptions
        {
            scenes = new[] { scene }, locationPathName = player, target = target, options = options
        });
        if (build.summary.result != BuildResult.Succeeded)
            throw new InvalidOperationException($"Overlay pilot player build {build.summary.result}.");
    }
}
