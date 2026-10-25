using System;
using System.Collections;
using FlutterUnityIntegration;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.RenderGraphModule.Util;
using Unity.InferenceEngine;

/// <summary>
/// On-Device Snapchat-Style Live Car Segmentation & Tracking Engine.
/// Runs CarSegMask.onnx (dual YOLOv8 vehicle + 17-part sheet-metal segmentation with window/grille/plate cutouts)
/// Locally on the configured Sentis CPU backend, requiring zero Wi-Fi, zero laptop server, and zero cloud API requests during live AR.
/// Captures the clean AR camera feed inside URP 17 RenderGraph at BeforeRenderingTransparents (before LiveCarPaint overlay
/// and before RenderGraph.ClearGlobalBindings resets _CameraOpaqueTexture to black).
/// Features Temporal Exponential Moving Average (EMA) smoothing for jitter-free, rock-solid paint edges.
/// </summary>
public class SentisCarSegmenter : MonoBehaviour
{
    const int ModelSize = 384;

    /// <summary>
    /// URP 17 RenderGraph pass that copies the clean AR camera color buffer (after ARBackgroundRendererFeature
    /// and before the LiveCarPaint Overlay quad) directly into Sentis's 384x384 inputRT.
    /// Preserves true 1:1 aspect ratio via center-crop letterboxing to prevent vehicle squashing.
    /// </summary>
    sealed class CleanCameraCapturePass : ScriptableRenderPass
    {
        public RTHandle targetHandle;
        public bool requestCapture;
        public bool hasCaptured;
        public Vector3 capturedCamPos;
        public Quaternion capturedCamRot = Quaternion.identity;

        public CleanCameraCapturePass()
        {
            renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            if (!requestCapture || targetHandle == null || targetHandle.rt == null)
                return;

            var resourcesData = frameData.Get<UniversalResourceData>();
            if (resourcesData == null)
                return;

            TextureHandle source = resourcesData.activeColorTexture;
            if (!source.IsValid() && resourcesData.cameraOpaqueTexture.IsValid())
                source = resourcesData.cameraOpaqueTexture;
            if (!source.IsValid())
                return;

            TextureHandle dest = renderGraph.ImportTexture(targetHandle);
            if (!dest.IsValid())
                return;

            // Direct 1:1 camera capture into 384x384 input tensor.
            // The Unity camera viewport inside Flutter is already a ~1080x1040 square surface,
            // so a 1:1 blit preserves 100% of visible sheet metal with zero vertical cropping distortion.
            renderGraph.AddBlitPass(source, dest, Vector2.one, Vector2.zero, passName: "CaptureCleanARCamera");
            hasCaptured = true;
            requestCapture = false;

            var cam = Camera.main;
            if (cam != null)
            {
                capturedCamPos = cam.transform.position;
                capturedCamRot = cam.transform.rotation;
            }
        }
    }

    Model runtimeModel;
    Worker worker;
    Tensor<float> inputTensor;
    RenderTexture inputRT;
    RTHandle inputRTHandle;
    RenderTexture maskRT;
    RenderTexture smoothMaskRT;
    RenderTexture historyMaskRT;
    Material blendMaterial;
    CleanCameraCapturePass capturePass;
    bool modelLoaded;
    string loadedModelName;
    bool isInferring;

    Vector3 prevCamPos;
    Quaternion prevCamRot = Quaternion.identity;
    bool hasPrevCamPose;

    bool loopActive;
    Coroutine loopCoroutine;
    bool hasSentInitialMask;
    float lastReportTime;
    float smoothedRenderFps = 60f;

    // Anti-flicker hold: brief model dropouts (motion judder, exposure shifts) must not
    // make the paint blink. Keep showing the last accepted mask for a short grace period.
    bool reportedNoVehicle;
    float captureStartedAt;
    static RenderTexture probeRT;
    static Texture2D probeTex;

    public bool IsLoopActive => loopActive;
    public bool IsOnDeviceModelReady => modelLoaded;

    void Awake()
    {
        InitializeOnDeviceModel();
    }

    void Update()
    {
        if (loopActive && Time.unscaledDeltaTime > 0.0001f)
        {
            float instantFps = 1.0f / Time.unscaledDeltaTime;
            smoothedRenderFps = Mathf.Lerp(smoothedRenderFps, instantFps, 0.12f);
        }
    }

