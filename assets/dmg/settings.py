# Layout do DMG para o dmgbuild (uvx dmgbuild -s assets/dmg/settings.py -D app=... "Notch Limits" out.dmg)
# background.tiff = background.html renderizado em 1x + 2x (tiffutil -cathidpicheck)
import os

app = defines["app"]
appname = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("volicon")

background = os.path.join(os.path.dirname(os.path.abspath(defines["app"])), "..", "assets", "dmg", "background.tiff")
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    appname: (178, 190),
    "Applications": (482, 190),
}
hide_extensions = [appname]
