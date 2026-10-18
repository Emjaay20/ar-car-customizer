using UnityEditor;
using UnityEngine;
using Unity.InferenceEngine;
using System;
using System.IO;

/// <summary>
/// Export commands for Flutter + Unity.
/// Run these from the Unity menu: Flutter/...
/// </summary>
public class BuildCommand
{
    static void VerifySentisModelInUnity(string projectRoot)
    {
        AssetDatabase.Refresh();
        var modelAsset = Resources.Load<ModelAsset>("CarSegMask");
        if (modelAsset == null)
            throw new Exception("[VerifySentis] CarSegMask ModelAsset is null in Resources!");

        var model = ModelLoader.Load(modelAsset);
        using var worker = new Worker(model, BackendType.CPU);
        using var blankTensor = new Tensor<float>(new TensorShape(1, 3, 256, 256));
        worker.Schedule(blankTensor);
        var blankOut = (worker.PeekOutput() as Tensor<float>).ReadbackAndClone();
        float blankMax = 0f;
        for (int i = 0; i < blankOut.count; i++)
            if (blankOut[i] > blankMax) blankMax = blankOut[i];
        blankOut.Dispose();
        Debug.Log($"[VerifySentis] Blank 256x256 tensor max = {blankMax:F5}");
        if (blankMax > 0.05f)
            throw new Exception($"[VerifySentis] Blank tensor max too high: {blankMax}");

        string[] testFrames = { "frame_0000.jpg", "frame_1040.jpg", "frame_1300.jpg" };
        foreach (var fname in testFrames)
        {
            string fpath = Path.Combine(projectRoot, "scratch", "eval_085711", fname);
            if (!File.Exists(fpath)) continue;
            byte[] bytes = File.ReadAllBytes(fpath);
            var tex = new Texture2D(2, 2);
            tex.LoadImage(bytes);

            // Crop top half (Unity viewport) and resize to 256x256 on CPU to verify worker execution in batchmode
            using var imgTensor = new Tensor<float>(new TensorShape(1, 3, 256, 256));
            int cropH = tex.height / 2;
            for (int y = 0; y < 256; y++)
            {
                // y=0 is top of image; Texture2D.GetPixelBilinear has v=1 at top, v=0.5 at middle of full screenshot
                float v = 1.0f - (y / 255.0f) * 0.5f;
                for (int x = 0; x < 256; x++)
                {
                    float u = x / 255.0f;
                    Color c = tex.GetPixelBilinear(u, v);
                    imgTensor[0, 0, y, x] = c.r;
                    imgTensor[0, 1, y, x] = c.g;
                    imgTensor[0, 2, y, x] = c.b;
                }
            }
            UnityEngine.Object.DestroyImmediate(tex);

            worker.Schedule(imgTensor);
            using var outClone = (worker.PeekOutput() as Tensor<float>).ReadbackAndClone();
            float maxVal = 0f, sumVal = 0f;
            int activeCount = 0;
            for (int i = 0; i < outClone.count; i++)
            {
                float val = outClone[i];
                if (val > maxVal) maxVal = val;
                sumVal += val;
                if (val > 0.25f) activeCount++;
            }
            float meanVal = sumVal / outClone.count;
            float cov = (activeCount * 100f) / outClone.count;
            Debug.Log($"[VerifySentis] {fname}: max={maxVal:F4}, mean={meanVal:F4}, coverage={cov:F1}%");
            if (maxVal < 0.8f || cov < 10f)
                throw new Exception($"[VerifySentis] Failed detection on {fname}: max={maxVal}, cov={cov}%");
        }
        Debug.Log("[VerifySentis] All Unity Sentis CPU inference checks PASSED!");
    }

    [MenuItem("Flutter/Verify Sentis Model")]
    public static void VerifySentisMenu()
    {
        string projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, "..", ".."));
        VerifySentisModelInUnity(projectRoot);
    }

    [MenuItem("Flutter/Export Android for Flutter")]
    public static void PerformAndroidExport()
    {
        Debug.Log("Starting Automated Android Export for Flutter...");

        EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android);
        EditorUserBuildSettings.exportAsGoogleAndroidProject = true;
        PlayerSettings.SetManagedStrippingLevel(UnityEditor.Build.NamedBuildTarget.Android, ManagedStrippingLevel.Minimal);
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
