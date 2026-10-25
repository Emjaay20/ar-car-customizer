using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using FlutterUnityIntegration;
using GLTFast;
using UnityEngine;
using UnityEngine.Networking;

/// <summary>
/// Flutter calls methods on the GameObject named FlutterMessageReceiver.
/// Loads a hosted GLB, paints body materials, and attaches rim/spoiler stand-ins
/// at estimated anchors. Live camera tint stays off until a segmentation mask arrives.
/// ApplyPaint also sets finish and panel. CaptureSnapshot writes a PNG for Flutter to share.
/// </summary>
public class FlutterMessageReceiver : MonoBehaviour
{
    const string BundledModel = "cesium-milk-truck.glb";

    GameObject currentCar;
    GltfImport activeImport;
    string pendingPaint;
    readonly List<string> pendingParts = new List<string>();
    string pendingLiveTint;
    bool liveTintSent;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    static void EnsureBridge()
    {
        var existing = FindAnyObjectByType<FlutterMessageReceiver>();
        if (existing != null)
        {
            existing.gameObject.name = "FlutterMessageReceiver";
            return;
        }

        var bridge = new GameObject("FlutterMessageReceiver");
        bridge.AddComponent<FlutterMessageReceiver>();
        bridge.AddComponent<SpatialDamageAnchorManager>();
        bridge.AddComponent<VoiceCommandDispatcher>();
        DontDestroyOnLoad(bridge);
    }

    void Start()
    {
        ArTemplateChrome.Hide();
    }

    public void LoadCarModel(string modelUrl)
    {
        ArTemplateChrome.Hide();

        if (string.IsNullOrEmpty(modelUrl))
        {
            Debug.LogError("No model URL provided from Flutter");
            SendMessageToFlutter("MODEL_FAILED:missing-url");
            return;
        }

        StartCoroutine(LoadCarModelRoutine(modelUrl));
    }

    public void ChangePaintColor(string colorNameOrHex)
    {
        ApplyPaint(colorNameOrHex);
    }

    public void ApplyPaint(string json)
    {
        pendingPaint = json;
        pendingLiveTint = json;
        liveTintSent = false;
        var request = PaintRequest.Parse(json);
        ApplyLive(request);
        if (currentCar == null)
        {
            SendMessageToFlutter("PAINT_QUEUED:" + request.finish);
            return;
        }

        if (CarPaintApplicator.Apply(currentCar, request))
            SendMessageToFlutter("PAINT_APPLIED:" + request.finish + ":" + request.color + ":" + request.panel);
        else
            SendMessageToFlutter("PAINT_NO_BODY:" + request.color);
    }

    public void CaptureSnapshot(string mode)
    {
        StartCoroutine(CaptureSnapshotRoutine(mode));
    }

    public void AnchorToSurface(string unused)
    {
        if (currentCar == null)
        {
            SendMessageToFlutter("ANCHOR_FAILED:no-car");
            return;
        }

        CarSurfaceAnchor.Begin(currentCar);
        SendMessageToFlutter("ANCHOR_SEARCHING");
    }

    public void DisplayDamagePins(string jsonPayload)
    {
        SpatialDamageAnchorManager.Instance?.SetCarTarget(currentCar);
        SpatialDamageAnchorManager.Instance?.DisplayDamagePins(jsonPayload);
        SendMessageToFlutter("DAMAGE_PINS_UPDATED");
    }

    public void ClearDamagePins(string unused)
    {
        SpatialDamageAnchorManager.Instance?.ClearPins();
        SendMessageToFlutter("DAMAGE_PINS_CLEARED");
    }

    public void ProcessVoiceCommand(string transcript)
    {
        var dispatcher = GetComponent<VoiceCommandDispatcher>();
        if (dispatcher != null)
            dispatcher.ProcessVoiceCommand(transcript);
        else
            SendMessageToFlutter("VOICE_FAILED:no-dispatcher");
    }

