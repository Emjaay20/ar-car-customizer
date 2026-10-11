using System;
using UnityEngine;

/// <summary>
/// Voice Command Dispatcher for AR Car Customizer and Workshop.
/// Inspired by subho004/Voice_AR_App.
/// Interprets spoken phrases and triggers paint, parts, and inspection modes hands-free.
/// </summary>
public class VoiceCommandDispatcher : MonoBehaviour
{
    FlutterMessageReceiver messageReceiver;

    void Awake()
    {
        messageReceiver = GetComponent<FlutterMessageReceiver>();
        if (messageReceiver == null)
        {
            messageReceiver = FindAnyObjectByType<FlutterMessageReceiver>();
        }
    }

    /// <summary>
    /// Processes spoken phrase from speech recognizer bridge.
    /// E.g. "change paint to candy red", "matte black", "inspect car", "clear damage"
    /// </summary>
    public void ProcessVoiceCommand(string rawTranscript)
    {
        if (string.IsNullOrEmpty(rawTranscript))
            return;

        string phrase = rawTranscript.Trim().ToLowerInvariant();
        Debug.Log($"[VoiceCommandDispatcher] Received voice intent: '{phrase}'");

        if (phrase.Contains("red") || phrase.Contains("candy red") || phrase.Contains("carmine"))
        {
            messageReceiver?.ApplyPaint("{\"color\":\"#d0122d\",\"finish\":\"candy\",\"panel\":\"body\"}");
            FlutterMessageReceiver.Report("VOICE_ACK:Applied Candy Red Paint");
        }
        else if (phrase.Contains("black") || phrase.Contains("matte"))
        {
            messageReceiver?.ApplyPaint("{\"color\":\"#1c1c1c\",\"finish\":\"matte\",\"panel\":\"body\"}");
            FlutterMessageReceiver.Report("VOICE_ACK:Applied Matte Black Paint");
        }
        else if (phrase.Contains("silver") || phrase.Contains("metallic"))
        {
            messageReceiver?.ApplyPaint("{\"color\":\"#b7b7be\",\"finish\":\"metallic\",\"panel\":\"body\"}");
            FlutterMessageReceiver.Report("VOICE_ACK:Applied Metallic Silver Paint");
        }
        else if (phrase.Contains("graphite") || phrase.Contains("satin"))
        {
            messageReceiver?.ApplyPaint("{\"color\":\"#6a6e73\",\"finish\":\"satin\",\"panel\":\"body\"}");
            FlutterMessageReceiver.Report("VOICE_ACK:Applied Satin Graphite Paint");
        }
        else if (phrase.Contains("inspect") || phrase.Contains("damage") || phrase.Contains("scan"))
        {
            FlutterMessageReceiver.Report("VOICE_ACK:Triggered Vehicle Damage Inspection");
        }
        else if (phrase.Contains("clear") || phrase.Contains("reset"))
        {
            SpatialDamageAnchorManager.Instance?.ClearPins();
            FlutterMessageReceiver.Report("VOICE_ACK:Cleared Damage Pins");
        }
        else
        {
            FlutterMessageReceiver.Report($"VOICE_UNRECOGNIZED:{phrase}");
        }
    }
}
