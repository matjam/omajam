import QtQml

QtObject {
  function fromUrl(url) {
    var text = String(url)
    return text.indexOf("file://") === 0 ? decodeURIComponent(text.substring(7)) : text
  }
}
