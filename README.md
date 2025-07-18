# Garden

A performance-focused multi-media engine.

## Building

Unfortunately, building is not as simple as `zig build`.

1. `sh build_deps.sh` - Builds all dependencies (NRI, Slang, etc.) with complex build steps. The artifacts of these are
                        saved into `external/<lib>/*`. The dependency sources are pulled from `tools/dependency-manager` 
                        which references `build_config.zon`.
2. `zig build` - Builds everything else; will detect if step 1's dependencies haven't been built and run step 1 with
                 default settings if so.

## TODO

- [x] Basic Rendering
  - [x] Vulkan via SDL3 GPU
    - Will eventually convert to either full Vulkan or WebGPU
      - Ideally with an RHI
  - [x] Swapchain rendering
  - [x] ImGui Debug Window 
- [ ] Shader Compilation
  - [x] Online shader compilation with slang's compilation API
  - [ ] Offline shader compilation (invoke in build.zig)
  - [ ] Dedicated thread with persistent compilation session
- [ ] Engine Architecture
  - [x] "Objects"
    - [x] Imperative Usage
    - [ ] ECS(?)
      - Not particularly a fan of the method, will need to benchmark against imperative. 
  - [x] Lights (but not well)
    - A non-cohesive mess of objects.
- [ ] Lighting
  - [ ] Reflectance Models
    - [x] Single color (Lights)
    - [x] Flat Shading (Surface normals)
    - [x] Phong (Vertex normals)
    - [ ] Blinn-Phong
- [ ] Models
  - [ ] Stable ABI/API
  - [ ] OBJ with `tinyobjloader-c`
  - [ ] GLTF
    - Will require a rework of "objects"
  - [ ] LODs
    - [ ] Static
    - [ ] Dynamic
- [ ] Materials
  - Per OBJ Material Descriptions
  - [x] Ambient
    - [x] Color
    - [ ] Map/Texture
  - [x] Diffuse
    - [x] Color
    - [x] Map/Texture
  - [x] Specular
    - [x] Color
    - [ ] Map/Texture
    - [x] Highlight/Exponent/Shininess
      - [ ] Map/Texture
  - [ ] Transmittance
  - [ ] Emission
  - [ ] IOR
  - [ ] Dissolve
  - [ ] Illum
  - [ ] Bump Map
  - [ ] Displacement Map
  - [ ] Alpha Map
  - [ ] Textures
    - [x] Online
    - [ ] Offline
    - [ ] Some textures are appearing on the back of meshes when they are shown on both sides in blender.
    - [ ] Streaming
- [ ] Binary Resource Cache
  - Can be loaded with runtime-loaded and embedded data.
- [ ] Post-processing
  - [ ] HDR
  - [ ] Bloom
  - [ ] AA
  - [ ] Gamma Correction
- [ ] Skybox
  - [ ] Environment Lighting
- [ ] Scene
  - [ ] Frustum culling (AABB/Compute)
  - [ ] BVH
- [ ] Audio
  - [ ] Mono/Stereo
  - [ ] Spatial
- [ ] Physics
- [ ] Assets
  - [ ] Offline Compression
  - [ ] Streaming
  - [ ] Multi-threading
- [ ] Hot-reloading
  - [x] Shader recompilation
    - [ ] Needs caching
  - [ ] Models
  - [ ] Lights
  - [ ] Perhaps a better scene description format (OpenUSD)
- [ ] Debugging
  - [x] Tracy Zones / Allocation Tracking
  - [ ] Validation Layers