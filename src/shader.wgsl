struct VoxelRaw {
    @location(0) voxel_data: u32,
};

struct Voxel {
    position: vec3f,
    normal: u32,
    texture: u32,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) tex_coords: vec2f,
    @location(1) texture: u32,
};

struct Camera {
    projection: mat4x4f,
    view: mat4x4f,
};

struct Chunk {
    position: vec3i,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var texture: texture_2d<f32>;
@group(0) @binding(2) var<storage, read> chunk_position: array<Chunk>;

fn from_raw_voxel(raw: VoxelRaw) -> Voxel {
    let position_x = raw.voxel_data & 63u;
    let position_y = (raw.voxel_data >> 6u) & 63u;
    let position_z = (raw.voxel_data >> 12u) & 63u;
    let normal = (raw.voxel_data >> 18u) & 7u;
    let texture = (raw.voxel_data >> 21u) & 63u;

    return Voxel(
        vec3f(f32(position_x), f32(position_y), f32(position_z)),
        u32(normal),
        u32(texture),
    );
}

fn get_local_coords(vertex_idx: u32) -> vec2f {
    switch(vertex_idx) {
        case 0u: { return vec2f(0.0, 0.0); }
        case 1u, 3u: { return vec2f(1.0, 0.0); }
        case 2u, 5u: { return vec2f(0.0, 1.0); }
        case 4u: { return vec2f(1.0, 1.0); }

        default: { return vec2f(0.0, 0.0); }
    };
}

fn get_face_offset(normal: u32, local_coords: vec2f) -> vec3f {
    switch(normal) {
        case 0u: {
            return vec3f(1.0, local_coords.y, 1.0 - local_coords.x);
        }
        case 1u: {
            return vec3f(0.0, local_coords.y, local_coords.x);
        }
        case 2u: {
            return vec3f(local_coords.x, 1.0, 1.0 - local_coords.y);
        }
        case 3u: {
            return vec3f(local_coords.x, 0.0, local_coords.y);
        }
        case 4u: {
            return vec3f(local_coords.x, local_coords.y, 1.0);
        }
        case 5u: {
            return vec3f(1.0 - local_coords.x, local_coords.y, 0.0);
        }

        default: { return vec3f(0.0); }
    }
}

@vertex
fn vs_main(
    raw: VoxelRaw,
    @builtin(vertex_index) vertex_idx: u32,
    @builtin(instance_index) instance_idx: u32,
) -> VertexOutput {
    var out: VertexOutput;
    let voxel = from_raw_voxel(raw);

    let local_coords = get_local_coords(vertex_idx);

    let face_offset = get_face_offset(voxel.normal, local_coords);

    let world_pos = voxel.position + face_offset;

    let view_pos = camera.view * vec4f(world_pos, 1.0);

    out.position = camera.projection * view_pos;
    out.tex_coords = local_coords;
    out.texture = voxel.texture;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let tex_size = textureDimensions(texture);
    let mapped_coords = vec2i(in.tex_coords * vec2f(tex_size));
    let color = textureLoad(texture, mapped_coords, 0).rgb;
    let linear_color = pow(color, vec3f(2.2));
    return vec4f(linear_color, 1.0);
}
