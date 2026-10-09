using UnityEditor;
using UnityEngine;
using System.IO;

/// <summary>
/// Export commands for Flutter + Unity.
/// Run these from the Unity menu: Flutter/...
/// </summary>
public class BuildCommand
{
    [MenuItem("Flutter/Export Android for Flutter")]
    public static void PerformAndroidExport()
    {
        Debug.Log("Starting Automated Android Export for Flutter...");

        EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android);
        EditorUserBuildSettings.exportAsGoogleAndroidProject = true;
        // The phone loads GLBs from the LAN backend over http://. Unity blocks that
        // unless this is AlwaysAllowed, and the value is baked in at export time.
        PlayerSettings.insecureHttpOption = InsecureHttpOption.AlwaysAllowed;

        string projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, "..", ".."));
        string exportPath = Path.Combine(projectRoot, "client", "android", "unityLibrary");

        Debug.Log("Target Export Path: " + exportPath);

        BuildPlayerOptions buildPlayerOptions = new BuildPlayerOptions();
        buildPlayerOptions.scenes = new[] { "Assets/Scenes/SampleScene.unity" }; 
        buildPlayerOptions.locationPathName = exportPath;
        buildPlayerOptions.target = BuildTarget.Android;
        buildPlayerOptions.options = BuildOptions.AcceptExternalModificationsToPlayer;

        var report = BuildPipeline.BuildPlayer(buildPlayerOptions);
        var summary = report.summary;

        if (summary.result == UnityEditor.Build.Reporting.BuildResult.Succeeded)
            Debug.Log("Android Export Succeeded!");
        else
            Debug.LogError("Android Export Failed: " + summary.result);

        // Command-line exports must quit so the terminal gets an exit code.
        // The menu item must leave the editor window open.
        if (Application.isBatchMode)
            EditorApplication.Exit(summary.result == UnityEditor.Build.Reporting.BuildResult.Succeeded ? 0 : 1);
    }

    [MenuItem("Flutter/Export iOS for Flutter (iPhone)")]
    public static void PerformIOSExport()
    {
        Debug.Log("Starting iOS Export for Flutter (required for real iPhone support)...");

        EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.iOS, BuildTarget.iOS);

        string projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, "..", ".."));
        string exportPath = Path.Combine(projectRoot, "client", "ios", "Unity-iPhone");

        Directory.CreateDirectory(exportPath);

        BuildPlayerOptions buildPlayerOptions = new BuildPlayerOptions();
        buildPlayerOptions.scenes = new[] { "Assets/Scenes/SampleScene.unity" };
        buildPlayerOptions.locationPathName = exportPath;
        buildPlayerOptions.target = BuildTarget.iOS;
        buildPlayerOptions.options = BuildOptions.AcceptExternalModificationsToPlayer;

        var report = BuildPipeline.BuildPlayer(buildPlayerOptions);

        if (report.summary.result == UnityEditor.Build.Reporting.BuildResult.Succeeded)
        {
            Debug.Log("iOS Export Succeeded! Now open the exported project in Xcode and integrate UnityFramework.");
            Debug.Log("See flutter_unity_widget docs for Podfile + AppDelegate changes.");
        }
        else
        {
            Debug.LogError("iOS Export Failed. Make sure you have iOS build support installed in Unity Hub.");
        }
    }

    [MenuItem("Flutter/Quick Clean + Refresh")]
    public static void CleanAndRefresh()
    {
        AssetDatabase.Refresh();
        Debug.Log("Project refreshed. Ready for export.");
    }
}
