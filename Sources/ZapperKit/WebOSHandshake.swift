import Foundation

/// The registration manifest webOS expects. Current firmware accepts a plain
/// permission list; the old signed `com.lge.test` blob is no longer required.
enum WebOSHandshake {
    static let permissions: [String] = [
        "APP_TO_APP",
        "CLOSE",
        "CONTROL_AUDIO",
        "CONTROL_DISPLAY",
        "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_PLAYBACK",
        "CONTROL_INPUT_MEDIA_RECORDING",
        "CONTROL_INPUT_TEXT",
        "CONTROL_INPUT_TV",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "CONTROL_POWER",
        "CONTROL_TV_SCREEN",
        "LAUNCH",
        "LAUNCH_WEBAPP",
        "READ_APP_STATUS",
        "READ_COUNTRY_INFO",
        "READ_CURRENT_CHANNEL",
        "READ_INPUT_DEVICE_LIST",
        "READ_INSTALLED_APPS",
        "READ_LGE_SDX",
        "READ_LGE_TV_INPUT_EVENTS",
        "READ_NETWORK_STATE",
        "READ_NOTIFICATIONS",
        "READ_POWER_STATE",
        "READ_RUNNING_APPS",
        "READ_SETTINGS",
        "READ_TV_CHANNEL_LIST",
        "READ_TV_CURRENT_TIME",
        "READ_UPDATE_INFO",
        "SEARCH",
        "TEST_OPEN",
        "TEST_PROTECTED",
        "TEST_SECURE",
        "UPDATE_FROM_REMOTE_APP",
        "WRITE_NOTIFICATION_ALERT",
        "WRITE_NOTIFICATION_TOAST",
        "WRITE_SETTINGS",
    ]

    static var payload: JSONDict {
        [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "appVersion": "1.1",
                "manifestVersion": 1,
                "permissions": permissions,
            ] as JSONDict,
        ]
    }
}

/// SSAP endpoints used by the app.
enum SSAP {
    static let volumeUp        = "ssap://audio/volumeUp"
    static let volumeDown      = "ssap://audio/volumeDown"
    static let setVolume       = "ssap://audio/setVolume"
    static let setMute         = "ssap://audio/setMute"
    static let volumeStatus    = "ssap://audio/getVolume"

    static let channelUp       = "ssap://tv/channelUp"
    static let channelDown     = "ssap://tv/channelDown"
    static let openChannel     = "ssap://tv/openChannel"
    static let currentChannel  = "ssap://tv/getCurrentChannel"
    static let channelList     = "ssap://tv/getChannelList"

    static let externalInputs  = "ssap://tv/getExternalInputList"
    static let switchInput     = "ssap://tv/switchInput"

    static let launchPoints    = "ssap://com.webos.applicationManager/listLaunchPoints"
    static let foregroundApp   = "ssap://com.webos.applicationManager/getForegroundAppInfo"
    static let launch          = "ssap://system.launcher/launch"
    static let captureScreen   = "ssap://tv/executeOneShot"

    static let turnOff         = "ssap://system/turnOff"
    static let toast           = "ssap://system.notifications/createToast"

    static let pointerSocket   = "ssap://com.webos.service.networkinput/getPointerInputSocket"
}
