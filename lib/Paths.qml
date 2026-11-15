pragma Singleton
import QtQuick
import Quickshell

// Where this plugin keeps its files. The bar loads the widget straight from the
// plugin directory, so scripts and the cache have to be found relative to it.
Singleton {
    id: root

    readonly property string pluginDir: {
        var url = String(Qt.resolvedUrl("."))
        if (url.indexOf("file://") === 0) {
            try { url = decodeURIComponent(url.substring(7)) } catch (e) {}
        }
        return url.replace(/\/lib\/?$/, "")
    }

    readonly property string home: Quickshell.env("HOME")
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (home + "/.cache")) + "/omarchy"
    readonly property string cacheFile: cacheDir + "/humanos-update-cache.json"

    function script(name) {
        return pluginDir + "/scripts/" + name
    }
}
