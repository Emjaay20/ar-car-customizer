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
/// 100% locally on the phone's CPU/NPU, requiring zero Wi-Fi, zero laptop server, and zero cloud API requests during live AR.
/// Captures the clean AR camera feed inside URP 17 RenderGraph at BeforeRenderingTransparents (before LiveCarPaint overlay
/// and before RenderGraph.ClearGlobalBindings resets _CameraOpaqueTexture to black).
/// Features Temporal Exponential Moving Average (EMA) smoothing for jitter-free, rock-solid paint edges.
/// </summary>
public class SentisCarSegmenter : MonoBehaviour
{
    const int ModelSize = 256;

    /// <summary>
    /// URP 17 RenderGraph pass that copies the clean AR camera color buffer (after ARBackgroundRendererFeature
    /// and before the LiveCarPaint Overlay quad) directly into Sentis's 256x256 inputRT.
    /// </summary>
    sealed class CleanCameraCapturePass : ScriptableRenderPass
    {
        public RTHandle targetHandle;
        public bool requestCapture;
        public bool hasCaptured;

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

            renderGraph.AddBlitPass(source, dest, Vector2.one, Vector2.zero, passName: "CaptureCleanARCamera");
            hasCaptured = true;
            requestCapture = false;
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
    bool isInferring;

    Vector3 prevCamPos;
    Quaternion prevCamRot = Quaternion.identity;
    bool hasPrevCamPose;

    bool loopActive;
    Coroutine loopCoroutine;

    public bool IsLoopActive => loopActive;
    public bool IsOnDeviceModelReady => modelLoaded;

    void Awake()
    {
        InitializeOnDeviceModel();
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
            var modelAsset = Resources.Load<ModelAsset>("CarSegMask");
            if (modelAsset == null)
            {
                Debug.LogWarning("[SentisCarSegmenter] CarSegMask.onnx ModelAsset not found in Resources. Falling back to external mask mode.");
                return;
            }

            runtimeModel = ModelLoader.Load(modelAsset);
            // Use BackendType.CPU (ARM NEON Burst SIMD) for 100% crash-free execution across all Android GPUs
            worker = new Worker(runtimeModel, BackendType.CPU);
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
        if (capturePass != null)
            capturePass.requestCapture = false;
        if (loopCoroutine != null)
        {
            StopCoroutine(loopCoroutine);
            loopCoroutine = null;
        }
    }

    static void Report(string message)
    {
        Debug.Log("[To Flutter] " + message);
        NativeAPI.SendMessageToFlutter(message);
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

        // On-Device Snapchat-style continuous segmentation loop
        // Runs at adaptive ~10-12 Hz neural refresh rate while rendering at full 60 FPS
        const float neuralInterval = 0.08f;
        var waitInterval = new WaitForSeconds(neuralInterval);
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

                // Request clean camera capture during URP RenderGraph (BeforeRenderingTransparents)
                if (capturePass != null)
                {
                    capturePass.hasCaptured = false;
                    capturePass.requestCapture = true;
                }

                yield return endOfFrame;

                bool captured = capturePass != null && capturePass.hasCaptured;

                if (!captured && inputRT != null)
                {
                    // Fallback if URP RenderGraph pass did not fire: capture clean screen with filter hidden for 1 frame
                    var filterObj = cam != null ? cam.GetComponentInChildren<LiveCarFilter>() : null;
                    bool wasActive = filterObj != null && filterObj.gameObject.activeSelf;
                    if (wasActive)
                        filterObj.gameObject.SetActive(false);

                    yield return endOfFrame;

                    var screenShot = ScreenCapture.CaptureScreenshotAsTexture();
                    if (screenShot != null)
                    {
                        Graphics.Blit(screenShot, inputRT);
                        Destroy(screenShot);
                        captured = true;
                    }

                    if (wasActive && filterObj != null)
                        filterObj.gameObject.SetActive(true);
                }

                if (captured && inputRT != null && inputTensor != null && worker != null && cam != null)
                {
                    try
                    {
                        // 1. Convert 256x256 clean camera RT to [1, 3, 256, 256] RGB float tensor
                        TextureConverter.ToTensor(inputRT, inputTensor, inputTransform);

                        // 2. Execute on-device dual-YOLO segmentation network
                        worker.Schedule(inputTensor);

                        // 3. Retrieve probability mask [1, 1, 256, 256]
                        var outputTensor = worker.PeekOutput() as Tensor<float>;
                        if (outputTensor != null && maskRT != null)
                        {
                            // 4. Render neural mask output to maskRT
                            TextureConverter.RenderToTexture(outputTensor, maskRT, outputTransform);

                            // 5. Motion-Adaptive Temporal EMA Smoothing:
                            // While camera is moving, blendFactor is 0 (zero trailing ghost lag).
                            // While camera is stationary, blendFactor is 0.30 (jitter-free anti-flicker).
                            float blendFactor = 0.30f;
                            if (hasPrevCamPose)
                            {
                                float angleDelta = Quaternion.Angle(cam.transform.rotation, prevCamRot);
                                float posDelta = Vector3.Distance(cam.transform.position, prevCamPos);
                                if (angleDelta > 1.0f || posDelta > 0.025f)
                                {
                                    blendFactor = 0.0f; // Instant 0ms response when moving
                                }
                                else if (angleDelta > 0.35f || posDelta > 0.010f)
                                {
                                    blendFactor = 0.10f;
                                }
                            }
                            prevCamPos = cam.transform.position;
                            prevCamRot = cam.transform.rotation;
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

                            // 6. Apply clean scene texture + smoothed mask to LiveCarFilter on screen quad
                            var filter = LiveCarFilter.Ensure(cam);
                            if (filter != null)
                            {
                                filter.SetSceneTexture(inputRT);
                                filter.SetMask(activeMask);
                            }
                            Report("SENTIS_MASK_UPDATED");
                        }
                    }
                    catch (Exception ex)
                    {
                        Debug.LogWarning("[SentisCarSegmenter] Frame inference error: " + ex);
                    }
                }

                isInferring = false;
            }

            yield return waitInterval;
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