    public void ChangeRims(string rimName)
    {
        AttachPart(PartAnchorRig.LegacyRequest("RIM", rimName));
    }

    public void ChangeSpoiler(string spoilerName)
    {
        AttachPart(PartAnchorRig.LegacyRequest("SPOILER", spoilerName));
    }

    public void AttachPart(string json)
    {
        if (string.IsNullOrEmpty(json))
        {
            SendMessageToFlutter("PART_FAILED:empty");
            return;
        }

        var type = PartAnchorRig.ReadType(json);
        pendingParts.RemoveAll(item => PartAnchorRig.ReadType(item) == type);
        pendingParts.Add(json);
        if (currentCar == null)
        {
            SendMessageToFlutter("PART_QUEUED:" + type);
            return;
        }

        StartCoroutine(PartAnchorRig.Attach(currentCar, json, SendMessageToFlutter));
    }

    public void SetLiveTint(string colorNameOrHex)
    {
        pendingLiveTint = colorNameOrHex;
        liveTintSent = false;
        ApplyLive(PaintRequest.Parse(colorNameOrHex));
    }

    public void LoadSegmentationMask(string url)
    {
        StartCoroutine(LoadMaskRoutine(url));
    }

    public void LoadLockedFrame(string url)
    {
        StartCoroutine(LoadLockedFrameRoutine(url));
    }

    public void ReleaseLockedFrame(string unused)
    {
        var camera = Camera.main;
        var filter = LiveCarFilter.Ensure(camera);
        if (filter != null)
            filter.ReleaseLockedFrame();
        SendMessageToFlutter("LOCKED_FRAME_RELEASED");
    }

    public void SetKeypoints(string json)
    {
        var frame = JsonUtility.FromJson<KeypointFrame>(json);
        if (frame == null || frame.points == null)
        {
            SendMessageToFlutter("KEYPOINTS_FAILED");
            return;
        }

        PartAnchorRig.PlaceImageKeypoints(frame.points, Camera.main);
        PartAnchorRig.AttachToImageKeypoints(frame.points, Camera.main, pendingParts, SendMessageToFlutter);
        SendMessageToFlutter("KEYPOINTS_APPLIED:" + frame.points.Length);
    }

    public void ApplyBridgeFrame(string json)
    {
        var frame = JsonUtility.FromJson<BridgeFrame>(json);
        if (frame == null)
        {
            SendMessageToFlutter("BRIDGE_FAILED");
            return;
        }

        if (frame.points != null && frame.points.Length > 0)
            SetKeypoints(JsonUtility.ToJson(new KeypointFrame { points = frame.points }));
        if (!string.IsNullOrEmpty(frame.maskPng))
            LoadSegmentationMask(frame.maskPng);
    }

    public void CaptureLearningExample(string unused)
    {
        GetComponent<SentisCarSegmenter>()?.CaptureLearningExample();
    }

    public void SetLearningCapture(string enabled)
    {
        LearningSampleRecorder.Enabled = string.Equals(enabled, "true", StringComparison.OrdinalIgnoreCase);
        SendMessageToFlutter(LearningSampleRecorder.Enabled ? "LEARNING_CAPTURE_ON" : "LEARNING_CAPTURE_OFF");
    }

    public void RunSentis(string mode)
    {
        if (string.Equals(mode, "debug_mask_on", StringComparison.OrdinalIgnoreCase))
        {
            var filter = LiveCarFilter.Ensure(Camera.main);
            if (filter != null) filter.SetDebugMaskMode(true);
            SendMessageToFlutter("DEBUG_MASK:ON");
            return;
        }
        if (string.Equals(mode, "debug_mask_off", StringComparison.OrdinalIgnoreCase))
        {
            var filter = LiveCarFilter.Ensure(Camera.main);
            if (filter != null) filter.SetDebugMaskMode(false);
            SendMessageToFlutter("DEBUG_MASK:OFF");
            return;
        }

        var segmenter = GetComponent<SentisCarSegmenter>();
        if (segmenter == null)
            segmenter = gameObject.AddComponent<SentisCarSegmenter>();

        if (string.Equals(mode, "stop", StringComparison.OrdinalIgnoreCase))
        {
            segmenter.StopLiveLoop();
            var filter = LiveCarFilter.Ensure(Camera.main);
            if (filter != null)
                filter.ClearLive();
            SendMessageToFlutter("SENTIS_STOPPED");
            return;
        }

        segmenter.StartLiveLoop();
    }

