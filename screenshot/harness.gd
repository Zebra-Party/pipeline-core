extends Node

# Generic CI screenshot harness for any Godot 4 project. Launched
# once per (scene × resolution) via tools/ci/screenshot_scenes.sh.
#
# Parses args from OS.get_cmdline_user_args(), optionally runs a
# project-specific seed script to populate autoloads, renders the
# target scene into a SubViewport at the requested resolution, and
# writes a PNG.
#
# Run directly:
#   godot --rendering-driver opengl3 res://tools/ci/screenshot_harness.tscn \
#     -- --scene=res://scenes/foo.tscn --out=/tmp/foo.png \
#     --width=1080 --height=2400 \
#     [--seed=res://tools/ci/screenshot_seed.gd]
#
# The seed script, if provided, should extend RefCounted and expose
#   func seed(scene_path: String) -> void
# which the harness calls before instancing the target scene.

const SETTLE_FRAMES := 20
const DEFAULT_SEED_PATH := "res://tools/ci/screenshot_seed.gd"


func _ready() -> void:
	var args := _parse_args()
	var scene_path: String = args.get("scene", "")
	var out_path: String = args.get("out", "")
	var width: int = int(args.get("width", 1080))
	var height: int = int(args.get("height", 1920))
	# Empty string disables seeding; unset falls back to the conventional
	# path so a project just has to drop the file in to opt in.
	var seed_path: String = args.get("seed", DEFAULT_SEED_PATH)

	if scene_path == "" or out_path == "":
		push_error("screenshot_harness: --scene and --out are required")
		get_tree().quit(2)
		return

	# The window size is set via --resolution in screenshot_scenes.sh —
	# runtime DisplayServer resizes under xvfb don't propagate to the
	# viewport's render target reliably. We still set content_scale_size
	# so UI layout uses the requested design resolution.
	get_tree().root.content_scale_size = Vector2i(width, height)

	# Render into a SubViewport instead of the root Window. Reading
	# the root Window's framebuffer via get_texture().get_image() is
	# unreliable under xvfb+opengl3 — it returns a solid-clear-colour
	# buffer even when the scene is correctly in the tree. A
	# SubViewport is an explicit off-screen render target, which
	# makes the capture deterministic.
	var svp := SubViewport.new()
	svp.size = Vector2i(width, height)
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	svp.handle_input_locally = false
	add_child(svp)

	print(
		(
			"screenshot_harness: window=%s root_vp=%s svp=%s content_scale=%s"
			% [
				DisplayServer.window_get_size(),
				get_viewport().size,
				svp.size,
				get_tree().root.content_scale_size,
			]
		)
	)

	_run_seed(seed_path, scene_path)

	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("screenshot_harness: failed to load %s" % scene_path)
		get_tree().quit(3)
		return

	var target := packed.instantiate()
	svp.add_child(target)

	# Let _ready fan-out finish, layout resolve, fonts load, and tweens
	# reach their resting state before we capture.
	for i in range(SETTLE_FRAMES):
		await get_tree().process_frame

	# Force one more draw cycle so the last layout update is flushed to
	# the SubViewport's texture before we read it back.
	RenderingServer.force_draw(false)
	await RenderingServer.frame_post_draw

	var img: Image = svp.get_texture().get_image()
	var dir_path := out_path.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var err := img.save_png(out_path)
	if err != OK:
		push_error("screenshot_harness: save_png failed with %d" % err)
		get_tree().quit(4)
		return

	print(
		(
			"screenshot_harness: wrote %s (requested %dx%d, got %dx%d)"
			% [out_path, width, height, img.get_width(), img.get_height()]
		)
	)
	get_tree().quit(0)


func _parse_args() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if not arg.begins_with("--") or not ("=" in arg):
			continue
		var kv := arg.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1]
	return out


func _run_seed(seed_path: String, scene_path: String) -> void:
	if seed_path == "":
		return
	if not ResourceLoader.exists(seed_path):
		# Missing is fine when the path is the default — the project
		# just hasn't opted into seeding.
		if seed_path != DEFAULT_SEED_PATH:
			push_warning("screenshot_harness: seed script not found at %s" % seed_path)
		return
	var script := load(seed_path) as GDScript
	if script == null:
		push_warning("screenshot_harness: failed to load seed script %s" % seed_path)
		return
	var obj = script.new()
	if not obj.has_method("seed"):
		push_warning(
			"screenshot_harness: seed script %s has no seed(scene_path) method" % seed_path
		)
		return
	obj.seed(scene_path)
