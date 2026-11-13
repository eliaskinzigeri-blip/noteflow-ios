"""Source SideStore de NoteFlow (format AltStore 2) : la dernière version compilée.
Lancé par .github/workflows/ios.yml après le paquet .ipa ; écrit le JSON sur la sortie standard."""
import datetime
import json
import os

run = os.environ["RUN"]
repo = os.environ["GITHUB_REPOSITORY"]
raw = f"https://raw.githubusercontent.com/{repo}"
icon = f"{raw}/main/ios/NoteFlow/Assets.xcassets/AppIcon.appiconset/icon.png"
note = (os.environ.get("MSG") or "Nouvelle version").splitlines()[0][:200]

source = {
    "name": "NoteFlow",
    "identifier": "com.noteflow.source",
    "subtitle": "L’app iPhone de NoteFlow",
    "sourceURL": f"{raw}/ios-build/source.json",
    "iconURL": icon,
    "tintColor": "#0A0A0A",
    "apps": [{
        "name": "NoteFlow",
        "bundleIdentifier": "com.noteflow.app",
        "developerName": "NoteFlow",
        "subtitle": "Révisions, routine et activité en direct",
        "localizedDescription": "NoteFlow sur iPhone : le site, l’activité en direct de ta routine avec la navigation, "
                                "le widget, le réveil intelligent et les lumières Philips Hue.",
        "iconURL": icon,
        "tintColor": "#0A0A0A",
        "category": "education",
        "versions": [{
            "version": f"1.0.{run}",
            "buildVersion": run,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": note,
            "downloadURL": f"https://github.com/{repo}/releases/download/v1.0.{run}/NoteFlow.ipa",
            "size": os.path.getsize("ios/out/NoteFlow.ipa"),
            "minOSVersion": "17.0",
        }],
        "appPermissions": {
            "entitlements": ["com.apple.security.application-groups"],
            "privacy": {
                "NSLocationWhenInUseUsageDescription": "Suivre ton trajet jusqu’à l’arrêt et au collège.",
                "NSLocationAlwaysAndWhenInUseUsageDescription": "Activité en direct de ton trajet même NoteFlow fermé.",
                "NSCameraUsageDescription": "Photographier tes cours.",
                "NSPhotoLibraryUsageDescription": "Choisir les photos de tes cours.",
                "NSMicrophoneUsageDescription": "Dictée à voix haute.",
                "NSAlarmKitUsageDescription": "Réveil réglé sur ton premier cours.",
                "NSLocalNetworkUsageDescription": "Lever de soleil des lumières Philips Hue.",
            },
        },
    }],
    "news": [],
}
print(json.dumps(source, ensure_ascii=False, indent=2))
