import QtQml

QtObject {
  property var shell: null
  property string moduleName: ""

  function versionFor(shell, moduleName) {
    var service = null
    try { service = shell && shell.serviceFor ? shell.serviceFor(moduleName) : null } catch (e) {}
    return (service && service.manifest && service.manifest.version !== undefined)
      ? String(service.manifest.version) : ""
  }

  readonly property string version: versionFor(shell, moduleName)
}
