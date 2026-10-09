package com.xraph.plugin.flutter_unity_widget

import android.app.Activity
import com.unity3d.player.UnityPlayerForActivityOrService

/**
 * Unity 6 made UnityPlayer abstract. The embeddable type is UnityPlayerForActivityOrService.
 * Do not subclass UnityPlayer directly: its constructor is no longer (Context).
 */
class CustomUnityPlayer(context: Activity) : UnityPlayerForActivityOrService(context)
