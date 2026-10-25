extends Camera3D

# Drag your CharacterBody3D node into this slot in the Inspector panel!
@export var target: CharacterBody3D

@export var distance: float = 4.0      # How far behind the player the camera sits
@export var height: float = 2.0        # How high above the player the camera sits
@export var follow_speed: float = 5.0  # Smooth follow speed for position
@export var rotation_speed: float = 3.0 # Smooth interpolation speed for rotation

# Keeps track of the current horizontal angle of the camera
var current_angle: float = 0.0

func _ready() -> void:
	if target:
		# Initialize the angle based on the player's starting orientation
		current_angle = target.global_transform.basis.get_euler().y

func _physics_process(delta: float) -> void:
	if not target:
		return

	# 1. Track the player's movement velocity vector (ignoring the up/down Y velocity)
	var move_velocity = Vector3(target.velocity.x, 0, target.velocity.z)

	# 2. If the player is moving, calculate the angle of their movement direction
	if move_velocity.length() > 0.1:
		# atan2 calculates the horizontal angle of the movement vector
		var target_angle = atan2(-move_velocity.x, -move_velocity.z)
		
		# Smoothly rotate the current angle toward the target movement angle
		current_angle = lerp_angle(current_angle, target_angle, rotation_speed * delta)

	# 3. Calculate where the camera should be positioned based on the angle
	var offset = Vector3(
		sin(current_angle) * distance,
		height,
		cos(current_angle) * distance
	)
	var target_position = target.global_position + offset

	# 4. Smoothly slide the camera's position toward the target position
	global_position = global_position.lerp(target_position, follow_speed * delta)

	# 5. Force the camera to always tilt down and look at the player's body
	look_at(target.global_position + Vector3(0, 1, 0), Vector3.UP)
