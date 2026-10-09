using System;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace FlutterUnityIntegration
{
    /// <summary>
    /// Vendored from flutter_unity_widget 2022.2.1 so Unity can call back into Flutter.
    /// </summary>
    public class NativeAPI
    {
#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")]
        public static extern void OnUnityMessage(string message);

        [DllImport("__Internal")]
        public static extern void OnUnitySceneLoaded(string name, int buildIndex, bool isLoaded, bool isValid);
#endif

#if UNITY_WEBGL
        [DllImport("__Internal")]
        public static extern void OnUnityMessageWeb(string message);

        [DllImport("__Internal")]
        public static extern void OnUnitySceneLoadedWeb(string name, int buildIndex, bool isLoaded, bool isValid);
#endif

        public static void OnSceneLoaded(Scene scene, LoadSceneMode mode)
        {
#if UNITY_ANDROID
            try
            {
                AndroidJavaClass jc = new AndroidJavaClass("com.xraph.plugin.flutter_unity_widget.UnityPlayerUtils");
                jc.CallStatic("onUnitySceneLoaded", scene.name, scene.buildIndex, scene.isLoaded, scene.IsValid());
            }
            catch (Exception e)
            {
                Debug.Log(e.Message);
            }
#elif UNITY_WEBGL
            OnUnitySceneLoadedWeb(scene.name, scene.buildIndex, scene.isLoaded, scene.IsValid());
#elif UNITY_IOS && !UNITY_EDITOR
            OnUnitySceneLoaded(scene.name, scene.buildIndex, scene.isLoaded, scene.IsValid());
#endif
        }

        public static void SendMessageToFlutter(string message)
        {
#if UNITY_ANDROID
            try
            {
                AndroidJavaClass jc = new AndroidJavaClass("com.xraph.plugin.flutter_unity_widget.UnityPlayerUtils");
                jc.CallStatic("onUnityMessage", message);
            }
            catch (Exception e)
            {
                Debug.Log(e.Message);
            }
#elif UNITY_WEBGL
            OnUnityMessageWeb(message);
#elif UNITY_IOS && !UNITY_EDITOR
            OnUnityMessage(message);
#else
            Debug.Log("[Flutter bridge inactive in this player] " + message);
#endif
        }
    }
}
