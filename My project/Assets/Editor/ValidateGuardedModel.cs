#if UNITY_EDITOR
using System;
using System.IO;
using UnityEditor;
using UnityEngine;
using Unity.InferenceEngine;

/// <summary>Execute exact tensors in Unity CPU, independent of camera/graphics.</summary>
public static class ValidateGuardedModel
{
    public static void Run()
    {
        try
        {
            var directory = Path.GetFullPath(Path.Combine(Application.dataPath, "../../scratch/guarded-live/parity"));
            var asset = AssetDatabase.LoadAssetAtPath<ModelAsset>("Assets/Resources/CarSegMaskGuarded.onnx");
            if (asset == null) throw new Exception("Guarded model missing");
            using var worker = new Worker(ModelLoader.Load(asset), BackendType.CPU);
            foreach (var file in Directory.GetFiles(directory, "*.input.f32"))
            {
                var bytes = File.ReadAllBytes(file);
                var input = new float[bytes.Length / 4]; Buffer.BlockCopy(bytes, 0, input, 0, bytes.Length);
                using var tensor = new Tensor<float>(new TensorShape(1, 3, 384, 384), input);
                var timing = System.Diagnostics.Stopwatch.StartNew();
                worker.Schedule(tensor);
                var output = worker.PeekOutput() as Tensor<float>;
                using var cpu = output.ReadbackAndClone();
                var values = cpu.DownloadToArray();
                timing.Stop();
                var result = new byte[values.Length * 4]; Buffer.BlockCopy(values, 0, result, 0, result.Length);
                File.WriteAllBytes(file.Replace(".input.f32", ".unity.f32"), result);
                Debug.Log("GUARDED_PARITY_EXECUTED " + Path.GetFileName(file) + " desktop_cpu_ms=" + timing.ElapsedMilliseconds);
            }
        }
        catch (Exception ex) { Debug.LogException(ex); EditorApplication.Exit(1); }
    }
}
#endif