    void Update()
    {
        if (!liveTintSent && !string.IsNullOrEmpty(pendingLiveTint))
            ApplyLive(PaintRequest.Parse(pendingLiveTint));
    }

    void ApplyLive(PaintRequest request)
    {
        var camera = Camera.main;
        if (camera == null || request == null)
            return;

        var filter = LiveCarFilter.Ensure(camera);
        var finish = request.FinishValues();
        if (filter == null || !filter.SetTint(CarPaintApplicator.ParseColor(request.color)))
        {
            SendMessageToFlutter("LIVE_TINT_NO_SHADER");
            liveTintSent = true;
            return;
        }

        filter.SetFinish(finish.metallic, finish.smoothness, finish.strength, request.PanelId(), request.FinishId());
        if (!liveTintSent)
            SendMessageToFlutter("LIVE_TINT:" + request.finish + ":" + request.color);
        liveTintSent = true;
    }

    System.Collections.IEnumerator LoadMaskRoutine(string url)
    {
        if (string.IsNullOrEmpty(url))
        {
            SendMessageToFlutter("MASK_FAILED:missing-url");
            yield break;
        }

        if (TryLocalPath(url, out var localPath))
        {
            byte[] bytes;
            try
            {
                bytes = File.ReadAllBytes(localPath);
            }
            catch (Exception e)
            {
                SendMessageToFlutter("MASK_FAILED:" + e.Message);
                yield break;
            }

            var texture = new Texture2D(2, 2, TextureFormat.RGBA32, false);
            if (!texture.LoadImage(bytes) || !ApplyMaskTexture(texture))
            {
                SendMessageToFlutter("MASK_FAILED:bad-image");
                yield break;
            }

            SendMessageToFlutter("MASK_APPLIED");
            yield break;
        }

        using (var request = UnityWebRequestTexture.GetTexture(ToRequestUrl(url)))
        {
            yield return request.SendWebRequest();
            if (request.result != UnityWebRequest.Result.Success)
            {
                SendMessageToFlutter("MASK_FAILED:" + request.error);
                yield break;
            }

            var texture = DownloadHandlerTexture.GetContent(request);
            if (!ApplyMaskTexture(texture))
            {
                SendMessageToFlutter("MASK_FAILED:no-camera");
                yield break;
            }

            SendMessageToFlutter("MASK_APPLIED");
        }
    }

    Texture2D lastLockedTexture;

    System.Collections.IEnumerator LoadLockedFrameRoutine(string url)
    {
        if (string.IsNullOrEmpty(url))
        {
            SendMessageToFlutter("LOCKED_FRAME_FAILED:missing-url");
            yield break;
        }

        byte[] bytes = null;
        if (TryLocalPath(url, out var localPath))
        {
            try
            {
                bytes = File.ReadAllBytes(localPath);
            }
            catch (Exception e)
            {
                SendMessageToFlutter("LOCKED_FRAME_FAILED:" + e.Message);
                yield break;
            }
        }
        else
        {
            using (var request = UnityWebRequestTexture.GetTexture(ToRequestUrl(url)))
            {
                yield return request.SendWebRequest();
                if (request.result != UnityWebRequest.Result.Success)
                {
                    SendMessageToFlutter("LOCKED_FRAME_FAILED:" + request.error);
                    yield break;
                }

                var texture = DownloadHandlerTexture.GetContent(request);
                if (!ApplyLockedFrameTexture(texture))
                {
                    SendMessageToFlutter("LOCKED_FRAME_FAILED:no-camera");
                    yield break;
                }

                SendMessageToFlutter("LOCKED_FRAME_APPLIED");
                yield break;
            }
        }

        if (bytes != null)
        {
            var texture = new Texture2D(2, 2, TextureFormat.RGB24, false);
            if (!texture.LoadImage(bytes) || !ApplyLockedFrameTexture(texture))
            {
                SendMessageToFlutter("LOCKED_FRAME_FAILED:bad-image");
                yield break;
            }

            SendMessageToFlutter("LOCKED_FRAME_APPLIED");
        }
    }