    void OnEnable()
    {
        RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
    }

    void OnDisable()
    {
        RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
    }

    void OnBeginCameraRendering(ScriptableRenderContext context, Camera cam)
    {
        if (!loopActive || !modelLoaded || capturePass == null || !capturePass.requestCapture)
            return;

        if (cam != Camera.main)
            return;

        var camData = cam.GetUniversalAdditionalCameraData();
        if (camData != null && camData.scriptableRenderer != null)
        {
            camData.scriptableRenderer.EnqueuePass(capturePass);
        }
    }

    static RenderTexture CreateClearedRT(int width, int height, bool enableRandomWrite)
    {
        var rt = new RenderTexture(width, height, 0, RenderTextureFormat.ARGB32)
        {
            filterMode = FilterMode.Bilinear,
            wrapMode = TextureWrapMode.Clamp,
            enableRandomWrite = enableRandomWrite
        };
        rt.Create();
        var prev = RenderTexture.active;
        RenderTexture.active = rt;
        GL.Clear(false, true, Color.black);
        RenderTexture.active = prev;
        return rt;
    }

    void InitializeOnDeviceModel()
    {
        try
        {
            // Prefer the video-tuned export (parts-anchored presence, no giant-box silhouette):
            // see ml/video_testbed.py + scratch/corolla_testbed for validation on the Corolla walkaround.
            var guardedAsset = Resources.Load<ModelAsset>("CarSegMaskGuarded");
            var tunedAsset = Resources.Load<ModelAsset>("CarSegMaskTuned");
            var modelAsset = guardedAsset != null ? guardedAsset : (tunedAsset != null ? tunedAsset : Resources.Load<ModelAsset>("CarSegMask"));
            loadedModelName = guardedAsset != null ? "CarSegMaskGuarded-v1" : (tunedAsset != null ? "CarSegMaskTuned" : "CarSegMask");
            if (modelAsset == null)
            {
                Debug.LogWarning("[SentisCarSegmenter] CarSegMask.onnx ModelAsset not found in Resources. Falling back to external mask mode.");
                return;
            }
            Debug.Log("[SentisCarSegmenter] Selected model: " + loadedModelName);
            if (guardedAsset == null && tunedAsset != null)
            {
                Debug.Log("[SentisCarSegmenter] Loaded video-tuned CarSegMaskTuned.onnx (validated on Corolla walkaround testbed).");
            }

            runtimeModel = ModelLoader.Load(modelAsset);
            // Use BackendType.CPU with time-sliced ScheduleIterable execution:
            // On Android OpenGL ES 3.0 (gles3), GPUCompute stalls on TopK/Gather readbacks.
            // Time-sliced CPU avoids scheduling the full network in one render tick; device performance must be measured.
            worker = new Worker(runtimeModel, BackendType.CPU);
            Debug.Log("[SentisCarSegmenter] On-device Sentis model initialized with BackendType.CPU (time-sliced mode).");
            inputTensor = new Tensor<float>(new TensorShape(1, 3, ModelSize, ModelSize));

            inputRT = CreateClearedRT(ModelSize, ModelSize, enableRandomWrite: false);
            inputRTHandle = RTHandles.Alloc(inputRT);

            maskRT = CreateClearedRT(ModelSize, ModelSize, enableRandomWrite: true);
            smoothMaskRT = CreateClearedRT(ModelSize, ModelSize, enableRandomWrite: false);
            historyMaskRT = CreateClearedRT(ModelSize, ModelSize, enableRandomWrite: false);

            capturePass = new CleanCameraCapturePass
            {
                targetHandle = inputRTHandle,
                requestCapture = false,
                hasCaptured = false
            };

            var blendShader = Shader.Find("ARCar/TemporalBlend");
            if (blendShader != null)
            {
                blendMaterial = new Material(blendShader);
            }

            modelLoaded = true;
            Debug.Log("[SentisCarSegmenter] On-device Sentis 256x256 dual-YOLO car segmentation engine initialized (100% offline).");
        }
        catch (Exception ex)
        {
            Debug.LogError("[SentisCarSegmenter] Failed to initialize on-device Sentis worker: " + ex);
            modelLoaded = false;
        }
    }

