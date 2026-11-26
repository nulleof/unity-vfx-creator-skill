using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class UiEffectsPlayerBuild
{
    [Serializable]
    private sealed class Inputs
    {
        public string[] effects;
        public string scene;
        public string player;
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
        var build = BuildPipeline.BuildPlayer(new BuildPlayerOptions
        {
            scenes = new[] { input.scene }, locationPathName = input.player,
            target = BuildTarget.StandaloneWindows64
        });
        if (build.summary.result != BuildResult.Succeeded)
            throw new InvalidOperationException($"Overlay pilot player build {build.summary.result}.");
    }
}
