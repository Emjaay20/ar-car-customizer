using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 3D Spatial Damage Pinning for AR Vehicle Inspection.
/// Inspired by yudhisteer/Augmented-Reality-for-Preventive-Maintenance.
/// Anchors 3D floating markers and severity indicators directly to vehicle coordinates.
/// </summary>
public class SpatialDamageAnchorManager : MonoBehaviour
{
    [Serializable]
    public class DamagePinData
    {
        public string id;
        public string damageType;
        public string severity;
        public string affectedPanel;
        public float areaPercentage;
        public float x;
        public float y;
        public float z;
        public string recommendedAction;
    }

    [Serializable]
    public class DamagePayload
    {
        public List<DamagePinData> damages;
    }

    readonly List<GameObject> activePins = new List<GameObject>();
    GameObject carTarget;

    public static SpatialDamageAnchorManager Instance { get; private set; }

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
        }
    }

    public void SetCarTarget(GameObject car)
    {
        carTarget = car;
    }

    /// <summary>
    /// Spawns 3D spatial pins onto the vehicle based on JSON assessment payload.
    /// </summary>
    public void DisplayDamagePins(string jsonPayload)
    {
        ClearPins();

        if (string.IsNullOrEmpty(jsonPayload))
            return;

        try
        {
            var payload = JsonUtility.FromJson<DamagePayload>(jsonPayload);
            if (payload == null || payload.damages == null)
                return;

            Transform parentTransform = carTarget != null ? carTarget.transform : transform;

            foreach (var pinData in payload.damages)
            {
                CreatePin(pinData, parentTransform);
            }

            Debug.Log($"[SpatialDamageAnchorManager] Spawned {activePins.Count} damage pins.");
        }
        catch (Exception ex)
        {
            Debug.LogError($"[SpatialDamageAnchorManager] Failed to parse damage pins: {ex.Message}");
        }
    }

    void CreatePin(DamagePinData data, Transform parent)
    {
        var pinObj = new GameObject($"DamagePin_{data.affectedPanel}_{data.damageType}");
        pinObj.transform.SetParent(parent, false);
        pinObj.transform.localPosition = new Vector3(data.x, data.y, data.z);

        // Visual marker: glowing sphere / badge
        var marker = GameObject.CreatePrimitive(PrimitiveType.Sphere);
        marker.transform.SetParent(pinObj.transform, false);
        marker.transform.localScale = new Vector3(0.12f, 0.12f, 0.12f);

        var renderer = marker.GetComponent<Renderer>();
        if (renderer != null)
        {
            var mat = new Material(Shader.Find("Universal Render Pipeline/Lit") ?? Shader.Find("Standard"));
            mat.color = GetSeverityColor(data.severity);
            if (mat.HasProperty("_EmissionColor"))
            {
                mat.EnableKeyword("_EMISSION");
                mat.SetColor("_EmissionColor", GetSeverityColor(data.severity) * 1.5f);
            }
            renderer.sharedMaterial = mat;
        }

        // Add a collider for tap interactions
        var collider = marker.GetComponent<SphereCollider>();
        if (collider != null)
        {
            collider.isTrigger = true;
        }

        activePins.Add(pinObj);
    }

    Color GetSeverityColor(string severity)
    {
        switch ((severity ?? "").ToUpperInvariant())
        {
            case "MINOR":
                return new Color(0.2f, 0.85f, 0.3f); // Green / Lime
            case "MODERATE":
                return new Color(1.0f, 0.75f, 0.1f); // Amber / Yellow
            case "SEVERE":
            case "CRITICAL":
                return new Color(0.95f, 0.15f, 0.15f); // High-alert Red
            default:
                return new Color(0.2f, 0.6f, 1.0f); // Cyan default
        }
    }

    public void ClearPins()
    {
        foreach (var pin in activePins)
        {
            if (pin != null)
                Destroy(pin);
        }
        activePins.Clear();
    }

    public void ToggleVisibility(bool visible)
    {
        foreach (var pin in activePins)
        {
            if (pin != null)
                pin.SetActive(visible);
        }
    }
}