    public void Run()
    {
        StartLiveLoop();
    }

    public void StartLiveLoop()
    {
        if (loopActive && loopCoroutine != null)
        {
            Report("SENTIS_LIVE_STARTED");
            if (modelLoaded)
                Report("SENTIS_MASK_UPDATED");
            return;
        }
        loopActive = true;
        loopCoroutine = StartCoroutine(LiveLoopRoutine());
    }

    public void StopLiveLoop()
    {
        loopActive = false;
        hasSentInitialMask = false;
        reportedNoVehicle = false;
        if (capturePass != null)
            capturePass.requestCapture = false;
        if (loopCoroutine != null)
        {
            StopCoroutine(loopCoroutine);
            loopCoroutine = null;
        }

        var cam = Camera.main;
        if (cam != null)
        {
            var filter = LiveCarFilter.Ensure(cam);
            if (filter != null)
                filter.ClearLive();
        }
    }

    static void Report(string message)
    {
        Debug.Log("[To Flutter] " + message);
        NativeAPI.SendMessageToFlutter(message);
    }

    /// <summary>
    /// Thresholded 32x32 downsample readback of the fresh mask to detect empty/invalid outputs.
    /// Returns the mean, or float.NaN when the mask contains non-finite values (bad GPU run).
    /// </summary>
    static float ProbeMaskMean(RenderTexture mask, out float coverage)
    {
        coverage = 0f;
        try
        {
            if (probeRT == null)
            {
                probeRT = CreateClearedRT(32, 32, enableRandomWrite: false);
                probeTex = new Texture2D(32, 32, TextureFormat.RGBAFloat, false);
            }
            Graphics.Blit(mask, probeRT);
            var prev = RenderTexture.active;
            RenderTexture.active = probeRT;
            probeTex.ReadPixels(new Rect(0, 0, 32, 32), 0, 0);
            probeTex.Apply(false);
            RenderTexture.active = prev;
            var pix = probeTex.GetPixels();
            if (pix == null || pix.Length == 0)
                return float.NaN;
            double sum = 0.0;
            int selected = 0;
            bool finite = true;
            for (int i = 0; i < pix.Length; i++)
            {
                float v = pix[i].r;
                if (!float.IsFinite(v)) { finite = false; break; }
                sum += v;
                if (v > 0.16f) selected++;
            }
            coverage = selected / (float)pix.Length; // Thresholded 32x32 sample coverage, not a mean proxy.
            return finite ? (float)(sum / pix.Length) : float.NaN;
        }
        catch (Exception)
        {
            return float.NaN;
        }
    }

    public void CaptureLearningExample()
    {
        var sample = LearningSampleRecorder.TryRecord(inputRT, maskRT,
            "user-marked-last-inference", loadedModelName, true);
        if (sample != null) Report("LEARNING_SAMPLE_SAVED:" + sample);
    }

    public void NotifyExternalMaskApplied()
    {
        // External mask applied from snapshot or cloud polish
    }

