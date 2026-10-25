extends CharacterBody3D

const SPEED = 10.0
const JUMP_VELOCITY = 4.5
const ROTATION_SPEED = 12.0 # How fast the player snaps to face their walking direction

# Automatically references your imported Blender model node
@onready var visual_model: Node3D = $Model

# Drag and drop your Camera3D node directly into this slot in the Inspector!
@export var camera: Camera3D

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# 1. Get raw input from keyboard (WASD)
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	
	# Initialize our 3D direction vector
	var direction := Vector3.ZERO
	
	# 2. Calculate movement relative to the camera's orientation
	if camera:
		# Grab the forward and right vectors of the camera
		var cam_basis = camera.global_transform.basis
		
		# Flatten the camera vectors onto the horizontal plane (ignore up/down tilt)
		var cam_forward = Vector3(cam_basis.z.x, 0, cam_basis.z.z).normalized()
		var cam_right = Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
		
		# Combine camera directions with our keyboard input
		# input_dir.y is up/down (mapped to camera forward)
		# input_dir.x is left/right (mapped to camera right)
		direction = (cam_right * input_dir.x + cam_forward * input_dir.y).normalized()
	else:
		# Fallback to standard global directions if no camera is linked yet
		direction = Vector3(input_dir.x, 0, input_dir.y).normalized()

	# 3. Apply movement velocity
	if direction != Vector3.ZERO:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
		
		# 4. Smoothly rotate the visual model to face the direction of movement
		# Using atan2 to find the horizontal angle of our calculated camera-relative direction
		var target_angle = atan2(direction.x, direction.z)
		visual_model.rotation.y = lerp_angle(visual_model.rotation.y, target_angle, ROTATION_SPEED * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()
