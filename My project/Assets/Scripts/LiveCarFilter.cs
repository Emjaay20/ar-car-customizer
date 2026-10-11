using UnityEngine;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Screen-space tint. Invisible until a segmentation mask is supplied.
/// The mask's red channel is the paint region; windows and tires should already be black.
/// </summary>
public class LiveCarFilter : MonoBehaviour
{
    const float Distance = 0.35f;

    Material material;
    bool reportedMissingShader;
    bool maskApplied;
    float metallic = 0.08f;
    float smoothness = 0.92f;
    float strength = 0.95f;
    float panel;

    public static LiveCarFilter Ensure(Camera camera)
    {
        if (camera == null) return null;

        var camData = camera.GetComponent<UniversalAdditionalCameraData>();
        if (camData != null)
        {
            camData.requiresColorOption = CameraOverrideOption.On;
            camData.requiresColorTexture = true;
        }

        var existing = camera.GetComponentInChildren<LiveCarFilter>(true);
        if (existing != null) return existing;

        var quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
        quad.name = "LiveCarPaint";
        var collider = quad.GetComponent<Collider>();
        if (collider != null) Destroy(collider);
        quad.transform.SetParent(camera.transform, false);
        return quad.AddComponent<LiveCarFilter>();
    }

    void LateUpdate()
    {
        var camera = GetComponentInParent<Camera>();
        if (camera == null) return;

        // ARCore overrides camera.projectionMatrix directly without updating camera.fieldOfView.
        // Compute exact quad dimensions and principal-point offset from projectionMatrix so UV [0..1]
        // maps 1:1 to the camera viewport corners (-1..+1 NDC).
        var proj = camera.projectionMatrix;
        float m00 = Mathf.Abs(proj.m00) > 1e-4f ? proj.m00 : (1f / (Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad) * camera.aspect));
        float m11 = Mathf.Abs(proj.m11) > 1e-4f ? proj.m11 : (1f / Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad));
        float width = (2f * Distance) / Mathf.Abs(m00);
        float height = (2f * Distance) / Mathf.Abs(m11);
        float offsetX = (proj.m02 * Distance) / m00;
        float offsetY = (proj.m12 * Distance) / m11;

        transform.localPosition = new Vector3(offsetX, offsetY, Distance);
        transform.localRotation = Quaternion.identity;
        transform.localScale = new Vector3(width, height, 1f);
    }

    public bool SetTint(Color color)
    {
        if (!EnsureMaterial()) return false;
        material.SetColor("_Tint", color);
        ApplyFinish();
        return true;
    }

    public void SetFinish(float metallic, float smoothness, float strength, float panel)
    {
        this.metallic = metallic;
        this.smoothness = smoothness;
        this.strength = strength;
        this.panel = panel;
        ApplyFinish();
    }

    public bool SetMask(Texture2D mask)
    {
        if (!EnsureMaterial()) return false;
        maskApplied = mask != null;
        material.SetTexture("_MaskTex", mask != null ? mask : Texture2D.blackTexture);
        ApplyFinish();
        return mask != null;
    }

    public void SetSceneTexture(Texture sceneTex)
    {
        if (!EnsureMaterial()) return;
        if (sceneTex != null)
            material.SetTexture("_SceneTex", sceneTex);
    }

    void ApplyFinish()
    {
        if (material == null) return;
        material.SetFloat("_Metallic", metallic);
        material.SetFloat("_Smoothness", smoothness);
        material.SetFloat("_Panel", panel);
        material.SetFloat("_Strength", maskApplied ? strength : 0f);
    }

    bool EnsureMaterial()
    {
        if (material != null) return true;

        var source = Resources.Load<Material>("LiveCarPaint");
        if (source != null)
            material = new Material(source);
        else
        {
            var shader = Shader.Find("ARCar/LivePaint");
            if (shader != null)
                material = new Material(shader);
        }

        if (material == null)
        {
            if (!reportedMissingShader)
            {
                reportedMissingShader = true;
                Debug.LogError("ARCar/LivePaint shader is missing from the build.");
            }
            return false;
        }

        var renderer = GetComponent<Renderer>();
        if (renderer != null)
            renderer.sharedMaterial = material;
        ApplyFinish();
        return true;
    }
}