    IEnumerator LiveLoopRoutine()
    {
        Report("SENTIS_LIVE_STARTED");

        if (!modelLoaded)
        {
            Report("SENTIS_NO_MODEL");
            yield break;
        }

        // The camera must keep presenting while the network runs. The S25 Ultra
        // dropped to 4 FPS because every frame waited on the full dual-YOLO graph.
        // Infer, then rest at least twice as long as that inference took, so most
        // frames are free. The paint quad warps the last mask with the camera pose
        // during the rest, which is what keeps it stuck to the car.
        var endOfFrame = new WaitForEndOfFrame();

        var inputTransform = new TextureTransform()
            .SetDimensions(ModelSize, ModelSize, 3)
            .SetTensorLayout(TensorLayout.NCHW)
            .SetCoordOrigin(CoordOrigin.TopLeft);

        var outputTransform = new TextureTransform()
            .SetTensorLayout(TensorLayout.NCHW)
            .SetCoordOrigin(CoordOrigin.TopLeft);

        while (loopActive)
        {
            var cam = Camera.main;
            if (cam != null && modelLoaded && !isInferring)
            {
                isInferring = true;

                captureStartedAt = Time.unscaledTime;
                // Request clean camera capture during URP RenderGraph (BeforeRenderingTransparents)
                if (capturePass != null)
                {
                    capturePass.hasCaptured = false;
                    capturePass.requestCapture = true;
                }

                // Wait up to 2 frames for a confirmed fresh camera capture
                yield return endOfFrame;
                if (capturePass != null && !capturePass.hasCaptured)
                {
                    yield return endOfFrame;
                }

                bool captured = capturePass != null && capturePass.hasCaptured;

                if (captured && inputRT != null && inputTensor != null && worker != null && cam != null)
                {
                    Vector3 capPos = (capturePass != null && capturePass.capturedCamPos != Vector3.zero)
                        ? capturePass.capturedCamPos
                        : cam.transform.position;
                    Quaternion capRot = (capturePass != null && capturePass.capturedCamRot != Quaternion.identity)
                        ? capturePass.capturedCamRot
                        : cam.transform.rotation;

                    IEnumerator schedule = null;
                    try
                    {
                        // 1. Convert 384x384 clean camera RT to [1, 3, 384, 384] RGB float tensor
                        TextureConverter.ToTensor(inputRT, inputTensor, inputTransform);
                        // 2. Start time-sliced scheduling; execution cost must be profiled on-device
                        schedule = worker.ScheduleIterable(inputTensor);
                    }
                    catch (Exception ex)
                    {
                        Debug.LogWarning("[SentisCarSegmenter] ScheduleIterable init error: " + ex);
                        schedule = null;
                    }

                    if (schedule != null)
                    {
                        const float sliceBudgetSec = 0.0020f; // Scheduling budget only; individual layers can exceed it
                        bool scheduleOk = true;
                        while (loopActive && scheduleOk)
                        {
                            float sliceStart = Time.realtimeSinceStartup;
                            bool hasMore = false;
                            try
                            {
                                while (Time.realtimeSinceStartup - sliceStart < sliceBudgetSec)
                                {
                                    if (!schedule.MoveNext())
                                    {
                                        hasMore = false;
                                        goto SliceDone;
                                    }
                                    hasMore = true;
                                }
                            }
                            catch (Exception ex)
                            {
                                Debug.LogWarning("[SentisCarSegmenter] Slice step error: " + ex);
                                scheduleOk = false;
                            }
                        SliceDone:
                            if (!hasMore || !scheduleOk)
                                break;
                            yield return null; // Present next 60 FPS camera frame with 6DoF pose warp
                        }

                        if (loopActive && scheduleOk && cam != null)
                        {
                            try
                            {
                                var outputTensor = worker.PeekOutput() as Tensor<float>;
                                if (outputTensor != null && maskRT != null)
                                {
                                    // 4. Render neural mask output to maskRT
                                    TextureConverter.RenderToTexture(outputTensor, maskRT, outputTransform);

                                    float coverage;
                                    float probeMean = ProbeMaskMean(maskRT, out coverage);
                                    bool stale = Time.unscaledTime - captureStartedAt > 0.75f;
                                    bool maskEmpty = !float.IsFinite(probeMean) || coverage <= 0f || stale;
                                    if (maskEmpty || coverage > 0.60f)
                                    {
                                        var sample = LearningSampleRecorder.TryRecord(inputRT, maskRT,
                                            stale ? "stale-inference" : (maskEmpty ? "empty-or-unsupported" : "large-mask"), loadedModelName);
                                        if (sample != null) Report("LEARNING_SAMPLE_SAVED:" + sample);
                                    }
                                    if (maskEmpty)
                                    {
                                        LiveCarFilter.Ensure(cam)?.ClearLive();
                                        foreach (var rt in new[] { historyMaskRT, smoothMaskRT })
                                        {
                                            if (rt == null) continue;
                                            var previous = RenderTexture.active;
                                            RenderTexture.active = rt;
                                            GL.Clear(false, true, Color.black);
                                            RenderTexture.active = previous;
                                        }
                                        hasPrevCamPose = false;
                                        hasSentInitialMask = false;
                                        if (!reportedNoVehicle)
                                            Report(stale ? "SENTIS_TRACKING_LOST" : "SENTIS_NO_VEHICLE");
                                        reportedNoVehicle = true;
                                    }

                                    if (!maskEmpty)
                                    {
                                    reportedNoVehicle = false;
                                    // 5. Motion-Adaptive Temporal EMA Smoothing:
                                    float blendFactor = 0.25f;
                                    if (hasPrevCamPose)
                                    {
                                        float angleDelta = Quaternion.Angle(capRot, prevCamRot);
                                        float posDelta = Vector3.Distance(capPos, prevCamPos);
                                        if (angleDelta > 6.0f || posDelta > 0.10f)
                                        {
                                            blendFactor = 0.95f; // Fast turn / new angle: nearly fresh frame, minimal ghosting
                                        }
                                        else if (angleDelta > 2.0f || posDelta > 0.03f)
                                        {
                                            blendFactor = 0.90f; // Walking / panning: 10% trail prevents strobing without drag
                                        }
                                        else if (angleDelta > 0.6f || posDelta > 0.01f)
                                        {
                                            blendFactor = 0.55f; // Gentle drift
                                        }
                                        else
                                        {
                                            blendFactor = 0.25f; // Stationary: rock-solid against glare
                                        }
                                    }
                                    prevCamPos = capPos;
                                    prevCamRot = capRot;
                                    hasPrevCamPose = true;

                                    RenderTexture activeMask = maskRT;
                                    if (blendMaterial != null && smoothMaskRT != null && historyMaskRT != null)
                                    {
                                        if (blendFactor > 0.01f)
                                        {
                                            blendMaterial.SetTexture("_PrevTex", historyMaskRT);
                                            blendMaterial.SetFloat("_Blend", blendFactor);
                                            Graphics.Blit(maskRT, smoothMaskRT, blendMaterial);
                                            Graphics.Blit(smoothMaskRT, historyMaskRT);
                                            activeMask = smoothMaskRT;
                                        }
                                        else
                                        {
                                            Graphics.Blit(maskRT, historyMaskRT);
                                            activeMask = maskRT;
                                        }
                                    }

                                    // 6. Apply clean scene texture + smoothed mask + 6DoF capture pose anchor to LiveCarFilter
                                    var filter = LiveCarFilter.Ensure(cam);
                                    if (filter != null)
                                    {
                                        filter.SetSceneTexture(inputRT);
                                        filter.SetMask(activeMask, 1.0f, capPos, capRot, captureStartedAt);
                                    }

                                    } // end valid fresh mask

                                    if (!maskEmpty && !hasSentInitialMask)
                                    {
                                        hasSentInitialMask = true;
                                        Report("SENTIS_MASK_UPDATED");
                                    }

                                    if (Time.unscaledTime - lastReportTime >= 1.0f)
                                    {
                                        int displayFps = Mathf.Max(0, Mathf.RoundToInt(smoothedRenderFps));
                                        Report($"SENTIS_FPS:{displayFps}");
                                        Report($"SENTIS_METRICS:{probeMean:F4}:{coverage:F4}:{Time.unscaledTime - captureStartedAt:F3}");
                                        lastReportTime = Time.unscaledTime;
                                    }
                                }
                            }
                            catch (Exception ex)
                            {
                                Debug.LogWarning("[SentisCarSegmenter] Output transfer error: " + ex);
                            }
                        }
                    }
                }

                isInferring = false;
            }

            yield return null;
        }
    }

    void OnDestroy()
    {
        RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
        loopActive = false;
        if (loopCoroutine != null)
        {
            StopCoroutine(loopCoroutine);
            loopCoroutine = null;
        }

        try
        {
            worker?.Dispose();
            worker = null;
            inputTensor?.Dispose();
            inputTensor = null;
            if (inputRTHandle != null)
            {
                RTHandles.Release(inputRTHandle);
                inputRTHandle = null;
            }
            if (inputRT != null)
            {
                inputRT.Release();
                Destroy(inputRT);
                inputRT = null;
            }
            if (maskRT != null)
            {
                maskRT.Release();
                Destroy(maskRT);
                maskRT = null;
            }
            if (smoothMaskRT != null)
            {
                smoothMaskRT.Release();
                Destroy(smoothMaskRT);
                smoothMaskRT = null;
            }
            if (historyMaskRT != null)
            {
                historyMaskRT.Release();
                Destroy(historyMaskRT);
                historyMaskRT = null;
            }
            if (blendMaterial != null)
            {
                Destroy(blendMaterial);
                blendMaterial = null;
            }
        }
        catch (Exception) {}
    }
}