    bool ApplyLockedFrameTexture(Texture2D texture)
    {
        var camera = Camera.main;
        var filter = LiveCarFilter.Ensure(camera);
        if (filter == null) return false;
        filter.SetLockedFrame(texture);
        if (lastLockedTexture != null && lastLockedTexture != texture)
            Destroy(lastLockedTexture);
        lastLockedTexture = texture;
        return true;
    }

    Texture lastMaskTexture;

    bool ApplyMaskTexture(Texture texture)
    {
        var camera = Camera.main;
        var filter = LiveCarFilter.Ensure(camera);
        if (filter == null || !filter.SetMask(texture))
            return false;
        if (lastMaskTexture != null && lastMaskTexture != texture)
            Destroy(lastMaskTexture);
        lastMaskTexture = texture;
        var segmenter = GetComponent<SentisCarSegmenter>();
        if (segmenter != null)
            segmenter.NotifyExternalMaskApplied();
        if (!string.IsNullOrEmpty(pendingLiveTint))
            ApplyLive(PaintRequest.Parse(pendingLiveTint));
        return true;
    }

    static bool TryLocalPath(string url, out string path)
    {
        path = null;
        if (string.IsNullOrEmpty(url))
            return false;

        if (url.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                path = new Uri(url).LocalPath;
            }
            catch (Exception)
            {
                return false;
            }

            return File.Exists(path);
        }

        if (Path.IsPathRooted(url) && File.Exists(url))
        {
            path = url;
            return true;
        }

