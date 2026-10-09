using System;
using System.Collections;
using System.Collections.Generic;
using System.Threading.Tasks;
using GLTFast;
using UnityEngine;

[Serializable]
public class PartRequest
{
    public string type;
    public string name;
    public string url;
    public string anchor;
}

[Serializable]
public class Keypoint
{
    public string name;
    public float x;
    public float y;
}

[Serializable]
public class KeypointFrame
{
    public Keypoint[] points;
}

[Serializable]
public class BridgeFrame
{
    public string maskPng;
    public Keypoint[] points;
}

/// <summary>
/// Places rim and spoiler stand-ins on the preview model, and screen-space
/// markers when a segmentation bridge frame supplies image keypoints.
/// Trunk is the -Z face of the bounds. Many glTF cars face +Z, so that is the rear.
/// </summary>
public static class PartAnchorRig
{
    public static string ReadType(string json)
    {
        var request = JsonUtility.FromJson<PartRequest>(json);
        return request != null && !string.IsNullOrEmpty(request.type) ? request.type : "";
    }

    public static string LegacyRequest(string type, string spec)
    {
        if (!string.IsNullOrEmpty(spec) && spec.TrimStart().StartsWith("{"))
            return spec;

        return JsonUtility.ToJson(new PartRequest
        {
            type = type,
            name = spec,
            url = string.IsNullOrEmpty(spec) ? "primitive:" + type.ToLowerInvariant() : spec,
            anchor = type == "SPOILER" ? "trunk" : "wheels",
        });
    }

    public static IEnumerator Attach(GameObject car, string json, Action<string> report)
    {
        var request = JsonUtility.FromJson<PartRequest>(json);
        if (request == null || string.IsNullOrEmpty(request.type))
        {
            report("PART_FAILED:bad-json");
            yield break;
        }
        if (car == null)
        {
            report("PART_FAILED:no-car");
            yield break;
        }

        EnsureAnchors(car);
        ClearParts(car, request.type);
        var anchors = AnchorsFor(car, request.anchor, request.type);
        if (anchors.Count == 0)
        {
            report("PART_FAILED:no-anchor:" + request.type);
            yield break;
        }

        if (UsePrimitive(request.url))
        {
            foreach (var anchor in anchors)
                SpawnPrimitive(anchor, request.type);
            report("PART_ATTACHED:" + request.type + ":" + (string.IsNullOrEmpty(request.name) ? "stand-in" : request.name));
            yield break;
        }

        GameObject loaded = null;
        yield return LoadGlb(request.url, value => loaded = value);
        if (loaded == null)
        {
            foreach (var anchor in anchors)
                SpawnPrimitive(anchor, request.type);
            report("PART_GLB_FAILED:" + request.type + ":used stand-in");
            yield break;
        }

        for (var i = 0; i < anchors.Count; i++)
        {
            var copy = i == anchors.Count - 1 ? loaded : UnityEngine.Object.Instantiate(loaded);
            copy.name = "part-" + request.type;
            copy.transform.SetParent(anchors[i], false);
            copy.transform.localPosition = Vector3.zero;
            copy.transform.localRotation = Quaternion.identity;
            FitWorldSize(copy, request.type == "SPOILER" ? 0.4f : 0.22f);
        }
        report("PART_ATTACHED:" + request.type + ":" + request.url);
    }

    public static GameObject PlaceImageKeypoints(Keypoint[] points, Camera camera)
    {
        var existing = GameObject.Find("LiveKeypoints");
        if (existing != null)
            UnityEngine.Object.Destroy(existing);
        if (camera == null || points == null)
            return null;

        var root = new GameObject("LiveKeypoints");
        foreach (var point in points)
        {
            var marker = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            marker.name = "keypoint-" + point.name;
            var collider = marker.GetComponent<Collider>();
            if (collider != null)
                UnityEngine.Object.Destroy(collider);
            marker.transform.SetParent(root.transform, false);
            marker.transform.position = ViewportPoint(camera, point, 1.45f);
            marker.transform.localScale = Vector3.one * 0.04f;
        }
        return root;
    }

