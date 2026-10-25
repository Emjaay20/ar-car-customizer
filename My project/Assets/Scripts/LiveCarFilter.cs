using UnityEngine;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Screen-space car paint and locked showroom frame controller.
/// - SEARCHING/CAPTURING: LiveCarPaint quad applies mask tint with Dichromatic shader.
/// - LOCKED: ShowroomLockedFrame quad cross-fades into 960px polished composite, turning live shader OFF.
///   Subtle micro-warp compensates for small head movements (1-3°); clamps warp on larger delta without dropping the image.
/// </summary>
public class LiveCarFilter : MonoBehaviour
{
    const float Distance = 0.35f;

    Material material;
    bool reportedMissingShader;
    bool maskApplied;
    float metallic = 0.08f;
    float smoothness = 0.92f;
    float strength = 1.0f;
    float panel;
    float finishMode = 0f;
    float debugMaskMode = 0f;
    bool captureCleanHide = false;

    // Mask viewpoint anchor tracking
    Vector3 maskCamPos;
    Quaternion maskCamRot = Quaternion.identity;
    bool hasMaskPose = false;
    float motionFade = 1.0f;

    // Locked Showroom Full-Frame Quad
    GameObject lockedQuad;
    Material lockedMaterial;
    bool isLocked = false;
    Vector3 lockedCamPos;
    Quaternion lockedCamRot;
    float fadeAlpha = 0f;
    float targetAlpha = 0f;

    public bool IsLocked => isLocked;

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

    void Update()
    {
        if (lockedMaterial != null && Mathf.Abs(fadeAlpha - targetAlpha) > 0.005f)
        {
            fadeAlpha = Mathf.MoveTowards(fadeAlpha, targetAlpha, Time.unscaledDeltaTime * 5.0f);
            lockedMaterial.SetFloat("_Alpha", fadeAlpha);
            if (fadeAlpha <= 0.005f && targetAlpha == 0f)
            {
                isLocked = false;
                if (lockedQuad != null) lockedQuad.SetActive(false);
                ApplyFinish();
            }
        }
    }

    void LateUpdate()
    {
        var camera = GetComponentInParent<Camera>();
        if (camera == null) return;

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

        if (material != null && maskApplied)
        {
            material.SetFloat("_Strength", (maskApplied && !isLocked && !captureCleanHide) ? strength : 0f);

            // 6DoF Camera Reprojection: keeps the neural mask locked to vehicle sheet metal
            // between inference frames as the phone pans or rotates (Snapchat-style tracking)
            if (hasMaskPose)
            {
                Quaternion deltaRot = Quaternion.Inverse(camera.transform.rotation) * maskCamRot;
                Vector3 euler = deltaRot.eulerAngles;
                float yawRad = Mathf.DeltaAngle(0f, euler.y) * Mathf.Deg2Rad;
                float pitchRad = Mathf.DeltaAngle(0f, euler.x) * Mathf.Deg2Rad;
                Vector3 localDeltaPos = camera.transform.InverseTransformPoint(maskCamPos);

                float tanHalfFovY = Mathf.Max(0.001f, Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad));
                float tanHalfFovX = tanHalfFovY * camera.aspect;

                float uvShiftX = (Mathf.Tan(yawRad) + (localDeltaPos.x / 2.8f)) / (2f * tanHalfFovX);
                float uvShiftY = (-Mathf.Tan(pitchRad) + (localDeltaPos.y / 2.8f)) / (2f * tanHalfFovY);

                uvShiftX = Mathf.Clamp(uvShiftX, -0.35f, 0.35f);
                uvShiftY = Mathf.Clamp(uvShiftY, -0.35f, 0.35f);
                material.SetVector("_MaskUVOffset", new Vector4(uvShiftX, uvShiftY, 0f, 0f));
            }
        }

