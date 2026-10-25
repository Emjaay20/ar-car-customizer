using System;
using System.IO;
using System.Security.Cryptography;
using UnityEngine;

/// <summary>Opt-in, bounded local review queue. Predictions are never training labels.</summary>
public static class LearningSampleRecorder
{
    public static bool Enabled;
    static float nextCaptureAt;
    static readonly string session = Guid.NewGuid().ToString("N");

    [Serializable]
    class Sample
    {
        public string id, image_sha256, scene, reason, model;
        public bool reviewed = false;
        public bool prediction_is_ground_truth = false;
    }

    static byte[] Snapshot(RenderTexture source)
    {
        var previous = RenderTexture.active;
        var texture = new Texture2D(source.width, source.height, TextureFormat.RGB24, false);
        try
        {
            RenderTexture.active = source;
            texture.ReadPixels(new Rect(0, 0, source.width, source.height), 0, 0);
            texture.Apply(false);
            return texture.EncodeToPNG();
        }
        finally { RenderTexture.active = previous; UnityEngine.Object.Destroy(texture); }
    }

    public static string TryRecord(RenderTexture cleanInput, RenderTexture prediction, string reason, string model, bool userMarked = false)
    {
        if ((!Enabled && !userMarked) || cleanInput == null || (!userMarked && Time.unscaledTime < nextCaptureAt)) return null;
        nextCaptureAt = Time.unscaledTime + 15f;
        var root = Path.Combine(Application.persistentDataPath, "learning_queue");
        try
        {
            Directory.CreateDirectory(root);
            if (Directory.GetDirectories(root).Length >= 100) return null;
            var bytes = Snapshot(cleanInput);
            string hash;
            using (var sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
            var id = hash.Substring(0, 24);
            var folder = Path.Combine(root, id);
            if (Directory.Exists(folder)) return null;
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, "image.png"), bytes);
            if (prediction != null) File.WriteAllBytes(Path.Combine(folder, "prediction.png"), Snapshot(prediction));
            File.WriteAllText(Path.Combine(folder, "sample.json"), JsonUtility.ToJson(new Sample {
                id = id, image_sha256 = hash, scene = session, reason = reason, model = model
            }, true));
            return id;
        }
        catch (Exception ex) { Debug.LogWarning("Learning queue write failed: " + ex.Message); return null; }
    }
}
