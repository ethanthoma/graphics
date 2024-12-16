struct VertexInput {
    @location(0) position: vec3f,
    @location(1) color: vec3f,
};

struct InstanceInput {
    @location(2) model_matrix_0: vec4f,
    @location(3) model_matrix_1: vec4f,
    @location(4) model_matrix_2: vec4f,
    @location(5) model_matrix_3: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
};

struct Camera {
    projection: mat4x4f,
    view: mat4x4f,
};

@group(0) @binding(0) var<uniform> camera: Camera;

@vertex
fn vs_main(
    in: VertexInput,
    instance: InstanceInput,
) -> VertexOutput {
    var out: VertexOutput;

    let model = mat4x4f(
        instance.model_matrix_0,
        instance.model_matrix_1,
        instance.model_matrix_2,
        instance.model_matrix_3
    );

    var world_position = model * vec4f(in.position, 1.0);
    var view_position = camera.view * world_position;
    out.position = camera.projection * view_position;

    out.color = in.color;

	return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
	let linear_color = pow(in.color, vec3f(2.2));
	return vec4f(linear_color, 1.0);
}
