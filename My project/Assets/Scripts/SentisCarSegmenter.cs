using System.Collections;
using FlutterUnityIntegration;
using UnityEngine;
using UnityEngine.XR.ARFoundation;

/// <summary>
/// Manages the live car filter loop and 6DoF AR camera motion tracking.
/// Coordinates with the high-precision YOLOv8s-seg mask pipeline and ensures
/// Adreno 830 Vulkan never suffers from GPUCompute shader compilation errors or blank-mask overwrites.
/// </summary>
public class SentisCarSegmenter : MonoBehaviour
{
    bool loopActive;
    bool externalMaskActive;
    Coroutine loopCoroutine;

    Vector3 lastSettledPos;
    Quaternion lastSettledRot = Quaternion.identity;
    bool initializedPose;

    public bool IsLoopActive => loopActive;

    public void NotifyExternalMaskApplied()
    {
        externalMaskActive = true;
        var cam = Camera.main;
        if (cam != null)
        {
            lastSettledPos = cam.transform.position;
            lastSettledRot = cam.transform.rotation;
            initializedPose = true;
        }
    }

    public void Run()
    {
        StartLiveLoop();
    }

    public void StartLiveLoop()
    {
        if (loopActive && loopCoroutine != null)
            return;
        loopActive = true;
        loopCoroutine = StartCoroutine(LiveLoopRoutine());
    }

    public void StopLiveLoop()
    {
        loopActive = false;
        externalMaskActive = false;
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

    IEnumerator LiveLoopRoutine()
    {
        Report("SENTIS_LIVE_STARTED");
        Report("SENTIS_NEEDS_MASK");

        Vector3 prevPos = Vector3.zero;
        Quaternion prevRot = Quaternion.identity;
        bool hasMovedSinceSettle = false;
        float stillDuration = 0f;
        float lastTriggerTime = Time.unscaledTime;

        const float pollInterval = 0.06f;
        const float moveAngleThreshold = 1.8f;
        const float moveDistThreshold = 0.03f;
        const float largePanAngleThreshold = 3.2f;
        const float largePanDistThreshold = 0.055f;
        const float stillAngleDeltaMax = 0.85f;
        const float stillDistDeltaMax = 0.014f;
        const float settleHoldSeconds = 0.15f;
        const float minCooldownSeconds = 0.38f;

        while (loopActive)
        {
            var cam = Camera.main;
            if (cam != null)
            {
                Vector3 curPos = cam.transform.position;
                Quaternion curRot = cam.transform.rotation;

                if (!initializedPose)
                {
                    initializedPose = true;
                    lastSettledPos = curPos;
                    lastSettledRot = curRot;
                    prevPos = curPos;
                    prevRot = curRot;
                }
                else
                {
                    float angleFromSettled = Quaternion.Angle(curRot, lastSettledRot);
                    float distFromSettled = Vector3.Distance(curPos, lastSettledPos);
                    if (angleFromSettled > moveAngleThreshold || distFromSettled > moveDistThreshold)
                    {
                        hasMovedSinceSettle = true;
                    }

                    // If user pans significantly to a new angle or a different car, clear the stale angle mask immediately
                    if (externalMaskActive && (angleFromSettled > largePanAngleThreshold || distFromSettled > largePanDistThreshold))
                    {
                        externalMaskActive = false;
                        var filter = LiveCarFilter.Ensure(cam);
                        if (filter != null)
                            filter.SetMask(null);
                    }

                    float frameAngleDelta = Quaternion.Angle(curRot, prevRot);
                    float frameDistDelta = Vector3.Distance(curPos, prevPos);

                    if (frameAngleDelta < stillAngleDeltaMax && frameDistDelta < stillDistDeltaMax)
                    {
                        stillDuration += pollInterval;
                    }
                    else
                    {
                        stillDuration = 0f;
                    }

                    prevPos = curPos;
                    prevRot = curRot;

                    if (hasMovedSinceSettle &&
                        stillDuration >= settleHoldSeconds &&
                        (Time.unscaledTime - lastTriggerTime) >= minCooldownSeconds)
                    {
                        hasMovedSinceSettle = false;
                        stillDuration = 0f;
                        lastSettledPos = curPos;
                        lastSettledRot = curRot;
                        lastTriggerTime = Time.unscaledTime;
                        Report("CAMERA_SETTLED");
                    }
                }
            }

            yield return new WaitForSeconds(pollInterval);
        }
    }

    void OnDestroy()
    {
        loopActive = false;
    }
}
