import QtQuick
import QtQuick.Controls

// The context menu of one photo or of a selection: copy the files, copy the
// paths, open the folder, favorite, add to an album, and what kind of picture
// they are, and where they were taken. `ids` are the photos it acts on; `path` the folder to open (one photo).
Menu {
    id: menu
    required property QtObject theme
    property var ids: []
    property string path: ""
    property bool favorite: false

    signal copy(var ids)
    signal copyPath(var ids)
    signal openFolder(string path)
    signal toggleFavorite(var ids)
    signal addToAlbum(var ids)
    signal setPlace(var ids)
    signal setKind(var ids, string kind)
    signal remove(var ids, bool permanent)

    readonly property string suffix: ids.length === 1 ? "" : " (" + ids.length + ")"

    MenuItem { text: "Copy" + menu.suffix; onTriggered: menu.copy(menu.ids) }
    MenuItem { text: "Copy Path" + menu.suffix; onTriggered: menu.copyPath(menu.ids) }
    MenuItem { text: "Show in Folder"; enabled: menu.path.length > 0; onTriggered: menu.openFolder(menu.path) }
    MenuSeparator { }
    MenuItem { text: (menu.favorite ? "Unfavorite" : "Favorite") + menu.suffix; onTriggered: menu.toggleFavorite(menu.ids) }
    MenuItem { text: "Add to Album…" + menu.suffix; onTriggered: menu.addToAlbum(menu.ids) }
    MenuItem { text: "Set Place…" + menu.suffix; onTriggered: menu.setPlace(menu.ids) }
    MenuSeparator { }
    MenuItem { text: "Move to Trash" + menu.suffix; onTriggered: menu.remove(menu.ids, false) }
    MenuItem { text: "Delete Permanently…" + menu.suffix; onTriggered: menu.remove(menu.ids, true) }
    MenuSeparator { }
    Menu {
        title: "Mark as" + menu.suffix
        MenuItem { text: "Photo"; onTriggered: menu.setKind(menu.ids, "photo") }
        MenuItem { text: "Screenshot"; onTriggered: menu.setKind(menu.ids, "screenshot") }
        MenuItem { text: "Meme"; onTriggered: menu.setKind(menu.ids, "meme") }
    }
}
