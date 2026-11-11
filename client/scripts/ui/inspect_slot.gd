class_name InspectSlot
extends PanelContainer
## Blocks E6 / L8: one place in the Tab inspect view (InspectView) that takes drops: a column, a pocket or square
## group, or an item row; an item row can also be dragged from. Godot's drag and drop hooks only hand over to the
## view, which decides what a drop does. Mouse filter PASS: a drop the slot doesn't take (an item row that isn't
## a container) goes on to the group / column around it, and the wheel still scrolls.

var view: InspectView
## What dropping here means: {kind: "column" | "group" | "row", column: column id, key: group key, row: row}.
var target := {}
## The InventoryModel row dragged from here; {} for none (columns, groups).
var row := {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_NONE


func _gui_input(event: InputEvent) -> void:
	if view != null and not row.is_empty():
		view.row_input(row, event)   # clicks select


func _get_drag_data(_at: Vector2) -> Variant:
	if view == null or row.is_empty():
		return null
	var data: Variant = view.drag_data(row)
	if data != null and is_inside_tree() and get_viewport().gui_is_dragging():
		set_drag_preview(view.drag_preview(row))
	return data


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return view != null and view.can_drop(data, target)


func _drop_data(_at: Vector2, data: Variant) -> void:
	if view != null:
		view.drop(data, target)
