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
        {
            StripDuplicateLauncherFromManifest(exportPath);
            Debug.Log("Android Export Succeeded!");
        }
        else
            Debug.LogError("Android Export Failed: " + summary.result);

        // Command-line exports must quit so the terminal gets an exit code.
        // The menu item must leave the editor window open.
        if (Application.isBatchMode)
            EditorApplication.Exit(summary.result == UnityEditor.Build.Reporting.BuildResult.Succeeded ? 0 : 1);
    }

    static void StripDuplicateLauncherFromManifest(string exportPath)
    {
        string[] candidates =
        {
            Path.Combine(exportPath, "src", "main", "AndroidManifest.xml"),
            Path.Combine(exportPath, "unityLibrary", "src", "main", "AndroidManifest.xml"),
        };

        foreach (var manifestPath in candidates)
        {
            if (!File.Exists(manifestPath)) continue;
            var xml = File.ReadAllText(manifestPath);
            xml = System.Text.RegularExpressions.Regex.Replace(
                xml,
                @"<intent-filter>\s*<category android:name=""android\.intent\.category\.LAUNCHER""\s*/>\s*<action android:name=""android\.intent\.action\.MAIN""\s*/>\s*</intent-filter>",
                "",
                System.Text.RegularExpressions.RegexOptions.Singleline);
            xml = System.Text.RegularExpressions.Regex.Replace(
                xml,
                @"<intent-filter>\s*<action android:name=""android\.intent\.action\.MAIN""\s*/>\s*<category android:name=""android\.intent\.category\.LAUNCHER""\s*/>\s*</intent-filter>",
                "",
                System.Text.RegularExpressions.RegexOptions.Singleline);
            xml = xml.Replace(@"android:exported=""true""", @"android:exported=""false""");
            File.WriteAllText(manifestPath, xml);
            Debug.Log("Cleaned duplicate launcher intent-filter from: " + manifestPath);
        }
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
