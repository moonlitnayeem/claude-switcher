"""Rebuild the Finder layout with ds_store installed. Release builds use the saved template."""
from pathlib import Path
from ds_store import DSStore


destination = Path(__file__).resolve().parents[1] / "Resources" / "InstallerLayout.dsstore"
with DSStore.open(str(destination), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["vstl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 180}, {580, 300}}",
        "ShowSidebar": False, "ShowToolbar": False, "ShowStatusBar": False,
        "ShowPathbar": False, "ShowTabView": False, "ContainerShowSidebar": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "arrangeBy": "none", "backgroundType": 1,
        "backgroundColorRed": 0.91, "backgroundColorGreen": 0.95, "backgroundColorBlue": 0.93,
        "iconSize": 92.0, "textSize": 13.0, "gridSpacing": 100.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "labelOnBottom": True,
        "showIconPreview": True, "showItemInfo": False, "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["AI Switcher.app"]["Iloc"] = (145, 88)
    store["Applications"]["Iloc"] = (435, 88)
    store["Installation.txt"]["Iloc"] = (290, 218)
