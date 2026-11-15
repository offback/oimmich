import QtQuick
import Quickshell

// Development entry point only: `quickshell -p <this repo>` starts a throwaway
// shell that loads the service and its overlays, without touching the real
// Omarchy shell process. The installed plugin is loaded by omarchy-shell's
// plugin registry instead, using manifest.json.
ShellRoot {
  Service {
    id: dev
  }
}