        return false;
    }

    static string ToRequestUrl(string path)
    {
        if (path.StartsWith("http://") || path.StartsWith("https://") || path.StartsWith("file:"))
            return path;
        if (path.StartsWith("/"))
            return path;
        if (System.IO.Path.IsPathRooted(path))
            return new Uri(path).AbsoluteUri;
        return path;
    }

    void ReplayParts()
    {
        if (currentCar == null) return;
        foreach (var json in pendingParts)
            StartCoroutine(PartAnchorRig.Attach(currentCar, json, SendMessageToFlutter));
    }

    System.Collections.IEnumerator LoadCarModelRoutine(string url)
    {
        if (TryLocalPath(url, out var localPath))
        {
            yield return LoadLocalModel(localPath);
            yield break;
        }

        var holder = new GameObject("ARCarLoading");
        var gltf = holder.AddComponent<GltfAsset>();
        gltf.LoadOnStartup = false;

        Task<bool> task = null;
        var loadThrew = false;
        try
        {
            task = gltf.Load(url);
        }
        catch (Exception e)
        {
            Debug.LogError("[AR] GLB load threw: " + e.Message);
            Destroy(holder);
            loadThrew = true;
        }

        if (loadThrew)
        {
            yield return LoadBundledModel();
            yield break;
        }

        while (!task.IsCompleted)
            yield return null;

        if (task.IsFaulted || task.IsCanceled || !task.Result)
        {
            var reason = task.Exception != null ? task.Exception.GetBaseException().Message : "download failed";
            Debug.LogError("[AR] Remote GLB failed: " + url + " " + reason);
            Destroy(holder);
            yield return LoadBundledModel();
            yield break;
        }

        AdoptLoadedCar(holder, url);
    }

    System.Collections.IEnumerator LoadLocalModel(string path)
    {
        var holder = new GameObject("ARCarLoading");
        var importer = new GltfImport();
        Task<bool> loadTask = null;
        var loadThrew = false;
        try
        {
            loadTask = importer.LoadFile(path);
        }
        catch (Exception e)
        {
            Debug.LogError("[AR] Local GLB threw: " + e.Message);
            Destroy(holder);
            importer.Dispose();
            loadThrew = true;
        }

        if (loadThrew)
        {
            yield return LoadBundledModel();
            yield break;
        }

        while (!loadTask.IsCompleted)
            yield return null;

        if (loadTask.IsFaulted || loadTask.IsCanceled || !loadTask.Result)
        {
            var reason = loadTask.Exception != null ? loadTask.Exception.GetBaseException().Message : "read failed";
            Debug.LogError("[AR] Local GLB failed: " + path + " " + reason);
            Destroy(holder);
            importer.Dispose();
            yield return LoadBundledModel();
            yield break;
        }

        Task<bool> instanceTask = null;
        var instanceThrew = false;
        try
        {
            instanceTask = importer.InstantiateMainSceneAsync(holder.transform);
        }
        catch (Exception e)
        {
            Debug.LogError("[AR] Local GLB instantiate threw: " + e.Message);
            Destroy(holder);
            importer.Dispose();
            instanceThrew = true;
        }

        if (instanceThrew)
        {
            yield return LoadBundledModel();
            yield break;
        }

        while (!instanceTask.IsCompleted)
            yield return null;

        if (instanceTask.IsFaulted || instanceTask.IsCanceled || !instanceTask.Result)
        {
            Destroy(holder);
            importer.Dispose();
            yield return LoadBundledModel();
            yield break;
        }

        activeImport = importer;
        AdoptLoadedCar(holder, path);
    }

    void AdoptLoadedCar(GameObject holder, string source)
    {
        if (currentCar != null)
            Destroy(currentCar);
        currentCar = holder;
        currentCar.name = "ARCar";
        FramePreview(currentCar);

        Debug.Log("[AR] GLB loaded: " + source);
        SendMessageToFlutter("MODEL_LOADED:" + source);
        EnvironmentLight.Ensure();
        CarSurfaceAnchor.Begin(currentCar);

        if (!string.IsNullOrEmpty(pendingPaint))
            ChangePaintColor(pendingPaint);
        ReplayParts();
    }

    bool snapshotInFlight;

    System.Collections.IEnumerator CaptureSnapshotRoutine(string mode)
    {
        if (snapshotInFlight) { SendMessageToFlutter("SNAPSHOT_FAILED:busy"); yield break; }
        snapshotInFlight = true;
        bool captureClean = string.Equals(mode, "clean", StringComparison.OrdinalIgnoreCase);
        var filter = captureClean ? LiveCarFilter.Ensure(Camera.main) : null;
        if (filter != null)
        {
            filter.SetCaptureCleanHide(true);
            // Wait one full rendered camera frame so the live paint overlay is guaranteed off-screen
            yield return null;
        }

        yield return new WaitForEndOfFrame();
        var texture = ScreenCapture.CaptureScreenshotAsTexture();
        snapshotInFlight = false;

        if (filter != null)
            filter.SetCaptureCleanHide(false);

        if (texture == null)
        {
            SendMessageToFlutter("SNAPSHOT_FAILED:no-frame");
            yield break;
        }

        // Capture full uncropped camera frame so vehicle body, bumper, wheels, and hood are completely preserved
        var bytes = texture.EncodeToJPG(92);
        Destroy(texture);

        var path = Path.Combine(
            Application.persistentDataPath,
            "ar-paint-" + Guid.NewGuid().ToString("N") + ".jpg");
        try
        {
            File.WriteAllBytes(path, bytes);
        }
        catch (Exception e)
        {
            SendMessageToFlutter("SNAPSHOT_FAILED:" + e.Message);
            yield break;
        }

        SendMessageToFlutter("SNAPSHOT:" + path);
    }

    static void FramePreview(GameObject car)
    {
        CarPhotoMaterial.Apply(car);
        CarPreviewFrame.Fit(car);
        PlaceInFrontOfCamera(car);
        CarPreviewFrame.EnsureShadow(car);
    }

    System.Collections.IEnumerator LoadBundledModel()
    {
        var holder = new GameObject("ARCarLoading");
        var gltf = holder.AddComponent<GltfAsset>();
        gltf.LoadOnStartup = false;
        gltf.StreamingAsset = true;
        gltf.Url = BundledModel;

        Task<bool> task;
        try
        {
            task = gltf.Load(gltf.FullUrl);
        }
        catch (Exception e)
        {
            Destroy(holder);
            ShowFallbackCar();
            SendMessageToFlutter("MODEL_FAILED:" + e.Message);
            yield break;
        }

        while (!task.IsCompleted)
            yield return null;

        if (task.IsFaulted || task.IsCanceled || !task.Result)
        {
            Destroy(holder);
            ShowFallbackCar();
            SendMessageToFlutter("MODEL_FAILED:bundled model");
            yield break;
        }

        if (currentCar != null)
            Destroy(currentCar);
        currentCar = holder;
        currentCar.name = "ARCar";
        SpatialDamageAnchorManager.Instance?.SetCarTarget(currentCar);
        FramePreview(currentCar);
        SendMessageToFlutter("MODEL_LOADED:bundled");
        EnvironmentLight.Ensure();
        CarSurfaceAnchor.Begin(currentCar);
        if (!string.IsNullOrEmpty(pendingPaint))
            ChangePaintColor(pendingPaint);
        ReplayParts();
    }

    static void PlaceInFrontOfCamera(GameObject car)
    {
        CarPreviewFrame.PlaceOnLookRay(car);
    }

    void ShowFallbackCar()
    {
        if (currentCar != null)
            Destroy(currentCar);

        var root = new GameObject("ARCar");
        var body = GameObject.CreatePrimitive(PrimitiveType.Cube);
        body.name = "Body";
        body.transform.SetParent(root.transform, false);
        body.transform.localScale = new Vector3(0.9f, 0.35f, 2f);
        body.transform.localPosition = new Vector3(0f, 0.28f, 0f);

        var cabin = GameObject.CreatePrimitive(PrimitiveType.Cube);
        cabin.name = "Cabin";
        cabin.transform.SetParent(root.transform, false);
        cabin.transform.localScale = new Vector3(0.8f, 0.35f, 0.9f);
        cabin.transform.localPosition = new Vector3(0f, 0.58f, -0.15f);

        var shader = Shader.Find("ARCar/PhotoPaint");
        if (shader == null)
            shader = Shader.Find("Universal Render Pipeline/Lit");
        if (shader == null)
            shader = Shader.Find("Standard");
        if (shader != null)
        {
            var material = new Material(shader) { name = "truck" };
            CarPaintApplicator.ApplyToMaterial(material, new Color(0.15f, 0.15f, 0.15f), new PaintFinishValues(0.08f, 0.92f, 0.62f));
            body.GetComponent<Renderer>().sharedMaterial = material;
            cabin.GetComponent<Renderer>().sharedMaterial = material;
        }

        currentCar = root;
        FramePreview(currentCar);
        EnvironmentLight.Ensure();
        CarSurfaceAnchor.Begin(currentCar);
        if (!string.IsNullOrEmpty(pendingPaint))
            ChangePaintColor(pendingPaint);
    }

    public static void Report(string message)
    {
        SendMessageToFlutter(message);
    }

    static void SendMessageToFlutter(string message)
    {
        Debug.Log("[To Flutter] " + message);
        NativeAPI.SendMessageToFlutter(message);
    }
}