    public static void AttachToImageKeypoints(Keypoint[] points, Camera camera, IList<string> partJson, Action<string> report)
    {
        if (camera == null || points == null || partJson == null)
            return;

        var root = GameObject.Find("LiveKeypoints");
        if (root == null)
            root = PlaceImageKeypoints(points, camera);
        if (root == null)
            return;

        foreach (var json in partJson)
        {
            var request = JsonUtility.FromJson<PartRequest>(json);
            if (request == null || string.IsNullOrEmpty(request.type))
                continue;

            var wanted = request.type == "SPOILER" || request.anchor == "trunk" ? "trunk" : "wheel";
            var attached = 0;
            foreach (var point in points)
            {
                if (!NameMatches(point.name, wanted))
                    continue;
                var anchor = new GameObject("live-anchor-" + point.name);
                anchor.transform.SetParent(root.transform, false);
                anchor.transform.position = ViewportPoint(camera, point, 1.35f);
                SpawnPrimitive(anchor.transform, request.type);
                attached++;
            }
            if (attached > 0)
                report("LIVE_PART_ATTACHED:" + request.type + ":stand-in");
        }
    }

    static Vector3 ViewportPoint(Camera camera, Keypoint point, float depth)
    {
        return camera.ViewportToWorldPoint(new Vector3(
            Mathf.Clamp01(point.x),
            1f - Mathf.Clamp01(point.y),
            depth));
    }

    static bool NameMatches(string pointName, string wanted)
    {
        if (string.IsNullOrEmpty(pointName)) return false;
        var name = pointName.ToLowerInvariant();
        return wanted == "wheel" ? name.Contains("wheel") : name.Contains("trunk");
    }

    public static void EnsureAnchors(GameObject car)
    {
        if (car.transform.Find("anchor-trunk") != null)
            return;
        if (!TryBounds(car, out var bounds))
            return;

        var insetX = bounds.size.x * 0.18f;
        var insetZ = bounds.size.z * 0.18f;
        var y = bounds.min.y + bounds.size.y * 0.18f;
        AddAnchor(car, "anchor-wheel-fl", new Vector3(bounds.min.x + insetX, y, bounds.max.z - insetZ));
        AddAnchor(car, "anchor-wheel-fr", new Vector3(bounds.max.x - insetX, y, bounds.max.z - insetZ));
        AddAnchor(car, "anchor-wheel-rl", new Vector3(bounds.min.x + insetX, y, bounds.min.z + insetZ));
        AddAnchor(car, "anchor-wheel-rr", new Vector3(bounds.max.x - insetX, y, bounds.min.z + insetZ));
        AddAnchor(car, "anchor-trunk", new Vector3(bounds.center.x, bounds.max.y, bounds.min.z + bounds.size.z * 0.08f));
    }

    static void AddAnchor(GameObject car, string name, Vector3 world)
    {
        var anchor = new GameObject(name);
        anchor.transform.SetParent(car.transform, true);
        anchor.transform.position = world;
        anchor.transform.rotation = Quaternion.identity;
    }

    static List<Transform> AnchorsFor(GameObject car, string anchor, string type)
    {
        var key = string.IsNullOrEmpty(anchor)
            ? (type == "SPOILER" ? "trunk" : "wheels")
            : anchor;
        string[] names;
        if (key == "wheels")
            names = new[] { "anchor-wheel-fl", "anchor-wheel-fr", "anchor-wheel-rl", "anchor-wheel-rr" };
        else if (key == "trunk")
            names = new[] { "anchor-trunk" };
        else
            names = new[] { key.StartsWith("anchor-") ? key : "anchor-" + key };

        var found = new List<Transform>();
        foreach (var name in names)
        {
            var child = car.transform.Find(name);
            if (child != null)
                found.Add(child);
        }
        return found;
    }