        if (lockedQuad != null && lockedQuad.activeSelf)
        {
            float lDistance = Distance - 0.005f;
            float lWidth = (2f * lDistance) / Mathf.Abs(m00);
            float lHeight = (2f * lDistance) / Mathf.Abs(m11);
            float lOffsetX = (proj.m02 * lDistance) / m00;
            float lOffsetY = (proj.m12 * lDistance) / m11;
            lockedQuad.transform.localScale = new Vector3(lWidth, lHeight, 1f);

            if (isLocked)
            {
                float angleDelta = Quaternion.Angle(camera.transform.rotation, lockedCamRot);
                float distDelta = Vector3.Distance(camera.transform.position, lockedCamPos);
                if (angleDelta < 4.0f && distDelta < 0.15f)
                {
                    // Small head motion compensation (micro-warp)
                    Quaternion deltaRot = Quaternion.Inverse(camera.transform.rotation) * lockedCamRot;
                    Vector3 deltaPos = camera.transform.InverseTransformDirection(lockedCamPos - camera.transform.position);
                    lockedQuad.transform.localRotation = Quaternion.Slerp(Quaternion.identity, deltaRot, 0.70f);
                    lockedQuad.transform.localPosition = new Vector3(lOffsetX, lOffsetY, lDistance) + deltaPos * 0.12f;
                }
                else
                {
                    // Delta exceeded: release warp, clamp camera-aligned, hold image without rubber-sheeting
                    lockedQuad.transform.localRotation = Quaternion.identity;
                    lockedQuad.transform.localPosition = new Vector3(lOffsetX, lOffsetY, lDistance);
                }
            }
            else
            {
                lockedQuad.transform.localRotation = Quaternion.identity;
                lockedQuad.transform.localPosition = new Vector3(lOffsetX, lOffsetY, lDistance);
            }
        }
    }

    public void SetLockedFrame(Texture2D frameTex, bool instant = false)
    {
        EnsureLockedQuad();
        if (lockedMaterial != null && frameTex != null)
        {
            lockedMaterial.SetTexture("_MainTex", frameTex);
        }

        var camera = GetComponentInParent<Camera>();
        if (camera != null)
        {
            lockedCamPos = camera.transform.position;
            lockedCamRot = camera.transform.rotation;
        }

        isLocked = true;
        if (lockedQuad != null)
            lockedQuad.SetActive(true);

        if (instant)
        {
            fadeAlpha = 1f;
            targetAlpha = 1f;
            if (lockedMaterial != null) lockedMaterial.SetFloat("_Alpha", 1f);
        }
        else
        {
            targetAlpha = 1f;
        }

        // Live shader OFF while locked to prevent double-paint sunglass look
        ApplyFinish();
    }

    public void ReleaseLockedFrame()
    {
        targetAlpha = 0f;
    }

    void EnsureLockedQuad()
    {
        if (lockedQuad != null && lockedMaterial != null) return;

        var camera = GetComponentInParent<Camera>();
        if (camera == null) return;

        var existing = camera.transform.Find("ShowroomLockedFrame");
        if (existing != null)
        {
            lockedQuad = existing.gameObject;
        }
        else
        {
            lockedQuad = GameObject.CreatePrimitive(PrimitiveType.Quad);
            lockedQuad.name = "ShowroomLockedFrame";
            var collider = lockedQuad.GetComponent<Collider>();
            if (collider != null) Destroy(collider);
            lockedQuad.transform.SetParent(camera.transform, false);
        }

        if (lockedMaterial == null)
        {
            var shader = Shader.Find("ARCar/ShowroomFrame");
            if (shader == null) shader = Shader.Find("Universal Render Pipeline/Unlit");
            if (shader == null) shader = Shader.Find("Unlit/Texture");
            lockedMaterial = new Material(shader) { name = "ShowroomFrameMat" };
            lockedMaterial.SetFloat("_Alpha", fadeAlpha);
        }

        var renderer = lockedQuad.GetComponent<Renderer>();
        if (renderer != null)
            renderer.sharedMaterial = lockedMaterial;
    }

    public bool SetTint(Color color)
    {
        if (!EnsureMaterial()) return false;
        material.SetColor("_Tint", color);
        ApplyFinish();
        return true;
    }

    public void SetFinish(float metallic, float smoothness, float strength, float panel, float finishMode = 0f)
    {
        this.metallic = metallic;
        this.smoothness = smoothness;
        this.strength = strength;
        this.panel = panel;
        this.finishMode = finishMode;
        ApplyFinish();
    }

    public void SetDebugMaskMode(bool enabled)
    {
        debugMaskMode = enabled ? 1f : 0f;
        if (EnsureMaterial())
            ApplyFinish();
    }

    public void SetCaptureCleanHide(bool hide)
    {
        captureCleanHide = hide;
        var mr = GetComponent<MeshRenderer>();
        if (mr != null)
            mr.enabled = maskApplied && !hide;
        if (lockedQuad != null && isLocked)
            lockedQuad.SetActive(!hide);
        if (material != null)
            material.SetFloat("_Strength", (maskApplied && !isLocked && !hide) ? strength : 0f);
    }

    public bool SetMask(Texture mask, float letterboxAspect = 1.0f, Vector3 capturePos = default, Quaternion captureRot = default)
    {
        if (mask == null)
        {
            ClearLive();
            return false;
        }

        if (!EnsureMaterial()) return false;
        maskApplied = true;
        material.SetTexture("_MaskTex", mask);
        material.SetFloat("_LetterboxAspect", letterboxAspect);

        var mr = GetComponent<MeshRenderer>();
        if (mr != null) mr.enabled = !captureCleanHide;

        var camera = GetComponentInParent<Camera>();
        if (camera != null)
        {
            maskCamPos = (capturePos != default) ? capturePos : camera.transform.position;
            maskCamRot = (captureRot != default) ? captureRot : camera.transform.rotation;
            hasMaskPose = true;
            motionFade = 1.0f;
        }

        ApplyFinish();
        return maskApplied;
    }

    public void ClearLive()
    {
        maskApplied = false;
        hasMaskPose = false;
        if (material != null)
        {
            material.SetTexture("_MaskTex", Texture2D.blackTexture);
            material.SetTexture("_SceneTex", Texture2D.blackTexture);
            material.SetFloat("_Strength", 0f);
            material.SetVector("_MaskUVOffset", Vector4.zero);
        }
        var mr = GetComponent<MeshRenderer>();
        if (mr != null) mr.enabled = false;

        ReleaseLockedFrame();
        if (lockedQuad != null) lockedQuad.SetActive(false);
        isLocked = false;
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
        material.SetFloat("_Finish", finishMode);
        material.SetFloat("_DebugMaskMode", debugMaskMode);
        // Live shader OFF while showroom full frame is locked, paused, or capturing clean original photo
        material.SetFloat("_Strength", (maskApplied && !isLocked && !captureCleanHide) ? strength : 0f);
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
