using FlutterUnityIntegration;
using UnityEngine;

/// <summary>
/// On-device segmentation hook. Compiles without Inference Engine.
/// Enable it by installing com.unity.ai.inference, adding scripting define ARCAR_INFERENCE_ENGINE,
/// and placing a ModelAsset named CarSegMask in a Resources folder.
/// ONNX contract: input float32 NCHW 1x3x256x256 RGB 0..1, output a 256x256 paint probability.
/// Do not assign a raw YOLOv8-seg graph; export a model that already outputs the body mask.
/// </summary>
public class SentisCarSegmenter : MonoBehaviour
{
    public void Run()
    {
#if ARCAR_INFERENCE_ENGINE
        StartCoroutine(RunInference());
#else
        Report("SENTIS_UNAVAILABLE:Install com.unity.ai.inference, add scripting define ARCAR_INFERENCE_ENGINE, and place a 256x256 mask ModelAsset at Resources/CarSegMask.");
#endif
    }

    static void Report(string message)
    {
        Debug.Log("[To Flutter] " + message);
        NativeAPI.SendMessageToFlutter(message);
    }

#if ARCAR_INFERENCE_ENGINE
    const int Size = 256;
    Unity.InferenceEngine.Worker worker;

    System.Collections.IEnumerator RunInference()
    {
        var modelAsset = Resources.Load<Unity.InferenceEngine.ModelAsset>("CarSegMask");
        if (modelAsset == null)
        {
            Report("SENTIS_NO_MODEL:Resources/CarSegMask is missing.");
            yield break;
        }

        Texture2D frame = null;
        string grabError = null;
        yield return GrabCameraFrame(value => frame = value, reason => grabError = reason);
        if (frame == null)
        {
            Report(grabError ?? "SENTIS_NO_FRAME");
            yield break;
        }

        var runtime = Unity.InferenceEngine.ModelLoader.Load(modelAsset);
        worker ??= new Unity.InferenceEngine.Worker(runtime, Unity.InferenceEngine.BackendType.GPUCompute);
        using var input = new Unity.InferenceEngine.Tensor<float>(new Unity.InferenceEngine.TensorShape(1, 3, Size, Size));
        Unity.InferenceEngine.TextureConverter.ToTensor(frame, input);
        worker.Schedule(input);

        var output = worker.PeekOutput() as Unity.InferenceEngine.Tensor<float>;
        var values = output != null ? output.DownloadToArray() : null;
        if (values == null || values.Length < Size * Size)
        {
            Report("SENTIS_BAD_OUTPUT:expected a 256x256 paint mask, not a raw detection graph.");
            yield break;
        }

        var mask = new Texture2D(Size, Size, TextureFormat.R8, false);
        var pixels = new byte[Size * Size];
        var offset = values.Length - pixels.Length;
        for (var i = 0; i < pixels.Length; i++)
            pixels[i] = values[offset + i] >= 0.5f ? (byte)255 : (byte)0;
        mask.LoadRawTextureData(pixels);
        mask.Apply();

        var filter = LiveCarFilter.Ensure(Camera.main);
        if (filter == null || !filter.SetMask(mask))
        {
            Report("MASK_FAILED:no-camera");
            yield break;
        }
        Report("MASK_APPLIED:sentis");
    }

    static System.Collections.IEnumerator GrabCameraFrame(System.Action<Texture2D> onFrame, System.Action<string> onError)
    {
        var manager = FindAnyObjectByType<UnityEngine.XR.ARFoundation.ARCameraManager>();
        if (manager == null || !manager.TryAcquireLatestCpuImage(out var image))
        {
            onError("SENTIS_NO_FRAME:AR camera has no CPU image yet.");
            onFrame(null);
            yield break;
        }

        var conversion = new UnityEngine.XR.ARSubsystems.XRCpuImage.ConversionParams
        {
            inputRect = new RectInt(0, 0, image.width, image.height),
            outputDimensions = new Vector2Int(Size, Size),
            outputFormat = TextureFormat.RGB24,
            transformation = UnityEngine.XR.ARSubsystems.XRCpuImage.Transformation.MirrorY,
        };
        var buffer = new Unity.Collections.NativeArray<byte>(
            image.GetConvertedDataSize(conversion),
            Unity.Collections.Allocator.Temp);
        try
        {
            image.Convert(conversion, buffer);
            var texture = new Texture2D(Size, Size, TextureFormat.RGB24, false);
            texture.LoadRawTextureData(buffer);
            texture.Apply();
            onFrame(texture);
        }
        finally
        {
            buffer.Dispose();
            image.Dispose();
        }
        yield return null;
    }

    void OnDestroy()
    {
        worker?.Dispose();
    }
#endif
}