    static void ClearParts(GameObject car, string type)
    {
        var doomed = new List<GameObject>();
        foreach (var child in car.GetComponentsInChildren<Transform>(true))
        {
            if (child.name == "part-" + type)
                doomed.Add(child.gameObject);
        }
        foreach (var part in doomed)
            UnityEngine.Object.Destroy(part);
    }

    static bool UsePrimitive(string url)
    {
        return string.IsNullOrEmpty(url) || url.StartsWith("primitive:") || url.StartsWith("color:");
    }

    static GameObject SpawnPrimitive(Transform anchor, string type)
    {
        var spoiler = type == "SPOILER";
        var part = GameObject.CreatePrimitive(spoiler ? PrimitiveType.Cube : PrimitiveType.Cylinder);
        part.name = "part-" + type;
        var collider = part.GetComponent<Collider>();
        if (collider != null)
            UnityEngine.Object.Destroy(collider);

        part.transform.SetParent(anchor, false);
        part.transform.localPosition = Vector3.zero;
        part.transform.localRotation = spoiler ? Quaternion.identity : Quaternion.Euler(0f, 0f, 90f);
        part.transform.localScale = Vector3.one;
        var lossy = part.transform.lossyScale;
        part.transform.localScale = spoiler
            ? WorldScale(lossy, 0.42f, 0.04f, 0.12f)
            : WorldScale(lossy, 0.22f, 0.07f, 0.22f);

        var shader = Shader.Find("Universal Render Pipeline/Lit");
        if (shader == null)
            shader = Shader.Find("Standard");
        if (shader != null)
        {
            var color = spoiler ? new Color(0.05f, 0.05f, 0.05f) : new Color(0.55f, 0.56f, 0.58f);
            var material = new Material(shader) { name = spoiler ? "spoiler" : "rim", color = color };
            if (material.HasProperty("_BaseColor"))
                material.SetColor("_BaseColor", color);
            part.GetComponent<Renderer>().sharedMaterial = material;
        }
        return part;
    }

    static Vector3 WorldScale(Vector3 lossy, float x, float y, float z)
    {
        return new Vector3(
            x / Mathf.Max(lossy.x, 0.0001f),
            y / Mathf.Max(lossy.y, 0.0001f),
            z / Mathf.Max(lossy.z, 0.0001f));
    }

    static IEnumerator LoadGlb(string url, Action<GameObject> done)
    {
        var holder = new GameObject("part-loading");
        var gltf = holder.AddComponent<GltfAsset>();
        gltf.LoadOnStartup = false;
        Task<bool> task;
        try
        {
            task = gltf.Load(url);
        }
        catch (Exception)
        {
            UnityEngine.Object.Destroy(holder);
            done(null);
            yield break;
        }

        while (!task.IsCompleted)
            yield return null;

        if (task.IsFaulted || task.IsCanceled || !task.Result)
        {
            UnityEngine.Object.Destroy(holder);
            done(null);
            yield break;
        }
        done(holder);
    }

    static void FitWorldSize(GameObject part, float targetMeters)
    {
        var renderers = part.GetComponentsInChildren<Renderer>(true);
        if (renderers.Length == 0) return;
        var bounds = renderers[0].bounds;
        for (var i = 1; i < renderers.Length; i++)
            bounds.Encapsulate(renderers[i].bounds);
        var max = Mathf.Max(bounds.size.x, bounds.size.y, bounds.size.z);
        if (max < 0.001f) return;
        var factor = targetMeters / max;
        part.transform.localScale = part.transform.localScale * factor;
    }

    static bool TryBounds(GameObject car, out Bounds bounds)
    {
        var renderers = car.GetComponentsInChildren<Renderer>(true);
        if (renderers.Length == 0)
        {
            bounds = new Bounds(car.transform.position, Vector3.zero);
            return false;
        }
        bounds = renderers[0].bounds;
        for (var i = 1; i < renderers.Length; i++)
            bounds.Encapsulate(renderers[i].bounds);
        return true;
    }
}
