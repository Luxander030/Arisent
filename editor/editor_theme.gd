## Opaque dark theme for the editor's panels (the 3D view shows between them).
class_name EditorTheme
extends RefCounted


static func build() -> Theme:
	var t := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.11, 0.12, 0.15, 0.97)
	panel.content_margin_left = 8
	panel.content_margin_right = 8
	panel.content_margin_top = 6
	panel.content_margin_bottom = 6
	t.set_stylebox("panel", "PanelContainer", panel)
	var popup := panel.duplicate() as StyleBoxFlat
	popup.border_color = Color(0.3, 0.34, 0.42)
	popup.set_border_width_all(1)
	popup.set_corner_radius_all(4)
	t.set_stylebox("panel", "PopupMenu", popup)
	return t
