// Generate a GTK/Adwaita stylesheet for the qml-css engine, so the app can wear the
// system GTK theme and be indistinguishable from a native GTK app. We read the live
// desktop settings (light/dark + accent) via gsettings and emit the matching libadwaita
// palette as `@define-color`s plus per-token selectors (#pw-window, #pw-sidebar, …) that
// qml/Main.qml reads back through cssTheme.resolve(). The palette values are the exact
// resolved libadwaita named colours (extracted from the running theme), flattened to
// solid #rrggbb where the original carried alpha, so QML's `color` parses them directly.
module photowagon.ui.gtktheme;

import std.process : execute;
import std.string : strip, toLower;
import std.format : format;

/// One resolved Adwaita palette (the subset the app's chrome needs). Hex strings.
private struct Palette
{
    string windowBg, windowFg, viewBg, headerbarBg, sidebarBg, secondarySidebarBg,
           cardBg, popoverBg, borders, fieldBg;
}

// Adwaita LIGHT — the resolved libadwaita named colours (alpha flattened over their bg):
// window_fg_color is 80% black over #fafafb → #323236; borders is 12% black → #dcdcde.
private enum Palette adwLight = Palette(
    "#fafafb", "#323236", "#ffffff", "#ffffff", "#ebebed", "#f3f3f5",
    "#ffffff", "#ffffff", "#dcdcde", "#ffffff");

// Adwaita DARK — resolved libadwaita dark: card_bg_color is 8% white over the view → #2c2c2f;
// borders is 15% white over the window → #434348.
private enum Palette adwDark = Palette(
    "#222226", "#ffffff", "#1d1d20", "#2e2e32", "#2e2e32", "#28282c",
    "#2c2c2f", "#36363a", "#434348", "#2c2c30");

/// GNOME 47+ named accent → the libadwaita @accent_bg_color hex (matches backend.d).
private string adwaitaAccentHex(string name)
{
    switch (name)
    {
        case "blue":   return "#3584e4";
        case "teal":   return "#2190a4";
        case "green":  return "#3a944a";
        case "yellow": return "#c88800";
        case "orange": return "#ed5b00";
        case "red":    return "#e62d42";
        case "pink":   return "#d56199";
        case "purple": return "#9141ac";
        case "slate":  return "#6f8396";
        default:       return "#3584e4";
    }
}

private string gsetting(string key)
{
    try
    {
        auto r = execute(["gsettings", "get", "org.gnome.desktop.interface", key]);
        if (r.status == 0)
        {
            auto s = r.output.strip;
            if (s.length >= 2 && s[0] == '\'' && s[$ - 1] == '\'')
                s = s[1 .. $ - 1];
            return s;
        }
    }
    catch (Exception)
    {
    }
    return "";
}

/// True when the desktop is in dark mode (`color-scheme` = prefer-dark).
bool gtkPrefersDark()
{
    return gsetting("color-scheme").toLower == "prefer-dark";
}

/// Build the full GTK/Adwaita stylesheet for the current desktop settings. Callers hand
/// the result to pw_css_load_string; qml/Main.qml's "gtk" theme mode reads the tokens via
/// cssTheme.resolve("pw-window") etc.
string gtkThemeCss()
{
    immutable dark = gtkPrefersDark();
    immutable p = dark ? adwDark : adwLight;
    immutable accent = adwaitaAccentHex(gsetting("accent-color").toLower);

    return format(q"CSS
@define-color window_bg_color %1$s;
@define-color window_fg_color %2$s;
@define-color view_bg_color %3$s;
@define-color headerbar_bg_color %4$s;
@define-color sidebar_bg_color %5$s;
@define-color secondary_sidebar_bg_color %6$s;
@define-color card_bg_color %7$s;
@define-color popover_bg_color %8$s;
@define-color borders_color %9$s;
@define-color field_bg_color %10$s;
@define-color accent_bg_color %11$s;

#pw-window    { background-color: @window_bg_color; color: @window_fg_color; }
#pw-content   { background-color: @view_bg_color;   color: @window_fg_color; }
#pw-sidebar   { background-color: @sidebar_bg_color; }
#pw-panel     { background-color: @secondary_sidebar_bg_color; }
#pw-toolbar   { background-color: @headerbar_bg_color; }
#pw-viewer    { background-color: @view_bg_color; }
#pw-tile      { background-color: @card_bg_color; }
#pw-popover   { background-color: @popover_bg_color; }
#pw-field     { background-color: @field_bg_color; }
#pw-separator { color: @borders_color; }
#pw-text      { color: @window_fg_color; }
#pw-accent    { color: @accent_bg_color; }
CSS", p.windowBg, p.windowFg, p.viewBg, p.headerbarBg, p.sidebarBg, p.secondarySidebarBg,
   p.cardBg, p.popoverBg, p.borders, p.fieldBg, accent);
}
