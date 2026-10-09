using UnityEngine;
using UnityEngine.XR.ARFoundation;
using UnityEngine.XR.Templates.AR;

/// <summary>
/// The exported scene is still Unity's AR Mobile Template.
/// Its greeting card, logo, and dotted plane overlay sit on top of the camera
/// and do not receive taps through Flutter. Hide them instead of waiting for Continue.
/// </summary>
public class ArTemplateChrome : MonoBehaviour
{
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    static void Install()
    {
        if (FindAnyObjectByType<ArTemplateChrome>() != null)
            return;

        var hider = new GameObject("ArTemplateChrome");
        hider.AddComponent<ArTemplateChrome>();
        DontDestroyOnLoad(hider);
    }

    void Awake()
    {
        Hide();
    }

    void LateUpdate()
    {
        // Planes and coaching cards appear after the first frames.
        Hide();
    }

    public static void Hide()
    {
        var goals = FindObjectsByType<GoalManager>(FindObjectsInactive.Include);
        for (var i = 0; i < goals.Length; i++)
        {
            var goal = goals[i];
            if (goal.greetingPrompt != null)
                goal.greetingPrompt.SetActive(false);
            if (goal.optionsButton != null)
                goal.optionsButton.SetActive(false);
            if (goal.createButton != null)
                goal.createButton.SetActive(false);
            if (goal.menuManager != null)
                goal.menuManager.gameObject.SetActive(false);
            if (goal.stepList != null)
            {
                for (var s = 0; s < goal.stepList.Count; s++)
                {
                    if (goal.stepList[s].stepObject != null)
                        goal.stepList[s].stepObject.SetActive(false);
                }
            }
            goal.enabled = false;
        }

        var menus = FindObjectsByType<ARTemplateMenuManager>(FindObjectsInactive.Include);
        for (var i = 0; i < menus.Length; i++)
            menus[i].gameObject.SetActive(false);

        var canvases = FindObjectsByType<Canvas>(FindObjectsInactive.Include);
        for (var i = 0; i < canvases.Length; i++)
            canvases[i].gameObject.SetActive(false);

        var planes = FindObjectsByType<ARPlane>(FindObjectsInactive.Include);
        for (var i = 0; i < planes.Length; i++)
        {
            var renderers = planes[i].GetComponentsInChildren<Renderer>(true);
            for (var r = 0; r < renderers.Length; r++)
                renderers[r].enabled = false;
        }

        var clouds = FindObjectsByType<ARPointCloud>(FindObjectsInactive.Include);
        for (var i = 0; i < clouds.Length; i++)
        {
            var renderers = clouds[i].GetComponentsInChildren<Renderer>(true);
            for (var r = 0; r < renderers.Length; r++)
                renderers[r].enabled = false;
            var particles = clouds[i].GetComponentsInChildren<ParticleSystem>(true);
            for (var p = 0; p < particles.Length; p++)
                particles[p].Stop(true, ParticleSystemStopBehavior.StopEmittingAndClear);
        }
    }
}
