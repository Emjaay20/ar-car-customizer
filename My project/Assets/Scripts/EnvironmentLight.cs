using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.XR.ARFoundation;

/// <summary>
/// Drives the scene light from ARCore light estimation so preview paint
/// picks up the room instead of a fixed studio lamp.
/// </summary>
public class EnvironmentLight : MonoBehaviour
{
    ARCameraManager manager;
    Light keyLight;
    bool hooked;

    public static void Ensure()
    {
        if (FindAnyObjectByType<EnvironmentLight>() != null)
            return;
        var go = new GameObject("EnvironmentLight");
        go.AddComponent<EnvironmentLight>();
        DontDestroyOnLoad(go);
    }

    void OnEnable()
    {
        TryHook();
    }

    void Update()
    {
        if (!hooked)
            TryHook();
    }

    void OnDisable()
    {
        Unhook();
    }

    void TryHook()
    {
        if (hooked) return;
        manager = FindAnyObjectByType<ARCameraManager>();
        if (manager == null) return;

        manager.requestedLightEstimation =
            LightEstimation.AmbientIntensity |
            LightEstimation.AmbientColor |
            LightEstimation.AmbientSphericalHarmonics |
            LightEstimation.MainLightDirection |
            LightEstimation.MainLightIntensity;
        manager.frameReceived += OnFrame;
        hooked = true;
        keyLight = FindKeyLight();
    }

    void Unhook()
    {
        if (!hooked || manager == null) return;
        manager.frameReceived -= OnFrame;
        hooked = false;
    }

    void OnFrame(ARCameraFrameEventArgs args)
    {
        var data = args.lightEstimation;
        if (keyLight == null)
            keyLight = FindKeyLight();

        if (keyLight != null)
        {
            if (data.mainLightDirection.HasValue)
                keyLight.transform.rotation = Quaternion.LookRotation(data.mainLightDirection.Value);
            if (data.mainLightColor.HasValue)
                keyLight.color = data.mainLightColor.Value;
            if (data.averageMainLightBrightness.HasValue)
                keyLight.intensity = Mathf.Clamp(data.averageMainLightBrightness.Value, 0.55f, 1.7f);
            keyLight.shadows = LightShadows.Soft;
            keyLight.shadowStrength = 0.55f;
            EnsureFill();
        }

        if (data.ambientSphericalHarmonics.HasValue)
        {
            RenderSettings.ambientMode = AmbientMode.Skybox;
            RenderSettings.ambientProbe = data.ambientSphericalHarmonics.Value;
            return;
        }

        if (data.averageBrightness.HasValue)
        {
            var tint = data.colorCorrection ?? Color.white;
            var brightness = Mathf.Clamp(data.averageBrightness.Value, 0.2f, 1.3f);
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = tint * brightness;
        }
    }

    static Light FindKeyLight()
    {
        var lights = FindObjectsByType<Light>(FindObjectsInactive.Exclude);
        for (var i = 0; i < lights.Length; i++)
        {
            if (lights[i].type == LightType.Directional)
                return lights[i];
        }

        var go = new GameObject("EnvironmentKeyLight");
        var created = go.AddComponent<Light>();
        created.type = LightType.Directional;
        created.intensity = 1.1f;
        created.shadows = LightShadows.Soft;
        created.shadowStrength = 0.55f;
        created.transform.rotation = Quaternion.Euler(48f, -28f, 0f);
        EnsureFill();
        return created;
    }

    static void EnsureFill()
    {
        if (GameObject.Find("EnvironmentFillLight") != null)
            return;
        var go = new GameObject("EnvironmentFillLight");
        var fill = go.AddComponent<Light>();
        fill.type = LightType.Directional;
        fill.intensity = 0.28f;
        fill.color = new Color(0.82f, 0.88f, 1f);
        fill.shadows = LightShadows.None;
        go.transform.rotation = Quaternion.Euler(18f, 150f, 0f);
        Object.DontDestroyOnLoad(go);
    }
}
